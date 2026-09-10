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
