package ui

import (
	"testing"

	"scratchpad/document"
	"scratchpad/editor"

	. "go.hasen.dev/shirei"
)

const proseGeometryOracleWidth float32 = 96

func requireProseGeometryFonts(t *testing.T, sample string, style TextStyleAttrs) {
	t.Helper()
	InitFontSubsystem()
	if shaped := ShapeText(sample, style); len(shaped.Lines) == 0 || len(shaped.Lines[0].Segments) == 0 {
		t.Skip("Shirei has no usable font for geometry oracle")
	}
}

func assertNearGeometry(t *testing.T, got, want, tolerance float32, label string) {
	t.Helper()
	if got < want-tolerance || got > want+tolerance {
		t.Fatalf("%s = %.3f, want %.3f ± %.3f", label, got, want, tolerance)
	}
}

func measuredProseText(width float32, text string, style TextStyleAttrs, spans ...TextSpan) Vec2 {
	return Measure(Vec2{width, 1000}, func() {
		Container(Attrs(FixWidth(width)), func() {
			Text(text, style, spans...)
		})
	})
}

func TestVisualLineHeightMatchesPublicShireiMeasure(t *testing.T) {
	style := DefaultTextStyle()
	text := "A comfortable paragraph wraps across several rows so its block padding and line metrics are exercised."
	requireProseGeometryFonts(t, text, style)

	b := editor.NewBuffer([]byte(text))
	visual, ok := BuildVisualLineMax(&b, 0, 0, style, proseGeometryOracleWidth)
	if !ok || len(visual.Layout.Lines) < 2 {
		t.Skip("fixture did not soft-wrap with the available font")
	}

	want := measuredProseText(proseGeometryOracleWidth, text, style)
	assertNearGeometry(t, visual.Height(20), want[1], 0.05, "VisualLine.Height")
}

func TestMarkdownSpanHeightMatchesPublicShireiMeasure(t *testing.T) {
	style := DefaultTextStyle()
	text := "Heading words are larger, while the rest of this paragraph keeps the normal editor size and wraps."
	span := document.PresentationSpan{StartByte: 0, EndByte: len("Heading words"), Kind: document.PresentationHeading, Level: 1}
	requireProseGeometryFonts(t, text, style)

	b := editor.NewBuffer([]byte(text))
	visual, ok := buildVisualLineAroundMaxStyled(&b, 0, 0, style, proseGeometryOracleWidth,
		func(start, end int) []document.PresentationSpan { return []document.PresentationSpan{span} },
		MarkdownPresentationStyle, MarkdownPresentationSpanStyle)
	if !ok || len(visual.Layout.Lines) < 2 {
		t.Skip("fixture did not soft-wrap with the available font")
	}

	spanMods := MarkdownPresentationSpanStyle(span, style)
	want := measuredProseText(proseGeometryOracleWidth, text, style, Span(0, len([]rune("Heading words")), spanMods...))
	assertNearGeometry(t, visual.Height(20), want[1], 0.05, "spanned VisualLine.Height")
}

func TestVisualLineCaretRowsMatchRenderedGlyphOrigins(t *testing.T) {
	style := DefaultTextStyle()
	text := "first wrapped row has enough words to continue onto another rendered row"
	requireProseGeometryFonts(t, text, style)

	b := editor.NewBuffer([]byte(text))
	visual, ok := BuildVisualLineMax(&b, 0, 0, style, proseGeometryOracleWidth)
	if !ok || len(visual.Layout.Lines) < 2 {
		t.Skip("fixture did not soft-wrap with the available font")
	}

	out := RunFrameFn(func() {
		ContainerWithKey("prose-geometry-oracle", Attrs(FixWidth(proseGeometryOracleWidth)), func() {
			Text(text, style)
		})
	})
	glyphs := make([]Surface, 0, len(out.Surfaces))
	for _, surface := range out.Surfaces {
		if surface.FontId != 0 && surface.GlyphId != 0 {
			glyphs = append(glyphs, surface)
		}
	}
	if len(glyphs) == 0 {
		t.Skip("Shirei produced no glyph surfaces")
	}

	// The public frame surfaces expose each glyph's resolved origin. Compare
	// the first glyph in every shaped row with VisualLine's caret row origin.
	glyphAt := 0
	for lineIndex, line := range visual.Layout.Lines {
		start, end := visual.shapedLineRange(lineIndex)
		if end <= start || len(line.Segments) == 0 {
			continue
		}
		if glyphAt >= len(glyphs) {
			t.Fatalf("rendered glyphs ended before shaped row %d", lineIndex)
		}
		glyph := glyphs[glyphAt]
		lineGlyphCount := 0
		for _, segment := range line.Segments {
			lineGlyphCount += len(segment.Glyphs)
		}
		glyphAt += lineGlyphCount
		_, caretY, _ := visual.CaretPosition(start, editor.AffinityLeading)
		assertNearGeometry(t, glyph.Rect.Origin[1], caretY, 0.05, "first glyph row origin")
		wantX, _, _ := visual.CaretPosition(start, editor.AffinityLeading)
		assertNearGeometry(t, glyph.Rect.Origin[0], wantX, 0.05, "first glyph x origin")
	}
	if glyphAt == 0 {
		t.Fatal("no non-empty shaped rows were checked")
	}
}

func TestBlankVisualLineUsesConfiguredFallbackWhenShireiHasNoTextBounds(t *testing.T) {
	style := DefaultTextStyle()
	requireProseGeometryFonts(t, "x", style)
	b := editor.NewBuffer([]byte("\nfilled"))
	visual, ok := BuildVisualLineMax(&b, 0, 0, style, proseGeometryOracleWidth)
	if !ok {
		t.Fatal("BuildVisualLineMax failed for blank line")
	}
	if len(visual.Layout.Lines) != 0 {
		t.Fatalf("blank line shaped into %d rows, want no text rows", len(visual.Layout.Lines))
	}
	const fallback float32 = 24
	if got := visual.Height(fallback); got != fallback {
		t.Fatalf("blank VisualLine.Height = %.3f, want configured fallback %.3f", got, fallback)
	}
	if measured := measuredProseText(proseGeometryOracleWidth, "", style); measured[1] != 0 {
		t.Fatalf("public empty Text measure height = %.3f, want zero before editor fallback", measured[1])
	}
}

func TestWrappedBoundaryKeepsTrailingCaretOnPreviousRow(t *testing.T) {
	style := DefaultTextStyle()
	text := "A sentence with enough words to span several visual rows."
	requireProseGeometryFonts(t, text, style)
	buffer := editor.NewBuffer([]byte(text))
	visual, ok := BuildVisualLineMax(&buffer, 0, 0, style, proseGeometryOracleWidth)
	if !ok || len(visual.Layout.Lines) < 2 {
		t.Fatal("fixture did not wrap")
	}
	_, end := visual.shapedLineRange(0)
	if row := visual.lineAtRune(end, editor.AffinityTrailing); row != 0 {
		t.Fatalf("end-of-row caret moved to row %d", row)
	}
	_, firstY, _ := visual.CaretPosition(end, editor.AffinityTrailing)
	_, nextY, _ := visual.CaretPosition(end, editor.AffinityLeading)
	if nextY <= firstY {
		t.Fatalf("wrap affinities collapsed to same row: trailing=%v leading=%v", firstY, nextY)
	}
}
