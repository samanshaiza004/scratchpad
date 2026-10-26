package backend

import (
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"

	"scratchpad/application"
)

func TestPinnedWireRejectsMissingAndOverflowedCoordinates(t *testing.T) {
	valid := `{"version":1,"request_id":1,"command":"pinned_add","document_id":"doc","source_instance":5,"editor_revision":0,"start_byte":0,"end_byte":4}`
	if _, r, ok := decodeCommandRequest([]byte(valid), lifecycleRunning); !ok {
		t.Fatal(r)
	}
	for _, input := range []string{
		strings.Replace(valid, `"editor_revision":0,`, "", 1),
		strings.Replace(valid, `"editor_revision":0`, `"editor_revision":null`, 1),
		strings.Replace(valid, `"source_instance":5`, `"source_instance":0`, 1),
		strings.Replace(valid, `"end_byte":4`, `"end_byte":18446744073709551615`, 1),
		`{"version":1,"request_id":1,"command":"pinned_window","pin_epoch":1,"pin_revision":1,"projection_first":0,"projection_limit":257,"max_bytes":65536}`,
		`{"version":1,"request_id":1,"command":"pinned_window","pin_epoch":1,"pin_revision":1,"projection_first":0,"projection_limit":256,"max_bytes":65537}`,
	} {
		if _, r, ok := decodeCommandRequest([]byte(input), lifecycleRunning); ok || r.OK {
			t.Fatal("bad pinned request accepted", input)
		}
	}
}

func pinnedBridgeCommand(t *testing.T, r *Runtime, request CommandRequest) Response {
	t.Helper()
	request.Version = 1
	request.RequestID = 91
	dispatchForTest(t, r, mustJSON(t, request))
	return decodeResponse(t, r.Pump())
}

func TestPinnedBridgeResourceIdentityAndStaleReorder(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "note.txt")
	writeFile(t, path, "one\ntwo\nthree\n")
	r := newStartedRuntime(t, root)
	defer stopRuntime(t, r)
	if response := pinnedBridgeCommand(t, r, CommandRequest{Command: "open_path", Path: path}); !response.OK {
		t.Fatal(response)
	}
	state := latestStateForTest(t, r)
	doc := state.Documents[0]
	response := pinnedBridgeCommand(t, r, CommandRequest{Command: "pinned_add", DocumentID: doc.ID, SourceInstance: doc.InstanceID, EditorRevision: 0, StartByte: 0, EndByte: 7})
	if !response.OK || response.Pinned == nil || len(response.Pinned.Ranges) != 1 {
		t.Fatal(response)
	}
	s := *response.Pinned
	pin := s.Ranges[0]
	response = pinnedBridgeCommand(t, r, CommandRequest{Command: "pinned_window", PinEpoch: s.Epoch, PinRevision: s.Revision, ProjectionLimit: 256, MaxBytes: 65536})
	if !response.OK || response.PinnedWindow == nil || response.Resource == nil {
		t.Fatal(response)
	}
	data, err := r.caliber.readResourceCopy(response.Resource.ResourceID, response.Resource.Generation)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "onetwo" {
		t.Fatal(string(data))
	}
	_ = r.caliber.releaseResourceOwner(response.Resource.ResourceID, response.Resource.Generation)
	response = pinnedBridgeCommand(t, r, CommandRequest{Command: "pinned_go_to_source", PinEpoch: s.Epoch, PinRevision: s.Revision, PinID: uint64(pin.ID)})
	if !response.OK || response.EditorSelection == nil || response.EditorSelection.AnchorByte != 0 || response.EditorSelection.CursorByte != 7 {
		t.Fatal(response)
	}
	if r.app.Documents[application.DocumentID(doc.ID)].Dirty() {
		t.Fatal("pin navigation changed source")
	}
	response = pinnedBridgeCommand(t, r, CommandRequest{Command: "pinned_copy", PinEpoch: s.Epoch, PinRevision: s.Revision, PinID: uint64(pin.ID)})
	if !response.OK || response.Resource == nil {
		t.Fatal(response)
	}
	data, err = r.caliber.readResourceCopy(response.Resource.ResourceID, response.Resource.Generation)
	if err != nil || string(data) != "one\ntwo" {
		t.Fatal(string(data), err)
	}
	_ = r.caliber.releaseResourceOwner(response.Resource.ResourceID, response.Resource.Generation)
	if err := r.app.Dispatch(application.PresentationCommand{Kind: application.PresentationReplaceDocument, DocumentID: application.DocumentID(doc.ID), StartByte: 0, EndByte: 1, Replacement: []byte("O")}); err != nil {
		t.Fatal(err)
	}
	_ = r.publishApplicationState()
	response = pinnedBridgeCommand(t, r, CommandRequest{Command: "pinned_window", PinEpoch: s.Epoch, PinRevision: s.Revision, ProjectionLimit: 20, MaxBytes: 65536})
	if response.OK || response.Resource != nil || response.Outcome.Code != "stale_pinned_response" {
		t.Fatal("old response produced current bytes", response)
	}
	response = pinnedBridgeCommand(t, r, CommandRequest{Command: "pinned_read"})
	s = *response.Pinned
	if s.Ranges[0].Status != application.ProjectionStale || s.SourceInvalidations != 1 {
		t.Fatal(s)
	}
	encoded, _ := json.Marshal(latestStateForTest(t, r))
	if !strings.Contains(string(encoded), `"pinned_count":1`) {
		t.Fatal("pinned summary was not published")
	}
}
