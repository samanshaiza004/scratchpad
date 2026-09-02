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

func TestProjectEmitsDisposableBlockPresentation(t *testing.T) {
	source := []byte("> quote\n\n- item\n\n---\n\n| a | b |\n| - | - |\n| c | d |\n\n```go\nfmt.Println(1)\n```\n")
	got := Project(source, 8)
	seen := map[document.BlockKind]bool{}
	for _, block := range got.Blocks {
		if block.StartByte < 0 || block.EndByte > len(source) || block.StartByte >= block.EndByte {
			t.Fatalf("invalid block = %+v", block)
		}
		seen[block.Kind] = true
	}
	for _, kind := range []document.BlockKind{
		document.BlockQuote, document.BlockList, document.BlockThematicBreak,
		document.BlockTable, document.BlockCode,
	} {
		if !seen[kind] {
			t.Errorf("missing block kind %v in %+v", kind, got.Blocks)
		}
	}
}

func TestProjectKeepsTableSourceVisible(t *testing.T) {
	source := []byte("| name | value |\n| :--- | ---: |\n| one | two |\n")
	got := Project(source, 9)
	if !hasPresentationKind(got.Markdown.Spans, document.PresentationTable) {
		t.Fatalf("table presentation spans = %+v", got.Markdown.Spans)
	}
	if len(got.Blocks) != 1 || got.Blocks[0].Kind != document.BlockTable {
		t.Fatalf("table blocks = %+v", got.Blocks)
	}
	if string(source[got.Blocks[0].StartByte:got.Blocks[0].EndByte]) != string(source) {
		t.Fatalf("table block range = %+v, source=%q", got.Blocks[0], source)
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
