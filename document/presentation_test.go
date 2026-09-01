package document

import "testing"

func TestMarkdownPresentationSpansInIncludesNestedRanges(t *testing.T) {
	presentation := NewMarkdownPresentation(9, []PresentationSpan{
		{StartByte: 2, EndByte: 8, Kind: PresentationStrong},
		{StartByte: 4, EndByte: 6, Kind: PresentationEmphasis},
		{StartByte: 10, EndByte: 12, Kind: PresentationSyntax},
	})
	got := presentation.SpansIn(5, 11)
	if len(got) != 3 {
		t.Fatalf("SpansIn = %+v, want all intersecting spans", got)
	}
	if presentation.Revision != 9 || presentation.Spans[0].StartByte != 2 {
		t.Fatalf("presentation = %+v", presentation)
	}
}

func TestMarkdownPresentationSpansInDoesNotReturnDisjointRanges(t *testing.T) {
	presentation := NewMarkdownPresentation(1, []PresentationSpan{
		{StartByte: 0, EndByte: 2, Kind: PresentationSyntax},
		{StartByte: 8, EndByte: 10, Kind: PresentationSyntax},
	})
	if got := presentation.SpansIn(3, 8); got != nil {
		t.Fatalf("SpansIn = %+v, want nil", got)
	}
}

func TestDisplayCodeRebasesOnlySafeHighlightSpans(t *testing.T) {
	doc := New("main.go", []byte("package main\nfunc main() {}\n"), "go")
	doc.SetDerived(nil, Projections{
		Revision: doc.Revision(),
		Code: NewCodeProjection(doc.Revision(), "go", []HighlightSpan{
			{StartByte: 0, EndByte: 7, Kind: HighlightKeyword},
			{StartByte: 13, EndByte: 17, Kind: HighlightKeyword},
		}, nil, nil),
	})

	doc.Editor.SetCursor(0)
	if err := doc.Insert([]byte("// comment\n")); err != nil {
		t.Fatal(err)
	}
	display, ok := doc.DisplayCodeProjection()
	if !ok || display.Revision != doc.Revision() {
		t.Fatalf("display projection = %+v, ok=%v", display, ok)
	}
	if len(display.Highlights) != 2 || display.Highlights[0].StartByte != 11 || display.Highlights[1].StartByte != 24 {
		t.Fatalf("rebased highlights = %+v", display.Highlights)
	}

	if err := doc.Replace(24, 25, []byte("X")); err != nil {
		t.Fatal(err)
	}
	display, ok = doc.DisplayCodeProjection()
	if !ok || len(display.Highlights) != 1 || display.Highlights[0].StartByte != 11 {
		t.Fatalf("intersecting highlight was not dropped: %+v, ok=%v", display.Highlights, ok)
	}
}

func BenchmarkMarkdownPresentationSpansIn(b *testing.B) {
	for _, test := range []struct {
		name  string
		count int
	}{
		{"1k", 1000}, {"10k", 10000},
	} {
		test := test
		b.Run(test.name, func(b *testing.B) {
			count := test.count
			spans := make([]PresentationSpan, count)
			for i := range spans {
				spans[i] = PresentationSpan{StartByte: i * 4, EndByte: i*4 + 3, Kind: PresentationEmphasis}
			}
			presentation := NewMarkdownPresentation(1, spans)
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				_ = presentation.SpansIn((i%count)*4, (i%count)*4+3)
			}
		})
	}
}
