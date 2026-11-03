package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import alicorn "alicorn:runtime"
import bridge "./bridge"

@(test)
test_search_result_cleanup_is_idempotent :: proc(t: ^testing.T) {
	app: App
	app.workspace_search_edit_buffer, _ = alicorn.text_field_buffer_init("needle", context.allocator)
	app.workspace_search_edit_source_text, _ = strings.clone("needle", context.allocator)
	app.workspace_search_edit_document_id, _ = strings.clone("document", context.allocator)
	workspace_search_edit_clear(&app)
	testing.expect(t, app.workspace_search_edit_source_text == "" && app.workspace_search_edit_document_id == "" &&
		!app.workspace_search_edit_buffer.initialized, "clearing a session must reset every owning handle before another activation or shutdown")
	workspace_search_edit_clear(&app)
}

@(test)
test_search_result_actions_complete_outside_description_loop :: proc(t: ^testing.T) {
	sync.mutex_lock(&backend_integration_test_mutex)
	defer sync.mutex_unlock(&backend_integration_test_mutex)
	workspace, err := os.make_directory_temp("", "scratchpad-search-switch-*", context.temp_allocator)
	if err != nil { testing.expect(t, false, "search fixture must exist"); return }
	defer _ = os.remove_all(workspace)
	if os.write_entire_file_from_string(fmt.tprintf("%s/note.txt", workspace), "needle one\nneedle two\nneedle three\n") != nil {
		testing.expect(t, false, "search fixture source must exist"); return
	}
	library, found := os.lookup_env("SCRATCHPAD_BACKEND_LIBRARY", context.temp_allocator)
	if !found { testing.expect(t, false, "search transition regression needs the real backend"); return }
	app: App
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 1000, 800})
	defer alicorn.destroy_runtime(&rt)
	defer application_stop(rawptr(&app))
	fonts_loaded := alicorn.text_engine_load_font(&rt.text_engine, ALICORN_TEST_UI_FONT_DATA) &&
		alicorn.text_engine_load_font_role(&rt.text_engine, .Monospace, ALICORN_TEST_MONO_FONT_DATA)
	if !fonts_loaded {
		testing.expect(t, false, "search pointer regression must load the UI and monospace fonts to produce shaped hit-test geometry")
		return
	}
	init_menus(&app)
	loaded, message := bridge.backend_load(&app.backend, library)
	if !loaded { testing.expect(t, false, message); return }
	started, start_message := bridge.backend_start(&app.backend, workspace, tree_test_wake, nil, context.allocator)
	if !started { testing.expect(t, false, start_message); return }
	keep_path := fmt.tprintf("%s/keep.txt", workspace)
	if os.write_entire_file_from_string(keep_path, "keep this editor active\n") != nil {
		testing.expect(t, false, "active editor fixture source must exist"); return
	}
	keep_open := bridge.backend_command(&app.backend, "open_path", path=keep_path)
	if !keep_open.ok {
		testing.expect(t, false, keep_open.message)
		bridge.backend_command_result_destroy(&keep_open, context.allocator)
		return
	}
	handle_command_result(&app, &rt, &keep_open)
	bridge.backend_command_result_destroy(&keep_open, context.allocator)
	active_document_before := app.backend.state.active
	testing.expect(t, active_document_before != "", "fixture must begin with an active editor document")
	app.workspace_search_mode = true
	app.workspace_search_query, _ = strings.clone("needle", context.allocator)
	app.workspace_search_started_query, _ = strings.clone("needle", context.allocator)
	app.workspace_search_started_root, _ = strings.clone(app.backend.state.workspace_root, context.allocator)
	workspace_search_view_begin(&app.workspace_search_view, 7)
	results := []bridge.Workspace_Search_Result{
		{path="note.txt", text="needle one", start_byte=0, end_byte=6, context_start_byte=0, context_end_byte=10, editable=true, projection_key=101},
		{path="note.txt", text="needle two", line=1, start_byte=11, end_byte=17, context_start_byte=11, context_end_byte=21, editable=true, projection_key=202},
		{path="note.txt", text="needle three", line=2, start_byte=22, end_byte=28, context_start_byte=22, context_end_byte=34, editable=true, projection_key=303},
	}
	testing.expect(t, workspace_search_view_append(&app.workspace_search_view, {generation=7, sequence=1, results=results}), "fixture must publish three results")
	_ = build_app(rawptr(&app), &rt, 1000, 800, 1)
	preview_node := alicorn.Node_ID(0)
	for pointer_target in app.workspace_search_pointer_targets {
		if pointer_target.projection_key == 101 && pointer_target.kind == .Edit_Text { preview_node = pointer_target.node; break }
	}
	preview_info, preview_found := alicorn.node_info(&rt, preview_node)
	testing.expect(t, preview_found && preview_info.text_geometry_available, "inactive search excerpts must remain retained text with hit-test geometry")
	click_x := preview_info.bounds.x+min(preview_info.bounds.w*0.55, f32(72))
	click_y := preview_info.bounds.y+preview_info.bounds.h*0.5
	clicked_position, click_hit := alicorn.text_node_hit_test(&rt, preview_node, click_x, click_y)
	testing.expect(t, click_hit, "the preview's shaped text must map a pointer position to a source-text byte")
	click := alicorn.Pointer_Event{kind=.Down, x=click_x, y=click_y, button=alicorn.POINTER_BUTTON_PRIMARY}
	target := alicorn.process_pointer(&rt, click)
	application_pointer(rawptr(&app), &rt, click, target)
	testing.expect(t, app.workspace_search_edit_active && app.workspace_search_edit_index == 0,
		"clicking source text must activate its result directly")
	testing.expect(t, app.workspace_search_edit_ready,
		"the bounded source context should be validated before text input is enabled")
	testing.expect(t, app.backend.state.active == active_document_before,
		"editing a Search excerpt must not activate its source document in the main editor")
	_ = build_app(rawptr(&app), &rt, 1000, 800, 1)
	first_edit_node := app.workspace_search_edit_node
	first_interaction, first_interaction_found := alicorn.text_field_interaction(&rt, first_edit_node)
	testing.expect(t, first_interaction_found && first_interaction.caret == clicked_position.byte && !first_interaction.has_selection,
		"clicking a preview must put the caret at the clicked grapheme instead of selecting the match")
	second_preview := alicorn.Node_ID(0)
	for pointer_target in app.workspace_search_pointer_targets {
		if pointer_target.projection_key == 202 && pointer_target.kind == .Edit_Text { second_preview = pointer_target.node; break }
	}
	second_info, second_found := alicorn.node_info(&rt, second_preview)
	testing.expect(t, second_found, "other visible results must remain available as lightweight text previews")
	second_x := second_info.bounds.x+min(second_info.bounds.w*0.6, f32(76))
	second_y := second_info.bounds.y+second_info.bounds.h*0.5
	second_click := alicorn.Pointer_Event{kind=.Down, x=second_x, y=second_y, button=alicorn.POINTER_BUTTON_PRIMARY}
	second_target := alicorn.process_pointer(&rt, second_click)
	application_pointer(rawptr(&app), &rt, second_click, second_target)
	testing.expect(t, app.workspace_search_edit_active && app.workspace_search_edit_index == 1 &&
		app.workspace_search_edit_buffer.text == "needle two", "clicking a different result must safely transfer the single edit buffer")
	testing.expect(t, app.backend.state.active == active_document_before,
		"switching Search edit targets must preserve the main editor's active document")
	alicorn.invalidate_root(&rt, "describe second search editor")
	_ = build_app(rawptr(&app), &rt, 1000, 800, 1)
	testing.expect(t, settings_test_find_node(&rt, "", "Edit result") == 0 &&
		settings_test_find_node(&rt, "", "Done") == 0 && settings_test_find_node(&rt, "", "Go to source") == 0,
		"search results should not add per-result edit, done, or source buttons")
	// A source/line heading is the direct navigation affordance. A changed
	// active result finishes and refreshes before the old rows are retired.
	app.workspace_search_edit_source_changed = true
	heading_node := alicorn.Node_ID(0)
	for pointer_target in app.workspace_search_pointer_targets {
		if pointer_target.projection_key == 202 && pointer_target.kind == .Navigate_Source { heading_node = pointer_target.node; break }
	}
	heading_info, heading_found := alicorn.node_info(&rt, heading_node)
	testing.expect(t, heading_found, "each result must expose a compact, clickable file/line heading")
	heading_click := alicorn.Pointer_Event{
		kind=.Down,
		x=heading_info.bounds.x+heading_info.bounds.w*0.5,
		y=heading_info.bounds.y+heading_info.bounds.h*0.5,
		button=alicorn.POINTER_BUTTON_PRIMARY,
	}
	heading_target := alicorn.process_pointer(&rt, heading_click)
	application_pointer(rawptr(&app), &rt, heading_click, heading_target)
	testing.expect(t, !app.workspace_search_edit_active && app.workspace_search_view.generation != 7 &&
		len(app.workspace_search_view.results) == 0, "heading navigation must safely finish editing and refresh after the click")
}
