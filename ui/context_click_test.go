package ui

import (
	"os"
	"path/filepath"
	"testing"

	"scratchpad/application"

	. "go.hasen.dev/shirei"
	. "go.hasen.dev/shirei/widgets"
)

func TestContextClickTreeAndTabs(t *testing.T) {
	gestures := []struct {
		name    string
		primary Modifiers
		button  MouseButton
		mods    Modifiers
		context bool
	}{
		{"mac-control", ModCmd, MousePrimary, ModCtrl, true},
		{"mac-secondary", ModCmd, MouseSecondary, 0, true},
		{"windows-secondary", ModCtrl, MouseSecondary, 0, true},
		{"windows-control", ModCtrl, MousePrimary, ModCtrl, false},
		{"mac-command", ModCmd, MousePrimary, ModCmd, false},
		{"mac-primary", ModCmd, MousePrimary, 0, false},
	}
	for _, gesture := range gestures {
		for _, target := range []string{"file", "folder", "tab", "close-tab"} {
			t.Run(gesture.name+"/"+target, func(t *testing.T) {
				ResetInputSession()
				host := GetHost()
				oldPrimary := host.PrimaryMod
				host.PrimaryMod = gesture.primary
				host.HeadlessRender = true
				host.WindowFocused = true
				host.WindowSize = Vec2{800, 500}
				t.Cleanup(func() { host.PrimaryMod = oldPrimary; ResetInputSession() })
				root := t.TempDir()
				for _, file := range []string{"a.txt", "b.txt"} {
					if err := os.WriteFile(filepath.Join(root, file), []byte(file), 0o644); err != nil {
						t.Fatal(err)
					}
				}
				if err := os.Mkdir(filepath.Join(root, "folder"), 0o755); err != nil {
					t.Fatal(err)
				}
				state := application.New(nil)
				if err := state.OpenWorkspace(root); err != nil {
					t.Fatal(err)
				}
				if err := state.OpenPath(filepath.Join(root, "a.txt")); err != nil {
					t.Fatal(err)
				}
				firstID := state.Active
				isTab := target == "tab" || target == "close-tab"
				var targetID application.DocumentID
				if isTab {
					if err := state.OpenPath(filepath.Join(root, "b.txt")); err != nil {
						t.Fatal(err)
					}
					targetID = state.Active
					state.Active = firstID
					if target == "close-tab" && !gesture.context {
						// Exercise normal close on the active tab; context clicks
						// above target an inactive tab without activating it.
						state.Active = targetID
					}
				}
				shell := &workbenchState{Tree: treeState{Expanded: make(map[string]bool)}}
				scope := new(int)
				showMenu := true
				view := func() {
					ContainerWithKey(scope, Attrs(Viewport), func() {
						if isTab {
							tabs(state, shell, DefaultTheme())
						} else {
							renderTreeWithShell(state, &shell.Tree, shell, "", 0, DefaultTheme())
						}
						if showMenu {
							contextMenu(state, shell, DefaultTheme())
						}
					})
				}
				run := func(action MouseAction, mods Modifiers, point Vec2) {
					GetInputState().Modifiers = mods
					GetInputState().MouseButton = gesture.button
					GetInputState().MousePoint = point
					GetFrameInput().Mouse = action
					GetFrameInput().Key = KeyCodeNone
					GetFrameInput().Text = ""
					RunFrameFn(view)
				}
				run(0, 0, Vec2{-1000, -1000})
				var rect Rect
				path := filepath.Join(root, "b.txt")
				switch target {
				case "file":
					rect = GetResolvedRectOf(shell.Tree.RowIDs["b.txt"])
				case "folder":
					rect = GetResolvedRectOf(shell.Tree.RowIDs["folder"])
					path = filepath.Join(root, "folder")
				case "tab":
					rect = GetResolvedRectOf(shell.TabIDs[targetID])
				case "close-tab":
					rect = GetResolvedRectOf(shell.TabCloseIDs[targetID])
				}
				point := Vec2{rect.Origin[0] + 10, rect.Origin[1] + rect.Size[1]/2}
				run(0, gesture.mods, point)
				run(MouseClick, gesture.mods, point)
				if shell.ContextMenu.Open != gesture.context {
					t.Fatalf("context menu open=%v, want %v", shell.ContextMenu.Open, gesture.context)
				}
				if gesture.context && shell.ContextMenu.Path != path {
					t.Fatalf("menu path=%q, want %q", shell.ContextMenu.Path, path)
				}
				// Remove the popup to exercise the original target's release path,
				// including users who release Control before the mouse button.
				showMenu = false
				shell.ContextMenu.Open = false
				if gesture.context {
					run(0, 0, Vec2{point[0] + 30, point[1]})
					if _, dragging := GetDraggingItem[treeDragPayload](); dragging {
						t.Fatal("context gesture started a file drag")
					}
				}
				run(MouseRelease, 0, point)
				if gesture.context {
					if state.Active != firstID || shell.Tree.Expanded["folder"] {
						t.Fatal("context gesture activated a document or toggled the folder")
					}
					if isTab && len(state.Documents) != 2 {
						t.Fatal("context gesture closed a tab")
					}
					if !isTab && len(state.Documents) != 1 {
						t.Fatal("context gesture opened a file")
					}
				} else {
					switch target {
					case "folder":
						if !shell.Tree.Expanded["folder"] {
							t.Fatal("primary click did not expand folder")
						}
					case "close-tab":
						if len(state.Documents) != 1 {
							t.Fatal("primary click did not close tab")
						}
					default:
						if state.Active == firstID {
							t.Fatal("primary click did not activate file/tab")
						}
					}
				}
			})
		}
	}
}
