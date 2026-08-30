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
