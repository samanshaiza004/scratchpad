//go:build cgo && !treesitter_pure && !treesitter_none

package treesitter

import (
	"fmt"
	"sort"
	"strings"

	ts "github.com/tree-sitter/go-tree-sitter"
	treeSitterGo "github.com/tree-sitter/tree-sitter-go/bindings/go"

	"scratchpad/document"
	"scratchpad/editor"
)

type goImplementationCGo struct {
	parser      *ts.Parser
	language    *ts.Language
	highlight   *ts.Query
	tags        *ts.Query
	tree        *ts.Tree
	revision    uint64
	hasRevision bool
}

func newGoImplementation() (goImplementation, error) {
	language := ts.NewLanguage(treeSitterGo.Language())
	parser := ts.NewParser()
	if err := parser.SetLanguage(language); err != nil {
		parser.Close()
		return nil, err
	}
	highlight, queryErr := ts.NewQuery(language, GoHighlightsQuery)
	if queryErr != nil {
		parser.Close()
		return nil, queryErr
	}
	tags, queryErr := ts.NewQuery(language, GoTagsQuery)
	if queryErr != nil {
		highlight.Close()
		parser.Close()
		return nil, queryErr
	}
	return &goImplementationCGo{parser: parser, language: language, highlight: highlight, tags: tags}, nil
}

func (g *goImplementationCGo) Analyze(source []byte, revision uint64, edits []editor.SourceEdit) (document.CodeProjection, error) {
	if g.tree != nil && (!g.hasRevision || len(edits) == 0 || edits[0].BeforeRevision != g.revision) {
		g.tree.Close()
		g.tree = nil
	}
	if g.tree != nil {
		for _, edit := range edits {
			g.tree.Edit(&ts.InputEdit{
				StartByte: uint(edit.StartByte), OldEndByte: uint(edit.OldEndByte), NewEndByte: uint(edit.NewEndByte),
				StartPosition:  ts.Point{Row: uint(edit.StartPoint.Row), Column: uint(edit.StartPoint.Column)},
				OldEndPosition: ts.Point{Row: uint(edit.OldEndPoint.Row), Column: uint(edit.OldEndPoint.Column)},
				NewEndPosition: ts.Point{Row: uint(edit.NewEndPoint.Row), Column: uint(edit.NewEndPoint.Column)},
			})
		}
	}
	oldTree := g.tree
	g.tree = g.parser.Parse(source, oldTree)
	if oldTree != nil && oldTree != g.tree {
		oldTree.Close()
	}
	if g.tree == nil || g.tree.RootNode() == nil {
		return document.CodeProjection{}, fmt.Errorf("Go parser returned no tree")
	}
	g.revision, g.hasRevision = revision, true
	return g.lower(source), nil
}

func (g *goImplementationCGo) lower(source []byte) document.CodeProjection {
	highlights := captureHighlights(g.highlight, g.tree.RootNode(), source)
	symbols := captureSymbols(g.tags, g.tree.RootNode(), source)
	folds, selections := collectSyntaxRanges(g.tree.RootNode(), source)
	projection := document.NewCodeProjection(g.revision, "go", highlights, symbols, folds)
	projection.SelectionRanges = selections
	return projection
}

func (g *goImplementationCGo) Close() {
	if g == nil {
		return
	}
	if g.tree != nil {
		g.tree.Close()
	}
	if g.highlight != nil {
		g.highlight.Close()
	}
	if g.tags != nil {
		g.tags.Close()
	}
	if g.parser != nil {
		g.parser.Close()
	}
}

func captureHighlights(query *ts.Query, root *ts.Node, source []byte) []document.HighlightSpan {
	cursor := ts.NewQueryCursor()
	defer cursor.Close()
	captures := cursor.Captures(query, root, source)
	names := query.CaptureNames()
	spans := make([]document.HighlightSpan, 0)
	for {
		match, index := captures.Next()
		if match == nil {
			break
		}
		capture := match.Captures[index]
		start, end := int(capture.Node.StartByte()), int(capture.Node.EndByte())
		if start >= end || end > len(source) {
			continue
		}
		spans = append(spans, document.HighlightSpan{StartByte: start, EndByte: end, Kind: highlightKind(names[capture.Index])})
	}
	return spans
}

func captureSymbols(query *ts.Query, root *ts.Node, source []byte) []document.Symbol {
	cursor := ts.NewQueryCursor()
	defer cursor.Close()
	matches := cursor.Matches(query, root, source)
	names := query.CaptureNames()
	symbols := make([]document.Symbol, 0)
	for match := matches.Next(); match != nil; match = matches.Next() {
		var name string
		var nameStart, nameEnd int
		var kind string
		var start, end int
		for _, capture := range match.Captures {
			captureName := names[capture.Index]
			captureStart, captureEnd := int(capture.Node.StartByte()), int(capture.Node.EndByte())
			switch {
			case captureName == "name":
				name = string(source[captureStart:captureEnd])
				nameStart, nameEnd = captureStart, captureEnd
			case strings.HasPrefix(captureName, "definition."):
				kind = strings.TrimPrefix(captureName, "definition.")
				start, end = captureStart, captureEnd
			}
		}
		if kind != "" && name != "" && start >= 0 && end <= len(source) && nameStart >= start && nameEnd <= end {
			symbols = append(symbols, document.Symbol{Name: name, Kind: kind, StartByte: start, EndByte: end})
		}
	}
	sort.SliceStable(symbols, func(i, j int) bool { return symbols[i].StartByte < symbols[j].StartByte })
	return symbols
}

// collectSyntaxRanges lowers the existing analysis tree to byte ranges. A
// single cursor keeps traversal iterative, including for deeply nested syntax.
func collectSyntaxRanges(root *ts.Node, source []byte) ([]document.LanguageFold, []document.SelectionRange) {
	if root == nil {
		return nil, nil
	}
	folds := make([]document.LanguageFold, 0)
	var selections []document.SelectionRange
	cursor := root.Walk()
	defer cursor.Close()
	for {
		node := cursor.Node()
		start, end := int(node.StartByte()), int(node.EndByte())
		if node.IsNamed() && !node.IsMissing() && !node.IsError() {
			selections = append(selections, document.SelectionRange{StartByte: start, EndByte: end})
		}
		if start >= 0 && end <= len(source) && end-start > 1 && isFoldNode(node.Kind()) && bytesContainNewline(source[start:end]) {
			folds = append(folds, document.LanguageFold{StartByte: start, EndByte: end})
		}
		if cursor.GotoFirstChild() {
			continue
		}
		for !cursor.GotoNextSibling() {
			if !cursor.GotoParent() {
				return folds, normalizeSelectionRanges(selections, len(source))
			}
		}
	}
}
