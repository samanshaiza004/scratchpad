package ui

import (
	"os"
	"path/filepath"
	"testing"

	"scratchpad/application"

	. "go.hasen.dev/shirei"
)

func TestExpandedTreeRowsStackVertically(t *testing.T) {
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
	tree := &treeState{Expanded: map[string]bool{"src": true}}
	scope := new(int)
	GetHost().HeadlessRender = true
	GetHost().WindowSize = Vec2{500, 300}
	GetInputState().MousePoint = Vec2{-1000, -1000}
	RunFrameFn(func() {
		ContainerWithKey(scope, Attrs(Viewport, FixSize(500, 300)), func() {
			renderTree(state, tree, "", 0, DefaultTheme())
		})
	})

	parent := GetResolvedRectOf(tree.RowIDs["src"])
	child := GetResolvedRectOf(tree.RowIDs[filepath.Join("src", "main.go")])
	if parent.Size[1] != 24 || child.Size[1] != 24 {
		t.Fatalf("row sizes parent=%v child=%v, want 24px rows", parent.Size, child.Size)
	}
	if child.Origin[1] <= parent.Origin[1] {
		t.Fatalf("child row y=%v did not stack below parent y=%v", child.Origin[1], parent.Origin[1])
	}
}

func TestTreeMutationDefersRowIDInvalidationDuringRender(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "new.txt"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	state := application.New(nil)
	if err := state.OpenWorkspace(root); err != nil {
		t.Fatal(err)
	}
	shell := &workbenchState{Tree: treeState{
		Expanded:    map[string]bool{"stale": true},
		RowIDs:      map[string]ContainerId{"stale": nil},
		renderDepth: 1,
	}}
	resetTreeAfterMutation(shell)
	if shell.Tree.RowIDs == nil {
		t.Fatal("row IDs were invalidated during an active tree render")
	}
	if !shell.Tree.rowsDirty {
		t.Fatal("tree row invalidation was not deferred")
	}

	GetHost().HeadlessRender = true
	GetHost().WindowSize = Vec2{500, 300}
	GetInputState().MousePoint = Vec2{-1000, -1000}
	shell.Tree.renderDepth = 0
	scope := new(int)
	RunFrameFn(func() {
		ContainerWithKey(scope, Attrs(Viewport, FixSize(500, 300)), func() {
			renderTreeWithShell(state, &shell.Tree, shell, "", 0, DefaultTheme())
		})
	})
	if shell.Tree.rowsDirty {
		t.Fatal("tree row invalidation remained pending after the next render")
	}
	if _, ok := shell.Tree.RowIDs["stale"]; ok {
		t.Fatal("stale row ID survived deferred invalidation")
	}
	if _, ok := shell.Tree.RowIDs["new.txt"]; !ok {
		t.Fatal("new row ID was not recorded after deferred invalidation")
	}
}

func TestTreeSelectionClickUsesVisiblePathModel(t *testing.T) {
	tree := treeState{}
	visible := []string{"a.txt", "folder", filepath.Join("folder", "b.txt"), "c.txt"}
	treeSelectionClick(&tree, "a.txt", 0, ModCtrl, visible)
	if !tree.Selected["a.txt"] || tree.AnchorPath != "a.txt" || tree.LeadPath != "a.txt" {
		t.Fatalf("initial selection = %#v anchor=%q lead=%q", tree.Selected, tree.AnchorPath, tree.LeadPath)
	}
	treeSelectionClick(&tree, "c.txt", ModShift, ModCtrl, visible)
	for _, path := range visible {
		if !tree.Selected[path] {
			t.Fatalf("shift range omitted %q: %#v", path, tree.Selected)
		}
	}
	if tree.AnchorPath != "a.txt" || tree.LeadPath != "c.txt" {
		t.Fatalf("range endpoints = %q:%q", tree.AnchorPath, tree.LeadPath)
	}
	treeSelectionClick(&tree, "folder", ModCtrl, ModCtrl, visible)
	if tree.Selected["folder"] {
		t.Fatal("control-click did not toggle the selected path off")
	}
	if !tree.Selected["a.txt"] || !tree.Selected["c.txt"] {
		t.Fatalf("control-click changed unrelated paths: %#v", tree.Selected)
	}
	treeSelectionClick(&tree, "folder", 0, ModCtrl, visible)
	if len(tree.Selected) != 1 || !tree.Selected["folder"] {
		t.Fatalf("normal click did not replace selection: %#v", tree.Selected)
	}
}

func TestTreeMarqueeRectAndIntersection(t *testing.T) {
	selection := treeMarqueeRect(Vec2{80, 70}, Vec2{20, 10})
	if selection.Origin != (Vec2{20, 10}) || selection.Size != (Vec2{60, 60}) {
		t.Fatalf("marquee rect = %#v, want origin {20,10}, size {60,60}", selection)
	}
	if !treeRectsIntersect(selection, Rect{Origin: Vec2{30, 30}, Size: Vec2{10, 10}}) {
		t.Fatal("overlapping row was not intersected")
	}
	if treeRectsIntersect(selection, Rect{Origin: Vec2{100, 10}, Size: Vec2{10, 10}}) {
		t.Fatal("non-overlapping row was intersected")
	}
}

func TestWorkspaceContextMenuTargetsRoot(t *testing.T) {
	shell := &workbenchState{}
	GetHost().HeadlessRender = true
	GetInputState().MousePoint = Vec2{40, 50}
	openWorkspaceContextMenu(shell, `C:\workspace`)
	if !shell.ContextMenu.Open || !shell.ContextMenu.WorkspaceRoot || !shell.ContextMenu.IsDir {
		t.Fatalf("root context menu = %#v", shell.ContextMenu)
	}
	if shell.ContextMenu.Path != `C:\workspace` {
		t.Fatalf("root context path = %q", shell.ContextMenu.Path)
	}
}

func TestSidebarEmptyBackgroundOpensWorkspaceContextMenu(t *testing.T) {
	ResetInputSession()
	host := GetHost()
	host.HeadlessRender = true
	host.WindowFocused = true
	host.WindowSize = Vec2{500, 300}
	t.Cleanup(ResetInputSession)
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "note.txt"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	state := application.New(nil)
	if err := state.OpenWorkspace(root); err != nil {
		t.Fatal(err)
	}
	shell := &workbenchState{SidebarMode: SidebarFiles}
	scope := new(int)
	frame := func(action MouseAction, button MouseButton, point Vec2) {
		GetInputState().MousePoint = point
		GetInputState().MouseButton = button
		GetFrameInput().Mouse = action
		GetFrameInput().Key = KeyCodeNone
		GetFrameInput().Text = ""
		RunFrameFn(func() {
			ContainerWithKey(scope, Attrs(Viewport, FixSize(500, 300)), func() {
				Container(Attrs(Row, Grow(1), Expand), func() {
					sidebar(state, shell, DefaultTheme())
					Container(Attrs(Grow(1), Expand), func() {})
				})
			})
		})
	}
	frame(0, MousePrimary, Vec2{-1000, -1000})
	frame(MouseClick, MouseSecondary, Vec2{100, 180})
	if !shell.ContextMenu.Open || !shell.ContextMenu.WorkspaceRoot || shell.ContextMenu.Path != root {
		t.Fatalf("empty-background context menu = %#v, want workspace root", shell.ContextMenu)
	}
}

func TestSidebarBackgroundMarqueeSelectsVisibleRows(t *testing.T) {
	ResetInputSession()
	host := GetHost()
	host.HeadlessRender = true
	host.WindowFocused = true
	host.WindowSize = Vec2{500, 300}
	t.Cleanup(ResetInputSession)
	root := t.TempDir()
	for _, name := range []string{"a.txt", "b.txt", "c.txt"} {
		if err := os.WriteFile(filepath.Join(root, name), nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	state := application.New(nil)
	if err := state.OpenWorkspace(root); err != nil {
		t.Fatal(err)
	}
	shell := &workbenchState{SidebarMode: SidebarFiles}
	scope := new(int)
	frame := func(action MouseAction, point Vec2) {
		GetInputState().MousePoint = point
		GetInputState().MouseButton = MousePrimary
		GetFrameInput().Mouse = action
		GetFrameInput().Key = KeyCodeNone
		GetFrameInput().Text = ""
		RunFrameFn(func() {
			ContainerWithKey(scope, Attrs(Viewport, FixSize(500, 300)), func() {
				Container(Attrs(Row, Grow(1), Expand), func() {
					sidebar(state, shell, DefaultTheme())
					Container(Attrs(Grow(1), Expand), func() {})
				})
			})
		})
	}
	frame(0, Vec2{-1000, -1000})
	frame(MouseClick, Vec2{230, 150})
	if !shell.Tree.MarqueeActive {
		t.Fatal("empty background press did not start a marquee")
	}
	frame(0, Vec2{10, 60})
	frame(MouseRelease, Vec2{10, 60})
	if shell.Tree.MarqueeActive {
		t.Fatal("marquee remained active after release")
	}
	for _, name := range []string{"a.txt", "b.txt", "c.txt"} {
		if !shell.Tree.Selected[name] {
			t.Fatalf("marquee did not select %q: %#v", name, shell.Tree.Selected)
		}
	}
}
