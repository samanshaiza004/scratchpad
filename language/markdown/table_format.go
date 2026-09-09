package markdown

import (
	"bytes"
	"strings"

	"github.com/rivo/uniseg"
	"github.com/yuin/goldmark/v2/ast"
	"github.com/yuin/goldmark/v2/extension"
	"github.com/yuin/goldmark/v2/parser"
	"scratchpad/document"
)

// FormatTable returns one explicitly aligned source replacement for table.
// The caller owns the undoable edit; this function only formats the table
// bytes described by the parser-owned projection. Inline Markdown remains
// source text, while padding is added outside each cell's content.
func FormatTable(source []byte, table document.TableProjection) ([]byte, bool) {
	if table.StartByte < 0 || table.EndByte <= table.StartByte || table.EndByte > len(source) || len(table.Rows) < 2 {
		return nil, false
	}
	columnCount := len(table.Columns)
	for _, row := range table.Rows {
		// GFM derives the table schema from the header and delimiter rows.
		// An overlong body row contains cells that the parser intentionally
		// ignores; refusing to rewrite it avoids making those cells meaningful
		// (or silently dropping them) during formatting or cell navigation.
		if !row.Header && !row.Delimiter && len(row.Cells) > columnCount {
			return nil, false
		}
	}
	if columnCount == 0 {
		return nil, false
	}

	widths := make([]int, columnCount)
	for _, row := range table.Rows {
		for column, cell := range row.Cells {
			if column >= columnCount {
				break
			}
			raw := source[cell.StartByte:cell.EndByte]
			cellWidth := tableCellDisplayWidth(raw)
			if row.Delimiter {
				cellWidth = maxTableInt(cellWidth, delimiterWidth(tableColumnAlignment(table, column)))
			}
			if cellWidth > widths[column] {
				widths[column] = cellWidth
			}
		}
	}
	for column := range widths {
		if widths[column] == 0 {
			widths[column] = delimiterWidth(tableColumnAlignment(table, column))
		}
	}

	crlf := bytes.Contains(source[table.StartByte:table.EndByte], []byte("\r\n"))
	newline := "\n"
	if crlf {
		newline = "\r\n"
	}
	formatted := make([]string, 0, len(table.Rows))
	for _, row := range table.Rows {
		cells := make([]string, columnCount)
		for column := range cells {
			if column < len(row.Cells) {
				cell := row.Cells[column]
				raw := source[cell.StartByte:cell.EndByte]
				if row.Delimiter {
					cells[column] = formatDelimiter(tableColumnAlignment(table, column), widths[column])
				} else {
					cells[column] = formatTableCell(raw, widths[column], tableColumnAlignment(table, column))
				}
			} else if row.Delimiter {
				cells[column] = formatDelimiter(tableColumnAlignment(table, column), widths[column])
			} else {
				cells[column] = strings.Repeat(" ", widths[column])
			}
		}
		var line strings.Builder
		line.WriteByte('|')
		for _, cell := range cells {
			line.WriteByte(' ')
			line.WriteString(cell)
			line.WriteString(" |")
		}
		formatted = append(formatted, line.String())
	}
	result := []byte(strings.Join(formatted, newline))
	if table.EndByte > table.Rows[len(table.Rows)-1].EndByte {
		result = append(result, newline...)
	}
	return result, true
}

func tableColumnAlignment(table document.TableProjection, column int) document.TableAlignment {
	if column >= 0 && column < len(table.Columns) {
		return table.Columns[column].Alignment
	}
	return document.TableAlignDefault
}

func formatTableCell(raw []byte, targetWidth int, alignment document.TableAlignment) string {
	text := string(raw)
	padding := targetWidth - tableCellDisplayWidth(raw)
	if padding < 0 {
		padding = 0
	}
	switch alignment {
	case document.TableAlignRight:
		return strings.Repeat(" ", padding) + text
	case document.TableAlignCenter:
		left := padding / 2
		return strings.Repeat(" ", left) + text + strings.Repeat(" ", padding-left)
	default:
		return text + strings.Repeat(" ", padding)
	}
}

func formatDelimiter(alignment document.TableAlignment, targetWidth int) string {
	left, right := false, false
	switch alignment {
	case document.TableAlignLeft:
		left = true
	case document.TableAlignCenter:
		left, right = true, true
	case document.TableAlignRight:
		right = true
	}
	dashes := targetWidth
	if left {
		dashes--
	}
	if right {
		dashes--
	}
	if dashes < 3 {
		dashes = 3
	}
	var result strings.Builder
	if left {
		result.WriteByte(':')
	}
	result.WriteString(strings.Repeat("-", dashes))
	if right {
		result.WriteByte(':')
	}
	return result.String()
}

func delimiterWidth(alignment document.TableAlignment) int {
	width := 3
	if alignment == document.TableAlignLeft || alignment == document.TableAlignRight {
		width = 4
	} else if alignment == document.TableAlignCenter {
		width = 5
	}
	return width
}

// tableCellDisplayWidth measures the rendered inline content rather than its
// source syntax. Goldmark supplies the visible text, then uniseg applies UAX
// #29 grapheme segmentation and its wcwidth-like monospace policy. This keeps
// table padding correct for combining marks, variation selectors, modifiers,
// joined emoji, flags, and wide CJK characters without another local Unicode
// approximation.
func tableCellDisplayWidth(raw []byte) int {
	visible := tableCellDisplayText(raw)
	return uniseg.StringWidth(visible)
}

func tableCellDisplayText(raw []byte) string {
	root := parser.New(parser.WithExtensions(extension.NewStrikethroughParser())).Parse(raw)
	var parts []string
	_ = ast.Walk(root, func(node ast.Node, entering bool) (ast.WalkStatus, error) {
		if !entering {
			return ast.WalkContinue, nil
		}
		switch node := node.(type) {
		case *ast.Text:
			parts = append(parts, node.Value.Value(raw))
		case *ast.CodeSpan:
			parts = append(parts, node.Value.Value(raw))
		case *ast.AutoLink:
			parts = append(parts, node.Label.Value(raw))
		}
		return ast.WalkContinue, nil
	})
	return displayInvalid([]byte(strings.Join(parts, "")))
}

func maxTableInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}
