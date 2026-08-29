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

func TestAtomicWritePreservesExistingPermissions(t *testing.T) {
	path := filepath.Join(t.TempDir(), "note.md")
	if err := os.WriteFile(path, []byte("old"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := AtomicWriteFile(path, []byte("new"), 0o644); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != 0o600 {
		t.Fatalf("mode = %o, want 600", got)
	}
}

func TestAtomicWriteUsesRequestedModeForNewFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "new.md")
	if err := AtomicWriteFile(path, []byte("new"), 0o640); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != 0o640 {
		t.Fatalf("mode = %o, want 640", got)
	}
}

func TestAtomicWritePreservesSymlink(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "real.md")
	link := filepath.Join(dir, "link.md")
	if err := os.WriteFile(target, []byte("real"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, link); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
	if err := AtomicWriteFile(link, []byte("replacement"), 0); err != nil {
		t.Fatal(err)
	}
	if info, err := os.Lstat(link); err != nil || info.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("link was replaced: %v", err)
	}
	if got, err := os.ReadFile(target); err != nil || string(got) != "replacement" {
		t.Fatalf("target not updated: %q, %v", got, err)
	}
}

func TestAtomicWriteRefusesHardLink(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "original")
	link := filepath.Join(dir, "hard-link")
	if err := os.WriteFile(path, []byte("old"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Link(path, link); err != nil {
		t.Skipf("hard links unavailable: %v", err)
	}
	if err := AtomicWriteFile(path, []byte("new"), 0); err == nil {
		t.Fatal("expected hard-link replacement to be refused")
	}
}

func TestAtomicWriteCleansTemporaryFileAfterRenameFailure(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "target-dir")
	if err := os.Mkdir(target, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := AtomicWriteFile(target, []byte("data"), 0); err == nil {
		t.Fatal("expected replacement of directory to fail")
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if entry.Name() != "target-dir" {
			t.Fatalf("temporary save artifact remains: %s", entry.Name())
		}
	}
}
