package application

import (
	"context"
	"errors"
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

func TestSaveAsRejectsOpenDirtyDestination(t *testing.T) {
	dir := t.TempDir()
	source := filepath.Join(dir, "source.txt")
	target := filepath.Join(dir, "target.txt")
	if err := os.WriteFile(source, []byte("source on disk"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(target, []byte("target on disk"), 0o644); err != nil {
		t.Fatal(err)
	}

	a := New(nil)
	if err := a.OpenPath(source); err != nil {
		t.Fatal(err)
	}
	sourceID := a.Active
	sourceDoc := a.Documents[sourceID]
	sourceDoc.Editor.SetCursor(sourceDoc.Editor.Buffer.ByteLen())
	if err := sourceDoc.Insert([]byte(" with local edits")); err != nil {
		t.Fatal(err)
	}
	if err := a.OpenPath(target); err != nil {
		t.Fatal(err)
	}
	targetID := a.Active
	targetDoc := a.Documents[targetID]
	targetDoc.Editor.SetCursor(targetDoc.Editor.Buffer.ByteLen())
	if err := targetDoc.Insert([]byte(" that must survive")); err != nil {
		t.Fatal(err)
	}
	order := append([]DocumentID(nil), a.Order...)
	active := a.Active

	if err := a.SaveAs(sourceID, target); !errors.Is(err, ErrDocumentAlreadyOpen) {
		t.Fatalf("SaveAs error = %v, want ErrDocumentAlreadyOpen", err)
	}
	if len(a.Documents) != 2 || len(a.Order) != 2 {
		t.Fatalf("documents=%d order=%d after rejected SaveAs", len(a.Documents), len(a.Order))
	}
	if a.Order[0] != order[0] || a.Order[1] != order[1] || a.Active != active {
		t.Fatalf("registry changed: order=%v want=%v active=%q want=%q", a.Order, order, a.Active, active)
	}
	if a.Documents[sourceID] != sourceDoc || a.Documents[targetID] != targetDoc {
		t.Fatal("rejected SaveAs replaced an open document")
	}
	if sourceDoc.Path != source || targetDoc.Path != target {
		t.Fatalf("document paths changed: source=%q target=%q", sourceDoc.Path, targetDoc.Path)
	}
	if string(sourceDoc.Editor.Buffer.Text()) != "source on disk with local edits" || !sourceDoc.Dirty() {
		t.Fatalf("source state changed: text=%q dirty=%v", sourceDoc.Editor.Buffer.Text(), sourceDoc.Dirty())
	}
	if string(targetDoc.Editor.Buffer.Text()) != "target on disk that must survive" || !targetDoc.Dirty() {
		t.Fatalf("target state changed: text=%q dirty=%v", targetDoc.Editor.Buffer.Text(), targetDoc.Dirty())
	}
	if got, err := os.ReadFile(source); err != nil || string(got) != "source on disk" {
		t.Fatalf("source disk changed: bytes=%q err=%v", got, err)
	}
	if got, err := os.ReadFile(target); err != nil || string(got) != "target on disk" {
		t.Fatalf("target disk changed: bytes=%q err=%v", got, err)
	}
}

func TestSaveAsRejectsOpenDestinationSymlinkAlias(t *testing.T) {
	dir := t.TempDir()
	source := filepath.Join(dir, "source.txt")
	target := filepath.Join(dir, "target.txt")
	alias := filepath.Join(dir, "target-alias.txt")
	if err := os.WriteFile(source, []byte("source"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(target, []byte("target"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, alias); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}

	a := New(nil)
	if err := a.OpenPath(source); err != nil {
		t.Fatal(err)
	}
	sourceID := a.Active
	if err := a.OpenPath(target); err != nil {
		t.Fatal(err)
	}
	targetID := a.Active
	order := append([]DocumentID(nil), a.Order...)
	if err := a.SaveAs(sourceID, alias); !errors.Is(err, ErrDocumentAlreadyOpen) {
		t.Fatalf("SaveAs alias error = %v, want ErrDocumentAlreadyOpen", err)
	}
	if len(a.Documents) != 2 || len(a.Order) != 2 || a.Order[0] != order[0] || a.Order[1] != order[1] {
		t.Fatalf("registry changed after alias collision: documents=%d order=%v", len(a.Documents), a.Order)
	}
	if a.Documents[sourceID].Path != source || a.Documents[targetID].Path != target {
		t.Fatalf("document paths changed: source=%q target=%q", a.Documents[sourceID].Path, a.Documents[targetID].Path)
	}
	if got, err := os.ReadFile(target); err != nil || string(got) != "target" {
		t.Fatalf("target disk changed: bytes=%q err=%v", got, err)
	}
}

func TestOpenPathFileDoesNotInventWorkspace(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "note.txt")
	if err := os.WriteFile(path, []byte("hello"), 0o644); err != nil {
		t.Fatal(err)
	}
	a := New(nil)
	if err := a.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	if a.HasWorkspace || a.Workspace.Root != "" || a.ActiveDocument().Path != path {
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

func TestCloseDocumentRequiresExplicitDirtyDecision(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "note.txt")
	if err := os.WriteFile(path, []byte("hello"), 0o644); err != nil {
		t.Fatal(err)
	}
	a := New(nil)
	if err := a.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	id := a.Active
	if err := a.Documents[id].Insert([]byte("!")); err != nil {
		t.Fatal(err)
	}
	if err := a.CloseDocument(id, false); err != ErrDirty {
		t.Fatalf("close dirty error = %v, want ErrDirty", err)
	}
	if _, ok := a.Documents[id]; !ok {
		t.Fatal("dirty document was closed without an explicit decision")
	}
	if err := a.CloseDocument(id, true); err != nil {
		t.Fatal(err)
	}
	if len(a.Documents) != 0 || len(a.Order) != 0 {
		t.Fatalf("documents=%d order=%d after discard", len(a.Documents), len(a.Order))
	}
}

func TestReopenClosedRestoresFileWithoutChangingDirtyPolicy(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "note.txt")
	if err := os.WriteFile(path, []byte("hello"), 0o644); err != nil {
		t.Fatal(err)
	}
	a := New(nil)
	if err := a.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	id := a.Active
	if err := a.Documents[id].Insert([]byte("!")); err != nil {
		t.Fatal(err)
	}
	if err := a.CloseDocument(id, false); err != ErrDirty {
		t.Fatalf("dirty close error = %v, want ErrDirty", err)
	}
	if err := a.CloseDocument(id, true); err != nil {
		t.Fatal(err)
	}
	if got := a.RecentlyClosedPaths(); len(got) != 1 || got[0] != path {
		t.Fatalf("closed paths = %v", got)
	}
	if err := a.ReopenClosed(); err != nil {
		t.Fatal(err)
	}
	if a.ActiveDocument() == nil || string(a.ActiveDocument().Editor.Buffer.Text()) != "hello" {
		t.Fatalf("reopened document = %#v", a.ActiveDocument())
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

func TestFlushRecoveryCapturesEditsAfterInFlightSnapshot(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "note.txt")
	if err := os.WriteFile(path, []byte("disk"), 0o644); err != nil {
		t.Fatal(err)
	}
	a := New(nil)
	if err := a.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	doc := a.ActiveDocument()
	doc.Editor.SetCursor(doc.Editor.Buffer.ByteLen())
	if err := doc.Insert([]byte("-old")); err != nil {
		t.Fatal(err)
	}
	recoveryDir := filepath.Join(t.TempDir(), "recovery")
	if err := a.WriteRecovery(recoveryDir); err != nil {
		t.Fatal(err)
	}
	if err := doc.Insert([]byte("-latest")); err != nil {
		t.Fatal(err)
	}

	// Model a completed asynchronous write whose payload was captured before
	// the latest edit. FlushRecovery must still write a fresh payload.
	a.recoveryRunning = true
	a.recoveryDone <- nil
	if err := a.FlushRecovery(recoveryDir); err != nil {
		t.Fatal(err)
	}

	restored := New(nil)
	if err := restored.RestoreRecovery(recoveryDir); err != nil {
		t.Fatal(err)
	}
	if got := string(restored.ActiveDocument().Editor.Buffer.Text()); got != "disk-old-latest" {
		t.Fatalf("flushed recovery = %q, want latest edits", got)
	}
}

func TestRestoreRecoveryConflictsWhenDiskChangedSinceBase(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "note.txt")
	if err := os.WriteFile(path, []byte("base"), 0o644); err != nil {
		t.Fatal(err)
	}
	a := New(nil)
	if err := a.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	doc := a.ActiveDocument()
	doc.Editor.SetCursor(doc.Editor.Buffer.ByteLen())
	if err := doc.Insert([]byte("-local")); err != nil {
		t.Fatal(err)
	}
	recoveryDir := filepath.Join(t.TempDir(), "recovery")
	if err := a.WriteRecovery(recoveryDir); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("external"), 0o644); err != nil {
		t.Fatal(err)
	}

	restored := New(nil)
	if err := restored.RestoreRecovery(recoveryDir); err != nil {
		t.Fatal(err)
	}
	id := restored.Active
	if got := string(restored.Documents[id].Editor.Buffer.Text()); got != "base-local" {
		t.Fatalf("recovered local bytes = %q", got)
	}
	if status := restored.Status(id); status != StatusConflict {
		t.Fatalf("recovered status = %v, want conflict", status)
	}
	conflict, ok := restored.Conflict(id)
	if !ok || string(conflict.Disk) != "external" {
		t.Fatalf("recovered conflict = %+v, want external disk bytes", conflict)
	}
	if err := restored.SaveActive(); !errors.Is(err, ErrConflict) {
		t.Fatalf("SaveActive error = %v, want ErrConflict", err)
	}
	if got, err := os.ReadFile(path); err != nil || string(got) != "external" {
		t.Fatalf("disk after blocked save = %q, err=%v", got, err)
	}
}

func TestFindCurrentAndSearchWorkspace(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "note.txt")
	if err := os.WriteFile(path, []byte("needle\nother needle\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	a := New(nil)
	if err := a.OpenWorkspace(dir); err != nil {
		t.Fatal(err)
	}
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

func TestFindCurrentTracksLinesIncrementallyAcrossRawByteMatches(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "note.txt")
	data := []byte("before\nneedle\nneedle\nend")
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
	a := New(nil)
	if err := a.OpenPath(path); err != nil {
		t.Fatal(err)
	}

	matches := a.FindCurrent(a.Active, []byte("needle"))
	if len(matches) != 2 || matches[0].Start != 7 || matches[0].Line != 1 || matches[0].Column != 0 || matches[1].Start != 14 || matches[1].Line != 2 || matches[1].Column != 0 {
		t.Fatalf("matches = %+v", matches)
	}

	// A newline in a raw-byte query must advance the line state before the
	// next non-overlapping match, just as it did in the previous implementation.
	matches = a.FindCurrent(a.Active, []byte("needle\nneedle"))
	if len(matches) != 1 || matches[0].Start != 7 || matches[0].End != 20 || matches[0].Line != 1 || matches[0].Column != 0 {
		t.Fatalf("newline query matches = %+v", matches)
	}
}
