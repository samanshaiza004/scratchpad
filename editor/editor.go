package editor

// ScratchEditor is the intentionally boring Gate B behavior shell around
// Buffer. It supports one byte-oriented caret and one selection. IME, bidi,
// grapheme motion, undo, soft wrap, and key decoding are deliberately absent.
type ScratchEditor struct {
	Buffer Buffer
	Cursor int
	Anchor int
}

func NewScratchEditor(source []byte) *ScratchEditor {
	return &ScratchEditor{Buffer: NewBuffer(source)}
}

func (e *ScratchEditor) SetCursor(cursor int) {
	if cursor < 0 {
		cursor = 0
	}
	if cursor > e.Buffer.ByteLen() {
		cursor = e.Buffer.ByteLen()
	}
	e.Cursor = cursor
	e.Anchor = cursor
}

func (e *ScratchEditor) SetSelection(anchor, cursor int) {
	e.Anchor = clamp(anchor, e.Buffer.ByteLen())
	e.Cursor = clamp(cursor, e.Buffer.ByteLen())
}

func (e *ScratchEditor) Insert(text []byte) error {
	from, to := e.selection()
	if err := e.Buffer.Delete(from, to); err != nil {
		return err
	}
	if err := e.Buffer.Insert(from, text); err != nil {
		return err
	}
	e.Cursor = from + len(text)
	e.Anchor = e.Cursor
	return nil
}

func (e *ScratchEditor) Backspace() error {
	from, to := e.selection()
	if from != to {
		if err := e.Buffer.Delete(from, to); err != nil {
			return err
		}
		e.Cursor, e.Anchor = from, from
		return nil
	}
	if e.Cursor == 0 {
		return nil
	}
	if err := e.Buffer.Delete(e.Cursor-1, e.Cursor); err != nil {
		return err
	}
	e.Cursor--
	e.Anchor = e.Cursor
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
