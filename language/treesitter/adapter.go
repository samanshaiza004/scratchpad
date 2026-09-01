package treesitter

import (
	"fmt"
	"strings"

	"scratchpad/document"
	"scratchpad/editor"
)

type goImplementation interface {
	Analyze(source []byte, revision uint64, edits []editor.SourceEdit) (document.CodeProjection, error)
	Close()
}

// GoAdapter is a worker-owned, revision-aware Go analysis adapter. Its parser
// state is intentionally opaque and never enters Document or the UI.
type GoAdapter struct {
	impl goImplementation
}

func NewGoAdapter() (*GoAdapter, error) {
	impl, err := newGoImplementation()
	if err != nil {
		return nil, err
	}
	return &GoAdapter{impl: impl}, nil
}

func (a *GoAdapter) Analyze(source []byte, revision uint64, edits []editor.SourceEdit) (document.CodeProjection, error) {
	if a == nil || a.impl == nil {
		return document.CodeProjection{}, fmt.Errorf("nil Go adapter")
	}
	return a.impl.Analyze(source, revision, edits)
}

func (a *GoAdapter) Close() {
	if a != nil && a.impl != nil {
		a.impl.Close()
	}
}

func highlightKind(capture string) document.HighlightKind {
	switch capture {
	case "function.method", "method":
		return document.HighlightMethod
	case "type.builtin", "type.super":
		return document.HighlightType
	case "variable.parameter", "variable.member":
		return document.HighlightVariable
	case "constant.builtin":
		return document.HighlightConstant
	case "function.builtin":
		return document.HighlightBuiltin
	case "punctuation.bracket", "punctuation.delimiter":
		return document.HighlightPunctuation
	case "string.special":
		return document.HighlightString
	}
	if dot := strings.IndexByte(capture, '.'); dot >= 0 {
		capture = capture[:dot]
	}
	switch capture {
	case "comment":
		return document.HighlightComment
	case "keyword":
		return document.HighlightKeyword
	case "string":
		return document.HighlightString
	case "number":
		return document.HighlightNumber
	case "type":
		return document.HighlightType
	case "function":
		return document.HighlightFunction
	case "variable":
		return document.HighlightVariable
	case "constant":
		return document.HighlightConstant
	case "property":
		return document.HighlightProperty
	case "operator":
		return document.HighlightOperator
	case "punctuation":
		return document.HighlightPunctuation
	case "builtin", "variable.builtin":
		return document.HighlightBuiltin
	case "parameter":
		return document.HighlightParameter
	case "tag":
		return document.HighlightTag
	case "attribute":
		return document.HighlightAttribute
	default:
		return document.HighlightKind(capture)
	}
}

func sourceInputEdit(edit editor.SourceEdit) inputEdit {
	return inputEdit{
		startByte: edit.StartByte, oldEndByte: edit.OldEndByte, newEndByte: edit.NewEndByte,
		startPoint: edit.StartPoint, oldEndPoint: edit.OldEndPoint, newEndPoint: edit.NewEndPoint,
	}
}

// inputEdit lets each runtime adapter convert the same editor-owned edit
// journal without exposing either runtime's point type to Scratchpad.
type inputEdit struct {
	startByte, oldEndByte, newEndByte    int
	startPoint, oldEndPoint, newEndPoint editor.BytePoint
}
