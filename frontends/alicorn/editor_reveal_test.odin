package main

import "core:fmt"
import "core:strings"
import "core:testing"
import alicorn "alicorn:runtime"
import bridge "./bridge"

@(test)
test_editor_reveal_request_retains_revision_and_source_destination :: proc(t: ^testing.T) {
	view := Editor_View_State{document_id="document-1"}
	defer editor_reveal_request_clear(&view.reveal_request, context.temp_allocator)

	set := editor_reveal_request_set(
		&view,
		view.document_id,
		17,
		240,
		247,
		12,
		.Center_When_Needed,
		context.temp_allocator,
	)
	testing.expect(t, set, "a source-relative reveal should be retained")
	testing.expect(t, editor_reveal_request_matches(view.reveal_request, view.document_id, 17),
		"the request should match its target document and editor revision")
	testing.expect(t, view.reveal_request.source_start == 240 && view.reveal_request.source_end == 247 &&
		view.reveal_request.logical_line == 12 && view.reveal_request.alignment == .Center_When_Needed,
		"the request should preserve its source range, line, and alignment")
	testing.expect(t, !editor_reveal_request_matches(view.reveal_request, view.document_id, 18),
		"a reveal must not resolve against a different source revision")
	testing.expect(t, !editor_reveal_request_matches(view.reveal_request, "other-document", 17),
		"a reveal must not resolve against another document")

	invalid := editor_reveal_request_set(
		&view,
		view.document_id,
		18,
		248,
		247,
		12,
		.Nearest,
		context.temp_allocator,
	)
	testing.expect(t, !invalid && editor_reveal_request_matches(view.reveal_request, view.document_id, 17),
		"an invalid replacement must leave the previous request intact")
}

@(test)
test_editor_reveal_request_clear_releases_pending_destination :: proc(t: ^testing.T) {
	view := Editor_View_State{document_id="document-2"}
	_ = editor_reveal_request_set(
		&view,
		view.document_id,
		3,
		0,
		0,
		0,
		.Nearest,
		context.temp_allocator,
	)
	editor_reveal_request_clear(&view.reveal_request, context.temp_allocator)
	testing.expect(t, !view.reveal_request.pending && view.reveal_request.document_id == "",
		"clearing a reveal request should erase its owned document identity")
}

@(test)
test_editor_reveal_alignment_centers_only_when_needed :: proc(t: ^testing.T) {
	visible, visible_changed := editor_reveal_content_offset(400, 600, 520, 24, .Center_When_Needed)
	near_edge, edge_changed := editor_reveal_content_offset(400, 600, 960, 24, .Center_When_Needed)
	wrapped, wrapped_changed := editor_reveal_content_offset(400, 600, 1_200, 72, .Center_When_Needed)

	testing.expect(t, !visible_changed && visible == 400,
		"center-aligned reveal should preserve a comfortably visible destination")
	testing.expect(t, edge_changed && near_edge == 672,
		"center-aligned reveal should center an offscreen destination")
	testing.expect(t, wrapped_changed && wrapped == 936,
		"center-aligned reveal should use the full wrapped visual height")
}

@(test)
test_editor_reveal_nearest_alignment_uses_minimal_scroll :: proc(t: ^testing.T) {
	visible, visible_changed := editor_reveal_content_offset(400, 600, 520, 24, .Nearest)
	above, above_changed := editor_reveal_content_offset(400, 600, 390, 24, .Nearest)
	below, below_changed := editor_reveal_content_offset(400, 600, 1_020, 24, .Nearest)

	testing.expect(t, !visible_changed && visible == 400,
		"nearest reveal should preserve a destination already inside the viewport margin")
	testing.expect(t, above_changed && above == 384,
		"nearest reveal should make only the top-edge adjustment required")
	testing.expect(t, below_changed && below == 450,
		"nearest reveal should make only the bottom-edge adjustment required")
}

@(test)
test_go_to_line_resolves_to_revisioned_source_reveal :: proc(t: ^testing.T) {
	line := Editor_Display_Line{
		logical_line=4,
		source_start=100,
		source_end=103,
		display="abc",
		display_bytes=[]u64{100, 101, 102, 103},
	}
	window := Editor_Window{
		document_id="document-goto",
		editor_revision=9,
		start_line=4,
		end_line=5,
		start_byte=100,
		source=[]u8{'a', 'b', 'c'},
		lines=make([dynamic]Editor_Display_Line, 0, allocator=context.temp_allocator),
	}
	append(&window.lines, line)
	view := Editor_View_State{
		document_id="document-goto",
		pending_goto_line=true,
		pending_goto_target_line=4,
		pending_goto_column=3,
	}
	defer editor_reveal_request_clear(&view.reveal_request)

	resolved := editor_view_resolve_goto_line(&view, &window, 8)
	testing.expect(t, resolved, "Go to Line should resolve once its logical line is loaded")
	testing.expect(t, view.caret_byte == 102 && view.selection_anchor == 102,
		"Go to Line should preserve the requested grapheme column as a source byte")
	testing.expect(t,
		editor_reveal_request_matches(view.reveal_request, "document-goto", 9) &&
		view.reveal_request.source_start == 102 && view.reveal_request.source_end == 102 &&
		view.reveal_request.logical_line == 4 && view.reveal_request.alignment == .Center_When_Needed,
		"Go to Line should queue a revisioned, source-byte destination for shared reveal")
}

@(test)
test_editor_reveal_after_frame_resolves_shaped_source_geometry :: proc(t: ^testing.T) {
	line_count := 50
	target_line := 40
	source := make([dynamic]u8, 0, allocator=context.allocator)
	defer delete(source)
	target_line_start := 0
	for line_index in 0..<line_count {
		if line_index > 0 { append(&source, '\n') }
		if line_index == target_line {
			target_line_start = len(source)
			for _ in 0..<360 { append(&source, 'x') }
		} else {
			append(&source, fmt.tprintf("row-%02d", line_index))
		}
	}
	document_id := "editor-reveal-geometry-document"
	source_length := len(source)
	visible := bridge.Visible_Window{
		document_id=document_id,
		application_rev=3,
		editor_revision=7,
		start_line=0,
		end_line=u64(line_count),
		start_byte=0,
		source=source[:],
	}
	window, window_ok, window_error := editor_window_from_visible(&visible, context.allocator)
	source = {}
	testing.expect(t, window_ok, window_error)
	if !window_ok {
		if len(visible.source) > 0 { delete(visible.source, context.allocator) }
		return
	}
	app: App
	app.backend.started = true
	app.backend.state.active = document_id
	app.backend.state.revision = 3
	documents := make([dynamic]bridge.State_Document, 1, allocator=context.allocator)
	app.backend.state.documents = documents[:]
	documents[0] = bridge.State_Document{
		id=document_id,
		path="reveal.go",
		language="go",
		status="ready",
		editor_revision=7,
		line_count=u64(line_count),
		byte_length=u64(source_length),
	}
	app.editor_window = window
	app.editor_window_ready = true
	app.editor_views = make([dynamic]Editor_View_State, 0, allocator=context.allocator)
	app.editor_row_targets = make([dynamic]Editor_Row_Target, 0, allocator=context.allocator)
	view_index, view_ok := editor_view_ensure(&app.editor_views, document_id)
	testing.expect(t, view_ok, "a source-relative reveal should have retained document view state")
	if !view_ok {
		delete(documents)
		delete(app.editor_views)
		delete(app.editor_row_targets)
		editor_window_destroy(&app.editor_window, context.allocator)
		return
	}
	view := &app.editor_views[view_index]
	view.authoritative_revision = 7
	request_start := u64(target_line_start+300)
	_ = editor_reveal_request_set(
		view,
		document_id,
		7,
		request_start,
		request_start+5,
		u64(target_line),
		.Center_When_Needed,
	)
	init_menus(&app)
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 900, 420})
	defer {
		editor_window_destroy(&app.editor_window, context.allocator)
		editor_views_destroy(&app.editor_views, context.allocator)
		if len(app.editor_presented_document_id) > 0 { delete(app.editor_presented_document_id, context.allocator) }
		delete(app.editor_views)
		delete(app.editor_row_targets)
		delete(documents)
		alicorn.destroy_runtime(&rt)
	}
	fonts_loaded := alicorn.text_engine_load_font(&rt.text_engine, ALICORN_TEST_UI_FONT_DATA) &&
	                alicorn.text_engine_load_font_role(&rt.text_engine, .Monospace, ALICORN_TEST_MONO_FONT_DATA)
	testing.expect(t, fonts_loaded, "reveal geometry should use the same shaped monospace rows as the editor")
	if !fonts_loaded { return }
	for _ in 0..<5 {
		_ = build_app(rawptr(&app), &rt, 900, 420, 1)
		owner := alicorn.scroll_region_state(&rt, app.editor_scroll_owner)
		if owner.offset_y > 0.5 && owner.offset_x > 0.5 && !view.reveal_request.pending { break }
	}
	owner := alicorn.scroll_region_state(&rt, app.editor_scroll_owner)
	testing.expect(t, owner.offset_y > 0.5,
		"after-frame reveal should scroll the destination row into the vertical viewport")
	testing.expect(t, owner.offset_x > 0.5,
		"after-frame reveal should use shaped source geometry to reveal the horizontal match range")
	testing.expect(t, !view.reveal_request.pending,
		"the shared request should clear after both axes have been resolved")
	target, target_found := editor_row_target_for_source(app.editor_row_targets[:], u64(target_line), request_start)
	testing.expect(t, target_found, "the destination row should be realized by the frame before reveal resolves")
	if target_found {
		line, line_found := editor_window_line(&app.editor_window, u64(target_line))
		display_line, display_found := editor_display_line_for_target(&app.editor_window, line, target)
		start_display := editor_source_to_display(&display_line, request_start)
		end_display := editor_source_to_display(&display_line, request_start+5)
		start_geometry := alicorn.text_node_caret_geometry(&rt, target.node, alicorn.Text_Position{byte=start_display, affinity=.Leading})
		end_geometry := alicorn.text_node_caret_geometry(&rt, target.node, alicorn.Text_Position{byte=end_display, affinity=.Trailing})
		owner_node, owner_found := rt.nodes[app.editor_scroll_owner]
		visible := line_found && display_found && start_geometry.valid && end_geometry.valid && owner_found &&
		           min(start_geometry.rect.x, end_geometry.rect.x) >= owner_node.scroll_viewport_bounds.x &&
		           max(start_geometry.rect.x, end_geometry.rect.x) <= owner_node.scroll_viewport_bounds.x+owner_node.scroll_viewport_width &&
		           min(start_geometry.rect.y, end_geometry.rect.y) >= owner_node.scroll_viewport_bounds.y &&
		           max(start_geometry.rect.y, end_geometry.rect.y) <= owner_node.scroll_viewport_bounds.y+owner_node.scroll_viewport_height
		testing.expect(t, visible,
			"the exact source range should end within the retained viewport after resolution")
	}
}
