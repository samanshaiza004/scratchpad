package markdown

import (
	"bytes"
	"reflect"
	"testing"

	"github.com/yuin/goldmark/v2/ast"
	"github.com/yuin/goldmark/v2/extension"
	markdownast "github.com/yuin/goldmark/v2/extension/ast"
	"github.com/yuin/goldmark/v2/parser"
	"scratchpad/document"
)

func projectSingleTable(t *testing.T, source string, revision uint64) (document.Projections, document.TableProjection) {
	t.Helper()
	got := Project([]byte(source), revision)
	if len(got.Tables) != 1 {
		t.Fatalf("Tables count = %d, want 1: %+v", len(got.Tables), got.Tables)
	}
	return got, got.Tables[0]
}

func tableCellStrings(source []byte, row document.TableRow) []string {
	out := make([]string, 0, len(row.Cells))
	for _, cell := range row.Cells {
		out = append(out, string(source[cell.StartByte:cell.EndByte]))
	}
	return out
}

func assertTableRowSane(t *testing.T, source []byte, row document.TableRow) {
	t.Helper()
	if row.StartByte < 0 || row.EndByte > len(source) || row.StartByte > row.EndByte {
		t.Fatalf("row range [%d,%d) outside %q", row.StartByte, row.EndByte, source)
	}
	if bytes.IndexByte(source[row.StartByte:row.EndByte], '\n') >= 0 {
		t.Fatalf("row range [%d,%d) spans lines in %q", row.StartByte, row.EndByte, source)
	}
	previous := -1
	for _, pipe := range row.Pipes {
		if pipe.EndByte-pipe.StartByte != 1 || string(source[pipe.StartByte:pipe.EndByte]) != "|" {
			t.Fatalf("pipe %+v is not a single | in %q", pipe, source)
		}
		if pipe.StartByte < row.StartByte || pipe.EndByte > row.EndByte {
			t.Fatalf("pipe %+v outside row [%d,%d) in %q", pipe, row.StartByte, row.EndByte, source)
		}
		if pipe.StartByte <= previous {
			t.Fatalf("pipes not increasing: %+v", row.Pipes)
		}
		previous = pipe.StartByte
	}
	for _, cell := range row.Cells {
		if cell.StartByte < row.StartByte || cell.EndByte > row.EndByte || cell.StartByte > cell.EndByte {
			t.Fatalf("cell %+v outside row [%d,%d) in %q", cell, row.StartByte, row.EndByte, source)
		}
	}
	for i, cell := range row.Cells {
		if cell.Column != i {
			t.Fatalf("cell %d has Column=%d: %+v", i, cell.Column, row.Cells)
		}
	}
}

func assertTableSane(t *testing.T, source string, revision uint64, table document.TableProjection) {
	t.Helper()
	src := []byte(source)
	if table.Revision != revision {
		t.Fatalf("table revision = %d, want %d", table.Revision, revision)
	}
	if table.StartByte < 0 || table.EndByte > len(src) || table.StartByte >= table.EndByte {
		t.Fatalf("table range [%d,%d) invalid in %q", table.StartByte, table.EndByte, source)
	}
	if len(table.Rows) < 2 {
		t.Fatalf("table has %d rows, want header+delimiter at least: %+v", len(table.Rows), table.Rows)
	}
	if !table.Rows[0].Header || table.Rows[0].Delimiter {
		t.Fatalf("row 0 flags = header:%v delimiter:%v", table.Rows[0].Header, table.Rows[0].Delimiter)
	}
	if !table.Rows[1].Delimiter || table.Rows[1].Header {
		t.Fatalf("row 1 flags = header:%v delimiter:%v", table.Rows[1].Header, table.Rows[1].Delimiter)
	}
	for i := 2; i < len(table.Rows); i++ {
		if table.Rows[i].Header || table.Rows[i].Delimiter {
			t.Fatalf("data row %d flags = header:%v delimiter:%v", i, table.Rows[i].Header, table.Rows[i].Delimiter)
		}
	}
	for _, row := range table.Rows {
		assertTableRowSane(t, src, row)
	}
}

func TestProjectTablesPortfolioStyle(t *testing.T) {
	source := "| Project | Stack | Notes |\n| --- | :-: | --: |\n| `site` | **Go** | fast |\n"
	_, table := projectSingleTable(t, source, 21)
	assertTableSane(t, source, 21, table)

	wantAlign := []document.TableAlignment{document.TableAlignDefault, document.TableAlignCenter, document.TableAlignRight}
	if len(table.Columns) != 3 {
		t.Fatalf("columns = %+v", table.Columns)
	}
	for i, want := range wantAlign {
		if table.Columns[i].Alignment != want {
			t.Fatalf("column %d alignment = %v, want %v", i, table.Columns[i].Alignment, want)
		}
	}
	if len(table.Rows) != 3 {
		t.Fatalf("rows = %+v", table.Rows)
	}
	if got := tableCellStrings([]byte(source), table.Rows[0]); !reflect.DeepEqual(got, []string{"Project", "Stack", "Notes"}) {
		t.Fatalf("header cells = %q", got)
	}
	// Inline markup stays inside the cell byte ranges; the projection never
	// strips syntax.
	if got := tableCellStrings([]byte(source), table.Rows[2]); !reflect.DeepEqual(got, []string{"`site`", "**Go**", "fast"}) {
		t.Fatalf("data cells = %q", got)
	}
	for _, row := range table.Rows {
		if len(row.Pipes) != 4 {
			t.Fatalf("row [%d,%d) pipes = %+v, want 4", row.StartByte, row.EndByte, row.Pipes)
		}
	}
	if table.StartByte != 0 || table.EndByte != len(source) {
		t.Fatalf("table range = [%d,%d), want [0,%d)", table.StartByte, table.EndByte, len(source))
	}
}

func TestProjectTablesEscapedPipes(t *testing.T) {
	source := "| a | b |\n| - | - |\n| c \\| d | e |\n"
	_, table := projectSingleTable(t, source, 22)
	assertTableSane(t, source, 22, table)

	row := table.Rows[2]
	if got := tableCellStrings([]byte(source), row); !reflect.DeepEqual(got, []string{`c \| d`, "e"}) {
		t.Fatalf("escaped-pipe cells = %q", got)
	}
	if len(row.Pipes) != 3 {
		t.Fatalf("pipes = %+v, want 3 (escaped pipe is not structural)", row.Pipes)
	}
	escaped := bytes.Index([]byte(source), []byte(`\|`))
	for _, pipe := range row.Pipes {
		if pipe.StartByte == escaped+1 {
			t.Fatalf("escaped pipe at %d treated as structural: %+v", escaped+1, row.Pipes)
		}
	}
}

func TestProjectTablesCodeSpanPipesSplitUnlessEscaped(t *testing.T) {
	tests := []struct {
		name string
		row  string
		want []string
	}{
		{name: "unescaped", row: "| c `x|y` |\n", want: []string{"c `x", "y`"}},
		{name: "escaped", row: "| c `x\\|y` d | e |\n", want: []string{"c `x\\|y` d", "e"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			source := "| a | b |\n| - | - |\n" + tt.row
			_, table := projectSingleTable(t, source, 23)
			assertTableSane(t, source, 23, table)

			row := table.Rows[2]
			projectionCells := tableCellStrings([]byte(source), row)
			goldmarkCells := goldmarkTableCellStrings([]byte(source), row.StartByte)
			if !reflect.DeepEqual(goldmarkCells, tt.want) {
				t.Fatalf("Goldmark cells = %q, want %q", goldmarkCells, tt.want)
			}
			if !reflect.DeepEqual(projectionCells, goldmarkCells) {
				t.Fatalf("projection cells = %q, Goldmark cells = %q", projectionCells, goldmarkCells)
			}
		})
	}
}

func goldmarkTableCellStrings(source []byte, rowStart int) []string {
	root := parser.New(parser.WithExtensions(extension.NewTableParser())).Parse(source)
	var cells []string
	_ = ast.Walk(root, func(node ast.Node, entering bool) (ast.WalkStatus, error) {
		if !entering {
			return ast.WalkContinue, nil
		}
		row, ok := node.(*markdownast.TableRow)
		if !ok || row.Pos() != rowStart {
			return ast.WalkContinue, nil
		}
		for child := row.FirstChild(); child != nil; child = child.NextSibling() {
			cell, ok := child.(*markdownast.TableCell)
			if !ok {
				continue
			}
			var start, end int
			for _, segment := range cell.Source() {
				if start == 0 || segment.Start < start {
					start = segment.Start
				}
				if segment.Stop > end {
					end = segment.Stop
				}
			}
			cells = append(cells, string(source[start:end]))
		}
		return ast.WalkSkipChildren, nil
	})
	return cells
}

func TestProjectTablesMissingTrailingPipe(t *testing.T) {
	source := "| a | b |\n| - | - |\n| c | d\n"
	_, table := projectSingleTable(t, source, 24)
	assertTableSane(t, source, 24, table)

	row := table.Rows[2]
	if got := tableCellStrings([]byte(source), row); !reflect.DeepEqual(got, []string{"c", "d"}) {
		t.Fatalf("cells without trailing pipe = %q", got)
	}
	if len(row.Pipes) != 2 {
		t.Fatalf("pipes = %+v, want leading+interior only", row.Pipes)
	}
	if string([]byte(source)[row.StartByte:row.EndByte]) != "| c | d" {
		t.Fatalf("row bytes = %q", source[row.StartByte:row.EndByte])
	}
	if table.EndByte != len(source) {
		t.Fatalf("table EndByte = %d, want %d (cover trailing newline)", table.EndByte, len(source))
	}
}

func TestProjectTablesOptionalEdgePipes(t *testing.T) {
	source := "a | b\n-- | --\n1 | 2\n"
	_, table := projectSingleTable(t, source, 25)
	assertTableSane(t, source, 25, table)

	if got := tableCellStrings([]byte(source), table.Rows[0]); !reflect.DeepEqual(got, []string{"a", "b"}) {
		t.Fatalf("header cells without edge pipes = %q", got)
	}
	if got := tableCellStrings([]byte(source), table.Rows[2]); !reflect.DeepEqual(got, []string{"1", "2"}) {
		t.Fatalf("data cells without edge pipes = %q", got)
	}
	for _, row := range table.Rows {
		if len(row.Pipes) != 1 {
			t.Fatalf("row %q pipes = %+v, want 1 interior pipe", source[row.StartByte:row.EndByte], row.Pipes)
		}
	}
}

func TestProjectTablesCJKEmojiByteRanges(t *testing.T) {
	source := "| \u65e5\u672c\u8a9e | \U0001F389 |\n| --- | --- |\n| \u30c6\u30b9\u30c8 | \u2705x |\n"
	src := []byte(source)
	_, table := projectSingleTable(t, source, 26)
	assertTableSane(t, source, 26, table)

	header := table.Rows[0]
	if got := tableCellStrings(src, header); !reflect.DeepEqual(got, []string{"\u65e5\u672c\u8a9e", "\U0001F389"}) {
		t.Fatalf("CJK/emoji header cells = %q", got)
	}
	// Byte ranges must span the full multibyte sequences: widths are left for
	// the future aligner to measure from these bytes.
	cjk := header.Cells[0]
	if cjk.EndByte-cjk.StartByte != len("\u65e5\u672c\u8a9e") || string(src[cjk.StartByte:cjk.EndByte]) != "\u65e5\u672c\u8a9e" {
		t.Fatalf("CJK cell range [%d,%d) = %q", cjk.StartByte, cjk.EndByte, src[cjk.StartByte:cjk.EndByte])
	}
	emoji := header.Cells[1]
	if emoji.EndByte-emoji.StartByte != len("\U0001F389") || string(src[emoji.StartByte:emoji.EndByte]) != "\U0001F389" {
		t.Fatalf("emoji cell range [%d,%d) = %q", emoji.StartByte, emoji.EndByte, src[emoji.StartByte:emoji.EndByte])
	}
	if got := tableCellStrings(src, table.Rows[2]); !reflect.DeepEqual(got, []string{"\u30c6\u30b9\u30c8", "\u2705x"}) {
		t.Fatalf("CJK/emoji data cells = %q", got)
	}
}

func TestProjectTablesUnevenColumnsPreserved(t *testing.T) {
	source := "| a | b |\n| - | - |\n| x | y | z |\n| only |\n"
	_, table := projectSingleTable(t, source, 27)
	assertTableSane(t, source, 27, table)

	if len(table.Columns) != 2 {
		t.Fatalf("columns = %+v, want 2 from delimiter", table.Columns)
	}
	long := table.Rows[2]
	if got := tableCellStrings([]byte(source), long); !reflect.DeepEqual(got, []string{"x", "y", "z"}) {
		t.Fatalf("long row cells = %q, want preserved as-is", got)
	}
	if len(long.Cells) != 3 || long.Cells[2].Column != 2 {
		t.Fatalf("long row columns = %+v, want 0,1,2 by position", long.Cells)
	}
	short := table.Rows[3]
	if got := tableCellStrings([]byte(source), short); !reflect.DeepEqual(got, []string{"only"}) {
		t.Fatalf("short row cells = %q, want no padding", got)
	}
	if len(short.Cells) != 1 || short.Cells[0].Column != 0 {
		t.Fatalf("short row cells = %+v", short.Cells)
	}
}

func TestProjectTablesAlignmentColons(t *testing.T) {
	source := "| a | b | c | d |\n| :-- | :-: | --: | --- |\n| 1 | 2 | 3 | 4 |\n"
	_, table := projectSingleTable(t, source, 28)
	assertTableSane(t, source, 28, table)

	want := []document.TableAlignment{
		document.TableAlignLeft, document.TableAlignCenter,
		document.TableAlignRight, document.TableAlignDefault,
	}
	if len(table.Columns) != len(want) {
		t.Fatalf("columns = %+v", table.Columns)
	}
	for i, want := range want {
		if table.Columns[i].Alignment != want {
			t.Fatalf("column %d = %v, want %v", i, table.Columns[i].Alignment, want)
		}
	}
	if got := tableCellStrings([]byte(source), table.Rows[2]); !reflect.DeepEqual(got, []string{"1", "2", "3", "4"}) {
		t.Fatalf("data cells = %q", got)
	}
}

func TestProjectTablesCRLFRangesExcludeCarriageReturn(t *testing.T) {
	source := "| a | b |\r\n| --- | --- |\r\n| c | d |\r\n"
	_, table := projectSingleTable(t, source, 29)
	assertTableSane(t, source, 29, table)
	for i, row := range table.Rows {
		if row.EndByte > row.StartByte && source[row.EndByte-1] == '\r' {
			t.Fatalf("row %d includes CR in range [%d,%d)", i, row.StartByte, row.EndByte)
		}
		if got := source[row.StartByte:row.EndByte]; bytes.Contains([]byte(got), []byte("\r")) {
			t.Fatalf("row %d contains CR: %q", i, got)
		}
	}
	if table.EndByte != len(source) {
		t.Fatalf("table EndByte = %d, want %d", table.EndByte, len(source))
	}
}

func TestTablePipeEscapeParity(t *testing.T) {
	source := []byte(`| x \\| y | z |`)
	if got := tablePipeOffsets(source, 0, len(source)); !reflect.DeepEqual(got, []int{0, 6, 10, 14}) {
		t.Fatalf("two-backslash pipes = %v, want the even-backslash pipe structural", got)
	}
	source = []byte(`| x \\\| y | z |`)
	if got := tablePipeOffsets(source, 0, len(source)); !reflect.DeepEqual(got, []int{0, 11, 15}) {
		t.Fatalf("three-backslash pipes = %v, want escaped pipe omitted", got)
	}
}

func TestProjectTablesMatchBlockRangeAndRevision(t *testing.T) {
	source := "| name | value |\n| :--- | ---: |\n| one | two |\n"
	got, table := projectSingleTable(t, source, 9)
	assertTableSane(t, source, 9, table)

	if len(got.Blocks) != 1 || got.Blocks[0].Kind != document.BlockTable {
		t.Fatalf("blocks = %+v", got.Blocks)
	}
	if table.StartByte != got.Blocks[0].StartByte || table.EndByte != got.Blocks[0].EndByte {
		t.Fatalf("table range [%d,%d) != block range [%d,%d)",
			table.StartByte, table.EndByte, got.Blocks[0].StartByte, got.Blocks[0].EndByte)
	}
	if !hasPresentationKind(got.Markdown.Spans, document.PresentationTable) {
		t.Fatalf("missing PresentationTable span: %+v", got.Markdown.Spans)
	}
	if table.Columns[0].Alignment != document.TableAlignLeft || table.Columns[1].Alignment != document.TableAlignRight {
		t.Fatalf("columns = %+v", table.Columns)
	}
}

func TestProjectTablesEmptyAndMultiple(t *testing.T) {
	got := Project([]byte("# hi\n\nplain text\n"), 30)
	if len(got.Tables) != 0 {
		t.Fatalf("Tables = %+v, want none", got.Tables)
	}
	source := "| a |\n| - |\n| 1 |\n\ntext\n\n| b | c |\n| - | - |\n| 2 | 3 |\n"
	got = Project([]byte(source), 31)
	if len(got.Tables) != 2 {
		t.Fatalf("Tables count = %d, want 2: %+v", len(got.Tables), got.Tables)
	}
	for _, table := range got.Tables {
		assertTableSane(t, source, 31, table)
	}
	if got.Tables[1].StartByte <= got.Tables[0].EndByte {
		t.Fatalf("tables overlap: %+v", got.Tables)
	}
	if got.Tables[0].Rows[2].Cells[0].Column != 0 || got.Tables[1].Rows[2].Cells[1].Column != 1 {
		t.Fatalf("column mapping wrong: %+v %+v", got.Tables[0].Rows[2], got.Tables[1].Rows[2])
	}
}
