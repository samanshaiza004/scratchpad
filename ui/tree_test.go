package ui

import (
	"os"
	"path/filepath"
	"testing"

	"scratchpad/application"
	"scratchpad/commands"

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

func TestTreePathMutationRemapsViewState(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "src", "nested"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "src", "nested", "note.txt"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	state := application.New(nil)
	if err := state.OpenWorkspace(root); err != nil {
		t.Fatal(err)
	}
	shell := &workbenchState{Tree: treeState{
		Expanded:   map[string]bool{"src": true, filepath.Join("src", "nested"): true, "keep": true},
		Selected:   map[string]bool{"src": true, filepath.Join("src", "nested", "note.txt"): true, "keep.txt": true},
		AnchorPath: filepath.Join("src", "nested"),
		LeadPath:   filepath.Join("src", "nested", "note.txt"),
	}}
	oldPath := filepath.Join(root, "src")
	newPath := filepath.Join(root, "archive")
	if err := state.MovePath("src", "archive"); err != nil {
		t.Fatal(err)
	}
	reconcileTreePathMutation(shell, state, oldPath, newPath, false)
	resetTreeAfterMutation(shell)

	for _, path := range []string{"archive", filepath.Join("archive", "nested")} {
		if !shell.Tree.Expanded[path] {
			t.Fatalf("expanded state omitted remapped path %q: %#v", path, shell.Tree.Expanded)
		}
	}
	for _, path := range []string{"archive", filepath.Join("archive", "nested", "note.txt"), "keep.txt"} {
		if !shell.Tree.Selected[path] {
			t.Fatalf("selection omitted path %q: %#v", path, shell.Tree.Selected)
		}
	}
	if shell.Tree.AnchorPath != filepath.Join("archive", "nested") || shell.Tree.LeadPath != filepath.Join("archive", "nested", "note.txt") {
		t.Fatalf("selection endpoints = %q:%q", shell.Tree.AnchorPath, shell.Tree.LeadPath)
	}
}

func TestWorkspaceRefreshPrunesDeletedTreeViewState(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "gone", "nested"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "keep.txt"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	state := application.New(nil)
	if err := state.OpenWorkspace(root); err != nil {
		t.Fatal(err)
	}
	shell := &workbenchState{Tree: treeState{
		Expanded:   map[string]bool{"gone": true, filepath.Join("gone", "nested"): true},
		Selected:   map[string]bool{"gone": true, filepath.Join("gone", "nested"): true, "keep.txt": true},
		AnchorPath: "gone",
		LeadPath:   filepath.Join("gone", "nested"),
	}}
	if err := os.RemoveAll(filepath.Join(root, "gone")); err != nil {
		t.Fatal(err)
	}
	executeCommand(state, shell, commands.WorkspaceRefresh)
	if len(shell.Tree.Expanded) != 0 || len(shell.Tree.Selected) != 1 || !shell.Tree.Selected["keep.txt"] {
		t.Fatalf("refreshed tree state expanded=%#v selected=%#v", shell.Tree.Expanded, shell.Tree.Selected)
	}
	if shell.Tree.AnchorPath != "" || shell.Tree.LeadPath != "" {
		t.Fatalf("deleted selection endpoints = %q:%q", shell.Tree.AnchorPath, shell.Tree.LeadPath)
	}
}

func TestTreeDragSelectionMatchesSinglePathPayload(t *testing.T) {
	tree := treeState{
		Selected:   map[string]bool{"a.txt": true, "b.txt": true, "c.txt": true},
		AnchorPath: "a.txt",
		LeadPath:   "c.txt",
	}
	treeSelectionForDrag(&tree, "b.txt")
	if len(tree.Selected) != 1 || !tree.Selected["b.txt"] {
		t.Fatalf("drag selection = %#v, want only b.txt", tree.Selected)
	}
	if tree.AnchorPath != "b.txt" || tree.LeadPath != "b.txt" {
		t.Fatalf("drag endpoints = %q:%q, want b.txt:b.txt", tree.AnchorPath, tree.LeadPath)
	}
}

func TestTreeKeyboardMovesAndActivatesFocusedPath(t *testing.T) {
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, "dir"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "a.txt"), []byte("a"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "b.txt"), []byte("b"), 0o644); err != nil {
		t.Fatal(err)
	}
	state := application.New(nil)
	if err := state.OpenWorkspace(root); err != nil {
		t.Fatal(err)
	}
	shell := &workbenchState{SidebarMode: SidebarFiles}
	scope := new(int)
	GetHost().HeadlessRender = true
	GetHost().WindowFocused = true
	GetHost().WindowSize = Vec2{500, 300}
	GetInputState().MousePoint = Vec2{-1000, -1000}
	GetFrameInput().Key = KeyCodeNone
	RunFrameFn(func() {
		ContainerWithKey(scope, Attrs(Viewport, FixSize(500, 300)), func() {
			sidebar(state, shell, DefaultTheme())
		})
	})
	if shell.Tree.FocusID == nil {
		t.Fatal("tree did not create a focus target")
	}
	FocusImmediateOn(shell.Tree.FocusID)

	GetFrameInput().Key = KeyDown
	GetFrameInput().Text = ""
	GetInputState().Modifiers = 0
	if !handleTreeKeyboardInput(state, shell) {
		t.Fatal("down was not handled by the tree")
	}
	if shell.Tree.FocusedPath != "a.txt" {
		t.Fatalf("focused path = %q, want a.txt", shell.Tree.FocusedPath)
	}

	GetFrameInput().Key = KeySpace
	if !handleTreeKeyboardInput(state, shell) {
		t.Fatal("space activation was not handled by the tree")
	}
	if state.ActiveDocument() == nil || state.ActiveDocument().Path != filepath.Join(root, "a.txt") {
		t.Fatalf("active document = %#v, want a.txt", state.ActiveDocument())
	}
}

func TestTreeKeyboardF2StartsInlineRenameAndCommitPreservesTarget(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "old.txt")
	if err := os.WriteFile(path, []byte("content"), 0o644); err != nil {
		t.Fatal(err)
	}
	state := application.New(nil)
	if err := state.OpenWorkspace(root); err != nil {
		t.Fatal(err)
	}
	if err := state.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	shell := &workbenchState{Tree: treeState{VisiblePaths: []string{"old.txt"}, FocusedPath: "old.txt"}}
	if !beginTreeRename(state, shell) {
		t.Fatal("F2 did not start inline rename")
	}
	if shell.TreeRename.Text != "old.txt" {
		t.Fatalf("rename text = %q, want old.txt", shell.TreeRename.Text)
	}
	shell.TreeRename.Text = "new.txt"
	if !commitTreeRename(state, shell) {
		t.Fatal("inline rename did not commit")
	}
	if _, err := os.Stat(filepath.Join(root, "new.txt")); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("old path still exists: %v", err)
	}
	if got := state.ActiveDocument().Path; got != filepath.Join(root, "new.txt") {
		t.Fatalf("active document path = %q, want new.txt", got)
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
