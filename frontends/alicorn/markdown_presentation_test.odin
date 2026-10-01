package main

import "core:fmt"
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

test_table_window :: proc(source: string) -> (window: Editor_Window, ok: bool) {
	bytes, allocation_error := make([]u8, len(source), context.temp_allocator)
	if allocation_error != nil { return }
	for index in 0..<len(source) { bytes[index] = source[index] }
	window = Editor_Window{
		editor_revision=11,
		start_line=0,
		start_byte=0,
		source=bytes,
		presentation_revision=11,
		presentation_ready=true,
		lines=make([dynamic]Editor_Display_Line, 0, allocator=context.temp_allocator),
	}
	spans := make([dynamic]bridge.Presentation_Record, 0, allocator=context.temp_allocator)
	blocks := make([dynamic]bridge.Presentation_Record, 0, allocator=context.temp_allocator)
	line_start := 0
	logical_line: u64 = 0
	for index in 0..<len(bytes) {
		if bytes[index] != '\n' { continue }
		line_end := index
		if line_end > line_start && bytes[line_end-1] == '\r' { line_end -= 1 }
		line, line_ok := editor_project_line(bytes[line_start:line_end], u64(line_start), logical_line, context.temp_allocator)
		if !line_ok { editor_window_destroy(&window, context.temp_allocator); return {}, false }
		append(&window.lines, line)
		logical_line += 1
		line_start = index+1
	}
	if line_start < len(bytes) {
		line_end := len(bytes)
		if line_end > line_start && bytes[line_end-1] == '\r' { line_end -= 1 }
		line, line_ok := editor_project_line(bytes[line_start:line_end], u64(line_start), logical_line, context.temp_allocator)
		if !line_ok { editor_window_destroy(&window, context.temp_allocator); return {}, false }
		append(&window.lines, line)
		logical_line += 1
	}
	window.end_line = logical_line
	for index in 0..<len(bytes) {
		if bytes[index] == '|' {
			append(&spans, bridge.Presentation_Record{
				kind=EDITOR_PRESENTATION_TABLE_PIPE,
				start_byte=u32(index),
				end_byte=u32(index+1),
			})
		}
	}
	if len(window.lines) > 1 {
		delimiter := &window.lines[1]
		append(&spans, bridge.Presentation_Record{
			kind=EDITOR_PRESENTATION_TABLE_DELIMITER,
			start_byte=u32(delimiter.source_start),
			end_byte=u32(delimiter.source_end),
		})
	}
	append(&blocks, bridge.Presentation_Record{
		kind=EDITOR_PRESENTATION_BLOCK_TABLE,
		start_byte=0,
		end_byte=u32(len(bytes)),
		level_flags=2,
	})
	window.presentation_spans = spans[:]
	window.presentation_blocks = blocks[:]
	return window, true
}

@(test)
test_table_block_layout_shares_wrap_mode_and_columns_across_rows :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 480, 300})
	defer alicorn.destroy_runtime(&rt)
	if !alicorn.text_engine_load_font_role(&rt.text_engine, .Monospace, ALICORN_TEST_MONO_FONT_DATA) {
		testing.expect(t, false, "table wrap regression should load the bundled monospace face")
		return
	}
	long_summary := "A long description that should wrap within the shared summary column while the page column stays aligned across every table row."
	long_dashes := "----------------------------------------------------------------------------------------------------"
	source := fmt.tprintf("| Page | Summary |\n| %s | %s |\n| [[overview]] | %s |\n", long_dashes, long_dashes, long_summary)
	window, window_ok := test_table_window(source)
	testing.expect(t, window_ok, "test table source should project into logical editor lines")
	if !window_ok { return }
	defer editor_window_destroy(&window, context.temp_allocator)
	header, header_ok := editor_window_line(&window, 0)
	delimiter, delimiter_ok := editor_window_line(&window, 1)
	body, body_ok := editor_window_line(&window, 2)
	if !header_ok || !delimiter_ok || !body_ok {
		testing.expect(t, false, "all table rows should be present in the bounded window")
		return
	}
	available_width := f32(480)
	header_layout := editor_table_row_layout(&window, header, available_width, context.temp_allocator)
	delimiter_layout := editor_table_row_layout(&window, delimiter, available_width, context.temp_allocator)
	body_layout := editor_table_row_layout(&window, body, available_width, context.temp_allocator)
	testing.expect(t, header_layout.wraps && delimiter_layout.wraps && body_layout.wraps,
		"every row in a fitting table must use the shared cell-wrap mode")
	if len(header_layout.widths) < 2 || len(delimiter_layout.widths) < 2 || len(body_layout.widths) < 2 ||
	   len(header_layout.cells) < 2 || len(body_layout.cells) < 2 {
		testing.expect(t, false, "a fitting two-column table should expose two shared cells and widths")
		return
	}
	testing.expect(t, header_layout.delimiter == false && delimiter_layout.delimiter && !body_layout.delimiter,
		"only the parser-marked delimiter row should use structural delimiter treatment")
	for column in 0..<2 {
		testing.expect(t,
			header_layout.widths[column] == delimiter_layout.widths[column] &&
				header_layout.widths[column] == body_layout.widths[column],
			"all rows in one table must share an identical column-width vector")
	}
	testing.expect(t, header_layout.cells[0].display == "Page" && header_layout.cells[1].display == "Summary",
		"cell shaping should use trimmed semantic content instead of alignment padding")
	testing.expect(t, body_layout.cells[0].display == "[[overview]]" && body_layout.cells[1].display == long_summary,
		"wrapped body cells should preserve exact source content without source padding")
	testing.expect(t, body_layout.cells[0].source_start > body.source_start && body_layout.cells[1].source_end < body.source_end,
		"semantic cell byte ranges should exclude whitespace padding around source cells")
	testing.expect(t, editor_table_cell_for_x(body_layout, body_layout.origins[1]+1) == 1,
		"hit-testing within the shared second-column geometry should identify that semantic cell")
	break_source := editor_display_to_source(&body_layout.cells[1], 4)
	testing.expect(t, break_source >= body_layout.cells[1].source_start && break_source <= body_layout.cells[1].source_end,
		"cell display hit-testing must map back into the trimmed source range")
	_, _, delimiter_rows, delimiter_height_ok := editor_measure_line_height(&rt, &window, delimiter, available_width, true, true)
	_, _, body_rows, body_height_ok := editor_measure_line_height(&rt, &window, body, available_width, true, true)
	testing.expect(t, delimiter_height_ok && delimiter_rows == 1,
		"long delimiter dashes must use shared table geometry without creating extra wrapped rows")
	testing.expect(t, body_height_ok && body_rows > 1,
		"long semantic cell content should wrap into multiple visual rows")
	index: alicorn.Virtual_List_Height_Index
	if !alicorn.virtual_list_height_index_init(&index, len(window.lines), EDITOR_ROW_HEIGHT, context.allocator) {
		testing.expect(t, false, "table wrap test should initialize a variable-height index")
		return
	}
	defer alicorn.virtual_list_height_index_destroy(&index)
	content_width := editor_visible_window_content_width(&window, &index, 0, 250, 48, "markdown", true, available_width)
	testing.expect(t, content_width == 0,
		"a cell-wrapped table must not establish horizontal overflow extent")
	narrow_body_layout := editor_table_row_layout(&window, body, 300, context.temp_allocator)
	narrow_height, _, narrow_rows, narrow_height_ok := editor_measure_line_height(&rt, &window, body, 300, true, true)
	_ = narrow_height
	testing.expect(t, narrow_body_layout.wraps && narrow_height_ok && narrow_rows > body_rows,
		"resizing a fitting table narrower should reflow cell content into more visual rows")
	narrow_content_width := editor_visible_window_content_width(&window, &index, 0, 250, 48, "markdown", true, 300)
	testing.expect(t, narrow_content_width == 0,
		"a resized cell-wrapped table must continue to have no horizontal overflow")
	unchanged := len(window.source) == len(source)
	for index in 0..<min(len(window.source), len(source)) {
		unchanged = unchanged && window.source[index] == source[index]
	}
	testing.expect(t, unchanged, "table layout and resizing must not rewrite Markdown source bytes")
}

@(test)
test_table_block_layout_overflows_as_one_shared_mode_when_columns_do_not_fit :: proc(t: ^testing.T) {
	long_token := "unbreakabletokenwithenoughcharactersfortestingoverflow"
	source := fmt.tprintf("| Page | Summary |\n| ---------------- | ---------------- |\n| [[overview]] | %s |\n", long_token)
	window, window_ok := test_table_window(source)
	testing.expect(t, window_ok, "overflow table source should project into logical editor lines")
	if !window_ok { return }
	defer editor_window_destroy(&window, context.temp_allocator)
	for line_index in 0..<len(window.lines) {
		line := &window.lines[line_index]
		layout := editor_table_row_layout(&window, line, 300, context.temp_allocator)
		testing.expect(t, layout.ok && !layout.wraps,
			"a table whose minimum column widths exceed the viewport must overflow consistently in every row")
	}
	index: alicorn.Virtual_List_Height_Index
	if !alicorn.virtual_list_height_index_init(&index, len(window.lines), EDITOR_ROW_HEIGHT, context.allocator) {
		testing.expect(t, false, "table overflow test should initialize a variable-height index")
		return
	}
	defer alicorn.virtual_list_height_index_destroy(&index)
	content_width := editor_visible_window_content_width(&window, &index, 0, 250, 48, "markdown", true, 300)
	testing.expect(t, content_width > 300,
		"an overflow-mode table should expose one shared horizontal lane for its rows")
}
