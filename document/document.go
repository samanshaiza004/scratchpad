// Package document contains product-owned document state and deliberately has
// no Shirei dependency.
package document

import "path/filepath"

// Document is the small domain object used by the scaffold. Source is a
// provisional byte slice so the file-native model can be tested now; Gate B
// must decide whether it becomes a gap buffer, piece tree, rope, or another
// representation before serious editing is implemented.
type Document struct {
	Path          string
	Source        []byte
	RootLanguage  string
	Injected      []InjectedRegion
	Projections   Projections
	Revision      uint64
	SavedRevision uint64
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
	Symbols []Symbol
	Folds   []Fold
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

// New creates a document and takes ownership of a copy of source.
func New(path string, source []byte, rootLanguage string) Document {
	cleanPath := filepath.Clean(path)
	if path == "" {
		cleanPath = ""
	}
	return Document{
		Path:          cleanPath,
		Source:        append([]byte(nil), source...),
		RootLanguage:  rootLanguage,
		SavedRevision: 0,
	}
}

// Dirty reports whether the in-memory document differs from the last saved
// revision.
func (d Document) Dirty() bool {
	return d.Revision != d.SavedRevision
}

// ReplaceSource is a small scaffold operation, not the eventual editing
// primitive. It keeps the revision bookkeeping explicit while Gate B is open.
func (d *Document) ReplaceSource(source []byte) {
	d.Source = append(d.Source[:0], source...)
	d.Revision++
	d.Projections = Projections{}
	d.Injected = nil
}

// MarkSaved records that the current revision has been persisted.
func (d *Document) MarkSaved() {
	d.SavedRevision = d.Revision
}
