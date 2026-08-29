// Package document contains product-owned document state and deliberately has
// no Shirei dependency.
package document

import (
	"errors"
	"io/fs"
	"path/filepath"

	"scratchpad/editor"
	"scratchpad/workspace"
)

var ErrDiskChanged = errors.New("file changed on disk")

// Document is the product-owned identity and revision shell around the one
// authoritative editable text state. The editor contains the bytes; Document
// never keeps a second complete content copy.
type Document struct {
	Path             string
	Editor           *editor.ScratchEditor
	SavedRevision    uint64
	DiskVersion      workspace.DiskVersion
	FileMode         fs.FileMode
	Format           FileFormat
	RootLanguage     string
	Injected         []InjectedRegion
	Projections      Projections
	DerivedRevision  uint64
	observedRevision uint64
	base             []byte
}

// DiskVersion is kept as a document-package alias so callers can describe
// persistence state without depending on the concrete workspace adapter.
type DiskVersion = workspace.DiskVersion

// FileFormat records byte-preserving presentation facts. The bytes remain in
// the editor buffer; this metadata only describes how they should be shown or
// interpreted by future explicit encoding commands.
type FileFormat struct {
	UTF8BOM  bool
	Encoding string
}

// InjectedRegion identifies a nested-language region without tying the
// document model to a parser implementation.
type InjectedRegion struct {
	StartByte int
	EndByte   int
	Language  string
}

// Projections are derived views. They are not authoritative document data and
// can be discarded and rebuilt after a revision changes.
type Projections struct {
	Revision uint64
	Valid    bool
	Symbols  []Symbol
	Folds    []Fold
}

type Symbol struct {
	Name      string
	StartByte int
	EndByte   int
}

type Fold struct {
	StartByte int
	EndByte   int
}

// New creates a document with one editor-owned copy of source.
func New(path string, source []byte, rootLanguage string) *Document {
	cleanPath := filepath.Clean(path)
	if path == "" {
		cleanPath = ""
	}
	return &Document{
		Path:             cleanPath,
		Editor:           editor.NewScratchEditor(source),
		RootLanguage:     rootLanguage,
		SavedRevision:    0,
		observedRevision: 0,
	}
}

// NewLoaded creates a clean document from a verified filesystem snapshot.
// The snapshot bytes are transferred into the editor and are not retained as
// a second document-content authority.
func NewLoaded(path string, source []byte, version workspace.DiskVersion, mode fs.FileMode, rootLanguage string) *Document {
	doc := New(path, source, rootLanguage)
	doc.DiskVersion = version
	doc.FileMode = mode
	doc.Format = DetectFormat(source)
	doc.base = append([]byte(nil), source...)
	doc.MarkSaved()
	return doc
}

func DetectFormat(source []byte) FileFormat {
	return FileFormat{
		UTF8BOM:  len(source) >= 3 && source[0] == 0xef && source[1] == 0xbb && source[2] == 0xbf,
		Encoding: "utf-8",
	}
}

// Revision returns the editor's current byte-state revision.
func (d *Document) Revision() uint64 {
	if d == nil || d.Editor == nil {
		return 0
	}
	return d.Editor.Revision()
}

// Dirty reports whether the in-memory document differs from the last saved
// revision.
func (d *Document) Dirty() bool {
	return d.Revision() != d.SavedRevision
}

// ReplaceText replaces the entire editable state through the same editor
// contract used for ordinary edits. It is useful for initial reload and test
// seams; it does not create a second source authority.
func (d *Document) ReplaceText(source []byte) error {
	d.Editor.SelectAll()
	if err := d.Editor.Insert(source); err != nil {
		return err
	}
	d.InvalidateDerived()
	return nil
}

// Reload replaces the editor state with freshly loaded bytes and marks that
// state clean. It is intentionally not undoable because it is a filesystem
// synchronization operation rather than a user edit.
func (d *Document) Reload(source []byte, version workspace.DiskVersion, mode fs.FileMode) {
	d.Editor.Reset(source)
	d.DiskVersion = version
	d.FileMode = mode
	d.Format = DetectFormat(source)
	d.base = append([]byte(nil), source...)
	d.SavedRevision = d.Revision()
	d.observedRevision = d.Revision()
	d.InvalidateDerived()
}

// SyncEditorState records edits made through the visual editor adapter and
// invalidates derived projections without copying the editor contents.
func (d *Document) SyncEditorState() {
	if d == nil || d.Editor == nil || d.observedRevision == d.Revision() {
		return
	}
	d.observedRevision = d.Revision()
	d.InvalidateDerived()
}

// Insert delegates a byte edit to the authoritative editor and invalidates
// derived state when the document revision changes.
func (d *Document) Insert(source []byte) error {
	before := d.Revision()
	if err := d.Editor.Insert(source); err != nil {
		return err
	}
	if d.Revision() != before {
		d.observedRevision = d.Revision()
		d.InvalidateDerived()
	}
	return nil
}

// Delete delegates a byte edit to the authoritative editor and invalidates
// derived state when the document revision changes.
func (d *Document) Delete(start, end int) error {
	if d == nil || d.Editor == nil || start < 0 || end < start || end > d.Editor.Buffer.ByteLen() {
		return errors.New("document delete range outside buffer")
	}
	before := d.Revision()
	d.Editor.SetSelection(start, end)
	if err := d.Editor.Insert(nil); err != nil {
		return err
	}
	if d.Revision() != before {
		d.observedRevision = d.Revision()
		d.InvalidateDerived()
	}
	return nil
}

// InvalidateDerived discards projections that no longer describe the current
// editor revision. Callers may also leave old values in place, but they must
// treat DerivedCurrent as the validity check.
func (d *Document) InvalidateDerived() {
	d.DerivedRevision = 0
	d.Injected = nil
	d.Projections.Valid = false
}

// DerivedCurrent reports whether disposable projections match current text.
func (d *Document) DerivedCurrent() bool {
	return d != nil && d.DerivedRevision == d.Revision() && d.Projections.Valid && d.Projections.Revision == d.Revision()
}

// SetDerived records projections against one immutable editor revision.
func (d *Document) SetDerived(injected []InjectedRegion, projections Projections) bool {
	if d == nil || projections.Revision != d.Revision() {
		return false
	}
	projections.Valid = true
	d.Injected = injected
	d.Projections = projections
	d.DerivedRevision = d.Revision()
	return true
}

// MarkSaved records that the current revision has been persisted.
func (d *Document) MarkSaved() {
	d.SavedRevision = d.Revision()
	d.observedRevision = d.Revision()
}

// Save persists the current authoritative buffer and changes saved metadata
// only after the filesystem operation succeeds.
func (d *Document) Save(store workspace.FileStore) error {
	if d == nil || d.Editor == nil || d.Path == "" {
		return errors.New("document has no save path")
	}
	disk, err := store.Verify(d.Path)
	if err != nil {
		return err
	}
	if !d.DiskVersion.Equal(disk) {
		return ErrDiskChanged
	}
	version, err := store.Save(d.Path, d.Editor.Buffer.Text(), d.FileMode)
	if err != nil {
		return err
	}
	d.DiskVersion = version
	d.MarkSaved()
	d.base = d.Editor.Buffer.Text()
	return nil
}

// SaveAs persists the current buffer at a new path. The document path changes
// only after the replacement succeeds.
func (d *Document) SaveAs(store workspace.FileStore, path string) error {
	if d == nil || d.Editor == nil || path == "" {
		return errors.New("document has no save-as path")
	}
	version, err := store.Save(path, d.Editor.Buffer.Text(), d.FileMode)
	if err != nil {
		return err
	}
	d.Path = filepath.Clean(path)
	d.DiskVersion = version
	d.MarkSaved()
	d.base = d.Editor.Buffer.Text()
	return nil
}

// BaseSnapshot returns the originally loaded bytes for transient conflict
// comparison. It is never used as the editor's content authority.
func (d *Document) BaseSnapshot() []byte {
	if d == nil {
		return nil
	}
	return append([]byte(nil), d.base...)
}
