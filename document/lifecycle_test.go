package document

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"scratchpad/workspace"
)

func TestLoadedDocumentNoOpSaveIsByteIdentical(t *testing.T) {
	path := filepath.Join(t.TempDir(), "mixed.txt")
	want := []byte{0xef, 0xbb, 0xbf, 'a', '\r', '\n', 'e', 0xcc, 0x81, '\n', 0xff, '\r', '\n'}
	if err := os.WriteFile(path, want, 0o640); err != nil {
		t.Fatal(err)
	}
	store := workspace.NewOSFileStore()
	snapshot, err := store.Load(path)
	if err != nil {
		t.Fatal(err)
	}
	doc := NewLoaded(path, snapshot.Data, snapshot.Version, snapshot.Mode, "text")
	if err := doc.Save(store); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("no-op save changed bytes: got %x, want %x", got, want)
	}
	if doc.Dirty() {
		t.Fatal("no-op save left document dirty")
	}
}

func TestDocumentSaveRejectsChangedDiskAndPreservesState(t *testing.T) {
	path := filepath.Join(t.TempDir(), "note.txt")
	if err := os.WriteFile(path, []byte("original"), 0o644); err != nil {
		t.Fatal(err)
	}
	store := workspace.NewOSFileStore()
	snapshot, err := store.Load(path)
	if err != nil {
		t.Fatal(err)
	}
	doc := NewLoaded(path, snapshot.Data, snapshot.Version, snapshot.Mode, "text")
	if err := doc.Insert([]byte("!")); err != nil {
		t.Fatal(err)
	}
	beforePath, beforeRevision, beforeVersion := doc.Path, doc.Revision(), doc.DiskVersion
	if err := os.WriteFile(path, []byte("external"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := doc.Save(store); !errors.Is(err, ErrDiskChanged) {
		t.Fatalf("Save error = %v, want ErrDiskChanged", err)
	}
	if doc.Path != beforePath || doc.Revision() != beforeRevision || doc.DiskVersion != beforeVersion || !doc.Dirty() {
		t.Fatal("failed save changed document state")
	}
	got, _ := os.ReadFile(path)
	if string(got) != "external" {
		t.Fatalf("external file was overwritten: %q", got)
	}
}

func TestSaveAsChangesPathOnlyAfterSuccess(t *testing.T) {
	dir := t.TempDir()
	source := filepath.Join(dir, "source.txt")
	target := filepath.Join(dir, "target.txt")
	if err := os.WriteFile(source, []byte("source"), 0o644); err != nil {
		t.Fatal(err)
	}
	store := workspace.NewOSFileStore()
	snapshot, err := store.Load(source)
	if err != nil {
		t.Fatal(err)
	}
	doc := NewLoaded(source, snapshot.Data, snapshot.Version, snapshot.Mode, "text")
	doc.Editor.SetCursor(doc.Editor.Buffer.ByteLen())
	if err := doc.Insert([]byte(" changed")); err != nil {
		t.Fatal(err)
	}
	if err := doc.SaveAs(store, target); err != nil {
		t.Fatal(err)
	}
	if doc.Path != target || doc.Dirty() {
		t.Fatalf("SaveAs state: path=%q dirty=%v", doc.Path, doc.Dirty())
	}
	got, _ := os.ReadFile(target)
	if string(got) != "source changed" {
		t.Fatalf("target = %q", got)
	}
}

func TestDivergentEditAfterUndoRemainsDirty(t *testing.T) {
	doc := New("note.txt", []byte("a"), "text")
	doc.MarkSaved()
	if err := doc.Insert([]byte("b")); err != nil {
		t.Fatal(err)
	}
	if err := doc.Editor.Undo(); err != nil {
		t.Fatal(err)
	}
	if doc.Dirty() {
		t.Fatal("undo should return to saved state")
	}
	if err := doc.Insert([]byte("c")); err != nil {
		t.Fatal(err)
	}
	if !doc.Dirty() {
		t.Fatal("divergent edit after undo should be dirty")
	}
}
