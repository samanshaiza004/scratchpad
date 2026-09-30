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
test_soft_wrap_policy_keeps_code_tables_and_code_languages_unwrapped :: proc(t: ^testing.T) {
	source := [?]u8{'a', ' ', 'b', ' ', 'c'}
	line, line_ok := editor_project_line(source[:], 10, 0, context.temp_allocator)
	testing.expect(t, line_ok, "source projection should succeed for wrap policy")
	if !line_ok { return }
	defer delete(line.display, context.temp_allocator)
	defer delete(line.display_bytes, context.temp_allocator)
	prose := Editor_Window{editor_revision=4, start_byte=10, presentation_revision=4, presentation_ready=true}
	testing.expect(t, editor_line_should_wrap("markdown", &prose, &line), "ordinary Markdown prose should wrap")
	testing.expect(t, !editor_line_should_wrap("odin", &prose, &line), "source-code language rows should stay horizontally scrollable")
	code_spans := [?]bridge.Presentation_Record{{kind=EDITOR_PRESENTATION_CODE_BLOCK, start_byte=0, end_byte=5}}
	prose.presentation_spans = code_spans[:]
	testing.expect(t, !editor_line_should_wrap("markdown", &prose, &line), "fenced code rows should stay horizontally scrollable")
	table_spans := [?]bridge.Presentation_Record{{kind=EDITOR_PRESENTATION_TABLE, start_byte=0, end_byte=5}}
	prose.presentation_spans = table_spans[:]
	testing.expect(t, !editor_line_should_wrap("markdown", &prose, &line), "Markdown table rows should stay horizontally scrollable")
	prose.presentation_spans = nil
	table_blocks := [?]bridge.Presentation_Record{{kind=EDITOR_PRESENTATION_BLOCK_TABLE, start_byte=0, end_byte=5}}
	prose.presentation_blocks = table_blocks[:]
	testing.expect(t, !editor_line_should_wrap("markdown", &prose, &line), "table block metadata also keeps table rows unwrapped")
}

@(test)
test_soft_wrap_shapes_styled_source_before_wrapping :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 420, 220})
	defer alicorn.destroy_runtime(&rt)
	if !alicorn.text_engine_load_font_role(&rt.text_engine, .Monospace, ALICORN_TEST_MONO_FONT_DATA) {
		testing.expect(t, false, "soft-wrap regression should load the bundled monospace face")
		return
	}
	source := "This **source text** should wrap after its Markdown typography has been applied."
	source_bytes, source_error := make([]u8, len(source), context.temp_allocator)
	if source_error != nil { testing.expect(t, false, "could not allocate styled wrap source bytes"); return }
	defer delete(source_bytes, context.temp_allocator)
	for index in 0..<len(source) { source_bytes[index] = source[index] }
	line, line_ok := editor_project_line(source_bytes, 0, 0, context.temp_allocator)
	testing.expect(t, line_ok, "source projection should succeed before shaping")
	if !line_ok { return }
	defer delete(line.display, context.temp_allocator)
	defer delete(line.display_bytes, context.temp_allocator)
	strong_start := 7
	spans := [?]bridge.Presentation_Record{{kind=3, start_byte=u32(strong_start), end_byte=u32(strong_start+len("source text"))}}
	window := Editor_Window{
		document_id="wrap-style-test", editor_revision=9, start_byte=0, source=source_bytes,
		presentation_revision=9, presentation_ready=true, presentation_spans=spans[:],
	}
	styles := editor_presentation_text_styles_for_line(&window, &line, context.temp_allocator)
	defer delete(styles, context.temp_allocator)
	run, run_ok := editor_temporary_text_run(&rt, &line, 96, .Wrap, styles)
	testing.expect(t, run_ok, "Runa should shape the styled text under a constrained width")
	if !run_ok { return }
	defer alicorn.text_run_destroy(&run)
	testing.expect(t, len(run.lines) > 1, "the constrained styled text should produce multiple visual rows")
	testing.expect(t, run.value == line.display, "wrapping and typography must not rewrite source-derived display bytes")
	if len(run.lines) > 1 {
		first_end := run.lines[0].byte_end
		second_start := run.lines[1].byte_start
		testing.expect(t, second_start >= first_end, "visual rows should preserve monotonic display-byte ranges")
		mapped := editor_display_to_source(&line, second_start)
		testing.expect(t, mapped >= line.source_start && mapped <= line.source_end,
			"visual-row boundaries should map back to legal source-byte coordinates")
	}
	long_word := "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz"
	word_bytes, word_error := make([]u8, len(long_word), context.temp_allocator)
	if word_error != nil { testing.expect(t, false, "could not allocate long-word wrap fixture"); return }
	defer delete(word_bytes, context.temp_allocator)
	for index in 0..<len(long_word) { word_bytes[index] = long_word[index] }
	word_line, word_line_ok := editor_project_line(word_bytes, 0, 0, context.temp_allocator)
	testing.expect(t, word_line_ok, "source projection should accept a long unbroken word")
	if !word_line_ok { return }
	defer delete(word_line.display, context.temp_allocator)
	defer delete(word_line.display_bytes, context.temp_allocator)
	word_run, word_run_ok := editor_temporary_text_run(&rt, &word_line, 48, .Wrap)
	testing.expect(t, word_run_ok, "Runa should shape an unbroken word under a constrained width")
	if !word_run_ok { return }
	defer alicorn.text_run_destroy(&word_run)
	testing.expect(t, len(word_run.lines) > 1, "a pathological long prose word should fall back to grapheme-safe visual rows")
	previous_end := 0
	for visual_line in word_run.lines {
		testing.expect(t, visual_line.byte_start >= previous_end && visual_line.byte_end >= visual_line.byte_start,
			"long-word visual rows should retain monotonic, non-overlapping display-byte ranges")
		previous_end = visual_line.byte_end
	}
}

@(test)
test_wrap_height_edits_shift_unaffected_logical_lines :: proc(t: ^testing.T) {
	source := [?]u8{'o','n','e','\n','t','w','o','\n','t','h','r','e','e','\n','f','o','u','r'}
	visible := bridge.Visible_Window{
		document_id="height-edit-test", editor_revision=2, start_line=0, end_line=4,
		start_byte=0, source=source[:],
	}
	window, window_ok, message := editor_window_from_visible(&visible, context.temp_allocator)
	testing.expect(t, window_ok, message)
	if !window_ok { return }
	defer editor_window_destroy(&window, context.temp_allocator)
	view: Editor_View_State
	view.wrap_height_index_ready = alicorn.virtual_list_height_index_init(&view.wrap_height_index, 4, EDITOR_ROW_HEIGHT, context.allocator)
	if !view.wrap_height_index_ready { testing.expect(t, false, "sparse wrap-height cache should initialize"); return }
	defer alicorn.virtual_list_height_index_destroy(&view.wrap_height_index)
	_ = alicorn.virtual_list_height_index_set_height(&view.wrap_height_index, 3, 66)
	editor_wrap_heights_apply_edit(&view, &window, 4, 8, {}, 1)
	testing.expect(t, view.wrap_height_index.item_count == 3, "joining two logical lines should update cached collection size")
	testing.expect(t, alicorn.virtual_list_height_index_item_height(&view.wrap_height_index, 2) == 66,
		"the measured unaffected suffix should shift to its new source-line identity")
	testing.expect(t, alicorn.virtual_list_height_index_item_height(&view.wrap_height_index, 1) == EDITOR_ROW_HEIGHT,
		"measurements belonging to replaced logical lines should be discarded")
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
