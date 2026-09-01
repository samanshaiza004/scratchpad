package ui

import (
	"fmt"
	"sort"
	"time"
	"unicode/utf8"

	"scratchpad/document"
	"scratchpad/editor"
	"scratchpad/language"

	. "go.hasen.dev/shirei"
	. "go.hasen.dev/shirei/widgets"
)

const (
	// Long logical lines are presented as deterministic chunks. Keeping the
	// chunk smaller than the old safety window materially reduces the amount
	// of Shirei shaping and temporary glyph state per frame.
	maxShapingBytes       = 16 << 10
	longLineChunkBytes    = maxShapingBytes
	maxChunkBoundaryBytes = 1 << 10
)

// VisualLine is the row-local bridge between the byte-oriented document and
// Shirei's rune/cluster-oriented shaping model. It never needs the rest of
// the document to translate a visible row.
type VisualLine struct {
	DocStart int
	DocEnd   int
	// LogicalStart and LogicalEnd retain the complete line range when the
	// shaped window is bounded for a pathological line.
	LogicalStart    int
	LogicalEnd      int
	Text            string
	Runes           []rune
	Layout          ShapedText
	layoutSpans     []StyleSpan
	TruncatedBefore bool
	TruncatedAfter  bool
	ChunkIndex      int
	ChunkCount      int

	sourceBytes []int
}

// BuildVisualLine copies and shapes one logical line. Callers should invoke it
// only for rows the viewport is actually building.
func BuildVisualLine(buffer *editor.Buffer, line int, style TextStyleAttrs) (VisualLine, bool) {
	return BuildVisualLineAround(buffer, line, 0, style)
}

// BuildVisualLineAround copies and shapes one bounded window of a logical
// line. For ordinary lines the window is the complete line. For pathological
// lines it is centered on anchor when possible, so the active caret remains
// visible without asking Shirei to shape megabytes synchronously.
func BuildVisualLineAround(buffer *editor.Buffer, line, anchor int, style TextStyleAttrs) (VisualLine, bool) {
	return buildVisualLineAround(buffer, line, anchor, style, nil, nil)
}

type EditorPresentationSource func(startByte, endByte int) []document.PresentationSpan

type EditorPresentationStyler func(kind document.PresentationKind, base TextStyleAttrs) []TextStyleFn

func buildVisualLineAround(buffer *editor.Buffer, line, anchor int, style TextStyleAttrs, presentation EditorPresentationSource, styler EditorPresentationStyler) (VisualLine, bool) {
	start, end, ok := buffer.LineRange(line)
	if !ok {
		return VisualLine{}, false
	}
	windowStart, windowEnd, chunkIndex, chunkCount := boundedLineWindow(buffer, start, end, anchor)
	data, err := buffer.Bytes(windowStart, windowEnd)
	if err != nil {
		return VisualLine{}, false
	}
	display, runes, sourceBytes := displayText(data)
	visual := VisualLine{
		DocStart:        windowStart,
		DocEnd:          windowEnd,
		LogicalStart:    start,
		LogicalEnd:      end,
		Text:            display,
		Runes:           runes,
		TruncatedBefore: windowStart > start,
		TruncatedAfter:  windowEnd < end,
		ChunkIndex:      chunkIndex,
		ChunkCount:      chunkCount,
		sourceBytes:     sourceBytes,
	}
	if presentation != nil && styler != nil {
		sourceSpans := presentation(windowStart, windowEnd)
		textSpans := presentationTextSpans(visual, sourceSpans, style, styler)
		visual.layoutSpans = presentationStyleSpans(visual, sourceSpans, style, styler)
		visual.Layout = ShapeText(display, style, textSpans...)
	} else {
		visual.Layout = ShapeText(display, style)
	}
	return visual, true
}

func presentationStyleSpans(visual VisualLine, sourceSpans []document.PresentationSpan, base TextStyleAttrs, styler EditorPresentationStyler) []StyleSpan {
	if len(sourceSpans) == 0 {
		return nil
	}
	spans := make([]StyleSpan, 0, len(sourceSpans))
	for _, sourceSpan := range sourceSpans {
		start := maxInt(sourceSpan.StartByte, visual.DocStart)
		end := minInt(sourceSpan.EndByte, visual.DocEnd)
		if start >= end {
			continue
		}
		from := visual.LocalByteToRune(start - visual.DocStart)
		to := visual.LocalByteToRune(end - visual.DocStart)
		if from >= to {
			continue
		}
		mods := styler(sourceSpan.Kind, base)
		if len(mods) > 0 {
			spans = append(spans, ResolveSpan(from, to, base, mods...))
		}
	}
	if len(spans) == 0 {
		return nil
	}
	return spans
}

func presentationTextSpans(visual VisualLine, sourceSpans []document.PresentationSpan, base TextStyleAttrs, styler EditorPresentationStyler) []TextSpan {
	if len(sourceSpans) == 0 {
		return nil
	}
	spans := make([]TextSpan, 0, len(sourceSpans))
	for _, sourceSpan := range sourceSpans {
		start := maxInt(sourceSpan.StartByte, visual.DocStart)
		end := minInt(sourceSpan.EndByte, visual.DocEnd)
		if start >= end {
			continue
		}
		from := visual.LocalByteToRune(start - visual.DocStart)
		to := visual.LocalByteToRune(end - visual.DocStart)
		if from >= to {
			continue
		}
		mods := styler(sourceSpan.Kind, base)
		if len(mods) > 0 {
			spans = append(spans, Span(from, to, mods...))
		}
	}
	if len(spans) == 0 {
		return nil
	}
	return spans
}

// displayText creates the Unicode projection used by Shirei while retaining
// a local display-rune to source-byte mapping. Invalid UTF-8 bytes are shown
// as explicit escapes and remain untouched in the authoritative buffer.
func displayText(source []byte) (string, []rune, []int) {
	var display []byte
	var sourceBytes []int
	sourceBytes = append(sourceBytes, 0)
	for at := 0; at < len(source); {
		r, size := utf8.DecodeRune(source[at:])
		if r == utf8.RuneError && size == 1 && source[at] >= utf8.RuneSelf {
			escape := fmt.Sprintf("\\x%02X", source[at])
			display = append(display, escape...)
			for i := range []rune(escape) {
				if i == len([]rune(escape))-1 {
					sourceBytes = append(sourceBytes, at+1)
				} else {
					sourceBytes = append(sourceBytes, at)
				}
			}
			at++
			continue
		}
		display = append(display, source[at:at+size]...)
		sourceBytes = append(sourceBytes, at+size)
		at += size
	}
	displayText := string(display)
	return displayText, []rune(displayText), sourceBytes
}

func boundedLineWindow(buffer *editor.Buffer, start, end, anchor int) (windowStart, windowEnd, chunkIndex, chunkCount int) {
	if end-start <= maxShapingBytes {
		return start, end, 0, 1
	}
	anchor = maxInt(start, minInt(anchor, end))
	lineBytes := end - start
	chunkCount = (lineBytes + longLineChunkBytes - 1) / longLineChunkBytes
	chunkIndex = (anchor - start) / longLineChunkBytes
	if chunkIndex >= chunkCount {
		chunkIndex = chunkCount - 1
	}
	windowStart = start + chunkIndex*longLineChunkBytes
	windowEnd = minInt(end, windowStart+longLineChunkBytes)
	windowStart, windowEnd = expandToClusterBoundaries(buffer, start, end, windowStart, windowEnd)
	for windowStart > start {
		byteAt, ok := buffer.ByteAt(windowStart)
		if ok && utf8.RuneStart(byteAt) {
			break
		}
		windowStart--
	}
	for windowEnd < end {
		byteAt, ok := buffer.ByteAt(windowEnd)
		if ok && utf8.RuneStart(byteAt) {
			break
		}
		windowEnd++
	}
	return windowStart, windowEnd, chunkIndex, chunkCount
}

// expandToClusterBoundaries keeps the small amount of shaping context needed
// for common combining and ZWJ sequences on the same side of a chunk. The
// expansion is bounded; an unusually huge single grapheme remains subject to
// the fixed-line fallback rather than turning a frame into an unbounded scan.
func expandToClusterBoundaries(buffer *editor.Buffer, lineStart, lineEnd, start, end int) (int, int) {
	if start > lineStart {
		clusterStart := buffer.PreviousCluster(start)
		clusterEnd := buffer.NextCluster(clusterStart)
		if clusterStart < start && clusterEnd > start && start-clusterStart <= maxChunkBoundaryBytes {
			start = clusterStart
		}
	}
	if end < lineEnd {
		clusterStart := buffer.PreviousCluster(end)
		clusterEnd := buffer.NextCluster(clusterStart)
		if clusterEnd > end && clusterEnd-end <= maxChunkBoundaryBytes {
			end = clusterEnd
		}
	}
	return start, end
}

// MoveLongLineChunk advances the caret by one bounded shaping chunk on the
// current logical line. Ordinary left/right motion remains cluster-aware and
// fine-grained; this operation gives a deterministic way to traverse a line
// that cannot be represented by one Shirei shaping request.
func MoveLongLineChunk(e *editor.ScratchEditor, forward, extend bool) bool {
	line, ok := e.Buffer.LineAt(e.Cursor)
	if !ok {
		return false
	}
	start, end, ok := e.Buffer.LineRange(line)
	if !ok || end-start <= longLineChunkBytes {
		return false
	}
	target := e.Cursor
	if forward {
		target = minInt(end, target+longLineChunkBytes)
	} else {
		target = maxInt(start, target-longLineChunkBytes)
	}
	if target == e.Cursor {
		return false
	}
	anchor := e.Anchor
	if extend {
		e.SetSelection(anchor, target)
	} else {
		e.SetCursor(target)
	}
	return true
}

func (v VisualLine) LocalByteToRune(offset int) int {
	if offset <= 0 {
		return 0
	}
	if offset >= v.sourceBytes[len(v.sourceBytes)-1] {
		return len(v.Runes)
	}
	return sort.Search(len(v.sourceBytes), func(i int) bool { return v.sourceBytes[i] >= offset })
}

func (v VisualLine) LocalRuneToByte(index int) int {
	if index <= 0 {
		return 0
	}
	if index >= len(v.sourceBytes) {
		return v.sourceBytes[len(v.sourceBytes)-1]
	}
	return v.sourceBytes[index]
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
	penX := float32(0)
	bounds := v.clusterBounds()
	var low, high float32
	found := false
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
				var candidates [2]float32
				candidateCount := 0
				if segment.Dir == LTR {
					if cluster == runeIndex {
						candidates[candidateCount] = penX
						candidateCount++
					}
					if after == runeIndex {
						candidates[candidateCount] = penX + glyph.XAdvance
						candidateCount++
					}
				} else {
					if cluster == runeIndex {
						candidates[candidateCount] = penX + glyph.XAdvance
						candidateCount++
					}
					if after == runeIndex {
						candidates[candidateCount] = penX
						candidateCount++
					}
				}
				for i := 0; i < candidateCount; i++ {
					x := candidates[i]
					if !found {
						low, high, found = x, x, true
					} else {
						if x < low {
							low = x
						}
						if x > high {
							high = x
						}
					}
				}
				penX += glyph.XAdvance
			}
		}
	}
	if !found {
		if runeIndex == len(v.Runes) {
			return penX
		}
		return 0
	}
	if affinity == editor.AffinityLeading {
		return low
	}
	return high
}

func (v VisualLine) clusterBounds() []int {
	bounds := []int{0, len(v.Runes)}
	for lineIndex := range v.Layout.Lines {
		line := &v.Layout.Lines[lineIndex]
		for segmentIndex := range line.Segments {
			for glyphIndex := range line.Segments[segmentIndex].Glyphs {
				cluster := int(line.Segments[segmentIndex].Glyphs[glyphIndex].Cluster)
				if cluster >= 0 && cluster <= len(v.Runes) {
					bounds = append(bounds, cluster)
				}
			}
		}
	}
	for i, r := range v.Runes {
		if r == '\n' {
			// Newline boundaries remain caret stops even when the shaper omits
			// a drawable glyph for the hard break.
			bounds = append(bounds, i, i+1)
		}
	}
	sort.Ints(bounds)
	unique := bounds[:0]
	for _, bound := range bounds {
		if len(unique) == 0 || unique[len(unique)-1] != bound {
			unique = append(unique, bound)
		}
	}
	return unique
}

func (v VisualLine) nextClusterBoundary(bounds []int, cluster int) int {
	index := sort.Search(len(bounds), func(i int) bool { return bounds[i] > cluster })
	if index == len(bounds) {
		return len(v.Runes)
	}
	return bounds[index]
}

type EditorViewOptions struct {
	Style             TextStyleAttrs
	RowHeight         float32
	ScrollY           *float32
	ScrollInitialized bool
	Rows              *editor.RowMap
	LineNumbers       bool
	Foldable          func(logicalLine int) bool
	FoldMarker        func(logicalLine int) string
	OnFoldToggle      func(logicalLine int)
	Presentation      EditorPresentationSource
	PresentationStyle EditorPresentationStyler
}

// EditableDocumentView binds the existing Shirei-backed editor view to the
// product document seam. The editor remains the content authority; this
// adapter only synchronizes revision/derived-state bookkeeping.
func EditableDocumentView(key any, doc *document.Document, options EditorViewOptions) {
	if doc == nil || doc.Editor == nil {
		return
	}
	if isDefaultEditorStyle(options.Style) {
		options.Style = EditorTextStyleForDocument(doc)
	}
	if options.Presentation == nil && language.ID(doc.RootLanguage) == language.Markdown && doc.DerivedCurrent() && doc.Projections.Markdown.Revision == doc.Revision() {
		code := doc.Projections.Code
		options.Presentation = func(startByte, endByte int) []document.PresentationSpan {
			spans := doc.Projections.Markdown.SpansIn(startByte, endByte)
			for _, span := range code.HighlightsIn(startByte, endByte) {
				spans = append(spans, document.PresentationSpan{StartByte: span.StartByte, EndByte: span.EndByte, Kind: codePresentationKind(span.Kind)})
			}
			return spans
		}
		options.PresentationStyle = MarkdownPresentationStyle
	}
	if options.Presentation == nil {
		code, ok := doc.DisplayCodeProjection()
		if ok {
			options.Presentation = func(startByte, endByte int) []document.PresentationSpan {
				spans := make([]document.PresentationSpan, 0, len(code.Highlights))
				for _, span := range code.HighlightsIn(startByte, endByte) {
					spans = append(spans, document.PresentationSpan{StartByte: span.StartByte, EndByte: span.EndByte, Kind: codePresentationKind(span.Kind)})
				}
				return spans
			}
			options.PresentationStyle = MarkdownPresentationStyle
		}
	}
	EditableView(key, doc.Editor, options)
	doc.SyncEditorState()
}

func codePresentationKind(kind document.HighlightKind) document.PresentationKind {
	switch kind {
	case document.HighlightComment:
		return document.PresentationCodeComment
	case document.HighlightKeyword:
		return document.PresentationCodeKeyword
	case document.HighlightString:
		return document.PresentationCodeString
	case document.HighlightNumber:
		return document.PresentationCodeNumber
	case document.HighlightType:
		return document.PresentationCodeType
	case document.HighlightFunction:
		return document.PresentationCodeFunction
	case document.HighlightMethod:
		return document.PresentationCodeMethod
	case document.HighlightVariable:
		return document.PresentationCodeVariable
	case document.HighlightConstant:
		return document.PresentationCodeConstant
	case document.HighlightProperty:
		return document.PresentationCodeProperty
	case document.HighlightOperator:
		return document.PresentationCodeOperator
	case document.HighlightPunctuation:
		return document.PresentationCodePunctuation
	case document.HighlightBuiltin:
		return document.PresentationCodeBuiltin
	case document.HighlightParameter:
		return document.PresentationCodeParameter
	case document.HighlightTag:
		return document.PresentationCodeTag
	case document.HighlightAttribute:
		return document.PresentationCodeAttribute
	default:
		return document.PresentationSyntax
	}
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
	rows := editor.IdentityRowMap(e.Buffer.LineCount())
	if options.Rows != nil {
		rows = *options.Rows
	}
	gutterWidth := float32(0)
	if options.LineNumbers {
		digits := len(fmt.Sprintf("%d", e.Buffer.LineCount()))
		gutterWidth = float32(digits*8 + 22)
	}
	ContainerWithKey(key, Attrs(Viewport, Expand, Focusable, Clip), func() {
		AutoFocus()
		FocusOnClick()
		PressAction()

		scrollY := Use[float32]("editor-scroll-y")
		if options.ScrollY != nil && options.ScrollInitialized {
			*scrollY = *options.ScrollY
		}
		firstVisible := Use[int]("editor-first-visible")
		lastVisible := Use[int]("editor-last-visible")
		caretBlink := Use[caretBlinkState]("editor-caret-blink")
		beforeCaret := takeEditorCaretSnapshot(e)
		if HasFocus() {
			WantKeyboard()
			processEditorInput(e, style, rowHeight, *scrollY, rows, gutterWidth)
		}
		caretActivity := beforeCaret.changed(e) || editorCaretInputActivity()
		editorFocused := HasFocus() && GetHost().WindowFocused

		VirtualListViewExt("editor-lines", VirtualListAttrs{
			ItemCount:       rows.Count(),
			ItemKey:         func(index int) any { logical, _ := rows.Logical(index); return logical },
			ItemHeight:      func(index int, width float32) float32 { return rowHeight },
			OutScrollOffset: scrollY,
			OutFirstVisible: firstVisible,
			OutLastVisible:  lastVisible,
			ItemView: func(index int, width float32) {
				logical, ok := rows.Logical(index)
				if !ok {
					return
				}
				anchor := 0
				if start, end, exists := e.Buffer.LineRange(logical); exists && e.Cursor >= start && e.Cursor <= end {
					anchor = e.Cursor
				}
				visual, ok := buildVisualLineAround(&e.Buffer, logical, anchor, style, options.Presentation, options.PresentationStyle)
				if !ok {
					return
				}
				ContainerWithKey(logical, Attrs(FixHeight(rowHeight), Expand, NoClip), func() {
					Container(Attrs(Row, Expand, NoClip), func() {
						if options.LineNumbers {
							Container(Attrs(FixWidth(gutterWidth), FixHeight(rowHeight), Pad2(0, 8), CrossMid), func() {
								if options.Foldable != nil && options.Foldable(logical) {
									foldButton := ProcessButtonEvents(false)
									marker := "▾"
									if options.FoldMarker != nil {
										marker = options.FoldMarker(logical)
									}
									Label(marker, FontSize(style.FontSize*0.85), TextColorVec(Vec4{0.42, 0.45, 0.5, 1}))
									if foldButton.Clicked && options.OnFoldToggle != nil {
										options.OnFoldToggle(logical)
									}
								}
								Label(fmt.Sprintf("%*d", len(fmt.Sprintf("%d", e.Buffer.LineCount())), logical+1), FontSize(style.FontSize*0.85), TextColorVec(Vec4{0.42, 0.45, 0.5, 1}))
							})
						}
						Container(Attrs(Grow(1), Expand, NoClip), func() {
							selectionFrom, selectionTo := visibleSelection(visual, e)
							ShapedTextLayout(visual.Layout, style, selectionFrom, selectionTo, visual.layoutSpans...)

							if e.Cursor >= visual.DocStart && e.Cursor <= visual.DocEnd {
								localRune := visual.LocalByteToRune(e.Cursor - visual.DocStart)
								x := visual.CaretX(localRune, e.Affinity)
								composition := e.Composition()
								ordinaryCaretEligible := editorFocused && e.Cursor == e.Anchor && composition.Text == ""
								blinkVisible := caretBlink.sync(time.Now(), ordinaryCaretEligible, caretActivity, GetHost().HeadlessRender, RequestNextFrame)
								showCaret := ordinaryCaretEligible && blinkVisible
								caret := editorCaretGeometry(rowHeight, style)
								if composition.Text != "" {
									// Keep the established full-row IME anchor independent
									// from the narrowed ordinary insertion caret.
									Container(Attrs(FloatVec(Vec2{x, 0}), MinSize(1, rowHeight), InFront, BackgroundVec(Vec4{0, 0, 20, 0})), func() {
										r := GetScreenRect()
										GetHost().CompositionPos = Vec2{r.Origin[0], r.Origin[1] + r.Size[1]}
									})
								} else {
									caretColor := Vec4{0, 0, 20, 1}
									if !showCaret {
										caretColor[3] = 0
									}
									Container(Attrs(FloatVec(Vec2{x, caret.Y}), MinSize(caret.Width, caret.Height), InFront, BackgroundVec(caretColor)), func() {
										r := GetScreenRect()
										GetHost().CaretPos = Vec2{r.Origin[0], r.Origin[1] + r.Size[1]}
										GetHost().CaretHeight = r.Size[1]
									})
								}

								if composition.Text != "" {
									compositionStyle := style
									compositionStyle.Underline = true
									Container(Attrs(FloatVec(Vec2{x, 0}), NoClip, InFront), func() {
										ShapedTextLayout(ShapeText(composition.Text, compositionStyle), compositionStyle, 0, 0)
									})
								}
							}
						})
					})
				})
			},
		})
		if options.ScrollY != nil {
			*options.ScrollY = *scrollY
		}
	})
}

func processEditorInput(e *editor.ScratchEditor, style TextStyleAttrs, rowHeight, scrollY float32, rows editor.RowMap, gutterWidth float32) {
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
		case frame.Key == KeyLeft && input.Modifiers&^ModShift == primary|ModAlt:
			MoveLongLineChunk(e, false, shift)
		case frame.Key == KeyRight && input.Modifiers&^ModShift == primary|ModAlt:
			MoveLongLineChunk(e, true, shift)
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
		visible := int((input.MousePoint[1] - content.Origin[1] + scrollY) / rowHeight)
		if visible < 0 {
			visible = 0
		}
		line, ok := rows.Logical(visible)
		if !ok {
			return
		}
		if input.MousePoint[0]-content.Origin[0] < gutterWidth {
			return
		}
		if visual, ok := BuildVisualLineAround(&e.Buffer, line, e.Cursor, style); ok {
			localRune, affinity := visual.HitTest(input.MousePoint[0] - content.Origin[0] - gutterWidth)
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
