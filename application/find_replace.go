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
	return a.ReplaceCurrentMatchWithOptions(id, expectedRevision, match, query, replacement, beforeAnchor, beforeCursor, FindOptions{MatchCase: true})
}

// ReplaceCurrentMatchWithOptions validates and replaces one current literal
// match using the same matching rules as Find.
func (a *Application) ReplaceCurrentMatchWithOptions(id DocumentID, expectedRevision uint64, match CurrentMatch, query, replacement []byte, beforeAnchor, beforeCursor int, options FindOptions) (editor.AppliedEdit, error) {
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
	if err != nil || !findMatchAt(doc.Editor.Buffer.Text(), match.Start, match.End, query, options) {
		return editor.AppliedEdit{}, ErrStaleFindMatch
	}
	if bytes.Equal(current, replacement) {
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
	return a.ReplaceAllCurrentWithOptions(id, expectedRevision, query, replacement, beforeAnchor, beforeCursor, FindOptions{MatchCase: true})
}

// ReplaceAllCurrentWithOptions computes and applies literal, non-overlapping
// matches using the same options as Find.
func (a *Application) ReplaceAllCurrentWithOptions(id DocumentID, expectedRevision uint64, query, replacement []byte, beforeAnchor, beforeCursor int, options FindOptions) (FindReplaceAllResult, error) {
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
	first, last := -1, -1
	var matchStarts []int
	for offset := 0; offset <= len(source)-len(query); {
		start, found := findNextLiteral(source, query, offset, options)
		if !found {
			break
		}
		if first < 0 {
			first = start
		}
		last = start + len(query)
		matchStarts = append(matchStarts, start)
		offset = last
	}
	count := len(matchStarts)
	result.MatchCount = count
	if count == 0 {
		return result, nil
	}
	allReplacementsUnchanged := true
	for _, matchStart := range matchStarts {
		if !bytes.Equal(source[matchStart:matchStart+len(query)], replacement) {
			allReplacementsUnchanged = false
			break
		}
	}
	if allReplacementsUnchanged {
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
	for _, matchStart := range matchStarts {
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

func findMatchAt(source []byte, start, end int, query []byte, options FindOptions) bool {
	if start < 0 || end < start || end > len(source) || end-start != len(query) {
		return false
	}
	value := source[start:end]
	if options.MatchCase {
		if !bytes.Equal(value, query) {
			return false
		}
	} else if !bytes.EqualFold(value, query) {
		return false
	}
	return !options.WholeWord || isWholeWordMatch(source, start, end)
}
