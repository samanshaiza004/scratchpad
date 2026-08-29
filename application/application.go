// Package application owns the product's open-document registry and active
// application state. It deliberately contains no Shirei dependency.
package application

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"scratchpad/document"
	"scratchpad/language"
	"scratchpad/workspace"
)

type DocumentID string

type DocumentStatus uint8

const (
	StatusSynced DocumentStatus = iota
	StatusDirty
	StatusConflict
	StatusMissing
)

var ErrConflict = errors.New("document has an unresolved external-change conflict")

type Conflict struct {
	Base        []byte
	Disk        []byte
	DiskVersion workspace.DiskVersion
	DiskMode    os.FileMode
}

type ViewState struct {
	ScrollY float32
}

type Application struct {
	Store           workspace.FileStore
	Workspace       workspace.Workspace
	HasWorkspace    bool
	Documents       map[DocumentID]*document.Document
	Order           []DocumentID
	Active          DocumentID
	Views           map[DocumentID]ViewState
	Watcher         workspace.Watcher
	watchEvents     <-chan workspace.WatchEvent
	Stale           map[DocumentID]bool
	Conflicts       map[DocumentID]Conflict
	RecoveryDir     string
	lastRecovery    time.Time
	recoveryRunning bool
	recoveryDone    chan error
}

func New(store workspace.FileStore) *Application {
	if store == nil {
		store = workspace.NewOSFileStore()
	}
	return &Application{
		Store:        store,
		Documents:    make(map[DocumentID]*document.Document),
		Views:        make(map[DocumentID]ViewState),
		Stale:        make(map[DocumentID]bool),
		Conflicts:    make(map[DocumentID]Conflict),
		recoveryDone: make(chan error, 1),
	}
}

// OpenPath is the shared entry seam for CLI paths, file pickers, and future
// drag-and-drop or recent-file actions.
func (a *Application) OpenPath(path string) error {
	if a == nil {
		return errors.New("nil application")
	}
	if path == "" {
		return errors.New("empty path")
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return err
	}
	abs = filepath.Clean(abs)
	info, err := os.Stat(abs)
	if err != nil {
		return err
	}
	if info.IsDir() {
		return a.OpenWorkspace(abs)
	}
	return a.OpenDocument(abs)
}

func (a *Application) OpenWorkspace(path string) error {
	ws, err := workspace.Open(path)
	if err != nil {
		return err
	}
	a.Workspace = ws
	a.HasWorkspace = true
	return nil
}

func (a *Application) OpenDocument(path string) error {
	if a == nil {
		return errors.New("nil application")
	}
	snapshot, err := a.Store.Load(path)
	if err != nil {
		return err
	}
	id := documentID(path)
	if existing, ok := a.Documents[id]; ok {
		a.Active = id
		_ = existing
		return nil
	}
	if !a.HasWorkspace {
		if err := a.OpenWorkspace(filepath.Dir(snapshot.Path)); err != nil {
			return err
		}
	}
	rootLanguage := string(language.DetectPath(snapshot.Path))
	doc := document.NewLoaded(snapshot.Path, snapshot.Data, snapshot.Version, snapshot.Mode, rootLanguage)
	a.Documents[id] = doc
	a.Order = append(a.Order, id)
	a.Views[id] = ViewState{}
	a.Active = id
	if a.Watcher != nil {
		if err := a.Watcher.WatchDirectory(filepath.Dir(doc.Path)); err != nil {
			return err
		}
	}
	return nil
}

func (a *Application) SetWatcher(watcher workspace.Watcher) error {
	a.Watcher = watcher
	if watcher == nil {
		a.watchEvents = nil
		return nil
	}
	a.watchEvents = watcher.Events()
	for _, doc := range a.Documents {
		if err := watcher.WatchDirectory(filepath.Dir(doc.Path)); err != nil {
			return err
		}
	}
	return nil
}

// PollWatcher keeps watcher state on the application/UI goroutine. Events
// remain advisory and are reconciled through the filesystem afterward.
func (a *Application) PollWatcher() {
	for a.watchEvents != nil {
		select {
		case event, ok := <-a.watchEvents:
			if !ok {
				a.watchEvents = nil
				return
			}
			a.HandleWatchEvent(event)
		default:
			return
		}
	}
}

// HandleWatchEvent records only an advisory hint. Reconcile performs the
// authoritative read and fingerprint comparison.
func (a *Application) HandleWatchEvent(event workspace.WatchEvent) {
	name := filepath.Clean(event.Name)
	for id, doc := range a.Documents {
		if filepath.Clean(doc.Path) == name {
			a.Stale[id] = true
		}
	}
}

func (a *Application) Reconcile(id DocumentID) (DocumentStatus, error) {
	doc, ok := a.Documents[id]
	if !ok {
		return StatusMissing, errors.New("unknown document")
	}
	snapshot, err := a.Store.Load(doc.Path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return StatusMissing, nil
		}
		return StatusSynced, err
	}
	delete(a.Stale, id)
	if doc.DiskVersion.Equal(snapshot.Version) {
		if doc.Dirty() {
			return StatusDirty, nil
		}
		return StatusSynced, nil
	}
	if !doc.Dirty() {
		doc.Reload(snapshot.Data, snapshot.Version, snapshot.Mode)
		return StatusSynced, nil
	}
	a.Conflicts[id] = Conflict{
		Base: append([]byte(nil), doc.BaseSnapshot()...), Disk: append([]byte(nil), snapshot.Data...),
		DiskVersion: snapshot.Version, DiskMode: snapshot.Mode,
	}
	return StatusConflict, nil
}

func (a *Application) Status(id DocumentID) DocumentStatus {
	if _, ok := a.Conflicts[id]; ok {
		return StatusConflict
	}
	doc := a.Documents[id]
	if doc == nil {
		return StatusMissing
	}
	if doc.Dirty() {
		return StatusDirty
	}
	return StatusSynced
}

func (a *Application) Conflict(id DocumentID) (Conflict, bool) {
	conflict, ok := a.Conflicts[id]
	return conflict, ok
}

func (a *Application) ReloadDisk(id DocumentID) error {
	conflict, ok := a.Conflicts[id]
	if !ok {
		return errors.New("document is not conflicted")
	}
	doc := a.Documents[id]
	doc.Reload(conflict.Disk, conflict.DiskVersion, conflict.DiskMode)
	delete(a.Conflicts, id)
	return nil
}

func (a *Application) KeepEditing(id DocumentID) error {
	if _, ok := a.Conflicts[id]; !ok {
		return errors.New("document is not conflicted")
	}
	return nil
}

func (a *Application) OverwriteDisk(id DocumentID) error {
	doc := a.Documents[id]
	if doc == nil {
		return errors.New("unknown document")
	}
	version, err := a.Store.Save(doc.Path, doc.Editor.Buffer.Text(), doc.FileMode)
	if err != nil {
		return err
	}
	doc.DiskVersion = version
	doc.MarkSaved()
	delete(a.Conflicts, id)
	return nil
}

func (a *Application) SaveActive() error {
	doc := a.ActiveDocument()
	if doc == nil {
		return errors.New("no active document")
	}
	if _, ok := a.Conflicts[a.Active]; ok {
		return ErrConflict
	}
	status, err := a.Reconcile(a.Active)
	if err != nil {
		return err
	}
	if status == StatusConflict {
		return ErrConflict
	}
	return doc.Save(a.Store)
}

func (a *Application) SaveAs(id DocumentID, path string) error {
	doc := a.Documents[id]
	if doc == nil {
		return errors.New("unknown document")
	}
	if err := doc.SaveAs(a.Store, path); err != nil {
		return err
	}
	newID := documentID(doc.Path)
	if newID != id {
		delete(a.Documents, id)
		a.Documents[newID] = doc
		for i, existing := range a.Order {
			if existing == id {
				a.Order[i] = newID
			}
		}
		a.Views[newID] = a.Views[id]
		delete(a.Views, id)
		if a.Active == id {
			a.Active = newID
		}
	}
	delete(a.Conflicts, id)
	return nil
}

func (a *Application) ReconcileStale() {
	for id := range a.Stale {
		_, _ = a.Reconcile(id)
	}
}

func (a *Application) Activate(id DocumentID) bool {
	if _, ok := a.Documents[id]; !ok {
		return false
	}
	a.Active = id
	return true
}

func (a *Application) ActiveDocument() *document.Document {
	if a == nil {
		return nil
	}
	return a.Documents[a.Active]
}

func (a *Application) Reorder(order []DocumentID) error {
	if len(order) != len(a.Order) {
		return errors.New("document order does not contain every open document")
	}
	seen := make(map[DocumentID]bool, len(order))
	for _, id := range order {
		if seen[id] {
			return fmt.Errorf("duplicate document id %q", id)
		}
		if _, ok := a.Documents[id]; !ok {
			return fmt.Errorf("unknown document id %q", id)
		}
		seen[id] = true
	}
	a.Order = append(a.Order[:0], order...)
	return nil
}

func documentID(path string) DocumentID {
	abs, err := filepath.Abs(path)
	if err != nil {
		return DocumentID(filepath.Clean(path))
	}
	abs = filepath.Clean(abs)
	if resolved, err := filepath.EvalSymlinks(abs); err == nil {
		abs = filepath.Clean(resolved)
	}
	return DocumentID(abs)
}
