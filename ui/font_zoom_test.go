package ui

import (
	"testing"

	"scratchpad/application"
	"scratchpad/commands"
	"scratchpad/document"
	"scratchpad/editor"

	. "go.hasen.dev/shirei"
)

func TestEditorFontZoomDefaultsAndBounds(t *testing.T) {
	if got := editorFontSize(nil); got != defaultEditorFontSize {
		t.Fatalf("nil shell font size = %v, want %v", got, defaultEditorFontSize)
	}
	if got := adjustEditorFontSize(0, 1); got != defaultEditorFontSize+editorFontSizeStep {
		t.Fatalf("zoom from unset size = %v, want %v", got, defaultEditorFontSize+editorFontSizeStep)
	}
	if got := adjustEditorFontSize(minEditorFontSize, -1); got != minEditorFontSize {
		t.Fatalf("minimum zoom escaped lower bound: %v", got)
	}
	if got := adjustEditorFontSize(maxEditorFontSize, 1); got != maxEditorFontSize {
		t.Fatalf("maximum zoom escaped upper bound: %v", got)
	}
	if got := clampEditorFontSize(-5); got != minEditorFontSize {
		t.Fatalf("negative size normalized to %v, want minimum %v", got, minEditorFontSize)
	}
}

func TestEditorFontZoomCommandsAndMetrics(t *testing.T) {
	primary := ModCtrl
	tests := []struct {
		name string
		key  KeyCode
		mods Modifiers
		want commands.ID
	}{
		{"windows decrease", KeyCode('-'), primary, commands.ViewDecreaseFontSize},
		{"windows plus", KeyCode('='), primary | ModShift, commands.ViewIncreaseFontSize},
		{"mac plus", KeyCode('+'), ModCmd, commands.ViewIncreaseFontSize},
		{"reset", Key0, primary, commands.ViewResetFontSize},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := editorZoomCommand(test.key, test.mods, func() Modifiers {
				if test.name == "mac plus" {
					return ModCmd
				}
				return primary
			}()); got != test.want {
				t.Fatalf("editorZoomCommand() = %q, want %q", got, test.want)
			}
		})
	}
	if got := editorRowHeight(defaultEditorFontSize); got != 24 {
		t.Fatalf("default row height = %v, want 24", got)
	}
	if got := editorRowHeight(32); got != 48 {
		t.Fatalf("scaled row height = %v, want 48", got)
	}
}

func TestEditorFontZoomCommandsUpdateState(t *testing.T) {
	shell := &workbenchState{}
	if !executeCommand(nil, shell, commands.ViewIncreaseFontSize) || shell.EditorFontSize != defaultEditorFontSize+editorFontSizeStep {
		t.Fatalf("increase from default = %v, want %v", shell.EditorFontSize, defaultEditorFontSize+editorFontSizeStep)
	}
	shell.EditorFontSize = maxEditorFontSize
	if !executeCommand(nil, shell, commands.ViewIncreaseFontSize) || shell.EditorFontSize != maxEditorFontSize {
		t.Fatalf("increase at maximum = %v, want %v", shell.EditorFontSize, maxEditorFontSize)
	}
	shell.EditorFontSize = minEditorFontSize
	if !executeCommand(nil, shell, commands.ViewDecreaseFontSize) || shell.EditorFontSize != minEditorFontSize {
		t.Fatalf("decrease at minimum = %v, want %v", shell.EditorFontSize, minEditorFontSize)
	}
	shell.EditorFontSize = 27
	if !executeCommand(nil, shell, commands.ViewResetFontSize) || shell.EditorFontSize != defaultEditorFontSize {
		t.Fatalf("reset = %v, want %v", shell.EditorFontSize, defaultEditorFontSize)
	}
}

func TestEditorFontZoomClearsPreferredVerticalPosition(t *testing.T) {
	state := application.New(nil)
	state.Documents["active"] = document.New("notes.md", []byte("one\ntwo"), "markdown")
	state.Order = []application.DocumentID{"active"}
	state.Active = "active"
	state.Documents["active"].Editor.SetPreferredVerticalX(42)

	if !executeCommand(state, &workbenchState{}, commands.ViewIncreaseFontSize) {
		t.Fatal("font increase command was not handled")
	}
	if _, ok := state.Documents["active"].Editor.PreferredVerticalX(); ok {
		t.Fatal("font zoom retained stale preferred vertical position")
	}
}

func TestEditorFontZoomRebuildsCachedLayout(t *testing.T) {
	buffer := editor.NewBuffer([]byte("A sentence with enough words to wrap when the editor font grows."))
	style := DefaultTextStyle()
	cache := &visualLineCache{}
	cache.prepare(0, 180, true)
	before, ok := cachedVisualLine(cache, &buffer, 0, 0, style, 180, nil, nil, nil)
	if !ok || len(before.Layout.Lines) == 0 {
		t.Fatal("initial layout unavailable")
	}
	style.FontSize *= 2
	after, ok := cachedVisualLine(cache, &buffer, 0, 0, style, 180, nil, nil, nil)
	if !ok || after.Height(24) <= before.Height(24) {
		t.Fatalf("zoom retained stale layout: before=%v after=%v", before.Height(24), after.Height(24))
	}
}
