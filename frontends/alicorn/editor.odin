package main

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import alicorn "alicorn:runtime"
import bridge "./bridge"

EDITOR_ROW_HEIGHT :: f32(22)
EDITOR_TAB_WIDTH :: 4
EDITOR_TAB_INSERT :: [4]u8{' ', ' ', ' ', ' '}
EDITOR_LONG_LINE_CHUNK_BYTES :: u64(16 * 1024)
EDITOR_MAX_OPTIMISTIC_SOURCE_BYTES :: int(bridge.MAX_VISIBLE_BYTES + bridge.MAX_EDIT_BYTES)
EDITOR_IME_RECOVERY_MAX_BYTES :: int(bridge.MAX_EDIT_BYTES)
EDITOR_PRESENTATION_HEADING :: u32(2)
EDITOR_PRESENTATION_STRONG :: u32(3)
EDITOR_PRESENTATION_EMPHASIS :: u32(4)
EDITOR_PRESENTATION_INLINE_CODE :: u32(5)
EDITOR_PRESENTATION_LINK :: u32(6)
EDITOR_PRESENTATION_STRIKE :: u32(7)
EDITOR_PRESENTATION_CODE_BLOCK :: u32(8)
EDITOR_PRESENTATION_LIST_MARKER :: u32(10)
EDITOR_PRESENTATION_TASK_MARKER :: u32(11)
EDITOR_PRESENTATION_TABLE :: u32(29)
EDITOR_PRESENTATION_TABLE_HEADER :: u32(30)
EDITOR_PRESENTATION_TABLE_DELIMITER :: u32(31)
EDITOR_PRESENTATION_TABLE_PIPE :: u32(32)
EDITOR_PRESENTATION_TABLE_CELL :: u32(33)
EDITOR_PRESENTATION_BLOCK_CODE :: u32(0x10001)
EDITOR_PRESENTATION_BLOCK_QUOTE :: u32(0x10002)
EDITOR_PRESENTATION_BLOCK_LIST :: u32(0x10003)
EDITOR_PRESENTATION_BLOCK_THEMATIC :: u32(0x10004)
EDITOR_PRESENTATION_BLOCK_TABLE :: u32(0x10005)

editor_logical_row_style :: proc() -> alicorn.Layout_Style {
	return alicorn.layout_style(.Row, height=EDITOR_ROW_HEIGHT, gap=8, align=.Center, clip=true)
}

Editor_Display_Line :: struct {
	logical_line:  u64,
	source_start:  u64,
	source_end:    u64,
	display:       string,
	display_bytes: []u64,
	is_table_cell: bool,
	table_cell_index: int,
}

Editor_Window :: struct {
	document_id:     string,
	application_rev: u64,
	editor_revision: u64,
	start_line:      u64,
	end_line:        u64,
	start_byte:      u64,
	line_byte_length: u64,
	has_source_anchor: bool,
	source_anchor_byte: u64,
	source_anchor_line: u64,
	truncated:       bool,
	source:          []u8,
	presentation_revision: u64,
	presentation_ready: bool,
	presentation_stale: bool,
	presentation_truncated: bool,
	presentation_spans: []bridge.Presentation_Record,
	presentation_blocks: []bridge.Presentation_Record,
	table_plan_cache_valid: bool,
	table_plan_cache_start: u64,
	table_plan_cache_end: u64,
	table_plan_cache_revision: u64,
	table_plan_cache_presentation_revision: u64,
	table_plan_cache_width: f32,
	table_plan_cache_stale: bool,
	table_plan_cache_wraps: bool,
	table_plan_cache_width_count: int,
	table_plan_cache_widths: [255]f32,
	lines:           [dynamic]Editor_Display_Line,
}

Editor_View_State :: struct {
	document_id:       string,
	scroll_y:          f32,
	scroll_x:          f32,
	horizontal_extent: f32,
	extent_revision:    u64,
	horizontal_scroll_suspended: bool,
	restore_y_pending: bool,
	restore_x_pending: bool,
	selection_anchor:  u64,
	caret_byte:        u64,
	anchor_affinity:   alicorn.Text_Affinity,
	caret_affinity:    alicorn.Text_Affinity,
	preferred_x:       f32,
	preferred_x_set:   bool,
	preedit_text:      []u8,
	preedit_active:    bool,
	// A committed SDL text event can be rejected by the bounded edit lane. Keep
	// that text visible across the host's following empty TEXT_EDITING cancel.
	preedit_recoverable: bool,
	// Recoverable composition uses one preallocated backing store so appending
	// later text-input events is bounded and does not copy the growing prefix.
	preedit_recovery_storage: []u8,
	preedit_replace_start: u64,
	preedit_replace_end: u64,
	preedit_selection_start: int,
	preedit_selection_end: int,
	pending_document_edge: Editor_Document_Edge,
	pending_document_edge_shift: bool,
	dragging_selection: bool,
	drag_selection_granularity: Editor_Selection_Granularity,
	drag_selection_start: u64,
	drag_selection_end: u64,
	drag_pointer_x: f32,
	drag_pointer_y: f32,
	drag_pointer_valid: bool,
	wrap_height_index: alicorn.Virtual_List_Height_Index,
	wrap_height_index_ready: bool,
	wrap_measurement_width: f32,
	wrap_measurement_revision: u64,
	wrap_measurement_presentation_revision: u64,
	wrap_measurement_start_line: u64,
	wrap_measurement_end_line: u64,
	wrap_measurement_pending_edits: u64,
	wrap_last_outer_width: f32,
	wrap_last_outer_height: f32,
	wrap_last_split_position: f32,
	wrap_last_split_position_valid: bool,
	authoritative_revision: u64,
	undo_group_id: u64,
	undo_group_editor_focus: bool,
	last_typing_at: time.Time,
	typing_group_active: bool,
	viewport_anchor_byte: u64,
	viewport_anchor_revision: u64,
	viewport_anchor_line: u64,
	viewport_anchor_offset: f32,
	viewport_anchor_pending: bool,
	viewport_anchor_resolved: bool,
	viewport_anchor_skip_next_source_change: bool,
	optimistic_window: Editor_Window,
	optimistic_window_ready: bool,
	optimistic_pending_edits: u64,
	optimistic_line_delta: i64,
	position_reconcile_pending: bool,
}

Editor_Document_Edge :: enum { None, Start, End }

// Pointer selection keeps its original granularity for the duration of a
// captured drag, as native text views do for character/word/line selection.
Editor_Selection_Granularity :: enum { Character, Word, Line }

EDITOR_SELECTION_AUTOSCROLL_INTERVAL_NS :: u64(16_000_000)
EDITOR_SELECTION_AUTOSCROLL_MAX_STEP :: f32(32)

editor_selection_autoscroll_step :: proc(distance: f32) -> f32 {
	if distance <= 0 { return 0 }
	return min(EDITOR_SELECTION_AUTOSCROLL_MAX_STEP, 2 + distance*0.35)
}

// Logical-line selection deliberately excludes its line ending, matching the
// Shirei editor's Buffer.LineRange contract. A drag spanning lines naturally
// includes intervening terminators between its endpoints.
editor_line_selection_range :: proc(window: ^Editor_Window, logical_line: u64) -> (start, end: u64, ok: bool) {
	if window == nil { return }
	line, found := editor_window_line(window, logical_line)
	if !found { return }
	start, end = line.source_start, line.source_end
	return start, end, true
}

editor_word_selection_range :: proc(window: ^Editor_Window, source_byte: u64) -> (start, end: u64, ok: bool) {
	if window == nil { return }
	line, found := editor_line_for_source(window, source_byte)
	if !found { return }
	display_byte := editor_source_to_display(line, source_byte)
	// Use Runa's UAX #29 word segmentation, matching the runtime's word
	// navigation policy instead of introducing byte/ASCII heuristics here.
	ranges := alicorn.text_word_ranges(line.display, context.temp_allocator)
	defer delete(ranges)
	selected := -1
	for range, index in ranges {
		if display_byte >= range.start && display_byte < range.end {
			selected = index
			break
		}
	}
	if selected < 0 && display_byte == len(line.display) && len(ranges) > 0 {
		selected = len(ranges)-1
	}
	if selected < 0 { return }
	range := ranges[selected]
	start = editor_normalize_source_position(line, editor_display_to_source(line, range.start))
	end = editor_normalize_source_position(line, editor_display_to_source(line, range.end))
	return start, end, end > start
}

editor_apply_pointer_selection :: proc(
	view: ^Editor_View_State,
	window: ^Editor_Window,
	source_byte: u64,
	affinity: alicorn.Text_Affinity,
	click_count: u8,
	shift: bool,
) -> bool {
	if view == nil || window == nil { return false }
	normalized_click_count := click_count
	if normalized_click_count == 0 { normalized_click_count = 1 }
	view.preferred_x_set = false
	if normalized_click_count >= 3 {
		line, found := editor_line_for_source(window, source_byte)
		if !found { return false }
		start, end, range_ok := editor_line_selection_range(window, line.logical_line)
		if !range_ok { return false }
		view.selection_anchor, view.caret_byte = start, end
		view.anchor_affinity, view.caret_affinity = .Leading, .Trailing
		view.drag_selection_granularity = .Line
		view.drag_selection_start, view.drag_selection_end = start, end
		return true
	}
	if normalized_click_count == 2 {
		start, end, range_ok := editor_word_selection_range(window, source_byte)
		if !range_ok {
			view.selection_anchor, view.caret_byte = source_byte, source_byte
			view.anchor_affinity, view.caret_affinity = affinity, affinity
			view.drag_selection_granularity = .Character
			view.drag_selection_start, view.drag_selection_end = source_byte, source_byte
			return true
		}
		view.selection_anchor, view.caret_byte = start, end
		view.anchor_affinity, view.caret_affinity = .Leading, .Trailing
		view.drag_selection_granularity = .Word
		view.drag_selection_start, view.drag_selection_end = start, end
		return true
	}
	view.drag_selection_granularity = .Character
	view.drag_selection_start, view.drag_selection_end = source_byte, source_byte
	if !shift { view.selection_anchor = source_byte; view.anchor_affinity = affinity }
	view.caret_byte, view.caret_affinity = source_byte, affinity
	return true
}

editor_extend_pointer_selection :: proc(
	view: ^Editor_View_State,
	window: ^Editor_Window,
	source_byte: u64,
	affinity: alicorn.Text_Affinity,
) -> bool {
	if view == nil || window == nil { return false }
	switch view.drag_selection_granularity {
	case .Word:
		start, end, range_ok := editor_word_selection_range(window, source_byte)
		if !range_ok { return false }
		if end <= view.drag_selection_start {
			view.selection_anchor, view.anchor_affinity = view.drag_selection_end, .Trailing
			view.caret_byte, view.caret_affinity = start, .Leading
		} else if start >= view.drag_selection_end {
			view.selection_anchor, view.anchor_affinity = view.drag_selection_start, .Leading
			view.caret_byte, view.caret_affinity = end, .Trailing
		} else {
			view.selection_anchor, view.caret_byte = view.drag_selection_start, view.drag_selection_end
			view.anchor_affinity, view.caret_affinity = .Leading, .Trailing
		}
	case .Line:
		line, found := editor_line_for_source(window, source_byte)
		if !found { return false }
		start, end, range_ok := editor_line_selection_range(window, line.logical_line)
		if !range_ok { return false }
		if end <= view.drag_selection_start {
			view.selection_anchor, view.anchor_affinity = view.drag_selection_end, .Trailing
			view.caret_byte, view.caret_affinity = start, .Leading
		} else if start >= view.drag_selection_end {
			view.selection_anchor, view.anchor_affinity = view.drag_selection_start, .Leading
			view.caret_byte, view.caret_affinity = end, .Trailing
		} else {
			view.selection_anchor, view.caret_byte = view.drag_selection_start, view.drag_selection_end
			view.anchor_affinity, view.caret_affinity = .Leading, .Trailing
		}
	case .Character:
		view.caret_byte, view.caret_affinity = source_byte, affinity
	}
	view.preferred_x_set = false
	return true
}

Editor_Edit_Selection_Snapshot :: struct {
	before_anchor_byte: u64,
	before_cursor_byte: u64,
	after_anchor_byte:  u64,
	after_cursor_byte:  u64,
}

editor_edit_selection_snapshot :: proc(
	view: ^Editor_View_State,
	after_anchor_byte, after_cursor_byte: u64,
) -> Editor_Edit_Selection_Snapshot {
	if view == nil { return {} }
	return Editor_Edit_Selection_Snapshot{
		before_anchor_byte=view.selection_anchor,
		before_cursor_byte=view.caret_byte,
		after_anchor_byte=after_anchor_byte,
		after_cursor_byte=after_cursor_byte,
	}
}

Editor_Edit_Intent :: struct {
	sequence:          u64,
	document_id:       string,
	base_editor_revision: u64,
	start_byte:        u64,
	end_byte:          u64,
	before_anchor_byte: u64,
	before_cursor_byte: u64,
	after_anchor_byte:  u64,
	after_cursor_byte:  u64,
	typing_group_id:    u64,
	replacement:       []u8,
	wire_replacement:  []u8,
}

EDITOR_TYPING_GROUP_PAUSE_NS :: i64(900_000_000)

editor_undo_group_break :: proc(view: ^Editor_View_State) {
	if view == nil { return }
	view.undo_group_id += 1
	if view.undo_group_id == 0 { view.undo_group_id = 1 }
	view.typing_group_active = false
}

editor_typing_group_id :: proc(view: ^Editor_View_State) -> u64 {
	if view == nil { return 0 }
	now := time.now()
	if !view.typing_group_active || time.duration_nanoseconds(time.since(view.last_typing_at)) > EDITOR_TYPING_GROUP_PAUSE_NS {
		editor_undo_group_break(view)
	}
	view.last_typing_at = now
	view.typing_group_active = true
	return view.undo_group_id
}

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
	return alicorn.text_run_build_with_overflow(
		&rt.text_engine,
		line.display,
		16,
		max_width,
		context.temp_allocator,
		context.temp_allocator,
		.Monospace,
		alicorn.FONT_WEIGHT_REGULAR,
		overflow,
		editable=true,
		text_style_spans=style_spans,
	)
}

editor_navigation_text_run :: proc(
	rt: ^alicorn.Runtime,
	window: ^Editor_Window,
	line: ^Editor_Display_Line,
	language: string,
	width: f32,
	presentation_current: bool,
) -> (run: alicorn.Text_Run, ok: bool) {
	if line == nil { return }
	style_spans: []alicorn.Text_Style_Span
	if presentation_current { style_spans = editor_presentation_text_styles_for_line(window, line, context.temp_allocator) }
	wrap := editor_line_should_wrap(language, window, line, presentation_current, width)
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
) -> (geometry: alicorn.Text_Caret_Geometry, visual_rows: int, run_height: f32, ok: bool) {
	if rt == nil || line == nil { return }
	position := alicorn.Text_Position{byte=editor_source_to_display(line, source_byte), affinity=affinity}
	if node, found := rt.nodes[text_node]; found && text_node != 0 {
		if node.active && node.text_run_valid && len(node.text_run.lines) > 0 {
			visual_rows, run_height = len(node.text_run.lines), node.text_run.height
			if measure_caret { geometry = alicorn.text_run_caret_geometry(&node.text_run, position, rt.scratch_allocator) }
			ok = visual_rows > 0
			return
		}
	}
	run, built := editor_navigation_text_run(rt, window, line, language, width, presentation_current)
	if !built { return }
	defer alicorn.text_run_destroy(&run)
	visual_rows, run_height = len(run.lines), run.height
	if measure_caret { geometry = alicorn.text_run_caret_geometry(&run, position, rt.scratch_allocator) }
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
) -> (source_byte: u64, affinity: alicorn.Text_Affinity, ok: bool) {
	if rt == nil || line == nil { return }
	position: alicorn.Text_Position
	if node, found := rt.nodes[text_node]; found && text_node != 0 && node.active && node.text_run_valid && len(node.text_run.lines) > 0 {
		y := visual_y
		if visual_row >= 0 {
			row := node.text_run.lines[clamp(visual_row, 0, len(node.text_run.lines)-1)]
			y = row.y+row.height*0.5
		}
		position = alicorn.text_run_hit_test(&node.text_run, visual_x, y, rt.scratch_allocator)
	} else {
		run, built := editor_navigation_text_run(rt, window, line, language, width, presentation_current)
		if !built { return }
		defer alicorn.text_run_destroy(&run)
		y := visual_y
		if visual_row >= 0 {
			row := run.lines[clamp(visual_row, 0, len(run.lines)-1)]
			y = row.y+row.height*0.5
		}
		position = alicorn.text_run_hit_test(&run, visual_x, y, rt.scratch_allocator)
	}
	source_byte = editor_normalize_source_position(line, editor_display_to_source(line, position.byte))
	affinity = position.affinity
	ok = true
	return
}

Editor_View_Restore :: struct {
	vertical:   bool,
	horizontal: bool,
	scroll_y:   f32,
	scroll_x:   f32,
}

editor_view_find :: proc(views: []Editor_View_State, document_id: string) -> int {
	for view, index in views {
		if view.document_id == document_id { return index }
	}
	return -1
}

editor_view_ensure :: proc(views: ^[dynamic]Editor_View_State, document_id: string, allocator := context.allocator) -> (index: int, ok: bool) {
	if views == nil || document_id == "" { return -1, false }
	if existing := editor_view_find(views[:], document_id); existing >= 0 { return existing, true }
	owned_id, clone_err := strings.clone(document_id, allocator)
	if clone_err != nil { return -1, false }
	append(views, Editor_View_State{document_id=owned_id, undo_group_id=1})
	return len(views)-1, true
}

editor_view_mark_active :: proc(view: ^Editor_View_State) {
	if view == nil { return }
	editor_undo_group_break(view)
	view.restore_y_pending = true
	view.restore_x_pending = true
}

// A preedit is frontend-only transient state. The original source selection is
// captured once and remains the replacement range for all subsequent IME
// updates and the eventual commit.
editor_preedit_update :: proc(
	view: ^Editor_View_State,
	text: string,
	selection_start, selection_end: int,
	allocator := context.allocator,
) -> bool {
	if view == nil || len(text) == 0 || view.preedit_recoverable { return false }
	if !view.preedit_active {
		view.preedit_replace_start = min(view.selection_anchor, view.caret_byte)
		view.preedit_replace_end = max(view.selection_anchor, view.caret_byte)
	}
	if !editor_preedit_replace_text(view, text, selection_start, selection_end, allocator) { return false }
	view.preedit_recoverable = false
	return true
}

editor_preedit_replace_text :: proc(
	view: ^Editor_View_State,
	text: string,
	selection_start, selection_end: int,
	allocator := context.allocator,
) -> bool {
	if view == nil || len(text) == 0 { return false }
	bytes, allocation_error := make([]u8, len(text), allocator=allocator)
	if allocation_error != nil { return false }
	mem.copy(rawptr(&bytes[0]), rawptr(raw_data(text)), len(text))
	if len(view.preedit_recovery_storage) > 0 {
		delete(view.preedit_recovery_storage, allocator)
		view.preedit_recovery_storage = {}
	} else if len(view.preedit_text) > 0 {
		delete(view.preedit_text, allocator)
	}
	view.preedit_text = bytes
	view.preedit_active = true
	view.preedit_selection_start = min(max(selection_start, 0), len(bytes))
	view.preedit_selection_end = min(max(selection_end, 0), len(bytes))
	return true
}

// A failed committed event is retained verbatim. For a normal-sized event,
// reserve the edit limit once so later commits can append in O(1) each. If the
// initial committed event already exceeds that bound, preserve it and allow no
// further growth.
editor_preedit_make_recoverable :: proc(
	view: ^Editor_View_State,
	text: string,
	start_byte, end_byte: u64,
	allocator := context.allocator,
) -> bool {
	if view == nil || len(text) == 0 { return false }
	capacity := max(len(text), EDITOR_IME_RECOVERY_MAX_BYTES)
	storage, allocation_error := make([]u8, capacity, allocator=allocator)
	if allocation_error != nil { return false }
	mem.copy(rawptr(&storage[0]), rawptr(raw_data(text)), len(text))
	if len(view.preedit_recovery_storage) > 0 {
		delete(view.preedit_recovery_storage, allocator)
	} else if len(view.preedit_text) > 0 {
		delete(view.preedit_text, allocator)
	}
	view.preedit_recovery_storage = storage
	view.preedit_text = storage[:len(text)]
	view.preedit_active = true
	view.preedit_recoverable = true
	view.preedit_replace_start = start_byte
	view.preedit_replace_end = end_byte
	view.preedit_selection_start = 0
	view.preedit_selection_end = len(text)
	return true
}

editor_preedit_append_recovery :: proc(
	view: ^Editor_View_State,
	text: string,
	allocator := context.allocator,
) -> bool {
	if view == nil || !view.preedit_recoverable || len(view.preedit_recovery_storage) == 0 { return false }
	if len(text) == 0 { return true }
	current_length := len(view.preedit_text)
	if current_length >= EDITOR_IME_RECOVERY_MAX_BYTES || current_length > len(view.preedit_recovery_storage) {
		return false
	}
	new_length := current_length+len(text)
	if new_length > len(view.preedit_recovery_storage) {
		// Keep the commit that crosses the soft recovery limit, then suspend
		// native input immediately. At most one delivered event can grow this
		// buffer beyond the limit; later commits are refused without reallocating.
		storage, allocation_error := make([]u8, new_length, allocator=allocator)
		if allocation_error != nil { return false }
		mem.copy(rawptr(&storage[0]), rawptr(raw_data(view.preedit_text)), current_length)
		delete(view.preedit_recovery_storage, allocator)
		view.preedit_recovery_storage = storage
	}
	mem.copy(rawptr(&view.preedit_recovery_storage[current_length]), rawptr(raw_data(text)), len(text))
	view.preedit_text = view.preedit_recovery_storage[:new_length]
	view.preedit_selection_start = 0
	view.preedit_selection_end = len(view.preedit_text)
	return true
}

editor_preedit_recovery_is_full :: proc(view: ^Editor_View_State) -> bool {
	return view != nil && view.preedit_recoverable && len(view.preedit_text) >= EDITOR_IME_RECOVERY_MAX_BYTES
}

// A document switch cancels ordinary platform composition, but must retain a
// committed composition that Alicorn could not enqueue. That text is the only
// remaining copy until the user explicitly copies it for recovery.
editor_preedit_clear_for_document_switch :: proc(view: ^Editor_View_State, allocator := context.allocator) {
	if view == nil || view.preedit_recoverable { return }
	editor_preedit_clear(view, allocator)
}

editor_preedit_clear :: proc(view: ^Editor_View_State, allocator := context.allocator) {
	if view == nil { return }
	if len(view.preedit_recovery_storage) > 0 {
		delete(view.preedit_recovery_storage, allocator)
	} else if len(view.preedit_text) > 0 {
		delete(view.preedit_text, allocator)
	}
	view.preedit_text = {}
	view.preedit_active = false
	view.preedit_recoverable = false
	view.preedit_recovery_storage = {}
	view.preedit_replace_start = 0
	view.preedit_replace_end = 0
	view.preedit_selection_start = 0
	view.preedit_selection_end = 0
}

editor_preedit_take_replace_range :: proc(
	view: ^Editor_View_State,
	selection_anchor, caret_byte: u64,
	allocator := context.allocator,
) -> (start_byte, end_byte: u64) {
	if view != nil && view.preedit_active {
		start_byte, end_byte = view.preedit_replace_start, view.preedit_replace_end
		editor_preedit_clear(view, allocator)
		return
	}
	return min(selection_anchor, caret_byte), max(selection_anchor, caret_byte)
}

editor_preedit_display_for_line :: proc(
	view: ^Editor_View_State,
	window: ^Editor_Window,
	line: ^Editor_Display_Line,
	allocator := context.temp_allocator,
) -> (display: string, selection_start, selection_end: int, applies: bool) {
	if view == nil || !view.preedit_active || window == nil || line == nil || len(view.preedit_text) == 0 {
		return
	}
	start_line, start_found := editor_line_for_source(window, view.preedit_replace_start)
	end_line, end_found := editor_line_for_source(window, view.preedit_replace_end)
	if !start_found || !end_found { return }
	if line.logical_line < start_line.logical_line || line.logical_line > end_line.logical_line { return }
	if line.logical_line != start_line.logical_line {
		// The replaced portion is temporarily hidden from later selected rows;
		// the suffix from the selection's final row is joined after preedit.
		return "", 0, 0, true
	}
	start_display := editor_source_to_display(start_line, view.preedit_replace_start)
	end_display := editor_source_to_display(end_line, view.preedit_replace_end)
	if start_display < 0 || start_display > len(start_line.display) || end_display < 0 || end_display > len(end_line.display) {
		return
	}
	prefix := start_line.display[:start_display]
	suffix := end_line.display[end_display:]
	display = fmt.aprintf("%s%s%s", prefix, string(view.preedit_text), suffix, allocator=allocator)
	selection_start = start_display + min(max(view.preedit_selection_start, 0), len(view.preedit_text))
	selection_end = start_display + min(max(view.preedit_selection_end, 0), len(view.preedit_text))
	return display, selection_start, selection_end, true
}

// Keep the widest intrinsic no-wrap content seen for this editor revision.
// Viewport width is applied separately so a previously wider window cannot
// leave a bogus horizontal scrollbar after resize.
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

editor_view_remove :: proc(views: ^[dynamic]Editor_View_State, index: int, allocator := context.allocator) {
	if views == nil || index < 0 || index >= len(views) { return }
	editor_preedit_clear(&views[index], allocator)
	if views[index].optimistic_window_ready {
		editor_window_destroy(&views[index].optimistic_window, allocator)
	}
	if views[index].wrap_height_index_ready {
		alicorn.virtual_list_height_index_destroy(&views[index].wrap_height_index)
	}
	delete(views[index].document_id, allocator)
	ordered_remove(views, index)
}

editor_views_destroy :: proc(views: ^[dynamic]Editor_View_State, allocator := context.allocator) {
	if views == nil { return }
	for &view in views {
		editor_preedit_clear(&view, allocator)
		if view.optimistic_window_ready { editor_window_destroy(&view.optimistic_window, allocator) }
		if view.wrap_height_index_ready { alicorn.virtual_list_height_index_destroy(&view.wrap_height_index) }
		if len(view.document_id) > 0 { delete(view.document_id, allocator) }
	}
	delete(views^)
	views^ = {}
}

editor_edit_intent_destroy :: proc(intent: ^Editor_Edit_Intent, allocator := context.allocator) {
	if intent == nil { return }
	if len(intent.document_id) > 0 { delete(intent.document_id, allocator) }
	delete(intent.replacement, allocator)
	delete(intent.wire_replacement, allocator)
	intent^ = {}
}

editor_hex_digit :: proc(value: u8) -> u8 {
	if value < 10 { return '0' + value }
	return 'A' + (value-10)
}

editor_utf8_sequence_length :: proc(source: []u8, index: int) -> int {
	if index >= len(source) { return 0 }
	c0 := source[index]
	if c0 < 0x80 { return 1 }
	if c0 >= 0xC2 && c0 <= 0xDF {
		if index+1 < len(source) && source[index+1] >= 0x80 && source[index+1] <= 0xBF { return 2 }
		return 0
	}
	if c0 >= 0xE0 && c0 <= 0xEF {
		if index+2 >= len(source) { return 0 }
		c1, c2 := source[index+1], source[index+2]
		if c2 < 0x80 || c2 > 0xBF { return 0 }
		if c0 == 0xE0 { return 3 if c1 >= 0xA0 && c1 <= 0xBF else 0 }
		if c0 == 0xED { return 3 if c1 >= 0x80 && c1 <= 0x9F else 0 }
		return 3 if c1 >= 0x80 && c1 <= 0xBF else 0
	}
	if c0 >= 0xF0 && c0 <= 0xF4 {
		if index+3 >= len(source) { return 0 }
		c1, c2, c3 := source[index+1], source[index+2], source[index+3]
		if c2 < 0x80 || c2 > 0xBF || c3 < 0x80 || c3 > 0xBF { return 0 }
		if c0 == 0xF0 { return 4 if c1 >= 0x90 && c1 <= 0xBF else 0 }
		if c0 == 0xF4 { return 4 if c1 >= 0x80 && c1 <= 0x8F else 0 }
		return 4 if c1 >= 0x80 && c1 <= 0xBF else 0
	}
	return 0
}

editor_emit_display_byte :: proc(output: ^[dynamic]u8, offsets: ^[dynamic]u64, value: u8, source_boundary: u64) {
	append(output, value)
	append(offsets, source_boundary)
}

editor_project_line :: proc(
	source: []u8,
	source_start: u64,
	logical_line: u64,
	allocator := context.allocator,
) -> (line: Editor_Display_Line, ok: bool) {
	output := make([dynamic]u8, 0, allocator=allocator)
	offsets := make([dynamic]u64, 0, allocator=allocator)
	defer delete(output)
	append(&offsets, source_start)
	index := 0
	column := 0
	if logical_line == 0 && source_start == 0 && len(source) >= 3 && source[0] == 0xEF && source[1] == 0xBB && source[2] == 0xBF {
		index = 3
		offsets[0] = 3
	}
	for index < len(source) {
		value := source[index]
		absolute := source_start + u64(index)
		if value == '\t' {
			spaces := EDITOR_TAB_WIDTH - column % EDITOR_TAB_WIDTH
			for space in 0..<spaces {
				boundary := absolute
				if space == spaces-1 { boundary += 1 }
				editor_emit_display_byte(&output, &offsets, ' ', boundary)
			}
			column += spaces
			index += 1
			continue
		}
		sequence_length := editor_utf8_sequence_length(source, index)
		if sequence_length == 1 && (value < 0x20 || value == 0x7F) || sequence_length == 0 {
			editor_emit_display_byte(&output, &offsets, '\\', absolute)
			editor_emit_display_byte(&output, &offsets, 'x', absolute)
			editor_emit_display_byte(&output, &offsets, editor_hex_digit(value >> 4), absolute)
			editor_emit_display_byte(&output, &offsets, editor_hex_digit(value & 0x0F), absolute+1)
			column += 4
			index += 1
			continue
		}
		for byte_index in 0..<sequence_length {
			editor_emit_display_byte(&output, &offsets, source[index+byte_index], absolute+u64(byte_index)+1)
		}
		column += 1
		index += sequence_length
	}
	display, clone_err := strings.clone(string(output[:]), allocator)
	if clone_err != nil { delete(offsets); return {}, false }
	return Editor_Display_Line{
		logical_line=logical_line,
		source_start=source_start,
		source_end=source_start+u64(len(source)),
		display=display,
		display_bytes=offsets[:],
	}, true
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
editor_display_to_source :: proc(line: ^Editor_Display_Line, display_byte: int) -> u64 {
	if line == nil || len(line.display_bytes) == 0 { return 0 }
	position := min(max(display_byte, 0), len(line.display_bytes)-1)
	if position == len(line.display_bytes)-1 { return line.display_bytes[position] }
	source := line.display_bytes[position]
	first := position
	for first > 0 && line.display_bytes[first-1] == source { first -= 1 }
	last := position
	for last+1 < len(line.display_bytes) && line.display_bytes[last+1] == source { last += 1 }
	if first == 0 || last+1 >= len(line.display_bytes) { return source }
	next_source := line.display_bytes[last+1]
	if next_source <= source { return source }
	// The repeated run spans the display boundaries from `first` through
	// `last+1`; choose before/after based on the clicked boundary's midpoint.
	if (position-first)*2 < last+1-first { return source }
	return next_source
}

// editor_source_to_display returns the first visible display boundary for a
// source position. If the source boundary is omitted (e.g. inside a BOM), it
// chooses the nearest visible boundary, preferring the leading side on ties.
editor_source_to_display :: proc(line: ^Editor_Display_Line, source_byte: u64) -> int {
	if line == nil || len(line.display_bytes) == 0 { return 0 }
	best_index := 0
	first_boundary := line.display_bytes[0]
	best_distance := first_boundary-source_byte if first_boundary >= source_byte else source_byte-first_boundary
	for boundary, index in line.display_bytes {
		if boundary == source_byte { return index }
		distance := boundary-source_byte if boundary >= source_byte else source_byte-boundary
		if distance < best_distance {
			best_distance = distance
			best_index = index
		}
	}
	return best_index
}

// editor_normalize_source_position maps an arbitrary byte coordinate onto a
// visible, legal projection boundary. It is used for initial positions and
// for transformed regions such as a hidden BOM.
editor_normalize_source_position :: proc(line: ^Editor_Display_Line, source_byte: u64) -> u64 {
	return editor_display_to_source(line, editor_source_to_display(line, source_byte))
}

// Source spans remain the only coordinate authority. This mapper converts
// source-byte coverage into display-byte coverage, including every repeated
// boundary used to spell tabs and malformed bytes visibly.
editor_source_range_to_display :: proc(line: ^Editor_Display_Line, start_byte, end_byte: u64) -> (start, end: int, ok: bool) {
	if line == nil || end_byte <= start_byte || len(line.display_bytes) < 2 { return }
	first := len(line.display)
	last := 0
	for index in 0..<len(line.display_bytes)-1 {
		left := line.display_bytes[index]
		right := line.display_bytes[index+1]
		covered := false
		if left == right {
			covered = left >= start_byte && left < end_byte
		} else {
			covered = min(left, right) < end_byte && max(left, right) > start_byte
		}
		if covered {
			first = min(first, index)
			last = max(last, index+1)
		}
	}
	if first >= last { return }
	return first, last, true
}

editor_presentation_record_color :: proc(kind: u32) -> (color: alicorn.Color, color_set: bool) {
	switch kind {
	case EDITOR_PRESENTATION_HEADING:
		return {}, false
	case EDITOR_PRESENTATION_STRONG:
		return alicorn.Color{0.86, 0.9, 1.0, 1}, true
	case EDITOR_PRESENTATION_EMPHASIS:
		return alicorn.Color{0.72, 0.79, 0.91, 1}, true
	case EDITOR_PRESENTATION_INLINE_CODE:
		return alicorn.Color{0.76, 0.84, 1.0, 1}, true
	case EDITOR_PRESENTATION_LINK:
		return alicorn.Color{0.38, 0.72, 1.0, 1}, true
	case EDITOR_PRESENTATION_CODE_BLOCK:
		return alicorn.Color{0.73, 0.82, 0.95, 1}, true
	case 9, 28, 31: // quote marker, thematic break, table delimiter
		return alicorn.Color{0.57, 0.63, 0.74, 1}, true
	case EDITOR_PRESENTATION_LIST_MARKER:
		return alicorn.Color{0.62, 0.75, 0.94, 1}, true
	case EDITOR_PRESENTATION_TASK_MARKER:
		return alicorn.Color{0.44, 0.8, 1.0, 1}, true
	case 12: // code comment
		return alicorn.Color{0.48, 0.69, 0.57, 1}, true
	case 13: // code keyword
		return alicorn.Color{0.78, 0.62, 1.0, 1}, true
	case 14: // code string
		return alicorn.Color{0.86, 0.72, 0.49, 1}, true
	case 15: // code number
		return alicorn.Color{0.54, 0.78, 0.9, 1}, true
	case 16: // code type
		return alicorn.Color{0.42, 0.8, 0.76, 1}, true
	case 17, 18: // function and method
		return alicorn.Color{0.48, 0.72, 0.98, 1}, true
	case 29: // table
		return alicorn.Color{0.76, 0.81, 0.9, 1}, true
	case 30: // table header
		return alicorn.Color{0.87, 0.9, 1.0, 1}, true
	case 32: // table pipe
		return alicorn.Color{0.43, 0.5, 0.63, 1}, true
	case:
		return {}, false
	}
}

Editor_Markdown_Row_Presentation :: struct {
	heading_level: u32,
	code_block: bool,
	blockquote: bool,
	list_item: bool,
	thematic_break: bool,
	table: bool,
	table_header: bool,
	table_delimiter: bool,
	task_marker: bool,
}

editor_presentation_range_intersects_line :: proc(
	line: ^Editor_Display_Line,
	start_byte, end_byte: u64,
) -> bool {
	if line == nil || end_byte <= start_byte { return false }
	if start_byte < line.source_end && end_byte > line.source_start { return true }
	// Empty Markdown rows still occupy source positions inside block ranges.
	return line.source_start == line.source_end && line.source_start >= start_byte && line.source_start < end_byte
}

editor_markdown_row_presentation :: proc(
	window: ^Editor_Window,
	line: ^Editor_Display_Line,
	current: bool,
) -> Editor_Markdown_Row_Presentation {
	result: Editor_Markdown_Row_Presentation
	if window == nil || line == nil || !current || !window.presentation_ready ||
	   (!window.presentation_stale && window.presentation_revision != window.editor_revision) { return result }
	window_end := window.start_byte+u64(len(window.source))
	for record in window.presentation_spans {
		start_byte := window.start_byte+u64(record.start_byte)
		end_byte := window.start_byte+u64(record.end_byte)
		if end_byte > window_end || !editor_presentation_range_intersects_line(line, start_byte, end_byte) { continue }
		switch record.kind {
		case EDITOR_PRESENTATION_HEADING:
			level := record.level_flags & 0xFF
			if level >= 1 && level <= 6 && level > result.heading_level { result.heading_level = level }
		case EDITOR_PRESENTATION_TABLE_HEADER:
			result.table_header = true
		case EDITOR_PRESENTATION_TABLE_DELIMITER:
			result.table_delimiter = true
		case EDITOR_PRESENTATION_TASK_MARKER:
			result.task_marker = true
		}
	}
	for record in window.presentation_blocks {
		start_byte := window.start_byte+u64(record.start_byte)
		end_byte := window.start_byte+u64(record.end_byte)
		if end_byte > window_end || !editor_presentation_range_intersects_line(line, start_byte, end_byte) { continue }
		switch record.kind {
		case EDITOR_PRESENTATION_BLOCK_CODE: result.code_block = true
		case EDITOR_PRESENTATION_BLOCK_QUOTE: result.blockquote = true
		case EDITOR_PRESENTATION_BLOCK_LIST: result.list_item = true
		case EDITOR_PRESENTATION_BLOCK_THEMATIC: result.thematic_break = true
		case EDITOR_PRESENTATION_BLOCK_TABLE: result.table = true
		}
	}
	return result
}

editor_markdown_heading_color :: proc(level: u32) -> alicorn.Color {
	switch level {
	case 1: return alicorn.Color{0.58, 0.78, 1.0, 1}
	case 2: return alicorn.Color{0.55, 0.74, 0.96, 1}
	case 3: return alicorn.Color{0.58, 0.73, 0.91, 1}
	case 4: return alicorn.Color{0.63, 0.74, 0.88, 1}
	case 5: return alicorn.Color{0.66, 0.74, 0.85, 1}
	case 6: return alicorn.Color{0.69, 0.75, 0.84, 1}
	case: return alicorn.Color{0.55, 0.76, 1.0, 1}
	}
}

editor_markdown_row_background :: proc(row: Editor_Markdown_Row_Presentation) -> alicorn.Color {
	// Keep the source surface calm. Markdown hierarchy comes from typography,
	// markers, and spacing; full-width semantic bands compete with selection.
	return alicorn.NO_BACKGROUND_COLOR
}

editor_markdown_row_extra_height :: proc(row: Editor_Markdown_Row_Presentation) -> f32 {
	extra: f32 = 0
	switch row.heading_level {
	case 1: extra = 20
	case 2: extra = 14
	case 3: extra = 9
	case 4: extra = 6
	case 5: extra = 4
	case 6: extra = 3
	case: extra = 0
	}
	if extra > 0 { return extra }
	if row.thematic_break { return 6 }
	if row.table_header { return 4 }
	return 0
}

// Markdown typography is applied over source-derived display bytes; block
// hierarchy affects measured row geometry independently of source text.
editor_presentation_text_styles_for_line :: proc(window: ^Editor_Window, line: ^Editor_Display_Line, allocator := context.temp_allocator) -> []alicorn.Text_Style_Span {
	result := make([dynamic]alicorn.Text_Style_Span, 0, allocator=allocator)
	if window == nil || line == nil || !window.presentation_ready ||
	   (!window.presentation_stale && window.presentation_revision != window.editor_revision) { return result[:] }
	window_end := window.start_byte+u64(len(window.source))
	for record in window.presentation_spans {
		weight: f32
		weight_set := false
		italic := false
		italic_set := false
		switch record.kind {
		case EDITOR_PRESENTATION_HEADING:
			switch record.level_flags & 0xFF {
			case 1: weight = alicorn.FONT_WEIGHT_SEMIBOLD
			case 2: weight = alicorn.FONT_WEIGHT_MEDIUM
			case 3: weight = 450
			case 4: weight = 430
			case 5: weight = 415
			case 6: weight = alicorn.FONT_WEIGHT_REGULAR
			case: continue
			}
			weight_set = true
		case EDITOR_PRESENTATION_STRONG:
			weight = alicorn.FONT_WEIGHT_BOLD
			weight_set = true
		case EDITOR_PRESENTATION_EMPHASIS:
			italic = true
			italic_set = true
		case EDITOR_PRESENTATION_LIST_MARKER:
			weight = alicorn.FONT_WEIGHT_SEMIBOLD
			weight_set = true
		case EDITOR_PRESENTATION_TASK_MARKER:
			weight = alicorn.FONT_WEIGHT_BOLD
			weight_set = true
		case EDITOR_PRESENTATION_TABLE_HEADER:
			weight = alicorn.FONT_WEIGHT_BOLD
			weight_set = true
		case:
			continue
		}
		absolute_start := window.start_byte+u64(record.start_byte)
		absolute_end := window.start_byte+u64(record.end_byte)
		start_byte := max(absolute_start, line.source_start)
		end_byte := min(absolute_end, line.source_end)
		if absolute_end > window_end || end_byte <= start_byte { continue }
		start, end, mapped := editor_source_range_to_display(line, start_byte, end_byte)
		if !mapped { continue }
		append(&result, alicorn.Text_Style_Span{
			start=start,
			end=end,
			font_weight=weight,
			font_weight_set=weight_set,
			italic=italic,
			italic_set=italic_set,
		})
	}
	return result[:]
}

editor_presentation_spans_for_line :: proc(window: ^Editor_Window, line: ^Editor_Display_Line, allocator := context.temp_allocator) -> []alicorn.Text_Paint_Span {
	result := make([dynamic]alicorn.Text_Paint_Span, 0, allocator=allocator)
	if window == nil || line == nil || !window.presentation_ready ||
	   (!window.presentation_stale && window.presentation_revision != window.editor_revision) { return result[:] }
	window_end := window.start_byte+u64(len(window.source))
	// Keep block treatment behind source characters only; full-width row fills
	// stay off so selection and the writing surface remain visually quiet.
	for record in window.presentation_blocks {
		absolute_start := window.start_byte+u64(record.start_byte)
		absolute_end := window.start_byte+u64(record.end_byte)
		start_byte := max(absolute_start, line.source_start)
		end_byte := min(absolute_end, line.source_end)
		if absolute_end > window_end || end_byte <= start_byte { continue }
		start, end, mapped := editor_source_range_to_display(line, start_byte, end_byte)
		if !mapped { continue }
		paint := alicorn.Text_Paint_Span{start=start, end=end}
		switch record.kind {
		case EDITOR_PRESENTATION_BLOCK_CODE:
			paint.background = alicorn.Color{0.09, 0.11, 0.16, 0.48}
			paint.background_set = true
		case EDITOR_PRESENTATION_BLOCK_QUOTE:
			paint.background = alicorn.Color{0.18, 0.22, 0.31, 0.34}
			paint.background_set = true
		case EDITOR_PRESENTATION_BLOCK_THEMATIC:
			paint.background = alicorn.Color{0.22, 0.26, 0.35, 0.32}
			paint.background_set = true
		}
		if paint.background_set { append(&result, paint) }
	}
	for record in window.presentation_spans {
		absolute_start := window.start_byte+u64(record.start_byte)
		absolute_end := window.start_byte+u64(record.end_byte)
		start_byte := max(absolute_start, line.source_start)
		end_byte := min(absolute_end, line.source_end)
		if absolute_end > window_end || end_byte <= start_byte { continue }
		start, end, mapped := editor_source_range_to_display(line, start_byte, end_byte)
		if !mapped { continue }
		color, color_set := editor_presentation_record_color(record.kind)
		if record.kind == EDITOR_PRESENTATION_HEADING {
			level := record.level_flags & 0xFF
			if level >= 1 && level <= 6 {
				color, color_set = editor_markdown_heading_color(level), true
			}
		}
		paint := alicorn.Text_Paint_Span{start=start, end=end, color=color, color_set=color_set}
		switch record.kind {
		case EDITOR_PRESENTATION_INLINE_CODE:
			paint.background = alicorn.Color{0.2, 0.24, 0.34, 0.76}
			paint.background_set = true
		case EDITOR_PRESENTATION_TASK_MARKER:
			paint.background = alicorn.Color{0.12, 0.25, 0.38, 0.84}
			paint.background_set = true
		case EDITOR_PRESENTATION_LINK:
			paint.underline = true
		case EDITOR_PRESENTATION_STRIKE:
			paint.strikethrough = true
		}
		if paint.color_set || paint.underline || paint.strikethrough || paint.background_set { append(&result, paint) }
	}
	return result[:]
}

editor_line_for_source :: proc(window: ^Editor_Window, source_byte: u64) -> (line: ^Editor_Display_Line, found: bool) {
	if window == nil { return nil, false }
	for &candidate in window.lines {
		if source_byte >= candidate.source_start && source_byte <= candidate.source_end {
			return &candidate, true
		}
	}
	return nil, false
}

// editor_reconcile_source_position keeps a frontend-local position legal after
// an optimistic chain is rejected and a newer authoritative window arrives.
editor_reconcile_source_position :: proc(
	window: ^Editor_Window,
	source_byte: u64,
) -> (position: u64, affinity: alicorn.Text_Affinity) {
	if window == nil || len(window.lines) == 0 { return source_byte, .Trailing }
	window_end := window.start_byte+u64(len(window.source))
	target := min(max(source_byte, window.start_byte), window_end)
	position = target
	if line, found := editor_line_for_source(window, position); found {
		position = editor_normalize_source_position(line, position)
		if position == line.source_start { affinity = .Leading } else { affinity = .Trailing }
		return
	}
	best_distance := window_end-window.start_byte+1
	for line in window.lines {
		for boundary_index in 0..<2 {
			boundary := line.source_start if boundary_index == 0 else line.source_end
			distance := boundary-target if boundary >= target else target-boundary
			if distance < best_distance {
				best_distance = distance
				position = boundary
				affinity = .Trailing if boundary == line.source_end else .Leading
			}
		}
	}
	return
}

editor_view_reconcile_positions :: proc(view: ^Editor_View_State, window: ^Editor_Window) -> bool {
	if view == nil || window == nil || !view.position_reconcile_pending { return false }
	view.caret_byte, view.caret_affinity = editor_reconcile_source_position(window, view.caret_byte)
	view.selection_anchor, view.anchor_affinity = editor_reconcile_source_position(window, view.selection_anchor)
	view.position_reconcile_pending = false
	return true
}

// A document-edge key may target a line outside the bounded source window.
// Keep the intent frontend-local until the corresponding window is installed.
editor_view_resolve_document_edge :: proc(
	view: ^Editor_View_State,
	window: ^Editor_Window,
	line_count: u64,
) -> bool {
	if view == nil || window == nil || view.pending_document_edge == .None || line_count == 0 { return false }
	target_line := u64(0) if view.pending_document_edge == .Start else line_count-1
	line, found := editor_window_line(window, target_line)
	if !found { return false }
	position := line.source_start
	affinity: alicorn.Text_Affinity = .Leading
	if view.pending_document_edge == .End {
		position = line.source_end
		affinity = .Trailing
	}
	position = editor_normalize_source_position(line, position)
	view.caret_byte = position
	view.caret_affinity = affinity
	if !view.pending_document_edge_shift {
		view.selection_anchor = position
		view.anchor_affinity = affinity
	}
	view.pending_document_edge = .None
	view.pending_document_edge_shift = false
	view.preferred_x_set = false
	return true
}

editor_position_after_delete :: proc(position, start_byte, end_byte: u64) -> u64 {
	if position <= start_byte { return position }
	if position >= end_byte { return position-(end_byte-start_byte) }
	return start_byte
}

// Returns the exact source bytes only when the complete selection is inside
// this bounded window. Clipboard commands must not copy or cut a partial range.
editor_selected_source_bytes :: proc(
	window: ^Editor_Window,
	selection_anchor, caret_byte: u64,
) -> (bytes: []u8, available: bool) {
	if window == nil { return {}, false }
	start_byte := min(selection_anchor, caret_byte)
	end_byte := max(selection_anchor, caret_byte)
	window_end := window.start_byte+u64(len(window.source))
	if start_byte < window.start_byte || end_byte > window_end || end_byte < start_byte { return {}, false }
	local_start := int(start_byte-window.start_byte)
	local_end := int(end_byte-window.start_byte)
	return window.source[local_start:local_end], true
}

editor_source_bytes_valid_utf8 :: proc(bytes: []u8) -> bool {
	index := 0
	for index < len(bytes) {
		value, width := utf8.decode_rune_in_bytes(bytes[index:])
		if width <= 0 || (value == utf8.RUNE_ERROR && width == 1 && bytes[index] >= 0x80) { return false }
		index += width
	}
	return true
}

editor_select_all :: proc(view: ^Editor_View_State, document_byte_length: u64) {
	if view == nil { return }
	editor_preedit_clear(view)
	view.pending_document_edge = .None
	view.pending_document_edge_shift = false
	view.selection_anchor = 0
	view.caret_byte = document_byte_length
	view.anchor_affinity = .Leading
	view.caret_affinity = .Trailing
	view.preferred_x_set = false
}

// editor_move_horizontal moves by Runa grapheme boundaries in the projected
// row, then maps back to source. Synthetic display spans can expose several
// visual boundaries for one source byte; those are skipped atomically.
editor_move_horizontal :: proc(
	line: ^Editor_Display_Line,
	source_byte: u64,
	affinity: alicorn.Text_Affinity,
	direction: int,
) -> (next_source: u64, next_affinity: alicorn.Text_Affinity, moved: bool) {
	if line == nil || direction == 0 { return source_byte, affinity, false }
	display_byte := editor_source_to_display(line, source_byte)
	position := alicorn.Text_Position{byte=display_byte, affinity=affinity}
	for _ in 0..<max(len(line.display), 1) {
		next := alicorn.text_move_logical(line.display, position, direction)
		if next.byte == position.byte { break }
		mapped := editor_display_to_source(line, next.byte)
		if mapped != source_byte {
			return mapped, next.affinity, true
		}
		position = next
	}
	return source_byte, affinity, false
}

// editor_move_word_source applies Alicorn/Runa's Unicode word segmentation to
// the projected row, then maps the result back to a legal Scratchpad source
// boundary. At a row edge it crosses one logical line boundary as a unit.
editor_move_word_source :: proc(
	window: ^Editor_Window,
	source_byte: u64,
	affinity: alicorn.Text_Affinity,
	direction: int,
) -> (next_source: u64, next_affinity: alicorn.Text_Affinity, moved: bool) {
	if window == nil || direction == 0 { return source_byte, affinity, false }
	line, found := editor_line_for_source(window, source_byte)
	if !found { return source_byte, affinity, false }
	position := alicorn.Text_Position{
		byte=editor_source_to_display(line, source_byte),
		affinity=affinity,
	}
	next := alicorn.text_move_word(line.display, position, direction, context.temp_allocator)
	mapped := editor_normalize_source_position(line, editor_display_to_source(line, next.byte))
	if mapped != source_byte { return mapped, next.affinity, true }

	if direction < 0 && source_byte == line.source_start && line.logical_line > window.start_line {
		previous, previous_found := editor_window_line(window, line.logical_line-1)
		if previous_found {
			end_position := alicorn.Text_Position{byte=len(previous.display), affinity=.Trailing}
			word_start := alicorn.text_move_word(previous.display, end_position, -1, context.temp_allocator)
			mapped = editor_normalize_source_position(previous, editor_display_to_source(previous, word_start.byte))
			return mapped, .Trailing, mapped != source_byte
		}
	}
	if direction > 0 && source_byte == line.source_end {
		following, following_found := editor_window_line(window, line.logical_line+1)
		if following_found {
			start_position := alicorn.Text_Position{byte=0, affinity=.Leading}
			word_end := alicorn.text_move_word(following.display, start_position, 1, context.temp_allocator)
			mapped = editor_normalize_source_position(following, editor_display_to_source(following, word_end.byte))
			return mapped, .Leading, mapped != source_byte
		}
	}
	return source_byte, affinity, false
}

editor_window_destroy :: proc(window: ^Editor_Window, allocator := context.allocator) {
	if window == nil { return }
	if len(window.document_id) > 0 { delete(window.document_id, allocator) }
	if len(window.source) > 0 { delete(window.source, allocator) }
	for &line in window.lines {
		if len(line.display) > 0 { delete(line.display, allocator) }
		delete(line.display_bytes, allocator)
	}
	delete(window.presentation_spans, allocator)
	delete(window.presentation_blocks, allocator)
	delete(window.lines)
	window^ = {}
}

editor_window_clone :: proc(source: ^Editor_Window, allocator := context.allocator) -> (window: Editor_Window, ok: bool, message: string) {
	if source == nil || source.document_id == "" {
		return {}, false, "editor window is unavailable for optimistic editing"
	}
	bytes, allocation_error := make([]u8, len(source.source), allocator=allocator)
	if allocation_error != nil { return {}, false, "could not retain the bounded optimistic source window" }
	if len(bytes) > 0 { mem.copy(rawptr(&bytes[0]), rawptr(&source.source[0]), len(bytes)) }
	visible := bridge.Visible_Window{
		document_id=source.document_id,
		application_rev=source.application_rev,
		editor_revision=source.editor_revision,
		start_line=source.start_line,
		end_line=source.end_line,
		start_byte=source.start_byte,
		line_byte_length=source.line_byte_length,
		has_source_anchor=source.has_source_anchor,
		source_anchor_byte=source.source_anchor_byte,
		source_anchor_line=source.source_anchor_line,
		truncated=source.truncated,
		source=bytes,
	}
	return editor_window_from_visible(&visible, allocator)
}

// editor_view_window resolves only an exact edit-authoritative window. It is
// deliberately observational: asking whether the current source is editable
// must not discard a stale snapshot that still carries the latest visible UI.
editor_view_window :: proc(
	view: ^Editor_View_State,
	base: ^Editor_Window,
	base_ready: bool,
	document_id: string,
	editor_revision: u64,
) -> (window: ^Editor_Window, matches: bool) {
	if view != nil && view.optimistic_window_ready {
		if view.optimistic_window.document_id == document_id &&
		   (view.optimistic_pending_edits > 0 || view.optimistic_window.editor_revision == editor_revision) {
			return &view.optimistic_window, true
		}
	}
	if base_ready && base != nil && base.document_id == document_id && base.editor_revision == editor_revision {
		return base, true
	}
	return nil, false
}

// editor_enter_projection mirrors the visible part of ScratchEditor.Enter for
// immediate presentation. The actual command remains a literal LF so Go
// chooses the authoritative document line ending and indentation; the edit
// acknowledgement reconciles any difference in this prediction.
editor_enter_projection :: proc(
	window: ^Editor_Window,
	line: ^Editor_Display_Line,
	allocator := context.temp_allocator,
) -> (replacement: []u8, ok: bool) {
	if window == nil || line == nil || line.source_start < window.start_byte || line.source_end < line.source_start {
		return {}, false
	}
	eol_length := 1
	eol_crlf := false
	for value, index in window.source {
		if value != '\n' { continue }
		if index > 0 && window.source[index-1] == '\r' {
			eol_length = 2
			eol_crlf = true
		}
		break
	}
	line_start := int(line.source_start-window.start_byte)
	line_end := int(line.source_end-window.start_byte)
	if line_start < 0 || line_end > len(window.source) || line_end < line_start { return {}, false }
	indent_end := line_start
	for indent_end < line_end {
		value := window.source[indent_end]
		if value != ' ' && value != '\t' { break }
		indent_end += 1
	}
	result, allocation_error := make([]u8, eol_length+indent_end-line_start, allocator=allocator)
	if allocation_error != nil { return {}, false }
	if eol_crlf {
		result[0], result[1] = '\r', '\n'
	} else {
		result[0] = '\n'
	}
	indent_length := indent_end-line_start
	if indent_length > 0 {
		mem.copy(rawptr(&result[eol_length]), rawptr(&window.source[line_start]), indent_length)
	}
	return result, true
}

// editor_window_replace_bytes updates only the already-bounded source window.
editor_window_replace_bytes :: proc(
	source: ^Editor_Window,
	start_byte, end_byte: u64,
	replacement: []u8,
	allocator := context.allocator,
) -> (window: Editor_Window, ok: bool, message: string) {
	if source == nil || end_byte < start_byte || start_byte < source.start_byte {
		return {}, false, "edit range is outside the bounded source window"
	}
	window_end := source.start_byte + u64(len(source.source))
	if end_byte > window_end {
		return {}, false, "edit range crosses the loaded source-window boundary"
	}
	new_length := len(source.source)-int(end_byte-start_byte)+len(replacement)
	if new_length > EDITOR_MAX_OPTIMISTIC_SOURCE_BYTES {
		return {}, false, "optimistic source window exceeded its bounded capacity"
	}
	bytes, allocation_error := make([]u8, new_length, allocator=allocator)
	if allocation_error != nil { return {}, false, "could not allocate the optimistic source projection" }
	local_start := int(start_byte-source.start_byte)
	local_end := int(end_byte-source.start_byte)
	removed_line_breaks := editor_count_line_breaks(source.source[local_start:local_end])
	added_line_breaks := editor_count_line_breaks(replacement)
	if removed_line_breaks > source.end_line-source.start_line {
		delete(bytes, allocator)
		return {}, false, "replacement removes more line breaks than the bounded window contains"
	}
	if source.end_line-source.start_line-removed_line_breaks+added_line_breaks > bridge.MAX_VISIBLE_LINES {
		delete(bytes, allocator)
		return {}, false, "replacement exceeds the bounded visible-line capacity"
	}
	if local_start > 0 { mem.copy(rawptr(&bytes[0]), rawptr(&source.source[0]), local_start) }
	if len(replacement) > 0 {
		mem.copy(rawptr(&bytes[local_start]), rawptr(&replacement[0]), len(replacement))
	}
	suffix_length := len(source.source)-local_end
	if suffix_length > 0 {
		suffix_start := local_start+len(replacement)
		mem.copy(rawptr(&bytes[suffix_start]), rawptr(&source.source[local_end]), suffix_length)
	}
	line_byte_length := source.line_byte_length
	if source.truncated && source.end_line == source.start_line+1 {
		removed := end_byte-start_byte
		if u64(len(replacement)) >= removed {
			line_byte_length += u64(len(replacement))-removed
		} else {
			line_byte_length -= removed-u64(len(replacement))
		}
	}
	visible := bridge.Visible_Window{
		document_id=source.document_id,
		application_rev=source.application_rev,
		editor_revision=source.editor_revision,
		start_line=source.start_line,
		end_line=source.end_line-removed_line_breaks+added_line_breaks,
		start_byte=source.start_byte,
		line_byte_length=line_byte_length,
		truncated=source.truncated,
		source=bytes,
	}
	window, ok, message = editor_window_from_visible(&visible, allocator, EDITOR_MAX_OPTIMISTIC_SOURCE_BYTES)
	if !ok && len(visible.source) > 0 { delete(visible.source, allocator) }
	if ok {
		window.presentation_revision = source.presentation_revision
		window.presentation_ready = source.presentation_ready
		window.presentation_truncated = source.presentation_truncated
		if source.presentation_ready {
			local_start := int(start_byte-source.start_byte)
			local_end := int(end_byte-source.start_byte)
			window.presentation_spans = editor_rebase_presentation_records(
				source.presentation_spans, local_start, local_end, len(replacement), allocator,
			)
			window.presentation_blocks = editor_rebase_presentation_records(
				source.presentation_blocks, local_start, local_end, len(replacement), allocator,
			)
			window.presentation_stale = true
		}
	}
	return
}

editor_rebase_presentation_records :: proc(
	records: []bridge.Presentation_Record,
	edit_start, edit_end, replacement_length: int,
	allocator := context.allocator,
) -> []bridge.Presentation_Record {
	result := make([dynamic]bridge.Presentation_Record, 0, allocator=allocator)
	delta := i64(replacement_length)-i64(edit_end-edit_start)
	edit_start_i64 := i64(edit_start)
	edit_end_i64 := i64(edit_end)
	for original in records {
		record := original
		start := i64(record.start_byte)
		end := i64(record.end_byte)
		if edit_start == edit_end {
			if end < edit_start_i64 {
				// Insertion after this record; retain its byte range.
			} else if start > edit_start_i64 {
				start += delta
				end += delta
			} else {
				// An insertion at either edge or inside a semantic range inherits
				// its presentation until the next exact parser projection arrives.
				end += delta
			}
		} else if end <= edit_start_i64 {
			// Record precedes the edit.
		} else if start >= edit_end_i64 {
			start += delta
			end += delta
		} else if start <= edit_start_i64 && end >= edit_end_i64 {
			// Preserve enclosing block/span context until the fresh projection
			// arrives; the edit acknowledgement never treats it as authority.
			end += delta
		} else {
			// Partially replaced records are too ambiguous to keep.
			continue
		}
		if start < 0 || end < start || end > i64(0xFFFFFFFF) { continue }
		record.start_byte = u32(start)
		record.end_byte = u32(end)
		append(&result, record)
	}
	return result[:]
}

editor_count_line_breaks :: proc(source: []u8) -> u64 {
	count: u64 = 0
	for value in source { if value == '\n' { count += 1 } }
	return count
}

// Source edits shift the logical-line identities used by sparse wrap-height
// measurements. Retire measurements for touched lines and shift only the
// unaffected suffix; if a bounded-range edge cannot be mapped, discard the
// measurements safely and let visible rows be remeasured.
editor_wrap_heights_apply_edit :: proc(
	view: ^Editor_View_State,
	window: ^Editor_Window,
	start_byte, end_byte: u64,
	replacement: []u8,
	removed_line_breaks: u64,
) {
	if view == nil || window == nil || !view.wrap_height_index_ready { return }
	first, first_found := editor_line_for_source(window, start_byte)
	last, last_found := editor_line_for_source(window, end_byte)
	line_delta := i64(editor_count_line_breaks(replacement))-i64(removed_line_breaks)
	result_count := view.wrap_height_index.item_count+int(line_delta)
	valid: bool = first_found && last_found && first.logical_line <= last.logical_line && result_count > 0
	if valid {
		first_index := int(first.logical_line)
		removed_count := int(last.logical_line-first.logical_line+1)
		inserted_count := removed_count+int(line_delta)
		valid = inserted_count > 0 && alicorn.virtual_list_height_index_apply_edit(
			&view.wrap_height_index,
			first_index,
			removed_count,
			inserted_count,
			result_count,
		)
	}
	if !valid {
		alicorn.virtual_list_height_index_destroy(&view.wrap_height_index)
		view.wrap_height_index_ready = alicorn.virtual_list_height_index_init(
			&view.wrap_height_index,
			max(result_count, 1),
			EDITOR_ROW_HEIGHT,
			context.allocator,
		)
	}
	view.wrap_measurement_revision = 0
}

editor_wrap_heights_reset :: proc(view: ^Editor_View_State, item_count: int) {
	if view == nil || !view.wrap_height_index_ready { return }
	alicorn.virtual_list_height_index_destroy(&view.wrap_height_index)
	view.wrap_height_index_ready = alicorn.virtual_list_height_index_init(
		&view.wrap_height_index,
		max(item_count, 1),
		EDITOR_ROW_HEIGHT,
		context.allocator,
	)
	view.wrap_measurement_width = -1
	view.wrap_measurement_revision = 0
	view.wrap_measurement_presentation_revision = 0
	view.wrap_measurement_start_line = 0
	view.wrap_measurement_end_line = 0
	view.wrap_measurement_pending_edits = 0
}

editor_bytes_equal :: proc(left, right: []u8) -> bool {
	if len(left) != len(right) { return false }
	for value, index in left { if value != right[index] { return false } }
	return true
}

// Maps source boundaries around a backend-canonicalized replacement. Matching
// prefix/suffix bytes preserve positions within the inserted indentation even
// when the authoritative line ending differs from the optimistic prediction.
editor_rebase_replacement_position :: proc(
	position, start_byte: u64,
	old_replacement, new_replacement: []u8,
) -> u64 {
	old_length := u64(len(old_replacement))
	new_length := u64(len(new_replacement))
	old_end := start_byte+old_length
	if position <= start_byte { return position }
	if position >= old_end { return position-old_length+new_length }
	prefix := 0
	limit := min(len(old_replacement), len(new_replacement))
	for prefix < limit && old_replacement[prefix] == new_replacement[prefix] { prefix += 1 }
	suffix := 0
	for suffix < min(len(old_replacement)-prefix, len(new_replacement)-prefix) &&
		old_replacement[len(old_replacement)-1-suffix] == new_replacement[len(new_replacement)-1-suffix] {
		suffix += 1
	}
	relative := int(position-start_byte)
	old_middle_end := len(old_replacement)-suffix
	new_middle_end := len(new_replacement)-suffix
	if relative <= prefix { return start_byte+u64(relative) }
	if relative >= old_middle_end {
		return start_byte+u64(new_middle_end+relative-old_middle_end)
	}
	// The only expected interior mismatch is a normalized line ending (LF vs
	// CRLF). A source boundary after it belongs after the complete canonical
	// ending, which is the far edge of the changed middle.
	return start_byte+u64(new_middle_end)
}

editor_window_from_visible :: proc(
	source: ^bridge.Visible_Window,
	allocator := context.allocator,
	max_source_bytes := int(bridge.MAX_VISIBLE_BYTES),
) -> (window: Editor_Window, ok: bool, message: string) {
	if source == nil || len(source.document_id) == 0 || source.end_line < source.start_line || source.end_line-source.start_line > bridge.MAX_VISIBLE_LINES || len(source.source) > max_source_bytes {
		return {}, false, "visible editor window metadata is invalid or exceeds bounded limits"
	}
	document_id, clone_err := strings.clone(source.document_id, allocator)
	if clone_err != nil { return {}, false, "could not retain editor document identity" }
	window = Editor_Window{
		document_id=document_id,
		application_rev=source.application_rev,
		editor_revision=source.editor_revision,
		start_line=source.start_line,
		end_line=source.end_line,
		start_byte=source.start_byte,
		line_byte_length=source.line_byte_length,
		truncated=source.truncated,
		source=source.source,
		presentation_revision=source.presentation_revision,
		presentation_ready=source.presentation_ready,
		presentation_truncated=source.presentation_truncated,
		presentation_spans=source.presentation_spans,
		presentation_blocks=source.presentation_blocks,
		lines=make([dynamic]Editor_Display_Line, 0, allocator=allocator),
	}
	source.source = {}
	source.presentation_spans = {}
	source.presentation_blocks = {}
	line_start := 0
	logical_line := window.start_line
	for index in 0..<len(window.source) {
		if window.source[index] != '\n' { continue }
		line_end := index
		if line_end > line_start && window.source[line_end-1] == '\r' { line_end -= 1 }
		line, line_ok := editor_project_line(window.source[line_start:line_end], window.start_byte+u64(line_start), logical_line, allocator)
		if !line_ok {
			editor_window_destroy(&window, allocator)
			return {}, false, "could not project a visible editor line"
		}
		append(&window.lines, line)
		logical_line += 1
		line_start = index+1
	}
	for logical_line < window.end_line {
		line_end := len(window.source)
		if line_end > line_start && window.source[line_end-1] == '\r' { line_end -= 1 }
		line, line_ok := editor_project_line(window.source[line_start:line_end], window.start_byte+u64(line_start), logical_line, allocator)
		if !line_ok {
			editor_window_destroy(&window, allocator)
			return {}, false, "could not project a visible editor line"
		}
		append(&window.lines, line)
		logical_line += 1
		line_start = len(window.source)
	}
	if u64(len(window.lines)) != window.end_line-window.start_line {
		editor_window_destroy(&window, allocator)
		return {}, false, "visible editor bytes do not represent the declared logical line range"
	}
	return window, true, ""
}

editor_window_line :: proc(window: ^Editor_Window, logical_line: u64) -> (line: ^Editor_Display_Line, found: bool) {
	if window == nil || logical_line < window.start_line || logical_line >= window.end_line { return nil, false }
	index := int(logical_line-window.start_line)
	if index < 0 || index >= len(window.lines) { return nil, false }
	return &window.lines[index], true
}

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
				run, built := alicorn.text_run_build_with_overflow(
					&rt.text_engine,
					cell.display,
					16,
					layout.widths[cell_index],
					context.temp_allocator,
					context.temp_allocator,
					.Monospace,
					alicorn.FONT_WEIGHT_REGULAR,
					.Wrap,
					true,
					style_spans,
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
		wrap := editor_line_should_wrap(language, window, &line, presentation_current, width)
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
		if !found || editor_line_should_wrap(language, window, line, presentation_current, wrap_width) { continue }
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
