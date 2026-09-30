package main

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"
import alicorn "alicorn:runtime"
import bridge "./bridge"

EDITOR_ROW_HEIGHT :: f32(22)
EDITOR_TAB_WIDTH :: 4
EDITOR_TAB_INSERT :: [4]u8{' ', ' ', ' ', ' '}
EDITOR_LONG_LINE_CHUNK_BYTES :: u64(16 * 1024)
EDITOR_MAX_OPTIMISTIC_SOURCE_BYTES :: int(bridge.MAX_VISIBLE_BYTES + bridge.MAX_EDIT_BYTES)
EDITOR_IME_RECOVERY_MAX_BYTES :: int(bridge.MAX_EDIT_BYTES)

editor_logical_row_style :: proc() -> alicorn.Layout_Style {
	return alicorn.layout_style(.Row, height=EDITOR_ROW_HEIGHT, gap=8, align=.Center, clip=true)
}

Editor_Display_Line :: struct {
	logical_line:  u64,
	source_start:  u64,
	source_end:    u64,
	display:       string,
	display_bytes: []u64,
}

Editor_Window :: struct {
	document_id:     string,
	application_rev: u64,
	editor_revision: u64,
	start_line:      u64,
	end_line:        u64,
	start_byte:      u64,
	line_byte_length: u64,
	truncated:       bool,
	source:          []u8,
	presentation_revision: u64,
	presentation_ready: bool,
	presentation_truncated: bool,
	presentation_spans: []bridge.Presentation_Record,
	presentation_blocks: []bridge.Presentation_Record,
	lines:           [dynamic]Editor_Display_Line,
}

Editor_View_State :: struct {
	document_id:       string,
	scroll_y:          f32,
	scroll_x:          f32,
	horizontal_extent: f32,
	extent_revision:    u64,
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
	authoritative_revision: u64,
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
	start_byte:        u64,
	end_byte:          u64,
	before_anchor_byte: u64,
	before_cursor_byte: u64,
	after_anchor_byte:  u64,
	after_cursor_byte:  u64,
	replacement:       []u8,
	wire_replacement:  []u8,
}

Editor_Row_Target :: struct {
	node:         alicorn.Node_ID,
	logical_line: u64,
}

editor_row_node_for_line :: proc(rows: []Editor_Row_Target, logical_line: u64) -> alicorn.Node_ID {
	for row in rows {
		if row.logical_line == logical_line { return row.node }
	}
	return 0
}

editor_temporary_text_run :: proc(rt: ^alicorn.Runtime, line: ^Editor_Display_Line) -> (run: alicorn.Text_Run, ok: bool) {
	if rt == nil || line == nil { return }
	return alicorn.text_run_build_with_overflow(
		&rt.text_engine,
		line.display,
		16,
		0,
		context.temp_allocator,
		context.temp_allocator,
		.Monospace,
		alicorn.FONT_WEIGHT_REGULAR,
		.Clip,
	)
}

// editor_visual_x_for_source measures the caret relative to the start of the
// source lane, so horizontal scrolling does not change the preferred column.
// Retained geometry is used for realized rows; a bounded one-line Runa product
// is a fallback only while navigating to a neighboring row just outside the
// current viewport realization.
editor_visual_x_for_source :: proc(
	rt: ^alicorn.Runtime,
	line: ^Editor_Display_Line,
	text_node: alicorn.Node_ID,
	source_byte: u64,
	affinity: alicorn.Text_Affinity,
) -> (x: f32, ok: bool) {
	if line == nil { return }
	display_byte := editor_source_to_display(line, source_byte)
	position := alicorn.Text_Position{byte=display_byte, affinity=affinity}
	if node, found := rt.nodes[text_node]; found && text_node != 0 {
		geometry := alicorn.text_node_caret_geometry(rt, text_node, position)
		if geometry.valid { return geometry.rect.x-node.bounds.x, true }
	}
	run, built := editor_temporary_text_run(rt, line)
	if !built { return }
	defer alicorn.text_run_destroy(&run)
	geometry := alicorn.text_run_caret_geometry(&run, position)
	if geometry.valid { return geometry.rect.x, true }
	return
}

// editor_source_at_visual_x maps a preferred source-lane X onto a target line
// using the retained Runa run whenever that row is realized.
editor_source_at_visual_x :: proc(
	rt: ^alicorn.Runtime,
	line: ^Editor_Display_Line,
	text_node: alicorn.Node_ID,
	visual_x: f32,
) -> (source_byte: u64, affinity: alicorn.Text_Affinity, ok: bool) {
	if line == nil { return }
	position: alicorn.Text_Position
	if node, found := rt.nodes[text_node]; found && text_node != 0 {
		hit: bool
		position, hit = alicorn.text_node_hit_test(
			rt,
			text_node,
			node.bounds.x+visual_x,
			node.bounds.y+node.bounds.h/2,
		)
		if !hit { return }
	} else {
		run, built := editor_temporary_text_run(rt, line)
		if !built { return }
		position = alicorn.text_run_hit_test(&run, visual_x, 0)
		alicorn.text_run_destroy(&run)
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
	append(views, Editor_View_State{document_id=owned_id})
	return len(views)-1, true
}

editor_view_mark_active :: proc(view: ^Editor_View_State) {
	if view == nil { return }
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

// A bounded source window only provides a lower bound for the document's
// horizontal extent. Keep the widest observed window for this editor revision
// so paging through shorter windows cannot make the viewport geometry contract.
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
		}
	} else {
		view.scroll_x = live_x
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
	delete(views[index].document_id, allocator)
	ordered_remove(views, index)
}

editor_views_destroy :: proc(views: ^[dynamic]Editor_View_State, allocator := context.allocator) {
	if views == nil { return }
	for &view in views {
		editor_preedit_clear(&view, allocator)
		if view.optimistic_window_ready { editor_window_destroy(&view.optimistic_window, allocator) }
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
	case 2: // heading
		return alicorn.Color{0.55, 0.76, 1.0, 1}, true
	case 3: // strong
		return alicorn.Color{0.86, 0.9, 1.0, 1}, true
	case 4: // emphasis
		return alicorn.Color{0.72, 0.79, 0.91, 1}, true
	case 5: // inline code
		return alicorn.Color{0.76, 0.84, 1.0, 1}, true
	case 6: // link
		return alicorn.Color{0.38, 0.72, 1.0, 1}, true
	case 8: // code block
		return alicorn.Color{0.73, 0.82, 0.95, 1}, true
	case 9, 10, 28, 31: // quote, list marker, thematic break, table delimiter
		return alicorn.Color{0.57, 0.63, 0.74, 1}, true
	case 11: // task marker
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

// Markdown typography is applied over the same source-derived display bytes as
// paint spans. It changes glyph shaping but leaves the row's font size and
// layout bounds fixed.
editor_presentation_text_styles_for_line :: proc(window: ^Editor_Window, line: ^Editor_Display_Line, allocator := context.temp_allocator) -> []alicorn.Text_Style_Span {
	result := make([dynamic]alicorn.Text_Style_Span, 0, allocator=allocator)
	if window == nil || line == nil || !window.presentation_ready || window.presentation_revision != window.editor_revision { return result[:] }
	window_end := window.start_byte+u64(len(window.source))
	for record in window.presentation_spans {
		weight: f32
		weight_set := false
		italic := false
		italic_set := false
		switch record.kind {
		case 2: // heading; modest hierarchy without a size change
			switch record.level_flags & 0xFF {
			case 1: weight = alicorn.FONT_WEIGHT_SEMIBOLD
			case 2: weight = alicorn.FONT_WEIGHT_MEDIUM
			case 3: weight = 450
			case: continue
			}
			weight_set = true
		case 3: // strong
			weight = alicorn.FONT_WEIGHT_BOLD
			weight_set = true
		case 4: // emphasis
			italic = true
			italic_set = true
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
	if window == nil || line == nil || !window.presentation_ready || window.presentation_revision != window.editor_revision { return result[:] }
	window_end := window.start_byte+u64(len(window.source))
	// Block backgrounds go first so inline syntax colors remain visible above them.
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
		case 0x10001: // code block
			paint.background = alicorn.Color{0.09, 0.11, 0.16, 0.48}
			paint.background_set = true
		case 0x10002: // quote
			paint.background = alicorn.Color{0.18, 0.22, 0.31, 0.34}
			paint.background_set = true
		case 0x10004: // thematic break
			paint.background = alicorn.Color{0.22, 0.26, 0.35, 0.32}
			paint.background_set = true
		case 0x10005: // table
			paint.background = alicorn.Color{0.18, 0.22, 0.3, 0.38}
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
		paint := alicorn.Text_Paint_Span{start=start, end=end, color=color, color_set=color_set}
		switch record.kind {
		case 5: // inline code
			paint.background = alicorn.Color{0.2, 0.24, 0.34, 0.76}
			paint.background_set = true
		case 6: // link
			paint.underline = true
		case 7: // strike
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
	return
}

editor_count_line_breaks :: proc(source: []u8) -> u64 {
	count: u64 = 0
	for value in source { if value == '\n' { count += 1 } }
	return count
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

editor_window_content_width :: proc(window: ^Editor_Window, minimum, gutter_width: f32) -> f32 {
	width := minimum
	if window == nil { return width }
	for line in window.lines {
		// Deliberately conservative for multi-byte glyphs: the frontier is based
		// only on the bounded window, never a scan of the full document.
		width = max(width, f32(len(line.display))*10 + gutter_width + 8)
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
