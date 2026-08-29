// Package document contains product-owned document state and deliberately has
// no Shirei dependency.
package document

import (
	"errors"
	"path/filepath"
	"time"

	"scratchpad/editor"
)

// Document is the product-owned identity and revision shell around the one
// authoritative editable text state. The editor contains the bytes; Document
// never keeps a second complete content copy.
type Document struct {
	Path            string
	Editor          *editor.ScratchEditor
	SavedRevision   uint64
	DiskVersion     DiskVersion
	RootLanguage    string
	Injected        []InjectedRegion
	Projections     Projections
	DerivedRevision uint64
}

// DiskVersion is the small file identity snapshot needed by the document
// seam. It is evidence for future external-change policy, not that policy
// itself.
type DiskVersion struct {
	Exists  bool
	Size    int64
	ModTime time.Time
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
		Path:          cleanPath,
		Editor:        editor.NewScratchEditor(source),
		RootLanguage:  rootLanguage,
		SavedRevision: 0,
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

// Insert delegates a byte edit to the authoritative editor and invalidates
// derived state when the document revision changes.
func (d *Document) Insert(source []byte) error {
	before := d.Revision()
	if err := d.Editor.Insert(source); err != nil {
		return err
	}
	if d.Revision() != before {
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
}
