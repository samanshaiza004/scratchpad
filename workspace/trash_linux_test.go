//go:build linux

package workspace

import (
	"errors"
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

func TestLinuxTrashRenameDoesNotReplace(t *testing.T) {
	dir := t.TempDir()
	source := filepath.Join(dir, "source.txt")
	destination := filepath.Join(dir, "destination.txt")
	if err := os.WriteFile(source, []byte("source"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(destination, []byte("existing"), 0o600); err != nil {
		t.Fatal(err)
	}

	err := renameTrashEntry(source, destination)
	if !errors.Is(err, syscall.EEXIST) {
		t.Fatalf("renameTrashEntry error = %v, want EEXIST", err)
	}
	if got, readErr := os.ReadFile(source); readErr != nil || string(got) != "source" {
		t.Fatalf("source after collision = %q, %v", got, readErr)
	}
	if got, readErr := os.ReadFile(destination); readErr != nil || string(got) != "existing" {
		t.Fatalf("destination after collision = %q, %v", got, readErr)
	}
}

func TestLinuxTrashConcurrentSameNamesRemainDistinct(t *testing.T) {
	dataHome := t.TempDir()
	t.Setenv("XDG_DATA_HOME", dataHome)
	sourceDirA := t.TempDir()
	sourceDirB := t.TempDir()
	sourceA := filepath.Join(sourceDirA, "note.md")
	sourceB := filepath.Join(sourceDirB, "note.md")
	if err := os.WriteFile(sourceA, []byte("a"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(sourceB, []byte("b"), 0o600); err != nil {
		t.Fatal(err)
	}

	errs := make(chan error, 2)
	go func() { errs <- (linuxTrasher{}).Trash(sourceA) }()
	go func() { errs <- (linuxTrasher{}).Trash(sourceB) }()
	for range 2 {
		if err := <-errs; err != nil {
			t.Fatal(err)
		}
	}

	files, err := os.ReadDir(filepath.Join(dataHome, "Trash", "files"))
	if err != nil {
		t.Fatal(err)
	}
	if len(files) != 2 {
		t.Fatalf("trashed files = %d, want 2", len(files))
	}
	info, err := os.ReadDir(filepath.Join(dataHome, "Trash", "info"))
	if err != nil {
		t.Fatal(err)
	}
	if len(info) != 2 {
		t.Fatalf("trash metadata files = %d, want 2", len(info))
	}
}
