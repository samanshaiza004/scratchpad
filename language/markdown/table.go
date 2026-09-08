package markdown

import (
	"github.com/yuin/goldmark/v2/ast"
	markdownast "github.com/yuin/goldmark/v2/extension/ast"
	"scratchpad/document"
)

// collectTableProjections lowers every *markdownast.Table in the already-parsed
// Goldmark tree into source-byte-only table projections. It intentionally
// produces no Shirei values and never mutates source.
//
// Table recognition and column alignments come from the parser: a table node
// exists only when Goldmark accepted a header/delimiter pair, and each header
// cell already carries the alignment declared by the delimiter colons. Row,
// cell, and pipe geometry is then re-derived from source lines with a
// table-aware scanner (only escaped pipes never split; optional leading/trailing
// pipes handled) so uneven rows are preserved as-is even
// where Goldmark drops or pads cells.
func collectTableProjections(root ast.Node, source []byte, revision uint64) []document.TableProjection {
	var tables []document.TableProjection
	_ = ast.Walk(root, func(node ast.Node, entering bool) (ast.WalkStatus, error) {
		if !entering {
			return ast.WalkContinue, nil
		}
		table, ok := node.(*markdownast.Table)
		if !ok {
			return ast.WalkContinue, nil
		}
		if projection, ok := projectTable(table, source, revision); ok {
			tables = append(tables, projection)
		}
		return ast.WalkSkipChildren, nil
	})
	return tables
}

// projectTable builds one table projection. It returns false when the table
// node has no usable header (defensive: the parser should always provide one).
func projectTable(table *markdownast.Table, source []byte, revision uint64) (document.TableProjection, bool) {
	var header *markdownast.TableHeader
	var bodies []*markdownast.TableBody
	for child := table.FirstChild(); child != nil; child = child.NextSibling() {
		switch node := child.(type) {
		case *markdownast.TableHeader:
			if header == nil {
				header = node
			}
		case *markdownast.TableBody:
			bodies = append(bodies, node)
		}
	}
	if header == nil || header.FirstChild() == nil {
		return document.TableProjection{}, false
	}
	columns := make([]document.TableColumn, 0, 8)
	for child := header.FirstChild(); child != nil; child = child.NextSibling() {
		cell, ok := child.(*markdownast.TableCell)
		if !ok {
			continue
		}
		columns = append(columns, document.TableColumn{Alignment: mapTableAlignment(cell.Alignment)})
	}
	if len(columns) == 0 {
		return document.TableProjection{}, false
	}

	headerStart := lineStart(source, header.Pos())
	headerEnd := lineEnd(source, headerStart)
	// The delimiter line is always the source line immediately following the
	// header line: the parser only forms a table from an adjacent
	// header/delimiter pair.
	delimiterStart := headerEnd
	if delimiterStart < len(source) && source[delimiterStart] == '\n' {
		delimiterStart++
	}
	if delimiterStart > len(source) {
		return document.TableProjection{}, false
	}
	delimiterEnd := lineEnd(source, delimiterStart)

	projection := document.TableProjection{Revision: revision, StartByte: headerStart}
	projection.Rows = append(projection.Rows, splitTableRow(source, headerStart, headerEnd, true, false))
	projection.Rows = append(projection.Rows, splitTableRow(source, delimiterStart, delimiterEnd, false, true))
	lastEnd := delimiterEnd
	for _, body := range bodies {
		for child := body.FirstChild(); child != nil; child = child.NextSibling() {
			row, ok := child.(*markdownast.TableRow)
			if !ok {
				continue
			}
			rowStart := lineStart(source, row.Pos())
			rowEnd := lineEnd(source, rowStart)
			projection.Rows = append(projection.Rows, splitTableRow(source, rowStart, rowEnd, false, false))
			lastEnd = rowEnd
		}
	}
	projection.Columns = columns
	// Match the BlockTable convention: cover the terminating newline of the
	// last row line when one is present.
	projection.EndByte = lastEnd
	if projection.EndByte < len(source) && source[projection.EndByte] == '\n' {
		projection.EndByte++
	}
	return projection, true
}

// mapTableAlignment converts a Goldmark delimiter-colon alignment into the
// parser-neutral contract. AlignNone (plain `---`) maps to the default.
func mapTableAlignment(alignment markdownast.Alignment) document.TableAlignment {
	switch alignment {
	case markdownast.AlignLeft:
		return document.TableAlignLeft
	case markdownast.AlignCenter:
		return document.TableAlignCenter
	case markdownast.AlignRight:
		return document.TableAlignRight
	default:
		return document.TableAlignDefault
	}
}

// splitTableRow derives one row's cells and pipes from its source line.
// Delimiter pipes are unescaped `|` bytes, including when they occur inside
// inline spans; cell ranges are trimmed of surrounding ASCII whitespace.
// Column is the zero-based position in the row, preserving uneven rows as-is.
func splitTableRow(source []byte, start, end int, header, delimiter bool) document.TableRow {
	rowEnd := end
	if rowEnd > start && source[rowEnd-1] == '\r' {
		rowEnd--
	}
	row := document.TableRow{StartByte: start, EndByte: rowEnd, Header: header, Delimiter: delimiter}
	pipeOffsets := tablePipeOffsets(source, start, rowEnd)
	pipes := make([]document.ByteRange, 0, len(pipeOffsets))
	for _, offset := range pipeOffsets {
		pipes = append(pipes, document.ByteRange{StartByte: offset, EndByte: offset + 1})
	}
	row.Pipes = pipes

	type gap struct{ start, end int }
	gaps := make([]gap, 0, len(pipeOffsets)+1)
	previous := start
	for index, offset := range pipeOffsets {
		if index == 0 && isTableBlank(source, start, offset) {
			// Optional leading pipe: no cell before it.
			previous = offset + 1
			continue
		}
		gaps = append(gaps, gap{start: previous, end: offset})
		previous = offset + 1
	}
	if len(pipeOffsets) == 0 || !isTableBlank(source, previous, rowEnd) {
		// No trailing pipe (or no pipes at all): the tail is a cell, even
		// when the row has uneven or missing delimiters.
		gaps = append(gaps, gap{start: previous, end: rowEnd})
	}
	cells := make([]document.TableCell, 0, len(gaps))
	for column, span := range gaps {
		cellStart, cellEnd := span.start, span.end
		for cellStart < cellEnd && isTableSpace(source[cellStart]) {
			cellStart++
		}
		for cellEnd > cellStart && isTableSpace(source[cellEnd-1]) {
			cellEnd--
		}
		cells = append(cells, document.TableCell{StartByte: cellStart, EndByte: cellEnd, Column: column})
	}
	row.Cells = cells
	return row
}

// tablePipeOffsets returns the byte offsets of structural pipes on one row
// line. GFM table parsing treats every unescaped `|` as a delimiter, even
// when the pipe occurs inside inline markup such as a code span.
func tablePipeOffsets(source []byte, start, end int) []int {
	var offsets []int
	for at := start; at < end; at++ {
		if source[at] == '|' && !isBackslashEscaped(source, start, at) {
			offsets = append(offsets, at)
		}
	}
	return offsets
}

// isBackslashEscaped reports whether the byte at offset is preceded by an odd
// run of backslashes. CommonMark uses parity here: two backslashes leave the
// following delimiter structural, while three escape it.
func isBackslashEscaped(source []byte, start, offset int) bool {
	count := 0
	for at := offset - 1; at >= start && source[at] == '\\'; at-- {
		count++
	}
	return count%2 == 1
}

// isTableBlank reports whether [start, end) holds only cell-padding
// whitespace. It uses the same ASCII whitespace set Goldmark trims from cell
// edges.
func isTableBlank(source []byte, start, end int) bool {
	for at := start; at < end; at++ {
		if !isTableSpace(source[at]) {
			return false
		}
	}
	return true
}

// isTableSpace matches Goldmark's cell-trim whitespace set
// (" \t\n\x0b\x0c\x0d"); the newline never occurs inside a row slice but is
// kept for parity.
func isTableSpace(c byte) bool {
	switch c {
	case ' ', '\t', '\n', '\v', '\f', '\r':
		return true
	default:
		return false
	}
}
