package commands

import (
	"bytes"
	"strconv"
	"strings"
)

// MarkdownEnterResult is the bounded line-local projection for an Enter key.
// RemoveFrom is relative to the beginning of the logical line and is non-zero
// only when Enter breaks out of an empty list/quote item.
type MarkdownEnterResult struct {
	Prefix     []byte
	RemoveFrom int
	Breakout   bool
}

// MarkdownEnterPrefix derives the continuation prefix from the bytes before
// the insertion point on one logical line. It does not parse or retain a whole
// document, and it deliberately handles only common Markdown block prefixes.
func MarkdownEnterPrefix(linePrefix []byte, atLineEnd bool) MarkdownEnterResult {
	indentEnd := 0
	for indentEnd < len(linePrefix) && (linePrefix[indentEnd] == ' ' || linePrefix[indentEnd] == '\t') {
		indentEnd++
	}
	quoteEnd := indentEnd
	quotePrefix := make([]byte, 0, len(linePrefix))
	quotePrefix = append(quotePrefix, linePrefix[:indentEnd]...)
	for quoteEnd < len(linePrefix) && linePrefix[quoteEnd] == '>' {
		quotePrefix = append(quotePrefix, '>', ' ')
		quoteEnd++
		if quoteEnd < len(linePrefix) && linePrefix[quoteEnd] == ' ' {
			quoteEnd++
		}
		for quoteEnd < len(linePrefix) && linePrefix[quoteEnd] == '\t' {
			quoteEnd++
		}
	}

	result := MarkdownEnterResult{Prefix: append([]byte(nil), quotePrefix...)}
	listStart := quoteEnd
	markerEnd, ordered := markdownListMarker(linePrefix, listStart)
	if markerEnd <= listStart {
		if atLineEnd && quoteEnd > indentEnd && len(linePrefix) == quoteEnd {
			result.Prefix = append([]byte(nil), linePrefix[:indentEnd]...)
			result.RemoveFrom = indentEnd
			result.Breakout = true
		}
		return result
	}

	itemContentStart := markerEnd
	task := false
	taskStart := markerEnd
	for taskStart < len(linePrefix) && (linePrefix[taskStart] == ' ' || linePrefix[taskStart] == '\t') {
		taskStart++
	}
	if taskStart+3 < len(linePrefix) && linePrefix[taskStart] == '[' &&
		(linePrefix[taskStart+1] == ' ' || linePrefix[taskStart+1] == 'x' || linePrefix[taskStart+1] == 'X') &&
		linePrefix[taskStart+2] == ']' && (linePrefix[taskStart+3] == ' ' || linePrefix[taskStart+3] == '\t') {
		task = true
		itemContentStart = taskStart + 4
	}

	if atLineEnd && len(bytes.TrimSpace(linePrefix[itemContentStart:])) == 0 {
		result.Prefix = append([]byte(nil), quotePrefix...)
		result.RemoveFrom = listStart
		result.Breakout = true
		return result
	}

	if ordered {
		markerByte := listStart
		for markerByte < markerEnd && linePrefix[markerByte] >= '0' && linePrefix[markerByte] <= '9' {
			markerByte++
		}
		number, err := strconv.ParseUint(string(linePrefix[listStart:markerByte]), 10, 64)
		if err == nil && number < ^uint64(0) {
			width := markerByte - listStart
			result.Prefix = append(result.Prefix[:0], quotePrefix...)
			result.Prefix = append(result.Prefix, []byte(strings.Repeat("0", max(0, width-len(strconv.FormatUint(number+1, 10)))))...)
			result.Prefix = append(result.Prefix, strconv.FormatUint(number+1, 10)...)
			result.Prefix = append(result.Prefix, linePrefix[markerByte:markerEnd]...)
		} else {
			result.Prefix = append(result.Prefix, linePrefix[listStart:markerEnd]...)
		}
	} else {
		result.Prefix = append(result.Prefix, linePrefix[listStart:markerEnd]...)
	}
	if task {
		result.Prefix = append(result.Prefix, "[ ] "...)
	}
	return result
}

func markdownListMarker(line []byte, start int) (end int, ordered bool) {
	if start >= len(line) {
		return 0, false
	}
	index := start
	if line[index] == '-' || line[index] == '+' || line[index] == '*' {
		index++
	} else {
		for index < len(line) && line[index] >= '0' && line[index] <= '9' {
			index++
		}
		if index == start || index >= len(line) || (line[index] != '.' && line[index] != ')') {
			return 0, false
		}
		ordered = true
		index++
	}
	if index >= len(line) || (line[index] != ' ' && line[index] != '\t') {
		return 0, false
	}
	index++
	return index, ordered
}
