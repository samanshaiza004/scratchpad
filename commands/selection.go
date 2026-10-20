package commands

import (
	"bytes"
	"unicode"
	"unicode/utf8"

	"github.com/rivo/uniseg"
	"scratchpad/document"
)

// expandSelection has no remembered expansion stack. Every invocation starts
// from the supplied directional selection and source revision; moving the caret
// or editing the source therefore resets expansion without a separate protocol.
func expandSelection(request Request) Outcome {
	return expandSelectionASCII(request)
}

// expandSelectionUnicode uses the complete Unicode segmentation tables but
// keeps only boundary offsets that are relevant to the current selection.
func expandSelectionUnicode(request Request) Outcome {
	source := request.Source
	if len(source) == 0 {
		return Outcome{Status: ResultNoOp, Anchor: request.Anchor, Cursor: request.Cursor}
	}
	start, end := request.Anchor, request.Cursor
	if start > end {
		start, end = end, start
	}
	start, end = clampSelectionOffset(start, len(source)), clampSelectionOffset(end, len(source))
	originalStart, originalEnd := start, end
	// Keep only source-range endpoints that might participate in this
	// expansion. Grapheme segmentation below validates these exact offsets;
	// retaining a boundary for every grapheme made a 10 MiB file allocate
	// hundreds of MiB on every invocation.
	semanticCandidates := selectionSemanticCandidates(request, originalStart, originalEnd)
	paragraph := selectionParagraph(source, originalStart, originalEnd)
	boundaryTargets := map[int]bool{0: true, len(source): true}
	requestBoundary := func(offset int) {
		if _, isDocumentEdge := boundaryTargets[offset]; !isDocumentEdge {
			boundaryTargets[offset] = false
		}
	}
	for _, candidate := range semanticCandidates {
		requestBoundary(candidate.StartByte)
		requestBoundary(candidate.EndByte)
	}
	requestBoundary(paragraph.StartByte)
	requestBoundary(paragraph.EndByte)

	var words, sentences []document.SelectionRange
	cluster := document.SelectionRange{}
	wordTrimStart, wordTrimEnd, sentenceTrimStart, sentenceTrimEnd := 0, 0, 0, 0
	wordHasText, sentenceHasText := false, false
	offset, state := 0, -1
	remaining := source
	for len(remaining) > 0 {
		clusterBytes, rest, boundaries, nextState := uniseg.Step(remaining, state)
		from, to := offset, offset+len(clusterBytes)
		if _, needed := boundaryTargets[to]; needed {
			boundaryTargets[to] = true
		}
		if from < originalStart && originalStart < to {
			start = from
		}
		if from < originalEnd && originalEnd < to {
			end = to
		}
		if from <= originalStart && originalStart < to || originalStart == len(source) && to == originalStart {
			cluster = document.SelectionRange{StartByte: from, EndByte: to}
		}
		whitespace := selectionClusterIsSpace(clusterBytes)
		if !whitespace {
			if !wordHasText {
				wordTrimStart = from
				wordHasText = true
			}
			wordTrimEnd = to
			if !sentenceHasText {
				sentenceTrimStart = from
				sentenceHasText = true
			}
			sentenceTrimEnd = to
		}
		if boundaries&uniseg.MaskWord != 0 {
			word := document.SelectionRange{StartByte: wordTrimStart, EndByte: wordTrimEnd}
			if wordHasText && word.StartByte <= originalStart && word.EndByte >= originalEnd {
				words = append(words, word)
				boundaryTargets[word.StartByte], boundaryTargets[word.EndByte] = true, true
			}
			wordTrimStart, wordTrimEnd = to, to
			wordHasText = false
		}
		if boundaries&uniseg.MaskSentence != 0 {
			sentence := document.SelectionRange{StartByte: sentenceTrimStart, EndByte: sentenceTrimEnd}
			if sentenceHasText && sentence.StartByte <= originalStart && sentence.EndByte >= originalEnd {
				sentences = append(sentences, sentence)
				boundaryTargets[sentence.StartByte], boundaryTargets[sentence.EndByte] = true, true
			}
			sentenceTrimStart, sentenceTrimEnd = to, to
			sentenceHasText = false
		}
		offset, remaining, state = to, rest, nextState
	}
	normalized := start != originalStart || end != originalEnd
	semantics := make([]document.SelectionRange, 0, len(semanticCandidates))
	for _, candidate := range semanticCandidates {
		if candidate.StartByte > start || candidate.EndByte < end ||
			!boundaryTargets[candidate.StartByte] || !boundaryTargets[candidate.EndByte] {
			continue
		}
		if start == end && start == candidate.EndByte && start != len(source) {
			continue
		}
		semantics = append(semantics, candidate)
	}
	if !boundaryTargets[paragraph.StartByte] || !boundaryTargets[paragraph.EndByte] {
		paragraph = document.SelectionRange{}
	}
	return chooseSelectionExpansion(request, start, end, normalized, cluster, words, sentences, paragraph, semantics)
}

func expandSelectionASCII(request Request) Outcome {
	source := request.Source
	if len(source) == 0 {
		return Outcome{Status: ResultNoOp, Anchor: request.Anchor, Cursor: request.Cursor}
	}
	start, end := request.Anchor, request.Cursor
	if start > end {
		start, end = end, start
	}
	start, end = clampSelectionOffset(start, len(source)), clampSelectionOffset(end, len(source))
	semanticCandidates := selectionSemanticCandidates(request, start, end)
	words := asciiWordRangesAt(source, start, end)
	if !selectionASCIIContextSafe(source, start, end, words, nil, semanticCandidates) {
		return expandSelectionUnicode(request)
	}
	cluster := document.SelectionRange{}
	if start == end {
		clusterStart := start
		if clusterStart == len(source) {
			clusterStart--
		}
		cluster = document.SelectionRange{StartByte: clusterStart, EndByte: clusterStart + 1}
	}
	if hasStrictTextExpansion(start, end, words, semanticCandidates) {
		return chooseSelectionExpansion(request, start, end, false, cluster, words, nil, document.SelectionRange{}, semanticCandidates)
	}
	sentences, sentenceSafe := asciiSentenceRangesAt(source, start, end)
	if !sentenceSafe || !selectionASCIIContextSafe(source, start, end, words, sentences, semanticCandidates) {
		return expandSelectionUnicode(request)
	}
	if hasStrictTextExpansion(start, end, sentences, semanticCandidates) && !asciiSentenceRangesCrossParagraph(source, sentences) {
		return chooseSelectionExpansion(request, start, end, false, cluster, words, sentences, document.SelectionRange{}, semanticCandidates)
	}
	paragraph := selectionParagraph(source, start, end)
	if !selectionASCIIOffsetsSafe(source, paragraph.StartByte, paragraph.EndByte) {
		return expandSelectionUnicode(request)
	}
	return chooseSelectionExpansion(request, start, end, false, cluster, words, sentences, paragraph, semanticCandidates)
}

func selectionASCIIContextSafe(source []byte, start, end int, words, sentences, semantics []document.SelectionRange) bool {
	if !selectionASCIIOffsetsSafe(source, start, end) {
		return false
	}
	for _, candidate := range words {
		if !selectionASCIIOffsetsSafe(source, candidate.StartByte, candidate.EndByte) || !asciiWordCandidateSafe(source, candidate) {
			return false
		}
	}
	for _, candidate := range sentences {
		if !selectionASCIIOffsetsSafe(source, candidate.StartByte, candidate.EndByte) {
			return false
		}
	}
	for _, candidate := range semantics {
		if !selectionASCIIOffsetsSafe(source, candidate.StartByte, candidate.StartByte) ||
			!selectionASCIIOffsetsSafe(source, candidate.EndByte, candidate.EndByte) {
			return false
		}
	}
	return true
}

func asciiWordCandidateSafe(source []byte, candidate document.SelectionRange) bool {
	for _, b := range source[candidate.StartByte:candidate.EndByte] {
		if !asciiWordCore(b) {
			return false
		}
	}
	if candidate.StartByte > 1 && asciiWordConnector(source[candidate.StartByte-1]) && asciiWordCore(source[candidate.StartByte-2]) {
		return false
	}
	if candidate.EndByte+1 < len(source) && asciiWordConnector(source[candidate.EndByte]) && asciiWordCore(source[candidate.EndByte+1]) {
		return false
	}
	return true
}

func hasStrictTextExpansion(start, end int, candidates, semantics []document.SelectionRange) bool {
	for _, candidate := range candidates {
		if candidate.StartByte > start || candidate.EndByte < end || candidate.StartByte == start && candidate.EndByte == end {
			continue
		}
		crossesParent := false
		for _, parent := range semantics {
			inside := parent.StartByte <= candidate.StartByte && candidate.EndByte <= parent.EndByte
			outside := candidate.StartByte <= parent.StartByte && parent.EndByte <= candidate.EndByte
			if !inside && !outside {
				crossesParent = true
				break
			}
		}
		if !crossesParent {
			return true
		}
	}
	return false
}

func selectionASCIIOffsetsSafe(source []byte, start, end int) bool {
	start, end = clampSelectionOffset(start, len(source)), clampSelectionOffset(end, len(source))
	if asciiOffsetSplitsCRLF(source, start) || asciiOffsetSplitsCRLF(source, end) {
		return false
	}
	windowStart, windowEnd := max(start-4, 0), min(end+4, len(source))
	for _, b := range source[windowStart:windowEnd] {
		if b >= utf8.RuneSelf {
			return false
		}
	}
	return true
}

func asciiOffsetSplitsCRLF(source []byte, offset int) bool {
	return offset > 0 && offset < len(source) && source[offset-1] == '\r' && source[offset] == '\n' ||
		offset >= 0 && offset+1 < len(source) && source[offset] == '\r' && source[offset+1] == '\n'
}

func selectionSemanticCandidates(request Request, start, end int) []document.SelectionRange {
	if !request.ProjectionsCurrent || request.Projections.Revision != request.SourceRevision {
		return nil
	}
	var candidates []document.SelectionRange
	add := func(candidate document.SelectionRange) {
		if candidate.StartByte >= 0 && candidate.EndByte <= len(request.Source) && candidate.EndByte > candidate.StartByte &&
			candidate.StartByte <= start && candidate.EndByte >= end {
			candidates = append(candidates, candidate)
		}
	}
	for _, candidate := range request.Projections.SelectionRanges {
		add(candidate)
	}
	if request.Projections.Code.Revision == request.SourceRevision {
		for _, candidate := range request.Projections.Code.SelectionRanges {
			add(candidate)
		}
	}
	return candidates
}

func asciiWordRangesAt(source []byte, start, end int) []document.SelectionRange {
	probes := [2]int{start, start - 1}
	if start != end {
		probes[1] = -1
	}
	var ranges []document.SelectionRange
	for _, probe := range probes {
		if probe < 0 || probe >= len(source) {
			continue
		}
		segmentStart := probe
		for segmentStart > 0 && !asciiWordBoundary(source, segmentStart) {
			segmentStart--
		}
		segmentEnd := probe + 1
		for segmentEnd < len(source) && !asciiWordBoundary(source, segmentEnd) {
			segmentEnd++
		}
		candidate := trimSelectionSpace(source, segmentStart, segmentEnd)
		if candidate.EndByte <= candidate.StartByte || candidate.StartByte > start || candidate.EndByte < end {
			continue
		}
		if len(ranges) == 0 || ranges[len(ranges)-1] != candidate {
			ranges = append(ranges, candidate)
		}
	}
	return ranges
}

func asciiWordBoundary(source []byte, offset int) bool {
	if offset <= 0 || offset >= len(source) {
		return true
	}
	left, right := source[offset-1], source[offset]
	if asciiWordCore(left) && asciiWordCore(right) {
		return false
	}
	if asciiWordCore(left) && asciiWordConnector(right) && offset+1 < len(source) && asciiWordCore(source[offset+1]) {
		return false
	}
	if asciiWordConnector(left) && offset >= 2 && asciiWordCore(source[offset-2]) && asciiWordCore(right) {
		return false
	}
	return true
}

func asciiWordCore(b byte) bool {
	return b == '_' || b >= '0' && b <= '9' || b >= 'a' && b <= 'z' || b >= 'A' && b <= 'Z'
}

func asciiWordConnector(b byte) bool {
	return b == '\'' || b == '.' || b == ',' || b == ':'
}

func asciiSentenceRangesAt(source []byte, start, end int) ([]document.SelectionRange, bool) {
	for _, b := range source[start:end] {
		if b >= utf8.RuneSelf || b == '\r' {
			return nil, false
		}
	}
	sentenceStart := 0
	for terminator := start - 1; terminator >= 0; terminator-- {
		if source[terminator] >= utf8.RuneSelf || source[terminator] == '\r' {
			return nil, false
		}
		if !isASCIISentenceTerminator(source[terminator]) {
			continue
		}
		boundary, ok := asciiSentenceBoundaryAfter(source, terminator)
		if ok && boundary <= start {
			sentenceStart = boundary
			break
		}
	}
	sentenceEnd := len(source)
	for terminator := end; terminator < len(source); terminator++ {
		if source[terminator] >= utf8.RuneSelf || source[terminator] == '\r' {
			return nil, false
		}
		if !isASCIISentenceTerminator(source[terminator]) {
			continue
		}
		if boundary, ok := asciiSentenceBoundaryAfter(source, terminator); ok {
			sentenceEnd = boundary
			break
		}
	}
	candidate := trimSelectionSpace(source, sentenceStart, sentenceEnd)
	if candidate.StartByte <= start && candidate.EndByte >= end && candidate.EndByte > candidate.StartByte {
		return []document.SelectionRange{candidate}, true
	}
	return nil, true
}

func asciiSentenceRangesCrossParagraph(source []byte, sentences []document.SelectionRange) bool {
	for _, sentence := range sentences {
		lineStart := sentence.StartByte
		for lineStart < sentence.EndByte {
			relativeEnd := bytes.IndexByte(source[lineStart:sentence.EndByte], '\n')
			if relativeEnd < 0 {
				break
			}
			lineEnd := lineStart + relativeEnd
			nextStart := lineEnd + 1
			nextEnd := sentence.EndByte
			if nextLineBreak := bytes.IndexByte(source[nextStart:sentence.EndByte], '\n'); nextLineBreak >= 0 {
				nextEnd = nextStart + nextLineBreak
			}
			if len(bytes.TrimSpace(source[nextStart:nextEnd])) == 0 {
				return true
			}
			lineStart = nextStart
		}
	}
	return false
}

func isASCIISentenceTerminator(b byte) bool {
	return b == '.' || b == '!' || b == '?'
}

func asciiSentenceBoundaryAfter(source []byte, terminator int) (int, bool) {
	end := terminator + 1
	for end < len(source) && isASCIISentenceCloser(source[end]) {
		end++
	}
	lineBreak := false
	for end < len(source) && isASCIIWhitespace(source[end]) {
		lineBreak = lineBreak || source[end] == '\n' || source[end] == '\r'
		end++
	}
	if end == len(source) {
		return end, true
	}
	if lineBreak {
		return end, true
	}
	next := source[end]
	if next == '.' || next == '!' || next == '?' {
		return 0, false
	}
	if source[terminator] == '.' {
		if end == terminator+1 && next >= '0' && next <= '9' {
			return 0, false
		}
		if next >= 'a' && next <= 'z' {
			return 0, false
		}
		if end == terminator+1 && terminator > 0 && asciiLetter(source[terminator-1]) && next >= 'A' && next <= 'Z' {
			return 0, false
		}
	}
	return end, true
}

func isASCIISentenceCloser(b byte) bool {
	switch b {
	case '"', '\'', ')', ']', '}':
		return true
	default:
		return false
	}
}

func isASCIIWhitespace(b byte) bool {
	switch b {
	case ' ', '\t', '\n', '\r', '\v', '\f':
		return true
	default:
		return false
	}
}

func asciiLetter(b byte) bool {
	return b >= 'a' && b <= 'z' || b >= 'A' && b <= 'Z'
}

func chooseSelectionExpansion(request Request, start, end int, normalized bool, cluster document.SelectionRange,
	words, sentences []document.SelectionRange, paragraph document.SelectionRange, semantics []document.SelectionRange) Outcome {
	source := request.Source
	best := document.SelectionRange{StartByte: 0, EndByte: len(source)}
	found := false
	consider := func(candidate document.SelectionRange) {
		if candidate.StartByte < 0 || candidate.EndByte > len(source) || candidate.EndByte <= candidate.StartByte {
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
	// Text boundaries must not cross a current syntax parent; doing so would
	// make that parent unreachable on the next expansion.
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
	for _, word := range words {
		considerText(word)
	}
	if start == end && !found {
		considerText(cluster)
	}
	for _, sentence := range sentences {
		considerText(sentence)
	}
	considerText(paragraph)
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

func clampSelectionOffset(offset, length int) int {
	if offset < 0 {
		return 0
	}
	if offset > length {
		return length
	}
	return offset
}

func selectionClusterIsSpace(cluster []byte) bool {
	if len(cluster) == 0 {
		return false
	}
	for len(cluster) > 0 {
		r, size := utf8.DecodeRune(cluster)
		if !unicode.IsSpace(r) {
			return false
		}
		cluster = cluster[size:]
	}
	return true
}

func selectionParagraph(source []byte, start, end int) document.SelectionRange {
	lineStart := bytes.LastIndexByte(source[:start], '\n') + 1
	lineEnd := end
	if relative := bytes.IndexByte(source[end:], '\n'); relative >= 0 {
		lineEnd = end + relative
	} else {
		lineEnd = len(source)
	}
	for lineStart > 0 {
		previousEnd := lineStart - 1
		previousStart := bytes.LastIndexByte(source[:previousEnd], '\n') + 1
		if len(bytes.TrimSpace(source[previousStart:previousEnd])) == 0 {
			break
		}
		lineStart = previousStart
	}
	for lineEnd < len(source) {
		nextStart := lineEnd + 1
		nextEnd := len(source)
		if relative := bytes.IndexByte(source[nextStart:], '\n'); relative >= 0 {
			nextEnd = nextStart + relative
		}
		if len(bytes.TrimSpace(source[nextStart:nextEnd])) == 0 {
			break
		}
		lineEnd = nextEnd
	}
	return trimSelectionSpace(source, lineStart, lineEnd)
}

func trimSelectionSpace(source []byte, start, end int) document.SelectionRange {
	for start < end {
		r, size := utf8.DecodeRune(source[start:end])
		if !unicode.IsSpace(r) {
			break
		}
		start += size
	}
	for end > start {
		r, size := utf8.DecodeLastRune(source[start:end])
		if !unicode.IsSpace(r) {
			break
		}
		end -= size
	}
	return document.SelectionRange{StartByte: start, EndByte: end}
}
