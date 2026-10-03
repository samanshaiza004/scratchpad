package main

import "core:mem"
import "core:fmt"
import "core:testing"
import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"
import bridge "./bridge"

pointer_test_window :: proc(t: ^testing.T) -> (window: Editor_Window, ok: bool) {
	text := "one two\nhello 世界\r\nlast"
	source, source_error := make([]u8, len(text), allocator=context.allocator)
	if source_error != nil {
		testing.expect(t, false, "pointer selection fixture should allocate source bytes")
		return {}, false
	}
	if len(source) > 0 { mem.copy(rawptr(&source[0]), rawptr(raw_data(text)), len(text)) }
	visible := bridge.Visible_Window{
		document_id="pointer-selection-test",
		application_rev=1,
		editor_revision=1,
		start_line=0,
		end_line=3,
		start_byte=0,
		line_byte_length=u64(len(source)),
		source=source,
	}
	loaded_window, loaded_ok, message := editor_window_from_visible(&visible, context.allocator)
	if !loaded_ok { testing.expect(t, false, message) }
	return loaded_window, loaded_ok
}

@(test)
test_pointer_click_selection_matches_native_granularity :: proc(t: ^testing.T) {
	window, ok := pointer_test_window(t)
	if !ok { return }
	defer editor_window_destroy(&window)

	view := Editor_View_State{selection_anchor=1, caret_byte=1}
	if !editor_apply_pointer_selection(&view, &window, 5, .Leading, 2, false) {
		testing.expect(t, false, "double-click should select a Unicode word range")
		return
	}
	testing.expect(t, view.selection_anchor == 4 && view.caret_byte == 7 && view.drag_selection_granularity == .Word,
		"double-click inside 'two' should select its full word range")

	// The runtime's UAX #29 segmentation must keep the multi-byte letters as
	// one legal source interval regardless of byte position inside the word.
	if start, end, found := editor_word_selection_range(&window, 15); found {
		testing.expect(t, start == 14 && end >= 17 && end <= 20,
			"double-click inside CJK text should select a complete Unicode word/grapheme range")
	} else {
		testing.expect(t, false, "double-click inside non-ASCII text should return a word range")
	}
}

@(test)
test_shift_click_and_word_drag_preserve_selection_direction :: proc(t: ^testing.T) {
	window, ok := pointer_test_window(t)
	if !ok { return }
	defer editor_window_destroy(&window)

	view := Editor_View_State{selection_anchor=1, caret_byte=3}
	_ = editor_apply_pointer_selection(&view, &window, 7, .Trailing, 1, true)
	testing.expect(t, view.selection_anchor == 1 && view.caret_byte == 7,
		"Shift-click should keep the original anchor and move only the active end")

	_ = editor_apply_pointer_selection(&view, &window, 5, .Leading, 2, false)
	_ = editor_extend_pointer_selection(&view, &window, 1, .Leading)
	testing.expect(t, view.selection_anchor == 7 && view.caret_byte == 0,
		"word drag to the left should reverse direction while preserving the initial word's far edge")
	_ = editor_extend_pointer_selection(&view, &window, 15, .Leading)
	testing.expect(t, view.selection_anchor == 4 && view.caret_byte >= 17,
		"word drag to a later line should extend by complete Unicode word ranges")
}

@(test)
test_triple_click_selects_logical_line_without_line_ending :: proc(t: ^testing.T) {
	window, ok := pointer_test_window(t)
	if !ok { return }
	defer editor_window_destroy(&window)

	view: Editor_View_State
	_ = editor_apply_pointer_selection(&view, &window, 10, .Leading, 3, false)
	testing.expect(t, view.selection_anchor == 8 && view.caret_byte == 20 && view.drag_selection_granularity == .Line,
		"triple-click should select logical line content without its CRLF terminator")

	_ = editor_extend_pointer_selection(&view, &window, 23, .Leading)
	testing.expect(t, view.selection_anchor == 8 && view.caret_byte == 26,
		"line-granularity drag should extend through the target line")
	_ = editor_extend_pointer_selection(&view, &window, 2, .Leading)
	testing.expect(t, view.selection_anchor == 20 && view.caret_byte == 0,
		"line-granularity drag should reverse direction without losing its original edge")
}

@(test)
test_pointer_selection_autoscroll_step_is_bounded_and_monotonic :: proc(t: ^testing.T) {
	small := editor_selection_autoscroll_step(1)
	large := editor_selection_autoscroll_step(1000)
	testing.expect(t, small > 0 && large == EDITOR_SELECTION_AUTOSCROLL_MAX_STEP,
		"selection autoscroll should progress outside the viewport and cap each step")
	testing.expect(t, editor_selection_autoscroll_step(20) > small,
		"selection autoscroll should accelerate with pointer distance beyond the viewport")
}

Pointer_Autoscroll_Test_Scheduler :: struct {
	schedule_count: int,
	cancel_count: int,
	last_class: host.Scheduled_Wake_Class,
	last_delay_ns: u64,
}

pointer_autoscroll_test_schedule :: proc(data: rawptr, class: host.Scheduled_Wake_Class, delay_ns: u64) -> bool {
	scheduler := cast(^Pointer_Autoscroll_Test_Scheduler)data
	if scheduler == nil { return false }
	scheduler.schedule_count += 1
	scheduler.last_class = class
	scheduler.last_delay_ns = delay_ns
	return true
}

pointer_autoscroll_test_cancel :: proc(data: rawptr, class: host.Scheduled_Wake_Class) -> bool {
	scheduler := cast(^Pointer_Autoscroll_Test_Scheduler)data
	if scheduler == nil { return false }
	scheduler.cancel_count += 1
	scheduler.last_class = class
	return true
}

pointer_autoscroll_test_scheduler_stats :: proc(data: rawptr) -> host.Application_Scheduler_Stats {
	return {}
}

@(test)
test_editor_pointer_autoscrolls_both_axes_and_repeats_for_stationary_drag :: proc(t: ^testing.T) {
	line_count := 64
	source := make([dynamic]u8, 0, line_count*220, allocator=context.allocator)
	for line_index in 0..<line_count {
		line := fmt.tprintf("row-%02d %s\n", line_index, "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")
		append(&source, line)
	}
	visible := bridge.Visible_Window{
		document_id="pointer-autoscroll-document",
		application_rev=1,
		editor_revision=1,
		start_line=0,
		end_line=u64(line_count),
		start_byte=0,
		line_byte_length=u64(len(source)),
		source=source[:],
	}
	window, window_ok, window_error := editor_window_from_visible(&visible, context.allocator)
	testing.expect(t, window_ok, window_error)
	if !window_ok {
		if len(visible.source) > 0 { delete(visible.source, context.allocator) }
		delete(source)
		return
	}

	app: App
	app.backend.started = true
	app.backend.state.active = "pointer-autoscroll-document"
	app.backend.state.revision = 1
	documents := make([dynamic]bridge.State_Document, 1, allocator=context.allocator)
	documents[0] = bridge.State_Document{
		id="pointer-autoscroll-document",
		editor_revision=1,
		line_count=u64(line_count),
		byte_length=u64(len(window.source)),
	}
	app.backend.state.documents = documents[:]
	app.editor_window = window
	app.editor_window_ready = true
	app.editor_views = make([dynamic]Editor_View_State, 0, allocator=context.allocator)
	app.editor_row_targets = make([dynamic]Editor_Row_Target, 0, allocator=context.allocator)
	scheduler_state := Pointer_Autoscroll_Test_Scheduler{}
	app.services.scheduler = host.Application_Scheduler{
		data=rawptr(&scheduler_state),
		schedule=pointer_autoscroll_test_schedule,
		cancel=pointer_autoscroll_test_cancel,
		read_stats=pointer_autoscroll_test_scheduler_stats,
	}
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 520, 220})
	defer {
		editor_window_destroy(&app.editor_window)
		editor_views_destroy(&app.editor_views)
		delete(documents)
		delete(app.editor_row_targets)
		alicorn.destroy_runtime(&rt)
	}
	font_loaded := alicorn.text_engine_load_font_role(&rt.text_engine, .Monospace, ALICORN_TEST_MONO_FONT_DATA)
	testing.expect(t, font_loaded, "pointer drag fixture should load the monospace font used for hit testing")
	ui, should_build := alicorn.begin_frame(&rt)
	if !should_build { testing.expect(t, false, "pointer drag fixture should build the scroll owner"); return }
	alicorn.container_begin(&ui, .Root, key=alicorn.key_string("pointer-autoscroll-root"), style=alicorn.layout_style(.Column, grow=1))
	list := alicorn.virtual_list_begin(
		&ui,
		line_count,
		EDITOR_ROW_HEIGHT,
		key=alicorn.key_string("pointer-autoscroll-list"),
		style=alicorn.layout_style(grow=1, clip=true),
		content_width=2_400,
		label="pointer-autoscroll-list",
		axes=.Both,
		focusable=true,
	)
	app.editor_scroll_owner = list.scroll.id
	_ = alicorn.text_input_target(&ui, list.scroll.id)
	for position := list.first; position < list.last; position += 1 {
		line, found := editor_window_line(&app.editor_window, u64(position))
		if !found { continue }
		text_node := alicorn.text(&ui, line.display,
			key=alicorn.key_u64(u64(position)),
			style=alicorn.layout_style(.Row, height=EDITOR_ROW_HEIGHT),
			font=.Monospace,
		)
		append(&app.editor_row_targets, Editor_Row_Target{node=text_node, logical_line=u64(position)})
	}
	alicorn.virtual_list_end(&ui, list)
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
	view_index, view_ok := editor_view_ensure(&app.editor_views, app.backend.state.active)
	testing.expect(t, view_ok && app.editor_scroll_owner != 0 && len(app.editor_row_targets) > 0,
		"pointer drag fixture should retain a focused virtual editor list and visible rows")
	if !view_ok || app.editor_scroll_owner == 0 || len(app.editor_row_targets) == 0 { return }
	view := &app.editor_views[view_index]
	view.authoritative_revision = 1
	owner_before_node, owner_found := rt.nodes[app.editor_scroll_owner]
	first_row, first_row_found := rt.nodes[app.editor_row_targets[0].node]
	if !owner_found || !first_row_found { testing.expect(t, false, "pointer drag fixture should resolve laid-out viewport geometry"); return }
	owner_before := owner_before_node^
	viewport := alicorn.scroll_region_state(&rt, app.editor_scroll_owner).viewport_bounds
	start_x := first_row.bounds.x+30
	start_y := first_row.bounds.y+first_row.bounds.h/2
	down := alicorn.Pointer_Event{kind=.Down, x=start_x, y=start_y, button=1, click_count=1}
	target := alicorn.process_pointer(&rt, down)
	testing.expect(t, target == app.editor_scroll_owner, "pointer-down should capture the durable editor scroll owner")
	editor_pointer(rawptr(&app), &rt, down, target)
	if target != app.editor_scroll_owner { return }
	move := alicorn.Pointer_Event{
		kind=.Move,
		x=viewport.x+viewport.w+80,
		y=viewport.y+viewport.h+80,
	}
	move_target := alicorn.process_pointer(&rt, move)
	editor_pointer(rawptr(&app), &rt, move, move_target)
	owner_after_move_node := rt.nodes[app.editor_scroll_owner]
	owner_after_move := owner_after_move_node^
	testing.expect(t, owner_after_move.scroll_offset_y > owner_before.scroll_offset_y && owner_after_move.scroll_offset_x > owner_before.scroll_offset_x,
		fmt.tprintf("a captured selection dragged beyond the lower-right viewport should advance both offsets (captured=%d dragging=%v owner=%d viewport=%v pointer=%v,%v offsets=%v,%v -> %v,%v ranges=%v,%v)",
			rt.captured_node, view.dragging_selection, app.editor_scroll_owner, viewport,
			move.x, move.y, owner_before.scroll_offset_x, owner_before.scroll_offset_y,
			owner_after_move.scroll_offset_x, owner_after_move.scroll_offset_y,
			owner_before.scroll_content_width, owner_before.scroll_content_height))
	testing.expect(t, scheduler_state.schedule_count == 1 && scheduler_state.last_class == .Frequent &&
		scheduler_state.last_delay_ns == EDITOR_SELECTION_AUTOSCROLL_INTERVAL_NS,
		"active out-of-bounds autoscroll should schedule one bounded Frequent wake")

	first_y, first_x := owner_after_move.scroll_offset_y, owner_after_move.scroll_offset_x
	// No further pointer motion is dispatched. The one-shot wake must continue
	// scrolling from the retained pointer coordinates and arm the next step.
	application_scheduled_wake(rawptr(&app), &rt, .Frequent)
	owner_after_wake_node := rt.nodes[app.editor_scroll_owner]
	owner_after_wake := owner_after_wake_node^
	testing.expect(t, owner_after_wake.scroll_offset_y > first_y && owner_after_wake.scroll_offset_x > first_x,
		"the scheduled selection wake should continue scrolling while the pointer stays stationary outside")
	testing.expect(t, scheduler_state.schedule_count == 2,
		"continued stationary-pointer scrolling should rearm exactly one next wake")

	up := alicorn.Pointer_Event{kind=.Up, x=move.x, y=move.y, button=1}
	_ = alicorn.process_pointer(&rt, up)
	editor_pointer(rawptr(&app), &rt, up, 0)
	testing.expect(t, scheduler_state.cancel_count > 0 && !view.dragging_selection,
		"pointer release should cancel autoscroll and clear the captured selection state")
}
