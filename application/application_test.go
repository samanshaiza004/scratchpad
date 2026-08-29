package application

import (
	"os"
	"path/filepath"
	"testing"
)

func TestOpenPathSharesDocumentForAliases(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "note.md")
	alias := filepath.Join(dir, "alias.md")
	if err := os.WriteFile(path, []byte("hello"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(path, alias); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
	a := New(nil)
	if err := a.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	if err := a.OpenPath(alias); err != nil {
		t.Fatal(err)
	}
	if len(a.Documents) != 1 || len(a.Order) != 1 {
		t.Fatalf("documents=%d order=%d, want one document", len(a.Documents), len(a.Order))
	}
}

func TestOpenPathFileEstablishesContainingWorkspace(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "note.txt")
	if err := os.WriteFile(path, []byte("hello"), 0o644); err != nil {
		t.Fatal(err)
	}
	a := New(nil)
	if err := a.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	if a.Workspace.Root != dir || a.ActiveDocument().Path != path {
		t.Fatalf("workspace=%q document=%q", a.Workspace.Root, a.ActiveDocument().Path)
	}
}

func TestReorderKeepsStableDocumentIdentity(t *testing.T) {
	dir := t.TempDir()
	a := New(nil)
	for _, name := range []string{"a.txt", "b.txt"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(name), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := a.OpenPath(filepath.Join(dir, name)); err != nil {
			t.Fatal(err)
		}
	}
	first, second := a.Order[0], a.Order[1]
	if err := a.Reorder([]DocumentID{second, first}); err != nil {
		t.Fatal(err)
	}
	if a.Order[0] != second || a.Documents[first].Path != filepath.Join(dir, "a.txt") {
		t.Fatal("reorder changed document identity")
	}
}
