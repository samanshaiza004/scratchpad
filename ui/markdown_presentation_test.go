package ui

import (
	"bytes"
	"strings"
	"testing"

	"scratchpad/document"
	"scratchpad/editor"
	"scratchpad/language/markdown"

	. "go.hasen.dev/shirei"
)

func TestMarkdownPresentationStyleMapsSemanticKinds(t *testing.T) {
	base := DefaultTextStyle()
	tests := []struct {
		kind  document.PresentationKind
		check func(TextStyleAttrs) bool
		label string
	}{
		{document.PresentationHeading, func(style TextStyleAttrs) bool { return style.Weight == WeightBold }, "heading"},
		{document.PresentationStrong, func(style TextStyleAttrs) bool { return style.Weight == WeightBold }, "strong"},
		{document.PresentationEmphasis, func(style TextStyleAttrs) bool { return style.Style == StyleItalic }, "emphasis"},
		{document.PresentationInlineCode, func(style TextStyleAttrs) bool { return len(style.FontFamilies) > 0 && style.Background != (Vec4{}) }, "inline code"},
		{document.PresentationLink, func(style TextStyleAttrs) bool { return style.Underline }, "link"},
		{document.PresentationStrike, func(style TextStyleAttrs) bool { return style.Strike }, "strike"},
		{document.PresentationCodeBlock, func(style TextStyleAttrs) bool { return len(style.FontFamilies) > 0 && style.Background != (Vec4{}) }, "code block"},
		{document.PresentationTableHeader, func(style TextStyleAttrs) bool { return style.Weight == WeightBold }, "table header"},
		{document.PresentationTableDelimiter, func(style TextStyleAttrs) bool { return style.TextColor == DefaultTheme().Muted }, "table delimiter"},
		{document.PresentationTablePipe, func(style TextStyleAttrs) bool { return style.TextColor == DefaultTheme().Border }, "table pipe"},
	}
	for _, test := range tests {
		style := TextStyleWith(base, MarkdownPresentationStyle(test.kind, base)...)
		if !test.check(style) {
			t.Errorf("%s style = %+v", test.label, style)
		}
	}
}

func TestMarkdownTablePresentationUsesCodeFace(t *testing.T) {
	base := DefaultTextStyle()
	mods := MarkdownPresentationStyle(document.PresentationTable, base)
	if mods == nil {
		t.Fatal("PresentationTable style is nil, want a visible monospace style")
	}
	styled := TextStyleWith(base, mods...)
	want := codeFontFamilies()
	if len(styled.FontFamilies) != len(want) {
		t.Fatalf("table font families = %v, want %v", styled.FontFamilies, want)
	}
	for i := range want {
		if styled.FontFamilies[i] != want[i] {
			t.Fatalf("table font families = %v, want %v", styled.FontFamilies, want)
		}
	}
	if styled.TextColor != base.TextColor {
		t.Fatalf("table text color = %v, want base %v (row background stays with the BlockTable decoration)", styled.TextColor, base.TextColor)
	}
}

func TestMarkdownTableLineDecorationStylesRows(t *testing.T) {
	source := []byte("| name | value |\n| :--- | ---: |\n| one | two |\n")
	doc := document.New("notes.md", source, "markdown")
	if !doc.SetDerived(nil, markdown.Project(source, doc.Revision())) {
		t.Fatal("SetDerived rejected current table projection")
	}
	decorate := markdownLineDecoration(doc, DefaultTheme())
	header := decorate(0)
	delimiter := decorate(1)
	body := decorate(2)
	if header.Background == (Vec4{}) || delimiter.Background == (Vec4{}) || body.Background == (Vec4{}) {
		t.Fatalf("table row backgrounds = header:%v delimiter:%v body:%v", header.Background, delimiter.Background, body.Background)
	}
	if header.Background == body.Background || delimiter.Background == body.Background {
		t.Fatalf("table row backgrounds are not differentiated: header:%v delimiter:%v body:%v", header.Background, delimiter.Background, body.Background)
	}
	if header.Accent != (Vec4{}) || body.Accent != (Vec4{}) || delimiter.Accent == (Vec4{}) {
		t.Fatalf("table row accents = header:%v delimiter:%v body:%v", header.Accent, delimiter.Accent, body.Accent)
	}
}

func TestFormatTableAtCursorIsOneUndoableEdit(t *testing.T) {
	source := []byte("| Name | Notes |\n| :-- | --: |\n| **Go** | `日本語` |\n")
	doc := document.New("notes.md", source, "markdown")
	if !doc.SetDerived(nil, markdown.Project(source, doc.Revision())) {
		t.Fatal("SetDerived rejected current table projection")
	}
	doc.Editor.SetCursor(len("| Name | Notes |\n| :-- | --: |\n| "))
	if !formatTableAtCursor(doc) {
		t.Fatal("formatTableAtCursor returned false")
	}
	formatted := string(doc.Editor.Buffer.Text())
	if formatted == string(source) || !strings.Contains(formatted, "| :--- | -----: |") {
		t.Fatalf("formatted source = %q", formatted)
	}
	if doc.DerivedCurrent() {
		t.Fatal("format edit left stale projections current")
	}
	if err := doc.Editor.Undo(); err != nil {
		t.Fatalf("undo = %v", err)
	}
	if got := string(doc.Editor.Buffer.Text()); got != string(source) {
		t.Fatalf("undo source = %q, want %q", got, source)
	}
}

func TestTableNavigationFormatsAndMovesAcrossCells(t *testing.T) {
	source := []byte("Intro\n\n| a | b |\n| --- | --- |\n| one | two |\n")
	doc := document.New("notes.md", source, "markdown")
	if !doc.SetDerived(nil, markdown.Project(source, doc.Revision())) {
		t.Fatal("SetDerived rejected current table projection")
	}
	doc.Editor.SetCursor(len("Intro\n\n| a | b |\n| --- | --- |\n| "))
	if !navigateTableAtCursor(doc, false, false) {
		t.Fatal("Tab navigation returned false")
	}
	formatted := doc.Editor.Buffer.Text()
	projection := markdown.Project(formatted, doc.Revision())
	if len(projection.Tables) != 1 {
		t.Fatalf("formatted tables = %+v", projection.Tables)
	}
	body := projection.Tables[0].Rows[2]
	if doc.Editor.Cursor < body.Cells[1].StartByte || doc.Editor.Cursor > body.Cells[1].EndByte {
		t.Fatalf("Tab cursor = %d, want second body cell [%d,%d]", doc.Editor.Cursor, body.Cells[1].StartByte, body.Cells[1].EndByte)
	}

	doc.SetDerived(nil, projection)
	doc.Editor.SetCursor(body.Cells[1].StartByte)
	if !navigateTableAtCursor(doc, false, true) {
		t.Fatal("Enter navigation returned false")
	}
	withRow := doc.Editor.Buffer.Text()
	if !strings.Contains(string(withRow), "|   |   |\n") {
		t.Fatalf("created row missing from %q", withRow)
	}
	if err := doc.Editor.Undo(); err != nil {
		t.Fatalf("undo = %v", err)
	}
	if got := string(doc.Editor.Buffer.Text()); got != string(formatted) {
		t.Fatalf("undo navigation source = %q, want %q", got, formatted)
	}
}

func TestToggleTaskAtCursorMatchesOutlineSemantics(t *testing.T) {
	source := []byte("- [ ] first\n- [x] second\n- [X] third\nplain\n")
	doc := document.New("notes.md", source, "markdown")
	if !doc.SetDerived(nil, markdown.Project(source, doc.Revision())) {
		t.Fatal("SetDerived rejected current task projection")
	}
	doc.Editor.SetCursor(bytes.Index(source, []byte("first")))
	if !toggleTaskAtCursor(doc) || !strings.HasPrefix(string(doc.Editor.Buffer.Text()), "- [x] first") {
		t.Fatalf("unchecked task was not checked: %q", doc.Editor.Buffer.Text())
	}
	if !doc.SetDerived(nil, markdown.Project(doc.Editor.Buffer.Text(), doc.Revision())) {
		t.Fatal("SetDerived rejected checked task projection")
	}
	doc.Editor.SetCursor(bytes.Index(doc.Editor.Buffer.Text(), []byte("first")))
	if !toggleTaskAtCursor(doc) || !strings.HasPrefix(string(doc.Editor.Buffer.Text()), "- [ ] first") {
		t.Fatalf("checked task was not unchecked: %q", doc.Editor.Buffer.Text())
	}
	if !doc.SetDerived(nil, markdown.Project(doc.Editor.Buffer.Text(), doc.Revision())) {
		t.Fatal("SetDerived rejected unchecked task projection")
	}
	doc.Editor.SetCursor(bytes.Index(doc.Editor.Buffer.Text(), []byte("third")))
	if !toggleTaskAtCursor(doc) || !strings.Contains(string(doc.Editor.Buffer.Text()), "- [ ] third") {
		t.Fatalf("uppercase checked task was not unchecked: %q", doc.Editor.Buffer.Text())
	}
}

func TestMarkdownThematicBreakPresentationIsMuted(t *testing.T) {
	base := DefaultTextStyle()
	mods := MarkdownPresentationStyle(document.PresentationThematicBreak, base)
	if mods == nil {
		t.Fatal("PresentationThematicBreak style is nil, want a muted style")
	}
	styled := TextStyleWith(base, mods...)
	if styled.TextColor != DefaultTheme().Muted {
		t.Fatalf("thematic break color = %v, want muted %v", styled.TextColor, DefaultTheme().Muted)
	}
}

func TestSyntaxPresentationStyleUsesVisibleHSLAColors(t *testing.T) {
	base := DefaultTextStyle()
	for _, kind := range []document.PresentationKind{
		document.PresentationCodeComment,
		document.PresentationCodeKeyword,
		document.PresentationCodeString,
		document.PresentationCodeNumber,
		document.PresentationCodeType,
		document.PresentationCodeFunction,
	} {
		style := TextStyleWith(base, MarkdownPresentationStyle(kind, base)...)
		color := style.TextColor
		if color[0] <= 1 || color[1] <= 1 || color[2] <= 1 || color[3] != 1 {
			t.Errorf("%v color = %v, want visible HSLA values", kind, color)
		}
	}
}

func TestCodeSyntaxPresentationDoesNotChangeFontMetrics(t *testing.T) {
	base := DefaultTextStyle()
	for _, kind := range []document.PresentationKind{
		document.PresentationCodeComment,
		document.PresentationCodeKeyword,
		document.PresentationCodeString,
		document.PresentationCodeNumber,
		document.PresentationCodeType,
		document.PresentationCodeFunction,
	} {
		style := TextStyleWith(base, MarkdownPresentationStyle(kind, base)...)
		if style.FontAspect != base.FontAspect || style.FontSize != base.FontSize ||
			len(style.FontFamilies) != len(base.FontFamilies) {
			t.Errorf("%v changed font metrics: base=%+v styled=%+v", kind, base, style)
		}
	}
}

func TestMarkdownHeadingSpanStyleAddsHierarchy(t *testing.T) {
	base := DefaultTextStyle()
	h1 := TextStyleWith(base, MarkdownPresentationSpanStyle(document.PresentationSpan{
		Kind: document.PresentationHeading, Level: 1,
	}, base)...)
	h3 := TextStyleWith(base, MarkdownPresentationSpanStyle(document.PresentationSpan{
		Kind: document.PresentationHeading, Level: 3,
	}, base)...)
	if h1.FontSize <= h3.FontSize || h3.FontSize <= base.FontSize {
		t.Fatalf("heading sizes = h1=%v h3=%v base=%v", h1.FontSize, h3.FontSize, base.FontSize)
	}
	if h1.Weight != WeightBold || h3.Weight != WeightBold {
		t.Fatalf("heading weights = h1=%v h3=%v", h1.Weight, h3.Weight)
	}
}

func TestVisualLineCarriesResolvedPresentationStylesToLayout(t *testing.T) {
	buffer := editor.NewBuffer([]byte("func main() {}"))
	visual, ok := buildVisualLineAround(&buffer, 0, 0, DefaultTextStyle(), func(start, end int) []document.PresentationSpan {
		return []document.PresentationSpan{{StartByte: 0, EndByte: 4, Kind: document.PresentationCodeKeyword}}
	}, MarkdownPresentationStyle)
	if !ok || len(visual.layoutSpans) != 1 {
		t.Fatalf("visual=%+v, layout spans=%+v", visual, visual.layoutSpans)
	}
	if visual.layoutSpans[0].From != 0 || visual.layoutSpans[0].To != 4 {
		t.Fatalf("layout span range=%+v", visual.layoutSpans[0])
	}
	if visual.layoutSpans[0].Style.TextColor != DefaultSyntaxTheme().Keyword {
		t.Fatalf("layout span color=%v, want=%v", visual.layoutSpans[0].Style.TextColor, DefaultSyntaxTheme().Keyword)
	}
}

func TestPresentationTextSpansClipToVisibleSourceWindow(t *testing.T) {
	visual := VisualLine{
		DocStart:    100,
		DocEnd:      110,
		Runes:       []rune("abcdefghij"),
		sourceBytes: []int{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10},
	}
	spans := presentationTextSpans(visual, []document.PresentationSpan{
		{StartByte: 90, EndByte: 104, Kind: document.PresentationStrong},
		{StartByte: 106, EndByte: 120, Kind: document.PresentationEmphasis},
	}, DefaultTextStyle(), MarkdownPresentationStyle)
	if len(spans) != 2 || spans[0].From != 0 || spans[0].To != 4 || spans[1].From != 6 || spans[1].To != 10 {
		t.Fatalf("local spans = %+v", spans)
	}
}

func TestPresentationTextSpansIgnoreEmptyStyles(t *testing.T) {
	visual := VisualLine{DocStart: 0, DocEnd: 3, Runes: []rune("abc"), sourceBytes: []int{0, 1, 2, 3}}
	spans := presentationTextSpans(visual, []document.PresentationSpan{{StartByte: 0, EndByte: 3, Kind: document.PresentationKind(255)}}, DefaultTextStyle(), MarkdownPresentationStyle)
	if spans != nil {
		t.Fatalf("spans = %+v, want nil", spans)
	}
}
