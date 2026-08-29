package application

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"scratchpad/workspace"
)

type fakeWatcher struct{ dirs []string }

func (w *fakeWatcher) WatchDirectory(path string) error {
	w.dirs = append(w.dirs, path)
	return nil
}
func (*fakeWatcher) Events() <-chan workspace.WatchEvent { return make(chan workspace.WatchEvent) }
func (*fakeWatcher) Errors() <-chan error                { return make(chan error) }
func (*fakeWatcher) Close() error                        { return nil }

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

func TestWatcherWatchesOpenDocumentParentAndOnlyHints(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "note.txt")
	if err := os.WriteFile(path, []byte("one"), 0o644); err != nil {
		t.Fatal(err)
	}
	a := New(nil)
	watcher := &fakeWatcher{}
	if err := a.SetWatcher(watcher); err != nil {
		t.Fatal(err)
	}
	if err := a.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	if len(watcher.dirs) != 1 || watcher.dirs[0] != dir {
		t.Fatalf("watched dirs = %v", watcher.dirs)
	}
	id := a.Active
	a.HandleWatchEvent(workspace.WatchEvent{Name: path})
	if !a.Stale[id] || string(a.Documents[id].Editor.Buffer.Text()) != "one" {
		t.Fatal("watch event changed content instead of recording a hint")
	}
}

func TestReconcileReloadsCleanAndConflictsDirtyDocuments(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "note.txt")
	if err := os.WriteFile(path, []byte("one"), 0o644); err != nil {
		t.Fatal(err)
	}
	a := New(nil)
	if err := a.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	id := a.Active
	if err := os.WriteFile(path, []byte("two"), 0o644); err != nil {
		t.Fatal(err)
	}
	status, err := a.Reconcile(id)
	if err != nil || status != StatusSynced || string(a.Documents[id].Editor.Buffer.Text()) != "two" {
		t.Fatalf("clean reconcile status=%v err=%v text=%q", status, err, a.Documents[id].Editor.Buffer.Text())
	}
	if err := a.Documents[id].Insert([]byte("local")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("three"), 0o644); err != nil {
		t.Fatal(err)
	}
	status, err = a.Reconcile(id)
	if err != nil || status != StatusConflict {
		t.Fatalf("dirty reconcile status=%v err=%v", status, err)
	}
	if !a.Documents[id].Dirty() || string(a.Documents[id].Editor.Buffer.Text()) != "localtwo" {
		t.Fatal("conflict reconciliation changed local content")
	}
	conflict, ok := a.Conflict(id)
	if !ok || string(conflict.Base) != "two" || string(conflict.Disk) != "three" {
		t.Fatalf("conflict snapshot = %+v", conflict)
	}
	if err := a.ReloadDisk(id); err != nil {
		t.Fatal(err)
	}
	if string(a.Documents[id].Editor.Buffer.Text()) != "three" || a.Documents[id].Dirty() {
		t.Fatal("reload did not replace local state cleanly")
	}
}

func TestSessionRoundTripRestoresDocumentsAndViewState(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "note.txt")
	if err := os.WriteFile(path, []byte("hello"), 0o644); err != nil {
		t.Fatal(err)
	}
	a := New(nil)
	if err := a.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	a.ActiveDocument().Editor.SetSelection(1, 4)
	a.Views[a.Active] = ViewState{ScrollY: 42}
	sessionPath := filepath.Join(t.TempDir(), "session.json")
	if err := a.SaveSession(sessionPath); err != nil {
		t.Fatal(err)
	}
	restored := New(nil)
	if err := restored.RestoreSession(sessionPath); err != nil {
		t.Fatal(err)
	}
	doc := restored.ActiveDocument()
	anchor, cursor := doc.Editor.Selection()
	if anchor != 1 || cursor != 4 || restored.Views[restored.Active].ScrollY != 42 {
		t.Fatalf("restored selection=%d:%d view=%+v", anchor, cursor, restored.Views[restored.Active])
	}
}

func TestRecoveryRoundTripRestoresDirtyRawBytes(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "note.txt")
	if err := os.WriteFile(path, []byte("disk"), 0o644); err != nil {
		t.Fatal(err)
	}
	a := New(nil)
	if err := a.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	a.ActiveDocument().Editor.SetCursor(4)
	if err := a.ActiveDocument().Insert([]byte{0xff, 'x'}); err != nil {
		t.Fatal(err)
	}
	recoveryDir := filepath.Join(t.TempDir(), "recovery")
	if err := a.WriteRecovery(recoveryDir); err != nil {
		t.Fatal(err)
	}
	restored := New(nil)
	if err := restored.RestoreRecovery(recoveryDir); err != nil {
		t.Fatal(err)
	}
	doc := restored.ActiveDocument()
	if !doc.Dirty() || string(doc.Editor.Buffer.Text()) != "disk\xffx" {
		t.Fatalf("recovered dirty=%v bytes=%x", doc.Dirty(), doc.Editor.Buffer.Text())
	}
	if err := restored.ClearRecovery(recoveryDir); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(recoveryDir, "manifest.json")); !os.IsNotExist(err) {
		t.Fatalf("recovery manifest remains: %v", err)
	}
}

func TestFindCurrentAndSearchWorkspace(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "note.txt")
	if err := os.WriteFile(path, []byte("needle\nother needle\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	a := New(nil)
	if err := a.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	matches := a.FindCurrent(a.Active, []byte("needle"))
	if len(matches) != 2 || matches[1].Line != 1 || matches[1].Column != 6 {
		t.Fatalf("matches = %+v", matches)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var results int
	for range a.SearchWorkspace(ctx, []byte("needle")) {
		results++
	}
	if results != 2 {
		t.Fatalf("workspace results = %d", results)
	}
}
