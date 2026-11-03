package main

import "core:mem"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import alicorn "alicorn:runtime"
import bridge "./bridge"

@(test)
test_task_and_link_commands_follow_document_language :: proc(t: ^testing.T) {
	app: App
	app.backend.started = true
	documents := [?]bridge.State_Document{
		{id="markdown", path="notes.md", language="markdown"},
		{id="code", path="main.go", language="go"},
	}
	app.backend.state.documents = documents[:]
	init_menus(&app)
	for document in documents {
		app.backend.state.active = document.id
		results := command_palette_collect_results(&app, context.temp_allocator)
		projection_count := 0
		for result in results {
			if result.action_id == ACTION_DOCUMENT_SHOW_TASKS || result.action_id == ACTION_DOCUMENT_SHOW_LINKS { projection_count += 1 }
		}
		testing.expect(t, projection_count == (2 if document.language == "markdown" else 0),
			"task/link commands should be discoverable for Markdown and absent for programming files")
		delete(results)
	}
}

@(test)
test_task_marker_click_uses_undoable_source_command :: proc(t: ^testing.T) {
	sync.mutex_lock(&backend_integration_test_mutex)
	defer sync.mutex_unlock(&backend_integration_test_mutex)
	workspace, err := os.make_directory_temp("", "scratchpad-task-click-*", context.temp_allocator)
	if err != nil { testing.expect(t, false, "task fixture directory should exist"); return }
	defer _ = os.remove_all(workspace)
	path := fmt.tprintf("%s/task.md", workspace)
	if os.write_entire_file_from_string(path, "- [ ] Task\nordinary text\n") != nil {
		testing.expect(t, false, "task fixture should be written"); return
	}
	library, found := os.lookup_env("SCRATCHPAD_BACKEND_LIBRARY", context.temp_allocator)
	if !found { testing.expect(t, false, "task click regression needs the staged backend"); return }
	app: App
	rt := alicorn.new_runtime({0, 0, 800, 180})
	defer { application_stop(rawptr(&app)); alicorn.destroy_runtime(&rt) }
	init_menus(&app)
	loaded, message := bridge.backend_load(&app.backend, library)
	if !loaded { testing.expect(t, false, message); return }
	started, start_message := bridge.backend_start(&app.backend, workspace, tree_test_wake, nil)
	if !started { testing.expect(t, false, start_message); return }
	opened := bridge.backend_command(&app.backend, "open_path", path=path)
	testing.expect(t, opened.ok, "task source should open")
	bridge.backend_command_result_destroy(&opened, context.allocator)
	document, _ := find_document(&app.backend.state, app.backend.state.active)
	id, _ := strings.clone(document.id, context.temp_allocator)
	ready := false
	for _ in 0..<60 {
		read := bridge.backend_command(&app.backend, "read_visible_lines", document_id=id,
			start_line=0, max_lines=32, max_bytes=4096, include_presentation=true)
		if read.ok && read.visible_window_owned && read.visible_window.presentation_ready {
			app.editor_window, ready, _ = editor_window_from_visible(&read.visible_window)
			app.editor_window_ready = ready
		}
		bridge.backend_command_result_destroy(&read, context.allocator)
		if ready { break }
		time.sleep(10*time.Millisecond)
	}
	testing.expect(t, ready, "parser should publish exact task-marker geometry")
	if !ready { return }
	_ = alicorn.text_engine_load_font(&rt.text_engine, ALICORN_TEST_UI_FONT_DATA)
	_ = alicorn.text_engine_load_font_role(&rt.text_engine, .Monospace, ALICORN_TEST_MONO_FONT_DATA)
	document, _ = find_document(&app.backend.state, id)
	editor_stale_window_test_render(&app, &rt, document)
	testing.expect(t, len(app.editor_row_targets) > 0, "task marker must be in the retained source row")
	if len(app.editor_row_targets) == 0 { return }
	row := app.editor_row_targets[0]
	left := alicorn.text_node_caret_geometry(&rt, row.node, {byte=2, affinity=.Leading})
	right := alicorn.text_node_caret_geometry(&rt, row.node, {byte=5, affinity=.Trailing})
	x, y := (left.rect.x+right.rect.x)/2, left.rect.y+left.rect.h/2
	start, end, hit := editor_task_marker_at_pointer(&app, &rt, &app.editor_window, x, y)
	testing.expect(t, hit && start == 2 && end == 5, "only the parser marker's actual text bounds should be clickable")
	if !hit { return }
	for kind in ([2]alicorn.Pointer_Kind{.Down, .Up}) {
		event := alicorn.Pointer_Event{kind=kind, x=x, y=y, button=alicorn.POINTER_BUTTON_PRIMARY, click_count=1}
		target := alicorn.process_pointer(&rt, event)
		editor_pointer(rawptr(&app), &rt, event, target)
	}
	testing.expect(t, app.error_message == "", "task click should execute instead of reporting an unavailable action")
	read := bridge.backend_command(&app.backend, "read_visible_lines", document_id=id, max_lines=32, max_bytes=4096)
	testing.expect(t, read.ok && string(read.visible_window.source) == "- [x] Task\nordinary text\n",
		"a click must replace the task's source marker through the backend")
	bridge.backend_command_result_destroy(&read, context.allocator)
	dispatch_action(&app, &rt, ACTION_EDIT_UNDO)
	read = bridge.backend_command(&app.backend, "read_visible_lines", document_id=id, max_lines=32, max_bytes=4096)
	testing.expect(t, read.ok && string(read.visible_window.source) == "- [ ] Task\nordinary text\n", "one Undo must reverse the checkbox source edit")
	bridge.backend_command_result_destroy(&read, context.allocator)
	dispatch_action(&app, &rt, ACTION_EDIT_REDO)
	read = bridge.backend_command(&app.backend, "read_visible_lines", document_id=id, max_lines=32, max_bytes=4096)
	testing.expect(t, read.ok && string(read.visible_window.source) == "- [x] Task\nordinary text\n", "one Redo must restore the checkbox source edit")
	bridge.backend_command_result_destroy(&read, context.allocator)
}

@(test)
test_task_marker_cut_keeps_source_editor_valid :: proc(t: ^testing.T) {
	original := "- [x] Task\nordinary text\n"
	for selection in ([6][2]u64{{2,5}, {2,3}, {4,5}, {3,4}, {0,6}, {2,18}}) {
		app: App
		rt := alicorn.new_runtime({0, 0, 800, 180})
		clipboard := Editor_Test_Clipboard{read_ok=true, write_ok=true}
		app.services.clipboard = {data=rawptr(&clipboard), get_text=editor_test_clipboard_get_text, set_text=editor_test_clipboard_set_text}
		app.backend.started = true
		documents := [?]bridge.State_Document{{id="task-cut", path="tasks.md", language="markdown", editor_revision=1, line_count=3, byte_length=u64(len(original))}}
		app.backend.state.active = "task-cut"
		app.backend.state.documents = documents[:]
		app.editor_views = make([dynamic]Editor_View_State, 0)
		app.editor_edits = make([dynamic]Editor_Edit_Intent, 0)
		app.editor_row_targets = make([dynamic]Editor_Row_Target, 0)
		source, _ := make([]u8, len(original))
		mem.copy(rawptr(&source[0]), rawptr(raw_data(original)), len(original))
		visible := bridge.Visible_Window{document_id="task-cut", editor_revision=1, end_line=3, source=source}
		window, ready, message := editor_window_from_visible(&visible)
		testing.expect(t, ready, message)
		if !ready { alicorn.destroy_runtime(&rt); continue }
		window.presentation_ready, window.presentation_revision = true, 1
		window.presentation_spans = make([]bridge.Presentation_Record, 2)
		window.presentation_spans[0] = {kind=EDITOR_PRESENTATION_LIST_MARKER, start_byte=0, end_byte=2}
		window.presentation_spans[1] = {kind=EDITOR_PRESENTATION_TASK_MARKER, start_byte=2, end_byte=5}
		app.editor_window, app.editor_window_ready = window, true
		defer {
			for len(app.editor_edits) > 0 { editor_remove_edit(&app, 0) }
			delete(app.editor_edits)
			editor_window_destroy(&app.editor_window)
			editor_views_destroy(&app.editor_views)
			delete(app.editor_row_targets)
			if len(app.editor_presented_document_id) > 0 { delete(app.editor_presented_document_id) }
			if len(app.error_message) > 0 { delete(app.error_message) }
			if len(clipboard.last_write) > 0 { delete(clipboard.last_write, context.temp_allocator) }
			alicorn.destroy_runtime(&rt)
		}
		_ = alicorn.text_engine_load_font(&rt.text_engine, ALICORN_TEST_UI_FONT_DATA)
		_ = alicorn.text_engine_load_font_role(&rt.text_engine, .Monospace, ALICORN_TEST_MONO_FONT_DATA)
		editor_stale_window_test_render(&app, &rt, documents[0])
		index := editor_view_find(app.editor_views[:], "task-cut")
		testing.expect(t, index >= 0, "task source should build a normal editable view")
		if index < 0 { continue }
		view := &app.editor_views[index]
		view.selection_anchor, view.caret_byte = selection[0], selection[1]
		editor_clipboard_command(&app, &rt, ACTION_EDIT_CUT)
		testing.expect(t, len(app.editor_edits) == 1 && view.optimistic_window_ready,
			"cutting Markdown syntax should queue one ordinary source edit")
		if !view.optimistic_window_ready { continue }
		testing.expect(t, string(view.optimistic_window.source) == fmt.tprintf("%s%s", original[:int(selection[0])], original[int(selection[1]):]),
			"Cut must remove exactly the selected bytes")
		testing.expect(t, !editor_task_marker_is_current(&view.optimistic_window, 2, 5),
			"old parser syntax cannot authorize an action after Cut")
		for record in view.optimistic_window.presentation_spans {
			testing.expect(t, record.kind != EDITOR_PRESENTATION_TASK_MARKER,
				"cut task syntax must stop inheriting task-marker paint")
		}
		editor_stale_window_test_render(&app, &rt, documents[0])
		testing.expect(t, len(app.editor_row_targets) > 0, "the authoritative editor must remain renderable after deleting task syntax")
	}
}

@(test)
test_task_marker_drag_and_stale_release_preserve_text_selection :: proc(t: ^testing.T) {
	app: App
	rt := alicorn.new_runtime({0, 0, 400, 200})
	defer alicorn.destroy_runtime(&rt)
	app.editor_views = make([dynamic]Editor_View_State, 0)
	defer editor_views_destroy(&app.editor_views)
	index, _ := editor_view_ensure(&app.editor_views, "task")
	view := &app.editor_views[index]
	view.task_toggle_pending = true
	view.task_toggle_x, view.task_toggle_y = 10, 20
	view.selection_anchor, view.caret_byte = 2, 5
	editor_task_marker_pointer_finish(&app, &rt, {kind=.Move, x=16, y=20})
	testing.expect(t, !view.task_toggle_pending && view.selection_anchor == 2 && view.caret_byte == 5,
		"dragging across a marker must select text and cancel the toggle")
	view.task_toggle_pending = true
	view.task_toggle_revision = 1
	app.backend.state.active = "task"
	documents := [?]bridge.State_Document{{id="task", language="markdown", editor_revision=2}}
	app.backend.state.documents = documents[:]
	editor_task_marker_pointer_finish(&app, &rt, {kind=.Up, button=alicorn.POINTER_BUTTON_PRIMARY})
	testing.expect(t, !view.task_toggle_pending && view.selection_anchor == 2 && view.caret_byte == 5,
		"a source revision change between down and up must cancel the task action")
}
