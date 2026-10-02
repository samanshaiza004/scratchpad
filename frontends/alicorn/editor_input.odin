package main

import "core:fmt"
import "core:mem"
import "core:time"
import "core:unicode/utf8"
import alicorn "alicorn:runtime"

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
	action_id:         string,
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

editor_edit_intent_destroy :: proc(intent: ^Editor_Edit_Intent, allocator := context.allocator) {
	if intent == nil { return }
	if len(intent.document_id) > 0 { delete(intent.document_id, allocator) }
	if len(intent.action_id) > 0 { delete(intent.action_id, allocator) }
	delete(intent.replacement, allocator)
	delete(intent.wire_replacement, allocator)
	intent^ = {}
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

editor_move_subword_source :: proc(
	window: ^Editor_Window,
	source_byte: u64,
	affinity: alicorn.Text_Affinity,
	direction: int,
) -> (next_source: u64, next_affinity: alicorn.Text_Affinity, moved: bool) {
	if window == nil || direction == 0 { return source_byte, affinity, false }
	line, found := editor_line_for_source(window, source_byte)
	if !found { return source_byte, affinity, false }
	display_byte := editor_source_to_display(line, source_byte)
	display_target, handled := editor_subword_move_ascii(line.display, display_byte, direction)
	if handled {
		mapped := editor_normalize_source_position(line, editor_display_to_source(line, display_target))
		if mapped != source_byte { return mapped, .Leading, true }
	}
	return editor_move_word_source(window, source_byte, affinity, direction)
}

