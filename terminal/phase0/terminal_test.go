package phase0

import (
	"strings"
	"testing"
	"unicode/utf8"

	shirei "go.hasen.dev/shirei"
)

func TestCoreCannedVTFixtures(t *testing.T) {
	core, err := NewCore(80, 12, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer core.Close()

	core.WriteVT([]byte("MWil1_|[]{}()<>/@\r\n"))
	core.WriteVT([]byte("e\u0301 \u754c 🙂 👨‍👩‍👧‍👦\r\n"))
	core.WriteVT([]byte("\x1b[1;3;4;9;38;2;255;128;0mstyled\x1b[0m\r\n"))
	core.WriteVT([]byte("\x1b]2;phase0-title\x1b\\"))

	snapshot, err := core.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.Cols != 80 || snapshot.Rows != 12 {
		t.Fatalf("dimensions = %dx%d, want 80x12", snapshot.Cols, snapshot.Rows)
	}
	if !snapshot.ValidUTF8() {
		t.Fatal("terminal snapshot contains invalid UTF-8")
	}
	if snapshot.Title != "phase0-title" {
		t.Fatalf("title = %q, want phase0-title", snapshot.Title)
	}

	for column, want := range []string{"M", "W", "i", "l", "1", "_", "|", "[", "]", "{", "}"} {
		assertCellText(t, snapshot, 0, column, want)
	}
	assertCellText(t, snapshot, 1, 0, "e\u0301")
	assertCellText(t, snapshot, 1, 2, "界")
	if cell, ok := snapshot.CellAt(1, 2); !ok || cell.Wide != CellWideGlyph {
		t.Fatalf("CJK cell = %#v, want wide cell", cell)
	}
	if cell, ok := snapshot.CellAt(1, 3); !ok || cell.Wide != CellSpacerTail {
		t.Fatalf("CJK tail = %#v, want spacer tail", cell)
	}

	styled, ok := firstCellWithText(snapshot, 2, "s")
	if !ok {
		t.Fatal("styled fixture was not copied into the snapshot")
	}
	if !styled.Style.Bold || !styled.Style.Italic || !styled.Style.Underline || !styled.Style.Strikethrough {
		t.Fatalf("styled cell flags = %+v", styled.Style)
	}
	if styled.Style.Foreground != (RGB{255, 128, 0}) {
		t.Fatalf("styled foreground = %+v, want orange", styled.Style.Foreground)
	}
}

func TestCorePreservesTabsAndAlternateScreen(t *testing.T) {
	core, err := NewCore(20, 4, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer core.Close()

	core.WriteVT([]byte("\tX"))
	first, err := core.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	assertCellText(t, first, 0, 8, "X")

	core.WriteVT([]byte("\x1b[?1049halt-screen\x1b[?1049l"))
	second, err := core.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(second.PlainText(), "X") {
		t.Fatalf("primary screen lost after alternate-screen round trip: %q", second.PlainText())
	}
}

func TestTerminalFontFallbackFixtureShapesUnicode(t *testing.T) {
	if len(TerminalFontFamilies) < 2 || TerminalFontFamilies[0] != "CommitMono" || TerminalFontFamilies[1] != "OCR-B" {
		t.Fatalf("font preference chain = %v", TerminalFontFamilies)
	}

	fixture := "0Oo1lI|{}[]()<> <= >= => -> != == === \"'`_ - + * / \\ | @#$%^& café naïve 日本語 العربية עברית 🙂 e\u0301"
	shaped := shirei.ShapeText(fixture, TerminalTextStyle(14))
	if len(shaped.Lines) == 0 {
		t.Skip("Shirei has no usable system fonts in this environment")
	}
	glyphs := 0
	for _, line := range shaped.Lines {
		for _, segment := range line.Segments {
			glyphs += len(segment.Glyphs)
		}
	}
	if glyphs == 0 {
		t.Skip("Shirei has no usable system fonts in this environment")
	}
	if len(shaped.Runes) != utf8.RuneCountInString(fixture) {
		t.Fatalf("shaped rune count = %d, want %d", len(shaped.Runes), utf8.RuneCountInString(fixture))
	}
}

func assertCellText(t *testing.T, snapshot Snapshot, row, column int, want string) {
	t.Helper()
	cell, ok := snapshot.CellAt(row, column)
	if !ok {
		t.Fatalf("cell (%d,%d) is outside snapshot", row, column)
	}
	if cell.Text != want {
		t.Fatalf("cell (%d,%d) = %q, want %q", row, column, cell.Text, want)
	}
}

func firstCellWithText(snapshot Snapshot, row int, text string) (Cell, bool) {
	for column := 0; column < int(snapshot.Cols); column++ {
		cell, _ := snapshot.CellAt(row, column)
		if cell.Text == text {
			return cell, true
		}
	}
	return Cell{}, false
}
