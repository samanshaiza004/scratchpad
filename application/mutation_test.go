package application

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"scratchpad/workspace"
)

type fakeTrasher struct {
	paths []string
	err   error
}

func (t *fakeTrasher) Trash(path string) error {
	t.paths = append(t.paths, path)
	return t.err
}

func TestCreateFileCreatesAndOpensRealDocument(t *testing.T) {
	root := t.TempDir()
	a := New(nil)
	if err := a.OpenWorkspace(root); err != nil {
		t.Fatal(err)
	}
	if err := a.CreateFile("notes/today.md"); err == nil {
		t.Fatal("CreateFile unexpectedly created a file below a missing parent")
	}
	if err := a.CreateDirectory("notes"); err != nil {
		t.Fatal(err)
	}
	if err := a.CreateFile("notes/today.md"); err != nil {
		t.Fatal(err)
	}
	if len(a.Documents) != 1 || a.Active == "" {
		t.Fatalf("documents=%d active=%q, want one active document", len(a.Documents), a.Active)
	}
	if got, err := os.ReadFile(filepath.Join(root, "notes", "today.md")); err != nil || len(got) != 0 {
		t.Fatalf("created bytes=%q err=%v", got, err)
	}
	if err := a.CreateFile("notes/today.md"); !errors.Is(err, workspace.ErrDestinationExists) {
		t.Fatalf("duplicate create error=%v, want ErrDestinationExists", err)
	}
}

func TestRenamePreservesDocumentEditorAndViewState(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "draft.txt")
	if err := os.WriteFile(path, []byte("draft"), 0o644); err != nil {
		t.Fatal(err)
	}
	a := New(nil)
	if err := a.OpenWorkspace(root); err != nil {
		t.Fatal(err)
	}
	if err := a.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	oldID := a.Active
	doc := a.Documents[oldID]
	doc.Editor.SetCursor(doc.Editor.Buffer.ByteLen())
	if err := doc.Insert([]byte(" changed")); err != nil {
		t.Fatal(err)
	}
	view := ViewState{ScrollY: 42, ScrollInitialized: true}
	a.Views[oldID] = view
	revision := doc.Revision()

	if err := a.RenamePath("draft.txt", "draft.md"); err != nil {
		t.Fatal(err)
	}
	newID := documentID(filepath.Join(root, "draft.md"))
	if a.Active != newID || a.Documents[newID] != doc {
		t.Fatalf("active/document identity: active=%q new=%q doc=%p", a.Active, newID, a.Documents[newID])
	}
	if doc.Path != filepath.Join(root, "draft.md") || doc.Revision() != revision || !doc.Dirty() {
		t.Fatalf("migrated doc path=%q revision=%d dirty=%v", doc.Path, doc.Revision(), doc.Dirty())
	}
	if string(doc.Editor.Buffer.Text()) != "draft changed" {
		t.Fatalf("migrated bytes=%q", doc.Editor.Buffer.Text())
	}
	if got := a.Views[newID]; !reflect.DeepEqual(got, view) {
		t.Fatalf("view=%+v, want %+v", got, view)
	}
	if _, ok := a.Documents[oldID]; ok {
		t.Fatal("old document identity remains registered")
	}
	if _, err := os.Stat(filepath.Join(root, "draft.txt")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("old path stat=%v, want not exist", err)
	}
	if got, err := os.ReadFile(filepath.Join(root, "draft.md")); err != nil || string(got) != "draft" {
		t.Fatalf("disk bytes=%q err=%v", got, err)
	}
}

func TestMoveDirectoryMigratesAllOpenDescendants(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "src", "nested"), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"one.go", filepath.Join("nested", "two.go")} {
		if err := os.WriteFile(filepath.Join(root, "src", name), []byte(name), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	a := New(nil)
	if err := a.OpenWorkspace(root); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"src/one.go", "src/nested/two.go"} {
		if err := a.OpenPath(filepath.Join(root, name)); err != nil {
			t.Fatal(err)
		}
	}
	watcher := &fakeWatcher{}
	if err := a.SetWatcher(watcher); err != nil {
		t.Fatal(err)
	}
	activeBefore := a.Active
	if err := a.MovePath("src", "moved"); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"moved/one.go", "moved/nested/two.go"} {
		id := documentID(filepath.Join(root, name))
		doc := a.Documents[id]
		if doc == nil || doc.Path != filepath.Join(root, name) {
			t.Fatalf("missing migrated document %q: %#v", name, doc)
		}
		if _, err := os.Stat(doc.Path); err != nil {
			t.Fatalf("migrated disk path %q: %v", doc.Path, err)
		}
	}
	if a.Active != documentID(filepath.Join(root, "moved", "nested", "two.go")) {
		t.Fatalf("active=%q, want moved active identity; before=%q", a.Active, activeBefore)
	}
	if _, ok := a.Documents[documentID(filepath.Join(root, "src", "one.go"))]; ok {
		t.Fatal("old descendant identity remains registered")
	}
	watchedMovedParent := false
	for _, watched := range watcher.dirs {
		if filepath.Clean(watched) == filepath.Join(root, "moved") {
			watchedMovedParent = true
		}
	}
	if !watchedMovedParent {
		t.Fatalf("watcher directories=%v, want moved parent", watcher.dirs)
	}
}

func TestMovePreflightRejectsConflictAndCollisionWithoutDiskChange(t *testing.T) {
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, "src"), 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "src", "note.md")
	if err := os.WriteFile(path, []byte("base"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "occupied"), []byte("keep"), 0o644); err != nil {
		t.Fatal(err)
	}
	a := New(nil)
	if err := a.OpenWorkspace(root); err != nil {
		t.Fatal(err)
	}
	if err := a.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	id := a.Active
	doc := a.Documents[id]
	doc.Editor.SetCursor(doc.Editor.Buffer.ByteLen())
	if err := doc.Insert([]byte(" local")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("external"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := a.MovePath("src/note.md", "occupied"); !errors.Is(err, workspace.ErrDestinationExists) {
		t.Fatalf("collision error=%v, want ErrDestinationExists", err)
	}
	if a.Documents[id].Path != path {
		t.Fatalf("collision changed document path=%q", a.Documents[id].Path)
	}
	if got, err := os.ReadFile(filepath.Join(root, "occupied")); err != nil || string(got) != "keep" {
		t.Fatalf("collision changed destination=%q err=%v", got, err)
	}
	if err := a.MovePath("src/note.md", "moved.md"); !errors.Is(err, ErrConflict) {
		t.Fatalf("external conflict error=%v, want ErrConflict", err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("conflict moved source: %v", err)
	}
}

func TestTrashClosesCleanDocumentsAndRequiresExplicitDirtyDecision(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "note.md")
	if err := os.WriteFile(path, []byte("note"), 0o644); err != nil {
		t.Fatal(err)
	}
	trasher := &fakeTrasher{}
	a := New(nil)
	a.SetTrasher(trasher)
	if err := a.OpenWorkspace(root); err != nil {
		t.Fatal(err)
	}
	if err := a.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	if err := a.TrashPath(path, false); err != nil {
		t.Fatal(err)
	}
	if len(trasher.paths) != 1 || len(a.Documents) != 0 {
		t.Fatalf("trash paths=%v documents=%d, want one trash operation and no open documents", trasher.paths, len(a.Documents))
	}

	if err := os.WriteFile(path, []byte("note"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := a.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	doc := a.Documents[a.Active]
	doc.Editor.SetCursor(doc.Editor.Buffer.ByteLen())
	if err := doc.Insert([]byte(" changed")); err != nil {
		t.Fatal(err)
	}
	if err := a.TrashPath(path, false); !errors.Is(err, ErrDirty) {
		t.Fatalf("dirty trash error=%v, want ErrDirty", err)
	}
	if len(trasher.paths) != 1 || a.Documents[a.Active] == nil {
		t.Fatal("dirty trash changed state before explicit decision")
	}
	if err := a.TrashPath(path, true); err != nil {
		t.Fatal(err)
	}
	if len(trasher.paths) != 2 || len(a.Documents) != 0 {
		t.Fatalf("discard trash paths=%v documents=%d, want second operation and no open documents", trasher.paths, len(a.Documents))
	}
}

func TestMoveDirectoryRewritesRememberedDescendantPaths(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "src", "closed.md")
	if err := os.Mkdir(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("closed"), 0o644); err != nil {
		t.Fatal(err)
	}
	a := New(nil)
	if err := a.OpenWorkspace(root); err != nil {
		t.Fatal(err)
	}
	if err := a.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	if err := a.CloseDocument(a.Active, false); err != nil {
		t.Fatal(err)
	}
	if err := a.MovePath("src", "archive"); err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(root, "archive", "closed.md")
	for _, remembered := range append(append([]string{}, a.RecentPaths()...), a.closed...) {
		if remembered == want {
			return
		}
	}
	t.Fatalf("remembered paths recent=%v closed=%v, want %q", a.RecentPaths(), a.closed, want)
}
