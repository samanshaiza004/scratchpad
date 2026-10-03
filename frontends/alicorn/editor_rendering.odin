package main

import "core:fmt"
import "core:unicode/utf8"
import alicorn "alicorn:runtime"

Editor_Row_Target :: struct {
	node:         alicorn.Node_ID,
	logical_line: u64,
	cell_start:   u64,
	cell_end:     u64,
	cell_index:   int,
	cell_width:   f32,
	cell_origin_x: f32,
	is_cell:      bool,
}

Editor_Table_Row_Layout :: struct {
	cells:         [dynamic]Editor_Display_Line,
	pipes:         [dynamic]u64,
	widths:        [dynamic]f32,
	origins:       [dynamic]f32,
	leading_pipe:  bool,
	trailing_pipe: bool,
	delimiter:     bool,
	wraps:         bool,
	ok:             bool,
}

Editor_Table_Block_Layout :: struct {
	widths: [dynamic]f32,
	wraps:  bool,
	ok:     bool,
}

Editor_Source_Range :: struct {
	start_byte: u64,
	end_byte:   u64,
}

editor_row_node_for_line :: proc(rows: []Editor_Row_Target, logical_line: u64) -> alicorn.Node_ID {
	for row in rows {
		if row.logical_line == logical_line { return row.node }
	}
	return 0
}

editor_row_target_for_source :: proc(
	rows: []Editor_Row_Target,
	logical_line: u64,
	source_byte: u64,
) -> (target: Editor_Row_Target, found: bool) {
	best_distance := u64(0xFFFF_FFFF_FFFF_FFFF)
	for row in rows {
		if row.logical_line != logical_line { continue }
		if !row.is_cell { return row, true }
		distance := u64(0)
		if source_byte < row.cell_start { distance = row.cell_start-source_byte }
		else if source_byte > row.cell_end { distance = source_byte-row.cell_end }
		if distance == 0 { return row, true }
		if distance < best_distance {
			best_distance = distance
			target = row
			found = true
		}
	}
	return
}

editor_temporary_text_run :: proc(
	rt: ^alicorn.Runtime,
	line: ^Editor_Display_Line,
	max_width: f32 = 0,
	overflow := alicorn.Text_Overflow.Clip,
	style_spans: []alicorn.Text_Style_Span = nil,
) -> (run: alicorn.Text_Run, ok: bool) {
	if rt == nil || line == nil { return }
	return alicorn.runtime_text_run_build(
		rt,
		line.display,
		size=alicorn.DEFAULT_TEXT_SIZE,
		max_width=max_width,
		font=.Monospace,
		font_weight=alicorn.FONT_WEIGHT_REGULAR,
		overflow=overflow,
		editable=true,
		text_style_spans=style_spans,
		allocator=context.temp_allocator,
		scratch_allocator=alicorn.runtime_scratch_allocator(rt),
	)
}

// Return the exact visual line containing a displayed caret position. This
// uses the same Runa shaping inputs as the retained editor node, so the active
// row follows wrapped prose and table cells without changing layout state.
editor_visual_row_display_range :: proc(
	rt: ^alicorn.Runtime,
	line: ^Editor_Display_Line,
	display_byte: int,
	affinity: alicorn.Text_Affinity,
	width: f32,
	wrap: bool,
	style_spans: []alicorn.Text_Style_Span = nil,
) -> (start, end: int, ok: bool) {
	if rt == nil || line == nil { return }
	overflow := alicorn.Text_Overflow.Clip
	max_width := f32(0)
	if wrap {
		overflow = .Wrap
		max_width = width
	}
	run, built := editor_temporary_text_run(rt, line, max_width, overflow, style_spans)
	if !built { return }
	defer alicorn.text_run_destroy(&run)
	geometry := alicorn.text_run_caret_geometry(
		&run,
		alicorn.Text_Position{byte=display_byte, affinity=affinity},
		alicorn.runtime_scratch_allocator(rt),
	)
	if !geometry.valid || geometry.line_index < 0 || geometry.line_index >= len(run.lines) { return }
	visual_line := run.lines[geometry.line_index]
	start = clamp(visual_line.byte_start, 0, len(line.display))
	end = clamp(visual_line.byte_end, start, len(line.display))
	return start, end, true
}

editor_merge_text_paint_spans :: proc(
	base, additions: []alicorn.Text_Paint_Span,
	allocator := context.temp_allocator,
) -> []alicorn.Text_Paint_Span {
	if len(additions) == 0 { return base }
	result := make([dynamic]alicorn.Text_Paint_Span, 0, len(base)+len(additions), allocator=allocator)
	for span in base { append(&result, span) }
	for span in additions { append(&result, span) }
	return result[:]
}

editor_navigation_text_run :: proc(
	rt: ^alicorn.Runtime,
	window: ^Editor_Window,
	line: ^Editor_Display_Line,
	language: string,
	width: f32,
	presentation_current: bool,
	wrap_mode := Editor_Wrap_Mode.Auto,
) -> (run: alicorn.Text_Run, ok: bool) {
	if line == nil { return }
	style_spans: []alicorn.Text_Style_Span
	if presentation_current { style_spans = editor_presentation_text_styles_for_line(window, line, context.temp_allocator) }
	wrap := editor_line_should_wrap_for_view(language, window, line, presentation_current, width, wrap_mode)
	overflow := alicorn.Text_Overflow.Clip
	max_width: f32 = 0
	if wrap {
		overflow = .Wrap
		max_width = width
	}
	return editor_temporary_text_run(rt, line, max_width, overflow, style_spans)
}

// Return the exact displayed run's caret geometry when a logical row is
// realized. A bounded one-line shape is used only for a target row just beyond
// the current viewport realization.
editor_line_visual_caret_metrics :: proc(
	rt: ^alicorn.Runtime,
	window: ^Editor_Window,
	line: ^Editor_Display_Line,
	language: string,
	width: f32,
	presentation_current: bool,
	text_node: alicorn.Node_ID,
	source_byte: u64,
	affinity: alicorn.Text_Affinity,
	measure_caret := true,
	wrap_mode := Editor_Wrap_Mode.Auto,
) -> (geometry: alicorn.Text_Caret_Geometry, visual_rows: int, run_height: f32, ok: bool) {
	if rt == nil || line == nil { return }
	position := alicorn.Text_Position{byte=editor_source_to_display(line, source_byte), affinity=affinity}
	if node, found := alicorn.node_info(rt, text_node); found && text_node != 0 {
		if node.active && node.text_geometry_available {
			visual_rows, run_height = alicorn.text_node_line_count(rt, text_node), node.text_content_height
			if measure_caret {
				geometry = alicorn.text_node_caret_geometry(rt, text_node, position)
				geometry.rect.x -= node.bounds.x
				geometry.rect.y -= node.bounds.y
			}
			ok = visual_rows > 0
			return
		}
	}
	run, built := editor_navigation_text_run(rt, window, line, language, width, presentation_current, wrap_mode)
	if !built { return }
	defer alicorn.text_run_destroy(&run)
	visual_rows, run_height = len(run.lines), run.height
	if measure_caret { geometry = alicorn.text_run_caret_geometry(&run, position, alicorn.runtime_scratch_allocator(rt)) }
	ok = visual_rows > 0
	return
}

// Map a preferred X and a chosen visual-row Y through the same styled Runa run
// used by rendering, then convert the resulting display boundary to source.
editor_source_at_visual_point :: proc(
	rt: ^alicorn.Runtime,
	window: ^Editor_Window,
	line: ^Editor_Display_Line,
	language: string,
	width: f32,
	presentation_current: bool,
	text_node: alicorn.Node_ID,
	visual_x, visual_y: f32,
	visual_row := -1,
	wrap_mode := Editor_Wrap_Mode.Auto,
) -> (source_byte: u64, affinity: alicorn.Text_Affinity, ok: bool) {
	if rt == nil || line == nil { return }
	position: alicorn.Text_Position
	if node, found := alicorn.node_info(rt, text_node); found && text_node != 0 && node.active && node.text_geometry_available {
		y := visual_y
		if visual_row >= 0 {
			row, row_found := alicorn.text_node_line_geometry(rt, text_node, clamp(visual_row, 0, alicorn.text_node_line_count(rt, text_node)-1))
			if !row_found { return }
			y = row.bounds.y+row.bounds.h*0.5
		} else {
			y += node.bounds.y
		}
		position, ok = alicorn.text_node_hit_test(rt, text_node, node.bounds.x+visual_x, y)
		if !ok { return }
	} else {
		run, built := editor_navigation_text_run(rt, window, line, language, width, presentation_current, wrap_mode)
		if !built { return }
		defer alicorn.text_run_destroy(&run)
		y := visual_y
		if visual_row >= 0 {
			row := run.lines[clamp(visual_row, 0, len(run.lines)-1)]
			y = row.y+row.height*0.5
		}
		position = alicorn.text_run_hit_test(&run, visual_x, y, alicorn.runtime_scratch_allocator(rt))
	}
	source_byte = editor_normalize_source_position(line, editor_display_to_source(line, position.byte))
	affinity = position.affinity
	ok = true
	return
}


editor_view_observe_horizontal_extent :: proc(
	view: ^Editor_View_State,
	editor_revision: u64,
	measured_width: f32,
) -> f32 {
	if view == nil { return max(measured_width, 0) }
	if view.extent_revision != editor_revision {
		view.extent_revision = editor_revision
		view.horizontal_extent = 0
	}
	view.horizontal_extent = max(view.horizontal_extent, max(measured_width, 0))
	return view.horizontal_extent
}

// Scroll offsets flow from the retained runtime into the document's saved
// view during ordinary rebuilds. Saved offsets flow back only once after a
// document becomes active; horizontal restore waits until its content width is
// known so it can be clamped to the correct geometry.
editor_view_sync_scroll :: proc(
	view: ^Editor_View_State,
	live_y, live_x: f32,
	max_y, max_x: f32,
	horizontal_ready: bool,
) -> Editor_View_Restore {
	result := Editor_View_Restore{}
	if view == nil { return result }
	if view.restore_y_pending {
		result.vertical = true
		result.scroll_y = min(max(view.scroll_y, 0), max(max_y, 0))
		view.scroll_y = result.scroll_y
		view.restore_y_pending = false
	} else {
		view.scroll_y = live_y
	}
	if view.restore_x_pending {
		if horizontal_ready {
			result.horizontal = true
			result.scroll_x = min(max(view.scroll_x, 0), max(max_x, 0))
			view.scroll_x = result.scroll_x
			view.restore_x_pending = false
			view.horizontal_scroll_suspended = false
		}
	} else if !horizontal_ready {
		// Keep the last horizontal position while the current viewport contains
		// only wrapped rows. Alicorn's shared scroll region clamps its live X to
		// zero when its horizontal lane is inactive; that temporary clamp must
		// not erase this document's position for a later no-wrap row.
		view.horizontal_scroll_suspended = true
	} else if view.horizontal_scroll_suspended {
		result.horizontal = true
		result.scroll_x = min(max(view.scroll_x, 0), max(max_x, 0))
		view.scroll_x = result.scroll_x
		view.horizontal_scroll_suspended = false
	} else {
		clamped_x := min(max(live_x, 0), max(max_x, 0))
		view.scroll_x = clamped_x
		if abs(clamped_x-live_x) > 0.5 {
			result.horizontal = true
			result.scroll_x = clamped_x
		}
	}
	return result
}

editor_line_number_text :: proc(line_number: u64) -> string {
	return fmt.tprintf("%d", line_number)
}

editor_line_number_gutter_width :: proc(line_count: u64) -> f32 {
	digits := 1
	remaining := line_count
	for remaining >= 10 {
		remaining /= 10
		digits += 1
	}
	digits = max(digits, 3)
	return f32(digits)*10 + 12
}


editor_table_source_is_whitespace :: proc(source: []u8) -> bool {
	for value in source {
		if value != ' ' && value != '\t' && value != '\r' { return false }
	}
	return true
}

editor_table_pipe_positions :: proc(
	window: ^Editor_Window,
	line: ^Editor_Display_Line,
	allocator := context.temp_allocator,
) -> [dynamic]u64 {
	pipes := make([dynamic]u64, 0, allocator=allocator)
	if window == nil || line == nil { return pipes }
	for record in window.presentation_spans {
		if record.kind != EDITOR_PRESENTATION_TABLE_PIPE { continue }
		start := window.start_byte+u64(record.start_byte)
		if start < line.source_start || start >= line.source_end { continue }
		append(&pipes, start)
	}
	// Presentation spans are sorted today, but keeping this local operation
	// robust makes table geometry independent of that transport detail.
	for index in 1..<len(pipes) {
		value := pipes[index]
		cursor := index
		for cursor > 0 && pipes[cursor-1] > value {
			pipes[cursor] = pipes[cursor-1]
			cursor -= 1
		}
		pipes[cursor] = value
	}
	return pipes
}

editor_table_line_is_projected :: proc(window: ^Editor_Window, line: ^Editor_Display_Line) -> bool {
	if window == nil || line == nil || line.is_table_cell || !window.presentation_ready ||
	   (!window.presentation_stale && window.presentation_revision != window.editor_revision) { return false }
	for record in window.presentation_blocks {
		if record.kind != EDITOR_PRESENTATION_BLOCK_TABLE { continue }
		start := window.start_byte+u64(record.start_byte)
		end := window.start_byte+u64(record.end_byte)
		if start < line.source_end && end > line.source_start { return true }
	}
	for record in window.presentation_spans {
		if record.kind != EDITOR_PRESENTATION_TABLE { continue }
		start := window.start_byte+u64(record.start_byte)
		end := window.start_byte+u64(record.end_byte)
		if start < line.source_end && end > line.source_start { return true }
	}
	return false
}

editor_table_line_cell_ranges :: proc(
	window: ^Editor_Window,
	line: ^Editor_Display_Line,
	allocator := context.temp_allocator,
) -> (ranges: [dynamic]Editor_Source_Range, pipes: [dynamic]u64, leading_pipe, trailing_pipe: bool) {
	ranges = make([dynamic]Editor_Source_Range, 0, allocator=allocator)
	pipes = editor_table_pipe_positions(window, line, allocator)
	if window == nil || line == nil { return }
	line_start := int(line.source_start-window.start_byte)
	line_end := int(line.source_end-window.start_byte)
	if line_start < 0 || line_end > len(window.source) || line_end < line_start { return }
	if len(pipes) > 0 {
		first_pipe := int(pipes[0]-window.start_byte)
		leading_pipe = editor_table_source_is_whitespace(window.source[line_start:first_pipe])
	}
	expected_columns := 0
	for record in window.presentation_blocks {
		if record.kind != EDITOR_PRESENTATION_BLOCK_TABLE { continue }
		start := window.start_byte+u64(record.start_byte)
		end := window.start_byte+u64(record.end_byte)
		if start < line.source_end && end > line.source_start {
			expected_columns = int(record.level_flags & 0xFF)
			break
		}
	}
	if len(pipes) > 0 {
		last_pipe := int(pipes[len(pipes)-1]-window.start_byte)
		trailing_pipe = editor_table_source_is_whitespace(window.source[last_pipe+1:line_end])
		if expected_columns > 0 {
			edge_pipe_count := len(pipes)-(expected_columns-1)
			if leading_pipe { edge_pipe_count -= 1 }
			if edge_pipe_count <= 0 { trailing_pipe = false }
			else { trailing_pipe = true }
		}
	}
	cell_start := line.source_start
	for pipe, pipe_index in pipes {
		if pipe_index == 0 && leading_pipe {
			cell_start = pipe+1
			continue
		}
		append(&ranges, Editor_Source_Range{cell_start, pipe})
		cell_start = pipe+1
	}
	if !trailing_pipe && cell_start <= line.source_end {
		append(&ranges, Editor_Source_Range{cell_start, line.source_end})
	}
	for expected_columns > 0 && len(ranges) < expected_columns {
		append(&ranges, Editor_Source_Range{line.source_end, line.source_end})
	}
	return
}

editor_table_cell_content_range :: proc(
	window: ^Editor_Window,
	line: ^Editor_Display_Line,
	slot: Editor_Source_Range,
	column: int,
) -> Editor_Source_Range {
	if window == nil || line == nil { return slot }
	for record in window.presentation_spans {
		if record.kind != EDITOR_PRESENTATION_TABLE_CELL || int(record.level_flags & 0xFF) != column { continue }
		start := window.start_byte+u64(record.start_byte)
	end := window.start_byte+u64(record.end_byte)
		if start >= slot.start_byte && end <= slot.end_byte && start <= end {
			return Editor_Source_Range{start, end}
		}
	}
	// During a rebased/stale presentation window a newly formed cell may not
	// have a parser cell span yet. Trimming the parser-delimited slot preserves
	// the same source range contract until Goldmark publishes the exact range.
	start := int(max(slot.start_byte, window.start_byte)-window.start_byte)
	end := int(min(slot.end_byte, window.start_byte+u64(len(window.source)))-window.start_byte)
	for start < end && editor_table_source_is_whitespace(window.source[start:start+1]) { start += 1 }
	for end > start && editor_table_source_is_whitespace(window.source[end-1:end]) { end -= 1 }
	return Editor_Source_Range{window.start_byte+u64(start), window.start_byte+u64(end)}
}

editor_table_line_is_delimiter :: proc(window: ^Editor_Window, line: ^Editor_Display_Line) -> bool {
	if window == nil || line == nil { return false }
	for record in window.presentation_spans {
		if record.kind != EDITOR_PRESENTATION_TABLE_DELIMITER { continue }
		start := window.start_byte+u64(record.start_byte)
		end := window.start_byte+u64(record.end_byte)
		if editor_presentation_range_intersects_line(line, start, end) { return true }
	}
	return false
}

editor_table_cell_widths :: proc(text: string) -> (minimum, preferred: f32) {
	longest_word: f32 = 0
	word_width: f32 = 0
	preferred = 0
	byte_index := 0
	for byte_index < len(text) {
		rune_value, sequence_length := utf8.decode_rune_in_string(text[byte_index:])
		if sequence_length <= 0 { sequence_length = 1 }
		glyph_width := f32(9.5)
		if rune_value >= 0x1100 { glyph_width = 16 }
		preferred += glyph_width
		if rune_value == ' ' || rune_value == '\t' || rune_value == '\r' {
			longest_word = max(longest_word, word_width)
			word_width = 0
		} else {
			word_width += glyph_width
		}
		byte_index += sequence_length
	}
	longest_word = max(longest_word, word_width)
	minimum = longest_word+20
	preferred += 20
	return
}

editor_table_block_layout :: proc(
	window: ^Editor_Window,
	line: ^Editor_Display_Line,
	width: f32,
	allocator := context.temp_allocator,
) -> (layout: Editor_Table_Block_Layout) {
	if window == nil || line == nil || width <= 0 { return }
	table_start, table_end: u64
	column_count := 0
	for record in window.presentation_blocks {
		if record.kind != EDITOR_PRESENTATION_BLOCK_TABLE { continue }
		start := window.start_byte+u64(record.start_byte)
		end := window.start_byte+u64(record.end_byte)
		if editor_presentation_range_intersects_line(line, start, end) {
			table_start, table_end = start, end
			column_count = int(record.level_flags & 0xFF)
			break
		}
	}
	if column_count <= 0 || table_end <= table_start { return }
	if window.table_plan_cache_valid &&
	   window.table_plan_cache_start == table_start && window.table_plan_cache_end == table_end &&
	   window.table_plan_cache_revision == window.editor_revision &&
	   window.table_plan_cache_presentation_revision == window.presentation_revision &&
	   window.table_plan_cache_stale == window.presentation_stale &&
	   window.table_plan_cache_width == width {
		layout.widths = make([dynamic]f32, 0, window.table_plan_cache_width_count, allocator=allocator)
		for column in 0..<window.table_plan_cache_width_count {
			append(&layout.widths, window.table_plan_cache_widths[column])
		}
		layout.wraps = window.table_plan_cache_wraps
		layout.ok = true
		return
	}

	window.table_plan_cache_valid = true
	window.table_plan_cache_start = table_start
	window.table_plan_cache_end = table_end
	window.table_plan_cache_revision = window.editor_revision
	window.table_plan_cache_presentation_revision = window.presentation_revision
	window.table_plan_cache_width = width
	window.table_plan_cache_stale = window.presentation_stale
	window.table_plan_cache_wraps = false
	window.table_plan_cache_width_count = 0

	minimums := make([dynamic]f32, 0, column_count, allocator=allocator)
	preferreds := make([dynamic]f32, 0, column_count, allocator=allocator)
	for _ in 0..<column_count {
		append(&minimums, 72)
		append(&preferreds, 72)
	}
	max_pipe_count := 0
	for &candidate in window.lines {
		if candidate.source_start >= table_end || candidate.source_end < table_start { continue }
		if !editor_table_line_is_projected(window, &candidate) { continue }
		slots, pipes, _, _ := editor_table_line_cell_ranges(window, &candidate, allocator)
		max_pipe_count = max(max_pipe_count, len(pipes))
		// A row with cells beyond the delimiter schema cannot share a coherent
		// wrapped column plan, so keep the complete table in overflow mode.
		if len(slots) > column_count { return }
		// The delimiter row describes alignment syntax, not column content.
		if editor_table_line_is_delimiter(window, &candidate) { continue }
		for column in 0..<min(column_count, len(slots)) {
			content := editor_table_cell_content_range(window, &candidate, slots[column], column)
			start := int(content.start_byte-window.start_byte)
			end := int(content.end_byte-window.start_byte)
			if start < 0 || end < start || end > len(window.source) { continue }
			cell, projected := editor_project_line(window.source[start:end], content.start_byte, candidate.logical_line, allocator)
			if !projected { continue }
			minimum, preferred := editor_table_cell_widths(cell.display)
			minimums[column] = max(minimums[column], minimum)
			preferreds[column] = max(preferreds[column], preferred)
		}
	}
	if max_pipe_count < column_count-1 { max_pipe_count = column_count-1 }
	cell_space := width-f32(max_pipe_count)*10
	minimum_total: f32 = 0
	for minimum in minimums { minimum_total += minimum }
	if cell_space < minimum_total { return }

	layout.widths = make([dynamic]f32, 0, column_count, allocator=allocator)
	remaining := cell_space-minimum_total
	for column in 0..<column_count {
		column_minimum := minimums[column]
		column_preferred := preferreds[column]
		// Let early columns grow only to a content-derived preferred width.
		// The final column absorbs spare viewport width, which gives the common
		// Page/Summary shape a compact key column and a generous prose column.
		if column+1 < column_count {
			column_preferred = min(column_preferred, max(column_minimum, width*0.45))
			growth := min(remaining, max(column_preferred-column_minimum, 0))
			column_minimum += growth
			remaining -= growth
		}
		append(&layout.widths, column_minimum)
	}
	if len(layout.widths) > 0 { layout.widths[len(layout.widths)-1] += remaining }
	layout.wraps = true
	layout.ok = true
	window.table_plan_cache_wraps = true
	window.table_plan_cache_width_count = min(len(layout.widths), len(window.table_plan_cache_widths))
	for column in 0..<window.table_plan_cache_width_count {
		window.table_plan_cache_widths[column] = layout.widths[column]
	}
	return
}

editor_table_row_layout :: proc(
	window: ^Editor_Window,
	line: ^Editor_Display_Line,
	width: f32,
	allocator := context.temp_allocator,
) -> (layout: Editor_Table_Row_Layout) {
	if !editor_table_line_is_projected(window, line) { return }
	slots, pipes, leading, trailing := editor_table_line_cell_ranges(window, line, allocator)
	layout.pipes = pipes
	layout.leading_pipe, layout.trailing_pipe = leading, trailing
	layout.cells = make([dynamic]Editor_Display_Line, 0, allocator=allocator)
	layout.widths = make([dynamic]f32, 0, allocator=allocator)
	layout.origins = make([dynamic]f32, 0, allocator=allocator)
	layout.delimiter = editor_table_line_is_delimiter(window, line)
	for slot, cell_index in slots {
		range := editor_table_cell_content_range(window, line, slot, cell_index)
		start, end := range.start_byte, range.end_byte
		if start < line.source_start || end > line.source_end || end < start { return }
		relative_start := int(start-window.start_byte)
		relative_end := int(end-window.start_byte)
		cell, projected := editor_project_line(window.source[relative_start:relative_end], start, line.logical_line, allocator)
		if !projected { return }
		cell.is_table_cell = true
		cell.table_cell_index = len(layout.cells)
		append(&layout.cells, cell)
	}
	if len(layout.cells) == 0 { return }
	plan := editor_table_block_layout(window, line, width, allocator)
	if !plan.ok || len(plan.widths) < len(layout.cells) { layout.ok = true; return }
	layout.widths = plan.widths
	origin_x := f32(0)
	if layout.leading_pipe { origin_x += 10 }
	for cell_width, width_index in layout.widths {
		append(&layout.origins, origin_x)
		origin_x += cell_width
		if width_index+1 < len(layout.widths) { origin_x += 10 }
	}
	layout.wraps = plan.wraps
	layout.ok = true
	return
}

editor_table_cell_line :: proc(
	window: ^Editor_Window,
	line: ^Editor_Display_Line,
	cell_index: int,
	allocator := context.temp_allocator,
) -> (cell: Editor_Display_Line, found: bool) {
	layout := editor_table_row_layout(window, line, 0, allocator)
	if cell_index < 0 || cell_index >= len(layout.cells) { return }
	return layout.cells[cell_index], true
}

editor_project_source_segment :: proc(
	window: ^Editor_Window,
	line: ^Editor_Display_Line,
	start_byte, end_byte: u64,
	allocator := context.temp_allocator,
) -> (segment: Editor_Display_Line, ok: bool) {
	if window == nil || line == nil || start_byte < line.source_start || end_byte > line.source_end || end_byte < start_byte { return }
	start := int(start_byte-window.start_byte)
	end := int(end_byte-window.start_byte)
	if start < 0 || end > len(window.source) { return }
	return editor_project_line(window.source[start:end], start_byte, line.logical_line, allocator)
}

editor_display_line_for_target :: proc(
	window: ^Editor_Window,
	line: ^Editor_Display_Line,
	target: Editor_Row_Target,
	allocator := context.temp_allocator,
) -> (display_line: Editor_Display_Line, ok: bool) {
	if line == nil { return }
	if !target.is_cell { return line^, true }
	return editor_project_source_segment(window, line, target.cell_start, target.cell_end, allocator)
}

editor_table_line_fit :: proc(window: ^Editor_Window, line: ^Editor_Display_Line, width: f32) -> bool {
	layout := editor_table_row_layout(window, line, width)
	return layout.ok && layout.wraps
}

editor_table_cell_for_x :: proc(layout: Editor_Table_Row_Layout, visual_x: f32) -> int {
	if len(layout.cells) == 0 { return -1 }
	for cell_width, cell_index in layout.widths {
		if visual_x < layout.origins[cell_index]+cell_width { return cell_index }
	}
	return len(layout.cells)-1
}

// editor_display_to_source maps an Runa hit-test boundary back to the nearest
// legal source boundary. Interior positions in repeated-map synthetic runs
// snap at the visual midpoint, so a tab or escaped byte remains one source
// unit rather than exposing carets inside its display spelling.

editor_line_should_wrap :: proc(language: string, window: ^Editor_Window, line: ^Editor_Display_Line, presentation_current := true, width: f32 = 0) -> bool {
	if language != "markdown" && language != "plain-text" { return false }
	if language != "markdown" || !presentation_current || window == nil || line == nil ||
	   !window.presentation_ready || (!window.presentation_stale && window.presentation_revision != window.editor_revision) {
		return true
	}
	table_line := editor_table_line_is_projected(window, line)
	for record in window.presentation_spans {
		// Fenced code remains on the horizontal-scroll path. Tables use their
		// parser-owned structural pipe map for a cell-aware fit decision below.
		if record.kind != EDITOR_PRESENTATION_CODE_BLOCK { continue }
		start := window.start_byte+u64(record.start_byte)
		end := window.start_byte+u64(record.end_byte)
		if start < line.source_end && end > line.source_start { return false }
	}
	for record in window.presentation_blocks {
		if record.kind != EDITOR_PRESENTATION_BLOCK_CODE { continue }
		start := window.start_byte+u64(record.start_byte)
		end := window.start_byte+u64(record.end_byte)
		if start < line.source_end && end > line.source_start { return false }
	}
	if table_line { return editor_table_line_fit(window, line, width) }
	return true
}

// User wrap preferences apply to ordinary logical rows. Parser-owned fenced
// code and table layout retain their established policy so toggling prose wrap
// cannot turn a table into independently reflowed cells or wrap a code block.
editor_line_should_wrap_for_view :: proc(
	language: string,
	window: ^Editor_Window,
	line: ^Editor_Display_Line,
	presentation_current := true,
	width: f32 = 0,
	mode := Editor_Wrap_Mode.Auto,
) -> bool {
	baseline := editor_line_should_wrap(language, window, line, presentation_current, width)
	if mode == .Auto || window == nil || line == nil { return baseline }
	if editor_table_line_is_projected(window, line) { return baseline }
	for record in window.presentation_spans {
		if record.kind != EDITOR_PRESENTATION_CODE_BLOCK { continue }
		start := window.start_byte+u64(record.start_byte)
		end := window.start_byte+u64(record.end_byte)
		if start < line.source_end && end > line.source_start { return false }
	}
	for record in window.presentation_blocks {
		if record.kind != EDITOR_PRESENTATION_BLOCK_CODE { continue }
		start := window.start_byte+u64(record.start_byte)
		end := window.start_byte+u64(record.end_byte)
		if start < line.source_end && end > line.source_start { return false }
	}
	return mode == .On
}

editor_cursor_in_markdown_table :: proc(window: ^Editor_Window, source_byte: u64) -> bool {
	if window == nil || !window.presentation_ready ||
	   (!window.presentation_stale && window.presentation_revision != window.editor_revision) {
		return false
	}
	for record in window.presentation_blocks {
		if record.kind != EDITOR_PRESENTATION_BLOCK_TABLE { continue }
		start := window.start_byte+u64(record.start_byte)
		end := window.start_byte+u64(record.end_byte)
		if source_byte >= start && source_byte < end { return true }
		// Goldmark includes a final LF in table block ranges. At EOF without an
		// LF, the caret immediately after the last cell is still in that cell.
		window_end := window.start_byte+u64(len(window.source))
		if source_byte == end && end == window_end && len(window.source) > 0 && window.source[len(window.source)-1] != '\n' {
			return true
		}
	}
	return false
}

editor_measure_line_height :: proc(
	rt: ^alicorn.Runtime,
	window: ^Editor_Window,
	line: ^Editor_Display_Line,
	width: f32,
	wrap: bool,
	presentation_current: bool,
) -> (height: f32, shaped_width: f32, visual_rows: int, ok: bool) {
	if line == nil { return }
	if wrap && editor_table_line_is_projected(window, line) {
		layout := editor_table_row_layout(window, line, width)
		if layout.ok && layout.wraps {
			if layout.delimiter { return EDITOR_ROW_HEIGHT, width, 1, true }
			tallest: f32 = EDITOR_ROW_HEIGHT
			visual_rows := 1
			for &cell, cell_index in layout.cells {
				style_spans := editor_presentation_text_styles_for_line(window, &cell, context.temp_allocator) if presentation_current else nil
				run, built := alicorn.runtime_text_run_build(
					rt,
					cell.display,
					size=alicorn.DEFAULT_TEXT_SIZE,
					max_width=layout.widths[cell_index],
					font=.Monospace,
					font_weight=alicorn.FONT_WEIGHT_REGULAR,
					overflow=.Wrap,
					editable=true,
					text_style_spans=style_spans,
					allocator=context.temp_allocator,
					scratch_allocator=alicorn.runtime_scratch_allocator(rt),
				)
				if !built { continue }
				tallest = max(tallest, run.height)
				visual_rows = max(visual_rows, len(run.lines))
				alicorn.text_run_destroy(&run)
			}
			if presentation_current {
				tallest += editor_markdown_row_extra_height(editor_markdown_row_presentation(window, line, true))
			}
			return tallest, width, visual_rows, true
		}
	}
	style_spans: []alicorn.Text_Style_Span
	if presentation_current { style_spans = editor_presentation_text_styles_for_line(window, line, context.temp_allocator) }
	overflow := alicorn.Text_Overflow.Clip
	if wrap { overflow = .Wrap }
	run, built := editor_temporary_text_run(rt, line, width, overflow, style_spans)
	if !built { return EDITOR_ROW_HEIGHT, 0, 1, false }
	defer alicorn.text_run_destroy(&run)
	height = max(EDITOR_ROW_HEIGHT, run.height)
	if presentation_current {
		height += editor_markdown_row_extra_height(editor_markdown_row_presentation(window, line, true))
	}
	shaped_width = run.width
	visual_rows = max(len(run.lines), 1)
	ok = true
	return
}

editor_measure_window_wrapping :: proc(
	rt: ^alicorn.Runtime,
	view: ^Editor_View_State,
	window: ^Editor_Window,
	language: string,
	width: f32,
	presentation_current: bool,
) -> bool {
	if rt == nil || view == nil || window == nil || !view.wrap_height_index_ready || width <= 0 { return false }
	changed := false
	for &line in window.lines {
		wrap := editor_line_should_wrap_for_view(language, window, &line, presentation_current, width, view.wrap_mode)
		height, _, _, ok := editor_measure_line_height(rt, window, &line, width, wrap, presentation_current)
		if !ok { continue }
		changed = alicorn.virtual_list_height_index_set_height(&view.wrap_height_index, int(line.logical_line), height) || changed
	}
	return changed
}

editor_window_content_width :: proc(window: ^Editor_Window, gutter_width: f32, language := "", presentation_current := true) -> f32 {
	width: f32 = 0
	if window == nil { return width }
	for &line in window.lines {
		if editor_line_should_wrap(language, window, &line, presentation_current) { continue }
		// Deliberately conservative for multi-byte glyphs: the frontier is based
		// only on the bounded window, never a scan of the full document.
		width = max(width, f32(len(line.display))*10 + gutter_width + 8)
	}
	return width
}

// Measure only the visible no-wrap rows (with half a viewport of vertical
// overscan on each side). A distant table or code line should not leave a horizontal bar
// over an otherwise wrapped prose viewport. The width remains a bounded-window
// estimate, just like the text surface itself.
editor_visible_window_content_width :: proc(
	window: ^Editor_Window,
	index: ^alicorn.Virtual_List_Height_Index,
	scroll_y, viewport_height: f32,
	gutter_width: f32,
	language: string,
	presentation_current: bool,
	wrap_width: f32,
	wrap_mode := Editor_Wrap_Mode.Auto,
) -> f32 {
	if window == nil || index == nil || viewport_height <= 0 { return 0 }
	overscan_y := max(viewport_height*0.5, EDITOR_ROW_HEIGHT)
	metrics := alicorn.virtual_list_variable_metrics(
		index,
		max(scroll_y-overscan_y, 0),
		viewport_height+overscan_y*2,
	)
	width: f32 = 0
	for position := metrics.first; position < metrics.last; position += 1 {
		line, found := editor_window_line(window, u64(position))
		if !found || editor_line_should_wrap_for_view(language, window, line, presentation_current, wrap_width, wrap_mode) { continue }
		// Deliberately conservative for multi-byte glyphs. The frontier is
		// limited to rows near the viewport, never the full document.
		// The lane leaves the gutter and its inner text padding outside the
		// source run, so include that full inset in the shared scroll extent.
		width = max(width, f32(len(line.display))*10+gutter_width+16)
	}
	return width
}

editor_window_is_long_line_chunk :: proc(window: ^Editor_Window) -> bool {
	return window != nil && window.truncated &&
	       window.end_line == window.start_line+1 &&
	       window.line_byte_length > u64(len(window.source))
}

editor_long_line_next_anchor :: proc(
	window: ^Editor_Window,
	visible_start: u64,
	offset_x, max_scroll_x: f32,
) -> (anchor_byte: u64, needed: bool) {
	if !editor_window_is_long_line_chunk(window) || window.start_line != visible_start ||
	   max_scroll_x <= 0 || max_scroll_x-offset_x > 48 {
		return 0, false
	}
	chunk_end := window.start_byte + u64(len(window.source))
	overlap := min(u64(64), u64(len(window.source))/4)
	anchor_byte = chunk_end-overlap
	if anchor_byte <= window.start_byte { anchor_byte = chunk_end }
	return anchor_byte, anchor_byte > window.start_byte
}
