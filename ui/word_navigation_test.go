package ui

import (
	"strings"
	"testing"

	"scratchpad/editor"

	. "go.hasen.dev/shirei"
)

func TestEditableViewDispatchesWindowsWordNavigation(t *testing.T) {
	if shaped := ShapeText("probe", DefaultTextStyle()); len(shaped.Lines) == 0 {
		t.Skip("Shirei has no usable font in this headless unit-test context")
	}
	ResetInputSession()
	host := GetHost()
	host.HeadlessRender = true
	host.WindowFocused = true
	host.WindowSize = Vec2{500, 160}
	oldPrimary := host.PrimaryMod
	host.PrimaryMod = ModCtrl
	defer func() { host.PrimaryMod = oldPrimary }()

	e := editor.NewScratchEditor([]byte("hello world"))
	scope := new(int)
	runKey := func(key KeyCode, mods Modifiers) {
		GetInputState().Modifiers = mods
		GetFrameInput().Key = key
		GetFrameInput().Text = ""
		GetFrameInput().Mouse = 0
		RunFrameFn(func() {
			ContainerWithKey(scope, Attrs(Viewport), func() {
				EditableView(scope, e, EditorViewOptions{Style: DefaultTextStyle(), RowHeight: 20})
			})
		})
		GetInputState().Modifiers = 0
		GetFrameInput().Key = KeyCodeNone
	}
	for range 2 {
		runKey(KeyCodeNone, 0)
	}

	e.SetCursor(0)
	runKey(KeyRight, ModCtrl)
	if e.Cursor != 5 || e.Anchor != 5 {
		t.Fatalf("ctrl-right = %d:%d, want 5:5", e.Anchor, e.Cursor)
	}
	runKey(KeyRight, ModCtrl|ModShift)
	if e.Cursor != 11 || e.Anchor != 5 {
		t.Fatalf("ctrl-shift-right = %d:%d, want 5:11", e.Anchor, e.Cursor)
	}

	e.SetCursor(11)
	runKey(KeyLeft, ModCtrl)
	if e.Cursor != 6 || e.Anchor != 6 {
		t.Fatalf("ctrl-left = %d:%d, want 6:6", e.Anchor, e.Cursor)
	}
	runKey(KeyLeft, ModCtrl|ModShift)
	if e.Cursor != 0 || e.Anchor != 6 {
		t.Fatalf("ctrl-shift-left = %d:%d, want 6:0", e.Anchor, e.Cursor)
	}
}

func TestEditableViewKeepsCtrlAltChunkNavigation(t *testing.T) {
	if shaped := ShapeText("probe", DefaultTextStyle()); len(shaped.Lines) == 0 {
		t.Skip("Shirei has no usable font in this headless unit-test context")
	}
	ResetInputSession()
	host := GetHost()
	host.HeadlessRender = true
	host.WindowFocused = true
	host.WindowSize = Vec2{500, 160}
	oldPrimary := host.PrimaryMod
	host.PrimaryMod = ModCtrl
	defer func() { host.PrimaryMod = oldPrimary }()

	e := editor.NewScratchEditor([]byte(strings.Repeat("x", longLineChunkBytes*2+1)))
	scope := new(int)
	runKey := func(key KeyCode, mods Modifiers) {
		GetInputState().Modifiers = mods
		GetFrameInput().Key = key
		GetFrameInput().Text = ""
		GetFrameInput().Mouse = 0
		RunFrameFn(func() {
			ContainerWithKey(scope, Attrs(Viewport), func() {
				EditableView(scope, e, EditorViewOptions{Style: DefaultTextStyle(), RowHeight: 20})
			})
		})
		GetInputState().Modifiers = 0
		GetFrameInput().Key = KeyCodeNone
	}
	for range 2 {
		runKey(KeyCodeNone, 0)
	}

	e.SetCursor(0)
	runKey(KeyRight, ModCtrl|ModAlt)
	if e.Cursor != longLineChunkBytes || e.Anchor != longLineChunkBytes {
		t.Fatalf("ctrl-alt-right chunk = %d:%d, want %d:%d", e.Anchor, e.Cursor, longLineChunkBytes, longLineChunkBytes)
	}
}
