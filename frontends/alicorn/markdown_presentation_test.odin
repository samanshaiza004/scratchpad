package main

import "core:testing"
import alicorn "alicorn:runtime"
import bridge "./bridge"

@(test)
test_markdown_display_mapping_covers_bom_tabs_and_invalid_bytes :: proc(t: ^testing.T) {
	source := [?]u8{0xEF, 0xBB, 0xBF, '#', '\t', 'X', 0xFF}
	line, ok := editor_project_line(source[:], 0, 0, context.temp_allocator)
	testing.expect(t, ok, "Markdown source display projection should accept BOM, tab, and malformed UTF-8 bytes")
	if !ok { return }
	defer delete(line.display, context.temp_allocator)
	defer delete(line.display_bytes, context.temp_allocator)
	testing.expect(t, line.display == "#   X\\xFF", "BOM should stay hidden while tabs and malformed bytes remain visible")
	start, end, tab_ok := editor_source_range_to_display(&line, 4, 5)
	testing.expect(t, tab_ok && start == 1 && end == 4, "a tab source span must cover every expanded display space")
	invalid_start, invalid_end, invalid_ok := editor_source_range_to_display(&line, 6, 7)
	testing.expect(t, invalid_ok && invalid_start == 5 && invalid_end == 9, "an invalid source byte span must cover its full visible escape spelling")
	_, _, bom_visible := editor_source_range_to_display(&line, 0, 3)
	testing.expect(t, !bom_visible, "a span containing only the hidden BOM must not invent visible glyphs")

	for display_position in 0..<len(line.display_bytes) {
		mapped := editor_display_to_source(&line, display_position)
		if mapped < line.source_start || mapped > line.source_end {
			testing.expect(t, false, "display caret mapping must remain within the source line")
			break
		}
	}
}

@(test)
test_markdown_typography_maps_semantics_without_changing_display_bytes :: proc(t: ^testing.T) {
	source := [?]u8{'#', ' ', 'H', ' ', '*', '*', 'B', '*', '*', ' ', '*', 'I', '*'}
	line, line_ok := editor_project_line(source[:], 0, 0, context.temp_allocator)
	testing.expect(t, line_ok, "source projection should succeed for typography mapping")
	if !line_ok { return }
	defer delete(line.display, context.temp_allocator)
	defer delete(line.display_bytes, context.temp_allocator)
	spans := [?]bridge.Presentation_Record{
		{kind=2, start_byte=2, end_byte=3, level_flags=1},
		{kind=3, start_byte=6, end_byte=7},
		{kind=4, start_byte=11, end_byte=12},
	}
	window := Editor_Window{
		document_id="typography-test",
		editor_revision=5,
		start_byte=0,
		source=source[:],
		presentation_revision=5,
		presentation_ready=true,
		presentation_spans=spans[:],
	}
	styles := editor_presentation_text_styles_for_line(&window, &line, context.temp_allocator)
	defer delete(styles, context.temp_allocator)
	testing.expect(t, len(styles) == 3, "heading, strong, and emphasis should each produce a typography span")
	if len(styles) == 3 {
		testing.expect(t, styles[0].start == 2 && styles[0].end == 3 && styles[0].font_weight_set && styles[0].font_weight == alicorn.FONT_WEIGHT_SEMIBOLD,
			"level-one heading should use semibold at the mapped source range")
		testing.expect(t, styles[1].start == 6 && styles[1].end == 7 && styles[1].font_weight_set && styles[1].font_weight == alicorn.FONT_WEIGHT_BOLD,
			"strong content should map to bold")
		testing.expect(t, styles[2].start == 11 && styles[2].end == 12 && styles[2].italic_set && styles[2].italic,
			"emphasis content should map to italic")
	}
	testing.expect(t, line.display == "# H **B** *I*", "typography metadata must not alter source-derived display bytes")
}

@(test)
test_markdown_heading_levels_use_modest_weights_without_size_metadata :: proc(t: ^testing.T) {
	source := [?]u8{'1', '2', '3'}
	line, line_ok := editor_project_line(source[:], 0, 0, context.temp_allocator)
	testing.expect(t, line_ok, "source projection should succeed for heading hierarchy")
	if !line_ok { return }
	defer delete(line.display, context.temp_allocator)
	defer delete(line.display_bytes, context.temp_allocator)
	spans := [?]bridge.Presentation_Record{
		{kind=2, start_byte=0, end_byte=1, level_flags=1},
		{kind=2, start_byte=1, end_byte=2, level_flags=2},
		{kind=2, start_byte=2, end_byte=3, level_flags=3},
	}
	window := Editor_Window{
		document_id="heading-levels-test",
		editor_revision=6,
		start_byte=0,
		source=source[:],
		presentation_revision=6,
		presentation_ready=true,
		presentation_spans=spans[:],
	}
	styles := editor_presentation_text_styles_for_line(&window, &line, context.temp_allocator)
	defer delete(styles, context.temp_allocator)
	testing.expect(t, len(styles) == 3, "three heading levels should produce three mapped style spans")
	if len(styles) == 3 {
		testing.expect(t, styles[0].font_weight == 600 && styles[1].font_weight == 500 && styles[2].font_weight == 450,
			"heading weights should step modestly from H1 to H3")
		for style in styles {
			testing.expect(t, !style.italic_set, "heading styles should not set italic or font-size metadata")
		}
	}
	testing.expect(t, line.display == "123", "heading typography must not alter source-derived display bytes")
}

@(test)
test_markdown_display_lines_keep_crlf_source_offsets :: proc(t: ^testing.T) {
	source, source_error := make([]u8, 6, context.temp_allocator)
	if source_error != nil { testing.expect(t, false, "could not allocate CRLF source fixture"); return }
	source[0], source[1], source[2], source[3], source[4], source[5] = 'a', '\r', '\n', 'b', '\r', '\n'
	visible := bridge.Visible_Window{
		document_id="doc-crlf",
		editor_revision=4,
		start_line=8,
		end_line=10,
		start_byte=100,
		source=source,
	}
	window, ok, message := editor_window_from_visible(&visible, context.temp_allocator)
	testing.expect(t, ok, message)
	if !ok { delete(source, context.temp_allocator); return }
	defer editor_window_destroy(&window, context.temp_allocator)
	first, first_ok := editor_window_line(&window, 8)
	second, second_ok := editor_window_line(&window, 9)
	testing.expect(t, first_ok && second_ok, "CRLF source should project as two logical lines")
	if first_ok && second_ok {
		testing.expect(t, first.source_start == 100 && first.source_end == 101 &&
			second.source_start == 103 && second.source_end == 104,
			"line display spans should preserve CRLF gaps in absolute source byte coordinates")
		testing.expect(t, editor_display_to_source(second, 1) == 104,
			"caret mapping on the second CRLF line should retain its absolute source offset")
	}
}

@(test)
test_markdown_paint_spans_use_projected_bytes_without_metric_styles :: proc(t: ^testing.T) {
	source := [?]u8{'#', '\t', 'X'}
	line, line_ok := editor_project_line(source[:], 50, 0, context.temp_allocator)
	testing.expect(t, line_ok, "source projection should succeed for paint-span mapping")
	if !line_ok { return }
	defer delete(line.display, context.temp_allocator)
	defer delete(line.display_bytes, context.temp_allocator)
	spans := [?]bridge.Presentation_Record{
		{kind=2, start_byte=0, end_byte=1, level_flags=1},
		{kind=5, start_byte=2, end_byte=3},
	}
	blocks := [?]bridge.Presentation_Record{{kind=0x10001, start_byte=0, end_byte=3}}
	window := Editor_Window{
		document_id="paint-test",
		editor_revision=4,
		start_byte=50,
		source=source[:],
		presentation_revision=4,
		presentation_ready=true,
		presentation_spans=spans[:],
		presentation_blocks=blocks[:],
	}
	paints := editor_presentation_spans_for_line(&window, &line, context.temp_allocator)
	defer delete(paints, context.temp_allocator)
	testing.expect(t, len(paints) == 3, "code-block surface plus heading and inline-code spans should produce paint-only modifiers")
	if len(paints) == 3 {
		testing.expect(t, paints[0].start == 0 && paints[0].end == len(line.display) && paints[0].background_set,
			"block styling should cover its displayed row range")
		testing.expect(t, paints[1].start == 0 && paints[1].end == 1 && paints[1].color_set,
			"heading paint should map its source marker without changing the display text")
		testing.expect(t, paints[2].start == 4 && paints[2].end == 5 && paints[2].background_set,
			"inline-code paint should map after the expanded tab using display byte coordinates")
	}
	testing.expect(t, line.display == "#   X", "styling metadata must not alter source-derived display bytes")
}
