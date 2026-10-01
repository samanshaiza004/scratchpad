// Package document contains product-owned document state and deliberately has
// no Shirei dependency.
package document

import (
	"crypto/sha256"
	"errors"
	"io/fs"
	"path/filepath"
	"sort"

	"scratchpad/editor"
	"scratchpad/workspace"
)

var ErrDiskChanged = errors.New("file changed on disk")

// Document is the product-owned identity and revision shell around the one
// authoritative editable text state. The editor contains the bytes; Document
// never keeps a second complete content copy.
type Document struct {
	Path          string
	Editor        *editor.ScratchEditor
	SavedRevision uint64
	DiskVersion   workspace.DiskVersion
	FileMode      fs.FileMode
	Format        FileFormat
	RootLanguage  string
	Injected      []InjectedRegion
	Projections   Projections
	// DisplayCode is a paint-only syntax cache. It may be rebased to the
	// current revision while semantic projections are being recomputed.
	DisplayCode      CodeProjection
	hasDisplayCode   bool
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
	Revision      uint64
	Valid         bool
	Injected      []InjectedRegion
	Headings      []Heading
	Folds         []Fold
	Tasks         []Task
	Links         []Link
	Blocks        []BlockPresentation
	blockTreeMax  []int
	blockTreeSize int
	Markdown      MarkdownPresentation
	Tables        []TableProjection
	Code          CodeProjection
}

// IndexBlocks prepares parser-produced blocks for bounded viewport queries.
// It is called once when a projection is built, never from a paint/request
// path. Blocks may nest, so subtree maximum ends prune disjoint query ranges.
func (p *Projections) IndexBlocks() {
	if p == nil {
		return
	}
	sort.SliceStable(p.Blocks, func(i, j int) bool {
		return p.Blocks[i].StartByte < p.Blocks[j].StartByte
	})
	p.blockTreeSize = 1
	for p.blockTreeSize < len(p.Blocks) {
		p.blockTreeSize <<= 1
	}
	p.blockTreeMax = make([]int, 2*p.blockTreeSize)
	for i := range p.blockTreeMax {
		p.blockTreeMax[i] = -1
	}
	for i, block := range p.Blocks {
		p.blockTreeMax[p.blockTreeSize+i] = block.EndByte
	}
	for i := p.blockTreeSize - 1; i > 0; i-- {
		p.blockTreeMax[i] = max(p.blockTreeMax[i*2], p.blockTreeMax[i*2+1])
	}
}

// BlocksIn returns at most limit blocks intersecting [startByte,endByte).
// The bool reports that additional matching blocks were omitted.
func (p Projections) BlocksIn(startByte, endByte, limit int) ([]BlockPresentation, bool) {
	if endByte <= startByte || limit <= 0 || len(p.Blocks) == 0 {
		return nil, false
	}
	if p.blockTreeSize <= 0 || len(p.blockTreeMax) != 2*p.blockTreeSize {
		result := make([]BlockPresentation, 0, min(limit, len(p.Blocks)))
		for _, block := range p.Blocks {
			if block.EndByte <= startByte || block.StartByte >= endByte {
				continue
			}
			if len(result) == limit {
				return result, true
			}
			result = append(result, block)
		}
		return result, false
	}
	endIndex := sort.Search(len(p.Blocks), func(i int) bool { return p.Blocks[i].StartByte >= endByte })
	result := make([]BlockPresentation, 0, min(limit, 64))
	truncated := false
	var visit func(node, left, right int)
	visit = func(node, left, right int) {
		if truncated || left >= endIndex || p.blockTreeMax[node] <= startByte {
			return
		}
		if right-left == 1 {
			block := p.Blocks[left]
			if block.StartByte < endByte && block.EndByte > startByte {
				if len(result) == limit {
					truncated = true
					return
				}
				result = append(result, block)
			}
			return
		}
		middle := left + (right-left)/2
		visit(node*2, left, middle)
		visit(node*2+1, middle, right)
	}
	visit(1, 0, p.blockTreeSize)
	return result, truncated
}

// HighlightKind is a parser-neutral semantic token category. It contains no
// colors, fonts, parser nodes, or Shirei types.
type HighlightKind string

const (
	HighlightComment     HighlightKind = "comment"
	HighlightKeyword     HighlightKind = "keyword"
	HighlightString      HighlightKind = "string"
	HighlightNumber      HighlightKind = "number"
	HighlightType        HighlightKind = "type"
	HighlightFunction    HighlightKind = "function"
	HighlightMethod      HighlightKind = "function.method"
	HighlightVariable    HighlightKind = "variable"
	HighlightConstant    HighlightKind = "constant"
	HighlightProperty    HighlightKind = "property"
	HighlightOperator    HighlightKind = "operator"
	HighlightPunctuation HighlightKind = "punctuation"
	HighlightBuiltin     HighlightKind = "builtin"
	HighlightParameter   HighlightKind = "parameter"
	HighlightTag         HighlightKind = "tag"
	HighlightAttribute   HighlightKind = "attribute"
)

type HighlightSpan struct {
	StartByte int
	EndByte   int
	Kind      HighlightKind
}

type Symbol struct {
	Name      string
	Kind      string
	StartByte int
	EndByte   int
}

type LanguageFold struct {
	StartByte int
	EndByte   int
}

// BlockKind identifies a disposable source block that may receive a row-level
// presentation treatment. It carries no rendering or parser types.
type BlockKind uint8

const (
	BlockCode BlockKind = iota
	BlockQuote
	BlockList
	BlockThematicBreak
	BlockTable
)

type BlockPresentation struct {
	Kind               BlockKind
	StartByte, EndByte int
	// Level carries small block-specific metadata. For BlockTable it is the
	// parser-declared column count; other block kinds currently leave it zero.
	Level              int
}

// CodeProjection is disposable language-derived data. Its spans are indexed
// by source byte range so the UI can request only the visible portion.
type CodeProjection struct {
	Revision   uint64
	Language   string
	Highlights []HighlightSpan
	Symbols    []Symbol
	Folds      []LanguageFold
	maxEnds    []int
}

func NewCodeProjection(revision uint64, language string, highlights []HighlightSpan, symbols []Symbol, folds []LanguageFold) CodeProjection {
	filtered := make([]HighlightSpan, 0, len(highlights))
	for _, span := range highlights {
		if span.StartByte < 0 {
			span.StartByte = 0
		}
		if span.EndByte > span.StartByte && span.Kind != "" {
			filtered = append(filtered, span)
		}
	}
	sort.SliceStable(filtered, func(i, j int) bool {
		if filtered[i].StartByte == filtered[j].StartByte {
			return filtered[i].EndByte < filtered[j].EndByte
		}
		return filtered[i].StartByte < filtered[j].StartByte
	})
	maxEnds := make([]int, len(filtered))
	for i, span := range filtered {
		maxEnds[i] = span.EndByte
		if i > 0 && maxEnds[i-1] > maxEnds[i] {
			maxEnds[i] = maxEnds[i-1]
		}
	}
	return CodeProjection{Revision: revision, Language: language, Highlights: filtered, Symbols: append([]Symbol(nil), symbols...), Folds: append([]LanguageFold(nil), folds...), maxEnds: maxEnds}
}

func (p CodeProjection) HighlightsIn(startByte, endByte int) []HighlightSpan {
	if endByte <= startByte || len(p.Highlights) == 0 {
		return nil
	}
	endIndex := sort.Search(len(p.Highlights), func(i int) bool { return p.Highlights[i].StartByte >= endByte })
	startIndex := 0
	if len(p.maxEnds) == len(p.Highlights) {
		startIndex = sort.Search(endIndex, func(i int) bool { return p.maxEnds[i] > startByte })
	}
	result := make([]HighlightSpan, 0, endIndex-startIndex)
	for _, span := range p.Highlights[startIndex:endIndex] {
		if span.EndByte > startByte && span.StartByte < endByte {
			result = append(result, span)
		}
	}
	return result
}

// PresentationKind identifies a source-preserving Markdown presentation
// span. It deliberately contains no colors, fonts, or UI types: the editor
// remains the source authority and the UI owns the visual treatment.
type PresentationKind uint8

const (
	PresentationSyntax PresentationKind = iota
	PresentationHeading
	PresentationStrong
	PresentationEmphasis
	PresentationInlineCode
	PresentationLink
	PresentationStrike
	PresentationCodeBlock
	PresentationBlockquote
	PresentationListMarker
	PresentationTaskMarker
	PresentationCodeComment
	PresentationCodeKeyword
	PresentationCodeString
	PresentationCodeNumber
	PresentationCodeType
	PresentationCodeFunction
	PresentationCodeMethod
	PresentationCodeVariable
	PresentationCodeConstant
	PresentationCodeProperty
	PresentationCodeOperator
	PresentationCodePunctuation
	PresentationCodeBuiltin
	PresentationCodeParameter
	PresentationCodeTag
	PresentationCodeAttribute
	PresentationThematicBreak
	PresentationTable
	PresentationTableHeader
	PresentationTableDelimiter
	PresentationTablePipe
)

// PresentationSpan is a half-open source-byte range. Spans may overlap when
// Markdown constructs nest; consumers should apply them in projection order.
type PresentationSpan struct {
	StartByte int
	EndByte   int
	Kind      PresentationKind
	Level     int
}

// MarkdownPresentation is a disposable, immutable-by-convention projection
// for one source revision. Its index keeps visible-row range queries bounded
// by the matching spans rather than requiring a document-wide scan.
type MarkdownPresentation struct {
	Revision    uint64
	Spans       []PresentationSpan
	treeMaxEnds []int
	treeSize    int
}

// NewMarkdownPresentation normalizes and indexes source spans produced by the
// Markdown adapter. The input slice is copied so a worker can safely publish a
// completed projection without retaining a mutable builder buffer.
func NewMarkdownPresentation(revision uint64, spans []PresentationSpan) MarkdownPresentation {
	filtered := make([]PresentationSpan, 0, len(spans))
	for _, span := range spans {
		if span.StartByte < 0 {
			span.StartByte = 0
		}
		if span.EndByte <= span.StartByte {
			continue
		}
		filtered = append(filtered, span)
	}
	sort.SliceStable(filtered, func(i, j int) bool {
		if filtered[i].StartByte == filtered[j].StartByte {
			if filtered[i].EndByte == filtered[j].EndByte {
				return filtered[i].Kind < filtered[j].Kind
			}
			return filtered[i].EndByte < filtered[j].EndByte
		}
		return filtered[i].StartByte < filtered[j].StartByte
	})
	treeSize := 1
	for treeSize < len(filtered) {
		treeSize <<= 1
	}
	treeMaxEnds := make([]int, 2*treeSize)
	for i := range treeMaxEnds {
		treeMaxEnds[i] = -1
	}
	for i, span := range filtered {
		treeMaxEnds[treeSize+i] = span.EndByte
	}
	for i := treeSize - 1; i > 0; i-- {
		treeMaxEnds[i] = max(treeMaxEnds[i*2], treeMaxEnds[i*2+1])
	}
	return MarkdownPresentation{Revision: revision, Spans: filtered, treeMaxEnds: treeMaxEnds, treeSize: treeSize}
}

// SpansIn returns source spans intersecting [startByte, endByte). The returned
// slice is independent so callers can clip or reorder it for one visible row.
func (p MarkdownPresentation) SpansIn(startByte, endByte int) []PresentationSpan {
	spans, _ := p.SpansInLimit(startByte, endByte, int(^uint(0)>>1))
	return spans
}

// SpansInLimit is the bounded counterpart to SpansIn. The bool reports that
// additional matching spans were omitted.
func (p MarkdownPresentation) SpansInLimit(startByte, endByte, limit int) ([]PresentationSpan, bool) {
	if startByte < 0 {
		startByte = 0
	}
	if endByte <= startByte || len(p.Spans) == 0 || limit <= 0 {
		return nil, false
	}
	endIndex := sort.Search(len(p.Spans), func(i int) bool { return p.Spans[i].StartByte >= endByte })
	result := make([]PresentationSpan, 0, min(limit, 64))
	truncated := false
	if p.treeSize > 0 && len(p.treeMaxEnds) == 2*p.treeSize {
		var visit func(node, left, right int)
		visit = func(node, left, right int) {
			if truncated || left >= endIndex || p.treeMaxEnds[node] <= startByte {
				return
			}
			if right-left == 1 {
				span := p.Spans[left]
				if span.StartByte < endByte && span.EndByte > startByte {
					if len(result) == limit {
						truncated = true
						return
					}
					result = append(result, span)
				}
				return
			}
			middle := left + (right-left)/2
			visit(node*2, left, middle)
			visit(node*2+1, middle, right)
		}
		visit(1, 0, p.treeSize)
	} else {
		for _, span := range p.Spans[:endIndex] {
			if span.EndByte <= startByte || span.StartByte >= endByte {
				continue
			}
			if len(result) == limit {
				truncated = true
				break
			}
			result = append(result, span)
		}
	}
	if len(result) == 0 {
		return nil, false
	}
	return result, truncated
}

type Heading struct {
	Level              int
	Text               string
	ID                 string
	StartByte, EndByte int
}

type Fold struct {
	HeadingStart       int
	StartByte, EndByte int
}

type Task struct {
	Text                   string
	Checked                bool
	StartByte, EndByte     int
	MarkerStart, MarkerEnd int
}

type Link struct {
	Label, Target      string
	StartByte, EndByte int
}

// DocumentSnapshot is a cheap, immutable capture of the editor state. The
// bytes are materialized only by consumers that explicitly request them.
type DocumentSnapshot struct {
	Revision uint64
	Buffer   editor.BufferSnapshot
}

func (d *Document) Snapshot() DocumentSnapshot {
	if d == nil || d.Editor == nil {
		return DocumentSnapshot{}
	}
	return DocumentSnapshot{Revision: d.Revision(), Buffer: d.Editor.Buffer.Snapshot()}
}

func (s DocumentSnapshot) Materialize() []byte { return s.Buffer.Materialize() }

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

// CanUndo reports whether the document's authoritative editor has an undo
// record.
func (d *Document) CanUndo() bool { return d != nil && d.Editor != nil && d.Editor.CanUndo() }

// CanRedo reports whether the document's authoritative editor has a redo
// record.
func (d *Document) CanRedo() bool { return d != nil && d.Editor != nil && d.Editor.CanRedo() }

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

// Replace performs one ordinary undoable source edit. Derived consumers use
// this seam for actions such as task toggles; Document remains the owner of
// invalidation while ScratchEditor remains the content authority.
func (d *Document) Replace(start, end int, text []byte) error {
	_, err := d.ReplaceResult(start, end, text)
	return err
}

// ReplaceResult applies one ordinary undoable source edit and returns the
// exact edit and normalized inserted bytes created by the editor.
func (d *Document) ReplaceResult(start, end int, text []byte) (editor.AppliedEdit, error) {
	if d == nil || d.Editor == nil || start < 0 || end < start || end > d.Editor.Buffer.ByteLen() {
		return editor.AppliedEdit{}, errors.New("document replace range outside buffer")
	}
	before := d.Revision()
	applied, err := d.Editor.ReplaceRangeResult(start, end, text)
	if err != nil {
		return editor.AppliedEdit{}, err
	}
	if d.Revision() != before {
		d.observedRevision = d.Revision()
		d.InvalidateDerived()
	}
	return applied, nil
}

// ReplaceWithSelection performs one command replacement while preserving the
// editor's current selection for undo and recording the supplied selection for
// redo. Unlike Replace, it does not select the source range before editing;
// structured commands may replace a range that differs from the user's
// selection and return a directional caret/anchor pair for the result.
func (d *Document) ReplaceWithSelection(start, end int, text []byte, anchor, cursor int) error {
	if d == nil || d.Editor == nil || start < 0 || end < start || end > d.Editor.Buffer.ByteLen() {
		return errors.New("document replace range outside buffer")
	}
	before := d.Revision()
	if err := d.Editor.ReplaceWithSelection(start, end, text, anchor, cursor); err != nil {
		return err
	}
	if d.Revision() != before {
		d.observedRevision = d.Revision()
		d.InvalidateDerived()
	}
	return nil
}

// ReplaceWithSelectionState records the frontend's actual selection on both
// sides of one source-edit transaction. Post-edit positions use byte offsets
// in the normalized resulting document. Ordinary caret movement stays local.
func (d *Document) ReplaceWithSelectionState(start, end int, text []byte, beforeAnchor, beforeCursor, afterAnchor, afterCursor int) error {
	_, err := d.ReplaceWithSelectionStateResult(start, end, text, beforeAnchor, beforeCursor, afterAnchor, afterCursor)
	return err
}

// ReplaceWithSelectionStateResult applies one foreign editor transaction and
// returns its exact source edit for acknowledgement without journal lookup.
func (d *Document) ReplaceWithSelectionStateResult(start, end int, text []byte, beforeAnchor, beforeCursor, afterAnchor, afterCursor int) (editor.AppliedEdit, error) {
	if d == nil || d.Editor == nil || start < 0 || end < start || end > d.Editor.Buffer.ByteLen() {
		return editor.AppliedEdit{}, errors.New("document replace range outside buffer")
	}
	beforeLength := d.Editor.Buffer.ByteLen()
	if beforeAnchor < 0 || beforeAnchor > beforeLength || beforeCursor < 0 || beforeCursor > beforeLength {
		return editor.AppliedEdit{}, errors.New("pre-edit selection outside buffer")
	}
	before := d.Revision()
	applied, err := d.Editor.ReplaceInputWithSelectionResult(start, end, text, beforeAnchor, beforeCursor, afterAnchor, afterCursor)
	if err != nil {
		return editor.AppliedEdit{}, err
	}
	if d.Revision() != before {
		d.observedRevision = d.Revision()
		d.InvalidateDerived()
	}
	return applied, nil
}

// Undo applies one editor-owned undo record and invalidates derived state if
// the authoritative source revision changed. Cursor/selection restoration is
// part of the editor's undo record and stays local to the document model.
func (d *Document) Undo() error {
	if d == nil || d.Editor == nil {
		return errors.New("document has no editor")
	}
	before := d.Revision()
	if err := d.Editor.Undo(); err != nil {
		return err
	}
	if d.Revision() != before {
		d.observedRevision = d.Revision()
		d.InvalidateDerived()
	}
	return nil
}

// Redo reapplies one editor-owned undo record and invalidates derived state
// when the authoritative source revision changed.
func (d *Document) Redo() error {
	if d == nil || d.Editor == nil {
		return errors.New("document has no editor")
	}
	before := d.Revision()
	if err := d.Editor.Redo(); err != nil {
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
	if d == nil || d.Editor == nil {
		return
	}
	if d.hasDisplayCode && d.DisplayCode.Revision != d.Revision() {
		edits, ok := d.Editor.EditsSince(d.DisplayCode.Revision)
		if !ok {
			d.DisplayCode = CodeProjection{}
			d.hasDisplayCode = false
		} else {
			d.DisplayCode = rebaseDisplayCode(d.DisplayCode, edits, d.Revision())
		}
	}
	d.DerivedRevision = 0
	d.Injected = nil
	d.Projections.Valid = false
}

func rebaseDisplayCode(code CodeProjection, edits []editor.SourceEdit, revision uint64) CodeProjection {
	highlights := code.Highlights
	for _, edit := range edits {
		shift := edit.NewEndByte - edit.OldEndByte
		next := make([]HighlightSpan, 0, len(highlights))
		for _, span := range highlights {
			switch {
			case span.EndByte <= edit.StartByte:
				next = append(next, span)
			case span.StartByte >= edit.OldEndByte:
				span.StartByte += shift
				span.EndByte += shift
				next = append(next, span)
				// A token touching the changed range is unsafe to display until
				// the parser has revalidated it.
			}
		}
		highlights = next
	}
	return NewCodeProjection(revision, code.Language, highlights, nil, nil)
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
	if injected == nil {
		injected = projections.Injected
	}
	d.Injected = injected
	d.Projections = projections
	if projections.Code.Language != "" {
		d.DisplayCode = NewCodeProjection(projections.Code.Revision, projections.Code.Language, projections.Code.Highlights, nil, nil)
		d.hasDisplayCode = true
	} else {
		d.DisplayCode = CodeProjection{}
		d.hasDisplayCode = false
	}
	d.DerivedRevision = d.Revision()
	return true
}

// DisplayCodeProjection returns the latest safe syntax spans for painting.
// Unlike Projections.Code, this result may describe a rebased intermediate
// revision and must never drive navigation, folds, or other actions.
func (d *Document) DisplayCodeProjection() (CodeProjection, bool) {
	if d == nil || !d.hasDisplayCode {
		return CodeProjection{}, false
	}
	return d.DisplayCode, true
}

// MarkSaved records that the current revision has been persisted.
func (d *Document) MarkSaved() {
	d.SavedRevision = d.Revision()
	d.observedRevision = d.Revision()
}

// Save persists the current authoritative buffer and changes saved metadata
// only after the filesystem operation succeeds. When the replacement
// completes but the parent directory cannot be flushed, the store returns the
// verified new version with an error wrapping workspace.ErrParentDirSync;
// Save adopts that version so a retry does not mistake the caller's own bytes
// for an external change, while still returning the durability warning.
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
	current := d.Editor.Buffer.Text()
	version, err := store.Save(d.Path, current, d.FileMode)
	if err != nil {
		if errors.Is(err, workspace.ErrParentDirSync) {
			if version.Verified {
				d.DiskVersion = version
				d.MarkSaved()
				d.base = append([]byte(nil), current...)
			} else if verified, verr := store.Verify(d.Path); verr == nil && verified.Verified && verified.Hash == sha256.Sum256(current) {
				d.DiskVersion = verified
				d.MarkSaved()
				d.base = append([]byte(nil), current...)
			}
		}
		return err
	}
	d.DiskVersion = version
	d.MarkSaved()
	d.base = append([]byte(nil), current...)
	return nil
}

// SaveAs persists the current buffer at a new path. The document path changes
// only after the replacement succeeds. Like Save, a parent-directory sync
// failure that still replaced the file adopts the verified version before
// returning the durability warning.
func (d *Document) SaveAs(store workspace.FileStore, path string) error {
	if d == nil || d.Editor == nil || path == "" {
		return errors.New("document has no save-as path")
	}
	current := d.Editor.Buffer.Text()
	version, err := store.Save(path, current, d.FileMode)
	if err != nil {
		if errors.Is(err, workspace.ErrParentDirSync) {
			if version.Verified {
				d.Path = filepath.Clean(path)
				d.DiskVersion = version
				d.MarkSaved()
				d.base = append([]byte(nil), current...)
			} else if verified, verr := store.Verify(path); verr == nil && verified.Verified && verified.Hash == sha256.Sum256(current) {
				d.Path = filepath.Clean(path)
				d.DiskVersion = verified
				d.MarkSaved()
				d.base = append([]byte(nil), current...)
			}
		}
		return err
	}
	d.Path = filepath.Clean(path)
	d.DiskVersion = version
	d.MarkSaved()
	d.base = append([]byte(nil), current...)
	return nil
}

// SaveAsIfVersion is the conditional form used when the application has
// shown an overwrite confirmation. The store must perform its version check
// at the replacement seam, after preparing the new bytes.
func (d *Document) SaveAsIfVersion(store workspace.FileStore, path string, expected workspace.DiskVersion) error {
	if d == nil || d.Editor == nil || path == "" {
		return errors.New("document has no save-as path")
	}
	conditional, ok := store.(workspace.ConditionalFileStore)
	if !ok {
		return errors.New("file store does not support conditional save-as")
	}
	current := d.Editor.Buffer.Text()
	version, err := conditional.SaveIfVersion(path, current, d.FileMode, expected)
	if err != nil {
		if errors.Is(err, workspace.ErrParentDirSync) {
			if version.Verified {
				d.Path = filepath.Clean(path)
				d.DiskVersion = version
				d.MarkSaved()
				d.base = append([]byte(nil), current...)
			} else if verified, verr := store.Verify(path); verr == nil && verified.Verified && verified.Hash == sha256.Sum256(current) {
				d.Path = filepath.Clean(path)
				d.DiskVersion = verified
				d.MarkSaved()
				d.base = append([]byte(nil), current...)
			}
		}
		return err
	}
	d.Path = filepath.Clean(path)
	d.DiskVersion = version
	d.MarkSaved()
	d.base = append([]byte(nil), current...)
	return nil
}

// MarkOverwritten records a successful force-overwrite of the on-disk file.
// It updates the disk identity, marks the current revision clean, and
// refreshes the conflict base to the current buffer bytes so later
// reconciliations do not compare against a stale base.
func (d *Document) MarkOverwritten(version workspace.DiskVersion) {
	d.DiskVersion = version
	d.MarkSaved()
	if d.Editor != nil {
		d.base = append([]byte(nil), d.Editor.Buffer.Text()...)
	} else {
		d.base = nil
	}
}

// BaseSnapshot returns the originally loaded bytes for transient conflict
// comparison. It is never used as the editor's content authority.
func (d *Document) BaseSnapshot() []byte {
	if d == nil {
		return nil
	}
	return append([]byte(nil), d.base...)
}
