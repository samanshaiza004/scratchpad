package main

import "core:mem"

Editor_Line_Indent_Projection :: struct {
	start_byte:   u64,
	end_byte:     u64,
	replacement:  []u8,
	anchor_byte:  u64,
	caret_byte:   u64,
	changed:      bool,
	ok:           bool,
}

// editor_line_indent_projection builds one bounded whole-line replacement for
// Tab/Shift+Tab. It only succeeds when every touched logical line is fully
// represented in the authoritative window. Selection direction is preserved
// by mapping anchor and caret independently through the per-line changes.
editor_line_indent_projection :: proc(
	window: ^Editor_Window,
	anchor_byte, caret_byte: u64,
	indent: []u8,
	outdent: bool,
	allocator := context.allocator,
) -> (result: Editor_Line_Indent_Projection) {
	if window == nil || len(window.lines) == 0 || len(indent) == 0 { return }
	selection_start := min(anchor_byte, caret_byte)
	selection_end := max(anchor_byte, caret_byte)
	window_end := window.start_byte+u64(len(window.source))
	if selection_start < window.start_byte || selection_end > window_end { return }

	first_line, first_ok := editor_line_for_source(window, selection_start)
	last_line, last_ok := editor_line_for_source(window, selection_end)
	if !first_ok || !last_ok || first_line.logical_line < window.start_line || last_line.logical_line < first_line.logical_line {
		return
	}
	first_index := int(first_line.logical_line-window.start_line)
	last_index := int(last_line.logical_line-window.start_line)
	if first_index < 0 || last_index < first_index || last_index >= len(window.lines) { return }
	// Match the document editor's convention: a non-empty selection ending at
	// column zero does not include the following line.
	if selection_start != selection_end && last_index > first_index && selection_end == last_line.source_start {
		last_index -= 1
	}
	if last_index < first_index { return }

	// Replacing a line requires its entire contents and terminator. A later
	// visible line proves the previous line is complete; the last row of a
	// truncated window may itself be a partial line or be followed by unseen
	// source, so fail closed there.
	if last_index == len(window.lines)-1 && window.truncated { return }
	first := &window.lines[first_index]
	last := &window.lines[last_index]
	block_start := first.source_start
	block_end := window_end
	if last_index+1 < len(window.lines) {
		block_end = window.lines[last_index+1].source_start
	}
	if block_start < window.start_byte || block_end < block_start || block_end > window_end { return }
	block_start_local := int(block_start-window.start_byte)
	block_end_local := int(block_end-window.start_byte)
	if block_start_local < 0 || block_end_local > len(window.source) { return }

	line_count := last_index-first_index+1
	remove_counts, alloc_error := make([]int, line_count, allocator=allocator)
	if alloc_error != nil { return }
	defer delete(remove_counts, allocator)
	removed_total := 0
	changed := !outdent
	for row_index in 0..<line_count {
		line := &window.lines[first_index+row_index]
		content_start := int(line.source_start-window.start_byte)
		content_end := int(line.source_end-window.start_byte)
		if content_start < block_start_local || content_end < content_start || content_end > block_end_local { return }
		prefix_start := content_start
		if line.logical_line == 0 && window.start_byte == 0 &&
		   content_end-content_start >= 3 && window.source[content_start] == 0xEF &&
		   window.source[content_start+1] == 0xBB && window.source[content_start+2] == 0xBF {
			prefix_start += 3
		}
		if outdent {
			count := 0
			if prefix_start < content_end && window.source[prefix_start] == '\t' {
				count = 1
			} else {
				for prefix_start+count < content_end && count < len(indent) && window.source[prefix_start+count] == ' ' {
					count += 1
				}
			}
			remove_counts[row_index] = count
			removed_total += count
			changed = changed || count > 0
		}
	}
	if !changed { return Editor_Line_Indent_Projection{ok=true} }

	old_length := block_end_local-block_start_local
	new_length := old_length+line_count*len(indent)
	if outdent { new_length = old_length-removed_total }
	if new_length < 0 { return }
	replacement, replacement_error := make([]u8, new_length, allocator=allocator)
	if replacement_error != nil { return }
	write := 0
	for row_index in 0..<line_count {
		line := &window.lines[first_index+row_index]
		content_start := int(line.source_start-window.start_byte)
		content_end := int(line.source_end-window.start_byte)
		terminator_end := block_end_local
		if first_index+row_index+1 < len(window.lines) {
			terminator_end = int(window.lines[first_index+row_index+1].source_start-window.start_byte)
		}
		prefix_start := content_start
		if line.logical_line == 0 && window.start_byte == 0 &&
		   content_end-content_start >= 3 && window.source[content_start] == 0xEF &&
		   window.source[content_start+1] == 0xBB && window.source[content_start+2] == 0xBF {
			prefix_start += 3
		}
		if outdent {
			count := remove_counts[row_index]
			prefix_length := prefix_start-content_start
			if prefix_length > 0 {
				mem.copy(rawptr(&replacement[write]), rawptr(&window.source[content_start]), prefix_length)
				write += prefix_length
			}
			copy_length := content_end-prefix_start-count
			if copy_length > 0 {
				mem.copy(rawptr(&replacement[write]), rawptr(&window.source[prefix_start+count]), copy_length)
				write += copy_length
			}
		} else {
			prefix_length := prefix_start-content_start
			if prefix_length > 0 {
				mem.copy(rawptr(&replacement[write]), rawptr(&window.source[content_start]), prefix_length)
				write += prefix_length
			}
			mem.copy(rawptr(&replacement[write]), rawptr(&indent[0]), len(indent))
			write += len(indent)
			copy_length := content_end-prefix_start
			if copy_length > 0 {
				mem.copy(rawptr(&replacement[write]), rawptr(&window.source[prefix_start]), copy_length)
				write += copy_length
			}
		}
		terminator_length := terminator_end-content_end
		if terminator_length < 0 || terminator_end > block_end_local { delete(replacement, allocator); return }
		if terminator_length > 0 {
			mem.copy(rawptr(&replacement[write]), rawptr(&window.source[content_end]), terminator_length)
			write += terminator_length
		}
	}
	if write != len(replacement) { delete(replacement, allocator); return }

	map_indent_position := proc(position: u64, rows: []Editor_Display_Line, start_index, count: int, window_start: u64, source: []u8, indent_length: int) -> u64 {
		mapped := position
		for row_offset in 0..<count {
			line := &rows[start_index+row_offset]
			insert_at := line.source_start
			if line.logical_line == 0 && window_start == 0 {
				local := int(line.source_start-window_start)
				line_end := int(line.source_end-window_start)
				if line_end-local >= 3 && source[local] == 0xEF && source[local+1] == 0xBB && source[local+2] == 0xBF {
					insert_at += 3
				}
			}
			if position >= insert_at { mapped += u64(indent_length) }
		}
		return mapped
	}
	map_outdent_position := proc(position: u64, rows: []Editor_Display_Line, start_index, count: int, window_start: u64, source: []u8, removals: []int) -> u64 {
		removed_before := u64(0)
		for row_offset in 0..<count {
			line := &rows[start_index+row_offset]
			line_start := line.source_start
			local_start := int(line_start-window_start)
			local_end := int(line.source_end-window_start)
			prefix_start := local_start
			if line.logical_line == 0 && window_start == 0 && local_end-local_start >= 3 &&
			   source[local_start] == 0xEF && source[local_start+1] == 0xBB && source[local_start+2] == 0xBF {
				prefix_start += 3
			}
			count_removed := removals[row_offset]
			if position < u64(prefix_start) { return position-removed_before }
			if count_removed > 0 && position < u64(prefix_start+count_removed) {
				return u64(prefix_start)-removed_before
			}
			removed_before += u64(count_removed)
		}
		return position-removed_before
	}
	anchor := anchor_byte
	cursor := caret_byte
	if outdent {
		anchor = map_outdent_position(anchor_byte, window.lines[:], first_index, line_count, window.start_byte, window.source, remove_counts)
		cursor = map_outdent_position(caret_byte, window.lines[:], first_index, line_count, window.start_byte, window.source, remove_counts)
	} else {
		anchor = map_indent_position(anchor_byte, window.lines[:], first_index, line_count, window.start_byte, window.source, len(indent))
		cursor = map_indent_position(caret_byte, window.lines[:], first_index, line_count, window.start_byte, window.source, len(indent))
	}
	return Editor_Line_Indent_Projection{
		start_byte=block_start,
		end_byte=block_end,
		replacement=replacement,
		anchor_byte=anchor,
		caret_byte=cursor,
		changed=true,
		ok=true,
	}
}
