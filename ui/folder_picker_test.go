package ui

import (
	"os"
	"path/filepath"
	"testing"

	"scratchpad/application"

	. "go.hasen.dev/shirei"
)

func TestFolderPickerNavigatesDirectoriesBeforeChoosing(t *testing.T) {
	root := t.TempDir()
	child := filepath.Join(root, "child")
	grandchild := filepath.Join(child, "grandchild")
	if err := os.MkdirAll(grandchild, 0o755); err != nil {
		t.Fatal(err)
	}

	state := application.New(nil)
	if err := state.OpenWorkspace(root); err != nil {
		t.Fatal(err)
	}
	shell := &workbenchState{ShowFolder: true, FolderPicker: folderPickerState{Cwd: root, Selected: -1}}
	scope := new(int)

	run := func(key KeyCode, mods Modifiers) {
		GetHost().HeadlessRender = true
		GetHost().WindowFocused = true
		GetHost().WindowSize = Vec2{800, 600}
		GetInputState().MousePoint = Vec2{-1000, -1000}
		GetInputState().Modifiers = mods
		GetFrameInput().Mouse = 0
		GetFrameInput().Scroll = Vec2{}
		GetFrameInput().Motion = Vec2{}
		GetFrameInput().Key = key
		GetFrameInput().Text = ""
		RunFrameFn(func() {
			ContainerWithKey(scope, Attrs(Viewport), func() {
				openControls(state, shell)
			})
		})
	}

	ResetInputSession()
	run(KeyCodeNone, 0)
	run(KeyCodeNone, 0)
	shell.FolderPicker.Filter = "child"
	run(KeyEnter, 0)
	if shell.FolderPicker.Cwd != child || !shell.ShowFolder {
		t.Fatalf("child navigation cwd=%q show=%v, want %q and picker open", shell.FolderPicker.Cwd, shell.ShowFolder, child)
	}

	shell.FolderPicker.Filter = "grandchild"
	run(KeyEnter, 0)
	if shell.FolderPicker.Cwd != grandchild || !shell.ShowFolder {
		t.Fatalf("grandchild navigation cwd=%q show=%v, want %q and picker open", shell.FolderPicker.Cwd, shell.ShowFolder, grandchild)
	}

	run(KeyEnter, PrimaryMod())
	if shell.ShowFolder {
		t.Fatal("choosing current directory left picker open")
	}
	if state.Workspace.Root != grandchild {
		t.Fatalf("workspace root=%q, want %q", state.Workspace.Root, grandchild)
	}
}

func TestFolderPickerClickNavigatesWithoutClosing(t *testing.T) {
	root := t.TempDir()
	child := filepath.Join(root, "child")
	if err := os.Mkdir(child, 0o755); err != nil {
		t.Fatal(err)
	}
	state := application.New(nil)
	if err := state.OpenWorkspace(root); err != nil {
		t.Fatal(err)
	}
	shell := &workbenchState{ShowFolder: true, FolderPicker: folderPickerState{
		Cwd: root, Filter: "child", Selected: -1,
	}}
	scope := new(int)
	var listID ContainerId
	run := func(mouse Vec2, action MouseAction) {
		GetHost().HeadlessRender = true
		GetHost().WindowFocused = true
		GetHost().WindowSize = Vec2{800, 600}
		GetInputState().MousePoint = mouse
		GetInputState().Modifiers = 0
		GetFrameInput().Mouse = action
		GetFrameInput().Scroll = Vec2{}
		GetFrameInput().Motion = Vec2{}
		GetFrameInput().Key = KeyCodeNone
		GetFrameInput().Text = ""
		RunFrameFn(func() {
			ContainerWithKey(scope, Attrs(Viewport), func() {
				Modal(560, func() { shell.ShowFolder = false }, func() {
					folderPickerPanel(shell)
					listID = GetLastId()
				})
			})
		})
	}

	ResetInputSession()
	run(Vec2{-1000, -1000}, 0)
	run(Vec2{-1000, -1000}, 0)
	list := GetResolvedRectOf(listID)
	if list.Size[1] < 28 {
		t.Fatalf("folder listing rect=%v, want a clickable row", list)
	}
	run(Vec2{list.Origin[0] + 24, list.Origin[1] + 14}, MouseClick)
	if shell.FolderPicker.Cwd != child || !shell.ShowFolder {
		t.Fatalf("click navigation cwd=%q show=%v, want %q and picker open", shell.FolderPicker.Cwd, shell.ShowFolder, child)
	}
}
