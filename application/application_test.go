package application

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"scratchpad/document"
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

type createBeforeConditionalStore struct {
	workspace.OSFileStore
	target string
}

type parentDirSyncStore struct{ workspace.OSFileStore }

func (s *parentDirSyncStore) Save(path string, data []byte, mode os.FileMode) (workspace.DiskVersion, error) {
	version, err := s.OSFileStore.Save(path, data, mode)
	if err != nil {
		return version, err
	}
	return version, fmt.Errorf("%w: test warning", workspace.ErrParentDirSync)
}

func (s *parentDirSyncStore) SaveIfVersion(path string, data []byte, mode os.FileMode, expected workspace.DiskVersion) (workspace.DiskVersion, error) {
	version, err := s.OSFileStore.SaveIfVersion(path, data, mode, expected)
	if err != nil {
		return version, err
	}
	return version, fmt.Errorf("%w: test warning", workspace.ErrParentDirSync)
}

func (s *createBeforeConditionalStore) SaveIfVersion(path string, data []byte, mode os.FileMode, expected workspace.DiskVersion) (workspace.DiskVersion, error) {
	if path == s.target {
		if err := os.WriteFile(s.target, []byte("external"), 0o644); err != nil {
			return workspace.DiskVersion{}, err
		}
	}
	return s.OSFileStore.SaveIfVersion(path, data, mode, expected)
}

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

func TestSaveAsRequiresConfirmationForExistingUnopenedDestination(t *testing.T) {
	dir := t.TempDir()
	source := filepath.Join(dir, "source.txt")
	target := filepath.Join(dir, "target.txt")
	if err := os.WriteFile(source, []byte("source"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(target, []byte("target"), 0o644); err != nil {
		t.Fatal(err)
	}

	a := New(nil)
	if err := a.OpenPath(source); err != nil {
		t.Fatal(err)
	}
	id := a.Active
	doc := a.Documents[id]
	doc.Editor.SetCursor(doc.Editor.Buffer.ByteLen())
	if err := doc.Insert([]byte(" changed")); err != nil {
		t.Fatal(err)
	}

	err := a.SaveAs(id, target)
	var request *SaveAsDestinationExistsError
	if !errors.As(err, &request) || !errors.Is(err, ErrSaveAsDestinationExists) {
		t.Fatalf("SaveAs error = %v, want versioned destination confirmation", err)
	}
	if request.Path != target || !request.Version.Exists || !request.Version.Verified {
		t.Fatalf("confirmation request = %+v", request)
	}
	if doc.Path != source || !doc.Dirty() {
		t.Fatalf("rejected SaveAs changed source state: path=%q dirty=%v", doc.Path, doc.Dirty())
	}
	if got, readErr := os.ReadFile(target); readErr != nil || string(got) != "target" {
		t.Fatalf("rejected SaveAs changed target: bytes=%q err=%v", got, readErr)
	}

	if err := a.ConfirmSaveAs(id, target, request.Version); err != nil {
		t.Fatal(err)
	}
	if doc.Path != target || doc.Dirty() {
		t.Fatalf("confirmed SaveAs state: path=%q dirty=%v", doc.Path, doc.Dirty())
	}
	if got, readErr := os.ReadFile(target); readErr != nil || string(got) != "source changed" {
		t.Fatalf("confirmed SaveAs target: bytes=%q err=%v", got, readErr)
	}
}

func TestSaveAsNewDestinationRejectsCreationBeforeReplacement(t *testing.T) {
	dir := t.TempDir()
	source := filepath.Join(dir, "source.txt")
	target := filepath.Join(dir, "target.txt")
	if err := os.WriteFile(source, []byte("source"), 0o644); err != nil {
		t.Fatal(err)
	}
	store := &createBeforeConditionalStore{OSFileStore: workspace.NewOSFileStore(), target: target}
	a := New(store)
	if err := a.OpenPath(source); err != nil {
		t.Fatal(err)
	}
	id := a.Active
	doc := a.Documents[id]
	doc.Editor.SetCursor(doc.Editor.Buffer.ByteLen())
	if err := doc.Insert([]byte(" changed")); err != nil {
		t.Fatal(err)
	}
	if err := a.SaveAs(id, target); !errors.Is(err, document.ErrDiskChanged) {
		t.Fatalf("SaveAs error = %v, want ErrDiskChanged", err)
	}
	if doc.Path != source || !doc.Dirty() {
		t.Fatalf("creation race changed source state: path=%q dirty=%v", doc.Path, doc.Dirty())
	}
	if got, err := os.ReadFile(target); err != nil || string(got) != "external" {
		t.Fatalf("creation race changed target: bytes=%q err=%v", got, err)
	}
}

func TestConfirmSaveAsRejectsDestinationChangedAfterPrompt(t *testing.T) {
	dir := t.TempDir()
	source := filepath.Join(dir, "source.txt")
	target := filepath.Join(dir, "target.txt")
	if err := os.WriteFile(source, []byte("source"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(target, []byte("target"), 0o644); err != nil {
		t.Fatal(err)
	}

	a := New(nil)
	if err := a.OpenPath(source); err != nil {
		t.Fatal(err)
	}
	id := a.Active
	doc := a.Documents[id]
	doc.Editor.SetCursor(doc.Editor.Buffer.ByteLen())
	if err := doc.Insert([]byte(" changed")); err != nil {
		t.Fatal(err)
	}
	var request *SaveAsDestinationExistsError
	if err := a.SaveAs(id, target); !errors.As(err, &request) {
		t.Fatalf("SaveAs error = %v, want destination confirmation", err)
	}
	if err := os.WriteFile(target, []byte("external"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := a.ConfirmSaveAs(id, target, request.Version); !errors.Is(err, document.ErrDiskChanged) {
		t.Fatalf("ConfirmSaveAs error = %v, want ErrDiskChanged", err)
	}
	if doc.Path != source || !doc.Dirty() {
		t.Fatalf("stale confirmation changed source state: path=%q dirty=%v", doc.Path, doc.Dirty())
	}
	if got, readErr := os.ReadFile(target); readErr != nil || string(got) != "external" {
		t.Fatalf("stale confirmation changed target: bytes=%q err=%v", got, readErr)
	}
}

func TestSaveAsSameDocumentUsesOrdinarySavePolicy(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "note.txt")
	if err := os.WriteFile(path, []byte("source"), 0o644); err != nil {
		t.Fatal(err)
	}
	a := New(nil)
	if err := a.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	id := a.Active
	doc := a.Documents[id]
	doc.Editor.SetCursor(doc.Editor.Buffer.ByteLen())
	if err := doc.Insert([]byte(" changed")); err != nil {
		t.Fatal(err)
	}
	if err := a.SaveAs(id, path); err != nil {
		t.Fatal(err)
	}
	if doc.Path != path || doc.Dirty() {
		t.Fatalf("same-document SaveAs state: path=%q dirty=%v", doc.Path, doc.Dirty())
	}
	if got, err := os.ReadFile(path); err != nil || string(got) != "source changed" {
		t.Fatalf("same-document SaveAs target: bytes=%q err=%v", got, err)
	}
}

func TestSaveAsSameDocumentRejectsUnreconciledExternalChange(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "note.txt")
	if err := os.WriteFile(path, []byte("source"), 0o644); err != nil {
		t.Fatal(err)
	}
	a := New(nil)
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

	if err := a.SaveAs(id, path); !errors.Is(err, ErrConflict) {
		t.Fatalf("same-document SaveAs error = %v, want ErrConflict", err)
	}
	if !doc.Dirty() || doc.Path != path {
		t.Fatalf("rejected same-document SaveAs changed state: path=%q dirty=%v", doc.Path, doc.Dirty())
	}
	if _, ok := a.Conflict(id); !ok {
		t.Fatal("same-document SaveAs did not retain the external-change conflict")
	}
	if got, readErr := os.ReadFile(path); readErr != nil || string(got) != "external" {
		t.Fatalf("rejected same-document SaveAs changed external bytes: %q (err=%v)", got, readErr)
	}
}

func TestSaveAsSameDocumentRejectsExistingConflict(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "note.txt")
	if err := os.WriteFile(path, []byte("source"), 0o644); err != nil {
		t.Fatal(err)
	}
	a := New(nil)
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
	status, err := a.Reconcile(id)
	if err != nil || status != StatusConflict {
		t.Fatalf("initial reconcile status=%v err=%v, want conflict", status, err)
	}

	if err := a.SaveAs(id, path); !errors.Is(err, ErrConflict) {
		t.Fatalf("same-document SaveAs error = %v, want ErrConflict", err)
	}
	if got, readErr := os.ReadFile(path); readErr != nil || string(got) != "external" {
		t.Fatalf("rejected conflicted SaveAs changed external bytes: %q (err=%v)", got, readErr)
	}
}

func TestSaveAsSameDocumentSymlinkAliasUsesOrdinarySavePolicy(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "note.txt")
	alias := filepath.Join(dir, "alias.txt")
	if err := os.WriteFile(path, []byte("source"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(path, alias); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
	a := New(nil)
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

	if err := a.SaveAs(id, alias); !errors.Is(err, ErrConflict) {
		t.Fatalf("same-identity alias SaveAs error = %v, want ErrConflict", err)
	}
	if got, readErr := os.ReadFile(path); readErr != nil || string(got) != "external" {
		t.Fatalf("rejected alias SaveAs changed external bytes: %q (err=%v)", got, readErr)
	}
}

func TestSaveActiveParentDirectoryWarningCommitsAndRefreshesRecovery(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "note.txt")
	if err := os.WriteFile(path, []byte("source"), 0o644); err != nil {
		t.Fatal(err)
	}
	recoveryDir := filepath.Join(t.TempDir(), "recovery")
	a := New(&parentDirSyncStore{OSFileStore: workspace.NewOSFileStore()})
	a.RecoveryDir = recoveryDir
	if err := a.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	doc := a.ActiveDocument()
	doc.Editor.SetCursor(doc.Editor.Buffer.ByteLen())
	if err := doc.Insert([]byte(" changed")); err != nil {
		t.Fatal(err)
	}
	if err := a.WriteRecovery(recoveryDir); err != nil {
		t.Fatal(err)
	}
	if err := a.SaveActive(); !errors.Is(err, workspace.ErrParentDirSync) {
		t.Fatalf("SaveActive error = %v, want ErrParentDirSync", err)
	}
	if doc.Dirty() {
		t.Fatal("committed durability warning left document dirty")
	}
	entries, err := os.ReadDir(recoveryDir)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("recovery files after committed save = %v, want empty", entries)
	}
}

func TestSaveAsParentDirectoryWarningCompletesApplicationBookkeeping(t *testing.T) {
	dir := t.TempDir()
	source := filepath.Join(dir, "source.txt")
	target := filepath.Join(dir, "moved", "target.txt")
	if err := os.WriteFile(source, []byte("source"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		t.Fatal(err)
	}
	a := New(&parentDirSyncStore{OSFileStore: workspace.NewOSFileStore()})
	if err := a.OpenPath(source); err != nil {
		t.Fatal(err)
	}
	watcher := &fakeWatcher{}
	if err := a.SetWatcher(watcher); err != nil {
		t.Fatal(err)
	}
	recoveryDir := filepath.Join(t.TempDir(), "recovery")
	a.RecoveryDir = recoveryDir
	oldID := a.Active
	a.Views[oldID] = ViewState{ScrollY: 42}
	doc := a.ActiveDocument()
	doc.Editor.SetCursor(doc.Editor.Buffer.ByteLen())
	if err := doc.Insert([]byte(" changed")); err != nil {
		t.Fatal(err)
	}
	if err := a.WriteRecovery(recoveryDir); err != nil {
		t.Fatal(err)
	}

	if err := a.SaveAs(oldID, target); !errors.Is(err, workspace.ErrParentDirSync) {
		t.Fatalf("SaveAs error = %v, want ErrParentDirSync", err)
	}
	newID := documentID(target)
	if doc.Path != target || doc.Dirty() {
		t.Fatalf("committed SaveAs state: path=%q dirty=%v", doc.Path, doc.Dirty())
	}
	if _, ok := a.Documents[oldID]; ok {
		t.Fatal("old document ID remained after committed SaveAs")
	}
	if a.Documents[newID] != doc || len(a.Order) != 1 || a.Order[0] != newID || a.Active != newID {
		t.Fatalf("document registry after SaveAs: documents=%v order=%v active=%q", a.Documents, a.Order, a.Active)
	}
	if got := a.Views[newID]; got.ScrollY != 42 {
		t.Fatalf("migrated view = %+v, want ScrollY 42", got)
	}
	if _, ok := a.Views[oldID]; ok {
		t.Fatal("old view ID remained after committed SaveAs")
	}
	if len(watcher.dirs) != 2 || watcher.dirs[1] != filepath.Dir(target) {
		t.Fatalf("watched directories = %v, want source then target", watcher.dirs)
	}
	if recent := a.RecentPaths(); len(recent) == 0 || recent[0] != target {
		t.Fatalf("recent paths = %v, want target first", recent)
	}
	entries, err := os.ReadDir(recoveryDir)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("recovery files after committed SaveAs = %v, want empty", entries)
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
	a.Views[a.Active] = ViewState{ScrollY: 42, ScrollInitialized: true, ScrollX: 18, ScrollXInitialized: true}
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
	view := restored.Views[restored.Active]
	if anchor != 1 || cursor != 4 || view.ScrollY != 42 || !view.ScrollInitialized || view.ScrollX != 18 || !view.ScrollXInitialized {
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

func TestClearRecoveryRemovesManifestBeforeInterruptedCleanup(t *testing.T) {
	recoveryDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(recoveryDir, "manifest.json"), []byte(`{"documents":[]}`), 0o600); err != nil {
		t.Fatal(err)
	}
	// A non-empty directory makes cleanup stop deterministically after the
	// manifest has been removed, modeling an interruption or cleanup failure.
	blocker := filepath.Join(recoveryDir, "00-blocker")
	if err := os.Mkdir(blocker, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(blocker, "keep"), []byte("orphan"), 0o600); err != nil {
		t.Fatal(err)
	}
	blob := filepath.Join(recoveryDir, "recovered.bytes")
	if err := os.WriteFile(blob, []byte("recovered"), 0o600); err != nil {
		t.Fatal(err)
	}

	if err := clearRecovery(recoveryDir); err == nil {
		t.Fatal("cleanup unexpectedly succeeded")
	}
	if _, err := os.Stat(filepath.Join(recoveryDir, "manifest.json")); !os.IsNotExist(err) {
		t.Fatalf("recovery manifest remains after interrupted cleanup: %v", err)
	}
	if _, err := os.Stat(blob); err != nil {
		t.Fatalf("recovery blob was removed before cleanup interruption: %v", err)
	}
}

func TestRestoreRecoveryMissingBlobDoesNotPartiallyRestore(t *testing.T) {
	recoveryDir := t.TempDir()
	firstPath := filepath.Join(t.TempDir(), "first.txt")
	secondPath := filepath.Join(t.TempDir(), "second.txt")
	firstBytesFile := "first.bytes"
	if err := os.WriteFile(filepath.Join(recoveryDir, firstBytesFile), []byte("first"), 0o600); err != nil {
		t.Fatal(err)
	}
	manifest := recoveryManifest{Documents: []recoveryDocument{
		{ID: documentID(firstPath), Path: firstPath, BytesFile: firstBytesFile},
		{ID: documentID(secondPath), Path: secondPath, BytesFile: "missing.bytes"},
	}}
	manifestBytes, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(recoveryDir, "manifest.json"), manifestBytes, 0o600); err != nil {
		t.Fatal(err)
	}

	restored := New(nil)
	if err := restored.RestoreRecovery(recoveryDir); err == nil {
		t.Fatal("missing recovery blob unexpectedly restored")
	}
	if len(restored.Documents) != 0 {
		t.Fatalf("partial recovery state after missing blob: %d documents", len(restored.Documents))
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

func TestRestoreRecoveryConflictsWhenSymlinkRetargeted(t *testing.T) {
	dir := t.TempDir()
	targetA := filepath.Join(dir, "a.txt")
	targetB := filepath.Join(dir, "b.txt")
	link := filepath.Join(dir, "current.txt")
	if err := os.WriteFile(targetA, []byte("base"), 0o644); err != nil {
		t.Fatal(err)
	}
	// Matching bytes make sure the conflict comes from the target identity,
	// rather than only from the content fingerprint.
	if err := os.WriteFile(targetB, []byte("base"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(targetA, link); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}

	a := New(nil)
	if err := a.OpenPath(link); err != nil {
		t.Fatal(err)
	}
	doc := a.ActiveDocument()
	doc.Editor.SetCursor(doc.Editor.Buffer.ByteLen())
	if err := doc.Insert([]byte("-recovered")); err != nil {
		t.Fatal(err)
	}
	recoveryDir := filepath.Join(t.TempDir(), "recovery")
	if err := a.WriteRecovery(recoveryDir); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(link); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(targetB, link); err != nil {
		t.Fatal(err)
	}

	restored := New(nil)
	if err := restored.RestoreRecovery(recoveryDir); err != nil {
		t.Fatalf("retargeted recovery: %v", err)
	}
	id := restored.Active
	if got := string(restored.Documents[id].Editor.Buffer.Text()); got != "base-recovered" {
		t.Fatalf("recovered local bytes = %q", got)
	}
	if status := restored.Status(id); status != StatusConflict {
		t.Fatalf("recovered status = %v, want conflict", status)
	}
	conflict, ok := restored.Conflict(id)
	if !ok || string(conflict.Disk) != "base" {
		t.Fatalf("recovered conflict = %+v, want target B bytes", conflict)
	}
	if err := restored.SaveActive(); !errors.Is(err, ErrConflict) {
		t.Fatalf("SaveActive error = %v, want ErrConflict", err)
	}
	if got, err := os.ReadFile(targetB); err != nil || string(got) != "base" {
		t.Fatalf("retargeted disk after blocked save = %q, err=%v", got, err)
	}
}

func TestRestoreRecoveryRetargetedOpenTargetPreservesLocalEdits(t *testing.T) {
	dir := t.TempDir()
	targetA := filepath.Join(dir, "a.txt")
	targetB := filepath.Join(dir, "b.txt")
	link := filepath.Join(dir, "current.txt")
	if err := os.WriteFile(targetA, []byte("from-a"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(targetB, []byte("from-b"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(targetA, link); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}

	source := New(nil)
	if err := source.OpenPath(link); err != nil {
		t.Fatal(err)
	}
	doc := source.ActiveDocument()
	doc.Editor.SetCursor(doc.Editor.Buffer.ByteLen())
	if err := doc.Insert([]byte("-recovered")); err != nil {
		t.Fatal(err)
	}
	recoveryDir := filepath.Join(t.TempDir(), "recovery")
	if err := source.WriteRecovery(recoveryDir); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(link); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(targetB, link); err != nil {
		t.Fatal(err)
	}

	restored := New(nil)
	if err := restored.OpenPath(link); err != nil {
		t.Fatal(err)
	}
	openID := restored.Active
	openText := string(restored.Documents[openID].Editor.Buffer.Text())
	openOrder := append([]DocumentID(nil), restored.Order...)
	if err := restored.RestoreRecovery(recoveryDir); err == nil {
		t.Fatal("retargeted recovery unexpectedly replaced an already-open document")
	}
	if got := string(restored.Documents[openID].Editor.Buffer.Text()); got != openText {
		t.Fatalf("already-open target changed from %q to %q", openText, got)
	}
	if restored.Active != openID {
		t.Fatalf("active document changed from %q to %q", openID, restored.Active)
	}
	if len(restored.Order) != len(openOrder) || restored.Order[0] != openOrder[0] {
		t.Fatalf("document registry changed: before=%v after=%v", openOrder, restored.Order)
	}
	if len(restored.Conflicts) != 0 {
		t.Fatalf("unexpected conflicts after rejected recovery: %+v", restored.Conflicts)
	}
}

func TestRestoreRecoveryConflictsWhenManifestIdentityRetargeted(t *testing.T) {
	dir := t.TempDir()
	targetA := filepath.Join(dir, "a.txt")
	targetB := filepath.Join(dir, "b.txt")
	diskBytes := []byte("disk-b")
	if err := os.WriteFile(targetB, diskBytes, 0o644); err != nil {
		t.Fatal(err)
	}
	snapshot, err := workspace.NewOSFileStore().Load(targetB)
	if err != nil {
		t.Fatal(err)
	}

	recoveryDir := filepath.Join(t.TempDir(), "recovery")
	if err := os.MkdirAll(recoveryDir, 0o700); err != nil {
		t.Fatal(err)
	}
	recoveredBytes := []byte("recovered-local")
	const bytesFile = "recovered.bytes"
	if err := os.WriteFile(filepath.Join(recoveryDir, bytesFile), recoveredBytes, 0o600); err != nil {
		t.Fatal(err)
	}
	manifest := recoveryManifest{Documents: []recoveryDocument{{
		ID: documentID(targetA), Path: targetB, BytesFile: bytesFile,
		BaseVersion: snapshot.Version, Mode: snapshot.Mode,
		Format: document.DetectFormat(snapshot.Data),
	}}}
	manifestBytes, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(recoveryDir, "manifest.json"), manifestBytes, 0o600); err != nil {
		t.Fatal(err)
	}

	restored := New(nil)
	if err := restored.RestoreRecovery(recoveryDir); err != nil {
		t.Fatalf("manifest retarget recovery: %v", err)
	}
	id := restored.Active
	if id != documentID(targetB) {
		t.Fatalf("restored ID = %q, want current target B ID %q", id, documentID(targetB))
	}
	if got := string(restored.Documents[id].Editor.Buffer.Text()); got != string(recoveredBytes) {
		t.Fatalf("recovered local bytes = %q", got)
	}
	if status := restored.Status(id); status != StatusConflict {
		t.Fatalf("recovered status = %v, want conflict", status)
	}
	conflict, ok := restored.Conflict(id)
	if !ok || string(conflict.Disk) != string(diskBytes) {
		t.Fatalf("recovered conflict = %+v, want target B bytes", conflict)
	}
	if err := restored.SaveActive(); !errors.Is(err, ErrConflict) {
		t.Fatalf("SaveActive error = %v, want ErrConflict", err)
	}
	if got, err := os.ReadFile(targetB); err != nil || string(got) != string(diskBytes) {
		t.Fatalf("target B after blocked save = %q, err=%v", got, err)
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
