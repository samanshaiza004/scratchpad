package treesitter

import (
	"fmt"
	"strings"

	"scratchpad/document"
	"scratchpad/editor"
)

// TypeScriptQueries combines the pinned TypeScript additions with the
// compatible JavaScript query set. TSX additionally receives JavaScript's JSX
// captures. Query assets stay private to this package so changing grammar
// revisions cannot change the document or UI contracts.
func TypeScriptQueries(tsx bool) (highlights, tags string) {
	highlights = strings.Join([]string{JavaScriptHighlightsQuery, TypeScriptHighlightsQuery}, "\n")
	if tsx {
		highlights = strings.Join([]string{highlights, JavaScriptJSXHighlightsQuery}, "\n")
	}
	tags = strings.Join([]string{JavaScriptTagsQuery, TypeScriptTagsQuery}, "\n")
	return highlights, tags
}

type typeScriptImplementation interface {
	Analyze(source []byte, revision uint64, edits []editor.SourceEdit) (document.CodeProjection, error)
	Close()
}

// TypeScriptAdapter is the concrete TypeScript/TSX adapter used by the
// selected Gate E backend. Parser state remains private and worker-owned.
type TypeScriptAdapter struct {
	impl typeScriptImplementation
}

func NewTypeScriptAdapter(tsx bool) (*TypeScriptAdapter, error) {
	impl, err := newTypeScriptImplementation(tsx)
	if err != nil {
		return nil, err
	}
	return &TypeScriptAdapter{impl: impl}, nil
}

func (a *TypeScriptAdapter) Analyze(source []byte, revision uint64, edits []editor.SourceEdit) (document.CodeProjection, error) {
	if a == nil || a.impl == nil {
		return document.CodeProjection{}, fmt.Errorf("nil TypeScript adapter")
	}
	return a.impl.Analyze(source, revision, edits)
}

func (a *TypeScriptAdapter) Close() {
	if a != nil && a.impl != nil {
		a.impl.Close()
	}
}
