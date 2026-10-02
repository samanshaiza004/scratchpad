package main

import "core:mem"
import "core:strings"
import "core:time"
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
EDITOR_PRESENTATION_CODE_COMMENT :: u32(12)
EDITOR_PRESENTATION_CODE_KEYWORD :: u32(13)
EDITOR_PRESENTATION_CODE_STRING :: u32(14)
EDITOR_PRESENTATION_CODE_NUMBER :: u32(15)
EDITOR_PRESENTATION_CODE_TYPE :: u32(16)
EDITOR_PRESENTATION_CODE_FUNCTION :: u32(17)
EDITOR_PRESENTATION_CODE_METHOD :: u32(18)
EDITOR_PRESENTATION_CODE_VARIABLE :: u32(19)
EDITOR_PRESENTATION_CODE_CONSTANT :: u32(20)
EDITOR_PRESENTATION_CODE_PROPERTY :: u32(21)
EDITOR_PRESENTATION_CODE_OPERATOR :: u32(22)
EDITOR_PRESENTATION_CODE_PUNCTUATION :: u32(23)
EDITOR_PRESENTATION_CODE_BUILTIN :: u32(24)
EDITOR_PRESENTATION_CODE_PARAMETER :: u32(25)
EDITOR_PRESENTATION_CODE_TAG :: u32(26)
EDITOR_PRESENTATION_CODE_ATTRIBUTE :: u32(27)
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

Editor_Wrap_Mode :: enum { Auto, On, Off }

Editor_Reveal_Alignment :: enum { Nearest, Center_When_Needed }

// An editor reveal is a source-relative destination. It stays valid across
// retained rebuilds and is resolved only once the destination's shaped text
// geometry exists for the requested document revision.
Editor_Reveal_Request :: struct {
	document_id: string,
	editor_revision: u64,
	source_start: u64,
	source_end: u64,
	logical_line: u64,
	alignment: Editor_Reveal_Alignment,
	pending: bool,
}

Editor_View_State :: struct {
	document_id:       string,
	scroll_y:          f32,
	scroll_x:          f32,
	horizontal_extent: f32,
	extent_revision:    u64,
	horizontal_scroll_suspended: bool,
	wrap_mode: Editor_Wrap_Mode,
	restore_y_pending: bool,
	restore_x_pending: bool,
	selection_anchor:  u64,
	caret_byte:        u64,
	anchor_affinity:   alicorn.Text_Affinity,
	caret_affinity:    alicorn.Text_Affinity,
	preferred_x:       f32,
	preferred_x_set:   bool,
	pending_goto_line: bool,
	pending_goto_column: u64,
	pending_goto_target_line: u64,
	auto_pair_closer_byte: u64,
	auto_pair_closer: u8,
	auto_pair_valid: bool,
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
	wrap_measurement_mode: Editor_Wrap_Mode,
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
	workspace_search_match_active: bool,
	workspace_search_match_start: u64,
	workspace_search_match_end: u64,
	workspace_search_match_revision: u64,
	reveal_request: Editor_Reveal_Request,
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

editor_reveal_request_clear :: proc(
	request: ^Editor_Reveal_Request,
	allocator := context.allocator,
) {
	if request == nil { return }
	if len(request.document_id) > 0 { delete(request.document_id, allocator) }
	request^ = {}
}

editor_reveal_request_set :: proc(
	view: ^Editor_View_State,
	document_id: string,
	editor_revision: u64,
	source_start, source_end, logical_line: u64,
	alignment: Editor_Reveal_Alignment,
	allocator := context.allocator,
) -> bool {
	if view == nil || document_id == "" || source_end < source_start { return false }
	owned_id, clone_error := strings.clone(document_id, allocator)
	if clone_error != nil { return false }
	editor_reveal_request_clear(&view.reveal_request, allocator)
	view.reveal_request = Editor_Reveal_Request{
		document_id=owned_id,
		editor_revision=editor_revision,
		source_start=source_start,
		source_end=source_end,
		logical_line=logical_line,
		alignment=alignment,
		pending=true,
	}
	return true
}

editor_reveal_request_matches :: proc(
	request: Editor_Reveal_Request,
	document_id: string,
	editor_revision: u64,
) -> bool {
	return request.pending && request.document_id == document_id && request.editor_revision == editor_revision
}

editor_reveal_content_offset :: proc(
	current_offset, viewport, target_top, target_height: f32,
	alignment: Editor_Reveal_Alignment,
) -> (offset: f32, should_scroll: bool) {
	if viewport <= 0 || target_height <= 0 { return current_offset, false }
	target_bottom := target_top+target_height
	if alignment == .Center_When_Needed {
		margin := min(viewport*0.18, 64)
		if target_top >= current_offset+margin && target_bottom <= current_offset+viewport-margin {
			return current_offset, false
		}
		return max(target_top+target_height*0.5-viewport*0.5, 0), true
	}
	margin := min(target_height*0.25, 8)
	if target_top >= current_offset+margin && target_bottom <= current_offset+viewport-margin {
		return current_offset, false
	}
	if target_top < current_offset+margin {
		return max(target_top-margin, 0), true
	}
	return max(target_bottom-viewport+margin, 0), true
}

// A preedit is frontend-only transient state. The original source selection is
// captured once and remains the replacement range for all subsequent IME
// updates and the eventual commit.

editor_view_remove :: proc(views: ^[dynamic]Editor_View_State, index: int, allocator := context.allocator) {
	if views == nil || index < 0 || index >= len(views) { return }
	editor_preedit_clear(&views[index], allocator)
	editor_reveal_request_clear(&views[index].reveal_request, allocator)
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
		editor_reveal_request_clear(&view.reveal_request, allocator)
		if view.optimistic_window_ready { editor_window_destroy(&view.optimistic_window, allocator) }
		if view.wrap_height_index_ready { alicorn.virtual_list_height_index_destroy(&view.wrap_height_index) }
		if len(view.document_id) > 0 { delete(view.document_id, allocator) }
	}
	delete(views^)
	views^ = {}
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

// Go-to-line remains a byte-based view intent until its logical row is in the
// bounded window. Column is one-based and counted in Runa grapheme steps.
editor_view_resolve_goto_line :: proc(
	view: ^Editor_View_State,
	window: ^Editor_Window,
	line_count: u64,
) -> bool {
	if view == nil || window == nil || !view.pending_goto_line || line_count == 0 { return false }
	target_line := min(view.pending_goto_target_line, line_count-1)
	line, found := editor_window_line(window, target_line)
	if !found { return false }
	position := editor_normalize_source_position(line, line.source_start)
	column := max(view.pending_goto_column, 1)
	for _ in 1..<column {
		next, _, moved := editor_move_horizontal(line, position, .Leading, 1)
		if !moved { break }
		position = next
	}
	view.selection_anchor = position
	view.caret_byte = position
	view.anchor_affinity = .Leading
	view.caret_affinity = .Leading
	_ = editor_reveal_request_set(
		view,
		window.document_id,
		window.editor_revision,
		position,
		position,
		target_line,
		.Center_When_Needed,
	)
	view.pending_goto_line = false
	view.pending_goto_column = 0
	view.pending_goto_target_line = 0
	view.pending_document_edge = .None
	view.pending_document_edge_shift = false
	view.preferred_x_set = false
	return true
}

// editor_subword_move_ascii provides source-language-neutral identifier
// subword boundaries for ASCII identifiers. Non-ASCII and punctuation remain
// on Runa's normal Unicode word path.

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

