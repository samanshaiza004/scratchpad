package workspace

import (
	"os"
	"path/filepath"
	"runtime"
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
	if !info.Mode().IsRegular() {
		t.Fatalf("saved path is not a regular file: %v", info.Mode())
	}
	if got, err := os.ReadFile(path); err != nil || string(got) != "new" {
		t.Fatalf("saved content = %q, %v", got, err)
	}
	if runtime.GOOS != "windows" {
		if got := info.Mode().Perm(); got != 0o600 {
			t.Fatalf("mode = %o, want 600", got)
		}
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
	if !info.Mode().IsRegular() {
		t.Fatalf("saved path is not a regular file: %v", info.Mode())
	}
	if got, err := os.ReadFile(path); err != nil || string(got) != "new" {
		t.Fatalf("saved content = %q, %v", got, err)
	}
	if runtime.GOOS != "windows" {
		if got := info.Mode().Perm(); got != 0o640 {
			t.Fatalf("mode = %o, want 640", got)
		}
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

func TestAtomicWriteRefusesSymlinkToHardLink(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "original")
	hardLink := filepath.Join(dir, "hard-link")
	symlink := filepath.Join(dir, "symlink")
	if err := os.WriteFile(target, []byte("old"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Link(target, hardLink); err != nil {
		t.Skipf("hard links unavailable: %v", err)
	}
	if err := os.Symlink(target, symlink); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
	if err := AtomicWriteFile(symlink, []byte("new"), 0); err == nil {
		t.Fatal("expected symlink to hard-linked file replacement to be refused")
	}
	for _, path := range []string{target, hardLink} {
		got, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if string(got) != "old" {
			t.Fatalf("%s changed to %q after refused replacement", path, got)
		}
	}
	if info, err := os.Lstat(symlink); err != nil || info.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("symlink changed after refused replacement: %v", err)
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
