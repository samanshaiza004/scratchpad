package ui

import (
	"sort"
	"unicode/utf8"

	"scratchpad/editor"

	. "go.hasen.dev/shirei"
	. "go.hasen.dev/shirei/widgets"
)

// VisualLine is the row-local bridge between the byte-oriented document and
// Shirei's rune/cluster-oriented shaping model. It never needs the rest of
// the document to translate a visible row.
type VisualLine struct {
	DocStart int
	DocEnd   int
	Text     string
	Runes    []rune
	Layout   ShapedText

	runeBytes []int
}

// BuildVisualLine copies and shapes one logical line. Callers should invoke it
// only for rows the viewport is actually building.
func BuildVisualLine(buffer *editor.Buffer, line int, style TextStyleAttrs) (VisualLine, bool) {
	start, end, ok := buffer.LineRange(line)
	if !ok {
		return VisualLine{}, false
	}
	data, err := buffer.Bytes(start, end)
	if err != nil {
		return VisualLine{}, false
	}
	text := string(data)
	runes := []rune(text)
	runeBytes := make([]int, len(runes)+1)
	for i, r := range runes {
		runeBytes[i+1] = runeBytes[i] + utf8.RuneLen(r)
	}
	return VisualLine{
		DocStart:  start,
		DocEnd:    end,
		Text:      text,
		Runes:     runes,
		Layout:    ShapeText(text, style),
		runeBytes: runeBytes,
	}, true
}

func (v VisualLine) LocalByteToRune(offset int) int {
	if offset <= 0 {
		return 0
	}
	if offset >= v.runeBytes[len(v.runeBytes)-1] {
		return len(v.Runes)
	}
	return sort.Search(len(v.runeBytes), func(i int) bool { return v.runeBytes[i] > offset }) - 1
}

func (v VisualLine) LocalRuneToByte(index int) int {
	if index <= 0 {
		return 0
	}
	if index >= len(v.runeBytes) {
		return v.runeBytes[len(v.runeBytes)-1]
	}
	return v.runeBytes[index]
}

// HitTest maps a shaped visual x-coordinate to a local rune boundary. The
// segment direction determines which side of an RTL glyph is the logical
// before/after side. Affinity records that visual choice for caret painting.
func (v VisualLine) HitTest(x float32) (int, editor.Affinity) {
	bounds := v.clusterBounds()
	penX := float32(0)
	for lineIndex := range v.Layout.Lines {
		line := &v.Layout.Lines[lineIndex]
		for segmentIndex := range line.Segments {
			segment := &line.Segments[segmentIndex]
			for glyphIndex := range segment.Glyphs {
				glyph := &segment.Glyphs[glyphIndex]
				cluster := int(glyph.Cluster)
				if cluster < 0 || cluster >= len(v.Runes) {
					continue
				}
				after := v.nextClusterBoundary(bounds, cluster)
				if penX+glyph.XAdvance >= x {
					leftSide := penX+(glyph.XAdvance/2) > x
					if segment.Dir == LTR {
						if leftSide {
							return cluster, editor.AffinityLeading
						}
						return after, editor.AffinityTrailing
					}
					if leftSide {
						return after, editor.AffinityLeading
					}
					return cluster, editor.AffinityTrailing
				}
				penX += glyph.XAdvance
			}
		}
	}
	if x <= 0 {
		return 0, editor.AffinityLeading
	}
	return len(v.Runes), editor.AffinityTrailing
}

// CaretX returns the visual x-coordinate for a local rune boundary. At a bidi
// boundary there can be two valid visual positions; affinity selects the
// lower or upper one, matching the side returned by HitTest.
func (v VisualLine) CaretX(runeIndex int, affinity editor.Affinity) float32 {
	runeIndex = maxInt(0, minInt(runeIndex, len(v.Runes)))
	positions := make(map[int][]float32)
	penX := float32(0)
	bounds := v.clusterBounds()
	for lineIndex := range v.Layout.Lines {
		line := &v.Layout.Lines[lineIndex]
		for segmentIndex := range line.Segments {
			segment := &line.Segments[segmentIndex]
			for glyphIndex := range segment.Glyphs {
				glyph := &segment.Glyphs[glyphIndex]
				cluster := int(glyph.Cluster)
				if cluster < 0 || cluster >= len(v.Runes) {
					continue
				}
				after := v.nextClusterBoundary(bounds, cluster)
				if segment.Dir == LTR {
					positions[cluster] = append(positions[cluster], penX)
					positions[after] = append(positions[after], penX+glyph.XAdvance)
				} else {
					positions[cluster] = append(positions[cluster], penX+glyph.XAdvance)
					positions[after] = append(positions[after], penX)
				}
				penX += glyph.XAdvance
			}
		}
	}
	xs := positions[runeIndex]
	if len(xs) == 0 {
		if runeIndex == len(v.Runes) {
			return penX
		}
		return 0
	}
	selected := xs[0]
	for _, x := range xs[1:] {
		if affinity == editor.AffinityLeading && x < selected {
			selected = x
		}
		if affinity == editor.AffinityTrailing && x > selected {
			selected = x
		}
	}
	return selected
}

func (v VisualLine) clusterBounds() []int {
	set := map[int]bool{0: true, len(v.Runes): true}
	for lineIndex := range v.Layout.Lines {
		line := &v.Layout.Lines[lineIndex]
		for segmentIndex := range line.Segments {
			for glyphIndex := range line.Segments[segmentIndex].Glyphs {
				cluster := int(line.Segments[segmentIndex].Glyphs[glyphIndex].Cluster)
				if cluster >= 0 && cluster <= len(v.Runes) {
					set[cluster] = true
				}
			}
		}
	}
	bounds := make([]int, 0, len(set))
	for bound := range set {
		bounds = append(bounds, bound)
	}
	sort.Ints(bounds)
	return bounds
}

func (v VisualLine) nextClusterBoundary(bounds []int, cluster int) int {
	index := sort.Search(len(bounds), func(i int) bool { return bounds[i] > cluster })
	if index == len(bounds) {
		return len(v.Runes)
	}
	return bounds[index]
}

type EditorViewOptions struct {
	Style     TextStyleAttrs
	RowHeight float32
}

// EditableView is the fixed-height Shirei view for ScratchEditor. It shapes
// only virtualized logical rows; the editor core remains unaware of glyphs,
// focus, clipboard transport, or native IME state.
func EditableView(key any, e *editor.ScratchEditor, options EditorViewOptions) {
	style := options.Style
	if style.FontSize == 0 && style.TextColor == (Vec4{}) && len(style.FontFamilies) == 0 {
		style = DefaultTextStyle()
	}
	rowHeight := options.RowHeight
	if rowHeight <= 0 {
		rowHeight = style.FontSize * 1.5
	}
	ContainerWithKey(key, Attrs(Viewport, Expand, Focusable, Clip), func() {
		AutoFocus()
		FocusOnClick()
		PressAction()

		scrollY := Use[float32]("editor-scroll-y")
		firstVisible := Use[int]("editor-first-visible")
		lastVisible := Use[int]("editor-last-visible")
		if HasFocus() {
			WantKeyboard()
			processEditorInput(e, style, rowHeight, *scrollY)
		}

		VirtualListViewExt("editor-lines", VirtualListAttrs{
			ItemCount:       e.Buffer.LineCount(),
			ItemKey:         func(index int) any { return index },
			ItemHeight:      func(index int, width float32) float32 { return rowHeight },
			OutScrollOffset: scrollY,
			OutFirstVisible: firstVisible,
			OutLastVisible:  lastVisible,
			ItemView: func(index int, width float32) {
				visual, ok := BuildVisualLine(&e.Buffer, index, style)
				if !ok {
					return
				}
				ContainerWithKey(index, Attrs(FixHeight(rowHeight), Expand, NoClip), func() {
					selectionFrom, selectionTo := visibleSelection(visual, e)
					ShapedTextLayout(visual.Layout, style, selectionFrom, selectionTo)

					if e.Cursor >= visual.DocStart && e.Cursor <= visual.DocEnd {
						localRune := visual.LocalByteToRune(e.Cursor - visual.DocStart)
						x := visual.CaretX(localRune, e.Affinity)
						composition := e.Composition()
						showCaret := e.Cursor == e.Anchor && composition.Text == ""
						caretColor := Vec4{0, 0, 20, 1}
						if !showCaret {
							caretColor[3] = 0
						}
						Container(Attrs(FloatVec(Vec2{x, 0}), MinSize(1, rowHeight), InFront, BackgroundVec(caretColor)), func() {
							r := GetScreenRect()
							caretPos := Vec2{r.Origin[0], r.Origin[1] + r.Size[1]}
							if composition.Text != "" {
								GetHost().CompositionPos = caretPos
							} else {
								GetHost().CaretPos = caretPos
								GetHost().CaretHeight = r.Size[1]
							}
						})

						if composition.Text != "" {
							compositionStyle := style
							compositionStyle.Underline = true
							Container(Attrs(FloatVec(Vec2{x, 0}), NoClip, InFront), func() {
								ShapedTextLayout(ShapeText(composition.Text, compositionStyle), compositionStyle, 0, 0)
							})
						}
					}
				})
			},
		})
	})
}

func processEditorInput(e *editor.ScratchEditor, style TextStyleAttrs, rowHeight, scrollY float32) {
	frame := GetFrameInput()
	input := GetInputState()
	composition := e.Composition()
	if input.Composition != "" {
		if composition.Text == "" {
			e.BeginComposition(input.Composition, input.CompositionSel)
		} else {
			e.UpdateComposition(input.Composition, input.CompositionSel)
		}
	} else if composition.Text != "" {
		e.CancelComposition()
	}

	if frame.Text != "" && input.Composition == "" {
		_ = e.Insert([]byte(frame.Text))
	}

	shift := input.Modifiers&ModShift != 0
	primary := PrimaryMod()
	if frame.Key != KeyCodeNone {
		switch {
		case frame.Key == KeyLeft && input.Modifiers&^ModShift == 0:
			e.MoveLeft(shift)
		case frame.Key == KeyRight && input.Modifiers&^ModShift == 0:
			e.MoveRight(shift)
		case frame.Key == KeyDeleteBackward && input.Modifiers&^ModShift == 0:
			_ = e.Backspace()
		case frame.Key == KeyDeleteForward && input.Modifiers&^ModShift == 0:
			_ = e.DeleteForward()
		case frame.Key == KeyEnter && input.Modifiers == 0:
			_ = e.Insert([]byte("\n"))
		case frame.Key == KeyA && input.Modifiers == primary:
			e.SelectAll()
		case frame.Key == KeyC && input.Modifiers == primary:
			if text := e.Copy(); text != "" {
				RequestTextCopy(text)
			}
		case frame.Key == KeyX && input.Modifiers == primary:
			if text, err := e.Cut(); err == nil && text != "" {
				RequestTextCopy(text)
			}
		case frame.Key == KeyV && input.Modifiers == primary:
			RequestPaste()
		case frame.Key == KeyZ && input.Modifiers == primary:
			_ = e.Undo()
		case frame.Key == KeyZ && input.Modifiers == primary|ModShift:
			_ = e.Redo()
		case frame.Key == KeyY && input.Modifiers == primary:
			_ = e.Redo()
		}
	}

	if IsClicked() || IsActive() {
		content := GetContentRect()
		line := int((input.MousePoint[1] - content.Origin[1] + scrollY) / rowHeight)
		if line < 0 {
			line = 0
		}
		if visual, ok := BuildVisualLine(&e.Buffer, line, style); ok {
			localRune, affinity := visual.HitTest(input.MousePoint[0] - content.Origin[0])
			position := visual.DocStart + visual.LocalRuneToByte(localRune)
			if IsClicked() && shift {
				e.SetSelection(e.Anchor, position)
			} else if IsClicked() {
				e.SetCursor(position)
			} else {
				e.SetSelection(e.Anchor, position)
			}
			e.SetAffinity(affinity)
		}
	}
}

func visibleSelection(visual VisualLine, e *editor.ScratchEditor) (from, to int) {
	anchor, cursor := e.Selection()
	if cursor < anchor {
		anchor, cursor = cursor, anchor
	}
	if cursor <= visual.DocStart || anchor >= visual.DocEnd {
		return 0, 0
	}
	if anchor < visual.DocStart {
		anchor = visual.DocStart
	}
	if cursor > visual.DocEnd {
		cursor = visual.DocEnd
	}
	return visual.LocalByteToRune(anchor - visual.DocStart), visual.LocalByteToRune(cursor - visual.DocStart)
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}
