package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"
import bridge "./bridge"

editor_paste_test_frame :: proc(app: ^App, rt: ^alicorn.Runtime) {
	document, found := find_document(&app.backend.state, app.backend.state.active)
	if !found { return }
	editor_stale_window_test_render(app, rt, document)
	editor_view_restore_after_frame(app, rt, app.editor_scroll_owner)
	editor_reveal_after_frame(app, rt)
}

editor_paste_test_caret :: proc(app: ^App, rt: ^alicorn.Runtime) -> (caret, viewport: alicorn.Rect, ok: bool) {
	document, found := find_document(&app.backend.state, app.backend.state.active)
	if !found { return }
	index := editor_view_find(app.editor_views[:], document.id)
	if index < 0 { return }
	view := &app.editor_views[index]
	window, matches := editor_view_window(view, &app.editor_window, app.editor_window_ready, document.id, document.editor_revision)
	if !matches { return }
	line, line_found := editor_line_for_source(window, view.caret_byte)
	if !line_found { return }
	target, target_found := editor_row_target_for_source(app.editor_row_targets[:], line.logical_line, view.caret_byte)
	if !target_found { return }
	geometry := alicorn.text_node_caret_geometry(rt, target.node,
		alicorn.Text_Position{byte=editor_source_to_display(line, view.caret_byte), affinity=view.caret_affinity})
	owner, owner_found := alicorn.node_info(rt, app.editor_scroll_owner)
	return geometry.rect, owner.scroll_viewport_bounds, geometry.valid && owner_found
}

@(test)
test_editor_paste_preserves_visible_caret_viewport :: proc(t: ^testing.T) {
	editor_paste_test_viewport(t, .Visible)
}

@(test)
test_editor_paste_preserves_caret_inside_tall_wrapped_line :: proc(t: ^testing.T) {
	editor_paste_test_viewport(t, .Wrapped)
}

@(test)
test_editor_paste_reveals_caret_near_viewport_edge :: proc(t: ^testing.T) {
	editor_paste_test_viewport(t, .Edge)
}

@(test)
test_editor_paste_reveals_end_of_long_multiline_paste :: proc(t: ^testing.T) {
	editor_paste_test_viewport(t, .Long)
}

Editor_Paste_Test_Case :: enum { Visible, Wrapped, Edge, Long }

editor_paste_test_viewport :: proc(t: ^testing.T, scenario: Editor_Paste_Test_Case) {
	sync.mutex_lock(&backend_integration_test_mutex)
	defer sync.mutex_unlock(&backend_integration_test_mutex)
	workspace, workspace_error := os.make_directory_temp("", "scratchpad-paste-viewport-*", context.temp_allocator)
	if workspace_error != nil { testing.expect(t, false, "temporary paste workspace should allocate"); return }
	defer _ = os.remove_all(workspace)
	path := fmt.tprintf("%s/paste.md", workspace)
	source := make([dynamic]u8, 0, allocator=context.temp_allocator)
	defer delete(source)
	for line in 0..<80 {
		if line%3 == 0 {
			append(&source, fmt.tprintf("## Heading %d\n", line))
		} else {
			if line == 32 && scenario == .Wrapped {
				for _ in 0..<8 { append(&source, "More wrapped prose to make one logical line taller than the viewport. ") }
			}
			append(&source, "A Markdown paragraph with **strong text** and wrapped prose. A Markdown paragraph with **strong text** and wrapped prose. A Markdown paragraph with **strong text** and wrapped prose.\n")
		}
	}
	if os.write_entire_file_from_string(path, string(source[:])) != nil {
		testing.expect(t, false, "temporary Markdown fixture should be written"); return
	}
	library, found_library := os.lookup_env("SCRATCHPAD_BACKEND_LIBRARY", context.temp_allocator)
	if !found_library { testing.expect(t, false, "paste integration needs the staged backend"); return }
	defer delete(library, context.temp_allocator)
	app: App
	loaded, load_error := bridge.backend_load(&app.backend, library)
	if !loaded { testing.expect(t, false, load_error); return }
	started, start_error := bridge.backend_start(&app.backend, workspace, tree_test_wake, nil)
	if !started { testing.expect(t, false, start_error); return }
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 800, 180})
	paste := "Z"
	if scenario == .Edge { paste = "\nnew row" }
	if scenario == .Long { paste = "\nfirst\nsecond\nthird\nfourth\nfifth\nsixth\nseventh\neighth\nninth\ntenth\nlast" }
	clipboard := Editor_Test_Clipboard{text=paste, read_ok=true, write_ok=true}
	app.services.clipboard = host.Clipboard_Service{data=rawptr(&clipboard), get_text=editor_test_clipboard_get_text, set_text=editor_test_clipboard_set_text}
	app.editor_views = make([dynamic]Editor_View_State, 0, allocator=context.allocator)
	app.editor_row_targets = make([dynamic]Editor_Row_Target, 0, allocator=context.allocator)
	defer {
		_ = bridge.visible_window_lane_stop(&app.visible_window_lane)
		editor_window_destroy(&app.editor_window)
		editor_views_destroy(&app.editor_views)
		tree_clear_directories(&app)
		tree_clear_focused_path(&app)
		if len(app.tree_root_path) > 0 { delete(app.tree_root_path) }
		delete(app.editor_row_targets)
		if len(app.editor_presented_document_id) > 0 { delete(app.editor_presented_document_id) }
		if len(app.editor_window_error) > 0 { delete(app.editor_window_error) }
		if len(app.error_message) > 0 { delete(app.error_message) }
		editor_window_rejection_clear(&app)
		alicorn.destroy_runtime(&rt)
		if app.backend.started {
			stopped, stop_error := bridge.backend_stop(&app.backend)
			testing.expect(t, stopped, stop_error)
		}
	}
	opened := bridge.backend_command(&app.backend, "open_path", path=path)
	testing.expect(t, opened.ok, "the real backend should open the Markdown fixture")
	bridge.backend_command_result_destroy(&opened, context.allocator)
	document, document_found := find_document(&app.backend.state, app.backend.state.active)
	if !document_found { testing.expect(t, false, "opened paste document should be published"); return }
	visible := bridge.backend_command(&app.backend, "read_visible_lines", document_id=document.id,
		start_line=0, max_lines=bridge.MAX_VISIBLE_LINES, max_bytes=bridge.MAX_VISIBLE_BYTES, include_presentation=true)
	window, converted, conversion_error := editor_window_from_visible(&visible.visible_window)
	bridge.backend_command_result_destroy(&visible, context.allocator)
	if !converted { testing.expect(t, false, conversion_error); return }
	app.editor_window, app.editor_window_ready = window, true
	if !alicorn.text_engine_load_font(&rt.text_engine, ALICORN_TEST_UI_FONT_DATA) ||
	   !alicorn.text_engine_load_font_role(&rt.text_engine, .Monospace, ALICORN_TEST_MONO_FONT_DATA) {
		testing.expect(t, false, "paste viewport should use real shaped editor fonts"); return
	}
	for _ in 0..<3 { editor_paste_test_frame(&app, &rt) }
	view_index := editor_view_find(app.editor_views[:], document.id)
	if view_index < 0 { testing.expect(t, false, "editor should retain view state"); return }
	view := &app.editor_views[view_index]
	line, line_found := editor_window_line(&app.editor_window, 32)
	if !line_found { testing.expect(t, false, "paste line should be loaded"); return }
	caret_offset := u64(5)
	if scenario == .Wrapped { caret_offset = 410 }
	view.selection_anchor, view.caret_byte = line.source_start+caret_offset, line.source_start+caret_offset
	line_top := alicorn.virtual_list_height_index_item_top(&view.wrap_height_index, 32)
	run, run_ok := editor_navigation_text_run(&rt, &app.editor_window, line, "markdown", view.wrap_measurement_width, true)
	if !run_ok { testing.expect(t, false, "paste caret should shape"); return }
	geometry := alicorn.text_run_caret_geometry(&run, alicorn.Text_Position{byte=int(caret_offset), affinity=.Trailing}, context.temp_allocator)
	caret_y := f32(55)
	if scenario == .Edge { caret_y = 115 }
	_ = alicorn.scroll_region_set_offset(&rt, app.editor_scroll_owner, line_top+geometry.rect.y-caret_y, "place the paste caret inside a nonzero viewport")
	alicorn.text_run_destroy(&run)
	for _ in 0..<3 { editor_paste_test_frame(&app, &rt) }
	before := alicorn.scroll_region_state(&rt, app.editor_scroll_owner)
	testing.expect(t, before.offset_y > 500 && alicorn.virtual_list_height_index_item_height(&view.wrap_height_index, 32) > EDITOR_ROW_HEIGHT,
		"fixture should have a nonzero scroll offset and variable-height wrapped Markdown")
	caret_rect, viewport, caret_found := editor_paste_test_caret(&app, &rt)
	testing.expect(t, caret_found && caret_rect.y > viewport.y+8 && caret_rect.y+caret_rect.h < viewport.y+viewport.h,
		"paste must begin with its actual shaped caret visible away from the top edge")
	if scenario == .Wrapped {
		testing.expect(t, alicorn.virtual_list_height_index_item_height(&view.wrap_height_index, 32) > before.viewport_height,
			"the wrapped regression must begin inside a logical line taller than the viewport")
	}
	caret_before := view.caret_byte
	editor_clipboard_command(&app, &rt, ACTION_EDIT_PASTE)
	testing.expect(t, clipboard.reads == 1 && view.caret_byte == caret_before+u64(len(paste)) && view.selection_anchor == view.caret_byte,
		"real clipboard paste and backend selection should insert text and collapse the caret")
	for _ in 0..<6 {
		editor_paste_test_frame(&app, &rt)
		if scenario == .Visible || scenario == .Wrapped {
			frame := alicorn.scroll_region_state(&rt, app.editor_scroll_owner)
			testing.expect(t, abs(frame.offset_y-before.offset_y) < 0.5,
				fmt.tprintf("each paste frame must preserve an already visible caret: before=%v after=%v", before.offset_y, frame.offset_y))
		}
	}
	after := alicorn.scroll_region_state(&rt, app.editor_scroll_owner)
	if scenario == .Visible || scenario == .Wrapped {
		testing.expect(t, abs(after.offset_y-before.offset_y) < 0.5,
			fmt.tprintf("paste at an already visible caret must preserve the viewport: before=%v after=%v", before.offset_y, after.offset_y))
	} else {
		testing.expect(t, after.offset_y > before.offset_y && (scenario == .Long || after.offset_y-before.offset_y < 90),
			fmt.tprintf("paste should reveal its new caret with minimal edge scrolling: before=%v after=%v", before.offset_y, after.offset_y))
	}
	testing.expect(t, !view.reveal_request.pending,
		"the exact acknowledged optimistic source should resolve the reveal before the asynchronous base window arrives")
	caret_rect, viewport, caret_found = editor_paste_test_caret(&app, &rt)
	testing.expect(t, caret_found && caret_rect.y >= viewport.y && caret_rect.y+caret_rect.h <= viewport.y+viewport.h,
		"the post-paste source caret must be fully visible, including a long paste's final row")

	// Start the real window lane only now: the old authoritative base stayed
	// installed throughout paste and its first frames. Refresh with a different
	// bounded source range, then deliver it through the production wake handler.
	signal: Editor_Edit_Test_Signal
	if !bridge.visible_window_lane_start(&app.visible_window_lane, &app.backend, editor_edit_test_wake, rawptr(&signal)) {
		testing.expect(t, false, "asynchronous source-window lane should start"); return
	}
	document, _ = find_document(&app.backend.state, app.backend.state.active)
	generation, accepted, message := bridge.visible_window_lane_request(&app.visible_window_lane,
		document.id, app.backend.state.application_rev, document.editor_revision, 26, bridge.MAX_VISIBLE_LINES, bridge.MAX_VISIBLE_BYTES,
		include_presentation=true, presentation_revision=document.presentation_revision, presentation_ready=document.presentation_ready)
	if !accepted { testing.expect(t, false, message); return }
	// Even a completed real request must not replace the presentation after its
	// application generation was superseded.
	app.editor_request_generation = generation+1
	wait_started := time.tick_now()
	for time.tick_since(wait_started) < 5*time.Second {
		sync.mutex_lock(&app.visible_window_lane.mutex)
		completed := app.visible_window_lane.completed_ready
		sync.mutex_unlock(&app.visible_window_lane.mutex)
		if completed { break }
		time.sleep(time.Millisecond)
	}
	application_visible_window_wake(&app, &rt, &app.visible_window_lane)
	testing.expect(t, app.editor_window.editor_revision != document.editor_revision && view.optimistic_window_ready,
		"a superseded asynchronous generation must leave the acknowledged source projection intact")
	generation, accepted, message = bridge.visible_window_lane_request(&app.visible_window_lane,
		document.id, app.backend.state.application_rev, document.editor_revision, 26, bridge.MAX_VISIBLE_LINES, bridge.MAX_VISIBLE_BYTES,
		include_presentation=true, presentation_revision=document.presentation_revision, presentation_ready=document.presentation_ready)
	if !accepted { testing.expect(t, false, message); return }
	app.editor_request_generation = generation
	wait_started = time.tick_now()
	for time.tick_since(wait_started) < 5*time.Second {
		application_visible_window_wake(&app, &rt, &app.visible_window_lane)
		if app.editor_window.editor_revision == document.editor_revision && app.editor_window.start_line == 26 { break }
		time.sleep(time.Millisecond)
	}
	testing.expect(t, app.editor_window.editor_revision == document.editor_revision && app.editor_window.start_line == 26 && !view.optimistic_window_ready,
		"the matching asynchronous response should replace the old base and acknowledged projection")
	for _ in 0..<4 { editor_paste_test_frame(&app, &rt) }
	refreshed := alicorn.scroll_region_state(&rt, app.editor_scroll_owner)
	testing.expect(t, abs(refreshed.offset_y-after.offset_y) < 0.5,
		fmt.tprintf("source-window refresh must retain the resolved viewport: before=%v after=%v", after.offset_y, refreshed.offset_y))
	fmt.printf("paste %v: scroll before=%v resolved=%v refreshed=%v; reveal pending=%v\n", scenario, before.offset_y, after.offset_y, refreshed.offset_y, view.reveal_request.pending)
}

@(test)
test_editor_selection_restore_retains_heights_only_for_matching_source :: proc(t: ^testing.T) {
	cases := [?]struct { source_id: string, source_revision: u64, source_ready, optimistic, preserve: bool }{
		{"selection-doc", 5, true, false, true},
		{"selection-doc", 5, true, true, true},
		{"other-doc", 5, true, false, false},
		{"other-doc", 5, true, true, false},
		{"selection-doc", 4, true, false, false},
		{"selection-doc", 4, true, true, false},
		{"selection-doc", 5, false, false, false},
	}
	for fixture in cases {
		app: App
		documents := [?]bridge.State_Document{{id="selection-doc", editor_revision=5, line_count=50, byte_length=100}}
		app.backend.state.documents = documents[:]
		app.editor_views = make([dynamic]Editor_View_State, 0, allocator=context.allocator)
		index, _ := editor_view_ensure(&app.editor_views, "selection-doc")
		view := &app.editor_views[index]
		view.authoritative_revision = 5
		view.wrap_height_index_ready = alicorn.virtual_list_height_index_init(&view.wrap_height_index, 50, EDITOR_ROW_HEIGHT)
		_ = alicorn.virtual_list_height_index_set_height(&view.wrap_height_index, 3, 88)
		if fixture.optimistic {
			view.optimistic_window.document_id, _ = strings.clone(fixture.source_id)
			view.optimistic_window.editor_revision = fixture.source_revision
			view.optimistic_window_ready = fixture.source_ready
		} else {
			app.editor_window = Editor_Window{document_id=fixture.source_id, editor_revision=fixture.source_revision}
			app.editor_window_ready = fixture.source_ready
		}
		rt := alicorn.new_runtime(alicorn.Rect{0, 0, 300, 200})
		editor_apply_backend_selection(&app, &rt,
			bridge.Editor_Selection{document_id="selection-doc", editor_revision=5, anchor_byte=4, cursor_byte=4})
		height := alicorn.virtual_list_height_index_item_height(&view.wrap_height_index, 3)
		testing.expect(t, height == (f32(88) if fixture.preserve else EDITOR_ROW_HEIGHT),
			fmt.tprintf("selection restore source identity must control cached heights: fixture=%v height=%v", fixture, height))
		editor_views_destroy(&app.editor_views)
		alicorn.destroy_runtime(&rt)
	}
}
