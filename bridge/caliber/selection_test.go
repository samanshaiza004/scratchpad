package backend

import (
	"os"
	"path/filepath"
	"testing"

	"scratchpad/application"
	"scratchpad/commands"
)

func TestSemanticSelectionRoundTripChangesOnlyDirectionalSelection(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "note.txt")
	if err := os.WriteFile(path, []byte("alpha beta.\n\nnext"), 0o644); err != nil {
		t.Fatal(err)
	}
	runtime := newStartedRuntime(t, root)
	defer stopRuntime(t, runtime)
	dispatchForTest(t, runtime, mustJSON(t, CommandRequest{Version: ProtocolVersion, RequestID: 1, Command: "open_path", Path: path}))
	if response := decodeResponse(t, runtime.Pump()); !response.OK {
		t.Fatalf("open: %+v", response)
	}
	state := latestStateForTest(t, runtime)
	doc := state.Documents[0]
	dispatchForTest(t, runtime, mustJSON(t, CommandRequest{Version: ProtocolVersion, RequestID: 2, Command: "execute_command", ActionID: string(commands.SelectionExpand),
		DocumentID: doc.ID, EditorRevision: doc.EditorRevision, EditorAnchorByte: 10, EditorCursorByte: 6}))
	response := decodeResponse(t, runtime.Pump())
	if !response.OK || response.CommandOutcome != CommandOutcomeSelectionOnly || response.EditorSelection == nil ||
		response.EditorSelection.AnchorByte != 11 || response.EditorSelection.CursorByte != 0 || response.SourceRefreshNeeded {
		t.Fatalf("expand: %+v", response)
	}
	authority := runtime.app.Documents[application.DocumentID(doc.ID)]
	if authority.Dirty() || authority.Revision() != doc.EditorRevision || string(authority.Editor.Buffer.Text()) != "alpha beta.\n\nnext" {
		t.Fatal("selection command mutated source")
	}
	if err := authority.Insert([]byte("changed")); err != nil {
		t.Fatal(err)
	}
	dispatchForTest(t, runtime, mustJSON(t, CommandRequest{Version: ProtocolVersion, RequestID: 3, Command: "execute_command", ActionID: string(commands.SelectionExpand),
		DocumentID: doc.ID, EditorRevision: doc.EditorRevision, EditorAnchorByte: 0, EditorCursorByte: 0}))
	if stale := decodeResponse(t, runtime.Pump()); stale.OK || stale.Outcome.Code != "stale_editor_revision" {
		t.Fatalf("stale expand: %+v", stale)
	}
}
