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
var ErrDirty = errors.New("document has unsaved changes")
var ErrDocumentAlreadyOpen = errors.New("destination document is already open")
var ErrSaveAsDestinationExists = errors.New("save-as destination already exists")

// SaveAsDestinationExistsError reports an existing, unopened Save As target
// and the verified version that the user must confirm before it can be
// replaced. Keeping the version on the error makes the confirmation
// conditional on the exact bytes seen by the initial request.
type SaveAsDestinationExistsError struct {
	Path    string
	Version workspace.DiskVersion
}

func (e *SaveAsDestinationExistsError) Error() string {
	if e == nil {
		return ErrSaveAsDestinationExists.Error()
	}
	return fmt.Sprintf("%s: %s", ErrSaveAsDestinationExists, e.Path)
}

func (e *SaveAsDestinationExistsError) Unwrap() error { return ErrSaveAsDestinationExists }

type Conflict struct {
	Base        []byte
	Disk        []byte
	DiskVersion workspace.DiskVersion
	DiskMode    os.FileMode
}

type ViewState struct {
	ScrollY            float32
	ScrollInitialized  bool
	ScrollX            float32
	ScrollXInitialized bool
	CollapsedHeadings  map[int]bool
	LastRevision       uint64
}

type Application struct {
	Store                 workspace.FileStore
	Workspace             workspace.Workspace
	HasWorkspace          bool
	Documents             map[DocumentID]*document.Document
	Order                 []DocumentID
	Active                DocumentID
	Views                 map[DocumentID]ViewState
	Watcher               workspace.Watcher
	watchEvents           <-chan workspace.WatchEvent
	Stale                 map[DocumentID]bool
	Conflicts             map[DocumentID]Conflict
	RecoveryDir           string
	recoveryWritesBlocked bool
	lastRecovery          time.Time
	recoveryRunning       bool
	recoveryDone          chan error
	derived               map[DocumentID]*projectionState
	derivedResults        chan projectionResult
	derivedRunning        int
	derivedWake           func()
	derivedAfterFunc      func(time.Duration, func())
	derivedWakeScheduled  int32
	recent                []string
	closed                []string
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
	id := documentID(path)
	if _, ok := a.Documents[id]; ok {
		a.Active = id
		a.recordRecent(a.Documents[id].Path)
		return nil
	}
	snapshot, err := a.Store.Load(path)
	if err != nil {
		return err
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
	a.recordRecent(doc.Path)
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
		// Drop advisory hints for unknown IDs so ReconcileStale (which ranges
		// over Stale and calls Reconcile) cannot retry them forever. This
		// covers stale hints left behind by identity changes.
		delete(a.Stale, id)
		return StatusMissing, errors.New("unknown document")
	}
	snapshot, err := a.Store.Load(doc.Path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			// One hint = one Load: consume the hint so a still-missing file
			// does not cause a Load every frame. The next watcher event
			// re-adds the hint if the file reappears/changes.
			// NOTE: Status() is intentionally left unchanged (sync, no IO):
			// the UI only handles StatusConflict/StatusSynced, so surfacing
			// Missing there would alter the close path with no handler.
			delete(a.Stale, id)
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
	if state := a.derived[id]; state != nil {
		state.closed = true
		if !state.running && state.runtime != nil {
			state.runtime.Close()
			delete(a.derived, id)
		}
	}
	return nil
}

// RecentPaths returns the most recently opened file paths, newest first. The
// list is metadata only; document contents never enter it.
func (a *Application) RecentPaths() []string {
	return append([]string(nil), a.recent...)
}

// RecentlyClosedPaths returns paths eligible for ReopenClosed, newest first.
func (a *Application) RecentlyClosedPaths() []string {
	return append([]string(nil), a.closed...)
}

// ReopenClosed reopens the newest closed file that still exists. A failed
// reopen remains available so a transient filesystem problem is not destructive.
func (a *Application) ReopenClosed() error {
	if len(a.closed) == 0 {
		return errors.New("no closed document")
	}
	path := a.closed[0]
	if err := a.OpenPath(path); err != nil {
		return err
	}
	a.closed = a.closed[1:]
	return nil
}

func (a *Application) recordRecent(path string) {
	path = filepath.Clean(path)
	for i, existing := range a.recent {
		if existing == path {
			a.recent = append(a.recent[:i], a.recent[i+1:]...)
			break
		}
	}
	a.recent = append([]string{path}, a.recent...)
	if len(a.recent) > 20 {
		a.recent = a.recent[:20]
	}
}

func (a *Application) recordClosed(path string) {
	path = filepath.Clean(path)
	for i, existing := range a.closed {
		if existing == path {
			a.closed = append(a.closed[:i], a.closed[i+1:]...)
			break
		}
	}
	a.closed = append([]string{path}, a.closed...)
	if len(a.closed) > 20 {
		a.closed = a.closed[:20]
	}
}

func (a *Application) OverwriteDisk(id DocumentID) error {
	doc := a.Documents[id]
	if doc == nil {
		return errors.New("unknown document")
	}
	conflict, ok := a.Conflicts[id]
	if !ok {
		return errors.New("document is not conflicted")
	}
	snapshot, err := a.Store.Load(doc.Path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return errors.New("file missing on disk")
		}
		return err
	}
	if !snapshot.Version.Equal(conflict.DiskVersion) {
		a.Conflicts[id] = Conflict{
			Base:        append([]byte(nil), doc.BaseSnapshot()...),
			Disk:        append([]byte(nil), snapshot.Data...),
			DiskVersion: snapshot.Version, DiskMode: snapshot.Mode,
		}
		return document.ErrDiskChanged
	}
	version, err := a.Store.Save(doc.Path, doc.Editor.Buffer.Text(), doc.FileMode)
	if err != nil {
		if errors.Is(err, workspace.ErrParentDirSync) && version.Verified {
			doc.MarkOverwritten(version)
			delete(a.Conflicts, id)
			delete(a.Stale, id)
			a.refreshRecoveryAfterSave()
		}
		return err
	}
	doc.MarkOverwritten(version)
	delete(a.Conflicts, id)
	delete(a.Stale, id)
	a.refreshRecoveryAfterSave()
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
	beforePath, beforeVersion, beforeDirty := doc.Path, doc.DiskVersion, doc.Dirty()
	if err := doc.Save(a.Store); err != nil {
		// ErrParentDirSync means the replacement completed when Document was
		// able to adopt the verified post-write version. Finish the same
		// application-level bookkeeping as a clean save before surfacing the
		// durability warning to the caller.
		if !committedDurabilityWarning(err, doc, beforePath, beforeVersion, beforeDirty) {
			return err
		}
		a.refreshRecoveryAfterSave()
		return err
	}
	a.refreshRecoveryAfterSave()
	return nil
}

func (a *Application) SaveDocument(id DocumentID) error {
	previous := a.Active
	if !a.Activate(id) {
		return errors.New("unknown document")
	}
	err := a.SaveActive()
	a.Active = previous
	return err
}

func (a *Application) SaveAs(id DocumentID, path string) error {
	return a.saveAs(id, path, nil)
}

// ConfirmSaveAs replaces an existing Save As destination only when its
// verified version still matches the version returned by SaveAs. This keeps a
// later external edit from being overwritten by an earlier confirmation.
func (a *Application) ConfirmSaveAs(id DocumentID, path string, expected workspace.DiskVersion) error {
	return a.saveAs(id, path, &expected)
}

func (a *Application) saveAs(id DocumentID, path string, expected *workspace.DiskVersion) error {
	doc := a.Documents[id]
	if doc == nil {
		return errors.New("unknown document")
	}
	// Resolve the destination before writing it. SaveAs changes the document's
	// identity, so allowing an already-open destination would replace that
	// document in Documents and leave a duplicate ID in Order. documentID also
	// resolves existing symlinks, keeping aliases covered by this check.
	newID := documentID(path)
	if newID == id {
		// A Save As to the current document (including a symlink alias) is an
		// ordinary save. In particular, do not use Document.SaveAs here: it
		// skips the current-path version check and could overwrite external
		// edits that a normal Save would reject.
		if _, ok := a.Conflicts[id]; ok {
			return ErrConflict
		}
		status, err := a.Reconcile(id)
		if err != nil {
			return err
		}
		if status == StatusConflict {
			return ErrConflict
		}
		beforePath, beforeVersion, beforeDirty := doc.Path, doc.DiskVersion, doc.Dirty()
		saveErr := doc.Save(a.Store)
		if saveErr != nil && !committedDurabilityWarning(saveErr, doc, beforePath, beforeVersion, beforeDirty) {
			return saveErr
		}
		a.completeSaveAs(id, doc, beforePath)
		a.refreshRecoveryAfterSave()
		return saveErr
	}
	if newID != id {
		if _, exists := a.Documents[newID]; exists {
			return ErrDocumentAlreadyOpen
		}
		destination, err := a.Store.Verify(filepath.Clean(path))
		if err != nil {
			return err
		}
		if destination.Exists {
			if expected == nil {
				return &SaveAsDestinationExistsError{Path: filepath.Clean(path), Version: destination}
			}
			if !destination.EqualForReplacement(*expected) {
				return fmt.Errorf("%w: save-as destination changed", document.ErrDiskChanged)
			}
		} else {
			if expected != nil {
				return fmt.Errorf("%w: save-as destination was removed", document.ErrDiskChanged)
			}
			// Carry the observed missing version into the write. This protects
			// a new destination from being created by another actor after the
			// preflight and before replacement.
			expected = &destination
		}
	}
	beforePath, beforeVersion, beforeDirty := doc.Path, doc.DiskVersion, doc.Dirty()
	var saveErr error
	if expected != nil {
		saveErr = doc.SaveAsIfVersion(a.Store, path, *expected)
		if errors.Is(saveErr, workspace.ErrVersionChanged) {
			saveErr = fmt.Errorf("%w: save-as destination changed", document.ErrDiskChanged)
		}
	} else {
		saveErr = doc.SaveAs(a.Store, path)
	}
	if saveErr != nil && !committedDurabilityWarning(saveErr, doc, beforePath, beforeVersion, beforeDirty) {
		return saveErr
	}
	a.completeSaveAs(id, doc, beforePath)
	a.refreshRecoveryAfterSave()
	return saveErr
}

// committedDurabilityWarning identifies the one save error that still leaves
// the document committed. Document adopts the verified post-write version
// before returning ErrParentDirSync, so a clean document is the application
// level proof that the replacement completed and bookkeeping may proceed.
func committedDurabilityWarning(err error, doc *document.Document, beforePath string, beforeVersion workspace.DiskVersion, beforeDirty bool) bool {
	if !errors.Is(err, workspace.ErrParentDirSync) || doc == nil || doc.Dirty() {
		return false
	}
	return beforeDirty || doc.Path != beforePath || doc.DiskVersion != beforeVersion
}

// completeSaveAs applies all application state changes that follow a
// committed Save As. It is deliberately shared by successful saves and
// committed durability warnings so callers cannot expose the warning before
// the document registry, watcher, and recovery state agree on the new path.
func (a *Application) completeSaveAs(id DocumentID, doc *document.Document, beforePath string) {
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
		// Close (don't migrate) derived state for the old identity, mirroring
		// CloseDocument/ReloadDisk. PollDerived recreates state for newID on
		// demand and reaps the closed entry without leaking goroutines.
		if state := a.derived[id]; state != nil {
			state.closed = true
			if !state.running && state.runtime != nil {
				state.runtime.Close()
				delete(a.derived, id)
			}
		}
	}
	if a.Watcher != nil && filepath.Clean(filepath.Dir(beforePath)) != filepath.Clean(filepath.Dir(doc.Path)) {
		// Save As may move the document to a directory that was not watched
		// when it was opened. Watch setup is best-effort: it cannot undo a
		// committed replacement, and recovery still records the new path.
		_ = a.Watcher.WatchDirectory(filepath.Dir(doc.Path))
	}
	a.recordRecent(doc.Path)
	delete(a.Conflicts, id)
	// Consume any stale hint for the old identity (identity change) and for
	// the same identity (SaveAs overwrote disk, so the hint is obsolete).
	delete(a.Stale, id)
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

func (a *Application) Cycle(delta int) {
	if len(a.Order) == 0 {
		return
	}
	current := 0
	for i, id := range a.Order {
		if id == a.Active {
			current = i
			break
		}
	}
	current = (current + delta) % len(a.Order)
	if current < 0 {
		current += len(a.Order)
	}
	a.Active = a.Order[current]
}

// CloseDocument removes a document only when its unsaved state has been
// explicitly handled by the caller. Tabs are application views, so closing a
// tab never changes the document's content authority before this check.
func (a *Application) CloseDocument(id DocumentID, discard bool) error {
	doc := a.Documents[id]
	if doc == nil {
		return errors.New("unknown document")
	}
	if doc.Dirty() && !discard {
		return ErrDirty
	}
	delete(a.Documents, id)
	delete(a.Views, id)
	delete(a.Stale, id)
	delete(a.Conflicts, id)
	if state := a.derived[id]; state != nil {
		state.closed = true
		if !state.running && state.runtime != nil {
			state.runtime.Close()
			delete(a.derived, id)
		}
	}
	for i, existing := range a.Order {
		if existing == id {
			a.Order = append(a.Order[:i], a.Order[i+1:]...)
			break
		}
	}
	if a.Active == id {
		a.Active = ""
		if len(a.Order) > 0 {
			a.Active = a.Order[len(a.Order)-1]
		}
	}
	a.recordClosed(doc.Path)
	return nil
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
