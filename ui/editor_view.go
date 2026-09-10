package ui

import (
	"fmt"
	"reflect"
	"sort"
	"time"
	"unicode"
	"unicode/utf8"

	"scratchpad/document"
	"scratchpad/editor"
	"scratchpad/language"

	. "go.hasen.dev/shirei"
	. "go.hasen.dev/shirei/widgets"
	"golang.org/x/text/width"
)

const (
	// editorTabSize is the source-independent display policy for literal tabs.
	// Tabs remain one source byte; only the paint projection expands them to the
	// next four-column stop so shaping, caret placement, and hit testing agree.
	editorTabSize = 4

	// Long logical lines are presented as deterministic chunks. Keeping the
	// chunk smaller than the old safety window materially reduces the amount
	// of Shirei shaping and temporary glyph state per frame.
	maxShapingBytes       = 16 << 10
	longLineChunkBytes    = maxShapingBytes
	maxChunkBoundaryBytes = 1 << 10
	// This is Shirei's documented pen-baseline fraction. It is used only to
	// turn the public FontFace descender metrics into the block padding that
	// ShapedTextLayout applies around its text lines.
	shireiGlyphBaselineFrac = float32(0.82)
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
	WrapWidth       float32
	baseStyle       TextStyleAttrs
	blockPaddingTop float32

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
	return buildVisualLineAroundMax(buffer, line, anchor, style, 0, nil, nil)
}

// BuildVisualLineMax is the visual-row entry point for a known width. A
// positive width enables Shirei's soft wrapping while preserving the same
// local source-byte mapping used by the fixed logical-line view.
func BuildVisualLineMax(buffer *editor.Buffer, line, anchor int, style TextStyleAttrs, maxWidth float32) (VisualLine, bool) {
	return buildVisualLineAroundMax(buffer, line, anchor, style, maxWidth, nil, nil)
}

type EditorPresentationSource func(startByte, endByte int) []document.PresentationSpan

type EditorPresentationStyler func(kind document.PresentationKind, base TextStyleAttrs) []TextStyleFn

type EditorPresentationSpanStyler func(span document.PresentationSpan, base TextStyleAttrs) []TextStyleFn

func buildVisualLineAround(buffer *editor.Buffer, line, anchor int, style TextStyleAttrs, presentation EditorPresentationSource, styler EditorPresentationStyler) (VisualLine, bool) {
	return buildVisualLineAroundMaxStyled(buffer, line, anchor, style, 0, presentation, styler, nil)
}

func buildVisualLineAroundMax(buffer *editor.Buffer, line, anchor int, style TextStyleAttrs, maxWidth float32, presentation EditorPresentationSource, styler EditorPresentationStyler) (VisualLine, bool) {
	return buildVisualLineAroundMaxStyled(buffer, line, anchor, style, maxWidth, presentation, styler, nil)
}

func buildVisualLineAroundMaxStyled(buffer *editor.Buffer, line, anchor int, style TextStyleAttrs, maxWidth float32, presentation EditorPresentationSource, styler EditorPresentationStyler, spanStyler EditorPresentationSpanStyler) (VisualLine, bool) {
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
		WrapWidth:       maxWidth,
		baseStyle:       style,
		sourceBytes:     sourceBytes,
	}
	if presentation != nil && styler != nil {
		sourceSpans := presentation(windowStart, windowEnd)
		textSpans := presentationTextSpansStyled(visual, sourceSpans, style, styler, spanStyler)
		visual.layoutSpans = presentationStyleSpansStyled(visual, sourceSpans, style, styler, spanStyler)
		visual.Layout = ShapeTextMax(display, style, maxWidth, textSpans...)
	} else {
		visual.Layout = ShapeTextMax(display, style, maxWidth)
	}
	visual.blockPaddingTop = visual.computeTextBlockPaddingTop()
	return visual, true
}

func presentationStyleSpans(visual VisualLine, sourceSpans []document.PresentationSpan, base TextStyleAttrs, styler EditorPresentationStyler) []StyleSpan {
	return presentationStyleSpansStyled(visual, sourceSpans, base, styler, nil)
}

func presentationStyleSpansStyled(visual VisualLine, sourceSpans []document.PresentationSpan, base TextStyleAttrs, styler EditorPresentationStyler, spanStyler EditorPresentationSpanStyler) []StyleSpan {
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
		mods := presentationMods(sourceSpan, base, styler, spanStyler)
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
	return presentationTextSpansStyled(visual, sourceSpans, base, styler, nil)
}

func presentationTextSpansStyled(visual VisualLine, sourceSpans []document.PresentationSpan, base TextStyleAttrs, styler EditorPresentationStyler, spanStyler EditorPresentationSpanStyler) []TextSpan {
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
		mods := presentationMods(sourceSpan, base, styler, spanStyler)
		if len(mods) > 0 {
			spans = append(spans, Span(from, to, mods...))
		}
	}
	if len(spans) == 0 {
		return nil
	}
	return spans
}

func presentationMods(span document.PresentationSpan, base TextStyleAttrs, styler EditorPresentationStyler, spanStyler EditorPresentationSpanStyler) []TextStyleFn {
	if spanStyler != nil {
		return spanStyler(span, base)
	}
	if styler != nil {
		return styler(span.Kind, base)
	}
	return nil
}

// displayText creates the Unicode projection used by Shirei while retaining
// a local display-rune to source-byte mapping. Invalid UTF-8 bytes are shown
// as explicit escapes and remain untouched in the authoritative buffer.
// Literal tabs are expanded to the next editor tab stop in this paint-only
// projection. Every expanded rune maps to the tab's source boundary, with
// the final space mapping to the byte after the tab.
func displayText(source []byte) (string, []rune, []int) {
	var display []byte
	var sourceBytes []int
	sourceBytes = append(sourceBytes, 0)
	displayColumn := 0
	joinNext := false
	regionalIndicatorCount := 0
	for at := 0; at < len(source); {
		r, size := utf8.DecodeRune(source[at:])
		if r == utf8.RuneError && size == 1 && source[at] >= utf8.RuneSelf {
			escape := fmt.Sprintf("\\x%02X", source[at])
			display = append(display, escape...)
			escapeRunes := []rune(escape)
			for i := range escapeRunes {
				if i == len(escapeRunes)-1 {
					sourceBytes = append(sourceBytes, at+1)
				} else {
					sourceBytes = append(sourceBytes, at)
				}
			}
			displayColumn += len(escapeRunes)
			joinNext = false
			regionalIndicatorCount = 0
			at++
			continue
		}
		if r == '\t' {
			spaces := editorTabSize - displayColumn%editorTabSize
			for i := 0; i < spaces; i++ {
				display = append(display, ' ')
				if i == spaces-1 {
					sourceBytes = append(sourceBytes, at+size)
				} else {
					sourceBytes = append(sourceBytes, at)
				}
			}
			displayColumn += spaces
			at += size
			continue
		}
		display = append(display, source[at:at+size]...)
		sourceBytes = append(sourceBytes, at+size)
		if r == '\n' {
			displayColumn = 0
			joinNext = false
			regionalIndicatorCount = 0
		} else {
			displayColumn += editorDisplayRuneWidth(r, &joinNext, &regionalIndicatorCount)
		}
		at += size
	}
	displayText := string(display)
	return displayText, []rune(displayText), sourceBytes
}

// editorDisplayRuneWidth returns the number of monospace columns occupied by
// a source rune for tab-stop calculation. Shirei still owns the final pixel
// shaping; this only keeps tab stops aligned with the editor's code-grid
// conventions for wide, combining, and joined Unicode text.
func editorDisplayRuneWidth(r rune, joinNext *bool, regionalIndicatorCount *int) int {
	if r == '\u200d' {
		*joinNext = true
		return 0
	}
	if unicode.Is(unicode.Mn, r) || unicode.Is(unicode.Mc, r) || unicode.Is(unicode.Me, r) ||
		(r >= 0xfe00 && r <= 0xfe0f) || (r >= 0x1f3fb && r <= 0x1f3ff) {
		return 0
	}
	if *joinNext {
		*joinNext = false
		*regionalIndicatorCount = 0
		return 0
	}
	if r >= 0x1f1e6 && r <= 0x1f1ff {
		if *regionalIndicatorCount%2 == 0 {
			(*regionalIndicatorCount)++
			return 2
		}
		(*regionalIndicatorCount)++
		return 0
	}
	*regionalIndicatorCount = 0
	if kind := width.LookupRune(r).Kind(); kind == width.EastAsianWide || kind == width.EastAsianFullwidth {
		return 2
	}
	return 1
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
	return v.caretXOnLine(v.lineAtRune(runeIndex, affinity), runeIndex, affinity)
}

// caretXOnLine returns the caret's visual x within one shaped row. Keeping
// the row selection here matters for soft wraps: a boundary at the start of a
// continuation row has two possible visual positions, and aggregating all
// rows would choose the wrong one for vertical motion.
func (v VisualLine) caretXOnLine(lineIndex, runeIndex int, affinity editor.Affinity) float32 {
	runeIndex = maxInt(0, minInt(runeIndex, len(v.Runes)))
	lineIndex = maxInt(0, minInt(lineIndex, len(v.Layout.Lines)-1))
	penX := float32(0)
	bounds := v.clusterBounds()
	var low, high float32
	found := false
	if len(v.Layout.Lines) == 0 {
		return 0
	}
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
					low = minFloat(low, x)
					high = maxFloat(high, x)
				}
			}
			penX += glyph.XAdvance
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

// HitTestAt is the wrapped-row variant of HitTest. y is relative to the top
// of this logical line, so a pointer in a continuation row resolves to the
// corresponding source-rune boundary.
func (v VisualLine) HitTestAt(y, x float32) (int, editor.Affinity) {
	y -= v.textBlockPaddingTop()
	if y < 0 {
		y = 0
	}
	return v.hitTestLine(v.lineAtY(y), x)
}

func (v VisualLine) hitTestLine(lineIndex int, x float32) (int, editor.Affinity) {
	if len(v.Layout.Lines) == 0 {
		return 0, editor.AffinityLeading
	}
	lineIndex = maxInt(0, minInt(lineIndex, len(v.Layout.Lines)-1))
	line := &v.Layout.Lines[lineIndex]
	bounds := v.clusterBounds()
	penX := float32(0)
	for _, segment := range line.Segments {
		for _, glyph := range segment.Glyphs {
			cluster := int(glyph.Cluster)
			if cluster < 0 || cluster >= len(v.Runes) {
				continue
			}
			after := v.nextClusterBoundary(bounds, cluster)
			if penX+glyph.XAdvance >= x {
				leftSide := penX+glyph.XAdvance/2 > x
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
	if x <= 0 {
		start, _ := v.shapedLineRange(lineIndex)
		return start, editor.AffinityLeading
	}
	_, end := v.shapedLineRange(lineIndex)
	return end, editor.AffinityTrailing
}

// CaretPosition returns x, y, and height for a local source-rune boundary.
// The y coordinate is relative to the top of this logical line.
func (v VisualLine) CaretPosition(runeIndex int, affinity editor.Affinity) (float32, float32, float32) {
	if len(v.Layout.Lines) == 0 {
		return 0, 0, 0
	}
	runeIndex = maxInt(0, minInt(runeIndex, len(v.Runes)))
	lineIndex := v.lineAtRune(runeIndex, affinity)
	line := &v.Layout.Lines[lineIndex]
	bounds := v.clusterBounds()
	penX := float32(0)
	var low, high float32
	found := false
	for _, segment := range line.Segments {
		for _, glyph := range segment.Glyphs {
			cluster := int(glyph.Cluster)
			if cluster < 0 || cluster >= len(v.Runes) {
				continue
			}
			after := v.nextClusterBoundary(bounds, cluster)
			var candidates [2]float32
			count := 0
			if segment.Dir == LTR {
				if cluster == runeIndex {
					candidates[count] = penX
					count++
				}
				if after == runeIndex {
					candidates[count] = penX + glyph.XAdvance
					count++
				}
			} else {
				if cluster == runeIndex {
					candidates[count] = penX + glyph.XAdvance
					count++
				}
				if after == runeIndex {
					candidates[count] = penX
					count++
				}
			}
			for i := 0; i < count; i++ {
				x := candidates[i]
				if !found {
					low, high, found = x, x, true
				} else {
					low = minFloat(low, x)
					high = maxFloat(high, x)
				}
			}
			penX += glyph.XAdvance
		}
	}
	if !found {
		low = penX
		high = penX
	}
	if affinity == editor.AffinityTrailing {
		low = high
	}
	caretHeight := float32(CaretHeightForStyle(v.baseStyle))
	if caretHeight <= 0 {
		caretHeight = lineHeight(*line)
	}
	leading := float32(0)
	if lineIndex > 0 {
		leading = lineHeight(v.Layout.Lines[lineIndex-1]) - v.lineEm(lineIndex-1)
	}
	return low, v.textBlockPaddingTop() + v.lineTop(lineIndex) + leading, caretHeight
}

func (v VisualLine) Height(fallback float32) float32 {
	if len(v.Layout.Lines) == 0 {
		return fallback
	}
	total := v.lineEm(0)
	for i := 1; i < len(v.Layout.Lines); i++ {
		// Shirei carries the previous line's leading into the next line's
		// top padding. Consequently the first row starts at its em height,
		// while each later row is its own em plus the preceding row's leading.
		total += v.lineEm(i) + lineHeight(v.Layout.Lines[i-1]) - v.lineEm(i-1)
	}
	if total <= 0 {
		return fallback
	}
	return total + 2*v.textBlockPaddingTop()
}

// textBlockPaddingTop returns the padding captured from the shaped glyphs'
// public face metrics. Render-oracle tests guard agreement with the pinned
// Shirei renderer's block geometry.
func (v VisualLine) textBlockPaddingTop() float32 {
	return v.blockPaddingTop
}

func (v VisualLine) computeTextBlockPaddingTop() float32 {
	if len(v.Layout.Lines) == 0 {
		return 0
	}
	last := &v.Layout.Lines[len(v.Layout.Lines)-1]
	lineEm := v.baseStyle.FontSize
	if lineEm <= 0 {
		lineEm = DefaultTextSize
	}
	for _, segment := range last.Segments {
		for _, glyph := range segment.Glyphs {
			if size := v.styleAt(int(glyph.Cluster)).FontSize; size > lineEm {
				lineEm = size
			}
		}
	}
	pad := float32(0)
	if len(last.Segments) == 0 {
		pad = maxFloat(0, float32(CaretHeightForStyle(v.baseStyle))-lineEm)
	} else {
		for _, segment := range last.Segments {
			for _, glyph := range segment.Glyphs {
				st := v.styleAt(int(glyph.Cluster))
				em := st.FontSize
				if em <= 0 {
					em = lineEm
				}
				face := GetFace(glyph.FontId)
				descender := face.Descender
				if descender > 0 {
					descender = -descender
				}
				depth := -descender * face.InvUPM * em
				reserved := (1 - shireiGlyphBaselineFrac) * lineEm
				pad = maxFloat(pad, maxFloat(0, depth-reserved))
			}
		}
	}
	return pad
}

func (v VisualLine) styleAt(runeIndex int) TextStyleAttrs {
	for _, span := range v.layoutSpans {
		if runeIndex >= span.From && runeIndex < span.To {
			return span.Style
		}
	}
	return v.baseStyle
}

func (v VisualLine) lineEm(index int) float32 {
	if index < 0 || index >= len(v.Layout.Lines) {
		return maxFloat(v.baseStyle.FontSize, DefaultTextSize)
	}
	em := v.baseStyle.FontSize
	if em <= 0 {
		em = DefaultTextSize
	}
	for _, segment := range v.Layout.Lines[index].Segments {
		for _, glyph := range segment.Glyphs {
			if size := v.styleAt(int(glyph.Cluster)).FontSize; size > em {
				em = size
			}
		}
	}
	return em
}

func lineHeight(line ShapedTextLine) float32 {
	if line.Height > 0 {
		return line.Height
	}
	return DefaultTextSize * 1.5
}

func (v VisualLine) lineTop(index int) float32 {
	index = maxInt(0, minInt(index, len(v.Layout.Lines)))
	if index == 0 || len(v.Layout.Lines) == 0 {
		return 0
	}
	y := v.lineEm(0)
	for i := 1; i < index; i++ {
		y += v.lineEm(i) + lineHeight(v.Layout.Lines[i-1]) - v.lineEm(i-1)
	}
	return y
}

func (v VisualLine) lineBoxHeight(index int) float32 {
	if index <= 0 {
		return v.lineEm(0)
	}
	return v.lineEm(index) + lineHeight(v.Layout.Lines[index-1]) - v.lineEm(index-1)
}

func (v VisualLine) lineAtY(y float32) int {
	if len(v.Layout.Lines) == 0 || y <= 0 {
		return 0
	}
	for i := range v.Layout.Lines {
		if y < v.lineTop(i)+v.lineBoxHeight(i) {
			return i
		}
	}
	return len(v.Layout.Lines) - 1
}

func (v VisualLine) lineAtRune(runeIndex int, affinity editor.Affinity) int {
	if len(v.Layout.Lines) == 0 {
		return 0
	}
	for i := range v.Layout.Lines {
		start, end := v.shapedLineRange(i)
		if runeIndex < end || (runeIndex == end && affinity == editor.AffinityTrailing) || i == len(v.Layout.Lines)-1 {
			if runeIndex == start && i > 0 && affinity == editor.AffinityLeading {
				return i
			}
			return i
		}
	}
	return len(v.Layout.Lines) - 1
}

func (v VisualLine) shapedLineRange(index int) (int, int) {
	if index < 0 || index >= len(v.Layout.Lines) {
		return 0, len(v.Runes)
	}
	bounds := v.clusterBounds()
	start := len(v.Runes)
	end := 0
	for _, segment := range v.Layout.Lines[index].Segments {
		for _, glyph := range segment.Glyphs {
			cluster := int(glyph.Cluster)
			start = minInt(start, cluster)
			if cluster >= 0 && cluster < len(v.Runes) {
				end = maxInt(end, v.nextClusterBoundary(bounds, cluster))
			}
		}
	}
	if start == len(v.Runes) {
		start = end
	}
	return start, end
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
	Style                 TextStyleAttrs
	Theme                 Theme
	RowHeight             float32
	Wrap                  bool
	ScrollY               *float32
	ScrollInitialized     bool
	ScrollX               *float32
	ScrollXInitialized    bool
	Rows                  *editor.RowMap
	LineNumbers           bool
	Foldable              func(logicalLine int) bool
	FoldMarker            func(logicalLine int) string
	OnFoldToggle          func(logicalLine int)
	Presentation          EditorPresentationSource
	PresentationStyle     EditorPresentationStyler
	PresentationSpanStyle EditorPresentationSpanStyler
	// PresentationKey versions the paint-only presentation epoch. The editor
	// revision alone cannot distinguish an unstyled first frame from a later
	// frame at the same revision after the async Markdown worker publishes:
	// both share the revision, but only the later frame has spans. Callers
	// with a custom Presentation source must bump this key whenever the
	// spans change without an editor revision bump. EditableDocumentView
	// derives it from document projection state; zero means unversioned.
	PresentationKey uint64
	LineDecoration  func(logicalLine int) EditorLineDecoration
	LineSpacing     func(logicalLine int) float32
	// NoWrapLine optionally exempts individual logical lines from soft
	// wrapping. An exempt line shapes with maxWidth 0 (horizontal overflow,
	// like code) while the rest of the document keeps the shared wrap
	// width. It is paint-only: the buffer is untouched and nil means no
	// exemptions. EditableDocumentView exempts Markdown table lines so
	// source-visible pipe rows never wrap mid-row.
	NoWrapLine func(logicalLine int) bool
}

// EditorLineDecoration is a deliberately small, row-level presentation hook.
// It is paint-only: the document and editor never see these values.
type EditorLineDecoration struct {
	Background Vec4
	// Accent is an optional one-pixel bottom rule painted over the row. It is
	// used by source-visible Markdown table delimiters and remains paint-only.
	Accent Vec4
}

const currentLineHighlightAlpha float32 = 0.12

// currentEditorLineBackground layers the caret-line treatment over an
// existing semantic row decoration without replacing it. A zero decoration
// remains zero for inactive rows so callers can distinguish an unpainted row.
func currentEditorLineBackground(theme Theme, decoration Vec4, active bool) Vec4 {
	if !active {
		return decoration
	}
	if decoration != (Vec4{}) {
		decoration[3] = minFloat(1, decoration[3]+currentLineHighlightAlpha)
		return decoration
	}
	// The regular Highlight role is intentionally close to Paper and becomes
	// imperceptible at this opacity. SelectionHighlight supplies the cooler,
	// more contrastive tint used for active editor state without implying that
	// the row's contents are selected.
	highlight := theme.SelectionHighlight
	highlight[3] = currentLineHighlightAlpha
	return highlight
}

type visualLineCache struct {
	Revision     uint64
	Width        float32
	Wrap         bool
	Presentation uint64
	Lines        map[int]VisualLine
	Order        []int
}

func (c *visualLineCache) prepare(revision uint64, width float32, wrap bool, presentation uint64) {
	if c.Lines == nil || c.Revision != revision || c.Width != width || c.Wrap != wrap || c.Presentation != presentation {
		c.Revision = revision
		c.Width = width
		c.Wrap = wrap
		c.Presentation = presentation
		c.Lines = make(map[int]VisualLine)
		c.Order = nil
	}
}

// effectivePresentationKey folds the nil/non-nil presence into the explicit
// key so a naive custom presentation that leaves PresentationKey at zero
// still invalidates the unstyled entry when spans appear. Theme generation is
// mixed into the same key because syntax and semantic colors can change while
// document bytes and the projection revision remain unchanged.
func effectivePresentationKey(options EditorViewOptions) uint64 {
	key := uint64(0)
	if options.Presentation != nil {
		key = options.PresentationKey
		if key == 0 {
			key = 1
		}
	}
	if options.Theme.Generation == 0 {
		return key
	}
	const (
		offset = uint64(14695981039346656037)
		prime  = uint64(1099511628211)
	)
	hash := offset
	hash ^= key
	hash *= prime
	hash ^= options.Theme.Generation
	hash *= prime
	if hash == 0 {
		return 1
	}
	return hash
}

// documentPresentationKey versions disposable projection arrival at a fixed
// editor revision. DerivedRevision/Projections.Revision/Markdown.Revision all
// flip from stale to current when the async worker publishes, while the
// editor revision stays put; span counts additionally separate a rebased
// intermediate code view from the fresh parse at the same revision. The root
// language is mixed in so a mode switch without an edit cannot reuse styled
// rows. The result is non-zero whenever hasPresentation is true.
func documentPresentationKey(doc *document.Document, hasPresentation bool) uint64 {
	if doc == nil || !hasPresentation {
		return 0
	}
	const (
		offset = uint64(14695981039346656037)
		prime  = uint64(1099511628211)
	)
	hash := offset
	mix := func(value uint64) {
		hash ^= value
		hash *= prime
	}
	mix(doc.DerivedRevision)
	mix(doc.Projections.Revision)
	if doc.Projections.Valid {
		mix(1)
	}
	mix(doc.Projections.Markdown.Revision)
	mix(uint64(len(doc.Projections.Markdown.Spans)))
	mix(doc.Projections.Code.Revision)
	mix(uint64(len(doc.Projections.Code.Highlights)))
	if code, ok := doc.DisplayCodeProjection(); ok {
		mix(code.Revision)
		mix(uint64(len(code.Highlights)))
	} else {
		mix(0x9e3779b97f4a7c15)
	}
	for i := 0; i < len(doc.RootLanguage); i++ {
		mix(uint64(doc.RootLanguage[i]))
	}
	if hash == 0 {
		hash = 1
	}
	return hash
}

func cachedVisualLine(c *visualLineCache, buffer *editor.Buffer, line, anchor int, style TextStyleAttrs, width float32, presentation EditorPresentationSource, styler EditorPresentationStyler, spanStyler EditorPresentationSpanStyler) (VisualLine, bool) {
	if visual, ok := c.Lines[line]; ok {
		// WrapWidth participates in the hit check because one revision can
		// hold mixed widths: table lines shape unwrapped (width 0) while
		// the surrounding prose keeps the shared wrap width.
		if anchor >= visual.DocStart && anchor <= visual.DocEnd && visual.WrapWidth == width && reflect.DeepEqual(visual.baseStyle, style) {
			return visual, true
		}
	}
	visual, ok := buildVisualLineAroundMaxStyled(buffer, line, anchor, style, width, presentation, styler, spanStyler)
	if ok {
		c.Lines[line] = visual
		c.Order = append(c.Order, line)
		const cacheLimit = 256
		if len(c.Order) > cacheLimit {
			oldest := c.Order[0]
			c.Order = c.Order[1:]
			delete(c.Lines, oldest)
		}
	}
	return visual, ok
}

func anchorForLine(e *editor.ScratchEditor, line int) int {
	if start, end, ok := e.Buffer.LineRange(line); ok && e.Cursor >= start && e.Cursor <= end {
		return e.Cursor
	}
	return 0
}

func editorContentWidth(width, gutter float32) float32 {
	content := width - gutter
	if content < 1 {
		return 1
	}
	return content
}

func contentWidthIfWrapped(wrap bool, width float32) float32 {
	if !wrap {
		return 0
	}
	return width
}

// effectiveWrapWidth resolves the per-line soft-wrap width. Lines exempted by
// NoWrapLine shape with maxWidth 0 (unwrapped with horizontal overflow);
// every other line keeps the shared policy. Non-wrapping documents always
// resolve to 0.
func effectiveWrapWidth(wrap bool, noWrapLine func(int) bool, logical int, fullWidth float32) float32 {
	if !wrap {
		return 0
	}
	if noWrapLine != nil && noWrapLine(logical) {
		return 0
	}
	return fullWidth
}

// wrapWidthForLine applies the shared per-line policy to view options.
func wrapWidthForLine(options EditorViewOptions, logical int, fullWidth float32) float32 {
	return effectiveWrapWidth(options.Wrap, options.NoWrapLine, logical, fullWidth)
}

// isTableLine reports whether a logical line intersects a BlockTable
// projection. It is paint-only: it never touches the buffer and returns
// false unless Markdown projections are current, so stale or non-Markdown
// views keep the shared wrap policy.
func isTableLine(doc *document.Document, logical int) bool {
	if doc == nil || doc.Editor == nil || doc.RootLanguage != string(language.Markdown) || !doc.DerivedCurrent() {
		return false
	}
	start, end, ok := doc.Editor.Buffer.LineRange(logical)
	if !ok {
		return false
	}
	for _, block := range doc.Projections.Blocks {
		if block.Kind != document.BlockTable {
			continue
		}
		if block.StartByte < end && block.EndByte > start {
			return true
		}
	}
	return false
}

// overflowCaretPadding keeps the caret a small distance from the viewport
// edge when the overflow lane follows it horizontally.
const overflowCaretPadding float32 = 16

func clampScrollX(v float32) float32 {
	if v < 0 {
		return 0
	}
	return v
}

// isOverflowLine reports whether a logical line renders in the horizontal
// overflow lane: any line resolved as unwrapped (wrapWidthForLine == 0 via
// NoWrapLine, or a globally unwrapped document like code). Wrapped prose
// never overflows and always renders at x=0.
func isOverflowLine(options EditorViewOptions, logical int) bool {
	if !options.Wrap {
		return true
	}
	return options.NoWrapLine != nil && options.NoWrapLine(logical)
}

// overflowXOffset resolves the paint-only x translation for one logical
// line. Wrapped prose always returns 0; unwrapped rows translate by
// -scrollX. The gutter is a sibling of the shifted content and stays fixed.
func overflowXOffset(scrollX float32, unwrapped bool) float32 {
	scrollX = clampScrollX(scrollX)
	if !unwrapped || scrollX <= 0 {
		return 0
	}
	return -scrollX
}

// overflowXOffsetForLine is the per-line convenience over overflowXOffset.
func overflowXOffsetForLine(options EditorViewOptions, logical int, scrollX float32) float32 {
	return overflowXOffset(scrollX, isOverflowLine(options, logical))
}

// adjustScrollXForCaret follows the caret just enough to keep it visible.
// CaretX is text-relative (unshifted) and viewportWidth is the text content
// width (editorContentWidth). Unwrapped rows scroll minimally with a small
// padding; wrapped prose resets to 0 (ignored) so prose never slides.
func adjustScrollXForCaret(scrollX, caretX, viewportWidth float32, unwrapped bool) float32 {
	if !unwrapped {
		return 0
	}
	scrollX = clampScrollX(scrollX)
	if viewportWidth <= 0 {
		return scrollX
	}
	if caretX-scrollX < 0 {
		return maxFloat(0, caretX-overflowCaretPadding)
	}
	if caretX-scrollX > viewportWidth-overflowCaretPadding {
		return maxFloat(0, caretX-viewportWidth+overflowCaretPadding)
	}
	return scrollX
}

// overflowHitX maps a mouse x (relative to the text content origin) through
// the overflow lane. Unwrapped rows add scrollX back; wrapped prose ignores
// it, mirroring overflowXOffset.
func overflowHitX(mouseX, scrollX float32, unwrapped bool) float32 {
	if !unwrapped {
		return mouseX
	}
	return mouseX + clampScrollX(scrollX)
}

func minFloat(a, b float32) float32 {
	if a < b {
		return a
	}
	return b
}

func maxFloat(a, b float32) float32 {
	if a > b {
		return a
	}
	return b
}

// EditableDocumentView binds the existing Shirei-backed editor view to the
// product document seam. The editor remains the content authority; this
// adapter only synchronizes revision/derived-state bookkeeping.
func EditableDocumentView(key any, doc *document.Document, options EditorViewOptions) {
	if doc == nil || doc.Editor == nil {
		return
	}
	options.Theme = normalizeTheme(options.Theme)
	if isDefaultEditorStyle(options.Style) {
		options.Style = EditorTextStyleForDocumentWithTheme(doc, options.Theme)
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
		options.PresentationStyle = MarkdownPresentationStyleForTheme(options.Theme)
		options.PresentationSpanStyle = MarkdownPresentationSpanStyleForTheme(options.Theme)
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
			options.PresentationStyle = MarkdownPresentationStyleForTheme(options.Theme)
			options.PresentationSpanStyle = MarkdownPresentationSpanStyleForTheme(options.Theme)
		}
	}
	options.PresentationKey = documentPresentationKey(doc, options.Presentation != nil)
	if options.NoWrapLine == nil && language.ID(doc.RootLanguage) == language.Markdown {
		options.NoWrapLine = func(logicalLine int) bool { return isTableLine(doc, logicalLine) }
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

// EditableView is the Shirei view for ScratchEditor. It virtualizes logical
// buffer lines, while prose lines may occupy several shaped visual rows. The
// editor core remains unaware of glyphs, focus, clipboard transport, or native
// IME state.
func EditableView(key any, e *editor.ScratchEditor, options EditorViewOptions) {
	options.Theme = normalizeTheme(options.Theme)
	theme := options.Theme
	style := options.Style
	if style.FontSize == 0 && style.TextColor == (Vec4{}) && len(style.FontFamilies) == 0 {
		style = DefaultTextStyle()
		style.TextColor = theme.Ink
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
		gutterWidth = float32(digits*8 + 23)
	}
	caretLine, hasCaretLine := e.Buffer.LineAt(e.Cursor)
	ContainerWithKey(key, Attrs(Viewport, Expand, Focusable, Clip), func() {
		AutoFocus()
		FocusOnClick()
		PressAction()

		scrollY := Use[float32]("editor-scroll-y")
		if options.ScrollY != nil && options.ScrollInitialized {
			*scrollY = *options.ScrollY
		}
		scrollX := Use[float32]("editor-scroll-x")
		if options.ScrollX != nil && options.ScrollXInitialized {
			*scrollX = clampScrollX(*options.ScrollX)
		}
		*scrollX = clampScrollX(*scrollX)
		firstVisible := Use[int]("editor-first-visible")
		lastVisible := Use[int]("editor-last-visible")
		lineCache := Use[visualLineCache]("editor-visual-lines")
		caretBlink := Use[caretBlinkState]("editor-caret-blink")
		beforeCaret := takeEditorCaretSnapshot(e)
		presentationKey := effectivePresentationKey(options)
		if caretLine, ok := e.Buffer.LineAt(e.Cursor); ok && !isOverflowLine(options, caretLine) {
			// Wrapped prose never slides sideways: reset the lane as soon
			// as the caret returns to prose so a previous wide-row offset
			// does not linger. Unwrapped rows keep scrollX for follow.
			*scrollX = 0
		}
		frameScrollX := *scrollX
		var pendingScrollX float32
		havePendingScrollX := false
		if HasFocus() {
			WantKeyboard()
			processEditorInput(e, style, rowHeight, *scrollY, rows, gutterWidth, options.Wrap, options.NoWrapLine, lineCache, options.Presentation, options.PresentationStyle, options.PresentationSpanStyle, presentationKey, options.LineSpacing, frameScrollX)
		}
		caretActivity := beforeCaret.changed(e) || editorCaretInputActivity()
		editorFocused := HasFocus() && GetHost().WindowFocused

		VirtualListViewExt("editor-lines", VirtualListAttrs{
			ItemCount: rows.Count(),
			ItemKey:   func(index int) any { logical, _ := rows.Logical(index); return logical },
			ItemHeight: func(index int, width float32) float32 {
				if !options.Wrap {
					return rowHeight
				}
				logical, ok := rows.Logical(index)
				if !ok {
					return rowHeight
				}
				contentWidth := editorContentWidth(width, gutterWidth)
				lineCache.prepare(e.Revision(), contentWidth, options.Wrap, presentationKey)
				lineWidth := wrapWidthForLine(options, logical, contentWidth)
				if lineWidth <= 0 {
					return rowHeight
				}
				visual, ok := cachedVisualLine(lineCache, &e.Buffer, logical, anchorForLine(e, logical), style, lineWidth, options.Presentation, options.PresentationStyle, options.PresentationSpanStyle)
				if !ok {
					return rowHeight
				}
				extra := float32(0)
				if options.LineSpacing != nil {
					extra = maxFloat(0, options.LineSpacing(logical))
				}
				return visual.Height(rowHeight) + extra
			},
			OutScrollOffset: scrollY,
			OutFirstVisible: firstVisible,
			OutLastVisible:  lastVisible,
			ItemView: func(index int, width float32) {
				logical, ok := rows.Logical(index)
				if !ok {
					return
				}
				fullWidth := editorContentWidth(width, gutterWidth)
				contentWidth := contentWidthIfWrapped(options.Wrap, fullWidth)
				lineCache.prepare(e.Revision(), contentWidth, options.Wrap, presentationKey)
				lineWidth := wrapWidthForLine(options, logical, fullWidth)
				visual, ok := cachedVisualLine(lineCache, &e.Buffer, logical, anchorForLine(e, logical), style, lineWidth, options.Presentation, options.PresentationStyle, options.PresentationSpanStyle)
				if !ok {
					return
				}
				itemHeight := rowHeight
				if lineWidth > 0 {
					itemHeight = visual.Height(rowHeight)
				}
				if options.LineSpacing != nil {
					itemHeight += maxFloat(0, options.LineSpacing(logical))
				}
				decoration := EditorLineDecoration{}
				if options.LineDecoration != nil {
					decoration = options.LineDecoration(logical)
				}
				currentLine := hasCaretLine && logical == caretLine
				lineBackground := currentEditorLineBackground(theme, decoration.Background, currentLine)
				rowAttrs := Attrs(FixHeight(itemHeight), Expand, NoClip)
				if lineBackground != (Vec4{}) {
					rowAttrs = AttrsWith(rowAttrs, BackgroundVec(lineBackground))
				}
				ContainerWithKey(logical, rowAttrs, func() {
					Container(Attrs(Row, Expand, NoClip), func() {
						if options.LineNumbers {
							gutterBackground := theme.Paper
							if currentLine {
								gutterBackground = lineBackground
							}
							lineNumberColor := theme.Muted
							if currentLine {
								lineNumberColor = theme.Ink
							}
							Container(Attrs(FixWidth(gutterWidth-1), FixHeight(itemHeight), Pad2(0, 8), CrossAlign(AlignStart), BackgroundVec(gutterBackground)), func() {
								if options.Foldable != nil && options.Foldable(logical) {
									foldButton := ProcessButtonEvents(false)
									marker := "▾"
									if options.FoldMarker != nil {
										marker = options.FoldMarker(logical)
									}
									markerColor := theme.Muted
									if foldButton.Hovered {
										markerColor = theme.Focus
									}
									Label(marker, FontSize(style.FontSize*0.85), TextColorVec(markerColor))
									if foldButton.Clicked && options.OnFoldToggle != nil {
										options.OnFoldToggle(logical)
									}
								}
								Label(fmt.Sprintf("%*d", len(fmt.Sprintf("%d", e.Buffer.LineCount())), logical+1), FontSize(style.FontSize*0.85), TextColorVec(lineNumberColor))
							})
							Element(Attrs(FixWidth(1), FixHeight(itemHeight), BackgroundVec(theme.Shadow), NoAnimate))
						}
						Container(Attrs(Grow(1), Expand, Clip), func() {
							unwrapped := isOverflowLine(options, logical)
							renderScrollX := frameScrollX
							if e.Cursor >= visual.DocStart && e.Cursor <= visual.DocEnd && unwrapped {
								localRune := visual.LocalByteToRune(e.Cursor - visual.DocStart)
								caretX, _, _ := visual.CaretPosition(localRune, e.Affinity)
								renderScrollX = adjustScrollXForCaret(frameScrollX, caretX, fullWidth, true)
								if renderScrollX != frameScrollX {
									pendingScrollX = renderScrollX
									havePendingScrollX = true
								}
							}
							xOff := overflowXOffset(renderScrollX, unwrapped)
							renderRow := func() {
								selectionFrom, selectionTo := visibleSelection(visual, e)
								ShapedTextLayout(visual.Layout, style, selectionFrom, selectionTo, visual.layoutSpans...)

								if e.Cursor >= visual.DocStart && e.Cursor <= visual.DocEnd {
									localRune := visual.LocalByteToRune(e.Cursor - visual.DocStart)
									x, caretY, caretHeight := visual.CaretPosition(localRune, e.Affinity)
									composition := e.Composition()
									ordinaryCaretEligible := editorFocused && e.Cursor == e.Anchor && composition.Text == ""
									blinkVisible := caretBlink.sync(time.Now(), ordinaryCaretEligible, caretActivity, GetHost().HeadlessRender, RequestNextFrame)
									showCaret := ordinaryCaretEligible && blinkVisible
									caret := editorCaretGeometry(rowHeight, style)
									if caretHeight > 0 {
										caret.Height = caretHeight
									}
									// CaretPosition is in the same padded text block that
									// ShapedTextLayout paints. Do not center it a second time
									// inside the logical row; that moves it away from the ink
									// and breaks wrapped-row/descender alignment.
									caret.Y = 0
									if composition.Text != "" {
										// Keep the established full-row IME anchor independent
										// from the narrowed ordinary insertion caret.
										Container(Attrs(FloatVec(Vec2{x, caretY}), MinSize(1, rowHeight), InFront, BackgroundVec(Vec4{0, 0, 20, 0})), func() {
											r := GetScreenRect()
											GetHost().CompositionPos = Vec2{r.Origin[0], r.Origin[1] + r.Size[1]}
										})
									} else {
										caretColor := theme.Ink
										if !showCaret {
											caretColor[3] = 0
										}
										Container(Attrs(FloatVec(Vec2{x, caretY + caret.Y}), MinSize(caret.Width, caret.Height), InFront, BackgroundVec(caretColor)), func() {
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
							}
							if xOff != 0 {
								Container(Attrs(FloatVec(Vec2{xOff, 0}), NoClip), renderRow)
							} else {
								renderRow()
							}
							if decoration.Accent != (Vec4{}) {
								Container(Attrs(Float(0, itemHeight-1), Expand, FixHeight(1), InFront, NoAnimate), func() {
									Element(Attrs(Expand, BackgroundVec(decoration.Accent), NoAnimate))
								})
							}
						})
					})
				})
			},
		})
		if havePendingScrollX {
			*scrollX = clampScrollX(pendingScrollX)
		}
		if options.ScrollY != nil {
			*options.ScrollY = *scrollY
		}
		if options.ScrollX != nil {
			*options.ScrollX = *scrollX
		}
	})
}

func processEditorInput(e *editor.ScratchEditor, style TextStyleAttrs, rowHeight, scrollY float32, rows editor.RowMap, gutterWidth float32, wrap bool, noWrapLine func(int) bool, lineCache *visualLineCache, presentation EditorPresentationSource, styler EditorPresentationStyler, spanStyler EditorPresentationSpanStyler, presentationKey uint64, spacing func(int) float32, scrollX float32) {
	frame := GetFrameInput()
	input := GetInputState()
	mouseSelection := Use[editorMouseSelectionState]("editor-mouse-selection")
	content := GetContentRect()
	lineWidth := contentWidthIfWrapped(wrap, editorContentWidth(content.Size[0], gutterWidth))
	lineWidthFor := func(logical int) float32 {
		return effectiveWrapWidth(wrap, noWrapLine, logical, lineWidth)
	}
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
	wordMod := ModCtrl
	if primary == ModCmd {
		wordMod = ModAlt
	}
	pageLines := 1
	if rowHeight > 0 && content.Size[1] > 0 {
		pageLines = maxInt(1, int(content.Size[1]/rowHeight))
	}
	if frame.Key != KeyCodeNone {
		switch {
		case frame.Key == KeyUp && input.Modifiers&^ModShift == 0:
			moveEditorVerticalLayoutWithWrapPolicy(e, style, rows, -1, shift, wrap, lineWidth, lineWidthFor, lineCache, presentation, styler, spanStyler, presentationKey)
		case frame.Key == KeyDown && input.Modifiers&^ModShift == 0:
			moveEditorVerticalLayoutWithWrapPolicy(e, style, rows, 1, shift, wrap, lineWidth, lineWidthFor, lineCache, presentation, styler, spanStyler, presentationKey)
		case frame.Key == KeyPageUp && input.Modifiers&^ModShift == 0:
			e.PageUp(pageLines, shift)
		case frame.Key == KeyPageDown && input.Modifiers&^ModShift == 0:
			e.PageDown(pageLines, shift)
		case frame.Key == KeyHome && input.Modifiers&^ModShift == primary:
			e.MoveDocumentStart(shift)
		case frame.Key == KeyEnd && input.Modifiers&^ModShift == primary:
			e.MoveDocumentEnd(shift)
		case frame.Key == KeyHome && input.Modifiers&^ModShift == 0:
			moveEditorLineBoundary(e, false, shift)
		case frame.Key == KeyEnd && input.Modifiers&^ModShift == 0:
			moveEditorLineBoundary(e, true, shift)
		case frame.Key == KeyLeft && input.Modifiers&^ModShift == primary|ModAlt:
			MoveLongLineChunk(e, false, shift)
		case frame.Key == KeyRight && input.Modifiers&^ModShift == primary|ModAlt:
			MoveLongLineChunk(e, true, shift)
		case frame.Key == KeyLeft && input.Modifiers&^ModShift == wordMod:
			e.MoveWordLeft(shift)
		case frame.Key == KeyRight && input.Modifiers&^ModShift == wordMod:
			e.MoveWordRight(shift)
		case frame.Key == KeyDeleteBackward && input.Modifiers&^ModShift == wordMod:
			_ = e.DeleteWordBackward()
		case frame.Key == KeyDeleteForward && input.Modifiers&^ModShift == wordMod:
			_ = e.DeleteWordForward()
		case frame.Key == KeyTab && input.Modifiers == 0:
			_ = e.Indent()
		case frame.Key == KeyTab && input.Modifiers == ModShift:
			_ = e.Outdent()
		case frame.Key == KeyCode(']') && input.Modifiers == primary:
			_ = e.Indent()
		case frame.Key == KeyCode('[') && input.Modifiers == primary:
			_ = e.Outdent()
		case frame.Key == KeyK && input.Modifiers == primary|ModShift:
			_ = e.DeleteLine()
		case frame.Key == KeyEnter && input.Modifiers == primary:
			_ = e.InsertLineBelow()
		case frame.Key == KeyEnter && input.Modifiers == primary|ModShift:
			_ = e.InsertLineAbove()
		case (frame.Key == KeyUp || frame.Key == KeyDown) && input.Modifiers == ModAlt:
			if frame.Key == KeyUp {
				_ = e.MoveLineUp()
			} else {
				_ = e.MoveLineDown()
			}
		case (frame.Key == KeyUp || frame.Key == KeyDown) && input.Modifiers == ModAlt|ModShift:
			if frame.Key == KeyUp {
				_ = e.DuplicateLineUp()
			} else {
				_ = e.DuplicateLineDown()
			}
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
		case frame.Key == KeyL && input.Modifiers == primary:
			e.SelectLine()
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
		if input.MousePoint[0]-content.Origin[0] < gutterWidth {
			return
		}
		targetY := input.MousePoint[1] - content.Origin[1] + scrollY
		lineWidth := contentWidthIfWrapped(wrap, editorContentWidth(content.Size[0], gutterWidth))
		var line int
		var visual VisualLine
		var localY float32
		var ok bool
		if wrap {
			line, localY, visual, ok = visualLineAtYWithWrapPolicy(e, rows, targetY, style, rowHeight, lineWidth, lineWidthFor, lineCache, presentation, styler, spanStyler, presentationKey, spacing)
		} else {
			visible := int(targetY / rowHeight)
			if visible < 0 {
				visible = 0
			}
			line, ok = rows.Logical(visible)
			if ok {
				visual, ok = BuildVisualLineAround(&e.Buffer, line, e.Cursor, style)
			}
		}
		if ok {
			unwrapped := !wrap || (noWrapLine != nil && noWrapLine(line))
			hitX := overflowHitX(input.MousePoint[0]-content.Origin[0]-gutterWidth, scrollX, unwrapped)
			localRune, affinity := visual.HitTestAt(localY, hitX)
			position := visual.DocStart + visual.LocalRuneToByte(localRune)
			if IsClicked() {
				applyEditorClickSelection(e, mouseSelection, line, position, frame.ClickCount, shift)
			} else if mouseSelection.WordDrag {
				selectDraggedWord(e, mouseSelection, position)
			} else {
				e.SetSelection(e.Anchor, position)
			}
			e.SetAffinity(affinity)
		}
	}
	if frame.Mouse == MouseRelease {
		mouseSelection.WordDrag = false
	}
}

type editorMouseSelectionState struct {
	WordDrag  bool
	WordStart int
	WordEnd   int
}

func applyEditorClickSelection(e *editor.ScratchEditor, selection *editorMouseSelectionState, line, position, clickCount int, shift bool) {
	if e == nil || selection == nil {
		return
	}
	switch {
	case clickCount >= 3:
		if start, end, ok := e.Buffer.LineRange(line); ok {
			e.SetSelection(start, end)
		}
		selection.WordDrag = false
	case clickCount == 2:
		if start, end, ok := e.Buffer.WordRangeAt(position); ok {
			e.SetSelection(start, end)
			selection.WordDrag = true
			selection.WordStart = start
			selection.WordEnd = end
		} else {
			e.SetCursor(position)
			selection.WordDrag = false
		}
	case shift:
		selection.WordDrag = false
		e.SetSelection(e.Anchor, position)
	default:
		selection.WordDrag = false
		e.SetCursor(position)
	}
}

func selectDraggedWord(e *editor.ScratchEditor, selection *editorMouseSelectionState, position int) {
	if e == nil || selection == nil {
		return
	}
	start, end, ok := e.Buffer.WordRangeAt(position)
	if !ok {
		return
	}
	switch {
	case end <= selection.WordStart:
		// Keep the selection direction consistent with a drag to the left.
		e.SetSelection(selection.WordEnd, start)
	case start >= selection.WordEnd:
		e.SetSelection(selection.WordStart, end)
	default:
		e.SetSelection(selection.WordStart, selection.WordEnd)
	}
}

func visualLineAtY(e *editor.ScratchEditor, rows editor.RowMap, targetY float32, style TextStyleAttrs, rowHeight, width float32, cache *visualLineCache, presentation EditorPresentationSource, styler EditorPresentationStyler, spanStyler EditorPresentationSpanStyler, presentationKey uint64, spacing func(int) float32) (int, float32, VisualLine, bool) {
	return visualLineAtYWithWrapPolicy(e, rows, targetY, style, rowHeight, width, nil, cache, presentation, styler, spanStyler, presentationKey, spacing)
}

func visualLineAtYWithWrapPolicy(e *editor.ScratchEditor, rows editor.RowMap, targetY float32, style TextStyleAttrs, rowHeight, width float32, lineWidthFor func(int) float32, cache *visualLineCache, presentation EditorPresentationSource, styler EditorPresentationStyler, spanStyler EditorPresentationSpanStyler, presentationKey uint64, spacing func(int) float32) (int, float32, VisualLine, bool) {
	if targetY < 0 {
		targetY = 0
	}
	cache.prepare(e.Revision(), width, true, presentationKey)
	var top float32
	for visible := 0; visible < rows.Count(); visible++ {
		line, ok := rows.Logical(visible)
		if !ok {
			continue
		}
		visualWidth := width
		if lineWidthFor != nil {
			visualWidth = lineWidthFor(line)
		}
		visual, ok := cachedVisualLine(cache, &e.Buffer, line, anchorForLine(e, line), style, visualWidth, presentation, styler, spanStyler)
		if !ok {
			continue
		}
		height := visual.Height(rowHeight)
		extra := float32(0)
		if spacing != nil {
			extra = maxFloat(0, spacing(line))
		}
		if targetY < top+height+extra || visible == rows.Count()-1 {
			return line, targetY - top, visual, true
		}
		top += height + extra
	}
	return 0, 0, VisualLine{}, false
}

// moveEditorVertical moves through visible rows while using the shaped caret
// position as the column. The row map is authoritative here: folded logical
// lines cannot become accidental destinations for keyboard navigation.
func moveEditorVertical(e *editor.ScratchEditor, style TextStyleAttrs, rows editor.RowMap, delta int, extend bool) bool {
	return moveEditorVerticalLayout(e, style, rows, delta, extend, false, 0, nil, nil, nil, nil, 0)
}

func moveEditorVerticalLayout(e *editor.ScratchEditor, style TextStyleAttrs, rows editor.RowMap, delta int, extend bool, wrap bool, width float32, cache *visualLineCache, presentation EditorPresentationSource, styler EditorPresentationStyler, spanStyler EditorPresentationSpanStyler, presentationKey uint64) bool {
	return moveEditorVerticalLayoutWithWrapPolicy(e, style, rows, delta, extend, wrap, width, nil, cache, presentation, styler, spanStyler, presentationKey)
}

func moveEditorVerticalLayoutWithWrapPolicy(e *editor.ScratchEditor, style TextStyleAttrs, rows editor.RowMap, delta int, extend bool, wrap bool, width float32, lineWidthFor func(int) float32, cache *visualLineCache, presentation EditorPresentationSource, styler EditorPresentationStyler, spanStyler EditorPresentationSpanStyler, presentationKey uint64) bool {
	line, ok := e.Buffer.LineAt(e.Cursor)
	if !ok {
		return false
	}
	visible, ok := rows.Visible(line)
	if !ok {
		return false
	}
	currentStart, _, ok := e.Buffer.LineRange(line)
	if !ok {
		return false
	}
	current, ok := verticalVisualLineWithWrapPolicy(e, line, e.Cursor, style, wrap, width, lineWidthFor, cache, presentation, styler, spanStyler, presentationKey)
	if !ok {
		return false
	}
	currentRune := current.LocalByteToRune(e.Cursor - current.DocStart)
	currentRow := current.lineAtRune(currentRune, e.Affinity)
	targetVisible := visible
	targetRow := currentRow + delta
	if targetRow < 0 || targetRow >= len(current.Layout.Lines) {
		targetVisible += delta
		targetRow = 0
		if delta < 0 {
			targetRow = -1 // selected after the target line is shaped below
		}
	}
	targetLine, ok := rows.Logical(targetVisible)
	if !ok {
		return false
	}
	x, hasPreferredX := e.PreferredVerticalX()
	if !hasPreferredX {
		x = current.caretXOnLine(currentRow, currentRune, e.Affinity)
	}
	targetStart, targetEnd, ok := e.Buffer.LineRange(targetLine)
	if !ok {
		return false
	}
	byteColumn := e.Cursor - currentStart
	anchor := targetStart + maxInt(0, minInt(byteColumn, targetEnd-targetStart))
	target, ok := verticalVisualLineWithWrapPolicy(e, targetLine, anchor, style, wrap, width, lineWidthFor, cache, presentation, styler, spanStyler, presentationKey)
	if !ok {
		return false
	}
	if targetRow < 0 {
		targetRow = len(target.Layout.Lines) - 1
	}
	if targetRow >= len(target.Layout.Lines) {
		targetRow = len(target.Layout.Lines) - 1
	}
	targetRune, affinity := target.hitTestLine(targetRow, x)
	position := target.DocStart + target.LocalRuneToByte(targetRune)
	if extend {
		e.SetSelection(e.Anchor, position)
	} else {
		e.SetCursor(position)
	}
	e.SetAffinity(affinity)
	e.SetPreferredVerticalX(x)
	return true
}

func verticalVisualLine(e *editor.ScratchEditor, line, anchor int, style TextStyleAttrs, wrap bool, width float32, cache *visualLineCache, presentation EditorPresentationSource, styler EditorPresentationStyler, spanStyler EditorPresentationSpanStyler, presentationKey uint64) (VisualLine, bool) {
	return verticalVisualLineWithWrapPolicy(e, line, anchor, style, wrap, width, nil, cache, presentation, styler, spanStyler, presentationKey)
}

func verticalVisualLineWithWrapPolicy(e *editor.ScratchEditor, line, anchor int, style TextStyleAttrs, wrap bool, width float32, lineWidthFor func(int) float32, cache *visualLineCache, presentation EditorPresentationSource, styler EditorPresentationStyler, spanStyler EditorPresentationSpanStyler, presentationKey uint64) (VisualLine, bool) {
	if wrap && cache != nil {
		cache.prepare(e.Revision(), width, true, presentationKey)
		visualWidth := width
		if lineWidthFor != nil {
			visualWidth = lineWidthFor(line)
		}
		return cachedVisualLine(cache, &e.Buffer, line, anchor, style, visualWidth, presentation, styler, spanStyler)
	}
	return BuildVisualLineAround(&e.Buffer, line, anchor, style)
}

func moveEditorLineBoundary(e *editor.ScratchEditor, end bool, extend bool) bool {
	line, ok := e.Buffer.LineAt(e.Cursor)
	if !ok {
		return false
	}
	start, lineEnd, ok := e.Buffer.LineRange(line)
	if !ok {
		return false
	}
	position := start
	if end {
		position = lineEnd
	}
	if extend {
		e.SetSelection(e.Anchor, position)
	} else {
		e.SetCursor(position)
	}
	if end {
		e.SetAffinity(editor.AffinityTrailing)
	}
	return true
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
