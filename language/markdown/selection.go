package markdown

import (
	"bytes"
	"slices"

	"github.com/yuin/goldmark/v2/ast"
	markdownast "github.com/yuin/goldmark/v2/extension/ast"
	"github.com/yuin/goldmark/v2/text"
	"scratchpad/document"
)

// Selection bounds travel alongside presentation bounds in the existing walk.
// Unlike styling bounds, they include complete child constructs and delimiters.
type selectionNodeRange struct {
	start, end int
}

func (r *selectionNodeRange) include(start, end int) {
	if start >= 0 && start < end {
		r.start = min(r.start, start)
		r.end = max(r.end, end)
	}
}

func selectionSourceRange(node ast.Node, start, end int) selectionNodeRange {
	r := selectionNodeRange{start: start, end: end}
	if block, ok := node.(ast.BlockNode); ok {
		for _, segment := range block.Source() {
			r.include(segment.Start, segment.Stop)
		}
	}
	switch node := node.(type) {
	case *ast.HTMLBlock:
		for _, segment := range node.Value.Segments() {
			r.include(segment.Start, segment.Stop)
		}
	case *ast.RawHTML:
		for _, index := range node.Value.Indices() {
			r.include(index.Start, index.Stop)
		}
	case *ast.LinkReferenceDefinition:
		for _, value := range []text.Value{node.Label, node.Destination, node.Title} {
			for _, index := range value.Indices() {
				r.include(index.Start, index.Stop)
			}
		}
	}
	return r
}

func appendSelectionRange(projection *document.Projections, node ast.Node, source []byte, r selectionNodeRange) selectionNodeRange {
	selected := true
	switch node := node.(type) {
	case *ast.Emphasis:
		r = selectionDelimitedRange(node, source, r, 1)
	case *ast.Strong:
		r = selectionDelimitedRange(node, source, r, 2)
	case *markdownast.Strikethrough:
		width := 1
		if at := node.Pos(); at >= 0 && at+1 < len(source) && source[at+1] == '~' {
			width = 2
		}
		r = selectionDelimitedRange(node, source, r, width)
	case *ast.CodeSpan:
		start := node.Pos()
		end := start
		for end >= 0 && end < len(source) && source[end] == '`' {
			end++
		}
		if end > start {
			// A closer at the start of a continuation line has no value
			// index on that line. Step over its container prefix only.
			if r.end > 0 && r.end <= len(source) && source[r.end-1] == '\n' {
				for r.end < len(source) && (source[r.end] == ' ' || source[r.end] == '\t' || source[r.end] == '>') {
					r.end++
				}
			}
			r = selectionDelimitedRange(node, source, r, end-start)
		}
	case *ast.Link, *ast.Image:
		r = selectionLinkRange(node, source, r.end)
	case *ast.AutoLink:
		index := node.Text.Index()
		r = selectionNodeRange{index.Start, index.Stop}
	case *ast.Heading:
		r.start, r.end = headingRange(node, source)
		r.end = selectionContentEnd(source, r.start, r.end)
	case *ast.Paragraph:
		r.end = selectionContentEnd(source, r.start, r.end)
	case *ast.CodeBlock:
		r = selectionBlockRange(node, source, r)
		// Indentation is syntax too; Goldmark's value starts after it.
		for r.start > 0 && r.start <= len(source) && (source[r.start-1] == ' ' || source[r.start-1] == '\t') {
			r.start--
		}
		if node.CodeBlockKind == ast.CodeBlockKindFenced {
			r.end = selectionFenceEnd(node, source, r.end)
		}
	case *ast.List, *ast.ListItem, *ast.Blockquote, *ast.ThematicBreak, *ast.HTMLBlock, *ast.LinkReferenceDefinition, *markdownast.Table:
		r = selectionBlockRange(node, source, r)
	default:
		selected = false
	}
	if selected && projection != nil && r.start >= 0 && r.start < r.end && r.end <= len(source) {
		projection.SelectionRanges = append(projection.SelectionRanges, document.SelectionRange{StartByte: r.start, EndByte: r.end})
	}
	return r
}

// Adjacent delimiters are measured around complete children, not node.Pos():
// Goldmark assigns the same opener position to both nodes in ***nested***.
func selectionDelimitedRange(node ast.Node, source []byte, r selectionNodeRange, width int) selectionNodeRange {
	position := node.Pos()
	start, end := r.start-width, r.end+width
	if position < 0 || position >= len(source) || width <= 0 || start < 0 || end > len(source) || r.start >= r.end {
		return selectionNodeRange{start: len(source)}
	}
	for i := 0; i < width; i++ {
		if source[start+i] != source[position] || source[r.end+i] != source[position] {
			return selectionNodeRange{start: len(source)}
		}
	}
	return selectionNodeRange{start, end}
}

func selectionContentEnd(source []byte, start, end int) int {
	for end > start && end <= len(source) && (source[end-1] == '\n' || source[end-1] == '\r') {
		end--
	}
	return end
}

func selectionBlockRange(node ast.Node, source []byte, r selectionNodeRange) selectionNodeRange {
	if position := node.Pos(); position >= 0 && position < len(source) {
		r.include(position, position+1)
	}
	if r.start < r.end && r.end <= len(source) {
		// Segment stops may already be at the following line. Step back before
		// finding the last line, so an adjacent block is never swallowed.
		r.end = selectionContentEnd(source, r.start, lineEnd(source, r.end-1))
	}
	return r
}

func selectionFenceEnd(node *ast.CodeBlock, source []byte, end int) int {
	position := node.Pos()
	if position < 0 || position >= len(source) {
		return end
	}
	width := 0
	for position+width < len(source) && source[position+width] == source[position] {
		width++
	}
	next := lineEnd(source, end)
	if next >= len(source) {
		return end
	}
	next++
	// An unterminated fence can end with its container. Do not mistake a
	// following sibling (possibly of an ancestor) for its closing fence.
	for parent := ast.Node(node); parent != nil; parent = parent.Parent() {
		if sibling := parent.NextSibling(); sibling != nil && sibling.Pos() >= 0 && lineStart(source, sibling.Pos()) <= next {
			return end
		}
	}
	stop := lineEnd(source, next)
	at := next
	for at < stop && (source[at] == ' ' || source[at] == '\t' || source[at] == '>') {
		at++
	}
	open := at
	for at < stop && source[at] == source[position] {
		at++
	}
	if width >= 3 && at-open >= width && len(bytes.TrimSpace(source[at:stop])) == 0 {
		return selectionContentEnd(source, next, stop)
	}
	return end
}

// Recover only the boundary of an accepted link. Destination/title indices
// avoid reinterpreting parentheses, escaped punctuation, and container prefixes
// in multiline titles. Complete child bounds locate the label's closing ']'.
func selectionLinkRange(node ast.Node, source []byte, labelEnd int) selectionNodeRange {
	invalid := selectionNodeRange{start: len(source)}
	start := node.Pos()
	var reference *ast.ReferenceLink
	var destination text.SingleLineValue
	var title text.MultiLineValue
	switch node := node.(type) {
	case *ast.Link:
		reference, destination, title = node.Reference, node.Destination, node.Title
	case *ast.Image:
		reference, destination, title = node.Reference, node.Destination, node.Title
	}
	if start < 0 || start >= len(source) {
		return invalid
	}
	labelStart := start
	if source[labelStart] == '!' {
		labelStart++
	}
	if labelStart >= len(source) || source[labelStart] != '[' {
		return invalid
	}
	close := max(labelStart+1, labelEnd)
	for close < len(source) && (source[close] != ']' || isBackslashEscaped(source, labelStart, close)) {
		close++
	}
	if close >= len(source) {
		return invalid
	}
	at := close + 1
	if reference != nil {
		if reference.ReferenceLinkKind != ast.ReferenceLinkKindShortcut {
			if at >= len(source) || source[at] != '[' {
				return invalid
			}
			end := matchingBracket(source, at)
			if end < 0 {
				return invalid
			}
			at = end + 1
		}
		return selectionNodeRange{start, at}
	}
	if at >= len(source) || source[at] != '(' {
		return invalid
	}
	at++ // opening '('
	if index := destination.Index(); !destination.IsOwned() {
		at = max(at, index.Stop)
		if index.Start > 0 && source[index.Start-1] == '<' {
			at++ // angle destination's closing '>'
		}
	}
	for _, index := range title.Indices() {
		at = max(at, index.Stop+1) // title's closing quote or ')'
	}
	for at < len(source) && (isTableSpace(source[at]) || source[at] == '>') {
		at++
	}
	if at >= len(source) || source[at] != ')' {
		return invalid
	}
	return selectionNodeRange{start, at + 1}
}

func finishSelectionRanges(source []byte, projection *document.Projections) {
	// A stack closes each section at the next heading of equal/lower level,
	// retaining subsection headings and intervening whitespace in its parent.
	var open []document.Heading
	addSection := func(heading document.Heading, end int) {
		if heading.StartByte >= 0 && heading.StartByte < end && end <= len(source) {
			projection.SelectionRanges = append(projection.SelectionRanges, document.SelectionRange{StartByte: heading.StartByte, EndByte: end})
		}
	}
	for _, heading := range projection.Headings {
		for len(open) > 0 && open[len(open)-1].Level >= heading.Level {
			addSection(open[len(open)-1], heading.StartByte)
			open = open[:len(open)-1]
		}
		open = append(open, heading)
	}
	for _, heading := range open {
		addSection(heading, len(source))
	}
	slices.SortFunc(projection.SelectionRanges, func(a, b document.SelectionRange) int {
		if a.StartByte != b.StartByte {
			return a.StartByte - b.StartByte
		}
		return a.EndByte - b.EndByte
	})
	projection.SelectionRanges = slices.Compact(projection.SelectionRanges)
}
