package ui

import (
	"os"
	"path/filepath"
	"testing"

	"scratchpad/application"
	"scratchpad/commands"

	. "go.hasen.dev/shirei"
)

func TestWorkbenchCommandsCopyPaths(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "notes", "today.md")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("hello"), 0o644); err != nil {
		t.Fatal(err)
	}
	state := application.New(nil)
	if err := state.OpenWorkspace(root); err != nil {
		t.Fatal(err)
	}
	if err := state.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	shell := &workbenchState{}
	ResetInputSession()
	GetHost().HeadlessRender = true
	RunFrameFn(func() {
		executeCommand(state, shell, commands.FileCopyPath)
	})
	if got := LastFrameOutput().Copy; got != path {
		t.Fatalf("copy path = %q, want %q", got, path)
	}
	RunFrameFn(func() {
		executeCommand(state, shell, commands.FileCopyRelativePath)
	})
	if got := LastFrameOutput().Copy; got != filepath.Join("notes", "today.md") {
		t.Fatalf("copy relative path = %q", got)
	}
}

func TestFileOpenWithoutArgumentsOpensPicker(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "README.md")
	if err := os.WriteFile(path, []byte("hello"), 0o644); err != nil {
		t.Fatal(err)
	}
	state := application.New(nil)
	if err := state.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	active := state.Active
	shell := &workbenchState{}
	executeCommand(state, shell, commands.FileOpen)
	if !shell.ShowOpen {
		t.Fatal("argumentless FileOpen did not open the picker")
	}
	if state.Active != active {
		t.Fatalf("argumentless FileOpen changed active document from %q to %q", active, state.Active)
	}
}

func TestCtrlOInvokesFileOpenCommand(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "README.md")
	if err := os.WriteFile(path, []byte("hello"), 0o644); err != nil {
		t.Fatal(err)
	}
	state := application.New(nil)
	if err := state.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	active := state.Active
	shell := &workbenchState{}
	ResetInputSession()
	GetFrameInput().Key = KeyO
	GetInputState().Modifiers = PrimaryMod()
	handleGlobalInput(state, shell)
	if !shell.ShowOpen {
		t.Fatal("Ctrl+O did not open the picker")
	}
	if state.Active != active {
		t.Fatalf("Ctrl+O changed active document from %q to %q", active, state.Active)
	}
}

func TestFolderClickUsesPersistentWorkbenchTreeState(t *testing.T) {
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, "src"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "src", "main.go"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	state := application.New(nil)
	if err := state.OpenWorkspace(root); err != nil {
		t.Fatal(err)
	}
	shell := &workbenchState{}
	executeCommand(state, shell, commands.WorkspaceToggleFolder, "src")
	if !shell.Tree.Expanded["src"] {
		t.Fatal("folder command did not persist expansion in workbench state")
	}
}

func TestOpenPickerCanTypeOnFirstAndSecondOpening(t *testing.T) {
	root := t.TempDir()
	for _, name := range []string{"child.md", "other.md"} {
		if err := os.WriteFile(filepath.Join(root, name), nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	state := application.New(nil)
	if err := state.OpenWorkspace(root); err != nil {
		t.Fatal(err)
	}
	shell := &workbenchState{}
	scope := new(int)
	GetHost().HeadlessRender = true
	GetHost().WindowFocused = true
	GetHost().WindowSize = Vec2{800, 600}
	GetInputState().MousePoint = Vec2{-1000, -1000}
	GetInputState().MouseButton = MousePrimary
	GetFrameInput().Mouse = 0
	GetFrameInput().Key = KeyCodeNone
	GetFrameInput().Text = ""
	var editorID ContainerId
	ResetInputSession()
	RunFrameFn(func() {
		ContainerWithKey(scope, Attrs(Viewport), func() {
			editorID = Container(Attrs(Focusable), func() {})
		})
	})
	FocusImmediateOn(editorID)
	if !IdHasFocus(editorID) {
		t.Fatal("test editor did not receive focus")
	}
	run := func(text string) {
		GetFrameInput().Mouse = 0
		GetFrameInput().Key = KeyCodeNone
		GetFrameInput().Text = text
		RunFrameFn(func() {
			ContainerWithKey(scope, Attrs(Viewport), func() { openControls(state, shell, DefaultTheme()) })
		})
	}
	openPathPicker(state, shell)
	if IdHasFocus(editorID) {
		t.Fatal("opening picker did not clear editor focus")
	}
	run("")
	run("")
	run("")
	run("child")
	if shell.PathPicker.Filter != "child" {
		t.Fatalf("first picker filter = %q, want child", shell.PathPicker.Filter)
	}
	shell.ShowOpen = false
	run("")
	openPathPicker(state, shell)
	run("")
	run("")
	run("")
	run("other")
	if shell.PathPicker.Filter != "other" {
		t.Fatalf("second picker filter = %q, want other", shell.PathPicker.Filter)
	}
}

func TestWorkbenchCommandsGoToLineAndFindNavigation(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "note.txt")
	if err := os.WriteFile(path, []byte("one needle\ntwo needle\nthree needle"), 0o644); err != nil {
		t.Fatal(err)
	}
	state := application.New(nil)
	if err := state.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	shell := &workbenchState{FindQuery: "needle"}
	ResetInputSession()
	GetHost().HeadlessRender = true
	RunFrameFn(func() {
		executeCommand(state, shell, commands.DocumentGoToLine, "2:5")
	})
	if got := state.ActiveDocument().Editor.Cursor; got != len("one needle\n")+4 {
		t.Fatalf("go to line cursor = %d", got)
	}
	state.ActiveDocument().Editor.SetCursor(0)
	RunFrameFn(func() { executeCommand(state, shell, commands.DocumentFindNext) })
	if anchor, cursor := state.ActiveDocument().Editor.Selection(); anchor != 4 || cursor != 10 {
		t.Fatalf("first find selection = %d:%d", anchor, cursor)
	}
	RunFrameFn(func() { executeCommand(state, shell, commands.DocumentFindNext) })
	if anchor, cursor := state.ActiveDocument().Editor.Selection(); anchor != 15 || cursor != 21 {
		t.Fatalf("second find selection = %d:%d", anchor, cursor)
	}
	RunFrameFn(func() { executeCommand(state, shell, commands.DocumentFindPrevious) })
	if anchor, cursor := state.ActiveDocument().Editor.Selection(); anchor != 4 || cursor != 10 {
		t.Fatalf("previous find selection = %d:%d", anchor, cursor)
	}
}

func TestContextMenuPositionsAtPointerAndDismissesOutside(t *testing.T) {
	state := application.New(nil)
	shell := &workbenchState{ContextMenu: contextMenuState{
		Open: true, Generation: 1, Path: filepath.Join(t.TempDir(), "note.txt"), Position: Vec2{120, 76},
	}}
	scope := new(int)
	ResetInputSession()
	GetHost().HeadlessRender = true
	GetHost().WindowFocused = true
	GetHost().WindowSize = Vec2{500, 300}
	GetInputState().MousePoint = Vec2{-1000, -1000}
	RunFrameFn(func() {
		ContainerWithKey(scope, Attrs(Viewport), func() { contextMenu(state, shell, DefaultTheme()) })
	})
	rect := GetResolvedRectOf(shell.ContextMenu.MenuID)
	if rect.Origin != shell.ContextMenu.Position {
		t.Fatalf("context menu origin = %v, want %v", rect.Origin, shell.ContextMenu.Position)
	}
	GetInputState().MousePoint = Vec2{10, 10}
	GetInputState().MouseButton = MousePrimary
	GetFrameInput().Mouse = MouseClick
	RunFrameFn(func() {
		ContainerWithKey(scope, Attrs(Viewport), func() { contextMenu(state, shell, DefaultTheme()) })
	})
	if shell.ContextMenu.Open {
		t.Fatal("outside click did not dismiss context menu")
	}
}
