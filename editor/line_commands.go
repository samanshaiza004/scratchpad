package editor

import (
	"bytes"
	"errors"
)

// DefaultIndent is the indentation inserted by the keyboard line commands.
// Callers that use spaces can pass their unit to Indent or Outdent.
const DefaultIndent = "\t"

// lineEnding returns the first line-ending convention in the document. A
// document without a line ending defaults to LF, which is also the safest
// representation for a new file.
func (e *ScratchEditor) lineEnding() []byte {
	text := e.Buffer.Text()
	for index, value := range text {
		if value != '\n' {
			continue
		}
		if index > 0 && text[index-1] == '\r' {
			return []byte("\r\n")
		}
		return []byte{'\n'}
	}
	return []byte{'\n'}
}

// newlineText is the single-line Enter payload used by Insert. It copies
// only leading ASCII space/tab indentation; all other bytes remain literal.
func (e *ScratchEditor) newlineText(at int) []byte {
	eol := e.lineEnding()
	line, ok := e.Buffer.LineAt(at)
	if !ok {
		return append([]byte(nil), eol...)
	}
	text, ok := e.Buffer.Line(line)
	if !ok {
		return append([]byte(nil), eol...)
	}
	indentEnd := 0
	for indentEnd < len(text) && (text[indentEnd] == ' ' || text[indentEnd] == '\t') {
		indentEnd++
	}
	result := make([]byte, len(eol)+indentEnd)
	copy(result, eol)
	copy(result[len(eol):], text[:indentEnd])
	return result
}

// selectedLineRange returns the logical lines touched by the selection. An
// endpoint exactly at the start of the following line does not accidentally
// make that following line part of the selection.
func (e *ScratchEditor) selectedLineRange() (first, last int, ok bool) {
	from, to := e.selection()
	first, ok = e.Buffer.LineAt(from)
	if !ok {
		return 0, 0, false
	}
	if from == to {
		return first, first, true
	}
	last, ok = e.Buffer.LineAt(to)
	if !ok {
		return 0, 0, false
	}
	if last > first && to == e.Buffer.lineStart(last) {
		last--
	}
	return first, last, true
}

func (e *ScratchEditor) wholeLineRange(first, last int) (start, end int, ok bool) {
	if first < 0 || last < first || last >= e.Buffer.LineCount() {
		return 0, 0, false
	}
	start, _, ok = e.Buffer.LineRange(first)
	if !ok {
		return 0, 0, false
	}
	if last+1 < e.Buffer.LineCount() {
		end = e.Buffer.lineStart(last + 1)
	} else {
		end = e.Buffer.ByteLen()
	}
	return start, end, true
}

func (e *ScratchEditor) currentLineEditRange() (start, end int) {
	line, ok := e.Buffer.LineAt(e.Cursor)
	if !ok {
		return e.Cursor, e.Cursor
	}
	start, end, ok = e.Buffer.LineRange(line)
	if !ok {
		return e.Cursor, e.Cursor
	}
	if end < e.Buffer.ByteLen() {
		end++
	}
	return start, end
}

func (e *ScratchEditor) lineContents(first, last int) ([][]byte, bool) {
	if first < 0 || last < first || last >= e.Buffer.LineCount() {
		return nil, false
	}
	lines := make([][]byte, 0, last-first+1)
	for line := first; line <= last; line++ {
		start, end, ok := e.Buffer.LineRange(line)
		if !ok {
			return nil, false
		}
		text, err := e.Buffer.Bytes(start, end)
		if err != nil {
			return nil, false
		}
		// Buffer.LineRange excludes LF but intentionally leaves the CR from a
		// CRLF terminator in the returned range. Line transformations operate
		// on content plus an explicitly selected separator, so remove that CR
		// only when it is immediately followed by the line's LF.
		if bytes.HasSuffix(text, []byte{'\r'}) {
			next, nextErr := e.Buffer.Bytes(end, end+1)
			if nextErr == nil && len(next) == 1 && next[0] == '\n' {
				text = text[:len(text)-1]
			}
		}
		lines = append(lines, append([]byte(nil), text...))
	}
	return lines, true
}

func (e *ScratchEditor) replaceSelection(start, end int, text []byte, anchor, cursor int) error {
	return e.replaceWithSelection(start, end, text, &selectionState{anchor: anchor, cursor: cursor})
}

func joinLineContents(lines [][]byte, trailingNewline bool, eol []byte) []byte {
	if len(lines) == 0 {
		return nil
	}
	length := 0
	for _, line := range lines {
		length += len(line)
	}
	length += (len(lines) - 1) * len(eol)
	if trailingNewline {
		length += len(eol)
	}
	result := make([]byte, 0, length)
	for i, line := range lines {
		if i != 0 {
			result = append(result, eol...)
		}
		result = append(result, line...)
	}
	if trailingNewline {
		result = append(result, eol...)
	}
	return result
}

func lineContentLength(lines [][]byte, separatorLength int) int {
	length := 0
	for i, line := range lines {
		length += len(line)
		if i != 0 {
			length += separatorLength
		}
	}
	return length
}

func (e *ScratchEditor) mapMovedSelection(blockStart, contentLength, destination int, position int) int {
	relative := position - blockStart
	if relative < 0 {
		relative = 0
	}
	if relative > contentLength {
		relative = contentLength
	}
	return destination + relative
}

// Indent prefixes every selected line, or the current line when the
// selection is empty. The default unit is a tab; a space unit may be passed
// for projects configured to indent with spaces.
func (e *ScratchEditor) Indent(unit ...string) error {
	indent := []byte(DefaultIndent)
	if len(unit) > 0 {
		indent = []byte(unit[0])
	}
	if bytes.IndexByte(indent, '\n') >= 0 || bytes.IndexByte(indent, '\r') >= 0 {
		return errors.New("indent unit contains a line break")
	}
	if len(indent) == 0 {
		return nil
	}
	first, last, ok := e.selectedLineRange()
	if !ok {
		return nil
	}
	start, end, ok := e.wholeLineRange(first, last)
	if !ok {
		return nil
	}
	lines, ok := e.lineContents(first, last)
	if !ok {
		return nil
	}
	for index := range lines {
		lines[index] = append(append([]byte(nil), indent...), lines[index]...)
	}
	eol := e.lineEnding()
	replacement := joinLineContents(lines, last+1 < e.Buffer.LineCount(), eol)
	mapPosition := func(position int) int {
		shift := 0
		for line := first; line <= last; line++ {
			lineStart, _, _ := e.Buffer.LineRange(line)
			if position >= lineStart {
				shift += len(indent)
			}
		}
		return position + shift
	}
	return e.replaceSelection(start, end, replacement,
		mapPosition(e.Anchor), mapPosition(e.Cursor))
}

// Outdent removes one indentation unit from every selected/current line. A
// partial final space run is removed completely, which makes outdenting an
// accidentally short-indented line predictable.
func (e *ScratchEditor) Outdent(unit ...string) error {
	indent := []byte(DefaultIndent)
	if len(unit) > 0 {
		indent = []byte(unit[0])
	}
	if bytes.IndexByte(indent, '\n') >= 0 || bytes.IndexByte(indent, '\r') >= 0 {
		return errors.New("indent unit contains a line break")
	}
	if len(indent) == 0 {
		return nil
	}
	first, last, ok := e.selectedLineRange()
	if !ok {
		return nil
	}
	start, end, ok := e.wholeLineRange(first, last)
	if !ok {
		return nil
	}
	old, err := e.Buffer.Bytes(start, end)
	if err != nil {
		return err
	}
	lines, ok := e.lineContents(first, last)
	if !ok {
		return nil
	}
	replacement := make([]byte, 0, len(old))
	removed := make([]int, 0, last-first+1)
	for line := first; line <= last; line++ {
		contents := lines[line-first]
		count := 0
		for count < len(contents) && count < len(indent) && contents[count] == indent[count] {
			count++
		}
		// A spaces unit can remove fewer spaces than the unit when the line
		// has only a partial indentation run.
		if len(indent) > 0 && indent[0] == ' ' {
			count = 0
			for count < len(contents) && count < len(indent) && contents[count] == ' ' {
				count++
			}
		}
		removed = append(removed, count)
		lines[line-first] = contents[count:]
	}
	changed := false
	for _, count := range removed {
		changed = changed || count != 0
	}
	if !changed {
		return nil
	}
	replacement = joinLineContents(lines, last+1 < e.Buffer.LineCount(), e.lineEnding())
	mapPosition := func(position int) int {
		prior := 0
		for index := 0; index < last-first+1; index++ {
			lineNumber := first + index
			lineStart, lineEnd, _ := e.Buffer.LineRange(lineNumber)
			count := removed[index]
			if position < lineStart {
				break
			}
			if position < lineStart+count {
				return lineStart - prior
			}
			if position <= lineEnd || lineNumber == last {
				return position - prior - count
			}
			prior += count
		}
		return position - prior
	}
	return e.replaceSelection(start, end, replacement,
		mapPosition(e.Anchor), mapPosition(e.Cursor))
}

// DeleteLine removes the whole current line or all lines touched by the
// selection. The line terminator is included when one exists.
func (e *ScratchEditor) DeleteLine() error {
	first, last, ok := e.selectedLineRange()
	if !ok {
		return nil
	}
	start, end, ok := e.wholeLineRange(first, last)
	if !ok {
		return nil
	}
	return e.replace(start, end, nil)
}

func (e *ScratchEditor) DeleteCurrentLine() error   { return e.DeleteLine() }
func (e *ScratchEditor) DeleteSelectedLines() error { return e.DeleteLine() }

// InsertLineAbove and InsertLineBelow insert a blank line relative to the
// current line block and leave the caret on that new blank line.
func (e *ScratchEditor) InsertLineAbove() error {
	first, _, ok := e.selectedLineRange()
	if !ok {
		return nil
	}
	start, _, ok := e.Buffer.LineRange(first)
	if !ok {
		return nil
	}
	return e.replaceSelection(start, start, e.lineEnding(), start, start)
}

func (e *ScratchEditor) InsertLineBelow() error {
	first, last, ok := e.selectedLineRange()
	if !ok {
		return nil
	}
	_, end, ok := e.wholeLineRange(first, last)
	if !ok {
		return nil
	}
	eol := e.lineEnding()
	return e.replaceSelection(end, end, eol, end+len(eol), end+len(eol))
}

// SelectLine selects the current line's content (not its LF). The optional
// extend form is useful for a Shift-style line selection.
func (e *ScratchEditor) SelectLine(extend ...bool) {
	line, ok := e.Buffer.LineAt(e.Cursor)
	if !ok {
		return
	}
	start, end, ok := e.Buffer.LineRange(line)
	if !ok {
		return
	}
	if len(extend) > 0 && extend[0] {
		e.Cursor = end
	} else {
		e.Anchor, e.Cursor = start, end
	}
	e.Affinity = AffinityLeading
	e.ClearPreferredVerticalX()
}

func (e *ScratchEditor) SelectCurrentLine() { e.SelectLine() }

// MoveLineUp and MoveLineDown swap the touched line block with its neighbor.
// The selection/caret remains attached to the moved block.
func (e *ScratchEditor) MoveLineUp() error    { return e.moveLines(-1) }
func (e *ScratchEditor) MoveLineDown() error  { return e.moveLines(1) }
func (e *ScratchEditor) MoveLinesUp() error   { return e.moveLines(-1) }
func (e *ScratchEditor) MoveLinesDown() error { return e.moveLines(1) }

func (e *ScratchEditor) moveLines(direction int) error {
	first, last, ok := e.selectedLineRange()
	if !ok || (direction < 0 && first == 0) || (direction > 0 && last+1 >= e.Buffer.LineCount()) {
		return nil
	}
	block, ok := e.lineContents(first, last)
	if !ok {
		return nil
	}
	eol := e.lineEnding()
	contentLength := lineContentLength(block, len(eol))
	blockStart, blockEnd, _ := e.wholeLineRange(first, last)
	var regionStart, regionEnd, destination int
	var replacement []byte
	if direction < 0 {
		previous, _ := e.lineContents(first-1, first-1)
		regionStart, _, _ = e.Buffer.LineRange(first - 1)
		regionEnd = blockEnd
		trailing := regionEnd != e.Buffer.ByteLen()
		replacement = joinLineContents(append(block, previous[0]), trailing, eol)
		destination = regionStart
	} else {
		next, _ := e.lineContents(last+1, last+1)
		regionStart = blockStart
		_, regionEnd, _ = e.wholeLineRange(last+1, last+1)
		trailing := regionEnd != e.Buffer.ByteLen()
		replacement = joinLineContents(append(next, block...), trailing, eol)
		destination = regionStart + len(next[0]) + len(eol)
	}
	return e.replaceSelection(regionStart, regionEnd, replacement,
		e.mapMovedSelection(blockStart, contentLength, destination, e.Anchor),
		e.mapMovedSelection(blockStart, contentLength, destination, e.Cursor))
}

// DuplicateLineUp and DuplicateLineDown duplicate the touched line block and
// move the selection/caret to the newly created copy.
func (e *ScratchEditor) DuplicateLineUp() error    { return e.duplicateLines(-1) }
func (e *ScratchEditor) DuplicateLineDown() error  { return e.duplicateLines(1) }
func (e *ScratchEditor) DuplicateLinesUp() error   { return e.duplicateLines(-1) }
func (e *ScratchEditor) DuplicateLinesDown() error { return e.duplicateLines(1) }

func (e *ScratchEditor) duplicateLines(direction int) error {
	first, last, ok := e.selectedLineRange()
	if !ok {
		return nil
	}
	start, end, _ := e.wholeLineRange(first, last)
	block, err := e.Buffer.Bytes(start, end)
	if err != nil {
		return err
	}
	content, _ := e.lineContents(first, last)
	eol := e.lineEnding()
	contentLength := lineContentLength(content, len(eol))
	insertAt := start
	duplicate := append([]byte(nil), block...)
	destination := insertAt
	if direction > 0 {
		insertAt = end
		if end == e.Buffer.ByteLen() {
			if !bytes.HasSuffix(block, eol) {
				duplicate = append(append([]byte(nil), eol...), duplicate...)
				destination = insertAt + len(eol)
			}
		} else {
			destination = insertAt
		}
	} else if end == e.Buffer.ByteLen() {
		if !bytes.HasSuffix(block, eol) {
			duplicate = append(duplicate, eol...)
		}
	}
	return e.replaceSelection(insertAt, insertAt, duplicate,
		e.mapMovedSelection(start, contentLength, destination, e.Anchor),
		e.mapMovedSelection(start, contentLength, destination, e.Cursor))
}

// JoinLines joins the current line to the next, or all touched selected
// lines. It trims indentation around the join and inserts one separating
// space when both sides contain text.
func (e *ScratchEditor) JoinLines() error {
	first, last, ok := e.selectedLineRange()
	if !ok {
		return nil
	}
	if first == last {
		last++
		if last >= e.Buffer.LineCount() {
			return nil
		}
	}
	lines, ok := e.lineContents(first, last)
	if !ok {
		return nil
	}
	joined := make([]byte, 0)
	for _, line := range lines {
		line = bytes.TrimRight(line, " \t")
		line = bytes.TrimLeft(line, " \t")
		if len(line) == 0 {
			continue
		}
		if len(joined) != 0 {
			joined = append(joined, ' ')
		}
		joined = append(joined, line...)
	}
	start, _, _ := e.Buffer.LineRange(first)
	_, end, _ := e.Buffer.LineRange(last)
	from, to := e.selection()
	if from == to {
		firstLine, firstEnd, _ := e.Buffer.LineRange(first)
		left, _ := e.Buffer.Bytes(firstLine, firstEnd)
		left = bytes.TrimRight(left, " \t")
		joinPoint := start + len(left)
		if joinPoint < start+len(joined) {
			joinPoint++
		}
		return e.replaceSelection(start, end, joined, joinPoint, joinPoint)
	}
	return e.replaceSelection(start, end, joined, start+len(joined), start+len(joined))
}

func (e *ScratchEditor) JoinSelectedLines() error { return e.JoinLines() }
