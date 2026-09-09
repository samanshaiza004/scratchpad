package workspace

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestWorkspaceCreateMutationsAreExclusive(t *testing.T) {
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, "notes"), 0o755); err != nil {
		t.Fatal(err)
	}
	ws, err := Open(root)
	if err != nil {
		t.Fatal(err)
	}

	file := filepath.Join(root, "notes", "today.md")
	if err := ws.CreateFile(filepath.Join("notes", "today.md")); err != nil {
		t.Fatal(err)
	}
	if info, err := os.Stat(file); err != nil || !info.Mode().IsRegular() {
		t.Fatalf("created file = %v, %v", info, err)
	}
	if data, err := os.ReadFile(file); err != nil || len(data) != 0 {
		t.Fatalf("created file data = %q, %v", data, err)
	}
	if err := ws.CreateFile(filepath.Join("notes", "today.md")); !errors.Is(err, ErrDestinationExists) {
		t.Fatalf("duplicate file error = %v, want ErrDestinationExists", err)
	}

	directory := filepath.Join(root, "notes", "archive")
	if err := ws.CreateDirectory(filepath.Join("notes", "archive")); err != nil {
		t.Fatal(err)
	}
	if info, err := os.Stat(directory); err != nil || !info.IsDir() {
		t.Fatalf("created directory = %v, %v", info, err)
	}
	if err := ws.CreateDirectory(filepath.Join("notes", "archive")); !errors.Is(err, ErrDestinationExists) {
		t.Fatalf("duplicate directory error = %v, want ErrDestinationExists", err)
	}
	if err := ws.CreateDirectory(filepath.Join("missing", "child")); err == nil {
		t.Fatal("CreateDirectory unexpectedly created missing parents")
	}
}

func TestWorkspaceMutationsRequireSafeRelativePaths(t *testing.T) {
	root := t.TempDir()
	ws, err := Open(root)
	if err != nil {
		t.Fatal(err)
	}

	for _, path := range []string{"", ".", "..", filepath.Join("..", "outside"), filepath.Join(root, "absolute")} {
		if err := ws.CreateFile(path); !errors.Is(err, ErrPathNotRelative) {
			t.Errorf("CreateFile(%q) error = %v, want ErrPathNotRelative", path, err)
		}
	}
	for _, path := range []string{".git", filepath.Join("nested", ".git", "config"), ".scratchpad", filepath.Join("nested", ".scratchpad", "session")} {
		if err := ws.CreateFile(path); !errors.Is(err, ErrReservedPath) {
			t.Errorf("CreateFile(%q) error = %v, want ErrReservedPath", path, err)
		}
	}
	if err := ws.Move(".git", "other"); !errors.Is(err, ErrReservedPath) {
		t.Fatalf("Move reserved source error = %v, want ErrReservedPath", err)
	}
	if err := ws.Move("other", ".scratchpad"); !errors.Is(err, ErrReservedPath) {
		t.Fatalf("Move reserved destination error = %v, want ErrReservedPath", err)
	}
}

func TestWorkspaceMoveDoesNotOverwriteOrMoveIntoSelf(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "from", "child"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "from", "note.md"), []byte("source"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "occupied"), []byte("destination"), 0o644); err != nil {
		t.Fatal(err)
	}
	ws, err := Open(root)
	if err != nil {
		t.Fatal(err)
	}

	if err := ws.Move(filepath.Join("from", "note.md"), "occupied"); !errors.Is(err, ErrDestinationExists) {
		t.Fatalf("collision error = %v, want ErrDestinationExists", err)
	}
	if got, err := os.ReadFile(filepath.Join(root, "occupied")); err != nil || string(got) != "destination" {
		t.Fatalf("occupied destination = %q, %v", got, err)
	}
	if _, err := os.Lstat(filepath.Join(root, "from", "note.md")); err != nil {
		t.Fatalf("source was changed after collision: %v", err)
	}
	if err := ws.Move("from", filepath.Join("from", "child", "again")); !errors.Is(err, ErrMoveIntoSelf) {
		t.Fatalf("descendant move error = %v, want ErrMoveIntoSelf", err)
	}
	if err := ws.Move("from", "from"); !errors.Is(err, ErrMoveIntoSelf) {
		t.Fatalf("same-path move error = %v, want ErrMoveIntoSelf", err)
	}

	if err := ws.Move(filepath.Join("from", "note.md"), filepath.Join("from", "renamed.md")); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(filepath.Join(root, "from", "note.md")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("old path error = %v, want not exist", err)
	}
	if got, err := os.ReadFile(filepath.Join(root, "from", "renamed.md")); err != nil || string(got) != "source" {
		t.Fatalf("moved data = %q, %v", got, err)
	}
}

func TestWorkspaceMovePreservesSymlinkEntryAndContainment(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()
	target := filepath.Join(outside, "target")
	if err := os.WriteFile(target, []byte("outside"), 0o644); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(root, "link")
	if err := os.Symlink(target, link); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
	escapingParent := filepath.Join(root, "out")
	if err := os.Symlink(outside, escapingParent); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
	ws, err := Open(root)
	if err != nil {
		t.Fatal(err)
	}

	if err := ws.Move("link", "moved-link"); err != nil {
		t.Fatal(err)
	}
	info, err := os.Lstat(filepath.Join(root, "moved-link"))
	if err != nil || info.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("moved entry = %v, %v; want symbolic link", info, err)
	}
	if got, err := os.Readlink(filepath.Join(root, "moved-link")); err != nil || got != target {
		t.Fatalf("moved link target = %q, %v", got, err)
	}
	if got, err := os.ReadFile(target); err != nil || string(got) != "outside" {
		t.Fatalf("link target was changed = %q, %v", got, err)
	}
	if err := ws.CreateFile(filepath.Join("out", "escape")); err == nil {
		t.Fatal("CreateFile followed a parent symlink outside the workspace")
	}
	if _, err := os.Lstat(filepath.Join(outside, "escape")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("file escaped workspace: %v", err)
	}
}
