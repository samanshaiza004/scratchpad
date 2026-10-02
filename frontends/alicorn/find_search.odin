package main

import "core:fmt"
import "core:mem"
import "core:strings"
import alicorn "alicorn:runtime"
import bridge "./bridge"

FIND_PASSIVE_BACKGROUND :: alicorn.Color{0.42, 0.34, 0.12, 0.34}
FIND_ACTIVE_BACKGROUND  :: alicorn.Color{0.72, 0.48, 0.12, 0.62}
EDITOR_CARET_ROW_BACKGROUND :: alicorn.Color{0.12, 0.15, 0.21, 0.42}
EDITOR_CARET_GUTTER_BACKGROUND :: alicorn.Color{0.15, 0.19, 0.27, 0.48}

// Find_Presentation owns only bounded match coordinates and frontend-local
// navigation state. Source text and match computation stay in Go.
Find_Presentation :: struct {
	document_id:     string,
	query:           string,
	editor_revision: u64,
	matches:         []bridge.Current_Match,
	active_match:    int,
	truncated:       bool,
}

FIND_MAX_MATCHES :: 1000
WORKSPACE_SEARCH_MAX_RESULTS :: 5000

Workspace_Search_View :: struct {
	generation:  u64,
	last_sequence: u64,
	count:       u64,
	done:        bool,
	truncated:   bool,
	results:     [dynamic]bridge.Workspace_Search_Result,
	allocator:   mem.Allocator,
}

find_initial_match :: proc(matches: []bridge.Current_Match, source_cursor: u64) -> int {
	for match, index in matches {
		if match.start >= 0 && u64(match.start) >= source_cursor {
			return index
		}
	}
	return 0 if len(matches) > 0 else -1
}

// direction is positive for next and negative for previous. An unset active
// index starts at the first match for next and the last match for previous.
find_step_match :: proc(match_count, active_index, direction: int) -> int {
	if match_count <= 0 { return -1 }
	if direction < 0 {
		if active_index < 0 { return match_count-1 }
		return (active_index+match_count-1)%match_count
	}
	if active_index < 0 { return 0 }
	return (active_index+1)%match_count
}

workspace_search_selection_step :: proc(result_count, selected_index, direction: int) -> int {
	if result_count <= 0 { return -1 }
	if selected_index < 0 { return 0 if direction >= 0 else result_count-1 }
	if direction < 0 { return max(0, selected_index-1) }
	return min(result_count-1, selected_index+1)
}

workspace_search_result_label :: proc(result: bridge.Workspace_Search_Result, max_preview_bytes := 88) -> string {
	preview := result.text
	preview_truncated := result.text_truncated
	if len(preview) > max_preview_bytes {
		end := max(max_preview_bytes, 0)
		for end > 0 && end < len(preview) && (u8(preview[end]) & 0xC0) == 0x80 { end -= 1 }
		preview = preview[:end]
		preview_truncated = true
	}
	if preview_truncated { preview = fmt.tprintf("%s…", preview) }
	return fmt.tprintf("%s:%d\n%s", result.path, result.line+1, preview)
}

find_presentation_install :: proc(
	presentation: ^Find_Presentation,
	document_id: string,
	query: string,
	editor_revision: u64,
	matches: []bridge.Current_Match,
	truncated: bool,
	source_cursor: u64,
	allocator := context.allocator,
) -> bool {
	if presentation == nil { return false }
	document_id_copy, err := strings.clone(document_id, allocator)
	if err != nil { return false }
	query_copy, query_error := strings.clone(query, allocator)
	if query_error != nil { delete(document_id_copy, allocator); return false }
	match_copy, allocation_error := make([]bridge.Current_Match, len(matches), allocator=allocator)
	if allocation_error != nil {
		delete(document_id_copy, allocator)
		delete(query_copy, allocator)
		return false
	}
	copy(match_copy[:], matches[:])
	find_presentation_destroy(presentation, allocator)
	presentation.document_id = document_id_copy
	presentation.query = query_copy
	presentation.editor_revision = editor_revision
	presentation.matches = match_copy
	presentation.active_match = find_initial_match(match_copy, source_cursor)
	presentation.truncated = truncated
	return true
}

find_presentation_destroy :: proc(presentation: ^Find_Presentation, allocator: mem.Allocator) {
	if presentation == nil { return }
	delete(presentation.document_id, allocator)
	delete(presentation.query, allocator)
	delete(presentation.matches, allocator)
	presentation^ = Find_Presentation{active_match=-1}
}

workspace_search_match_clear :: proc(view: ^Editor_View_State) {
	if view == nil { return }
	view.workspace_search_match_active = false
	view.workspace_search_match_start = 0
	view.workspace_search_match_end = 0
	view.workspace_search_match_revision = 0
	view.workspace_search_reveal_pending = false
	view.workspace_search_reveal_line = 0
}

workspace_search_match_paint_spans_for_line :: proc(
	window: ^Editor_Window,
	line: ^Editor_Display_Line,
	view: ^Editor_View_State,
	allocator := context.temp_allocator,
) -> []alicorn.Text_Paint_Span {
	result := make([dynamic]alicorn.Text_Paint_Span, 0, 1, allocator=allocator)
	if window == nil || line == nil || view == nil || !view.workspace_search_match_active { return result[:] }
	if window.editor_revision != view.workspace_search_match_revision ||
	   view.workspace_search_match_end <= view.workspace_search_match_start { return result[:] }
	start_byte := max(view.workspace_search_match_start, line.source_start)
	if start_byte >= line.source_end { return result[:] }
	end_byte := min(view.workspace_search_match_end, line.source_end)
	start, end, mapped := editor_source_range_to_display(line, start_byte, end_byte)
	if !mapped { return result[:] }
	append(&result, alicorn.Text_Paint_Span{
		start=start,
		end=end,
		background=FIND_ACTIVE_BACKGROUND,
		background_set=true,
	})
	return result[:]
}

// Match ranges are source-byte offsets. Intersect against a logical line and
// map through its existing source/display table; Alicorn then paints the
// resulting shaped-byte range across every wrapped visual row automatically.
find_paint_spans_for_line :: proc(
	window: ^Editor_Window,
	line: ^Editor_Display_Line,
	presentation: ^Find_Presentation,
	allocator := context.temp_allocator,
) -> []alicorn.Text_Paint_Span {
	result := make([dynamic]alicorn.Text_Paint_Span, 0, allocator=allocator)
	if window == nil || line == nil || presentation == nil { return result[:] }
	if len(presentation.matches) == 0 { return result[:] }
	if window.document_id != presentation.document_id || window.editor_revision != presentation.editor_revision { return result[:] }

	low, high := 0, len(presentation.matches)
	for low < high {
		middle := low + (high-low)/2
		match := presentation.matches[middle]
		if match.end >= 0 && u64(match.end) <= line.source_start {
			low = middle+1
		} else {
			high = middle
		}
	}
	for index := low; index < len(presentation.matches); index += 1 {
		match := presentation.matches[index]
		if match.start < 0 || match.end <= match.start { continue }
		start_byte := max(u64(match.start), line.source_start)
		if start_byte >= line.source_end { break }
		end_byte := min(u64(match.end), line.source_end)
		start, end, mapped := editor_source_range_to_display(line, start_byte, end_byte)
		if !mapped { continue }
		background := FIND_PASSIVE_BACKGROUND
		if index == presentation.active_match { background = FIND_ACTIVE_BACKGROUND }
		append(&result, alicorn.Text_Paint_Span{
			start=start,
			end=end,
			background=background,
			background_set=true,
		})
	}
	return result[:]
}


find_merge_paint_spans :: proc(
	window: ^Editor_Window,
	line: ^Editor_Display_Line,
	presentation: ^Find_Presentation,
	base: []alicorn.Text_Paint_Span,
	allocator := context.temp_allocator,
) -> []alicorn.Text_Paint_Span {
	result := make([dynamic]alicorn.Text_Paint_Span, 0, len(base)+4, allocator=allocator)
	for span in base { append(&result, span) }
	search := find_paint_spans_for_line(window, line, presentation, allocator)
	for span in search { append(&result, span) }
	return result[:]
}

workspace_search_view_begin :: proc(view: ^Workspace_Search_View, generation: u64, allocator := context.allocator) {
	if view == nil { return }
	workspace_search_view_destroy(view, view.allocator)
	view.generation = generation
	view.allocator = allocator
	view.results = make([dynamic]bridge.Workspace_Search_Result, 0, allocator=allocator)
}

workspace_search_view_append :: proc(view: ^Workspace_Search_View, page: bridge.Workspace_Search_Page) -> bool {
	if view == nil || page.generation == 0 || page.generation != view.generation { return false }
	if page.sequence == 0 || page.sequence != view.last_sequence+1 { return false }
	if len(view.results) >= WORKSPACE_SEARCH_MAX_RESULTS && len(page.results) > 0 {
		view.truncated = true
		return false
	}

	allocator := view.allocator
	copied := make([dynamic]bridge.Workspace_Search_Result, 0, min(len(page.results), bridge.MAX_WORKSPACE_SEARCH_PAGE_SIZE), allocator=allocator)
	for result in page.results {
		if len(view.results)+len(copied) >= WORKSPACE_SEARCH_MAX_RESULTS {
			view.truncated = true
			break
		}
		path_copy, err := strings.clone(result.path, allocator)
		if err != nil { workspace_search_page_destroy_slice(&copied, allocator); return false }
		text_copy, text_err := strings.clone(result.text, allocator)
		if text_err != nil {
			delete(path_copy, allocator)
			workspace_search_page_destroy_slice(&copied, allocator)
			return false
		}
		append(&copied, bridge.Workspace_Search_Result{
			path=path_copy,
			line=result.line,
			column=result.column,
			start_byte=result.start_byte,
			end_byte=result.end_byte,
			text=text_copy,
			text_truncated=result.text_truncated,
		})
	}
	for result in copied { append(&view.results, result) }
	delete(copied)
	view.last_sequence = page.sequence
	view.count = page.count
	view.done = page.done
	view.truncated = view.truncated || page.truncated || len(view.results) >= WORKSPACE_SEARCH_MAX_RESULTS
	return true
}

workspace_search_view_destroy :: proc(view: ^Workspace_Search_View, allocator: mem.Allocator) {
	if view == nil { return }
	for &result in view.results {
		delete(result.path, allocator)
		delete(result.text, allocator)
	}
	delete(view.results)
	view^ = {}
}

workspace_search_page_destroy_slice :: proc(results: ^[dynamic]bridge.Workspace_Search_Result, allocator: mem.Allocator) {
	if results == nil { return }
	for &result in results^ {
		delete(result.path, allocator)
		delete(result.text, allocator)
	}
	delete(results^)
}
