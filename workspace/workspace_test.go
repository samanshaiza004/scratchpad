package workspace

import (
	"os"
	"path/filepath"
	"testing"
)

func TestWorkspacePathsAndAtomicWrite(t *testing.T) {
	root := t.TempDir()
	ws, err := Open(root)
	if err != nil {
		t.Fatal(err)
	}

	inside := filepath.Join(root, "notes", "today.md")
	if err := os.MkdirAll(filepath.Dir(inside), 0o755); err != nil {
		t.Fatal(err)
	}
	rel, err := ws.RelativePath(inside)
	if err != nil || rel != filepath.Join("notes", "today.md") {
		t.Fatalf("RelativePath = %q, %v", rel, err)
	}
	if _, err := ws.RelativePath(filepath.Dir(root)); err == nil {
		t.Fatal("expected outside path to be rejected")
	}

	if err := AtomicWriteFile(inside, []byte("hello\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(inside)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "hello\n" {
		t.Fatalf("got %q", data)
	}
}
