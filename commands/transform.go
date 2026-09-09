package commands

import (
	"bytes"
	"errors"
	"fmt"
	"strings"
	"unicode"
	"unicode/utf8"

	"scratchpad/document"
	"scratchpad/language"
	md "scratchpad/language/markdown"
)

type ResultStatus uint8

const (
	ResultUnavailable ResultStatus = iota
	ResultNoOp
	ResultExecuted
	ResultFailed
)

type Request struct {
	ID                 ID
	Source             []byte
	Cursor             int
	Anchor             int
	RootLanguage       string
	Projections        document.Projections
	ProjectionsCurrent bool
	Argument           string
	RangeStart         int
	RangeEnd           int
	RangeOverride      bool
	SlashTrigger       bool
	InFence            bool
}

type Outcome struct {
	Status      ResultStatus
	Start       int
	End         int
	Replacement []byte
	Cursor      int
	Anchor      int
	Err         error
}

func (o Outcome) Changed() bool {
	return o.Status == ResultExecuted && !bytes.Equal(o.Replacement, nil)
}

// NewRequest snapshots the current editor bytes and synchronously refreshes a
// Markdown projection when the debounced worker is stale. Interactive
// commands therefore never wait for or act on an old parser result.
func NewRequest(doc *document.Document, id ID) (Request, error) {
	if doc == nil || doc.Editor == nil {
		return Request{}, errors.New("no active document")
	}
	source := doc.Editor.Buffer.Text()
	request := Request{ID: id, Source: source, Cursor: doc.Editor.Cursor, Anchor: doc.Editor.Anchor, RootLanguage: doc.RootLanguage, ProjectionsCurrent: doc.DerivedCurrent()}
	if doc.RootLanguage == "markdown" {
		if request.ProjectionsCurrent {
			request.Projections = doc.Projections
		} else {
			request.Projections = md.Project(source, doc.Revision())
			request.ProjectionsCurrent = true
		}
		for _, block := range request.Projections.Blocks {
			if block.Kind == document.BlockCode && doc.Editor.Cursor >= block.StartByte && doc.Editor.Cursor < block.EndByte {
				request.InFence = true
			}
			start, end := request.Anchor, request.Cursor
			if start > end {
				start, end = end, start
			}
			if block.Kind == document.BlockCode && start < block.EndByte && end > block.StartByte {
				request.InFence = true
			}
		}
	}
	return request, nil
}

func Execute(request Request) Outcome {
	if request.Cursor < 0 || request.Cursor > len(request.Source) || request.Anchor < 0 || request.Anchor > len(request.Source) {
		return Outcome{Status: ResultFailed, Err: errors.New("caret outside source")}
	}
	if request.RootLanguage != "markdown" && request.ID != CommentToggle && !isLineEditCommand(request.ID) {
		return Outcome{Status: ResultUnavailable}
	}
	if request.RootLanguage == "markdown" && request.InFence && request.ID != MarkdownSetFenceLanguage && !isLineEditCommand(request.ID) {
		return Outcome{Status: ResultUnavailable}
	}
	start, end := orderedRange(request)
	if request.SlashTrigger {
		return slashInsert(request, start, end)
	}
	switch request.ID {
	case MarkdownToggleStrong:
		return toggleInline(request, start, end, "**")
	case MarkdownToggleEmphasis:
		return toggleInline(request, start, end, "*")
	case MarkdownToggleStrike:
		return toggleInline(request, start, end, "~~")
	case MarkdownToggleInlineCode:
		return toggleInline(request, start, end, "`")
	case MarkdownInsertLink:
		return insertLink(request, start, end)
	case MarkdownHeading1, MarkdownHeading2, MarkdownHeading3:
		level := int(request.ID[len(request.ID)-1] - '0')
		return toggleLinePrefix(request, start, end, strings.Repeat("#", level)+" ", true)
	case MarkdownToggleBulletedList:
		return toggleList(request, start, end, false)
	case MarkdownToggleNumberedList:
		return toggleList(request, start, end, true)
	case MarkdownToggleQuote:
		return toggleLinePrefix(request, start, end, "> ", false)
	case MarkdownInsertTask:
		return taskCommand(request, start, end)
	case ItemToggle:
		return toggleProjectedTask(request)
	case MarkdownInsertCodeBlock:
		return insertCodeBlock(request, start, end)
	case MarkdownSetFenceLanguage:
		return setFenceLanguage(request)
	case MarkdownInsertTable:
		return insertLiteral(request, start, end, "| Column | Value |\n| --- | --- |\n|  |  |")
	case MarkdownTableNext:
		return navigateTable(request, false, false)
	case MarkdownTablePrevious:
		return navigateTable(request, true, false)
	case MarkdownTableEnter:
		return navigateTable(request, false, true)
	case MarkdownInsertDivider:
		return insertLiteral(request, start, end, "---")
	case DocumentFormat:
		return formatTable(request)
	case CommentToggle:
		return toggleComment(request, start, end)
	case MarkdownSmartPaste:
		return smartPaste(request, start, end)
	case EditIndentLines:
		return indentLines(request, start, end)
	case EditOutdentLines:
		return outdentLines(request, start, end)
	case EditDeleteLine:
		return deleteLines(request, start, end)
	case EditInsertLineAbove:
		return insertLine(request, start, end, false)
	case EditInsertLineBelow:
		return insertLine(request, start, end, true)
	case EditMoveLineUp:
		return moveLines(request, start, end, false)
	case EditMoveLineDown:
		return moveLines(request, start, end, true)
	case EditDuplicateLine:
		return duplicateLines(request, start, end)
	case EditJoinLines:
		return joinLines(request, start, end)
	default:
		return Outcome{Status: ResultUnavailable}
	}
}

func isLineEditCommand(id ID) bool {
	switch id {
	case EditIndentLines, EditOutdentLines, EditDeleteLine, EditInsertLineAbove,
		EditInsertLineBelow, EditMoveLineUp, EditMoveLineDown, EditDuplicateLine,
		EditJoinLines:
		return true
	default:
		return false
	}
}

func orderedRange(request Request) (int, int) {
	if request.RangeOverride {
		return clampRange(request.RangeStart, request.RangeEnd, len(request.Source))
	}
	if request.Anchor < request.Cursor {
		return request.Anchor, request.Cursor
	}
	return request.Cursor, request.Anchor
}

func clampRange(start, end, length int) (int, int) {
	if start < 0 {
		start = 0
	}
	if end < start {
		end = start
	}
	if end > length {
		end = length
	}
	return start, end
}

func outcome(request Request, start, end int, replacement string, cursor, anchor int) Outcome {
	if start == end && replacement == "" {
		return Outcome{Status: ResultNoOp, Cursor: request.Cursor, Anchor: request.Anchor}
	}
	return Outcome{Status: ResultExecuted, Start: start, End: end, Replacement: []byte(replacement), Cursor: cursor, Anchor: anchor}
}

func toggleInline(request Request, start, end int, marker string) Outcome {
	if start == end {
		start, end = wordRange(request.Source, request.Cursor)
	}
	if start == end {
		return outcome(request, request.Cursor, request.Cursor, marker+marker, request.Cursor+len(marker), request.Cursor+len(marker))
	}
	selected := string(request.Source[start:end])
	if strings.HasPrefix(selected, marker) && strings.HasSuffix(selected, marker) && len(selected) >= len(marker)*2 {
		innerStart := start + len(marker)
		innerEnd := end - len(marker)
		return outcome(request, start, end, selected[len(marker):len(selected)-len(marker)], innerEnd-len(marker), innerStart-len(marker))
	}
	if start >= len(marker) && end+len(marker) <= len(request.Source) && string(request.Source[start-len(marker):start]) == marker && string(request.Source[end:end+len(marker)]) == marker {
		return outcome(request, start-len(marker), end+len(marker), selected, end-len(marker), start-len(marker))
	}
	// Keep the selection on the original content after wrapping. This makes a
	// second toggle observe the delimiters immediately surrounding the
	// selection and remove them instead of nesting another pair.
	return outcome(request, start, end, marker+selected+marker, end+len(marker), start+len(marker))
}

func wordRange(source []byte, cursor int) (int, int) {
	start, end := cursor, cursor
	for start > 0 {
		r, size := utf8.DecodeLastRune(source[:start])
		if !unicode.IsLetter(r) && !unicode.IsNumber(r) && r != '_' {
			break
		}
		start -= size
	}
	for end < len(source) {
		r, size := utf8.DecodeRune(source[end:])
		if !unicode.IsLetter(r) && !unicode.IsNumber(r) && r != '_' {
			break
		}
		end += size
	}
	return start, end
}

func insertLink(request Request, start, end int) Outcome {
	if start == end {
		return outcome(request, start, end, "[](https://)", start+1, start+1)
	}
	label := string(request.Source[start:end])
	url := request.Argument
	if url == "" {
		url = "https://"
	}
	replacement := "[" + label + "](" + url + ")"
	return outcome(request, start, end, replacement, start+len(replacement), start)
}

func slashInsert(request Request, start, end int) Outcome {
	var replacement string
	var caretOffset int
	switch request.ID {
	case MarkdownToggleStrong:
		replacement, caretOffset = "****", 2
	case MarkdownToggleEmphasis:
		replacement, caretOffset = "**", 1
	case MarkdownToggleStrike:
		replacement, caretOffset = "~~~~", 2
	case MarkdownToggleInlineCode:
		replacement, caretOffset = "``", 1
	case MarkdownInsertLink:
		replacement, caretOffset = "[](https://)", 1
	case MarkdownHeading1:
		replacement, caretOffset = "# ", 2
	case MarkdownHeading2:
		replacement, caretOffset = "## ", 3
	case MarkdownHeading3:
		replacement, caretOffset = "### ", 4
	case MarkdownToggleBulletedList:
		replacement, caretOffset = "- ", 2
	case MarkdownToggleNumberedList:
		replacement, caretOffset = "1. ", 3
	case MarkdownToggleQuote:
		replacement, caretOffset = "> ", 2
	case MarkdownInsertTask:
		replacement, caretOffset = "- [ ] ", 6
	case MarkdownInsertCodeBlock:
		replacement, caretOffset = "```\n\n```", 4
	case MarkdownInsertTable:
		replacement, caretOffset = "| Column | Value |\n| --- | --- |\n|  |  |", 0
	case MarkdownInsertDivider:
		replacement, caretOffset = "---", 3
	default:
		return Outcome{Status: ResultUnavailable}
	}
	return outcome(request, start, end, replacement, start+caretOffset, start+caretOffset)
}

func smartPaste(request Request, start, end int) Outcome {
	text := request.Argument
	if text == "" {
		return Outcome{Status: ResultNoOp, Cursor: request.Cursor, Anchor: request.Anchor}
	}
	if start != end && (strings.HasPrefix(text, "https://") || strings.HasPrefix(text, "http://")) {
		label := string(request.Source[start:end])
		replacement := "[" + label + "](" + text + ")"
		return outcome(request, start, end, replacement, start+len(replacement), start)
	}
	return outcome(request, start, end, text, start+len(text), start+len(text))
}

func lineBounds(source []byte, start, end int) (int, int) {
	if start > len(source) {
		start = len(source)
	}
	if end > len(source) {
		end = len(source)
	}
	for start > 0 && source[start-1] != '\n' {
		start--
	}
	for end < len(source) && source[end] != '\n' {
		end++
	}
	return start, end
}

// sourceLine keeps the byte boundaries used by the editor while exposing a
// line's text without the CR in a CRLF terminator. Line commands operate on
// these logical lines and return one replacement so the caller can journal
// the whole action as a single undoable edit.
type sourceLine struct {
	start   int
	end     int
	fullEnd int
	text    string
}

func sourceLines(source []byte) []sourceLine {
	lines := make([]sourceLine, 0, bytes.Count(source, []byte{'\n'})+1)
	start := 0
	for {
		lf := bytes.IndexByte(source[start:], '\n')
		if lf < 0 {
			end := len(source)
			textEnd := end
			if textEnd > start && source[textEnd-1] == '\r' {
				textEnd--
			}
			lines = append(lines, sourceLine{start: start, end: end, fullEnd: end, text: string(source[start:textEnd])})
			return lines
		}
		end := start + lf
		textEnd := end
		if textEnd > start && source[textEnd-1] == '\r' {
			textEnd--
		}
		lines = append(lines, sourceLine{start: start, end: textEnd, fullEnd: end + 1, text: string(source[start:textEnd])})
		start = end + 1
		if start > len(source) {
			return lines
		}
	}
}

func lineEnding(source []byte) string {
	if at := bytes.IndexByte(source, '\n'); at >= 0 {
		if at > 0 && source[at-1] == '\r' {
			return "\r\n"
		}
	}
	return "\n"
}

func selectedLines(source []byte, start, end int) ([]sourceLine, int, int, int, int, string, bool) {
	lines := sourceLines(source)
	if len(lines) == 0 {
		return nil, 0, 0, 0, 0, "\n", false
	}
	first, ok := lineAt(source, start)
	if !ok {
		first = 0
	}
	last, ok := lineAt(source, end)
	if !ok {
		last = first
	}
	// A selection ending at the beginning of a line selects the preceding
	// line, which is the useful behavior for line-wise editing.
	if start != end && end > 0 && end <= len(source) && source[end-1] == '\n' {
		last--
	}
	if first < 0 {
		first = 0
	}
	if first >= len(lines) {
		first = len(lines) - 1
	}
	if last < first {
		last = first
	}
	if last >= len(lines) {
		last = len(lines) - 1
	}
	regionStart, regionEnd := lines[first].start, lines[last].fullEnd
	terminal := regionEnd > regionStart && source[regionEnd-1] == '\n'
	return lines, first, last, regionStart, regionEnd, lineEnding(source), terminal
}

func renderLineTexts(texts []string, eol string, terminal bool) string {
	result := strings.Join(texts, eol)
	if terminal {
		result += eol
	}
	return result
}

func removeOneIndent(text string) string {
	if strings.HasPrefix(text, "\t") {
		return text[1:]
	}
	spaces := 0
	for spaces < len(text) && text[spaces] == ' ' {
		spaces++
	}
	if spaces == 0 {
		return text
	}
	if spaces > 4 {
		spaces = 4
	}
	return text[spaces:]
}

func lineRegionPosition(position, regionStart, regionEnd int, original []sourceLine, transformed []string, eol string, lineMap, localDelta []int) int {
	oldLength := regionEnd - regionStart
	newLength := len(renderLineTexts(transformed, eol, regionEnd > regionStart && original[len(original)-1].fullEnd > original[len(original)-1].end))
	terminal := original[len(original)-1].fullEnd > original[len(original)-1].end
	if position < regionStart {
		return position
	}
	if position > regionEnd || (position == regionEnd && !terminal) {
		return position + newLength - oldLength
	}
	lineIndex := len(original) - 1
	for i, line := range original {
		if position >= line.start && position <= line.end {
			lineIndex = i
			break
		}
		if position < line.fullEnd {
			lineIndex = i
			position = line.end
			break
		}
	}
	newIndex := lineMap[lineIndex]
	newStart := regionStart
	for i := 0; i < newIndex; i++ {
		newStart += len(transformed[i]) + len(eol)
	}
	local := position - original[lineIndex].start + localDelta[lineIndex]
	if local < 0 {
		local = 0
	}
	if local > len(transformed[newIndex]) {
		local = len(transformed[newIndex])
	}
	return newStart + local
}

func identityLineMap(count int) ([]int, []int) {
	lineMap := make([]int, count)
	localDelta := make([]int, count)
	for i := range lineMap {
		lineMap[i] = i
	}
	return lineMap, localDelta
}

func indentLines(request Request, start, end int) Outcome {
	lines, first, last, regionStart, regionEnd, eol, terminal := selectedLines(request.Source, start, end)
	original := append([]sourceLine(nil), lines[first:last+1]...)
	transformed := make([]string, len(original))
	localDelta := make([]int, len(original))
	for i, line := range original {
		transformed[i] = "\t" + line.text
		localDelta[i] = 1
	}
	replacement := renderLineTexts(transformed, eol, terminal)
	lineMap, _ := identityLineMap(len(original))
	cursor := lineRegionPosition(request.Cursor, regionStart, regionEnd, original, transformed, eol, lineMap, localDelta)
	anchor := lineRegionPosition(request.Anchor, regionStart, regionEnd, original, transformed, eol, lineMap, localDelta)
	if replacement == string(request.Source[regionStart:regionEnd]) {
		return Outcome{Status: ResultNoOp, Cursor: request.Cursor, Anchor: request.Anchor}
	}
	return outcome(request, regionStart, regionEnd, replacement, cursor, anchor)
}

func outdentLines(request Request, start, end int) Outcome {
	lines, first, last, regionStart, regionEnd, eol, terminal := selectedLines(request.Source, start, end)
	original := append([]sourceLine(nil), lines[first:last+1]...)
	transformed := make([]string, len(original))
	localDelta := make([]int, len(original))
	for i, line := range original {
		transformed[i] = removeOneIndent(line.text)
		localDelta[i] = len(transformed[i]) - len(line.text)
	}
	replacement := renderLineTexts(transformed, eol, terminal)
	lineMap, _ := identityLineMap(len(original))
	cursor := lineRegionPosition(request.Cursor, regionStart, regionEnd, original, transformed, eol, lineMap, localDelta)
	anchor := lineRegionPosition(request.Anchor, regionStart, regionEnd, original, transformed, eol, lineMap, localDelta)
	if replacement == string(request.Source[regionStart:regionEnd]) {
		return Outcome{Status: ResultNoOp, Cursor: request.Cursor, Anchor: request.Anchor}
	}
	return outcome(request, regionStart, regionEnd, replacement, cursor, anchor)
}

func deleteLines(request Request, start, end int) Outcome {
	lines, first, _, _, regionEnd, _, _ := selectedLines(request.Source, start, end)
	deleteStart := lines[first].start
	deleteEnd := regionEnd
	if deleteStart == deleteEnd {
		return Outcome{Status: ResultNoOp, Cursor: request.Cursor, Anchor: request.Anchor}
	}
	return Outcome{Status: ResultExecuted, Start: deleteStart, End: deleteEnd, Replacement: []byte{}, Cursor: deleteStart, Anchor: deleteStart}
}

func insertLine(request Request, start, end int, below bool) Outcome {
	lines, first, last, _, _, eol, _ := selectedLines(request.Source, start, end)
	position := lines[first].start
	if below {
		position = lines[last].end
	}
	caret := position
	if below {
		caret += len(eol)
	}
	return outcome(request, position, position, eol, caret, caret)
}

func moveLines(request Request, start, end int, down bool) Outcome {
	lines, first, last, _, _, eol, _ := selectedLines(request.Source, start, end)
	neighbor := first - 1
	if down {
		neighbor = last + 1
	}
	if neighbor < 0 || neighbor >= len(lines) {
		return Outcome{Status: ResultNoOp, Cursor: request.Cursor, Anchor: request.Anchor}
	}
	regionFirst, regionLast := first, last
	if !down {
		regionFirst = neighbor
	} else {
		regionLast = neighbor
	}
	original := append([]sourceLine(nil), lines[regionFirst:regionLast+1]...)
	transformed := make([]string, len(original))
	lineMap := make([]int, len(original))
	localDelta := make([]int, len(original))
	if down {
		transformed[0] = original[len(original)-1].text
		lineMap[len(original)-1] = 0
		for i := 0; i < len(original)-1; i++ {
			transformed[i+1] = original[i].text
			lineMap[i] = i + 1
		}
	} else {
		for i := 0; i < len(original)-1; i++ {
			transformed[i] = original[i+1].text
			lineMap[i+1] = i
		}
		transformed[len(original)-1] = original[0].text
		lineMap[0] = len(original) - 1
	}
	regionStart, regionEnd := lines[regionFirst].start, lines[regionLast].fullEnd
	terminal := regionEnd > regionStart && request.Source[regionEnd-1] == '\n'
	replacement := renderLineTexts(transformed, eol, terminal)
	cursor := lineRegionPosition(request.Cursor, regionStart, regionEnd, original, transformed, eol, lineMap, localDelta)
	anchor := lineRegionPosition(request.Anchor, regionStart, regionEnd, original, transformed, eol, lineMap, localDelta)
	if replacement == string(request.Source[regionStart:regionEnd]) {
		return Outcome{Status: ResultNoOp, Cursor: request.Cursor, Anchor: request.Anchor}
	}
	return outcome(request, regionStart, regionEnd, replacement, cursor, anchor)
}

func duplicateLines(request Request, start, end int) Outcome {
	lines, first, last, regionStart, regionEnd, eol, terminal := selectedLines(request.Source, start, end)
	original := append([]sourceLine(nil), lines[first:last+1]...)
	texts := make([]string, len(original))
	for i, line := range original {
		texts[i] = line.text
	}
	copyText := renderLineTexts(texts, eol, terminal)
	copyStart := regionEnd
	if !terminal {
		copyText = eol + copyText
		copyStart += len(eol)
	}
	inserted := len(copyText)
	mapPosition := func(position int) int {
		if position < regionStart {
			return position
		}
		if position > regionEnd || (position == regionEnd && !terminal) {
			return position + inserted
		}
		local := position - regionStart
		if local < 0 {
			local = 0
		}
		if local > len(renderLineTexts(texts, eol, terminal)) {
			local = len(renderLineTexts(texts, eol, terminal))
		}
		return copyStart + local
	}
	return outcome(request, regionEnd, regionEnd, copyText, mapPosition(request.Cursor), mapPosition(request.Anchor))
}

func joinLines(request Request, start, end int) Outcome {
	lines, first, last, _, _, eol, _ := selectedLines(request.Source, start, end)
	if start == end {
		last++
	}
	if last >= len(lines) {
		return Outcome{Status: ResultNoOp, Cursor: request.Cursor, Anchor: request.Anchor}
	}
	original := append([]sourceLine(nil), lines[first:last+1]...)
	texts := make([]string, len(original))
	for i, line := range original {
		texts[i] = line.text
	}
	joined, bases := joinedTextAndBases(texts)
	regionStart, regionEnd := lines[first].start, lines[last].fullEnd
	terminal := regionEnd > regionStart && request.Source[regionEnd-1] == '\n'
	replacement := renderLineTexts([]string{joined}, eol, terminal)
	mapPosition := func(position int) int {
		oldLength := regionEnd - regionStart
		newLength := len(replacement)
		if position < regionStart {
			return position
		}
		if position > regionEnd || (position == regionEnd && !terminal) {
			return position + newLength - oldLength
		}
		index := len(original) - 1
		for i, line := range original {
			if position >= line.start && position <= line.end {
				index = i
				break
			}
			if position < line.fullEnd {
				index = i
				position = line.end
				break
			}
		}
		local := position - original[index].start
		leftTrim := len(strings.TrimRight(original[index].text, " \t"))
		leading := len(original[index].text) - len(strings.TrimLeft(original[index].text, " \t"))
		if index > 0 {
			local -= leading
		}
		if local < 0 {
			local = 0
		}
		if local > leftTrim && index == 0 {
			local = leftTrim
		}
		if local > len(joined)-bases[index] {
			local = len(joined) - bases[index]
		}
		return regionStart + bases[index] + local
	}
	if replacement == string(request.Source[regionStart:regionEnd]) {
		return Outcome{Status: ResultNoOp, Cursor: request.Cursor, Anchor: request.Anchor}
	}
	return outcome(request, regionStart, regionEnd, replacement, mapPosition(request.Cursor), mapPosition(request.Anchor))
}

func joinedTextAndBases(texts []string) (string, []int) {
	if len(texts) == 0 {
		return "", nil
	}
	result := texts[0]
	bases := make([]int, len(texts))
	for i := 1; i < len(texts); i++ {
		left := strings.TrimRight(result, " \t")
		right := strings.TrimLeft(texts[i], " \t")
		separator := ""
		if left != "" && right != "" {
			separator = " "
		}
		result = left + separator + right
		bases[i] = len(left) + len(separator)
	}
	return result, bases
}

func toggleLinePrefix(request Request, start, end int, prefix string, heading bool) Outcome {
	start, end = lineBounds(request.Source, start, end)
	old := string(request.Source[start:end])
	lines := strings.Split(old, "\n")
	remove := true
	for _, line := range lines {
		trimmed := strings.TrimLeft(line, " \t")
		if heading {
			if !strings.HasPrefix(trimmed, prefix) {
				remove = false
				break
			}
		} else if !strings.HasPrefix(trimmed, prefix) {
			remove = false
			break
		}
	}
	for i, line := range lines {
		indent := line[:len(line)-len(strings.TrimLeft(line, " \t"))]
		body := strings.TrimLeft(line, " \t")
		if remove {
			body = strings.TrimPrefix(body, prefix)
			lines[i] = indent + body
		} else if heading {
			if at := strings.IndexByte(body, ' '); at > 0 && strings.Trim(body[:at], "#") == "" {
				body = strings.TrimLeft(body[at+1:], " \t")
			}
			lines[i] = indent + prefix + body
		} else {
			lines[i] = indent + prefix + body
		}
	}
	replacement := strings.Join(lines, "\n")
	if replacement == old {
		return Outcome{Status: ResultNoOp, Cursor: request.Cursor, Anchor: request.Anchor}
	}
	delta := len(replacement) - (end - start)
	return outcome(request, start, end, replacement, shiftPosition(request.Cursor, start, end, delta), shiftPosition(request.Anchor, start, end, delta))
}

func toggleList(request Request, start, end int, numbered bool) Outcome {
	start, end = lineBounds(request.Source, start, end)
	old := string(request.Source[start:end])
	lines := strings.Split(old, "\n")
	remove := true
	for _, line := range lines {
		trimmed := strings.TrimLeft(line, " \t")
		if numbered {
			if !numberedPrefix(trimmed) {
				remove = false
				break
			}
		} else if !strings.HasPrefix(trimmed, "- ") && !strings.HasPrefix(trimmed, "* ") && !strings.HasPrefix(trimmed, "+ ") {
			remove = false
			break
		}
	}
	for i, line := range lines {
		indent := line[:len(line)-len(strings.TrimLeft(line, " \t"))]
		body := strings.TrimLeft(line, " \t")
		if remove {
			if numbered {
				body = stripNumberedPrefix(body)
			} else {
				body = body[2:]
			}
			lines[i] = indent + body
		} else if numbered {
			lines[i] = fmt.Sprintf("%s%d. %s", indent, i+1, body)
		} else {
			lines[i] = indent + "- " + body
		}
	}
	replacement := strings.Join(lines, "\n")
	delta := len(replacement) - (end - start)
	return outcome(request, start, end, replacement, shiftPosition(request.Cursor, start, end, delta), shiftPosition(request.Anchor, start, end, delta))
}

func numberedPrefix(line string) bool {
	for i, r := range line {
		if r == '.' && i+1 < len(line) && line[i+1] == ' ' {
			return i > 0
		}
		if r < '0' || r > '9' {
			return false
		}
	}
	return false
}

func stripNumberedPrefix(line string) string {
	for i := 0; i+1 < len(line); i++ {
		if line[i] == '.' && line[i+1] == ' ' {
			return line[i+2:]
		}
	}
	return line
}

func taskCommand(request Request, start, end int) Outcome {
	lineStart, lineEnd := lineBounds(request.Source, start, end)
	line := string(request.Source[lineStart:lineEnd])
	for _, marker := range []string{"[ ]", "[x]", "[X]"} {
		at := strings.Index(line, marker)
		if at >= 0 && (at == 0 || line[at-1] == ' ' || line[at-1] == '\t') {
			replacement := "[x]"
			if marker != "[ ]" {
				replacement = "[ ]"
			}
			return outcome(request, lineStart+at, lineStart+at+3, replacement, request.Cursor, request.Anchor)
		}
	}
	replacement := "- [ ] " + line
	return outcome(request, lineStart, lineEnd, replacement, lineStart+len(replacement), lineStart+len(replacement))
}

func toggleProjectedTask(request Request) Outcome {
	if !request.ProjectionsCurrent {
		return Outcome{Status: ResultUnavailable}
	}
	for _, task := range request.Projections.Tasks {
		if request.Cursor < task.StartByte || request.Cursor > task.EndByte {
			continue
		}
		marker := string(request.Source[task.MarkerStart:task.MarkerEnd])
		if marker != "[ ]" && marker != "[x]" && marker != "[X]" {
			return Outcome{Status: ResultUnavailable}
		}
		replacement := "[x]"
		if marker != "[ ]" {
			replacement = "[ ]"
		}
		return outcome(request, task.MarkerStart, task.MarkerEnd, replacement, request.Cursor, request.Anchor)
	}
	return Outcome{Status: ResultUnavailable}
}

func insertCodeBlock(request Request, start, end int) Outcome {
	if start == end {
		start, end = lineBounds(request.Source, request.Cursor, request.Cursor)
	}
	body := string(request.Source[start:end])
	replacement := "```" + strings.TrimSpace(request.Argument) + "\n" + body + "\n```"
	return outcome(request, start, end, replacement, start+len("```"+strings.TrimSpace(request.Argument)+"\n"), start+len("```"+strings.TrimSpace(request.Argument)+"\n"))
}

func setFenceLanguage(request Request) Outcome {
	if request.RootLanguage != "markdown" || request.Argument == "" {
		return Outcome{Status: ResultUnavailable}
	}
	line, ok := lineAt(request.Source, request.Cursor)
	if !ok {
		return Outcome{Status: ResultUnavailable}
	}
	lineCount := lenFenceLines(request.Source)
	for openerLine := 0; openerLine <= line; {
		opener, ok := parseFenceLine(request.Source, openerLine)
		if !ok {
			openerLine++
			continue
		}
		closingLine := -1
		for candidateLine := openerLine + 1; candidateLine < lineCount; candidateLine++ {
			candidate, candidateOK := parseFenceLine(request.Source, candidateLine)
			if candidateOK && candidate.closing && candidate.marker == opener.marker && candidate.markerLen >= opener.markerLen {
				closingLine = candidateLine
				break
			}
		}
		if closingLine < 0 {
			return Outcome{Status: ResultUnavailable}
		}
		if line < closingLine {
			if line <= openerLine {
				return Outcome{Status: ResultUnavailable}
			}
			start, end, ok := lineRange(request.Source, openerLine)
			if !ok {
				return Outcome{Status: ResultUnavailable}
			}
			if end > start && request.Source[end-1] == '\r' {
				end--
			}
			indent := string(request.Source[start:opener.markerStart])
			delimiter := strings.Repeat(string(opener.marker), opener.markerLen)
			replacement := indent + delimiter + strings.TrimSpace(request.Argument)
			delta := len(replacement) - (end - start)
			return outcome(request, start, end, replacement, shiftPosition(request.Cursor, start, end, delta), shiftPosition(request.Anchor, start, end, delta))
		}
		openerLine = closingLine + 1
	}
	return Outcome{Status: ResultUnavailable}
}

type fenceLine struct {
	marker      byte
	markerLen   int
	markerStart int
	closing     bool
}

func lenFenceLines(source []byte) int {
	lines := 1
	for _, value := range source {
		if value == '\n' {
			lines++
		}
	}
	return lines
}

func parseFenceLine(source []byte, line int) (fenceLine, bool) {
	start, end, ok := lineRange(source, line)
	if !ok {
		return fenceLine{}, false
	}
	if end > start && source[end-1] == '\r' {
		end--
	}
	markerStart := start
	for markerStart < end && (source[markerStart] == ' ' || source[markerStart] == '\t') {
		markerStart++
	}
	if markerStart-start > 3 || markerStart >= end || (source[markerStart] != '`' && source[markerStart] != '~') {
		return fenceLine{}, false
	}
	marker := source[markerStart]
	markerEnd := markerStart
	for markerEnd < end && source[markerEnd] == marker {
		markerEnd++
	}
	if markerEnd-markerStart < 3 {
		return fenceLine{}, false
	}
	rest := strings.TrimSpace(string(source[markerEnd:end]))
	if marker == '`' && strings.Contains(rest, "`") {
		return fenceLine{}, false
	}
	return fenceLine{marker: marker, markerLen: markerEnd - markerStart, markerStart: markerStart, closing: rest == ""}, true
}

func lineAt(source []byte, cursor int) (int, bool) {
	if cursor < 0 || cursor > len(source) {
		return 0, false
	}
	line := 0
	for _, value := range source[:cursor] {
		if value == '\n' {
			line++
		}
	}
	return line, true
}

func lineRange(source []byte, line int) (int, int, bool) {
	if line < 0 {
		return 0, 0, false
	}
	start := 0
	for current := 0; current < line; current++ {
		next := bytes.IndexByte(source[start:], '\n')
		if next < 0 {
			return 0, 0, false
		}
		start += next + 1
	}
	newline := bytes.IndexByte(source[start:], '\n')
	if newline < 0 {
		return start, len(source), true
	}
	return start, start + newline, true
}

func insertLiteral(request Request, start, end int, literal string) Outcome {
	return outcome(request, start, end, literal, start+len(literal), start+len(literal))
}

func formatTable(request Request) Outcome {
	if !request.ProjectionsCurrent {
		return Outcome{Status: ResultUnavailable}
	}
	for _, table := range request.Projections.Tables {
		if request.Cursor < table.StartByte || request.Cursor >= table.EndByte {
			continue
		}
		formatted, ok := md.FormatTable(request.Source, table)
		if !ok || bytes.Equal(formatted, request.Source[table.StartByte:table.EndByte]) {
			return Outcome{Status: ResultNoOp, Cursor: request.Cursor, Anchor: request.Anchor}
		}
		cursor, anchor := remapRange(request.Cursor, request.Anchor, table.StartByte, table.EndByte, formatted)
		return outcome(request, table.StartByte, table.EndByte, string(formatted), cursor, anchor)
	}
	return Outcome{Status: ResultUnavailable}
}

func navigateTable(request Request, previous, enter bool) Outcome {
	if !request.ProjectionsCurrent {
		return Outcome{Status: ResultUnavailable}
	}
	table, ok := projectedTableAt(request.Projections.Tables, request.Cursor)
	if !ok {
		return Outcome{Status: ResultUnavailable}
	}
	row, column, ok := projectedTableCell(table, request.Cursor)
	if !ok {
		return Outcome{Status: ResultUnavailable}
	}
	tableSource := append([]byte(nil), request.Source[table.StartByte:table.EndByte]...)
	formatted, ok := md.FormatTable(request.Source, table)
	if !ok {
		return Outcome{Status: ResultUnavailable}
	}
	formatChanged := !bytes.Equal(formatted, tableSource)
	tableSource = formatted
	local := md.Project(tableSource, 1)
	if len(local.Tables) == 0 {
		return Outcome{Status: ResultUnavailable}
	}
	rows := navigationRows(local.Tables[0])
	if row < 0 || row >= len(rows) {
		return Outcome{Status: ResultUnavailable}
	}
	targetRow, targetColumn := row, column
	create := false
	if enter {
		targetRow++
		if targetRow >= len(rows) || targetColumn >= len(rows[targetRow].Cells) {
			create = true
		}
	} else if previous {
		if targetColumn > 0 {
			targetColumn--
		} else if targetRow > 0 {
			targetRow--
			targetColumn = len(rows[targetRow].Cells) - 1
		} else {
			return Outcome{Status: ResultNoOp, Cursor: request.Cursor, Anchor: request.Anchor}
		}
	} else if targetColumn+1 < len(rows[targetRow].Cells) {
		targetColumn++
	} else if targetRow+1 < len(rows) {
		targetRow++
		targetColumn = 0
	} else {
		create = true
		targetRow = len(rows)
		targetColumn = 0
	}
	if create {
		tableSource = appendEmptyTableRow(tableSource, len(table.Columns))
		local = md.Project(tableSource, 1)
		if len(local.Tables) == 0 {
			return Outcome{Status: ResultUnavailable}
		}
		rows = navigationRows(local.Tables[0])
	}
	if targetRow < 0 || targetRow >= len(rows) || targetColumn < 0 || targetColumn >= len(rows[targetRow].Cells) {
		return Outcome{Status: ResultUnavailable}
	}
	target := table.StartByte + rows[targetRow].Cells[targetColumn].StartByte
	if !formatChanged && !create {
		return Outcome{Status: ResultExecuted, Start: request.Cursor, End: request.Cursor, Cursor: target, Anchor: target}
	}
	return Outcome{Status: ResultExecuted, Start: table.StartByte, End: table.EndByte, Replacement: tableSource, Cursor: target, Anchor: target}
}

func projectedTableAt(tables []document.TableProjection, cursor int) (document.TableProjection, bool) {
	for _, table := range tables {
		if cursor >= table.StartByte && cursor < table.EndByte {
			return table, true
		}
	}
	return document.TableProjection{}, false
}

func projectedTableCell(table document.TableProjection, cursor int) (int, int, bool) {
	rowNumber := 0
	for _, row := range table.Rows {
		if row.Delimiter {
			continue
		}
		for column, cell := range row.Cells {
			if cursor >= cell.StartByte && cursor <= cell.EndByte {
				return rowNumber, column, true
			}
		}
		rowNumber++
	}
	return 0, 0, false
}

func navigationRows(table document.TableProjection) []document.TableRow {
	rows := make([]document.TableRow, 0, len(table.Rows))
	for _, row := range table.Rows {
		if !row.Delimiter {
			rows = append(rows, row)
		}
	}
	return rows
}

func appendEmptyTableRow(source []byte, columnCount int) []byte {
	newline := "\n"
	if bytes.Contains(source, []byte("\r\n")) {
		newline = "\r\n"
	}
	count := columnCount
	if count < 1 {
		count = 1
	}
	row := "|" + strings.Repeat("   |", count)
	if len(source) > 0 && source[len(source)-1] == '\n' {
		return append(append(append([]byte(nil), source...), row...), newline...)
	}
	result := append(append([]byte(nil), source...), newline...)
	return append(result, row...)
}

func toggleComment(request Request, start, end int) Outcome {
	if !commentLanguage(request.RootLanguage) {
		return Outcome{Status: ResultUnavailable}
	}
	start, end = lineBounds(request.Source, start, end)
	old := string(request.Source[start:end])
	lines := strings.Split(old, "\n")
	all := true
	for _, line := range lines {
		trimmed := strings.TrimLeft(line, " \t")
		if trimmed != "" && !strings.HasPrefix(trimmed, "//") {
			all = false
			break
		}
	}
	for i, line := range lines {
		indent := line[:len(line)-len(strings.TrimLeft(line, " \t"))]
		body := strings.TrimLeft(line, " \t")
		if body == "" {
			continue
		}
		if all {
			body = strings.TrimPrefix(body, "//")
			body = strings.TrimPrefix(body, " ")
			lines[i] = indent + body
		} else {
			lines[i] = indent + "// " + body
		}
	}
	replacement := strings.Join(lines, "\n")
	delta := len(replacement) - (end - start)
	return outcome(request, start, end, replacement, shiftPosition(request.Cursor, start, end, delta), shiftPosition(request.Anchor, start, end, delta))
}

func commentLanguage(id string) bool {
	return language.DefaultRegistry().SupportsCommentToggle(language.ID(id))
}

func shiftPosition(position, start, end, delta int) int {
	if position <= start {
		return position
	}
	if position >= end {
		return position + delta
	}
	return start + delta
}

func remapRange(cursor, anchor, start, end int, replacement []byte) (int, int) {
	delta := len(replacement) - (end - start)
	return remapPosition(cursor, start, end, len(replacement), delta), remapPosition(anchor, start, end, len(replacement), delta)
}

func remapPosition(position, start, end, replacementLength, delta int) int {
	if position <= start {
		return position
	}
	if position >= end {
		return position + delta
	}
	relative := position - start
	if relative > replacementLength {
		relative = replacementLength
	}
	return start + relative
}
