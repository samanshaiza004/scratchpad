package markdown

import (
	"strconv"
	"testing"

	"scratchpad/document"
)

func TestProjectBuildsSourcePresentationSpans(t *testing.T) {
	source := []byte("# Heading *em* **strong** `code` [link](target.md) ~~old~~\n\n> quote\n- [ ] task\n\n```go\nfmt.Println(\"日本語\")\n```\n")
	got := Project(source, 12)
	if got.Markdown.Revision != 12 || len(got.Markdown.Spans) == 0 {
		t.Fatalf("markdown presentation = %+v", got.Markdown)
	}
	for _, span := range got.Markdown.Spans {
		if span.StartByte < 0 || span.EndByte > len(source) || span.StartByte >= span.EndByte {
			t.Fatalf("invalid source span %+v for %q", span, source)
		}
	}
	for _, kind := range []document.PresentationKind{
		document.PresentationHeading,
		document.PresentationEmphasis,
		document.PresentationStrong,
		document.PresentationInlineCode,
		document.PresentationLink,
		document.PresentationStrike,
		document.PresentationBlockquote,
		document.PresentationListMarker,
		document.PresentationTaskMarker,
		document.PresentationCodeBlock,
	} {
		if !hasPresentationKind(got.Markdown.Spans, kind) {
			t.Errorf("missing presentation kind %v", kind)
		}
	}
	if got.Markdown.SpansIn(0, len(source)) == nil {
		t.Fatal("SpansIn returned no full-document spans")
	}
}

func TestProjectPresentationKeepsMarkdownSyntaxVisible(t *testing.T) {
	source := []byte("## **bold**\n")
	got := Project(source, 1)
	if !hasPresentationRange(got.Markdown.Spans, document.PresentationHeading, 5, 9) {
		t.Fatalf("heading content spans = %+v", got.Markdown.Spans)
	}
	if !hasPresentationRange(got.Markdown.Spans, document.PresentationSyntax, 0, 3) {
		t.Fatalf("heading marker spans = %+v", got.Markdown.Spans)
	}
}

func TestProjectPresentationUsesGoldmarkStrikethrough(t *testing.T) {
	got := Project([]byte("~~done~~\n"), 1)
	if !hasPresentationKind(got.Markdown.Spans, document.PresentationStrike) {
		t.Fatalf("spans = %+v", got.Markdown.Spans)
	}
}

func TestProjectPresentationMultilineInline(t *testing.T) {
	for _, tc := range []struct {
		name       string
		source     string
		kind       document.PresentationKind
		openEnd    int
		closeStart int
		closeEnd   int
	}{
		{name: "emphasis", source: "*hello\nworld*\n", kind: document.PresentationEmphasis, openEnd: 1, closeStart: 12, closeEnd: 13},
		{name: "strong", source: "**hello\nworld**\n", kind: document.PresentationStrong, openEnd: 2, closeStart: 13, closeEnd: 15},
		{name: "strikethrough", source: "~~hello\nworld~~\n", kind: document.PresentationStrike, openEnd: 2, closeStart: 13, closeEnd: 15},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := Project([]byte(tc.source), 1)
			if !hasPresentationKind(got.Markdown.Spans, tc.kind) {
				t.Fatalf("spans = %+v", got.Markdown.Spans)
			}
			if !hasPresentationRange(got.Markdown.Spans, document.PresentationSyntax, 0, tc.openEnd) {
				t.Errorf("opening delimiter spans = %+v", got.Markdown.Spans)
			}
			if !hasPresentationRange(got.Markdown.Spans, document.PresentationSyntax, tc.closeStart, tc.closeEnd) {
				t.Errorf("closing delimiter spans = %+v", got.Markdown.Spans)
			}
		})
	}
}

func BenchmarkProjectMarkdownPresentation(b *testing.B) {
	for _, size := range []int{1 << 20, 10 << 20} {
		b.Run(sizeName(size), func(b *testing.B) {
			source := markdownBenchmarkSource(size)
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				_ = Project(source, uint64(i+1))
			}
		})
	}
}

func markdownBenchmarkSource(size int) []byte {
	source := make([]byte, 0, size)
	for line := 0; len(source) < size; line++ {
		source = append(source, "text *em* **strong** `code` [link](target.md) ~~old~~ "...)
		source = strconv.AppendInt(source, int64(line), 10)
		source = append(source, '\n', '\n')
	}
	return source[:size]
}

func hasPresentationKind(spans []document.PresentationSpan, kind document.PresentationKind) bool {
	for _, span := range spans {
		if span.Kind == kind {
			return true
		}
	}
	return false
}

func hasPresentationRange(spans []document.PresentationSpan, kind document.PresentationKind, start, end int) bool {
	for _, span := range spans {
		if span.Kind == kind && span.StartByte == start && span.EndByte == end {
			return true
		}
	}
	return false
}

func sizeName(size int) string {
	if size >= 10<<20 {
		return "10MiB"
	}
	return "1MiB"
}
