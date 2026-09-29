package backend

import (
	"hash/fnv"
	"testing"

	"scratchpad/application"
	"scratchpad/commands"
)

func TestPublishedShellActionsUseCanonicalScratchpadIDsAndContext(t *testing.T) {
	state := stateFromApplication(1, application.PresentationState{})
	if len(state.Actions) != len(shellActionIDs) {
		t.Fatalf("action count = %d, want %d", len(state.Actions), len(shellActionIDs))
	}
	byID := make(map[string]ActionState, len(state.Actions))
	for _, action := range state.Actions {
		byID[action.ID] = action
		if action.ID == "" || action.Title == "" {
			t.Fatalf("action lacks stable ID/title: %+v", action)
		}
	}
	open := byID[string(commands.FileOpen)]
	if !open.Visible || !open.Enabled {
		t.Fatalf("Open File should be available without an active document: %+v", open)
	}
	if got := byID[string(commands.FileSave)]; got.Enabled {
		t.Fatalf("Save should be disabled without an active document: %+v", got)
	}
	if got := byID[string(commands.WorkspaceRefresh)]; got.Enabled || got.Visible {
		t.Fatalf("Refresh should be hidden/disabled without a workspace: %+v", got)
	}
	if got := byID[string(commands.WorkspaceOpen)]; !got.Visible || !got.Enabled {
		t.Fatalf("Open Folder should be available without a workspace: %+v", got)
	}
	if got := byID[string(commands.EditUndo)]; !got.Visible || got.Enabled {
		t.Fatalf("Undo should be visible but disabled without an active document/history: %+v", got)
	}
	if got := byID[string(commands.EditRedo)]; !got.Visible || got.Enabled {
		t.Fatalf("Redo should be visible but disabled without an active document/history: %+v", got)
	}

	withWorkspace := stateFromApplication(2, application.PresentationState{
		HasWorkspace: true,
		Active:       "doc-1",
		Documents:    []application.PresentationDocument{{ID: "doc-1", ByteLength: 18, CanUndo: true}, {ID: "doc-2"}},
	})
	byID = make(map[string]ActionState, len(withWorkspace.Actions))
	for _, action := range withWorkspace.Actions {
		byID[action.ID] = action
	}
	if got := byID[string(commands.WorkspaceRefresh)]; !got.Visible || !got.Enabled {
		t.Fatalf("Refresh should be enabled with a workspace: %+v", got)
	}
	if got := byID[string(commands.TabNext)]; !got.Visible || !got.Enabled || len(got.Bindings) != 1 {
		t.Fatalf("tab navigation should be enabled with multiple documents: %+v", got)
	}
	if got := byID[string(commands.EditUndo)]; !got.Visible || !got.Enabled || len(got.Bindings) != 1 || got.Bindings[0] != "primary+z" {
		t.Fatalf("Undo action should follow active document history: %+v", got)
	}
	if got := byID[string(commands.EditRedo)]; !got.Visible || got.Enabled || len(got.Bindings) != 1 || got.Bindings[0] != "primary+shift+z" {
		t.Fatalf("Redo action should follow active document history: %+v", got)
	}
	if got := withWorkspace.Documents[0]; got.ByteLength != 18 || !got.CanUndo || got.CanRedo {
		t.Fatalf("document metadata lost editor state: %+v", got)
	}
}

func TestShellActionIDsMapToUniqueNonzeroAlicornTokens(t *testing.T) {
	seen := make(map[uint32]string, len(shellActionIDs))
	for _, id := range shellActionIDs {
		hash := fnv.New32a()
		_, _ = hash.Write([]byte(id))
		token := hash.Sum32()
		if token == 0 {
			t.Fatalf("action %q maps to Alicorn's reserved zero token", id)
		}
		if previous, exists := seen[token]; exists {
			t.Fatalf("action token collision: %q and %q both map to %d", previous, id, token)
		}
		seen[token] = string(id)
	}
}
