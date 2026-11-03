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
	init_menus(&app)
	loaded, message := bridge.backend_load(&app.backend, library)
	if !loaded { testing.expect(t, false, message); return }
	started, start_message := bridge.backend_start(&app.backend, workspace, tree_test_wake, nil, context.allocator)
	if !started { testing.expect(t, false, start_message); return }
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
	testing.expect(t, workspace_search_edit_begin(&app, &rt, 0), "first result must activate")
	// Context is known exactly in this fixture; bypass the unrelated window worker.
	app.workspace_search_edit_ready = true
	_ = build_app(rawptr(&app), &rt, 1000, 800, 1)
	edit := settings_test_find_node(&rt, "workspace-search-edit-202", "")
	testing.expect(t, edit != 0 && alicorn.focus(&rt, edit) && alicorn.activate_focused(&rt, .Enter), "second result must activate through its real UI button")
	_ = build_app(rawptr(&app), &rt, 1000, 800, 1)
	testing.expect(t, app.workspace_search_edit_active && app.workspace_search_edit_index == 1 &&
		app.workspace_search_edit_buffer.text == "needle two", "clicking a different result must safely transfer the edit buffer")
	app.workspace_search_edit_ready = true
	alicorn.invalidate_root(&rt, "describe second search editor")
	_ = build_app(rawptr(&app), &rt, 1000, 800, 1)
	// Model the acknowledged state that requires a complete query refresh when
	// leaving. There is still a third row after this one in the virtual-list loop.
	app.workspace_search_edit_source_changed = true
	done := settings_test_find_node(&rt, "workspace-search-done-202", "")
	testing.expect(t, done != 0 && alicorn.focus(&rt, done) && alicorn.activate_focused(&rt, .Enter), "Done must activate through its real UI button")
	_ = build_app(rawptr(&app), &rt, 1000, 800, 1)
	testing.expect(t, !app.workspace_search_edit_active && app.workspace_search_view.generation != 7 &&
		len(app.workspace_search_view.results) == 0, "query refresh must retire the results only after the entire description loop finishes")
	workspace_search_view_begin(&app.workspace_search_view, 9)
	testing.expect(t, workspace_search_view_append(&app.workspace_search_view, {generation=9, sequence=1, results=results}), "source navigation fixture must republish results")
	testing.expect(t, workspace_search_edit_begin(&app, &rt, 1), "second result must reactivate")
	app.workspace_search_edit_ready = true
	alicorn.invalidate_root(&rt, "describe source navigation action")
	_ = build_app(rawptr(&app), &rt, 1000, 800, 1)
	app.workspace_search_edit_source_changed = true
	source := settings_test_find_node(&rt, "workspace-search-source-202", "")
	testing.expect(t, source != 0 && alicorn.focus(&rt, source) && alicorn.activate_focused(&rt, .Enter), "source navigation must activate through its real UI button")
	_ = build_app(rawptr(&app), &rt, 1000, 800, 1)
	testing.expect(t, !app.workspace_search_edit_active && len(app.workspace_search_view.results) == 0,
		"source navigation must also refresh outside the result loop")
}
