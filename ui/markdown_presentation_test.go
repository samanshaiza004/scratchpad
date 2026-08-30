package ui

import (
	"testing"

	"scratchpad/document"

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
	}
	for _, test := range tests {
		style := TextStyleWith(base, MarkdownPresentationStyle(test.kind, base)...)
		if !test.check(style) {
			t.Errorf("%s style = %+v", test.label, style)
		}
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
