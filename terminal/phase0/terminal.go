// Package phase0 is the isolated terminal proof for Scratchpad.
//
// It is intentionally a nested Go module. Importing the current
// go-libghostty binding must not silently raise Scratchpad's root toolchain or
// add a native dependency to the application before the Phase 0 gates pass.
package phase0

import (
	"fmt"
	"strings"
	"sync"
	"unicode/utf8"

	ghostty "go.mitchellh.com/libghostty"
)

// DefaultCols and DefaultRows are deliberately modest smoke-test dimensions.
// The workbench will derive its size from the measured view once Phase 0 passes.
const (
	DefaultCols uint16 = 80
	DefaultRows uint16 = 24
)

// CellWide preserves the terminal core's column semantics at the adapter
// boundary. A wide cell occupies two columns; spacer cells are not rendered.
type CellWide uint8

const (
	CellNarrow CellWide = iota
	CellWideGlyph
	CellSpacerTail
	CellSpacerHead
)

// RGB is a copied terminal color. Keeping colors as RGB here avoids making the
// terminal adapter depend on Shirei's HSLA presentation convention.
type RGB struct {
	R, G, B uint8
}

// CellStyle is a copied, renderer-facing style snapshot.
type CellStyle struct {
	Foreground    RGB
	Background    RGB
	HasForeground bool
	HasBackground bool
	Bold          bool
	Faint         bool
	Italic        bool
	Underline     bool
	Strikethrough bool
	Inverse       bool
}

// Cell is a copied terminal cell. Text contains the whole grapheme cluster
// reported by libghostty, not merely its first codepoint.
type Cell struct {
	Text  string
	Wide  CellWide
	Style CellStyle
}

// IsSpacer reports whether this cell is occupied by the second half of a wide
// glyph or by the soft-wrap spacer at the end of a row.
func (c Cell) IsSpacer() bool {
	return c.Wide == CellSpacerTail || c.Wide == CellSpacerHead
}

// Cursor is the terminal cursor in viewport cell coordinates.
type Cursor struct {
	Column      uint16
	Row         uint16
	Visible     bool
	Blinking    bool
	WideTail    bool
	VisualStyle ghostty.CursorVisualStyle
}

// Snapshot is immutable after Core.Snapshot returns. It is safe for a session
// to publish a copy to a UI reader; no libghostty handle crosses this boundary.
type Snapshot struct {
	Cols       uint16
	Rows       uint16
	Cells      []Cell
	Cursor     Cursor
	Foreground RGB
	Background RGB
	Title      string
}

// CellAt returns a cell by viewport coordinates.
func (s Snapshot) CellAt(row, column int) (Cell, bool) {
	if row < 0 || column < 0 || row >= int(s.Rows) || column >= int(s.Cols) {
		return Cell{}, false
	}
	index := row*int(s.Cols) + column
	if index >= len(s.Cells) {
		return Cell{}, false
	}
	return s.Cells[index], true
}

// Core owns all libghostty handles. Callers must serialize Core methods; a
// Session does this by running them on one worker goroutine.
type Core struct {
	terminal  *ghostty.Terminal
	render    *ghostty.RenderState
	rowIter   *ghostty.RenderStateRowIterator
	cellIter  *ghostty.RenderStateRowCells
	closeOnce sync.Once
}

// NewCore creates a terminal emulator with the supplied cell dimensions. The
// optional writePTY callback receives protocol responses such as device-query
// replies. It runs synchronously during VTWrite and must be cheap and
// non-reentrant.
func NewCore(cols, rows uint16, writePTY func([]byte)) (*Core, error) {
	if cols == 0 || rows == 0 {
		return nil, fmt.Errorf("terminal dimensions must be positive: %dx%d", cols, rows)
	}

	term, err := ghostty.NewTerminal(
		ghostty.WithSize(cols, rows),
		ghostty.WithMaxScrollbackLines(10_000),
		ghostty.WithTitleReport(false),
		ghostty.WithWritePty(func(_ *ghostty.Terminal, data []byte) {
			if writePTY != nil {
				writePTY(data)
			}
		}),
		// Phase 0 keeps host side effects explicit. OSC 52 is denied here;
		// the eventual panel must make clipboard permissions a UI policy.
		ghostty.WithClipboardWrite(func(_ *ghostty.Terminal, _ ghostty.ClipboardWrite) ghostty.ClipboardWriteReply {
			return ghostty.ClipboardWriteReply{Result: ghostty.ClipboardWriteDenied}
		}),
		ghostty.WithClipboardRead(func(_ *ghostty.Terminal, _ ghostty.ClipboardRead) ghostty.ClipboardReadReply {
			return ghostty.ClipboardReadReply{Result: ghostty.ClipboardReadDenied}
		}),
		ghostty.WithBell(func(_ *ghostty.Terminal) {}),
		// Desktop notifications are deliberately ignored in the proof. Title
		// changes remain readable on Snapshot but never rename the application.
		ghostty.WithDesktopNotification(func(_ *ghostty.Terminal, _ ghostty.TerminalDesktopNotification) {}),
		ghostty.WithTitleChanged(func(_ *ghostty.Terminal) {}),
		ghostty.WithPwdChanged(func(_ *ghostty.Terminal) {}),
		ghostty.WithProgressReport(func(_ *ghostty.Terminal, _ ghostty.TerminalProgressReport) {}),
	)
	if err != nil {
		return nil, fmt.Errorf("create libghostty terminal: %w", err)
	}

	render, err := ghostty.NewRenderState()
	if err != nil {
		term.Close()
		return nil, fmt.Errorf("create libghostty render state: %w", err)
	}
	rowIter, err := ghostty.NewRenderStateRowIterator()
	if err != nil {
		render.Close()
		term.Close()
		return nil, fmt.Errorf("create libghostty row iterator: %w", err)
	}
	cellIter, err := ghostty.NewRenderStateRowCells()
	if err != nil {
		rowIter.Close()
		render.Close()
		term.Close()
		return nil, fmt.Errorf("create libghostty cell iterator: %w", err)
	}

	return &Core{
		terminal: term,
		render:   render,
		rowIter:  rowIter,
		cellIter: cellIter,
	}, nil
}

// WriteVT feeds a complete or partial VT byte stream into the terminal.
func (c *Core) WriteVT(data []byte) {
	c.terminal.VTWrite(data)
}

// Resize changes both the terminal's cell grid and the image-protocol cell
// metrics. Phase 0 uses the supplied logical cell dimensions as pixel values;
// the workbench will pass measured font metrics later.
func (c *Core) Resize(cols, rows uint16, cellWidth, cellHeight uint32) error {
	if cols == 0 || rows == 0 {
		return fmt.Errorf("terminal dimensions must be positive: %dx%d", cols, rows)
	}
	return c.terminal.Resize(cols, rows, cellWidth, cellHeight)
}

// Snapshot updates the render state, copies every visible cell, and clears its
// dirty flags only after the copy completes. No libghostty-owned value escapes.
func (c *Core) Snapshot() (Snapshot, error) {
	if err := c.render.Update(c.terminal); err != nil {
		return Snapshot{}, fmt.Errorf("update libghostty render state: %w", err)
	}

	cols, err := c.render.Cols()
	if err != nil {
		return Snapshot{}, fmt.Errorf("read terminal columns: %w", err)
	}
	rows, err := c.render.Rows()
	if err != nil {
		return Snapshot{}, fmt.Errorf("read terminal rows: %w", err)
	}
	colors, err := c.render.Colors()
	if err != nil {
		return Snapshot{}, fmt.Errorf("read terminal colors: %w", err)
	}
	cursor, err := c.render.Cursor()
	if err != nil {
		return Snapshot{}, fmt.Errorf("read terminal cursor: %w", err)
	}
	title, err := c.terminal.Title()
	if err != nil {
		return Snapshot{}, fmt.Errorf("read terminal title: %w", err)
	}

	snapshot := Snapshot{
		Cols:       cols,
		Rows:       rows,
		Cells:      make([]Cell, int(cols)*int(rows)),
		Foreground: RGB{colors.Foreground.R, colors.Foreground.G, colors.Foreground.B},
		Background: RGB{colors.Background.R, colors.Background.G, colors.Background.B},
		Title:      title,
		Cursor: Cursor{
			Visible:     cursor.Visible,
			Blinking:    cursor.Blinking,
			WideTail:    cursor.WideTail,
			VisualStyle: cursor.VisualStyle,
		},
	}
	if cursor.ViewportHasValue {
		snapshot.Cursor.Column = cursor.ViewportX
		snapshot.Cursor.Row = cursor.ViewportY
	}

	if err := c.render.RowIterator(c.rowIter); err != nil {
		return Snapshot{}, fmt.Errorf("read terminal rows: %w", err)
	}
	for rowNumber := 0; c.rowIter.Next(); rowNumber++ {
		if err := c.rowIter.Cells(c.cellIter); err != nil {
			return Snapshot{}, fmt.Errorf("read terminal cells: %w", err)
		}
		for column := 0; c.cellIter.Next(); column++ {
			if column >= int(cols) {
				break
			}
			cell, err := c.copyCell()
			if err != nil {
				return Snapshot{}, fmt.Errorf("copy terminal cell %d: %w", column, err)
			}
			// The row iterator's public API does not expose a numeric row
			// coordinate; rows are yielded in viewport order.
			if rowNumber >= int(rows) {
				break
			}
			snapshot.Cells[rowNumber*int(cols)+column] = cell
		}
	}

	if err := c.render.Clean(); err != nil {
		return Snapshot{}, fmt.Errorf("clean libghostty render state: %w", err)
	}
	return snapshot, nil
}

func (c *Core) copyCell() (Cell, error) {
	raw, err := c.cellIter.Raw()
	if err != nil {
		return Cell{}, err
	}
	wide, err := raw.Wide()
	if err != nil {
		return Cell{}, err
	}
	text, err := c.cellIter.AppendGraphemes(nil)
	if err != nil {
		return Cell{}, err
	}
	var style ghostty.RenderCellStyle
	if err := c.cellIter.StyleInto(&style); err != nil {
		return Cell{}, err
	}
	return Cell{
		Text: string(text),
		Wide: cellWide(wide),
		Style: CellStyle{
			Foreground:    RGB{style.Foreground.R, style.Foreground.G, style.Foreground.B},
			Background:    RGB{style.Background.R, style.Background.G, style.Background.B},
			HasForeground: style.HasForeground,
			HasBackground: style.HasBackground,
			Bold:          style.Bold,
			Faint:         style.Faint,
			Italic:        style.Italic,
			Underline:     style.Underline,
			Strikethrough: style.Strikethrough,
			Inverse:       style.Inverse,
		},
	}, nil
}

func cellWide(w ghostty.CellWide) CellWide {
	switch w {
	case ghostty.CellWideWide:
		return CellWideGlyph
	case ghostty.CellWideSpacerTail:
		return CellSpacerTail
	case ghostty.CellWideSpacerHead:
		return CellSpacerHead
	default:
		return CellNarrow
	}
}

// Close releases all native handles. It is idempotent and must run on the
// same owner goroutine as Snapshot/WriteVT in a live session.
func (c *Core) Close() {
	c.closeOnce.Do(func() {
		c.cellIter.Close()
		c.rowIter.Close()
		c.render.Close()
		c.terminal.Close()
	})
}

// PlainText returns a deterministic, cell-preserving diagnostic view. It is
// not the renderer's selection/copy implementation.
func (s Snapshot) PlainText() string {
	lines := make([]string, int(s.Rows))
	for row := 0; row < int(s.Rows); row++ {
		var b strings.Builder
		for col := 0; col < int(s.Cols); col++ {
			cell := s.Cells[row*int(s.Cols)+col]
			if cell.IsSpacer() {
				continue
			}
			if cell.Text == "" {
				b.WriteByte(' ')
				continue
			}
			b.WriteString(cell.Text)
		}
		lines[row] = strings.TrimRightFunc(b.String(), func(r rune) bool { return r == ' ' })
	}
	return strings.Join(lines, "\n")
}

// ValidUTF8 reports whether every copied text cell is valid UTF-8. Terminal
// cell text is expected to be a valid replacement-preserving Unicode string;
// this is a useful boundary assertion for Phase 0 fixtures.
func (s Snapshot) ValidUTF8() bool {
	for _, cell := range s.Cells {
		if !utf8.ValidString(cell.Text) {
			return false
		}
	}
	return true
}
