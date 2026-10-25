// Package application owns the product's open-document registry and active
// application state. It deliberately contains no frontend dependency.
package application

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"scratchpad/document"
	"scratchpad/language"
	"scratchpad/workspace"
)

type DocumentID string

type DocumentStatus uint8

type FileViewKind string

const (
	FileViewText        FileViewKind = "text"
	FileViewImage       FileViewKind = "image"
	FileViewUnsupported FileViewKind = "unsupported"
)

// FileView carries only stable metadata for non-text tabs. Encoded bytes are
// fetched explicitly through ImagePreviewBytes when the image tab is active.
type FileView struct {
	Kind     FileViewKind
	Format   string
	Revision uint64
	Width    uint32
	Height   uint32
	Error    string
	Version  workspace.DiskVersion
}

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
var ErrReadOnlyFileView = errors.New("preview documents are read-only")

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
	Density            ViewDensity `json:"density,omitempty"`
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
	SidebarWidth          float32
	SessionUI             SessionUI
	Documents             map[DocumentID]*document.Document
	FileViews             map[DocumentID]FileView
	Order                 []DocumentID
	Active                DocumentID
	Preview               DocumentID
	Views                 map[DocumentID]ViewState
	Watcher               workspace.Watcher
	Trasher               workspace.Trasher
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
	derivedWakeMu         sync.RWMutex
	derivedWake           func()
	derivedWorkers        sync.WaitGroup
	derivedClosed         bool
	derivedAfterFunc      func(time.Duration, func())
	derivedWakeScheduled  int32
	recent                []string
	recentWorkspaces      []string
	closed                []string
	presentationRevision  uint64
	projectionGeneration  uint64
	semanticViews         map[DocumentID]semanticViewCache
	pinned                pinnedSurface
}

func New(store workspace.FileStore) *Application {
	if store == nil {
		store = workspace.NewOSFileStore()
	}
	return &Application{
		Store:                store,
		SidebarWidth:         250,
		Documents:            make(map[DocumentID]*document.Document),
		FileViews:            make(map[DocumentID]FileView),
		Views:                make(map[DocumentID]ViewState),
		semanticViews:        make(map[DocumentID]semanticViewCache),
		Stale:                make(map[DocumentID]bool),
		Conflicts:            make(map[DocumentID]Conflict),
		recoveryDone:         make(chan error, 1),
		presentationRevision: 1,
		pinned:               pinnedSurface{epoch: 1, revision: 1},
	}
}

func (a *Application) touchPresentation() {
	if a.presentationRevision != ^uint64(0) {
		a.presentationRevision++
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

// OpenPreviewPath opens a path in the single replaceable preview slot used by
// workspace browsing. Explicit OpenPath/OpenDocument calls remain pinned.
// A clean previous preview is replaced only after the new document loads
// successfully; a dirty preview is retained and promoted to a normal tab.
func (a *Application) OpenPreviewPath(path string) error {
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

	id := documentID(abs)
	if doc := a.Documents[id]; doc != nil {
		if a.Preview == id && doc.Dirty() {
			a.PinPreview(id)
		}
		a.Active = id
		a.recordRecent(doc.Path)
		a.touchPresentation()
		return nil
	}

	// Load before retiring the old preview, so a transient I/O failure never
	// makes the current document disappear.
	doc, fileView, err := a.loadDocumentView(abs)
	if err != nil {
		return err
	}
	if previous := a.Preview; previous != "" {
		if old := a.Documents[previous]; old != nil && old.Dirty() {
			a.PinPreview(previous)
		} else if old != nil {
			if err := a.closeDocument(previous, false, false); err != nil {
				return err
			}
		} else {
			a.Preview = ""
		}
	}
	a.Documents[id] = doc
	if fileView.Kind != FileViewText {
		a.FileViews[id] = fileView
	}
	a.Order = append(a.Order, id)
	a.Views[id] = ViewState{}
	a.Active = id
	a.Preview = id
	a.touchPresentation()
	if a.Watcher != nil {
		if err := a.Watcher.WatchDirectory(filepath.Dir(doc.Path)); err != nil {
			return err
		}
	}
	a.recordRecent(doc.Path)
	return nil
}

// PinPreview makes a preview document persistent without changing its active
// state. It is a no-op for documents that are not the current preview.
func (a *Application) PinPreview(id DocumentID) bool {
	if a == nil || id == "" || a.Preview != id {
		return false
	}
	a.Preview = ""
	a.touchPresentation()
	return true
}

// PinDirtyPreview promotes a preview after application-owned content changes.
// Frontends that edit documents directly call this after handling input.
func (a *Application) PinDirtyPreview() bool {
	if a == nil || a.Preview == "" {
		return false
	}
	doc := a.Documents[a.Preview]
	if doc != nil && !doc.Dirty() {
		return false
	}
	return a.PinPreview(a.Preview)
}

func (a *Application) OpenWorkspace(path string) error {
	ws, err := workspace.Open(path)
	if err != nil {
		return err
	}
	if !a.HasWorkspace || !workspacePathsEqual(a.Workspace.Root, ws.Root) {
		if err := a.ClearPinnedRanges(); err != nil {
			return err
		}
	}
	a.Workspace = ws
	a.HasWorkspace = true
	a.recordRecentWorkspace(ws.Root)
	a.touchPresentation()
	return nil
}

func (a *Application) OpenDocument(path string) error {
	if a == nil {
		return errors.New("nil application")
	}
	id := documentID(path)
	if _, ok := a.Documents[id]; ok {
		a.PinPreview(id)
		a.Active = id
		a.recordRecent(a.Documents[id].Path)
		a.touchPresentation()
		return nil
	}
	doc, fileView, err := a.loadDocumentView(path)
	if err != nil {
		return err
	}
	a.Documents[id] = doc
	if fileView.Kind != FileViewText {
		a.FileViews[id] = fileView
	}
	a.Order = append(a.Order, id)
	a.Views[id] = ViewState{}
	a.Active = id
	a.touchPresentation()
	if a.Watcher != nil {
		if err := a.Watcher.WatchDirectory(filepath.Dir(doc.Path)); err != nil {
			return err
		}
	}
	a.recordRecent(doc.Path)
	return nil
}

func (a *Application) loadDocumentView(path string) (*document.Document, FileView, error) {
	snapshot, err := a.Store.Load(path)
	if err == nil {
		return document.NewLoaded(snapshot.Path, snapshot.Data, snapshot.Version, snapshot.Mode, string(language.DetectPath(snapshot.Path))), FileView{Kind: FileViewText}, nil
	}
	var unsupported *workspace.UnsupportedTextFileError
	if !errors.As(err, &unsupported) {
		return nil, FileView{}, err
	}
	imageStore, ok := a.Store.(workspace.ImageFileStore)
	if !ok {
		doc := document.NewLoaded(filepath.Clean(path), nil, workspace.DiskVersion{}, 0, "")
		return doc, FileView{Kind: FileViewUnsupported, Error: unsupported.Reason}, nil
	}
	image, imageErr := inspectImageStore(a.Store, imageStore, path)
	if imageErr != nil {
		return nil, FileView{}, imageErr
	}
	kind := FileViewUnsupported
	revision := uint64(0)
	if image.Format != "" {
		kind, revision = FileViewImage, 1
	}
	view := FileView{Kind: kind, Format: image.Format, Revision: revision, Width: image.Width, Height: image.Height, Error: image.Error, Version: image.Version}
	doc := document.NewLoaded(image.Path, nil, image.Version, image.Mode, "")
	return doc, view, nil
}

func inspectImageStore(store workspace.FileStore, images workspace.ImageFileStore, path string) (workspace.ImageFileSnapshot, error) {
	if metadata, ok := store.(workspace.ImageMetadataStore); ok {
		return metadata.InspectImage(path)
	}
	return images.LoadImage(path)
}

// ImageReadRequest is an immutable snapshot that may be read on a worker
// without holding the application's lifecycle lock. The caller revalidates the
// document/revision before publishing its resource.
type ImageReadRequest struct {
	Path    string
	Version workspace.DiskVersion
	store   workspace.ImageFileStore
}

func (a *Application) ImagePreviewRequest(id DocumentID, revision uint64) (ImageReadRequest, error) {
	doc := a.Documents[id]
	view, ok := a.FileViews[id]
	if doc == nil || !ok || view.Kind != FileViewImage {
		return ImageReadRequest{}, errors.New("document is not an image preview")
	}
	if revision == 0 || view.Revision != revision {
		return ImageReadRequest{}, errors.New("image preview changed; refresh the document state")
	}
	if view.Error != "" {
		return ImageReadRequest{}, errors.New(view.Error)
	}
	store, ok := a.Store.(workspace.ImageFileStore)
	if !ok {
		return ImageReadRequest{}, errors.New("image preview is unavailable from this file store")
	}
	return ImageReadRequest{Path: doc.Path, Version: view.Version, store: store}, nil
}

func (request ImageReadRequest) Read() ([]byte, error) {
	image, err := request.store.LoadImage(request.Path)
	if err != nil {
		return nil, err
	}
	if image.Error != "" {
		return nil, errors.New(image.Error)
	}
	if image.Format == "" || !request.Version.Equal(image.Version) {
		return nil, errors.New("image changed while it was being opened; retry the preview")
	}
	return image.Data, nil
}

// ImagePreviewBytes reads only the currently opened image tab's encoded bytes.
// The caller must provide the state revision it observed, preventing a stale
// frontend request from silently loading a newer external file version.
func (a *Application) ImagePreviewBytes(id DocumentID, revision uint64) ([]byte, error) {
	request, err := a.ImagePreviewRequest(id, revision)
	if err != nil {
		return nil, err
	}
	return request.Read()
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

// WatchEvents returns the single advisory event stream established by
// SetWatcher. Consumers must share it rather than call Watcher.Events again,
// which may create a competing reader and lose notifications.
func (a *Application) WatchEvents() <-chan workspace.WatchEvent {
	if a == nil {
		return nil
	}
	return a.watchEvents
}

// SetTrasher installs the platform-specific, reversible delete adapter. It
// is intentionally independent from Workspace so ordinary path mutations can
// remain portable and testable without pretending that rename is trash.
func (a *Application) SetTrasher(trasher workspace.Trasher) {
	a.Trasher = trasher
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
	if view, isFileView := a.FileViews[id]; isFileView {
		return a.reconcileFileView(id, doc, view)
	}
	snapshot, err := a.Store.Load(doc.Path)
	if err != nil {
		var unsupported *workspace.UnsupportedTextFileError
		if errors.As(err, &unsupported) {
			delete(a.Stale, id)
			// Reclassify a clean tab when another program replaces text with
			// a binary file. Never discard an unsaved editor buffer.
			if !doc.Dirty() {
				replacement, view, loadErr := a.loadDocumentView(doc.Path)
				if loadErr != nil {
					return StatusSynced, loadErr
				}
				a.Documents[id] = replacement
				if view.Kind != FileViewText {
					a.FileViews[id] = view
				}
				a.closeDerivedAfterPathChange(id)
				a.touchPresentation()
				return StatusSynced, nil
			}
			return StatusDirty, err
		}
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

func (a *Application) reconcileFileView(id DocumentID, doc *document.Document, view FileView) (DocumentStatus, error) {
	snapshot, err := a.Store.Load(doc.Path)
	if err == nil {
		a.Documents[id] = document.NewLoaded(snapshot.Path, snapshot.Data, snapshot.Version, snapshot.Mode, string(language.DetectPath(snapshot.Path)))
		delete(a.FileViews, id)
		delete(a.Stale, id)
		a.touchPresentation()
		return StatusSynced, nil
	}
	var unsupported *workspace.UnsupportedTextFileError
	if !errors.As(err, &unsupported) {
		if errors.Is(err, os.ErrNotExist) {
			delete(a.Stale, id)
			if view.Error != "File is missing on disk." {
				view.Error = "File is missing on disk."
				view.Revision++
				a.FileViews[id] = view
				a.touchPresentation()
			}
			return StatusMissing, nil
		}
		return a.fileViewReadFailure(id, view, err)
	}
	imageStore, ok := a.Store.(workspace.ImageFileStore)
	if !ok {
		delete(a.Stale, id)
		return StatusSynced, nil
	}
	image, imageErr := inspectImageStore(a.Store, imageStore, doc.Path)
	if imageErr != nil {
		return a.fileViewReadFailure(id, view, imageErr)
	}
	kind := FileViewUnsupported
	revision := uint64(0)
	if image.Format != "" {
		kind, revision = FileViewImage, view.Revision
		if revision == 0 {
			revision = 1
		}
	}
	changed := kind != view.Kind || image.Format != view.Format || image.Width != view.Width || image.Height != view.Height || image.Error != view.Error || !view.Version.Equal(image.Version)
	if !changed {
		delete(a.Stale, id)
		return StatusSynced, nil
	}
	if kind == FileViewImage && view.Kind == FileViewImage && revision < ^uint64(0) {
		revision++
	}
	view = FileView{Kind: kind, Format: image.Format, Revision: revision, Width: image.Width, Height: image.Height, Error: image.Error, Version: image.Version}
	a.FileViews[id] = view
	if image.Format != "" {
		a.Documents[id] = document.NewLoaded(image.Path, nil, image.Version, image.Mode, "")
	}
	delete(a.Stale, id)
	a.touchPresentation()
	return StatusSynced, nil
}

// One watcher hint causes one read attempt, even when access fails. Retrying
// waits for a new filesystem event instead of repeatedly doing I/O at idle.
func (a *Application) fileViewReadFailure(id DocumentID, view FileView, err error) (DocumentStatus, error) {
	delete(a.Stale, id)
	message := "Could not reload image preview: " + err.Error()
	if view.Error != message {
		view.Error = message
		if view.Revision < ^uint64(0) {
			view.Revision++
		}
		a.FileViews[id] = view
		a.touchPresentation()
	}
	return StatusSynced, err
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
	a.touchPresentation()
	if state := a.derived[id]; state != nil {
		state.closed = true
		if !state.running && state.runtime != nil {
			state.runtime.Close()
			delete(a.derived, id)
		}
	}
	a.refreshRecoverySnapshot()
	return nil
}

// RecentPaths returns the most recently opened file paths, newest first. The
// list is metadata only; document contents never enter it.
func (a *Application) RecentPaths() []string {
	return append([]string(nil), a.recent...)
}

// RecentWorkspaces returns the most recently opened workspace roots, newest first.
// It contains paths only and is bounded independently from recent files.
func (a *Application) RecentWorkspaces() []string {
	return append([]string(nil), a.recentWorkspaces...)
}

// SetRecentWorkspaces replaces the workspace history with a bounded copy of
// persisted path metadata. Paths are cleaned and duplicate roots are removed.
func (a *Application) SetRecentWorkspaces(paths []string) {
	if a == nil {
		return
	}
	cleanPaths := make([]string, 0, min(len(paths), maxRecentWorkspaces))
	for _, path := range paths {
		if path == "" {
			continue
		}
		abs, err := filepath.Abs(path)
		if err != nil {
			continue
		}
		clean := filepath.Clean(abs)
		duplicate := false
		for _, existing := range cleanPaths {
			if workspacePathsEqual(existing, clean) {
				duplicate = true
				break
			}
		}
		if duplicate {
			continue
		}
		cleanPaths = append(cleanPaths, clean)
		if len(cleanPaths) == maxRecentWorkspaces {
			break
		}
	}
	a.recentWorkspaces = cleanPaths
	a.touchPresentation()
}

// ClearRecentWorkspaces forgets the path-only workspace history.
func (a *Application) ClearRecentWorkspaces() bool {
	if a == nil || len(a.recentWorkspaces) == 0 {
		return false
	}
	a.recentWorkspaces = nil
	a.touchPresentation()
	return true
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

const maxRecentWorkspaces = 10

func (a *Application) recordRecentWorkspace(path string) {
	path = filepath.Clean(path)
	for i, existing := range a.recentWorkspaces {
		if workspacePathsEqual(existing, path) {
			a.recentWorkspaces = append(a.recentWorkspaces[:i], a.recentWorkspaces[i+1:]...)
			break
		}
	}
	a.recentWorkspaces = append([]string{path}, a.recentWorkspaces...)
	if len(a.recentWorkspaces) > maxRecentWorkspaces {
		a.recentWorkspaces = a.recentWorkspaces[:maxRecentWorkspaces]
	}
}

func workspacePathsEqual(left, right string) bool {
	if runtime.GOOS == "windows" {
		return strings.EqualFold(filepath.Clean(left), filepath.Clean(right))
	}
	return filepath.Clean(left) == filepath.Clean(right)
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
	if !snapshot.Version.EqualForReplacement(conflict.DiskVersion) {
		a.Conflicts[id] = Conflict{
			Base:        append([]byte(nil), doc.BaseSnapshot()...),
			Disk:        append([]byte(nil), snapshot.Data...),
			DiskVersion: snapshot.Version, DiskMode: snapshot.Mode,
		}
		a.touchPresentation()
		return document.ErrDiskChanged
	}
	conditional, ok := a.Store.(workspace.ConditionalFileStore)
	if !ok {
		return errors.New("file store does not support conditional save")
	}
	version, err := conditional.SaveIfVersion(doc.Path, doc.Editor.Buffer.Text(), doc.FileMode, conflict.DiskVersion)
	if errors.Is(err, workspace.ErrVersionChanged) {
		if latest, loadErr := a.Store.Load(doc.Path); loadErr == nil {
			a.Conflicts[id] = Conflict{
				Base:        append([]byte(nil), doc.BaseSnapshot()...),
				Disk:        append([]byte(nil), latest.Data...),
				DiskVersion: latest.Version, DiskMode: latest.Mode,
			}
		}
		a.touchPresentation()
		return document.ErrDiskChanged
	}
	if err != nil {
		if errors.Is(err, workspace.ErrParentDirSync) && version.Verified {
			doc.MarkOverwritten(version)
			delete(a.Conflicts, id)
			delete(a.Stale, id)
			a.refreshRecoverySnapshot()
		}
		return err
	}
	doc.MarkOverwritten(version)
	delete(a.Conflicts, id)
	delete(a.Stale, id)
	a.refreshRecoverySnapshot()
	return nil
}

func (a *Application) SaveActive() error {
	if _, readOnly := a.FileViews[a.Active]; readOnly {
		return ErrReadOnlyFileView
	}
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
		if errors.Is(err, document.ErrDiskChanged) {
			if latest, loadErr := a.Store.Load(doc.Path); loadErr == nil {
				a.Conflicts[a.Active] = Conflict{
					Base:        append([]byte(nil), doc.BaseSnapshot()...),
					Disk:        append([]byte(nil), latest.Data...),
					DiskVersion: latest.Version, DiskMode: latest.Mode,
				}
				delete(a.Stale, a.Active)
				a.touchPresentation()
				return ErrConflict
			}
			status, reconcileErr := a.Reconcile(a.Active)
			if reconcileErr == nil && status == StatusConflict {
				a.touchPresentation()
				return ErrConflict
			}
		}
		// ErrParentDirSync means the replacement completed when Document was
		// able to adopt the verified post-write version. Finish the same
		// application-level bookkeeping as a clean save before surfacing the
		// durability warning to the caller.
		if !committedDurabilityWarning(err, doc, beforePath, beforeVersion, beforeDirty) {
			return err
		}
		a.refreshRecoverySnapshot()
		a.touchPresentation()
		a.PinPreview(a.Active)
		return err
	}
	a.refreshRecoverySnapshot()
	a.touchPresentation()
	a.PinPreview(a.Active)
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
	if _, readOnly := a.FileViews[id]; readOnly {
		return ErrReadOnlyFileView
	}
	return a.saveAs(id, path, nil)
}

// ConfirmSaveAs replaces an existing Save As destination only when its
// verified version still matches the version returned by SaveAs. This keeps a
// later external edit from being overwritten by an earlier confirmation.
func (a *Application) ConfirmSaveAs(id DocumentID, path string, expected workspace.DiskVersion) error {
	return a.saveAs(id, path, &expected)
}

func (a *Application) saveAs(id DocumentID, path string, expected *workspace.DiskVersion) error {
	if _, readOnly := a.FileViews[id]; readOnly {
		return ErrReadOnlyFileView
	}
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
		a.refreshRecoverySnapshot()
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
	a.refreshRecoverySnapshot()
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
		delete(a.semanticViews, id)
		delete(a.semanticViews, newID)
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
		if a.Preview == id {
			a.Preview = newID
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
	a.touchPresentation()
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
	a.touchPresentation()
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
	a.touchPresentation()
}

// CloseDocument removes a document only when its unsaved state has been
// explicitly handled by the caller. Tabs are application views, so closing a
// tab never changes the document's content authority before this check.
func (a *Application) CloseDocument(id DocumentID, discard bool) error {
	return a.closeDocument(id, discard, true)
}

func (a *Application) closeDocument(id DocumentID, discard bool, rememberClosed bool) error {
	doc := a.Documents[id]
	if doc == nil {
		return errors.New("unknown document")
	}
	if doc.Dirty() && !discard {
		return ErrDirty
	}
	delete(a.Documents, id)
	delete(a.FileViews, id)
	delete(a.semanticViews, id)
	if a.Preview == id {
		a.Preview = ""
	}
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
	if rememberClosed {
		a.recordClosed(doc.Path)
	}
	a.touchPresentation()
	if doc.Dirty() && discard {
		a.refreshRecoverySnapshot()
	}
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
	a.touchPresentation()
	return nil
}

func documentID(path string) DocumentID {
	abs, err := filepath.Abs(path)
	if err != nil {
		return DocumentID(filepath.Clean(path))
	}
	abs = filepath.Clean(abs)
	// A destination may not exist yet during Save As or a planned move. Walk
	// up to the nearest existing ancestor, resolve that ancestor, then append
	// the missing suffix so identity is stable before and after the operation.
	missing := make([]string, 0, 4)
	for current := abs; ; current = filepath.Dir(current) {
		if resolved, resolveErr := filepath.EvalSymlinks(current); resolveErr == nil {
			abs = filepath.Clean(resolved)
			for i := len(missing) - 1; i >= 0; i-- {
				abs = filepath.Join(abs, missing[i])
			}
			break
		}
		parent := filepath.Dir(current)
		if parent == current {
			break
		}
		missing = append(missing, filepath.Base(current))
	}
	return DocumentID(abs)
}
