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
