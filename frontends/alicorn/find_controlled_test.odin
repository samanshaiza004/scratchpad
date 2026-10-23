package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:sync"
import "core:testing"
import alicorn "alicorn:runtime"
import bridge "./bridge"

controlled_find_test_render :: proc(app: ^App, rt: ^alicorn.Runtime) -> alicorn.Text_Field_Response {
	ui, build := alicorn.begin_frame(rt)
	if !build { return {} }
	alicorn.container_begin(&ui, .Root, key=alicorn.key_string("find-dogfood-root"), style=alicorn.layout_style(.Column, grow=1))
	response: alicorn.Text_Field_Response
	if app.find_open { response = find_query_build(app, &ui, rt) }
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
	return response
}

@(test)
test_controlled_find_commits_submit_reopen_and_programmatic_query :: proc(t: ^testing.T) {
	sync.mutex_lock(&backend_integration_test_mutex)
	defer sync.mutex_unlock(&backend_integration_test_mutex)
	workspace, err := os.make_directory_temp("", "scratchpad-controlled-find-*", context.temp_allocator)
	if err != nil { testing.expect(t, false, "Find fixture directory should exist"); return }
	defer _ = os.remove_all(workspace)
	path := fmt.tprintf("%s/note.txt", workspace)
	source := "needle one\nneedle two\nother\n"
	if os.write_entire_file_from_string(path, source) != nil { testing.expect(t, false, "Find fixture should be writable"); return }
	library, found := os.lookup_env("SCRATCHPAD_BACKEND_LIBRARY", context.temp_allocator)
	if !found { testing.expect(t, false, "controlled Find needs the real backend"); return }
	defer delete(library, context.temp_allocator)
	tracking: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracking, context.allocator)
	defer mem.tracking_allocator_destroy(&tracking)
	app: App
	buffer, buffer_ok := alicorn.text_field_buffer_init("", mem.tracking_allocator(&tracking))
	if !buffer_ok { testing.expect(t, false, "Find buffer should initialize"); return }
	app.find_query = buffer
	defer {
		application_stop(rawptr(&app))
		testing.expect(t, len(tracking.allocation_map) == 0, "application shutdown must release the Find buffer through its original allocator")
	}
	loaded, message := bridge.backend_load(&app.backend, library)
	testing.expect(t, loaded, message)
	if !loaded { return }
	started, start_message := bridge.backend_start(&app.backend, workspace, tree_test_wake, nil, context.allocator)
	testing.expect(t, started, start_message)
	if !started { return }
	opened := bridge.backend_command(&app.backend, "open_path", path=path, allocator=context.allocator)
	testing.expect(t, opened.ok, "Find fixture should open")
	bridge.backend_command_result_destroy(&opened, context.allocator)
	document, document_found := find_document(&app.backend.state, app.backend.state.active)
	if !document_found { testing.expect(t, false, "Find document should be published"); return }
	revision := document.editor_revision
	view_index, view_ok := editor_view_ensure(&app.editor_views, document.id)
	if !view_ok { testing.expect(t, false, "Find view should exist"); return }
	app.editor_views[view_index].selection_anchor = 2
	app.editor_views[view_index].caret_byte = 2
	find_open_surface(&app)
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 800, 160})
	defer alicorn.destroy_runtime(&rt)
	_ = controlled_find_test_render(&app, &rt)
	field := app.find_query_node
	testing.expect(t, field != 0 && alicorn.focus(&rt, field), "Find should retain a focusable controlled field")
	if field == 0 { return }
	testing.expect(t, alicorn.process_text_editing(&rt, field, "preedit", 0, 0), "Find should accept transient IME preedit")
	preedit := controlled_find_test_render(&app, &rt)
	testing.expect(t, !preedit.changed && app.find_query.text == "" && len(app.find_presentation.matches) == 0,
		"IME preedit must not become a query or start a source search")
	testing.expect(t, !alicorn.text_field_request_submit(&rt, field), "active composition must own Return")
	change := alicorn.process_text_input(&rt, field, "needle")
	if len(change.text) > 0 { delete(change.text, rt.persistent_allocator) }
	testing.expect(t, app.find_query.text == "", "native input must not mutate the app buffer before description")
	committed := controlled_find_test_render(&app, &rt)
	testing.expect(t, committed.changed && app.find_query.text == "needle" &&
		app.find_presentation.query == "needle" && len(app.find_presentation.matches) == 2,
		"one description must adopt the committed query and refresh real backend matches")
	testing.expect(t, rt.invalidated, "adopting a query must explicitly schedule the final description")
	settled := controlled_find_test_render(&app, &rt)
	testing.expect(t, !settled.changed && !settled.submitted, "the corrective description must not replay the edit")
	active := app.find_presentation.active_match
	testing.expect(t, !application_key(rawptr(&app), &rt, .Return), "the app key handler must defer Find Return to the controlled native path")
	testing.expect(t, alicorn.text_field_request_submit(&rt, field), "Return should queue a controlled submit")
	submitted := controlled_find_test_render(&app, &rt)
	testing.expect(t, submitted.submitted && app.find_presentation.active_match == find_step_match(2, active, 1),
		"one submit should navigate exactly one real match")
	active = app.find_presentation.active_match
	alicorn.invalidate_root(&rt, "Find one-shot submit regression")
	settled = controlled_find_test_render(&app, &rt)
	testing.expect(t, !settled.submitted && app.find_presentation.active_match == active, "later descriptions must not repeat Find navigation")
	testing.expect(t, application_key(rawptr(&app), &rt, .Find_Previous) &&
		app.find_presentation.active_match == find_step_match(2, active, -1), "the previous-match shortcut must remain available")
	testing.expect(t, application_key(rawptr(&app), &rt, .Escape), "Escape should close Find")
	_ = controlled_find_test_render(&app, &rt)
	find_restore_after_frame(&app, &rt)
	testing.expect(t, app.editor_views[view_index].selection_anchor == 2 && app.editor_views[view_index].caret_byte == 2,
		"closing Find should restore the original editor selection")
	find_open_surface(&app)
	alicorn.invalidate_root(&rt, "Find reopened")
	_ = controlled_find_test_render(&app, &rt)
	testing.expect(t, app.find_query.text == "needle", "retiring the field must preserve application-owned query text for reopening")
	testing.expect(t, alicorn.text_field_buffer_set(&app.find_query, "other"), "programmatic query replacement should use the buffer allocator")
	alicorn.invalidate_root(&rt, "programmatic Find query")
	programmatic := controlled_find_test_render(&app, &rt)
	retained, retained_ok := alicorn.text_field_value(&rt, app.find_query_node)
	testing.expect(t, !programmatic.changed && retained_ok && retained == "other" &&
		app.find_presentation.query == "other" && len(app.find_presentation.matches) == 1,
		"a programmatic query should refresh retained text and backend results without reporting a user edit")
	current, current_found := find_document(&app.backend.state, app.backend.state.active)
	testing.expect(t, current_found && current.editor_revision == revision && !current.dirty,
		"Find typing and navigation must leave authoritative bytes and save state unchanged")
	bytes, read_error := os.read_entire_file(path, context.temp_allocator)
	defer delete(bytes, context.temp_allocator)
	testing.expect(t, read_error == nil && string(bytes) == source, "Find dogfooding must not alter the file")
}
