package phase0

import (
	"math"

	shirei "go.hasen.dev/shirei"
	ghostty "go.mitchellh.com/libghostty"
)

// TerminalFontFamilies is the terminal-specific preference chain. Family
// names are preferences: Shirei skips unavailable faces and performs its
// script-aware fallback lookup for missing glyphs.
var TerminalFontFamilies = []string{
	"CommitMono",
	"OCR-B",
	"SF Mono",
	"Menlo",
	"Monaco",
	"Cascadia Mono",
	"Consolas",
	"Noto Sans Mono",
	"DejaVu Sans Mono",
	"Liberation Mono",
}

// GridMetrics are logical terminal cell dimensions. The eventual workbench
// will derive these from the active terminal font; Phase 0 keeps them explicit
// so column placement can be asserted without visual goldens.
type GridMetrics struct {
	CellWidth  float32
	CellHeight float32
	FontSize   float32
}

func (m GridMetrics) withDefaults() GridMetrics {
	if m.CellWidth <= 0 {
		m.CellWidth = 8
	}
	if m.CellHeight <= 0 {
		m.CellHeight = 18
	}
	if m.FontSize <= 0 {
		m.FontSize = 14
	}
	return m
}

// TerminalTextStyle returns the renderer's code-face policy without changing
// Scratchpad's document editor style. It is intentionally compatible with a
// future user preference by keeping the family list in one helper.
func TerminalTextStyle(fontSize float32) shirei.TextStyleAttrs {
	if fontSize <= 0 {
		fontSize = 14
	}
	style := shirei.TextStyleWith(shirei.DefaultTextStyle(), shirei.Fonts(TerminalFontFamilies...), shirei.FontSize(fontSize))
	return style
}

// CellPlacement records the fixed-cell container emitted for one leading cell.
// It is test-only evidence made useful to a future renderer integration; its
// coordinates are never inferred from shaped text advances.
type CellPlacement struct {
	Row    int
	Column int
	Span   int
	ID     shirei.ContainerId
}

type cellKey struct {
	Row    int
	Column int
}

// RenderSnapshot emits a proof renderer into the current Shirei container.
// Each leading terminal cell gets an explicit Float position and fixed size.
// Shirei still shapes the grapheme inside that cell, but it cannot decide the
// grid position or reorder the terminal's cell stream.
func RenderSnapshot(snapshot Snapshot, origin shirei.Vec2, metrics GridMetrics) []CellPlacement {
	metrics = metrics.withDefaults()
	placements := make([]CellPlacement, 0, len(snapshot.Cells))

	for row := 0; row < int(snapshot.Rows); row++ {
		for column := 0; column < int(snapshot.Cols); column++ {
			cell := snapshot.Cells[row*int(snapshot.Cols)+column]
			if cell.IsSpacer() {
				continue
			}
			span := 1
			if cell.Wide == CellWideGlyph && column+1 < int(snapshot.Cols) {
				span = 2
			}
			x := origin[0] + float32(column)*metrics.CellWidth
			y := origin[1] + float32(row)*metrics.CellHeight
			style := terminalCellTextStyle(snapshot, cell, metrics.FontSize)
			width := float32(span) * metrics.CellWidth

			id := shirei.ContainerWithKey(cellKey{Row: row, Column: column}, shirei.Attrs(
				shirei.NoAnimate,
				shirei.FixSize(width, metrics.CellHeight),
				shirei.Float(x, y),
				shirei.NoClip,
				shirei.SetTextStyle(style),
			), func() {
				if bg, ok := terminalCellBackground(snapshot, cell); ok {
					shirei.Element(shirei.Attrs(
						shirei.NoAnimate,
						shirei.FixSize(width, metrics.CellHeight),
						shirei.Float(0, 0),
						shirei.NoClip,
						shirei.BackgroundVec(bg),
					))
				}
				if cell.Text != "" {
					shirei.Text(cell.Text, style)
				}
			})
			placements = append(placements, CellPlacement{
				Row: row, Column: column, Span: span, ID: id,
			})
		}
	}

	if snapshot.Cursor.Visible && snapshot.Cursor.Row < snapshot.Rows && snapshot.Cursor.Column < snapshot.Cols {
		renderCursor(snapshot, origin, metrics)
	}
	return placements
}

func renderCursor(snapshot Snapshot, origin shirei.Vec2, metrics GridMetrics) {
	x := origin[0] + float32(snapshot.Cursor.Column)*metrics.CellWidth
	y := origin[1] + float32(snapshot.Cursor.Row)*metrics.CellHeight
	width, height, offsetY := metrics.CellWidth, metrics.CellHeight, float32(0)
	switch snapshot.Cursor.VisualStyle {
	case ghostty.CursorVisualStyleBar:
		width = 1
	case ghostty.CursorVisualStyleBlock:
		// Keep the full cell geometry.
	case ghostty.CursorVisualStyleUnderline:
		height = 2
		offsetY = metrics.CellHeight - height
	case ghostty.CursorVisualStyleBlockHollow:
		width = metrics.CellWidth
	}
	shirei.Element(shirei.Attrs(
		shirei.NoAnimate,
		shirei.FixSize(width, height),
		shirei.Float(x, y+offsetY),
		shirei.InFront,
		shirei.NoClip,
		shirei.BackgroundVec(rgbToHSLA(snapshot.Foreground)),
	))
}

func terminalCellTextStyle(snapshot Snapshot, cell Cell, fontSize float32) shirei.TextStyleAttrs {
	style := TerminalTextStyle(fontSize)
	fg := snapshot.Foreground
	if cell.Style.HasForeground {
		fg = cell.Style.Foreground
	}
	bg := snapshot.Background
	if cell.Style.HasBackground {
		bg = cell.Style.Background
	}
	if cell.Style.Inverse {
		fg, bg = bg, fg
	}
	style.TextColor = rgbToHSLA(fg)
	if cell.Style.Bold {
		style.Weight = shirei.WeightBold
	}
	if cell.Style.Italic {
		style.Style = shirei.StyleItalic
	}
	if cell.Style.Underline {
		style.Underline = true
	}
	if cell.Style.Strikethrough {
		style.Strike = true
	}
	return style
}

func terminalCellBackground(snapshot Snapshot, cell Cell) (shirei.Vec4, bool) {
	if !cell.Style.HasBackground && !cell.Style.Inverse {
		return shirei.Vec4{}, false
	}
	bg := snapshot.Background
	if cell.Style.HasBackground {
		bg = cell.Style.Background
	}
	if cell.Style.Inverse {
		fg := snapshot.Foreground
		if cell.Style.HasForeground {
			fg = cell.Style.Foreground
		}
		bg = fg
	}
	return rgbToHSLA(bg), true
}

// CellOrigin is the only coordinate calculation used by the proof renderer.
// It is deliberately independent of text shaping and is the assertion target
// for ASCII, wide cells, fallback glyphs, and styled rows.
func CellOrigin(origin shirei.Vec2, row, column int, metrics GridMetrics) shirei.Vec2 {
	metrics = metrics.withDefaults()
	return shirei.Vec2{
		origin[0] + float32(column)*metrics.CellWidth,
		origin[1] + float32(row)*metrics.CellHeight,
	}
}

func rgbToHSLA(rgb RGB) shirei.Vec4 {
	r := float64(rgb.R) / 255
	g := float64(rgb.G) / 255
	b := float64(rgb.B) / 255
	maxValue := math.Max(r, math.Max(g, b))
	minValue := math.Min(r, math.Min(g, b))
	l := (maxValue + minValue) / 2
	if maxValue == minValue {
		return shirei.Vec4{0, 0, float32(l * 100), 1}
	}
	delta := maxValue - minValue
	s := delta / (1 - math.Abs(2*l-1))
	var h float64
	switch maxValue {
	case r:
		h = math.Mod((g-b)/delta, 6)
	case g:
		h = (b-r)/delta + 2
	default:
		h = (r-g)/delta + 4
	}
	h *= 60
	if h < 0 {
		h += 360
	}
	return shirei.Vec4{float32(h), float32(s * 100), float32(l * 100), 1}
}
