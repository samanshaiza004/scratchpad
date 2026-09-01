//go:build !cgo || treesitter_pure

package treesitter

import (
	"fmt"
	"sort"
	"strings"

	gotreesitter "github.com/odvcencio/gotreesitter"
	"github.com/odvcencio/gotreesitter/grammars"

	"scratchpad/document"
	"scratchpad/editor"
)

type goImplementationPure struct {
	parser      *gotreesitter.Parser
	language    *gotreesitter.Language
	highlight   *gotreesitter.Query
	tags        *gotreesitter.Query
	tree        *gotreesitter.Tree
	revision    uint64
	hasRevision bool
}

func newGoImplementation() (goImplementation, error) {
	language := grammars.GoLanguage()
	highlight, err := gotreesitter.NewQuery(GoHighlightsQuery, language)
	if err != nil {
		return nil, err
	}
	tags, err := gotreesitter.NewQuery(PureTagsQuery(), language)
	if err != nil {
		return nil, err
	}
	return &goImplementationPure{parser: gotreesitter.NewParser(language), language: language, highlight: highlight, tags: tags}, nil
}

func (g *goImplementationPure) Analyze(source []byte, revision uint64, edits []editor.SourceEdit) (document.CodeProjection, error) {
	if g.tree != nil && (!g.hasRevision || len(edits) == 0 || edits[0].BeforeRevision != g.revision) {
		g.tree.Release()
		g.tree = nil
	}
	if g.tree != nil {
		for _, edit := range edits {
			g.tree.Edit(gotreesitter.InputEdit{
				StartByte: uint32(edit.StartByte), OldEndByte: uint32(edit.OldEndByte), NewEndByte: uint32(edit.NewEndByte),
				StartPoint:  gotreesitter.Point{Row: uint32(edit.StartPoint.Row), Column: uint32(edit.StartPoint.Column)},
				OldEndPoint: gotreesitter.Point{Row: uint32(edit.OldEndPoint.Row), Column: uint32(edit.OldEndPoint.Column)},
				NewEndPoint: gotreesitter.Point{Row: uint32(edit.NewEndPoint.Row), Column: uint32(edit.NewEndPoint.Column)},
			})
		}
	}
	var err error
	if g.tree == nil {
		g.tree, err = g.parser.Parse(source)
	} else {
		oldTree := g.tree
		g.tree, err = g.parser.ParseIncremental(source, oldTree)
		if oldTree != nil && oldTree != g.tree {
			oldTree.Release()
		}
	}
	if err != nil {
		return document.CodeProjection{}, err
	}
	if g.tree == nil || g.tree.RootNode() == nil {
		return document.CodeProjection{}, fmt.Errorf("Go parser returned no tree")
	}
	g.revision, g.hasRevision = revision, true
	return document.NewCodeProjection(revision, "go", pureHighlights(g.highlight, g.tree), pureSymbols(g.tags, g.tree, source), pureFolds(g.language, g.tree.RootNode(), source)), nil
}

func (g *goImplementationPure) Close() {
	if g != nil && g.tree != nil {
		g.tree.Release()
	}
}

func pureHighlights(query *gotreesitter.Query, tree *gotreesitter.Tree) []document.HighlightSpan {
	spans := make([]document.HighlightSpan, 0)
	for _, match := range query.Execute(tree) {
		for _, capture := range match.Captures {
			start, end := int(capture.Node.StartByte()), int(capture.Node.EndByte())
			if start < end && end <= len(tree.Source()) {
				spans = append(spans, document.HighlightSpan{StartByte: start, EndByte: end, Kind: highlightKind(capture.Name)})
			}
		}
	}
	return spans
}

func pureSymbols(query *gotreesitter.Query, tree *gotreesitter.Tree, source []byte) []document.Symbol {
	symbols := make([]document.Symbol, 0)
	for _, match := range query.Execute(tree) {
		var name, kind string
		var start, end int
		for _, capture := range match.Captures {
			captureStart, captureEnd := int(capture.Node.StartByte()), int(capture.Node.EndByte())
			switch {
			case capture.Name == "name":
				name = capture.Node.Text(source)
			case strings.HasPrefix(capture.Name, "definition."):
				kind = strings.TrimPrefix(capture.Name, "definition.")
				start, end = captureStart, captureEnd
			}
		}
		if name != "" && kind != "" {
			symbols = append(symbols, document.Symbol{Name: name, Kind: kind, StartByte: start, EndByte: end})
		}
	}
	sort.SliceStable(symbols, func(i, j int) bool { return symbols[i].StartByte < symbols[j].StartByte })
	return symbols
}

func pureFolds(language *gotreesitter.Language, root *gotreesitter.Node, source []byte) []document.LanguageFold {
	if root == nil {
		return nil
	}
	folds := make([]document.LanguageFold, 0)
	var walk func(*gotreesitter.Node)
	walk = func(node *gotreesitter.Node) {
		start, end := int(node.StartByte()), int(node.EndByte())
		kind := node.Type(language)
		if end-start > 1 && (kind == "function_declaration" || kind == "method_declaration" || kind == "type_declaration" || kind == "block" || kind == "composite_literal") && bytesContainNewline(source[start:end]) {
			folds = append(folds, document.LanguageFold{StartByte: start, EndByte: end})
		}
		for _, child := range node.Children() {
			walk(child)
		}
	}
	walk(root)
	return folds
}
