package main

import alicorn "alicorn:runtime"

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
	case EDITOR_PRESENTATION_CODE_COMMENT:
		return alicorn.Color{0.48, 0.69, 0.57, 1}, true
	case EDITOR_PRESENTATION_CODE_KEYWORD:
		return alicorn.Color{0.78, 0.62, 1.0, 1}, true
	case EDITOR_PRESENTATION_CODE_STRING:
		return alicorn.Color{0.86, 0.72, 0.49, 1}, true
	case EDITOR_PRESENTATION_CODE_NUMBER:
		return alicorn.Color{0.54, 0.78, 0.9, 1}, true
	case EDITOR_PRESENTATION_CODE_TYPE:
		return alicorn.Color{0.42, 0.8, 0.76, 1}, true
	case EDITOR_PRESENTATION_CODE_FUNCTION, EDITOR_PRESENTATION_CODE_METHOD:
		return alicorn.Color{0.48, 0.72, 0.98, 1}, true
	case EDITOR_PRESENTATION_CODE_VARIABLE:
		return alicorn.Color{0.78, 0.83, 0.92, 1}, true
	case EDITOR_PRESENTATION_CODE_CONSTANT:
		return alicorn.Color{0.91, 0.72, 0.48, 1}, true
	case EDITOR_PRESENTATION_CODE_PROPERTY:
		return alicorn.Color{0.62, 0.78, 0.98, 1}, true
	case EDITOR_PRESENTATION_CODE_OPERATOR:
		return alicorn.Color{0.73, 0.77, 0.86, 1}, true
	case EDITOR_PRESENTATION_CODE_PUNCTUATION:
		return alicorn.Color{0.61, 0.68, 0.8, 1}, true
	case EDITOR_PRESENTATION_CODE_BUILTIN:
		return alicorn.Color{0.4, 0.79, 0.86, 1}, true
	case EDITOR_PRESENTATION_CODE_PARAMETER:
		return alicorn.Color{0.83, 0.76, 0.91, 1}, true
	case EDITOR_PRESENTATION_CODE_TAG:
		return alicorn.Color{0.88, 0.58, 0.64, 1}, true
	case EDITOR_PRESENTATION_CODE_ATTRIBUTE:
		return alicorn.Color{0.84, 0.74, 0.51, 1}, true
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


Editor_Markdown_Enter_Projection :: struct {
	start_byte: u64,
	end_byte: u64,
	remove_from: int,
	breakout: bool,
	replacement: []u8,
}

// editor_markdown_enter_projection mirrors the bounded, common Markdown list
// and quote continuation semantics used by Go. Go remains authoritative; the
// returned bytes are only the immediate optimistic projection.
editor_markdown_enter_projection :: proc(
	window: ^Editor_Window,
	line: ^Editor_Display_Line,
	cursor_byte: u64,
	allocator := context.temp_allocator,
) -> (projection: Editor_Markdown_Enter_Projection, ok: bool) {
	if window == nil || line == nil || cursor_byte < line.source_start || cursor_byte > line.source_end ||
	   line.source_start < window.start_byte || line.source_end < line.source_start {
		return {}, false
	}
	line_start := int(line.source_start-window.start_byte)
	line_end := int(line.source_end-window.start_byte)
	cursor := int(cursor_byte-window.start_byte)
	if line_start < 0 || line_end > len(window.source) || cursor < line_start || cursor > line_end { return {}, false }
	prefix_end := min(cursor, line_start+4096)
	line_prefix := window.source[line_start:prefix_end]
	at_line_end := cursor == line_end

	prefix := make([dynamic]u8, 0, len(line_prefix)+16, allocator=allocator)
	remove_from, breakout, prefix_ok := editor_markdown_enter_prefix(line_prefix, at_line_end, &prefix, allocator)
	if !prefix_ok {
		delete(prefix)
		return {}, false
	}
	defer delete(prefix)

	eol_length := 1
	eol_crlf := false
	for value, index in window.source {
		if value != '\n' { continue }
		if index > 0 && window.source[index-1] == '\r' { eol_length, eol_crlf = 2, true }
		break
	}
	replacement, allocation_error := make([]u8, eol_length+len(prefix), allocator=allocator)
	if allocation_error != nil { return {}, false }
	if eol_crlf { replacement[0], replacement[1] = '\r', '\n' } else { replacement[0] = '\n' }
	for value, index in prefix { replacement[eol_length+index] = value }
	projection.start_byte = cursor_byte
	projection.remove_from = remove_from
	projection.breakout = breakout
	if breakout { projection.start_byte = line.source_start+u64(remove_from) }
	projection.end_byte = cursor_byte
	projection.replacement = replacement
	return projection, true
}

editor_markdown_enter_prefix :: proc(
	line_prefix: []u8,
	at_line_end: bool,
	out: ^[dynamic]u8,
	allocator := context.temp_allocator,
) -> (remove_from: int, breakout: bool, ok: bool) {
	if out == nil { return 0, false, false }
	indent_end := 0
	for indent_end < len(line_prefix) && (line_prefix[indent_end] == ' ' || line_prefix[indent_end] == '\t') { indent_end += 1 }
	quote_end := indent_end
	quote_prefix := make([dynamic]u8, 0, len(line_prefix)+4, allocator=allocator)
	for index in 0..<indent_end { append(&quote_prefix, line_prefix[index]) }
	for quote_end < len(line_prefix) && line_prefix[quote_end] == '>' {
		append(&quote_prefix, '>', ' ')
		quote_end += 1
		if quote_end < len(line_prefix) && line_prefix[quote_end] == ' ' { quote_end += 1 }
		for quote_end < len(line_prefix) && line_prefix[quote_end] == '\t' { quote_end += 1 }
	}
	defer delete(quote_prefix)

	list_start := quote_end
	marker_end, ordered := editor_markdown_list_marker(line_prefix, list_start)
	if marker_end <= list_start {
		if at_line_end && quote_end > indent_end && len(line_prefix) == quote_end {
			for index in 0..<indent_end { append(out, line_prefix[index]) }
			return indent_end, true, true
		}
		for value in quote_prefix { append(out, value) }
		return 0, false, true
	}

	item_content_start := marker_end
	task_start := marker_end
	for task_start < len(line_prefix) && (line_prefix[task_start] == ' ' || line_prefix[task_start] == '\t') { task_start += 1 }
	task := task_start+3 < len(line_prefix) && line_prefix[task_start] == '[' &&
	        (line_prefix[task_start+1] == ' ' || line_prefix[task_start+1] == 'x' || line_prefix[task_start+1] == 'X') &&
	        line_prefix[task_start+2] == ']' && (line_prefix[task_start+3] == ' ' || line_prefix[task_start+3] == '\t')
	if task { item_content_start = task_start+4 }
	content_empty := true
	for value in line_prefix[item_content_start:] {
		if value != ' ' && value != '\t' && value != '\r' && value != '\n' { content_empty = false; break }
	}
	if at_line_end && content_empty {
		for value in quote_prefix { append(out, value) }
		return list_start, true, true
	}

	for value in quote_prefix { append(out, value) }
	if ordered {
		marker_byte := list_start
		for marker_byte < marker_end && line_prefix[marker_byte] >= '0' && line_prefix[marker_byte] <= '9' { marker_byte += 1 }
		number: u64 = 0
		parsed := marker_byte > list_start
		for index in list_start..<marker_byte {
			digit := u64(line_prefix[index]-'0')
			if number > (0xFFFF_FFFF_FFFF_FFFF-digit)/10 { parsed = false; break }
			number = number*10+digit
		}
		if parsed && number < 0xFFFF_FFFF_FFFF_FFFF {
			number += 1
			digits: [dynamic]u8
			for number > 0 {
				append(&digits, u8('0'+number%10))
				number /= 10
			}
			old_width := marker_byte-list_start
			for _ in 0..<max(old_width-len(digits), 0) { append(out, '0') }
			for index := len(digits)-1; index >= 0; index -= 1 { append(out, digits[index]) }
			delete(digits)
			for index in marker_byte..<marker_end { append(out, line_prefix[index]) }
		} else {
			for index in list_start..<marker_end { append(out, line_prefix[index]) }
		}
	} else {
		for index in list_start..<marker_end { append(out, line_prefix[index]) }
	}
	if task { append(out, '[', ' ', ']', ' ') }
	return 0, false, true
}

editor_markdown_list_marker :: proc(line: []u8, start: int) -> (end: int, ordered: bool) {
	if start >= len(line) { return 0, false }
	index := start
	if line[index] == '-' || line[index] == '+' || line[index] == '*' {
		index += 1
	} else {
		for index < len(line) && line[index] >= '0' && line[index] <= '9' { index += 1 }
		if index == start || index >= len(line) || (line[index] != '.' && line[index] != ')') { return 0, false }
		ordered = true
		index += 1
	}
	if index >= len(line) || (line[index] != ' ' && line[index] != '\t') { return 0, false }
	return index+1, ordered
}

// editor_window_replace_bytes updates only the already-bounded source window.
