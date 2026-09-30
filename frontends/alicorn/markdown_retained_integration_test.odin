package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"
import bridge "./bridge"

markdown_test_wake :: proc(data: rawptr) {
	if data == nil { return }
	signal := cast(^Editor_Edit_Test_Signal)data
	sync.sema_post(&signal.sema)
}

@(test)
test_markdown_metadata_pending_to_ready_keeps_retained_row_geometry :: proc(t: ^testing.T) {
	sync.mutex_lock(&backend_integration_test_mutex)
	defer sync.mutex_unlock(&backend_integration_test_mutex)
	workspace, workspace_error := os.make_directory_temp("", "scratchpad-alicorn-markdown-*", context.temp_allocator)
	if workspace_error != nil { testing.expect(t, false, "could not create Markdown integration workspace"); return }
	defer _ = os.remove_all(workspace)
	path := fmt.tprintf("%s/notes.md", workspace)
	source := make([dynamic]u8, 0, allocator=context.temp_allocator)
	defer delete(source)
	// Keep the retained first row paint-only so this integration check continues
	// to prove paint metadata reuses the original shaped run. Typography spans
	// intentionally reshape their own text ranges and are covered separately.
	append(&source, "Stable text with [link](https://example.test) only.\n\n# Metric stable\n\nOpening text with **bold**, *emphasis*, [link](https://example.test), and `inline code`.\n")
	append(&source, "Soft-wrap regression paragraph: ")
	for _ in 0..<10 {
		append(&source, "A source sentence with **strong text**, *emphasis*, and enough ordinary prose to cross the editor's visual-row boundary. ")
	}
	append(&source, '\n')
	for index in 0..<1200 {
		line := fmt.tprintf("paragraph-%04d with **bold text** and `code`\n", index)
		append(&source, line)
	}
	if err := os.write_entire_file_from_string(path, string(source[:])); err != nil {
		testing.expect(t, false, "could not write Markdown integration fixture")
		return
	}
	backend_library, found_library := os.lookup_env("SCRATCHPAD_BACKEND_LIBRARY", context.temp_allocator)
	if !found_library { testing.expect(t, false, "Markdown integration requires the staged shared backend"); return }
	defer delete(backend_library, context.temp_allocator)
	app: App
	app.tree_directories = make([dynamic]Tree_Directory, 0, allocator=context.allocator)
	app.editor_views = make([dynamic]Editor_View_State, 0, allocator=context.allocator)
	app.editor_row_targets = make([dynamic]Editor_Row_Target, 0, allocator=context.allocator)
	init_menus(&app)
	loaded, load_message := bridge.backend_load(&app.backend, backend_library)
	testing.expect(t, loaded, fmt.tprintf("shared backend should load for Markdown integration: %s", load_message))
	if !loaded { return }
	signal: Editor_Edit_Test_Signal
	started, start_message := bridge.backend_start(&app.backend, workspace, markdown_test_wake, rawptr(&signal), context.allocator)
	testing.expect(t, started, fmt.tprintf("shared backend should start for Markdown integration: %s", start_message))
	if !started { return }
	opened := bridge.backend_command(&app.backend, "open_path", path=path, allocator=context.allocator)
	testing.expect(t, opened.ok && len(app.backend.state.documents) == 1, "Go should open a real Markdown document")
	bridge.backend_command_result_destroy(&opened, context.allocator)
	document, document_found := find_document(&app.backend.state, app.backend.state.active)
	testing.expect(t, document_found && document.language == "markdown", "the source path should select Go's Markdown projection")
	if !document_found { _, _ = bridge.backend_stop(&app.backend, context.allocator); return }
	document_id, document_id_error := strings.clone(document.id, context.allocator)
	if document_id_error != nil { testing.expect(t, false, "could not retain Markdown document identity across state refreshes"); _, _ = bridge.backend_stop(&app.backend, context.allocator); return }
	defer delete(document_id, context.allocator)
	bootstrap := bridge.backend_command(
		&app.backend, "read_visible_lines", document_id=document.id, start_line=0,
		max_lines=bridge.MAX_VISIBLE_LINES, max_bytes=bridge.MAX_VISIBLE_BYTES,
		include_presentation=true, allocator=context.allocator,
	)
	testing.expect(t, bootstrap.ok && bootstrap.visible_window_owned,
		"the first opted-in Go resource should enable the Markdown readiness coordinator")
	bridge.backend_command_result_destroy(&bootstrap, context.allocator)
	ready_observed := false
	for _ in 0..<300 {
		_, _, _ = bridge.backend_consume_wake(&app.backend, context.allocator)
		if current, found := find_document(&app.backend.state, document_id); found && current.presentation_ready && current.presentation_revision == current.editor_revision {
			ready_observed = true
			break
		}
		_ = sync.sema_wait_with_timeout(&signal.sema, time.Duration(10_000_000))
	}
	testing.expect(t, ready_observed, "the real Go Markdown projection should publish an exact-revision ready state")
	if !ready_observed { _, _ = bridge.backend_stop(&app.backend, context.allocator); return }
	document, _ = find_document(&app.backend.state, document_id)
	replacement := [?]int{'!'}
	edit := bridge.backend_command(
		&app.backend, "replace_document", document_id=document_id,
		editor_revision=document.editor_revision, start_byte=document.byte_length,
		end_byte=document.byte_length, replacement=replacement[:], allocator=context.allocator,
	)
	edit_ok := edit.ok
	testing.expect(t, edit_ok, "editing the real Markdown document should invalidate its derived presentation")
	bridge.backend_command_result_destroy(&edit, context.allocator)
	if !edit_ok { _, _ = bridge.backend_stop(&app.backend, context.allocator); return }
	append(&source, '!')
	document, document_found = find_document(&app.backend.state, document_id)
	testing.expect(t, document_found && !document.presentation_ready,
		"the source edit should publish a pending presentation tuple before reparsing")
	if !document_found { _, _ = bridge.backend_stop(&app.backend, context.allocator); return }
	window_lane_started := bridge.visible_window_lane_start(
		&app.visible_window_lane, &app.backend, markdown_test_wake, rawptr(&signal), context.allocator,
	)
	testing.expect(t, window_lane_started, "the Markdown integration should start the regular bounded-window lane")
	if !window_lane_started { _, _ = bridge.backend_stop(&app.backend, context.allocator); return }
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 1000, 680})
	defer {
		if app.backend.started {
			_ = bridge.visible_window_lane_stop(&app.visible_window_lane)
			_, _ = bridge.backend_stop(&app.backend, context.allocator)
		}
		editor_window_destroy(&app.editor_window, context.allocator)
		editor_views_destroy(&app.editor_views, context.allocator)
		editor_window_rejection_clear(&app)
		delete(app.editor_row_targets)
		tree_clear_directories(&app)
		delete(app.tree_directories)
		if len(app.tree_root_path) > 0 { delete(app.tree_root_path, context.allocator) }
		tree_clear_focused_path(&app)
		if len(app.editor_presented_document_id) > 0 { delete(app.editor_presented_document_id, context.allocator) }
		alicorn.destroy_runtime(&rt)
	}
	fonts_loaded := alicorn.text_engine_load_font(&rt.text_engine, ALICORN_TEST_UI_FONT_DATA) &&
	                alicorn.text_engine_load_font_role(&rt.text_engine, .Monospace, ALICORN_TEST_MONO_FONT_DATA)
	testing.expect(t, fonts_loaded, "retained Markdown styling test should load its UI and monospace font roles")
	if !fonts_loaded { return }
	_ = build_app(rawptr(&app), &rt, 1000, 680, 1)
	pending_installed := false
	for _ in 0..<100 {
		_ = sync.sema_wait_with_timeout(&signal.sema, time.Duration(20_000_000))
		application_wake(rawptr(&app), &rt)
		if app.editor_window_ready && app.editor_window.editor_revision == document.editor_revision { pending_installed = true; break }
	}
	testing.expect(t, pending_installed && !app.editor_window.presentation_ready,
		"the initial lane response should contain raw Markdown bytes with a pending trailer")
	if !pending_installed { return }
	_ = build_app(rawptr(&app), &rt, 1000, 680, 1)
	testing.expect(t, len(app.editor_row_targets) > 0, "the pending source window should build retained Markdown rows")
	if len(app.editor_row_targets) == 0 { return }
	first_row := app.editor_row_targets[0]
	plain_node, plain_found := rt.nodes[first_row.node]
	plain_line, plain_line_found := editor_window_line(&app.editor_window, first_row.logical_line)
	testing.expect(t, plain_found && plain_line_found, "the pending first row should have a retained text node and source mapping")
	if !plain_found || !plain_line_found { return }
	plain_run_generation := plain_node.text_run_generation
	plain_caret := alicorn.text_node_caret_geometry(&rt, first_row.node, alicorn.Text_Position{byte=1, affinity=.Leading})
	plain_hit, plain_hit_ok := alicorn.text_node_hit_test(&rt, first_row.node, plain_node.bounds.x+8, plain_node.bounds.y+plain_node.bounds.h/2)
	plain_id := first_row.node
	plain_source, plain_source_error := make([]u8, len(app.editor_window.source), allocator=context.allocator)
	if plain_source_error != nil { testing.expect(t, false, "could not retain pending source bytes for exact comparison"); return }
	defer delete(plain_source, context.allocator)
	if len(plain_source) > 0 { mem.copy(rawptr(&plain_source[0]), rawptr(&app.editor_window.source[0]), len(plain_source)) }
	ready_after_edit := false
	for _ in 0..<300 {
		application_wake(rawptr(&app), &rt)
		if current, found := find_document(&app.backend.state, document_id); found && current.presentation_ready && current.presentation_revision == current.editor_revision {
			ready_after_edit = true
			break
		}
		_ = sync.sema_wait_with_timeout(&signal.sema, time.Duration(10_000_000))
	}
	testing.expect(t, ready_after_edit, "Go should publish readiness for the edited Markdown revision")
	if !ready_after_edit { return }
	ready_document, _ := find_document(&app.backend.state, document_id)
	_ = build_app(rawptr(&app), &rt, 1000, 680, 1)
	for _ in 0..<100 {
		_ = sync.sema_wait_with_timeout(&signal.sema, time.Duration(20_000_000))
		application_wake(rawptr(&app), &rt)
		if app.editor_window.presentation_ready && app.editor_window.presentation_revision == ready_document.editor_revision { break }
	}
	styled_installed := app.editor_window.presentation_ready && app.editor_window.presentation_revision == ready_document.editor_revision
	testing.expect(t, styled_installed, "the readiness tuple should trigger one bounded SPVS2 refresh and install exact-revision metadata")
	if !styled_installed { return }
	_ = build_app(rawptr(&app), &rt, 1000, 680, 1)
	if len(app.editor_row_targets) == 0 { testing.expect(t, false, "the styled Markdown frame should retain its first source row"); return }
	styled_row := app.editor_row_targets[0]
	styled_node, styled_found := rt.nodes[styled_row.node]
	styled_line, styled_line_found := editor_window_line(&app.editor_window, styled_row.logical_line)
	testing.expect(t, styled_found && styled_line_found && styled_row.node == plain_id,
		"pending-to-ready styling should preserve the retained row identity")
	if !styled_found || !styled_line_found { return }
	wrapped_logical_line: u64 = 0
	wrapped_line_found := false
	for candidate in app.editor_window.lines {
		if strings.has_prefix(candidate.display, "Soft-wrap regression paragraph:") {
			wrapped_logical_line = candidate.logical_line
			wrapped_line_found = true
			break
		}
	}
	wrapped_line, wrapped_line_available := editor_window_line(&app.editor_window, wrapped_logical_line)
	wrapped_line_found = wrapped_line_found && wrapped_line_available
	wrapped_target := Editor_Row_Target{}
	if wrapped_line_found {
		for target in app.editor_row_targets {
			if target.logical_line == wrapped_line.logical_line { wrapped_target = target; break }
		}
	}
	wrapped_node, wrapped_node_found := rt.nodes[wrapped_target.node]
	wrapped_view_index := editor_view_find(app.editor_views[:], document_id)
	wrapped_height: f32 = 0
	if wrapped_view_index >= 0 && wrapped_line_found {
		wrapped_height = alicorn.virtual_list_height_index_item_height(
			&app.editor_views[wrapped_view_index].wrap_height_index,
			int(wrapped_line.logical_line),
		)
	}
	wrapped_source_unchanged := wrapped_line_found && strings.has_prefix(
		string(app.editor_window.source[int(wrapped_line.source_start-app.editor_window.start_byte):]),
		"Soft-wrap regression paragraph:",
	)
	testing.expect(t, wrapped_line_found && wrapped_node_found && len(wrapped_node.text_run.lines) > 1 &&
		wrapped_height > EDITOR_ROW_HEIGHT && wrapped_source_unchanged,
		"styled Markdown prose should shape into multiple visual rows while preserving source bytes and measured row height")
	if wrapped_line_found && wrapped_node_found && len(wrapped_node.text_run.lines) > 1 && wrapped_view_index >= 0 {
		first_visual_end := wrapped_node.text_run.lines[0].byte_end
		first_visual_source_end := editor_display_to_source(wrapped_line, first_visual_end)
		view := &app.editor_views[wrapped_view_index]
		view.selection_anchor, view.caret_byte = first_visual_source_end, first_visual_source_end
		view.anchor_affinity, view.caret_affinity = .Trailing, .Trailing
		wrapped_down := editor_text_key(
			rawptr(&app), &rt, app.editor_scroll_owner,
			host.Application_Text_Key_Event{key=.Down},
		)
		after_down_line, after_down_found := editor_line_for_source(&app.editor_window, view.caret_byte)
		testing.expect(t, wrapped_down && after_down_found && after_down_line.logical_line == wrapped_line.logical_line &&
			view.caret_byte > first_visual_source_end,
			"Down should move to the next shaped visual row within the same logical source line")
		wrapped_up := editor_text_key(
			rawptr(&app), &rt, app.editor_scroll_owner,
			host.Application_Text_Key_Event{key=.Up},
		)
		up_line, up_line_found := editor_line_for_source(&app.editor_window, view.caret_byte)
		testing.expect(t, wrapped_up && up_line_found && up_line.logical_line == wrapped_line.logical_line &&
			view.caret_byte <= first_visual_source_end,
			"Up should return to the previous visual row without crossing the logical source line")
		view.selection_anchor, view.caret_byte = first_visual_source_end, first_visual_source_end
		view.anchor_affinity, view.caret_affinity = .Trailing, .Trailing
		wrapped_shift_down := editor_text_key(
			rawptr(&app), &rt, app.editor_scroll_owner,
			host.Application_Text_Key_Event{key=.Down, shift=true},
		)
		shift_line, shift_line_found := editor_line_for_source(&app.editor_window, view.caret_byte)
		testing.expect(t, wrapped_shift_down && shift_line_found && shift_line.logical_line == wrapped_line.logical_line &&
			view.selection_anchor == first_visual_source_end && view.caret_byte > first_visual_source_end,
			"Shift+Down should extend the source selection across a visual-row boundary")
	}
	paints := editor_presentation_spans_for_line(&app.editor_window, styled_line, context.temp_allocator)
	testing.expect(t, len(paints) > 0 && len(styled_node.text_paint_spans) > 0,
		"the same retained Markdown row should carry actual paint-only semantic spans after readiness")
	delete(paints, context.temp_allocator)
	testing.expect(t, styled_node.text_run_generation == plain_run_generation,
		"adding semantic paint spans must reuse the original shaped text run")
	styled_caret := alicorn.text_node_caret_geometry(&rt, styled_row.node, alicorn.Text_Position{byte=1, affinity=.Leading})
	styled_hit, styled_hit_ok := alicorn.text_node_hit_test(&rt, styled_row.node, styled_node.bounds.x+8, styled_node.bounds.y+styled_node.bounds.h/2)
	testing.expect(t, plain_caret.valid && styled_caret.valid &&
		plain_caret.rect.x == styled_caret.rect.x && plain_caret.rect.y == styled_caret.rect.y &&
		plain_caret.rect.w == styled_caret.rect.w && plain_caret.rect.h == styled_caret.rect.h,
		"caret geometry must remain identical when the exact-revision spans arrive")
	testing.expect(t, plain_hit_ok && styled_hit_ok && plain_hit.byte == styled_hit.byte,
		"hit testing must return the same displayed byte boundary before and after paint styling")
	testing.expect(t, len(plain_source) == len(app.editor_window.source), "presentation arrival must not change bounded source length")
	if len(plain_source) == len(app.editor_window.source) {
		for index in 0..<len(plain_source) {
			if plain_source[index] != app.editor_window.source[index] {
				testing.expect(t, false, "presentation arrival must not modify any backend source byte")
				break
			}
		}
	}
	submitted_ready := app.visible_window_lane.submitted
	_ = build_app(rawptr(&app), &rt, 1000, 680, 1)
	_ = build_app(rawptr(&app), &rt, 1000, 680, 1)
	testing.expect(t, app.visible_window_lane.submitted == submitted_ready,
		"rebuilding the same ready view should not retry the unchanged metadata request")
	canonical := bridge.backend_command(
		&app.backend, "read_visible_lines", document_id=document_id, start_line=0,
		max_lines=bridge.MAX_VISIBLE_LINES, max_bytes=bridge.MAX_VISIBLE_BYTES, allocator=context.allocator,
	)
	testing.expect(t, canonical.ok && canonical.visible_window_owned &&
		len(canonical.visible_window.source) == len(app.editor_window.source),
		"backend canonical bytes should still match the retained styled window")
	if canonical.visible_window_owned && len(canonical.visible_window.source) == len(app.editor_window.source) {
		for index in 0..<len(app.editor_window.source) {
			if canonical.visible_window.source[index] != app.editor_window.source[index] {
				testing.expect(t, false, "frontend presentation must preserve the canonical backend byte sequence")
				break
			}
		}
	}
	bridge.backend_command_result_destroy(&canonical, context.allocator)
	if wrapped_line_found && wrapped_view_index >= 0 {
		view := &app.editor_views[wrapped_view_index]
		anchor_top := alicorn.virtual_list_height_index_item_top(&view.wrap_height_index, int(wrapped_line.logical_line))
		_ = alicorn.scroll_region_set_offset(&rt, app.editor_scroll_owner, anchor_top+5, "soft-wrap resize anchor regression")
		alicorn.invalidate_root(&rt, "soft-wrap resize anchor setup")
		_ = build_app(rawptr(&app), &rt, 1000, 680, 1)
		before_scroll := alicorn.scroll_region_state(&rt, app.editor_scroll_owner)
		before_metrics := alicorn.virtual_list_variable_metrics(
			&view.wrap_height_index, before_scroll.offset_y, before_scroll.viewport_height,
		)
		before_height := alicorn.virtual_list_height_index_item_height(&view.wrap_height_index, int(wrapped_line.logical_line))
		before_wrap_width := view.wrap_measurement_width
		rt.viewport.w = 820
		alicorn.invalidate_root(&rt, "soft-wrap width reflow regression")
		_ = build_app(rawptr(&app), &rt, 820, 680, 1)
		after_scroll := alicorn.scroll_region_state(&rt, app.editor_scroll_owner)
		after_metrics := alicorn.virtual_list_variable_metrics(
			&view.wrap_height_index, after_scroll.offset_y, after_scroll.viewport_height,
		)
		after_height := alicorn.virtual_list_height_index_item_height(&view.wrap_height_index, int(wrapped_line.logical_line))
		testing.expect(t, view.wrap_measurement_width < 0.9*before_wrap_width && after_height > before_height,
			"resizing narrower should reshape only the bounded window and increase rows for a long prose line")
		testing.expect(t, before_metrics.first == int(wrapped_line.logical_line) &&
			after_metrics.first == before_metrics.first && abs(after_metrics.leading_offset_y-before_metrics.leading_offset_y) < 1,
			"width reflow should preserve the visible logical source anchor and its intra-row offset")
	}
}
