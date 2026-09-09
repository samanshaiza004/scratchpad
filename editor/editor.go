package editor

import "unicode"

// ScratchEditor is the intentionally boring Gate B behavior shell around
// Buffer. It supports one byte-oriented caret, one selection, local grapheme
// motion, affinity, clipboard operations, undo/redo, and a preedit state.
// Shirei supplies the visual mapping and native input transport above this
// pure core.
type ScratchEditor struct {
	Buffer        Buffer
	Cursor        int
	Anchor        int
	Affinity      Affinity
	preedit       Composition
	preferredX    float32
	hasPreferredX bool
	revision      uint64
	nextRevision  uint64
	undo          []editRecord
	redo          []editRecord
	editJournal   []SourceEdit
}

// BytePoint is a UTF-8 byte position. Tree-sitter and the editor both use
// byte columns, so this type keeps parser details out of the parser adapters.
type BytePoint struct {
	Row    int
	Column int
}

// SourceEdit describes one source mutation in the coordinate space that was
// valid immediately before and after the mutation. It is deliberately free
// of Tree-sitter types so the editor can remain parser-independent.
type SourceEdit struct {
	BeforeRevision uint64
	AfterRevision  uint64

	StartByte  int
	OldEndByte int
	NewEndByte int

	StartPoint  BytePoint
	OldEndPoint BytePoint
	NewEndPoint BytePoint
}

const editJournalCapacity = 4096

type Affinity uint8

const (
	AffinityLeading Affinity = iota
	AffinityTrailing
)

type Composition struct {
	Text string
	Sel  [2]int
}

type editRecord struct {
	start                         int
	deleted, inserted             []byte
	beforeCursor, beforeAnchor    int
	afterCursor, afterAnchor      int
	beforeRevision, afterRevision uint64
}

func NewScratchEditor(source []byte) *ScratchEditor {
	return &ScratchEditor{Buffer: NewBuffer(source), nextRevision: 1}
}

// Revision identifies the current editable document state. It changes only
// when document bytes change; caret, selection, and viewport changes do not
// make a document dirty.
func (e *ScratchEditor) Revision() uint64 {
	return e.revision
}

// Reset replaces the editable content with a newly loaded file state. The
// load is not an edit and therefore clears undo history. It still receives a
// new revision identity: derived workers may still be finishing a parse of
// the previous contents, and reusing revision zero would let that result
// masquerade as a projection for the replacement bytes.
func (e *ScratchEditor) Reset(source []byte) {
	e.Buffer = NewBuffer(source)
	e.Cursor, e.Anchor = 0, 0
	e.Affinity = AffinityLeading
	e.preedit = Composition{}
	e.ClearPreferredVerticalX()
	e.revision = e.nextRevision
	e.nextRevision++
	e.undo = nil
	e.redo = nil
	e.editJournal = nil
}

// EditsSince returns the contiguous edit chain from revision to the current
// editor state. The journal is intentionally bounded; callers must fall back
// to a fresh parse when the requested chain has been evicted or is ambiguous.
func (e *ScratchEditor) EditsSince(revision uint64) ([]SourceEdit, bool) {
	if e == nil || revision == e.revision {
		return nil, true
	}
	start := -1
	for i, edit := range e.editJournal {
		if edit.BeforeRevision != revision {
			continue
		}
		if start != -1 {
			// Undo/redo can revisit a revision. A revision alone then does not
			// identify the parser's position in the journal, so be conservative.
			return nil, false
		}
		start = i
	}
	if start == -1 {
		return nil, false
	}
	chain := make([]SourceEdit, 0, len(e.editJournal)-start)
	current := revision
	for i := start; i < len(e.editJournal); i++ {
		edit := e.editJournal[i]
		if edit.BeforeRevision != current {
			return nil, false
		}
		chain = append(chain, edit)
		current = edit.AfterRevision
		if current == e.revision {
			return chain, true
		}
	}
	return nil, false
}

func (e *ScratchEditor) SetCursor(cursor int) {
	cursor = e.Buffer.boundary(cursor)
	e.Cursor = cursor
	e.Anchor = cursor
	e.Affinity = AffinityLeading
	e.ClearPreferredVerticalX()
}

func (e *ScratchEditor) SetSelection(anchor, cursor int) {
	e.Anchor = e.Buffer.boundary(anchor)
	e.Cursor = e.Buffer.boundary(cursor)
	e.Affinity = AffinityLeading
	e.ClearPreferredVerticalX()
}

// PreferredVerticalX is the visual horizontal position retained while the
// caret moves through consecutive lines with Up and Down.
func (e *ScratchEditor) PreferredVerticalX() (float32, bool) {
	if e == nil {
		return 0, false
	}
	return e.preferredX, e.hasPreferredX
}

// SetPreferredVerticalX records the visual horizontal position for vertical
// caret movement. It is a UI-derived value, not document state.
func (e *ScratchEditor) SetPreferredVerticalX(x float32) {
	if e == nil {
		return
	}
	e.preferredX = x
	e.hasPreferredX = true
}

// ClearPreferredVerticalX makes the next vertical movement derive its
// horizontal position from the current caret again.
func (e *ScratchEditor) ClearPreferredVerticalX() {
	if e == nil {
		return
	}
	e.preferredX = 0
	e.hasPreferredX = false
}

func (e *ScratchEditor) Insert(text []byte) error {
	from, to := e.selection()
	// The editor's Enter key is intentionally represented as an insertion by
	// the input adapter. Keep pasted/multi-byte text literal, but make the
	// single LF produced by Enter carry the current line's leading indent.
	if len(text) == 1 && text[0] == '\n' {
		text = e.newlineText(from)
	}
	return e.replace(from, to, text)
}

// ReplaceWithSelection applies one source replacement while preserving the
// current selection as the undo state and recording the supplied selection as
// the post-edit state. It is used by structured commands whose replacement
// range differs from the user's current selection and whose result has a
// meaningful caret/anchor pair.
func (e *ScratchEditor) ReplaceWithSelection(start, end int, text []byte, anchor, cursor int) error {
	return e.replaceWithSelection(start, end, text, &selectionState{anchor: anchor, cursor: cursor})
}

func (e *ScratchEditor) Backspace() error {
	from, to := e.selection()
	if from != to {
		return e.replace(from, to, nil)
	}
	if e.Cursor == 0 {
		return nil
	}
	return e.replace(e.Buffer.PreviousCluster(e.Cursor), e.Cursor, nil)
}

func (e *ScratchEditor) DeleteForward() error {
	from, to := e.selection()
	if from != to {
		return e.replace(from, to, nil)
	}
	if e.Cursor >= e.Buffer.ByteLen() {
		return nil
	}
	return e.replace(e.Cursor, e.Buffer.NextCluster(e.Cursor), nil)
}

// DeleteWordBackward removes the selection or the class-run word span ending
// at the caret. It shares Buffer.PreviousWord with word navigation so the two
// commands agree on punctuation, whitespace, scripts, and malformed bytes.
func (e *ScratchEditor) DeleteWordBackward() error {
	from, to := e.selection()
	if from != to {
		return e.replace(from, to, nil)
	}
	if e.Cursor == 0 {
		return nil
	}
	return e.replace(e.Buffer.PreviousWord(e.Cursor), e.Cursor, nil)
}

// DeleteWordForward removes the selection or the class-run word span starting
// at the caret. It uses the same boundaries as MoveWordRight.
func (e *ScratchEditor) DeleteWordForward() error {
	from, to := e.selection()
	if from != to {
		return e.replace(from, to, nil)
	}
	if e.Cursor >= e.Buffer.ByteLen() {
		return nil
	}
	return e.replace(e.Cursor, e.Buffer.NextWord(e.Cursor), nil)
}

// MoveDocumentStart moves to the beginning of the document. Shift-style
// callers can retain the existing anchor by passing extend=true.
func (e *ScratchEditor) MoveDocumentStart(extend bool) {
	e.moveDocumentBoundary(false, extend)
}

// MoveDocumentEnd moves to the end of the document. Shift-style callers can
// retain the existing anchor by passing extend=true.
func (e *ScratchEditor) MoveDocumentEnd(extend bool) {
	e.moveDocumentBoundary(true, extend)
}

// MoveToDocumentStart and MoveToDocumentEnd are descriptive aliases for
// input adapters whose naming follows the key action rather than the motion.
func (e *ScratchEditor) MoveToDocumentStart(extend bool) { e.MoveDocumentStart(extend) }
func (e *ScratchEditor) MoveToDocumentEnd(extend bool)   { e.MoveDocumentEnd(extend) }

func (e *ScratchEditor) moveDocumentBoundary(end, extend bool) {
	position := 0
	if end {
		position = e.Buffer.ByteLen()
	}
	e.Cursor = position
	if !extend {
		e.Anchor = position
	}
	e.Affinity = AffinityLeading
	e.ClearPreferredVerticalX()
}

// MovePage moves by pageLines logical lines while retaining the byte column
// where possible. The view may choose the page size from its visible rows;
// the model deliberately has no pixel/layout dependency.
func (e *ScratchEditor) MovePage(deltaLines, pageLines int, extend bool) {
	if pageLines < 0 {
		pageLines = -pageLines
	}
	if pageLines == 0 || e.Buffer.LineCount() == 0 {
		return
	}
	from, to := e.selection()
	origin := e.Cursor
	if !extend && from != to {
		if deltaLines < 0 {
			origin = from
		} else {
			origin = to
		}
	}
	line, ok := e.Buffer.LineAt(origin)
	if !ok {
		return
	}
	start, end, ok := e.Buffer.LineRange(line)
	if !ok {
		return
	}
	column := origin - start
	if column > end-start {
		column = end - start
	}
	targetLine := line + deltaLines*pageLines
	if targetLine < 0 {
		targetLine = 0
	}
	if last := e.Buffer.LineCount() - 1; targetLine > last {
		targetLine = last
	}
	targetStart, targetEnd, ok := e.Buffer.LineRange(targetLine)
	if !ok {
		return
	}
	position := e.Buffer.boundary(targetStart + clamp(column, targetEnd-targetStart))
	e.Cursor = position
	if !extend {
		e.Anchor = position
	}
	e.Affinity = AffinityLeading
	e.ClearPreferredVerticalX()
}

// PageUp and PageDown are model-level page motions. pageLines is normally
// supplied by the fixed-height viewport.
func (e *ScratchEditor) PageUp(pageLines int, extend bool) {
	e.MovePage(-1, pageLines, extend)
}

func (e *ScratchEditor) PageDown(pageLines int, extend bool) {
	e.MovePage(1, pageLines, extend)
}

func (e *ScratchEditor) Selection() (anchor, cursor int) {
	return e.Anchor, e.Cursor
}

func (e *ScratchEditor) SelectAll() {
	e.Anchor = 0
	e.Cursor = e.Buffer.ByteLen()
	e.Affinity = AffinityLeading
	e.ClearPreferredVerticalX()
}

func (e *ScratchEditor) Copy() string {
	from, to := e.selection()
	if from == to {
		from, to = e.currentLineEditRange()
	}
	data, _ := e.Buffer.Bytes(from, to)
	return string(data)
}

func (e *ScratchEditor) Cut() (string, error) {
	from, to := e.selection()
	if from == to {
		from, to = e.currentLineEditRange()
	}
	textBytes, err := e.Buffer.Bytes(from, to)
	if err != nil {
		return "", err
	}
	text := string(textBytes)
	return text, e.replace(from, to, nil)
}

// CopyLine and CutLine expose the whole-line clipboard behavior explicitly.
// With a non-empty selection they preserve the ordinary selection semantics;
// with an empty selection they include the current line's terminator when it
// has one.
func (e *ScratchEditor) CopyLine() string { return e.Copy() }

func (e *ScratchEditor) CutLine() (string, error) { return e.Cut() }

func (e *ScratchEditor) Paste(text string) error {
	return e.Insert([]byte(text))
}

func (e *ScratchEditor) Undo() error {
	if len(e.undo) == 0 {
		return nil
	}
	r := e.undo[len(e.undo)-1]
	e.undo = e.undo[:len(e.undo)-1]
	edit := e.sourceEdit(r.start, r.start+len(r.inserted), r.deleted, 0)
	edit.BeforeRevision = e.revision
	edit.AfterRevision = r.beforeRevision
	if err := e.Buffer.Delete(r.start, r.start+len(r.inserted)); err != nil {
		return err
	}
	if err := e.Buffer.Insert(r.start, r.deleted); err != nil {
		return err
	}
	e.Cursor, e.Anchor = r.beforeCursor, r.beforeAnchor
	e.revision = r.beforeRevision
	e.recordSourceEdit(edit)
	e.Affinity = AffinityLeading
	e.ClearPreferredVerticalX()
	e.redo = append(e.redo, r)
	return nil
}

func (e *ScratchEditor) Redo() error {
	if len(e.redo) == 0 {
		return nil
	}
	r := e.redo[len(e.redo)-1]
	e.redo = e.redo[:len(e.redo)-1]
	edit := e.sourceEdit(r.start, r.start+len(r.deleted), r.inserted, 0)
	edit.BeforeRevision = e.revision
	edit.AfterRevision = r.afterRevision
	if err := e.Buffer.Delete(r.start, r.start+len(r.deleted)); err != nil {
		return err
	}
	if err := e.Buffer.Insert(r.start, r.inserted); err != nil {
		return err
	}
	e.Cursor, e.Anchor = r.afterCursor, r.afterAnchor
	e.revision = r.afterRevision
	e.recordSourceEdit(edit)
	e.Affinity = AffinityLeading
	e.ClearPreferredVerticalX()
	e.undo = append(e.undo, r)
	return nil
}

func (e *ScratchEditor) MoveLeft(extend bool) {
	position := e.Buffer.PreviousCluster(e.Cursor)
	e.Cursor = position
	if !extend {
		e.Anchor = position
	}
	e.Affinity = AffinityLeading
	e.ClearPreferredVerticalX()
}

func (e *ScratchEditor) MoveRight(extend bool) {
	position := e.Buffer.NextCluster(e.Cursor)
	e.Cursor = position
	if !extend {
		e.Anchor = position
	}
	e.Affinity = AffinityTrailing
	e.ClearPreferredVerticalX()
}

// MoveWordLeft and MoveWordRight use the same class-run word boundaries as
// Shirei. Shift extends the current selection, while an ordinary motion
// collapses its anchor to the new caret position.
func (e *ScratchEditor) MoveWordLeft(extend bool) {
	position := e.Buffer.PreviousWord(e.Cursor)
	e.Cursor = position
	if !extend {
		e.Anchor = position
	}
	e.Affinity = AffinityLeading
	e.ClearPreferredVerticalX()
}

func (e *ScratchEditor) MoveWordRight(extend bool) {
	position := e.Buffer.NextWord(e.Cursor)
	e.Cursor = position
	if !extend {
		e.Anchor = position
	}
	e.Affinity = AffinityTrailing
	e.ClearPreferredVerticalX()
}

func (e *ScratchEditor) SetAffinity(affinity Affinity) {
	e.Affinity = affinity
}

func (e *ScratchEditor) BeginComposition(text string, selection [2]int) {
	e.preedit = Composition{Text: text, Sel: selection}
}

func (e *ScratchEditor) UpdateComposition(text string, selection [2]int) {
	e.preedit = Composition{Text: text, Sel: selection}
}

func (e *ScratchEditor) Composition() Composition {
	return e.preedit
}

func (e *ScratchEditor) CommitComposition() error {
	if e.preedit.Text == "" {
		e.preedit = Composition{}
		return nil
	}
	text := e.preedit.Text
	e.preedit = Composition{}
	return e.Insert([]byte(text))
}

func (e *ScratchEditor) CancelComposition() {
	e.preedit = Composition{}
}

// HitTest maps a logical line and byte column to a buffer byte offset. Pixel
// hit-testing belongs to the Shirei view; affinity records the visual side of
// a bidi boundary selected by that view.
func (e *ScratchEditor) HitTest(line, byteColumn int, affinity Affinity) (int, bool) {
	start, end, ok := e.Buffer.LineRange(line)
	if !ok {
		return 0, false
	}
	position := e.Buffer.boundary(clamp(start+byteColumn, end))
	e.Affinity = affinity
	return position, true
}

func (e *ScratchEditor) DirectionAt() Direction {
	r, _, ok := e.Buffer.runeAt(e.Cursor)
	if !ok && e.Cursor > 0 {
		r, _, ok = e.Buffer.runeAt(e.Buffer.PreviousCluster(e.Cursor))
	}
	if ok && isRTL(r) {
		return DirectionRTL
	}
	return DirectionLTR
}

type Direction uint8

const (
	DirectionLTR Direction = iota
	DirectionRTL
)

func isRTL(r rune) bool {
	return unicode.In(r, unicode.Arabic, unicode.Hebrew, unicode.Syriac,
		unicode.Thaana, unicode.Nko, unicode.Coptic)
}

func (e *ScratchEditor) replace(start, end int, text []byte) error {
	return e.replaceWithSelection(start, end, text, nil)
}

type selectionState struct {
	anchor int
	cursor int
}

func (e *ScratchEditor) replaceWithSelection(start, end int, text []byte, after *selectionState) error {
	if start == end && len(text) == 0 {
		if after != nil {
			e.Anchor = e.Buffer.boundary(after.anchor)
			e.Cursor = e.Buffer.boundary(after.cursor)
			e.Affinity = AffinityLeading
			e.ClearPreferredVerticalX()
		}
		return nil
	}
	deleted, err := e.Buffer.Bytes(start, end)
	if err != nil {
		return err
	}
	beforeCursor, beforeAnchor := e.Cursor, e.Anchor
	edit := e.sourceEdit(start, end, text, 0)
	if err := e.Buffer.Delete(start, end); err != nil {
		return err
	}
	if err := e.Buffer.Insert(start, text); err != nil {
		return err
	}
	beforeRevision := e.revision
	afterRevision := e.nextRevision
	edit.BeforeRevision = beforeRevision
	edit.AfterRevision = afterRevision
	e.nextRevision++
	e.revision = afterRevision
	e.recordSourceEdit(edit)
	if after == nil {
		e.Cursor = start + len(text)
		e.Anchor = e.Cursor
	} else {
		e.Anchor = e.Buffer.boundary(after.anchor)
		e.Cursor = e.Buffer.boundary(after.cursor)
	}
	e.Affinity = AffinityLeading
	e.ClearPreferredVerticalX()
	e.undo = append(e.undo, editRecord{
		start: start, deleted: deleted, inserted: append([]byte(nil), text...),
		beforeCursor: beforeCursor, beforeAnchor: beforeAnchor,
		afterCursor: e.Cursor, afterAnchor: e.Anchor,
		beforeRevision: beforeRevision, afterRevision: afterRevision,
	})
	e.redo = nil
	return nil
}

func (e *ScratchEditor) sourceEdit(start, end int, text []byte, afterRevision uint64) SourceEdit {
	startPoint := bufferBytePoint(&e.Buffer, start)
	oldEndPoint := bufferBytePoint(&e.Buffer, end)
	return SourceEdit{
		StartByte:     start,
		OldEndByte:    end,
		NewEndByte:    start + len(text),
		StartPoint:    startPoint,
		OldEndPoint:   oldEndPoint,
		NewEndPoint:   advanceBytePoint(startPoint, text),
		AfterRevision: afterRevision,
	}
}

func (e *ScratchEditor) recordSourceEdit(edit SourceEdit) {
	e.editJournal = append(e.editJournal, edit)
	if len(e.editJournal) > editJournalCapacity {
		e.editJournal = e.editJournal[len(e.editJournal)-editJournalCapacity:]
	}
}

func bufferBytePoint(buffer *Buffer, offset int) BytePoint {
	line, ok := buffer.LineAt(offset)
	if !ok {
		return BytePoint{}
	}
	start, _, ok := buffer.LineRange(line)
	if !ok {
		return BytePoint{Row: line}
	}
	return BytePoint{Row: line, Column: offset - start}
}

func advanceBytePoint(start BytePoint, text []byte) BytePoint {
	point := start
	for _, c := range text {
		if c == '\n' {
			point.Row++
			point.Column = 0
		} else {
			point.Column++
		}
	}
	return point
}

func (e *ScratchEditor) selection() (int, int) {
	if e.Anchor < e.Cursor {
		return e.Anchor, e.Cursor
	}
	return e.Cursor, e.Anchor
}

func clamp(value, max int) int {
	if value < 0 {
		return 0
	}
	if value > max {
		return max
	}
	return value
}
