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

func TestMarkdownPresentationBoundedQueryPrunesOldRangesAndReportsTruncation(t *testing.T) {
	spans := []PresentationSpan{{StartByte: 0, EndByte: 100000, Kind: PresentationCodeBlock}}
	for i := 0; i < 10000; i++ {
		start := 2 + i*2
		spans = append(spans, PresentationSpan{StartByte: start, EndByte: start + 1, Kind: PresentationEmphasis})
	}
	presentation := NewMarkdownPresentation(4, spans)
	got, truncated := presentation.SpansInLimit(19000, 19002, 1)
	if !truncated || len(got) != 1 || got[0].Kind != PresentationCodeBlock {
		t.Fatalf("bounded query = %+v, truncated=%v", got, truncated)
	}
	all, truncated := presentation.SpansInLimit(19000, 19002, 8)
	if truncated || len(all) != 2 || all[0].Kind != PresentationCodeBlock || all[1].Kind != PresentationEmphasis {
		t.Fatalf("complete query = %+v, truncated=%v", all, truncated)
	}
}

func TestBlockPresentationIndexHandlesNestedAndDenseRanges(t *testing.T) {
	projection := Projections{Blocks: []BlockPresentation{{Kind: BlockQuote, StartByte: 0, EndByte: 100000}}}
	for i := 0; i < 10000; i++ {
		start := 2 + i*2
		projection.Blocks = append(projection.Blocks, BlockPresentation{Kind: BlockList, StartByte: start, EndByte: start + 1})
	}
	projection.IndexBlocks()
	got, truncated := projection.BlocksIn(19000, 19002, 1)
	if !truncated || len(got) != 1 || got[0].Kind != BlockQuote {
		t.Fatalf("bounded block query = %+v, truncated=%v", got, truncated)
	}
	all, truncated := projection.BlocksIn(19000, 19002, 8)
	if truncated || len(all) != 2 || all[0].Kind != BlockQuote || all[1].Kind != BlockList {
		t.Fatalf("complete block query = %+v, truncated=%v", all, truncated)
	}

	// A literal projection without an index remains correct for compatibility.
	legacy := Projections{Blocks: []BlockPresentation{
		{Kind: BlockList, StartByte: 50, EndByte: 51},
		{Kind: BlockQuote, StartByte: 0, EndByte: 100},
	}}
	legacyBlocks, _ := legacy.BlocksIn(0, 2, 8)
	if len(legacyBlocks) != 1 || legacyBlocks[0].Kind != BlockQuote {
		t.Fatalf("unindexed legacy projection query = %+v", legacyBlocks)
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

func TestCodeProjectionHighlightsInLimitBoundsResultAndReportsTruncation(t *testing.T) {
	spans := make([]HighlightSpan, 10000)
	for i := range spans {
		spans[i] = HighlightSpan{StartByte: 10, EndByte: 20, Kind: HighlightKeyword}
	}
	projection := NewCodeProjection(3, "go", spans, nil, nil)
	got, truncated := projection.HighlightsInLimit(12, 18, 7)
	if !truncated || len(got) != 7 {
		t.Fatalf("bounded highlights = %d spans, truncated=%v; want 7 and true", len(got), truncated)
	}
	all, truncated := projection.HighlightsInLimit(12, 18, 10000)
	if truncated || len(all) != len(spans) {
		t.Fatalf("complete highlights = %d spans, truncated=%v; want %d and false", len(all), truncated, len(spans))
	}
	if got, truncated := projection.HighlightsInLimit(20, 30, 7); len(got) != 0 || truncated {
		t.Fatalf("disjoint bounded highlights = %d spans, truncated=%v; want empty and false", len(got), truncated)
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

func BenchmarkMarkdownPresentationLateViewportWithEnclosingSpan(b *testing.B) {
	spans := make([]PresentationSpan, 100001)
	spans[0] = PresentationSpan{StartByte: 0, EndByte: 200002, Kind: PresentationCodeBlock}
	for i := 0; i < 100000; i++ {
		start := 2 + i*2
		spans[i+1] = PresentationSpan{StartByte: start, EndByte: start + 1, Kind: PresentationEmphasis}
	}
	presentation := NewMarkdownPresentation(1, spans)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, _ = presentation.SpansInLimit(199900, 199940, 256)
	}
}
