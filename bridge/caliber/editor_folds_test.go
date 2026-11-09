package backend

import (
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"scratchpad/application"
)

func TestReadEditorFoldsRequestValidation(t *testing.T) {
	valid := `{"version":1,"request_id":80,"command":"read_editor_folds","document_id":"doc","editor_revision":7}`
	request, _, ok := decodeCommandRequest([]byte(valid), lifecycleRunning)
	if !ok || request.Command != "read_editor_folds" || request.DocumentID != "doc" || request.EditorRevision != 7 {
		t.Fatalf("valid fold query rejected: %+v", request)
	}
	for _, tc := range []struct{ old, replacement, code string }{
		{`"document_id":"doc"`, `"document_id":""`, "invalid_document_id"},
		{`"document_id":"doc"`, `"document_id":"bad\u0000id"`, "invalid_document_id"},
		{`"editor_revision":7`, `"editor_revision":null`, "invalid_editor_revision"},
		{`,"editor_revision":7`, "", "invalid_editor_revision"},
	} {
		input := strings.Replace(valid, tc.old, tc.replacement, 1)
		_, response, ok := decodeCommandRequest([]byte(input), lifecycleRunning)
		if ok || response.OK || response.Outcome.Code != tc.code {
			t.Fatalf("accepted/incorrect error for %s: %+v", input, response)
		}
	}
}

func TestEditorFoldsWireSchemaAndDetachedConversion(t *testing.T) {
	plan := application.EditorFoldPlan{DocumentID: "doc", Revision: 7, InstanceID: 12,
		Ready: true, Supported: true, LineCount: 9,
		Folds: []application.EditorFold{{StartLine: 1, BodyStartLine: 2, EndLine: 6,
			StartByte: 8, BodyStartByte: 14, EndByte: 54, Label: "function Run"}}}
	wire := editorFoldsFromApplication(plan)
	encoded, err := json.Marshal(wire)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"document_id":"doc","revision":7,"instance_id":12,"ready":true,"supported":true,"line_count":9,"folds":[{"start_line":1,"body_start_line":2,"end_line":6,"start_byte":8,"body_start_byte":14,"end_byte":54,"label":"function Run"}]}`
	if string(encoded) != want {
		t.Fatalf("wire schema changed:\n%s\nwant:\n%s", encoded, want)
	}
	wire.Folds[0].BodyStartByte = 999
	if plan.Folds[0].BodyStartByte != 14 {
		t.Fatal("wire conversion aliases application fold metadata")
	}
}

func TestReadEditorFoldsReturnsMarkdownProjectionWithoutSourceMutation(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "notes.md")
	source := "# First\nopening\ndetail\n\n# Second\nbody\n"
	writeFile(t, path, source)
	runtime := newStartedRuntime(t, root)
	defer stopRuntime(t, runtime)
	dispatchForTest(t, runtime, mustJSON(t, CommandRequest{Version: ProtocolVersion, RequestID: 80,
		Command: "open_path", Path: path}))
	if response := decodeResponse(t, runtime.Pump()); !response.OK {
		t.Fatalf("open: %+v", response)
	}
	state := latestStateForTest(t, runtime)
	doc := runtime.app.Documents[application.DocumentID(state.Documents[0].ID)]
	if doc == nil {
		t.Fatal("opened document missing from application")
	}
	doc.Editor.SetSelection(8, 14)
	beforeRevision := doc.Revision()
	beforeText := string(doc.Editor.Buffer.Text())
	beforeApplicationRevision := runtime.applicationRevision
	dispatchForTest(t, runtime, mustJSON(t, CommandRequest{Version: ProtocolVersion, RequestID: 81,
		Command: "read_editor_folds", DocumentID: state.Documents[0].ID, EditorRevision: beforeRevision}))
	response := decodeResponse(t, runtime.Pump())
	plan := response.EditorFolds
	deadline := time.Now().Add(3 * time.Second)
	for response.OK && plan != nil && !plan.Ready && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
		dispatchForTest(t, runtime, mustJSON(t, CommandRequest{Version: ProtocolVersion, RequestID: 83,
			Command: "read_editor_folds", DocumentID: state.Documents[0].ID, EditorRevision: beforeRevision}))
		response = decodeResponse(t, runtime.Pump())
		plan = response.EditorFolds
	}
	if !response.OK || plan == nil || !plan.Ready || !plan.Supported || plan.DocumentID != state.Documents[0].ID ||
		plan.Revision != beforeRevision || plan.InstanceID != doc.InstanceID() || len(plan.Folds) == 0 {
		t.Fatalf("fold query: response=%+v plan=%+v", response, plan)
	}
	firstBody := strings.Index(source, "opening")
	if plan.Folds[0].BodyStartByte != firstBody || plan.Folds[0].BodyStartLine != 1 {
		t.Fatalf("fold query lost visible-heading/body boundary: %+v", plan.Folds[0])
	}
	if string(doc.Editor.Buffer.Text()) != beforeText || doc.Revision() != beforeRevision ||
		runtime.applicationRevision != beforeApplicationRevision || doc.CanUndo() {
		t.Fatal("reading fold metadata changed source or undo history")
	}
	dispatchForTest(t, runtime, mustJSON(t, CommandRequest{Version: ProtocolVersion, RequestID: 82,
		Command: "read_editor_folds", DocumentID: state.Documents[0].ID, EditorRevision: beforeRevision + 1}))
	stale := decodeResponse(t, runtime.Pump())
	if stale.OK || stale.Outcome.Code != "stale_editor_revision" || stale.EditorFolds != nil {
		t.Fatalf("stale fold query was not rejected: %+v", stale)
	}
}
