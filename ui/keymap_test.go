package ui

import (
	"testing"

	"scratchpad/application"
	"scratchpad/commands"
	"scratchpad/document"
	"scratchpad/editor"

	. "go.hasen.dev/shirei"
)

func TestWindowsEditorKeyBindings(t *testing.T) {
	host := GetHost()
	oldPrimary := host.PrimaryMod
	host.PrimaryMod = ModCtrl
	defer func() { host.PrimaryMod = oldPrimary }()

	state := application.New(nil)
	doc := document.New("note.txt", []byte("one\ntwo"), "text")
	state.Documents["note"] = doc
	state.Order = []application.DocumentID{"note"}
	state.Active = "note"

	tests := []struct {
		key  KeyCode
		mods Modifiers
		want commands.ID
	}{
		{KeyCode(']'), ModCtrl, commands.EditIndentLines},
		{KeyCode('['), ModCtrl, commands.EditOutdentLines},
		{KeyK, ModCtrl | ModShift, commands.EditDeleteLine},
		{KeyEnter, ModCtrl, commands.EditInsertLineBelow},
		{KeyEnter, ModCtrl | ModShift, commands.EditInsertLineAbove},
		{KeyH, ModCtrl, commands.DocumentFindReplace},
		{KeyUp, ModAlt, commands.EditMoveLineUp},
		{KeyDown, ModAlt, commands.EditMoveLineDown},
	}
	for _, test := range tests {
		if got, ok := commandKeyBinding(state, test.key, "", test.mods, ModCtrl); !ok || got != test.want {
			t.Errorf("key %v mods %v = %q, %v; want %q, true", test.key, test.mods, got, ok, test.want)
		}
	}
}

func TestEditorViewDispatchesWindowsDocumentAndPageKeys(t *testing.T) {
	host := GetHost()
	oldPrimary := host.PrimaryMod
	host.PrimaryMod = ModCtrl
	defer func() { host.PrimaryMod = oldPrimary }()
	ResetInputSession()
	GetHost().HeadlessRender = true
	GetHost().WindowFocused = true
	GetHost().WindowSize = Vec2{500, 120}

	e := editor.NewScratchEditor([]byte("zero\none\ntwo\nthree\nfour"))
	e.SetCursor(9)
	rows := editor.IdentityRowMap(e.Buffer.LineCount())
	cache := &visualLineCache{}
	scope := new(int)
	run := func(key KeyCode, mods Modifiers) {
		GetInputState().Modifiers = mods
		GetFrameInput().Key = key
		GetFrameInput().Text = ""
		RunFrameFn(func() {
			ContainerWithKey(scope, Attrs(Viewport, FixSize(500, 120)), func() {
				processEditorInput(e, DefaultTextStyle(), 20, 0, rows, 0, false, nil, cache, nil, nil, nil, 0, nil, 0)
			})
		})
		GetInputState().Modifiers = 0
		GetFrameInput().Key = KeyCodeNone
	}

	run(KeyHome, ModCtrl)
	if e.Cursor != 0 || e.Anchor != 0 {
		t.Fatalf("Ctrl+Home selection = %d:%d, want 0:0", e.Anchor, e.Cursor)
	}
	run(KeyEnd, ModCtrl|ModShift)
	if e.Cursor != e.Buffer.ByteLen() || e.Anchor != 0 {
		t.Fatalf("Ctrl+Shift+End selection = %d:%d, want 0:%d", e.Anchor, e.Cursor, e.Buffer.ByteLen())
	}
	e.SetCursor(9)
	run(KeyPageDown, 0)
	if line, _ := e.Buffer.LineAt(e.Cursor); line != 4 {
		t.Fatalf("PageDown landed on line %d, want 4", line)
	}
	e.SetCursor(9)
	run(KeyPageUp, ModShift)
	if e.Anchor != 9 || e.Cursor != 0 {
		t.Fatalf("Shift+PageUp selection = %d:%d, want 9:0", e.Anchor, e.Cursor)
	}
}

func TestViewKeymapStateTogglesWithoutChangingOverflowPolicy(t *testing.T) {
	shell := &workbenchState{}
	doc := document.New("note.md", nil, "markdown")
	if !wrapEnabled(shell, doc) {
		t.Fatal("Markdown should start wrapped")
	}
	toggleWrap(shell, doc)
	if wrapEnabled(shell, doc) {
		t.Fatal("Word Wrap toggle did not disable wrapping")
	}
	if !lineNumbersEnabled(shell) {
		t.Fatal("line numbers should start enabled")
	}
	toggleLineNumbers(shell)
	if lineNumbersEnabled(shell) {
		t.Fatal("Line Numbers toggle did not disable line numbers")
	}
}

func TestFindReplaceEditsCurrentAndAllMatches(t *testing.T) {
	state := application.New(nil)
	doc := document.New("note.txt", []byte("one two one"), "text")
	state.Documents["note"] = doc
	state.Order = []application.DocumentID{"note"}
	state.Active = "note"
	shell := &workbenchState{ShowFind: true, ShowReplace: true, FindQuery: "one", ReplaceQuery: "1"}

	if !replaceCurrentMatch(state, shell) {
		t.Fatal("replaceCurrentMatch returned false")
	}
	if got := string(doc.Editor.Buffer.Text()); got != "1 two one" || doc.Editor.Cursor != 1 {
		t.Fatalf("current replacement = %q at %d", got, doc.Editor.Cursor)
	}

	doc.Editor.SetCursor(0)
	shell.findMatchesValid = false
	if !replaceAllMatches(state, shell) {
		t.Fatal("replaceAllMatches returned false")
	}
	if got := string(doc.Editor.Buffer.Text()); got != "1 two 1" {
		t.Fatalf("replace-all result = %q", got)
	}
	if err := doc.Editor.Undo(); err != nil {
		t.Fatal(err)
	}
	if got := string(doc.Editor.Buffer.Text()); got != "1 two one" {
		t.Fatalf("replace-all undo = %q", got)
	}
}
