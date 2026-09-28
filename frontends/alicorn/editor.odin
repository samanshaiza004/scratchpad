package main

import "core:fmt"
import "core:strings"
import alicorn "alicorn:runtime"
import bridge "./bridge"

EDITOR_ROW_HEIGHT :: f32(22)
EDITOR_TAB_WIDTH :: 4
EDITOR_LONG_LINE_CHUNK_BYTES :: u64(16 * 1024)

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
}

Editor_Row_Target :: struct {
	node:         alicorn.Node_ID,
	logical_line: u64,
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
	delete(views[index].document_id, allocator)
	ordered_remove(views, index)
}

editor_views_destroy :: proc(views: ^[dynamic]Editor_View_State, allocator := context.allocator) {
	if views == nil { return }
	for &view in views { if len(view.document_id) > 0 { delete(view.document_id, allocator) } }
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

editor_line_for_source :: proc(window: ^Editor_Window, source_byte: u64) -> (line: ^Editor_Display_Line, found: bool) {
	if window == nil { return nil, false }
	for &candidate in window.lines {
		if source_byte >= candidate.source_start && source_byte <= candidate.source_end {
			return &candidate, true
		}
	}
	return nil, false
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

editor_window_destroy :: proc(window: ^Editor_Window, allocator := context.allocator) {
	if window == nil { return }
	if len(window.document_id) > 0 { delete(window.document_id, allocator) }
	if len(window.source) > 0 { delete(window.source, allocator) }
	for &line in window.lines {
		if len(line.display) > 0 { delete(line.display, allocator) }
		delete(line.display_bytes, allocator)
	}
	delete(window.lines)
	window^ = {}
}

editor_window_from_visible :: proc(source: ^bridge.Visible_Window, allocator := context.allocator) -> (window: Editor_Window, ok: bool, message: string) {
	if source == nil || len(source.document_id) == 0 || source.end_line < source.start_line || source.end_line-source.start_line > bridge.MAX_VISIBLE_LINES || len(source.source) > int(bridge.MAX_VISIBLE_BYTES) {
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
		lines=make([dynamic]Editor_Display_Line, 0, allocator=allocator),
	}
	source.source = {}
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
