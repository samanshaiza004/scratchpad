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
	quickOpen := byID[string(commands.QuickOpen)]
	if quickOpen.Title != "Quick Open…" || len(quickOpen.Bindings) != 1 || quickOpen.Bindings[0] != "primary+p" {
		t.Fatalf("Quick Open should be published with its canonical shortcut: %+v", quickOpen)
	}
	if !quickOpen.Enabled || !quickOpen.Visible {
		t.Fatalf("Quick Open should fall back to the native picker without a workspace: %+v", quickOpen)
	}
	if got := byID[string(commands.FileSave)]; got.Enabled {
		t.Fatalf("Save should be disabled without an active document: %+v", got)
	}
	if got := byID[string(commands.WorkspaceRefresh)]; got.Enabled || got.Visible {
		t.Fatalf("Refresh should be hidden/disabled without a workspace: %+v", got)
	}
	for _, id := range []commands.ID{commands.WorkspaceNewFile, commands.WorkspaceNewFolder, commands.WorkspaceRename, commands.WorkspaceMove} {
		if got := byID[string(id)]; got.Enabled || got.Visible {
			t.Fatalf("%s should be hidden/disabled without a workspace: %+v", id, got)
		}
	}
	if got := byID[string(commands.WorkspaceTrash)]; got.Enabled || got.Visible {
		t.Fatalf("Move to Trash should be hidden/disabled without a workspace: %+v", got)
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
	quickOpen = byID[string(commands.QuickOpen)]
	if !quickOpen.Visible || !quickOpen.Enabled {
		t.Fatalf("Quick Open should be enabled with a workspace: %+v", quickOpen)
	}
	for _, id := range []commands.ID{commands.WorkspaceNewFile, commands.WorkspaceNewFolder, commands.WorkspaceRename, commands.WorkspaceMove} {
		if got := byID[string(id)]; !got.Visible || !got.Enabled {
			t.Fatalf("%s should be enabled with a workspace: %+v", id, got)
		}
	}
	if got := byID[string(commands.WorkspaceTrash)]; !got.Visible || got.Enabled {
		t.Fatalf("Move to Trash should be visible but disabled without a trasher: %+v", got)
	}
	withTrasher := stateFromApplication(3, application.PresentationState{HasWorkspace: true, HasTrasher: true})
	for _, action := range withTrasher.Actions {
		if action.ID == string(commands.WorkspaceTrash) && (!action.Visible || !action.Enabled) {
			t.Fatalf("Move to Trash should be enabled when the OS trasher exists: %+v", action)
		}
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

func TestPublishedAlicornEditorActionVocabulary(t *testing.T) {
	state := stateFromApplication(1, application.PresentationState{
		HasWorkspace: true,
		Active:       "doc-1",
		Documents:    []application.PresentationDocument{{ID: "doc-1", Language: "markdown"}},
	})
	byID := make(map[string]ActionState, len(state.Actions))
	for _, action := range state.Actions {
		byID[action.ID] = action
	}
	want := []commands.ID{
		commands.EditIndentLines, commands.EditOutdentLines, commands.EditDeleteLine,
		commands.EditInsertLineAbove, commands.EditInsertLineBelow, commands.EditMoveLineUp,
		commands.EditMoveLineDown, commands.EditDuplicateLine, commands.EditJoinLines,
		commands.CommentToggle, commands.ItemToggle, commands.MarkdownToggleStrong, commands.MarkdownToggleEmphasis,
		commands.MarkdownToggleStrike, commands.MarkdownToggleInlineCode, commands.MarkdownInsertLink,
		commands.MarkdownHeading1, commands.MarkdownHeading2, commands.MarkdownHeading3,
		commands.MarkdownToggleBulletedList, commands.MarkdownToggleNumberedList,
		commands.MarkdownToggleQuote, commands.MarkdownInsertTask, commands.MarkdownInsertCodeBlock,
		commands.MarkdownSetFenceLanguage, commands.MarkdownInsertTable, commands.MarkdownTableNext,
		commands.MarkdownTablePrevious, commands.MarkdownTableEnter, commands.MarkdownInsertDivider, commands.MarkdownSmartPaste,
	}
	for _, id := range want {
		if action, ok := byID[string(id)]; !ok || action.Title == "" {
			t.Errorf("Alicorn action %q is not published with a title: %+v", id, action)
		}
	}
	for _, id := range []commands.ID{
		commands.EditIndentLines, commands.EditOutdentLines, commands.EditDeleteLine,
		commands.EditInsertLineAbove, commands.EditInsertLineBelow, commands.EditMoveLineUp,
		commands.EditMoveLineDown, commands.EditDuplicateLine, commands.EditJoinLines,
		commands.MarkdownToggleStrong, commands.MarkdownToggleEmphasis, commands.MarkdownToggleStrike,
		commands.MarkdownToggleInlineCode, commands.MarkdownInsertLink, commands.MarkdownHeading1,
		commands.MarkdownHeading2, commands.MarkdownHeading3, commands.MarkdownToggleBulletedList,
		commands.MarkdownToggleNumberedList, commands.MarkdownToggleQuote, commands.MarkdownInsertTask, commands.ItemToggle,
		commands.MarkdownInsertCodeBlock, commands.MarkdownInsertTable, commands.MarkdownInsertDivider, commands.MarkdownSmartPaste,
	} {
		if action := byID[string(id)]; !action.Visible || !action.Enabled {
			t.Errorf("active Markdown action %q should be visible and enabled: %+v", id, action)
		}
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
