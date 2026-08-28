package editor

import "unicode"

// ScratchEditor is the intentionally boring Gate B behavior shell around
// Buffer. It supports one byte-oriented caret, one selection, local grapheme
// motion, affinity, clipboard operations, undo/redo, and a preedit state.
// Shirei supplies the visual mapping and native input transport above this
// pure core.
type ScratchEditor struct {
	Buffer   Buffer
	Cursor   int
	Anchor   int
	Affinity Affinity
	preedit  Composition
	undo     []editRecord
	redo     []editRecord
}

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
	start                      int
	deleted, inserted          []byte
	beforeCursor, beforeAnchor int
	afterCursor, afterAnchor   int
}

func NewScratchEditor(source []byte) *ScratchEditor {
	return &ScratchEditor{Buffer: NewBuffer(source)}
}

func (e *ScratchEditor) SetCursor(cursor int) {
	cursor = e.Buffer.boundary(cursor)
	e.Cursor = cursor
	e.Anchor = cursor
	e.Affinity = AffinityLeading
}

func (e *ScratchEditor) SetSelection(anchor, cursor int) {
	e.Anchor = e.Buffer.boundary(anchor)
	e.Cursor = e.Buffer.boundary(cursor)
	e.Affinity = AffinityLeading
}

func (e *ScratchEditor) Insert(text []byte) error {
	from, to := e.selection()
	return e.replace(from, to, text)
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

func (e *ScratchEditor) Selection() (anchor, cursor int) {
	return e.Anchor, e.Cursor
}

func (e *ScratchEditor) SelectAll() {
	e.Anchor = 0
	e.Cursor = e.Buffer.ByteLen()
	e.Affinity = AffinityLeading
}

func (e *ScratchEditor) Copy() string {
	from, to := e.selection()
	data, _ := e.Buffer.Bytes(from, to)
	return string(data)
}

func (e *ScratchEditor) Cut() (string, error) {
	text := e.Copy()
	from, to := e.selection()
	if from == to {
		return "", nil
	}
	return text, e.replace(from, to, nil)
}

func (e *ScratchEditor) Paste(text string) error {
	return e.Insert([]byte(text))
}

func (e *ScratchEditor) Undo() error {
	if len(e.undo) == 0 {
		return nil
	}
	r := e.undo[len(e.undo)-1]
	e.undo = e.undo[:len(e.undo)-1]
	if err := e.Buffer.Delete(r.start, r.start+len(r.inserted)); err != nil {
		return err
	}
	if err := e.Buffer.Insert(r.start, r.deleted); err != nil {
		return err
	}
	e.Cursor, e.Anchor = r.beforeCursor, r.beforeAnchor
	e.Affinity = AffinityLeading
	e.redo = append(e.redo, r)
	return nil
}

func (e *ScratchEditor) Redo() error {
	if len(e.redo) == 0 {
		return nil
	}
	r := e.redo[len(e.redo)-1]
	e.redo = e.redo[:len(e.redo)-1]
	if err := e.Buffer.Delete(r.start, r.start+len(r.deleted)); err != nil {
		return err
	}
	if err := e.Buffer.Insert(r.start, r.inserted); err != nil {
		return err
	}
	e.Cursor, e.Anchor = r.afterCursor, r.afterAnchor
	e.Affinity = AffinityLeading
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
}

func (e *ScratchEditor) MoveRight(extend bool) {
	position := e.Buffer.NextCluster(e.Cursor)
	e.Cursor = position
	if !extend {
		e.Anchor = position
	}
	e.Affinity = AffinityTrailing
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
	deleted, err := e.Buffer.Bytes(start, end)
	if err != nil {
		return err
	}
	beforeCursor, beforeAnchor := e.Cursor, e.Anchor
	if err := e.Buffer.Delete(start, end); err != nil {
		return err
	}
	if err := e.Buffer.Insert(start, text); err != nil {
		return err
	}
	e.Cursor = start + len(text)
	e.Anchor = e.Cursor
	e.Affinity = AffinityLeading
	e.undo = append(e.undo, editRecord{
		start: start, deleted: deleted, inserted: append([]byte(nil), text...),
		beforeCursor: beforeCursor, beforeAnchor: beforeAnchor,
		afterCursor: e.Cursor, afterAnchor: e.Anchor,
	})
	e.redo = nil
	return nil
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
