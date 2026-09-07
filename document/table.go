// Table projections are disposable, revision-tagged semantic views over GFM
// pipe tables. They carry source byte ranges only: no colors, fonts, display
// widths, parser nodes, or Shirei types.
//
// Contract notes for the future aligner (slice 4) and visuals (slice 3):
//   - All ranges are half-open source-byte offsets ([StartByte, EndByte)).
//     Multibyte runes (CJK, emoji) are stored as byte ranges; display width is
//     measured from source bytes at align time and is never baked into this
//     contract.
//   - TableProjection EndByte follows the BlockTable convention: it is one
//     past the terminating newline when the table's last row line ends with
//     '\n', so a table projection covers exactly the same bytes as its
//     BlockTable block. TableRow ranges exclude the terminating newline,
//     matching the Heading/Task line-range convention.
//   - TableCell ranges cover trimmed cell content (ASCII whitespace trimmed,
//     matching Goldmark's cell trimming). Inline markup bytes (**, backticks,
//     links) remain inside the cell range; the aligner measures visible
//     content from these bytes.
//   - TableRow.Cells preserves the source row as-is: short rows have fewer
//     cells and long rows have more cells than len(Columns). TableCell.Column
//     is the zero-based position in the row, never clamped or padded.
//   - TableRow.Pipes holds every structural pipe (leading, interior,
//     trailing) as one-byte ranges so the UI never re-parses table syntax.
//   - TableColumn.Alignment comes verbatim from the delimiter row's colons via
//     the parser (default/left/center/right). No numeric inference is ever
//     performed: Markdown colons are the source of truth.
package document

// TableAlignment is a parser-neutral column alignment. It records only what
// the delimiter row's colons declare.
type TableAlignment uint8

const (
	// TableAlignDefault is a plain `---` delimiter with no colons.
	TableAlignDefault TableAlignment = iota
	// TableAlignLeft is a `:--` delimiter.
	TableAlignLeft
	// TableAlignCenter is a `:-:` delimiter.
	TableAlignCenter
	// TableAlignRight is a `--:` delimiter.
	TableAlignRight
)

// String reports the alignment keyword used by the owning delimiter colons.
func (a TableAlignment) String() string {
	switch a {
	case TableAlignLeft:
		return "left"
	case TableAlignCenter:
		return "center"
	case TableAlignRight:
		return "right"
	default:
		return "default"
	}
}

// ByteRange is a half-open source-byte range [StartByte, EndByte).
type ByteRange struct {
	StartByte, EndByte int
}

// TableColumn describes one delimiter-declared column of a table.
type TableColumn struct {
	Alignment TableAlignment
}

// TableCell is one trimmed cell-content range within a source row. Column is
// the zero-based position of the cell in its row.
type TableCell struct {
	StartByte, EndByte int
	Column             int
}

// TableRow is one source line of a table: the header line, the delimiter
// line, or one data line. Exactly one of Header/Delimiter is true for the
// first two rows; both are false for data rows.
type TableRow struct {
	StartByte, EndByte int
	Header             bool
	Delimiter          bool
	Cells              []TableCell
	Pipes              []ByteRange
}

// TableProjection is the semantic row/cell/pipe view of one GFM pipe table.
// Like Blocks and Markdown, it is disposable: valid only for Revision and
// rebuilt from scratch after any edit.
type TableProjection struct {
	Revision           uint64
	StartByte, EndByte int
	Columns            []TableColumn
	Rows               []TableRow
}
