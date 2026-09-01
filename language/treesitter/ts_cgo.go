//go:build cgo && !treesitter_pure

package treesitter

import (
	"fmt"

	ts "github.com/tree-sitter/go-tree-sitter"
	treeSitterTS "github.com/tree-sitter/tree-sitter-typescript/bindings/go"

	"scratchpad/document"
	"scratchpad/editor"
)

type typeScriptImplementationCGo struct {
	parser       *ts.Parser
	language     *ts.Language
	highlight    *ts.Query
	tags         *ts.Query
	tree         *ts.Tree
	revision     uint64
	hasRevision  bool
	languageName string
}

func newTypeScriptImplementation(tsx bool) (typeScriptImplementation, error) {
	languageName := "typescript"
	languagePtr := treeSitterTS.LanguageTypescript()
	if tsx {
		languageName = "tsx"
		languagePtr = treeSitterTS.LanguageTSX()
	}
	language := ts.NewLanguage(languagePtr)
	parser := ts.NewParser()
	if err := parser.SetLanguage(language); err != nil {
		parser.Close()
		return nil, err
	}
	highlights, tags := TypeScriptQueries(tsx)
	highlight, err := ts.NewQuery(language, highlights)
	if err != nil {
		parser.Close()
		return nil, err
	}
	tagsQuery, err := ts.NewQuery(language, tags)
	if err != nil {
		highlight.Close()
		parser.Close()
		return nil, err
	}
	return &typeScriptImplementationCGo{
		parser: parser, language: language, highlight: highlight, tags: tagsQuery,
		languageName: languageName,
	}, nil
}

func (t *typeScriptImplementationCGo) Analyze(source []byte, revision uint64, edits []editor.SourceEdit) (document.CodeProjection, error) {
	if t.tree != nil && (!t.hasRevision || len(edits) == 0 || edits[0].BeforeRevision != t.revision) {
		t.tree.Close()
		t.tree = nil
	}
	if t.tree != nil {
		for _, edit := range edits {
			t.tree.Edit(&ts.InputEdit{
				StartByte: uint(edit.StartByte), OldEndByte: uint(edit.OldEndByte), NewEndByte: uint(edit.NewEndByte),
				StartPosition:  ts.Point{Row: uint(edit.StartPoint.Row), Column: uint(edit.StartPoint.Column)},
				OldEndPosition: ts.Point{Row: uint(edit.OldEndPoint.Row), Column: uint(edit.OldEndPoint.Column)},
				NewEndPosition: ts.Point{Row: uint(edit.NewEndPoint.Row), Column: uint(edit.NewEndPoint.Column)},
			})
		}
	}
	oldTree := t.tree
	t.tree = t.parser.Parse(source, oldTree)
	if oldTree != nil && oldTree != t.tree {
		oldTree.Close()
	}
	if t.tree == nil || t.tree.RootNode() == nil {
		return document.CodeProjection{}, fmt.Errorf("%s parser returned no tree", t.languageName)
	}
	t.revision, t.hasRevision = revision, true
	root := t.tree.RootNode()
	return document.NewCodeProjection(revision, t.languageName,
		captureHighlights(t.highlight, root, source),
		captureSymbols(t.tags, root, source),
		collectFolds(root, source)), nil
}

func (t *typeScriptImplementationCGo) Close() {
	if t == nil {
		return
	}
	if t.tree != nil {
		t.tree.Close()
	}
	if t.highlight != nil {
		t.highlight.Close()
	}
	if t.tags != nil {
		t.tags.Close()
	}
	if t.parser != nil {
		t.parser.Close()
	}
}
