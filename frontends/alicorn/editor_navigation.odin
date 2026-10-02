package main

import alicorn "alicorn:runtime"

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


editor_subword_move_ascii :: proc(text: string, byte: int, direction: int) -> (next: int, handled: bool) {
	if direction == 0 || byte < 0 || byte > len(text) { return byte, false }
	is_part := proc(value: u8) -> bool {
		return value == '_' || (value >= 'a' && value <= 'z') ||
		       (value >= 'A' && value <= 'Z') || (value >= '0' && value <= '9')
	}
	is_lower := proc(value: u8) -> bool { return value >= 'a' && value <= 'z' }
	is_upper := proc(value: u8) -> bool { return value >= 'A' && value <= 'Z' }
	is_digit := proc(value: u8) -> bool { return value >= '0' && value <= '9' }
	inside := false
	if byte > 0 && is_part(text[byte-1]) { inside = true }
	if byte < len(text) && is_part(text[byte]) { inside = true }
	if !inside { return byte, false }
	start := byte
	if start == len(text) || (start > 0 && !is_part(text[start])) { start -= 1 }
	for start > 0 && is_part(text[start-1]) { start -= 1 }
	end := byte
	if end < len(text) && !is_part(text[end]) { end += 1 }
	for end < len(text) && is_part(text[end]) { end += 1 }
	if end <= start { return byte, false }
	boundaries: [dynamic]int
	defer delete(boundaries)
	append(&boundaries, start)
	for index := start+1; index < end; index += 1 {
		previous, current := text[index-1], text[index]
		if previous == '_' || current == '_' ||
		   (is_lower(previous) && is_upper(current)) ||
		   (is_digit(previous) != is_digit(current)) {
			append(&boundaries, index)
			continue
		}
		if is_upper(previous) && is_upper(current) && index+1 < end && is_lower(text[index+1]) {
			append(&boundaries, index)
		}
	}
	append(&boundaries, end)
	if direction < 0 {
		for index := len(boundaries)-1; index >= 0; index -= 1 {
			if boundaries[index] < byte { return boundaries[index], true }
		}
	} else {
		for boundary in boundaries {
			if boundary > byte { return boundary, true }
		}
	}
	return byte, true
}

Editor_Bracket_Match :: struct { first: u64, second: u64 }

editor_bracket_match_in_window :: proc(window: ^Editor_Window, caret_byte: u64) -> (match: Editor_Bracket_Match, found: bool) {
	if window == nil || len(window.source) == 0 { return }
	window_end := window.start_byte+u64(len(window.source))
	if caret_byte < window.start_byte || caret_byte > window_end { return }
	local := int(caret_byte-window.start_byte)
	index := -1
	if local < len(window.source) && editor_is_bracket(window.source[local]) { index = local }
	if index < 0 && local > 0 && editor_is_bracket(window.source[local-1]) { index = local-1 }
	if index < 0 { return }
	value := window.source[index]
	opening := value == '(' || value == '[' || value == '{'
	partner := editor_bracket_partner(value)
	if partner == 0 { return }
	depth := 0
	step := 1 if opening else -1
	position := index
	for position >= 0 && position < len(window.source) {
		candidate := window.source[position]
		if candidate == value { depth += 1 }
		if candidate == partner {
			depth -= 1
			if depth == 0 {
				left := min(index, position)
				right := max(index, position)
				return Editor_Bracket_Match{window.start_byte+u64(left), window.start_byte+u64(right)}, true
			}
		}
		position += step
	}
	return
}

editor_is_bracket :: proc(value: u8) -> bool {
	return value == '(' || value == ')' || value == '[' || value == ']' || value == '{' || value == '}'
}

editor_bracket_partner :: proc(value: u8) -> u8 {
	switch value {
	case '(': return ')'
	case ')': return '('
	case '[': return ']'
	case ']': return '['
	case '{': return '}'
	case '}': return '{'
	}
	return 0
}

