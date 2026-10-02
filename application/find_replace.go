package application

import (
	"bytes"
	"errors"
	"fmt"

	"scratchpad/editor"
	"scratchpad/workspace"
)

var ErrStaleFindMatch = errors.New("stale Find match")

type FindReplaceAllResult struct {
	MatchCount     int
	Changed        bool
	EditorRevision uint64
	AnchorByte     int
	CursorByte     int
	CursorLine     int
}

// ReplaceCurrentMatch revalidates the selected source range against the
// authoritative document before applying one undoable edit.
func (a *Application) ReplaceCurrentMatch(id DocumentID, expectedRevision uint64, match CurrentMatch, query, replacement []byte, beforeAnchor, beforeCursor int) (editor.AppliedEdit, error) {
	if a == nil {
		return editor.AppliedEdit{}, errors.New("nil application")
	}
	doc := a.Documents[id]
	if doc == nil || doc.Editor == nil {
		return editor.AppliedEdit{}, errors.New("unknown document")
	}
	if doc.Revision() != expectedRevision {
		return editor.AppliedEdit{}, fmt.Errorf("%w: expected %d, current %d", ErrStaleEditorRevision, expectedRevision, doc.Revision())
	}
	if len(query) == 0 || match.Start < 0 || match.End <= match.Start || match.End-match.Start != len(query) {
		return editor.AppliedEdit{}, ErrStaleFindMatch
	}
	current, err := doc.Editor.Buffer.Bytes(match.Start, match.End)
	if err != nil || !bytes.Equal(current, query) {
		return editor.AppliedEdit{}, ErrStaleFindMatch
	}
	if bytes.Equal(query, replacement) {
		return editor.AppliedEdit{}, nil
	}
	replacement = doc.Editor.NormalizeLineEndings(replacement)
	after := match.Start + len(replacement)
	return a.ReplaceDocument(PresentationCommand{
		Kind: PresentationReplaceDocument, DocumentID: id, EditorRevision: expectedRevision,
		StartByte: match.Start, EndByte: match.End, Replacement: replacement, HasSelectionState: true,
		BeforeAnchorByte: beforeAnchor, BeforeCursorByte: beforeCursor,
		AfterAnchorByte: after, AfterCursorByte: after,
	})
}

// ReplaceAllCurrent computes literal non-overlapping matches against the
// authoritative Go buffer and applies them as one undoable source transaction.
func (a *Application) ReplaceAllCurrent(id DocumentID, expectedRevision uint64, query, replacement []byte, beforeAnchor, beforeCursor int) (FindReplaceAllResult, error) {
	result := FindReplaceAllResult{}
	if a == nil {
		return result, errors.New("nil application")
	}
	doc := a.Documents[id]
	if doc == nil || doc.Editor == nil {
		return result, errors.New("unknown document")
	}
	if doc.Revision() != expectedRevision {
		return result, fmt.Errorf("%w: expected %d, current %d", ErrStaleEditorRevision, expectedRevision, doc.Revision())
	}
	if len(query) == 0 {
		return result, nil
	}
	source := doc.Editor.Buffer.Text()
	first, last, count := -1, -1, 0
	for offset := 0; offset <= len(source)-len(query); {
		relative := bytes.Index(source[offset:], query)
		if relative < 0 {
			break
		}
		start := offset + relative
		if first < 0 {
			first = start
		}
		last = start + len(query)
		count++
		offset = last
	}
	result.MatchCount = count
	if count == 0 || bytes.Equal(query, replacement) {
		return result, nil
	}
	replacement = doc.Editor.NormalizeLineEndings(replacement)
	spanLength := last - first
	delta := len(replacement) - len(query)
	maxInt := int(^uint(0) >> 1)
	if delta > 0 && count > (maxInt-spanLength)/delta {
		return FindReplaceAllResult{}, errors.New("Replace All result exceeds the addressable buffer size")
	}
	newLength := spanLength + count*delta
	if newLength < 0 {
		return FindReplaceAllResult{}, errors.New("Replace All result length is invalid")
	}
	resultingDocumentLength := len(source) - spanLength + newLength
	if int64(resultingDocumentLength) > workspace.MaxSearchFileBytes {
		return FindReplaceAllResult{}, fmt.Errorf("Replace All result would exceed the %d-byte document limit", workspace.MaxSearchFileBytes)
	}
	newSpan := make([]byte, 0, newLength)
	sourceOffset, finalCursor := first, first
	for sourceOffset < last {
		relative := bytes.Index(source[sourceOffset:last], query)
		if relative < 0 {
			break
		}
		matchStart := sourceOffset + relative
		newSpan = append(newSpan, source[sourceOffset:matchStart]...)
		newSpan = append(newSpan, replacement...)
		sourceOffset = matchStart + len(query)
		finalCursor = first + len(newSpan)
	}
	newSpan = append(newSpan, source[sourceOffset:last]...)
	applied, err := a.ReplaceDocument(PresentationCommand{
		Kind: PresentationReplaceDocument, DocumentID: id, EditorRevision: expectedRevision,
		StartByte: first, EndByte: last, Replacement: newSpan, HasSelectionState: true,
		BeforeAnchorByte: beforeAnchor, BeforeCursorByte: beforeCursor,
		AfterAnchorByte: finalCursor, AfterCursorByte: finalCursor,
	})
	if err != nil {
		return FindReplaceAllResult{}, err
	}
	result.Changed = applied.SourceEdit.AfterRevision != applied.SourceEdit.BeforeRevision
	result.EditorRevision = applied.SourceEdit.AfterRevision
	result.AnchorByte, result.CursorByte = doc.Editor.Selection()
	result.CursorLine, _ = doc.Editor.Buffer.LineAt(result.CursorByte)
	return result, nil
}
