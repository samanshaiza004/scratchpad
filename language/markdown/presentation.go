package markdown

import (
	"bytes"
	"strings"

	"github.com/yuin/goldmark/v2/ast"
	"github.com/yuin/goldmark/v2/extension"
	markdownast "github.com/yuin/goldmark/v2/extension/ast"
	"scratchpad/document"
)

// collectPresentation lowers the already-parsed Goldmark tree into sorted,
// source-byte-only presentation spans. It intentionally does not produce
// Shirei values or own source text; the editor converts only the visible row
// window to local rune spans at shape time.
func collectPresentation(root ast.Node, source []byte, revision uint64, projection *document.Projections) document.MarkdownPresentation {
	spans := make([]document.PresentationSpan, 0, 32)
	add := func(start, end int, kind document.PresentationKind) {
		if start < 0 {
			start = 0
		}
		if end > len(source) {
			end = len(source)
		}
		if start < end {
			spans = append(spans, document.PresentationSpan{StartByte: start, EndByte: end, Kind: kind})
		}
	}

	stack := make([]presentationNodeRange, 0, 8)
	_ = ast.Walk(root, func(node ast.Node, entering bool) (ast.WalkStatus, error) {
		if entering {
			collectStructuralProjection(node, source, projection)
			state := presentationNodeRange{start: len(source)}
			appendNodeValueRange(&state, node)
			stack = append(stack, state)
			return ast.WalkContinue, nil
		}
		state := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		switch node := node.(type) {
		case *ast.Heading:
			appendHeadingPresentation(add, node, source, state.start, state.end)
		case *ast.CodeBlock:
			start, end := blockRange(node, source, state.end)
			add(start, end, document.PresentationCodeBlock)
		case *ast.Blockquote:
			start, end := blockRange(node, source, state.end)
			add(start, end, document.PresentationBlockquote)
		case *ast.ListItem:
			appendListPresentation(add, node, source)
		case *ast.Emphasis:
			appendInlinePresentation(add, node, source, document.PresentationEmphasis, 1, state.start, state.end)
		case *ast.Strong:
			appendInlinePresentation(add, node, source, document.PresentationStrong, 2, state.start, state.end)
		case *ast.CodeSpan:
			if state.start < state.end {
				add(state.start, state.end, document.PresentationInlineCode)
			}
		case *ast.Link:
			appendLinkPresentation(add, node, source, state.start, state.end)
		case *ast.AutoLink:
			appendAutoLinkPresentation(add, node, source, state.start, state.end)
		case *markdownast.Strikethrough:
			appendInlinePresentation(add, node, source, document.PresentationStrike, 2, state.start, state.end)
		}
		if len(stack) > 0 && state.start < state.end {
			if state.start < stack[len(stack)-1].start {
				stack[len(stack)-1].start = state.start
			}
			if state.end > stack[len(stack)-1].end {
				stack[len(stack)-1].end = state.end
			}
		}
		return ast.WalkContinue, nil
	})
	return document.NewMarkdownPresentation(revision, spans)
}

func collectStructuralProjection(node ast.Node, source []byte, projection *document.Projections) {
	if projection == nil {
		return
	}
	switch node := node.(type) {
	case *ast.CodeBlock:
		if node.CodeBlockKind == ast.CodeBlockKindFenced {
			if lang, ok := node.Language(source); ok && strings.EqualFold(strings.TrimSpace(lang), "go") {
				if start, end, ok := fencedCodeRange(node); ok {
					projection.Injected = append(projection.Injected, document.InjectedRegion{StartByte: start, EndByte: end, Language: "go"})
				}
			}
		}
	case *ast.Heading:
		start, end := headingRange(node, source)
		id := ""
		if value, ok := node.Attribute("id"); ok {
			id = value.Str(nil)
		}
		projection.Headings = append(projection.Headings, document.Heading{
			Level: node.Level, Text: headingText(node, source), ID: id, StartByte: start, EndByte: end,
		})
	case *ast.ListItem:
		if extension.IsTask(node) {
			if start, markerStart, markerEnd, checked, ok := taskRange(node, source); ok {
				projection.Tasks = append(projection.Tasks, document.Task{
					Text: nodeText(node, source), Checked: checked,
					StartByte: start, EndByte: lineEnd(source, start), MarkerStart: markerStart, MarkerEnd: markerEnd,
				})
			}
		}
	case *ast.Link:
		if start, end, ok := presentationLinkSourceRange(node, source); ok {
			projection.Links = append(projection.Links, document.Link{Label: nodeText(node, source), Target: node.Destination.Value(source), StartByte: start, EndByte: end})
		}
	case *ast.AutoLink:
		if start, end, ok := inlineRange(node.Pos(), source, '<'); ok {
			projection.Links = append(projection.Links, document.Link{Label: node.Label.Value(source), Target: node.Destination.Value(source), StartByte: start, EndByte: end})
		}
	}
}

func fencedCodeRange(block *ast.CodeBlock) (int, int, bool) {
	segments := block.Value.Segments()
	if len(segments) == 0 {
		return 0, 0, false
	}
	start, end := segments[0].Start, segments[0].Stop
	for _, segment := range segments[1:] {
		if segment.Start < start {
			start = segment.Start
		}
		if segment.Stop > end {
			end = segment.Stop
		}
	}
	return start, end, start < end
}

type presentationNodeRange struct {
	start int
	end   int
}

func appendNodeValueRange(state *presentationNodeRange, node ast.Node) {
	add := func(start, end int) {
		if start < state.start {
			state.start = start
		}
		if end > state.end {
			state.end = end
		}
	}
	switch node := node.(type) {
	case *ast.Text:
		for _, index := range node.Value.Indices() {
			add(index.Start, index.Stop)
		}
	case *ast.CodeSpan:
		for _, index := range node.Value.Indices() {
			add(index.Start, index.Stop)
		}
	case *ast.AutoLink:
		index := node.Label.Index()
		if !index.IsEmpty() {
			add(index.Start, index.Stop)
		}
	case *ast.CodeBlock:
		for _, segment := range node.Value.Segments() {
			add(segment.Start, segment.Stop)
		}
	}
}

func appendHeadingPresentation(add func(int, int, document.PresentationKind), heading *ast.Heading, source []byte, contentStart, contentEnd int) {
	start, end := headingRange(heading, source)
	if start >= end {
		return
	}
	if contentStart < contentEnd {
		add(contentStart, minInt(contentEnd, lineEnd(source, contentStart)), document.PresentationHeading)
	}
	lineEndByte := lineEnd(source, start)
	if heading.HeadingKind == ast.HeadingKindSetext {
		underlineStart := lineEndByte
		if underlineStart < len(source) && source[underlineStart] == '\n' {
			underlineStart++
		}
		add(underlineStart, lineEnd(source, underlineStart), document.PresentationSyntax)
		return
	}
	markerEnd := start
	for markerEnd < lineEndByte && source[markerEnd] == '#' {
		markerEnd++
	}
	if markerEnd > start {
		for markerEnd < lineEndByte && (source[markerEnd] == ' ' || source[markerEnd] == '\t') {
			markerEnd++
		}
		add(start, markerEnd, document.PresentationSyntax)
	}
}

func appendInlinePresentation(add func(int, int, document.PresentationKind), node ast.Node, source []byte, kind document.PresentationKind, delimiterSize, start, end int) {
	if start >= end {
		return
	}
	add(start, end, kind)
	position := node.Pos()
	if position < 0 || position >= len(source) || delimiterSize <= 0 {
		return
	}
	add(position, minInt(start, position+delimiterSize), document.PresentationSyntax)
	lineEndByte := lineEnd(source, position)
	delimiter := source[position:minInt(len(source), position+delimiterSize)]
	closeAt := bytes.Index(source[end:lineEndByte], delimiter)
	if closeAt >= 0 {
		closeStart := end + closeAt
		add(closeStart, closeStart+delimiterSize, document.PresentationSyntax)
	}
}

func appendLinkPresentation(add func(int, int, document.PresentationKind), link *ast.Link, source []byte, labelStart, labelEnd int) {
	if labelStart < labelEnd {
		add(labelStart, labelEnd, document.PresentationLink)
	}
	start, end, ok := presentationLinkSourceRange(link, source)
	if !ok {
		return
	}
	add(start, minInt(end, labelStart), document.PresentationSyntax)
	add(labelEnd, end, document.PresentationSyntax)
}

func presentationLinkSourceRange(link *ast.Link, source []byte) (int, int, bool) {
	if link == nil || link.Pos() < 0 || link.Pos() >= len(source) || source[link.Pos()] != '[' {
		return 0, 0, false
	}
	if link.Reference == nil {
		return inlineRange(link.Pos(), source, '[')
	}
	close := matchingPresentationBracket(source, link.Pos())
	if close < 0 {
		return 0, 0, false
	}
	end := close + 1
	if link.Reference.ReferenceLinkKind == ast.ReferenceLinkKindFull || link.Reference.ReferenceLinkKind == ast.ReferenceLinkKindCollapsed {
		if close+1 >= len(source) || source[close+1] != '[' {
			return 0, 0, false
		}
		refClose := matchingPresentationBracket(source, close+1)
		if refClose < 0 {
			return 0, 0, false
		}
		end = refClose + 1
	}
	return link.Pos(), end, true
}

func matchingPresentationBracket(source []byte, start int) int {
	depth := 0
	for at := start; at < len(source); at++ {
		if source[at] == '\\' {
			at++
			continue
		}
		switch source[at] {
		case '[':
			depth++
		case ']':
			depth--
			if depth == 0 {
				return at
			}
		}
	}
	return -1
}

func appendAutoLinkPresentation(add func(int, int, document.PresentationKind), link *ast.AutoLink, source []byte, labelStart, labelEnd int) {
	if labelStart < labelEnd {
		add(labelStart, labelEnd, document.PresentationLink)
	}
	start, end, ok := inlineRange(link.Pos(), source, '<')
	if ok {
		add(start, minInt(end, labelStart), document.PresentationSyntax)
		add(labelEnd, end, document.PresentationSyntax)
	}
}

func appendListPresentation(add func(int, int, document.PresentationKind), item *ast.ListItem, source []byte) {
	position := item.Pos()
	if position < 0 {
		return
	}
	start := lineStart(source, position)
	end := lineEnd(source, start)
	at := start
	for at < end && (source[at] == ' ' || source[at] == '\t') {
		at++
	}
	if at < end && ((source[at] >= '0' && source[at] <= '9') || source[at] == '-' || source[at] == '+' || source[at] == '*') {
		for at < end && source[at] >= '0' && source[at] <= '9' {
			at++
		}
		if at < end && (source[at] == '.' || source[at] == ')' || source[at] == '-' || source[at] == '+' || source[at] == '*') {
			at++
			for at < end && (source[at] == ' ' || source[at] == '\t') {
				at++
			}
			add(start, at, document.PresentationListMarker)
		}
	}
	if taskLine, markerStart, markerEnd, _, ok := taskRange(item, source); ok && taskLine == start {
		add(markerStart, markerEnd, document.PresentationTaskMarker)
	}
}

func blockRange(node ast.Node, source []byte, contentEnd int) (int, int) {
	start := lineStart(source, node.Pos())
	if contentEnd <= start {
		contentEnd = node.Pos()
	}
	if contentEnd < start {
		contentEnd = start
	}
	end := lineEnd(source, contentEnd)
	if end < len(source) && source[end] == '\n' {
		end++
	}
	return start, end
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}
