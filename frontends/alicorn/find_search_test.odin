package main

import "core:testing"
import alicorn "alicorn:runtime"
import bridge "./bridge"

@(test)
test_find_navigation_wraps_in_both_directions :: proc(t: ^testing.T) {
	testing.expect(t, find_step_match(3, -1, 1) == 0, "next from no active match should select the first")
	testing.expect(t, find_step_match(3, 2, 1) == 0, "next from the last match should wrap to the first")
	testing.expect(t, find_step_match(3, -1, -1) == 2, "previous from no active match should select the last")
	testing.expect(t, find_step_match(3, 0, -1) == 2, "previous from the first match should wrap to the last")
	testing.expect(t, find_step_match(0, 0, 1) == -1, "empty search has no active match")
}

@(test)
test_find_paint_uses_markdown_source_coordinates_across_wrap_boundary :: proc(t: ^testing.T) {
	source := "## **needle**"
	display_boundaries := make([]u64, len(source)+1, allocator=context.temp_allocator)
	for index := 0; index <= len(source); index += 1 {
		display_boundaries[index] = 100+u64(index)
	}
	line := Editor_Display_Line{
		logical_line=0,
		source_start=100,
		source_end=100+u64(len(source)),
		display=source,
		display_bytes=display_boundaries,
	}
	window := Editor_Window{document_id="doc", editor_revision=4, start_byte=100, source=transmute([]u8)source}
	matches := []bridge.Current_Match{{start=105, end=111, line=0, column=5}}
	presentation := Find_Presentation{
		document_id="doc",
		editor_revision=4,
		matches=matches,
		active_match=0,
	}
	spans := find_paint_spans_for_line(&window, &line, &presentation, context.temp_allocator)
	testing.expect(t, len(spans) == 1, "visible Markdown match should produce one source-mapped paint span")
	if len(spans) == 1 {
		span := spans[0]
		testing.expect(t, span.start == 5 && span.end == 11, "paint span should map the unchanged source bytes for 'needle'")
		testing.expect(t, span.background_set, "active match should have a visible background")
		// A wrap after byte 8 puts part of the same match on each visual row.
		testing.expect(t, span.start < 8 && span.end > 8, "one logical match span should continue across the visual wrap boundary")
	}
}

@(test)
test_workspace_search_view_discards_stale_or_duplicate_pages :: proc(t: ^testing.T) {
	view: Workspace_Search_View
	workspace_search_view_begin(&view, 2, context.temp_allocator)
	defer workspace_search_view_destroy(&view, context.temp_allocator)

	old_page := bridge.Workspace_Search_Page{
		generation=1,
		sequence=1,
		results=[]bridge.Workspace_Search_Result{{path="old.txt", text="stale"}},
	}
	testing.expect(t, !workspace_search_view_append(&view, old_page), "late generation A page must not append to generation B")
	page := bridge.Workspace_Search_Page{
		generation=2,
		sequence=1,
		count=1,
		results=[]bridge.Workspace_Search_Result{{
			path="docs/guide.md",
			line=4,
			start_byte=20,
			end_byte=25,
			text="needle",
		}},
	}
	testing.expect(t, workspace_search_view_append(&view, page), "current page should append")
	testing.expect(t, !workspace_search_view_append(&view, page), "duplicate page sequence must not append twice")
	testing.expect(t, len(view.results) == 1 && view.results[0].path == "docs/guide.md" &&
	               view.results[0].start_byte == 20,
	               "workspace hit should keep its relative path and exact source location")
}


@(test)
test_workspace_search_view_stops_at_bounded_result_cap :: proc(t: ^testing.T) {
	view: Workspace_Search_View
	workspace_search_view_begin(&view, 8, context.temp_allocator)
	defer workspace_search_view_destroy(&view, context.temp_allocator)
	results := make([]bridge.Workspace_Search_Result, WORKSPACE_SEARCH_MAX_RESULTS+1, allocator=context.temp_allocator)
	for &result, index in results {
		result.path = "hit.txt"
		result.line = index
	}
	page := bridge.Workspace_Search_Page{
		generation=8,
		sequence=1,
		count=u64(len(results)),
		results=results,
	}
	testing.expect(t, workspace_search_view_append(&view, page), "current result page should be accepted")
	testing.expect(t, len(view.results) == WORKSPACE_SEARCH_MAX_RESULTS && view.truncated,
	               "workspace result retention must remain bounded")
}

@(test)
test_workspace_search_keyboard_selection_is_bounded :: proc(t: ^testing.T) {
	testing.expect(t, workspace_search_selection_step(4, -1, 1) == 0, "down from no selection should choose the first result")
	testing.expect(t, workspace_search_selection_step(4, -1, -1) == 3, "up from no selection should choose the last result")
	testing.expect(t, workspace_search_selection_step(4, 0, -1) == 0, "up at the first result should not wrap")
	testing.expect(t, workspace_search_selection_step(4, 3, 1) == 3, "down at the last result should not wrap")
	testing.expect(t, workspace_search_selection_step(0, 0, 1) == -1, "empty results have no selection")
}
