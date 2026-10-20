package commands

import (
	"bytes"
	"sort"
	"unicode"

	"github.com/rivo/uniseg"
	"scratchpad/document"
)

// expandSelection has no remembered expansion stack. Every invocation starts
// from the supplied directional selection and source revision; moving the caret
// or editing the source therefore resets expansion without a separate protocol.
func expandSelection(request Request) Outcome {
	source := request.Source
	if len(source) == 0 {
		return Outcome{Status: ResultNoOp, Anchor: request.Anchor, Cursor: request.Cursor}
	}
	start, end := request.Anchor, request.Cursor
	if start > end {
		start, end = end, start
	}
	originalStart, originalEnd := start, end
	boundaries := []int{0}
	var words, sentences []document.SelectionRange
	graphemes := uniseg.NewGraphemes(string(source))
	wordStart, sentenceStart := 0, 0
	cluster := document.SelectionRange{}
	for graphemes.Next() {
		from, to := graphemes.Positions()
		boundaries = append(boundaries, to)
		if from <= start && start < to || start == len(source) && to == start {
			cluster = document.SelectionRange{StartByte: from, EndByte: to}
		}
		if graphemes.IsWordBoundary() {
			word := trimSelectionSpace(source, wordStart, to)
			if word.StartByte <= start && word.EndByte >= end {
				words = append(words, word)
			}
			wordStart = to
		}
		if graphemes.IsSentenceBoundary() {
			sentence := trimSelectionSpace(source, sentenceStart, to)
			if sentence.StartByte <= start && sentence.EndByte >= end {
				sentences = append(sentences, sentence)
			}
			sentenceStart = to
		}
	}
	// A foreign selection can arrive inside a UTF-8 sequence or cluster. Expand
	// outwards first; never return a source endpoint inside that cluster.
	left := sort.SearchInts(boundaries, start)
	if left == len(boundaries) || boundaries[left] != start {
		left--
	}
	right := sort.SearchInts(boundaries, end)
	start, end = boundaries[max(left, 0)], boundaries[min(right, len(boundaries)-1)]
	normalized := start != originalStart || end != originalEnd
	var semantics []document.SelectionRange
	addSemantic := func(candidate document.SelectionRange) {
		if candidate.StartByte < 0 || candidate.EndByte > len(source) || candidate.EndByte <= candidate.StartByte ||
			candidate.StartByte > start || candidate.EndByte < end ||
			!selectionBoundary(boundaries, candidate.StartByte) || !selectionBoundary(boundaries, candidate.EndByte) {
			return
		}
		if start == end && start == candidate.EndByte && start != len(source) {
			return
		}
		semantics = append(semantics, candidate)
	}
	if request.ProjectionsCurrent && request.Projections.Revision == request.SourceRevision {
		for _, candidate := range request.Projections.SelectionRanges {
			addSemantic(candidate)
		}
		if request.Projections.Code.Revision == request.SourceRevision {
			for _, candidate := range request.Projections.Code.SelectionRanges {
				addSemantic(candidate)
			}
		}
	}
	best := document.SelectionRange{StartByte: 0, EndByte: len(source)}
	found := false
	consider := func(candidate document.SelectionRange) {
		if candidate.StartByte < 0 || candidate.EndByte > len(source) || candidate.EndByte <= candidate.StartByte {
			return
		}
		if !selectionBoundary(boundaries, candidate.StartByte) || !selectionBoundary(boundaries, candidate.EndByte) {
			return
		}
		contains := candidate.StartByte <= start && candidate.EndByte >= end
		if start == end {
			contains = candidate.StartByte <= start && (start < candidate.EndByte || start == len(source) && candidate.EndByte == start)
		}
		if !contains || !normalized && candidate.StartByte == start && candidate.EndByte == end {
			return
		}
		if !found || candidate.EndByte-candidate.StartByte < best.EndByte-best.StartByte ||
			candidate.EndByte-candidate.StartByte == best.EndByte-best.StartByte && candidate.StartByte < best.StartByte {
			best, found = candidate, true
		}
	}
	// Text boundaries may sit inside or outside syntax, but must not cross a
	// current syntax parent: doing so would make that parent unreachable on the
	// next expansion (for example, a sentence starting before an emphasis span).
	considerText := func(candidate document.SelectionRange) {
		if candidate.StartByte > start || candidate.EndByte < end {
			return
		}
		for _, parent := range semantics {
			inside := parent.StartByte <= candidate.StartByte && candidate.EndByte <= parent.EndByte
			outside := candidate.StartByte <= parent.StartByte && parent.EndByte <= candidate.EndByte
			if !inside && !outside {
				return
			}
		}
		consider(candidate)
	}
	if normalized {
		considerText(document.SelectionRange{StartByte: start, EndByte: end})
	}
	// Words precede the cluster fallback so a normal caret selects a whole word
	// on its first invocation. Punctuation and whitespace still select a cluster.
	for _, word := range words {
		considerText(word)
	}
	if start == end && !found {
		considerText(cluster)
	}
	for _, sentence := range sentences {
		considerText(sentence)
	}
	paragraphStart := 0
	for lineStart := 0; lineStart < len(source); {
		lineEnd := bytes.IndexByte(source[lineStart:], '\n')
		if lineEnd < 0 {
			break
		}
		lineEnd += lineStart
		if len(bytes.TrimSpace(source[lineStart:lineEnd])) == 0 {
			considerText(trimSelectionSpace(source, paragraphStart, lineStart))
			paragraphStart = lineEnd + 1
		}
		lineStart = lineEnd + 1
	}
	considerText(trimSelectionSpace(source, paragraphStart, len(source)))
	for _, candidate := range semantics {
		consider(candidate)
	}
	consider(document.SelectionRange{StartByte: 0, EndByte: len(source)})
	if !found {
		return Outcome{Status: ResultNoOp, Anchor: request.Anchor, Cursor: request.Cursor}
	}
	anchor, cursor := best.StartByte, best.EndByte
	if request.Anchor > request.Cursor {
		anchor, cursor = cursor, anchor
	}
	return Outcome{Status: ResultExecuted, Anchor: anchor, Cursor: cursor}
}

func selectionBoundary(boundaries []int, at int) bool {
	i := sort.SearchInts(boundaries, at)
	return i < len(boundaries) && boundaries[i] == at
}

func trimSelectionSpace(source []byte, start, end int) document.SelectionRange {
	trimmed := bytes.TrimLeftFunc(source[start:end], unicode.IsSpace)
	start = end - len(trimmed)
	trimmed = bytes.TrimRightFunc(trimmed, unicode.IsSpace)
	return document.SelectionRange{StartByte: start, EndByte: start + len(trimmed)}
}
