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

editor_test_render_scroll_list :: proc(rt: ^alicorn.Runtime, count: int) -> alicorn.Node_ID {
	if rt == nil { return 0 }
	alicorn.invalidate_root(rt, "Scratchpad editor scroll restoration test")
	ui, should_build := alicorn.begin_frame(rt)
	if !should_build { return 0 }
	alicorn.container_begin(&ui, .Root, key=alicorn.key_string("undo-scroll-test-root"), style=alicorn.layout_style())
	list := alicorn.virtual_list_begin(
		&ui,
		count,
		EDITOR_ROW_HEIGHT,
		key=alicorn.key_string("undo-scroll-test-list"),
		style=alicorn.layout_style(grow=1, clip=true),
		label="undo-scroll-test-list",
		focusable=true,
	)
	for position := list.first; position < list.last; position += 1 {
		alicorn.text(&ui, fmt.tprintf("row %d", position), style=alicorn.layout_style(.Row, height=EDITOR_ROW_HEIGHT))
	}
	alicorn.virtual_list_end(&ui, list)
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
	return list.scroll.id
}

@(test)
test_editor_edit_selection_snapshot_captures_only_transaction_state :: proc(t: ^testing.T) {
	view := Editor_View_State{selection_anchor=11, caret_byte=11}
	collapsed := editor_edit_selection_snapshot(&view, 6, 6)
	testing.expect(t,
		collapsed.before_anchor_byte == 11 && collapsed.before_cursor_byte == 11 &&
		collapsed.after_anchor_byte == 6 && collapsed.after_cursor_byte == 6,
		"a collapsed word-delete transaction must carry its collapsed pre-edit caret and post-edit caret")

	view.selection_anchor, view.caret_byte = 11, 6
	selected := editor_edit_selection_snapshot(&view, 6, 6)
	testing.expect(t,
		selected.before_anchor_byte == 11 && selected.before_cursor_byte == 6 &&
		selected.after_anchor_byte == 6 && selected.after_cursor_byte == 6,
		"a selection-delete transaction must preserve the directional prior selection and record its collapsed result")
}

Editor_Edit_Test_Signal :: struct {
	sema: sync.Sema,
}

editor_edit_test_wake :: proc(data: rawptr) {
	if data == nil { return }
	signal := cast(^Editor_Edit_Test_Signal)data
	sync.sema_post(&signal.sema)
}

@(test)
test_backend_replace_document_transports_100k_paste_payload :: proc(t: ^testing.T) {
	sync.mutex_lock(&backend_integration_test_mutex)
	defer sync.mutex_unlock(&backend_integration_test_mutex)
	workspace, workspace_error := os.make_directory_temp("", "scratchpad-alicorn-large-edit-*", context.temp_allocator)
	if workspace_error != nil { testing.expect(t, false, "could not create a workspace for the bounded backend edit"); return }
	defer _ = os.remove_all(workspace)
	path := fmt.tprintf("%s/large-edit.txt", workspace)
	source, source_error := make([]u8, int(bridge.MAX_VISIBLE_BYTES), allocator=context.temp_allocator)
	if source_error != nil { testing.expect(t, false, "could not allocate the full visible-window source fixture"); return }
	defer delete(source, context.temp_allocator)
	for &byte in source { byte = 'a' }
	if write_error := os.write_entire_file_from_string(path, string(source)); write_error != nil {
		testing.expect(t, false, "could not write the full visible-window source fixture")
		return
	}
	backend_library, found_library := os.lookup_env("SCRATCHPAD_BACKEND_LIBRARY", context.temp_allocator)
	if !found_library { testing.expect(t, false, "large backend edit test requires the staged shared backend"); return }
	defer delete(backend_library, context.temp_allocator)
	app: App
	loaded, load_message := bridge.backend_load(&app.backend, backend_library)
	testing.expect(t, loaded, fmt.tprintf("shared backend should load for large edit: %s", load_message))
	if !loaded { return }
	started, start_message := bridge.backend_start(&app.backend, workspace, tree_test_wake, nil, context.allocator)
	testing.expect(t, started, fmt.tprintf("shared backend should start for large edit: %s", start_message))
	if !started { return }
	defer {
		if app.backend.started { _, _ = bridge.backend_stop(&app.backend, context.allocator) }
	}
	opened := bridge.backend_command(&app.backend, "open_path", path=path, allocator=context.allocator)
	testing.expect(t, opened.ok && len(app.backend.state.documents) == 1, "backend should open the bounded large-edit fixture")
	bridge.backend_command_result_destroy(&opened, context.allocator)
	document, document_found := find_document(&app.backend.state, app.backend.state.active)
	if !document_found { testing.expect(t, false, "backend should publish the opened large-edit document"); return }
	paste, paste_error := make([]int, 100*1024, allocator=context.temp_allocator)
	if paste_error != nil { testing.expect(t, false, "could not allocate the 100 KiB backend payload"); return }
	defer delete(paste, context.temp_allocator)
	for &value in paste { value = int('p') }
	edit := bridge.backend_command(
		&app.backend,
		"replace_document",
		document_id=document.id,
		editor_revision=document.editor_revision,
		start_byte=u64(len(source)),
		end_byte=u64(len(source)),
		replacement=paste,
		allocator=context.temp_allocator,
	)
	updated, updated_found := find_document(&app.backend.state, document.id)
	testing.expect(t, edit.ok && edit.edit.document_id == document.id &&
		edit.edit.editor_revision == document.editor_revision+1 &&
		edit.edit.new_end_byte == u64(len(source)+len(paste)) && updated_found && updated.dirty &&
		updated.editor_revision == edit.edit.editor_revision && updated.byte_length == u64(len(source)+len(paste)),
		"the real replace_document transport should accept one complete 100 KiB paste and publish its resulting revision/length")
	bridge.backend_command_result_destroy(&edit, context.temp_allocator)
	visible := bridge.backend_command(
		&app.backend,
		"read_visible_lines",
		document_id=document.id,
		start_line=0,
		max_lines=1,
		max_bytes=bridge.MAX_VISIBLE_BYTES,
		allocator=context.temp_allocator,
	)
	testing.expect(t, visible.ok && visible.visible_window_owned &&
		len(visible.visible_window.source) > 0 && len(visible.visible_window.source) <= int(bridge.MAX_VISIBLE_BYTES) &&
		visible.visible_window.line_byte_length == u64(len(source)+len(paste)) &&
		strings.has_prefix(string(visible.visible_window.source), "aaaa"),
		"the backend should continue to return a bounded visible chunk of the enlarged document")
	bridge.backend_command_result_destroy(&visible, context.temp_allocator)
}

@(test)
test_undo_waits_for_pending_optimistic_edit_and_restores_selection :: proc(t: ^testing.T) {
	sync.mutex_lock(&backend_integration_test_mutex)
	defer sync.mutex_unlock(&backend_integration_test_mutex)
	workspace, workspace_error := os.make_directory_temp("", "scratchpad-alicorn-undo-*", context.temp_allocator)
	if workspace_error != nil { testing.expect(t, false, "could not create a temporary workspace for queued Undo"); return }
	defer _ = os.remove_all(workspace)
	path := fmt.tprintf("%s/undo.txt", workspace)
	tail, tail_error := strings.repeat("line\n", 999, context.temp_allocator)
	if tail_error != nil { testing.expect(t, false, "could not create multi-line Undo fixture"); return }
	defer delete(tail, context.temp_allocator)
	source := fmt.aprintf("abc\n%s", tail, allocator=context.temp_allocator)
	defer delete(source, context.temp_allocator)
	if write_error := os.write_entire_file_from_string(path, source); write_error != nil {
		testing.expect(t, false, "could not create the Undo regression source fixture")
		return
	}
	backend_library, found_library := os.lookup_env("SCRATCHPAD_BACKEND_LIBRARY", context.temp_allocator)
	if !found_library { testing.expect(t, false, "queued Undo test requires the staged shared backend"); return }
	defer delete(backend_library, context.temp_allocator)

	app: App
	app.tree_directories = make([dynamic]Tree_Directory, 0, allocator=context.allocator)
	app.editor_views = make([dynamic]Editor_View_State, 0, allocator=context.allocator)
	app.editor_row_targets = make([dynamic]Editor_Row_Target, 0, allocator=context.allocator)
	app.editor_edits = make([dynamic]Editor_Edit_Intent, 0, allocator=context.allocator)
	app.deferred_actions = make([dynamic]Deferred_Action, 0, allocator=context.allocator)
	init_menus(&app)
	loaded, load_message := bridge.backend_load(&app.backend, backend_library)
	testing.expect(t, loaded, fmt.tprintf("shared backend should load for queued Undo: %s", load_message))
	if !loaded { return }
	signal: Editor_Edit_Test_Signal
	started, start_message := bridge.backend_start(&app.backend, workspace, editor_edit_test_wake, rawptr(&signal), context.allocator)
	testing.expect(t, started, fmt.tprintf("shared backend should start for queued Undo: %s", start_message))
	if !started { return }
	gate: sync.Sema
	if !bridge.editor_edit_lane_start(&app.editor_edit_lane, &app.backend, editor_edit_test_wake, rawptr(&signal), context.allocator, &gate) {
		testing.expect(t, false, "serial edit lane should start for queued Undo")
		_, _ = bridge.backend_stop(&app.backend, context.allocator)
		return
	}
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 640, 480})
	defer {
		for _ in 0..<8 { sync.sema_post(&gate) }
		if app.backend.started {
			_ = editor_flush_pending_edits(&app)
			_ = bridge.editor_edit_lane_stop(&app.editor_edit_lane)
			_, _ = bridge.backend_stop(&app.backend, context.allocator)
		}
		editor_window_destroy(&app.editor_window, context.allocator)
		editor_views_destroy(&app.editor_views, context.allocator)
		for index := len(app.editor_edits)-1; index >= 0; index -= 1 { editor_remove_edit(&app, index) }
		delete(app.editor_edits)
		deferred_actions_clear(&app)
		delete(app.deferred_actions)
		delete(app.editor_row_targets)
		tree_clear_directories(&app)
		delete(app.tree_directories)
		if len(app.tree_root_path) > 0 { delete(app.tree_root_path, context.allocator) }
		tree_clear_focused_path(&app)
		alicorn.destroy_runtime(&rt)
	}

	opened := bridge.backend_command(&app.backend, "open_path", path=path, allocator=context.allocator)
	testing.expect(t, opened.ok && len(app.backend.state.documents) == 1, "backend should open the multi-line Undo fixture")
	bridge.backend_command_result_destroy(&opened, context.allocator)
	document, doc_found := find_document(&app.backend.state, app.backend.state.active)
	if !doc_found { testing.expect(t, false, "opened document state should exist"); return }
	initial_editor_revision := document.editor_revision
	initial_line_count := document.line_count
	testing.expect(t, !document.dirty,
		fmt.tprintf("Undo/Redo fixture should start clean (dirty=%v lines=%d bytes=%d)", document.dirty, initial_line_count, document.byte_length))
	if document.dirty { return }
	testing.expect(t, initial_line_count >= 1000,
		fmt.tprintf("Undo/Redo fixture should publish at least 1000 stable lines (lines=%d bytes=%d)", initial_line_count, document.byte_length))
	if initial_line_count < 1000 { return }
	visible := bridge.backend_command(&app.backend, "read_visible_lines", document_id=document.id, start_line=0, max_lines=1, max_bytes=bridge.MAX_VISIBLE_BYTES, allocator=context.allocator)
	testing.expect(t, visible.ok && visible.visible_window_owned,
		fmt.tprintf("backend should provide the bounded source window (ok=%v owned=%v code=%s message=%s)",
			visible.ok, visible.visible_window_owned, visible.code, visible.message))
	if !visible.visible_window_owned { bridge.backend_command_result_destroy(&visible, context.allocator); return }
	window, window_ok, window_error := editor_window_from_visible(&visible.visible_window, context.allocator)
	app.editor_window = window
	app.editor_window_ready = window_ok
	bridge.backend_command_result_destroy(&visible, context.allocator)
	testing.expect(t, window_ok, window_error)
	if !window_ok { return }
	view_index, view_ok := editor_view_ensure(&app.editor_views, document.id)
	if !view_ok { testing.expect(t, false, "editor view should exist for queued Undo"); return }
	view := &app.editor_views[view_index]
	view.selection_anchor = 1
	view.caret_byte = 1
	app.editor_scroll_owner = editor_test_render_scroll_list(&rt, int(document.line_count))
	testing.expect(t, app.editor_scroll_owner != 0 && document.line_count == initial_line_count && initial_line_count >= 1000,
		fmt.tprintf("Undo regression should create a multi-page retained editor list (owner=%d lines=%d)", app.editor_scroll_owner, document.line_count))
	if app.editor_scroll_owner == 0 { return }
	_ = alicorn.scroll_region_set_offset(&rt, app.editor_scroll_owner, f32(900)*EDITOR_ROW_HEIGHT, "move viewport away before Undo")
	owner_before, owner_before_found := rt.nodes[app.editor_scroll_owner]
	testing.expect(t, owner_before_found && owner_before.scroll_offset_y > EDITOR_ROW_HEIGHT*800,
		"Undo regression should move the visible list far away from its original caret line")
	sync_runtime_actions(&app, &rt)
	sync_menu_states(&app)
	_, undo_state_before, undo_action_found := alicorn.action_lookup(&rt, action_id_for(ACTION_EDIT_UNDO))
	testing.expect(t, undo_action_found && !undo_state_before.enabled && !app.edit_items[0].state.enabled,
		"Undo should initially follow the backend's empty history state")
	editor_text_input(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Input_Event{kind=.Commit, text="X"})
	testing.expect(t, len(app.editor_edits) == 1 && string(view.optimistic_window.source) == "aXbc\n",
		"typing should immediately create one optimistic edit while the worker waits at its gate")
	_, undo_state_pending, undo_action_pending_found := alicorn.action_lookup(&rt, action_id_for(ACTION_EDIT_UNDO))
	testing.expect(t, undo_action_pending_found && undo_state_pending.enabled && app.edit_items[0].state.enabled,
		"a queued local edit should immediately enable runtime and native-menu Undo before its backend acknowledgement")
	dispatch_action(&app, &rt, ACTION_EDIT_UNDO)
	testing.expect(t, len(app.deferred_actions) == 1 && app.deferred_actions[0].value == ACTION_EDIT_UNDO,
		"Undo must queue behind an unacknowledged local edit even when published history metadata is stale")

	sync.sema_post(&gate)
	for _ in 0..<120 {
		_ = sync.sema_wait_with_timeout(&signal.sema, time.Duration(100_000_000))
		application_wake(rawptr(&app), &rt)
		if len(app.editor_edits) == 0 && len(app.deferred_actions) == 0 { break }
	}
	testing.expect(t, len(app.editor_edits) == 0 && len(app.deferred_actions) == 0,
		"the edit should acknowledge before the deferred Undo command runs")
	current, current_found := find_document(&app.backend.state, document.id)
	canonical := bridge.backend_command(&app.backend, "read_visible_lines", document_id=document.id, start_line=0, max_lines=1, max_bytes=bridge.MAX_VISIBLE_BYTES, allocator=context.temp_allocator)
	testing.expect(t, current_found && current.editor_revision == initial_editor_revision && !current.dirty &&
		current.byte_length == u64(len(source)) && current.line_count == initial_line_count &&
		canonical.ok && canonical.visible_window_owned && strings.has_prefix(string(canonical.visible_window.source), "abc\n"),
		"Go should apply the queued replacement then Undo, restoring source, editor revision, line count, and clean state")
	bridge.backend_command_result_destroy(&canonical, context.temp_allocator)
	testing.expect(t, view.selection_anchor == 1 && view.caret_byte == 1,
		"the Undo response should restore the original source selection through the semantic command result")
	testing.expect(t,
		editor_reveal_request_matches(view.reveal_request, document.id, initial_editor_revision) &&
		view.reveal_request.source_start == 1 && view.reveal_request.source_end == 1 &&
		view.reveal_request.logical_line == 0 && view.reveal_request.alignment == .Nearest,
		"Undo should queue a matching source-relative reveal for the restored cursor after the viewport moved away")

	sync_runtime_actions(&app, &rt)
	sync_menu_states(&app)
	testing.expect(t, action_enabled(&app.backend.state, ACTION_EDIT_REDO),
		"Undo should publish enabled Redo metadata before the frontend dispatches the next history step")
	dispatch_action(&app, &rt, ACTION_EDIT_REDO)
	current, current_found = find_document(&app.backend.state, document.id)
	canonical = bridge.backend_command(&app.backend, "read_visible_lines", document_id=document.id, start_line=0, max_lines=1, max_bytes=bridge.MAX_VISIBLE_BYTES, allocator=context.temp_allocator)
	testing.expect(t, current_found && current.editor_revision == initial_editor_revision+1 && current.dirty &&
		current.byte_length == u64(len(source)+1) && current.line_count == initial_line_count &&
		canonical.ok && canonical.visible_window_owned && strings.has_prefix(string(canonical.visible_window.source), "aXbc\n"),
		"Redo should restore the edited source and revision, keep line count, and mark the document dirty")
	bridge.backend_command_result_destroy(&canonical, context.temp_allocator)
	testing.expect(t, view.selection_anchor == 2 && view.caret_byte == 2,
		"the Redo response should restore the post-edit caret selection")
}

@(test)
test_canonical_enter_ack_rebases_queued_source_positions :: proc(t: ^testing.T) {
	source, source_error := make([]u8, len("a\nXb"), allocator=context.allocator)
	if source_error != nil { testing.expect(t, false, "could not allocate the optimistic Enter fixture"); return }
	copy(source, "a\nXb")
	visible := bridge.Visible_Window{
		document_id="enter-rebase-test",
		start_line=0,
		end_line=2,
		start_byte=0,
		source=source,
	}
	window, window_ok, window_error := editor_window_from_visible(&visible, context.allocator)
	testing.expect(t, window_ok, window_error)
	if !window_ok { if len(visible.source) > 0 { delete(visible.source, context.allocator) }; return }
	app: App
	app.editor_edits = make([dynamic]Editor_Edit_Intent, 0, allocator=context.allocator)
	view := Editor_View_State{
		optimistic_window=window,
		optimistic_window_ready=true,
		selection_anchor=3,
		caret_byte=3,
	}
	first_id, first_id_error := strings.clone("enter-rebase-test", context.allocator)
	first_bytes, first_bytes_error := make([]u8, 1, allocator=context.allocator)
	second_id, second_id_error := strings.clone("enter-rebase-test", context.allocator)
	second_bytes, second_bytes_error := make([]u8, 1, allocator=context.allocator)
	if first_id_error != nil || first_bytes_error != nil || second_id_error != nil || second_bytes_error != nil {
		testing.expect(t, false, "could not allocate queued Enter-rebase intents")
		delete(first_id, context.allocator)
		delete(first_bytes, context.allocator)
		delete(second_id, context.allocator)
		delete(second_bytes, context.allocator)
		editor_window_destroy(&view.optimistic_window, context.allocator)
		delete(app.editor_edits)
		return
	}
	first_bytes[0] = '\n'
	second_bytes[0] = 'X'
	append(&app.editor_edits,
		Editor_Edit_Intent{document_id=first_id, start_byte=1, end_byte=1, replacement=first_bytes},
		Editor_Edit_Intent{document_id=second_id, start_byte=2, end_byte=2, replacement=second_bytes},
	)
	applied := []u8{'\r', '\n', ' ', ' '}
	reconciled := editor_reconcile_applied_replacement(&app, &view, &app.editor_edits[0], applied)
	testing.expect(t, reconciled && string(view.optimistic_window.source) == "a\r\n  Xb",
		"canonical CRLF plus Scratchpad indentation should replace the optimistic LF without losing later local text")
	testing.expect(t, app.editor_edits[1].start_byte == 5 && app.editor_edits[1].end_byte == 5 &&
		view.caret_byte == 6 && view.selection_anchor == 6,
		"acknowledging Scratchpad's longer Enter replacement should rebase queued edits and the local caret")
	for index := len(app.editor_edits)-1; index >= 0; index -= 1 { editor_remove_edit(&app, index) }
	delete(app.editor_edits)
	editor_window_destroy(&view.optimistic_window, context.allocator)
}

@(test)
test_optimistic_replacements_converge_and_stale_chain_recovers :: proc(t: ^testing.T) {
	sync.mutex_lock(&backend_integration_test_mutex)
	defer sync.mutex_unlock(&backend_integration_test_mutex)
	workspace, workspace_error := os.make_directory_temp("", "scratchpad-alicorn-edit-*", context.temp_allocator)
	if workspace_error != nil {
		testing.expect(t, false, "could not create a temporary workspace for the optimistic edit test")
		return
	}
	defer _ = os.remove_all(workspace)
	path := fmt.tprintf("%s/typing.txt", workspace)
	other_path := fmt.tprintf("%s/other.txt", workspace)
	if write_error := os.write_entire_file_from_string(path, "hello world\r\nsecond\r\nthird\r\n  fourth"); write_error != nil {
		testing.expect(t, false, "could not create the committed-text source fixture")
		return
	}
	if write_error := os.write_entire_file_from_string(other_path, "another document"); write_error != nil {
		testing.expect(t, false, "could not create the deferred-tab fixture")
		return
	}
	backend_library, found_library := os.lookup_env("SCRATCHPAD_BACKEND_LIBRARY", context.temp_allocator)
	if !found_library { testing.expect(t, false, "optimistic editor test requires the staged shared backend"); return }
	defer delete(backend_library, context.temp_allocator)

	app: App
	app.tree_directories = make([dynamic]Tree_Directory, 0, allocator=context.allocator)
	app.editor_views = make([dynamic]Editor_View_State, 0, allocator=context.allocator)
	app.editor_row_targets = make([dynamic]Editor_Row_Target, 0, allocator=context.allocator)
	app.editor_edits = make([dynamic]Editor_Edit_Intent, 0, allocator=context.allocator)
	app.deferred_actions = make([dynamic]Deferred_Action, 0, allocator=context.allocator)
	init_menus(&app)
	loaded, load_message := bridge.backend_load(&app.backend, backend_library)
	testing.expect(t, loaded, fmt.tprintf("shared backend should load for optimistic editor test: %s", load_message))
	if !loaded { return }
	signal: Editor_Edit_Test_Signal
	started, start_message := bridge.backend_start(&app.backend, workspace, editor_edit_test_wake, rawptr(&signal), context.allocator)
	testing.expect(t, started, fmt.tprintf("shared backend should start for optimistic editor test: %s", start_message))
	if !started { return }
	window_lane_started := bridge.visible_window_lane_start(
		&app.visible_window_lane,
		&app.backend,
		editor_edit_test_wake,
		rawptr(&signal),
		context.allocator,
	)
	testing.expect(t, window_lane_started, "the authoritative recovery test should start the bounded visible-window lane")
	if !window_lane_started { _, _ = bridge.backend_stop(&app.backend, context.allocator); return }
	gate: sync.Sema
	lane_started := bridge.editor_edit_lane_start(
		&app.editor_edit_lane,
		&app.backend,
		editor_edit_test_wake,
		rawptr(&signal),
		context.allocator,
		&gate,
	)
	testing.expect(t, lane_started, "one serial editor edit worker should start")
	if !lane_started {
		_ = bridge.visible_window_lane_stop(&app.visible_window_lane)
		_, _ = bridge.backend_stop(&app.backend, context.allocator)
		return
	}
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 1000, 700})
	defer {
		if app.backend.started {
			_ = bridge.visible_window_lane_stop(&app.visible_window_lane)
			for _ in 0..<128 { sync.sema_post(&gate) }
			_ = editor_flush_pending_edits(&app)
			_ = bridge.editor_edit_lane_stop(&app.editor_edit_lane)
			_, _ = bridge.backend_stop(&app.backend, context.allocator)
		}
		editor_window_destroy(&app.editor_window, context.allocator)
		editor_views_destroy(&app.editor_views, context.allocator)
		tree_clear_directories(&app)
		tree_clear_focused_path(&app)
		if len(app.tree_root_path) > 0 { delete(app.tree_root_path, context.allocator) }
		for index := len(app.editor_edits)-1; index >= 0; index -= 1 { editor_remove_edit(&app, index) }
		delete(app.editor_edits)
		deferred_actions_clear(&app)
		delete(app.deferred_actions)
		delete(app.editor_row_targets)
		if len(app.editor_presented_document_id) > 0 { delete(app.editor_presented_document_id, context.allocator) }
		if len(app.editor_window_error) > 0 { delete(app.editor_window_error, context.allocator) }
		if len(app.error_message) > 0 { delete(app.error_message, context.allocator) }
		alicorn.destroy_runtime(&rt)
	}
	opened := bridge.backend_command(&app.backend, "open_path", path=path, allocator=context.temp_allocator)
	testing.expect(t, opened.ok && len(app.backend.state.documents) == 1, "Go should open the real source document before editing")
	bridge.backend_command_result_destroy(&opened, context.temp_allocator)
	typing_document_id, id_error := strings.clone(app.backend.state.active, context.allocator)
	testing.expect(t, id_error == nil && typing_document_id != "", "the typing document identity should be retained for deferred command assertions")
	defer delete(typing_document_id, context.allocator)
	opened_other := bridge.backend_command(&app.backend, "open_path", path=other_path, allocator=context.temp_allocator)
	testing.expect(t, opened_other.ok && len(app.backend.state.documents) == 2, "the second document should open for tab-switch ordering coverage")
	bridge.backend_command_result_destroy(&opened_other, context.temp_allocator)
	selected_typing := bridge.backend_command(&app.backend, "select_document", document_id=typing_document_id, allocator=context.temp_allocator)
	testing.expect(t, selected_typing.ok, "the typing document should be active before committed input begins")
	bridge.backend_command_result_destroy(&selected_typing, context.temp_allocator)
	document, document_found := find_document(&app.backend.state, app.backend.state.active)
	if !document_found { testing.expect(t, false, "opened source document should have authoritative state"); return }
	base_editor_revision := document.editor_revision
	base_application_revision := app.backend.state.application_rev
	visible := bridge.backend_command(
		&app.backend,
		"read_visible_lines",
		document_id=document.id,
		start_line=0,
		max_lines=bridge.MAX_VISIBLE_LINES,
		max_bytes=bridge.MAX_VISIBLE_BYTES,
		allocator=context.allocator,
	)
	testing.expect(t, visible.ok && visible.visible_window_owned, "the initial source should arrive through the existing bounded window resource")
	if !visible.visible_window_owned { bridge.backend_command_result_destroy(&visible, context.allocator); return }
	window, window_ok, window_error := editor_window_from_visible(&visible.visible_window, context.allocator)
	app.editor_window = window
	app.editor_window_ready = window_ok
	bridge.backend_command_result_destroy(&visible, context.allocator)
	testing.expect(t, window_ok, window_error)
	if !window_ok { return }
	if !alicorn.text_engine_load_font(&rt.text_engine, ALICORN_TEST_UI_FONT_DATA) ||
	   !alicorn.text_engine_load_font_role(&rt.text_engine, .Monospace, ALICORN_TEST_MONO_FONT_DATA) {
		testing.expect(t, false, "optimistic editor test should load the bundled UI and monospace fonts")
		return
	}
	_ = build_app(rawptr(&app), &rt, 1000, 700, 1)
	view_index, view_ok := editor_view_ensure(&app.editor_views, document.id)
	testing.expect(t, view_ok && app.editor_scroll_owner != 0, "the real document build should create a durable editor owner")
	if !view_ok { return }
	view := &app.editor_views[view_index]
	view.caret_byte = 9 // hello wor|ld
	view.selection_anchor = view.caret_byte
	_ = alicorn.focus(&rt, app.editor_scroll_owner)
	_ = build_app(rawptr(&app), &rt, 1000, 700, 1)
	if caret_node := editor_row_node_for_line(app.editor_row_targets[:], 0); caret_node != 0 {
		geometry := alicorn.text_node_caret_geometry(&rt, caret_node, alicorn.Text_Position{byte=9, affinity=.Leading})
		area, area_ok := alicorn.text_input_area(&rt, app.editor_scroll_owner)
		testing.expect(t, geometry.valid && area_ok && area.rect.y == geometry.rect.y && area.rect.h >= geometry.rect.h,
			"the generic text-input candidate area should follow the shaped caret row after layout")
	} else {
		testing.expect(t, false, "focused source row should be retained for candidate-area geometry")
	}
	commits := [7]string{"x", "a", "b", "c", "d", "e", "f"}
	for text in commits {
		editor_text_input(
			rawptr(&app),
			&rt,
			app.editor_scroll_owner,
			host.Application_Text_Input_Event{kind=.Commit, text=text},
		)
	}
	// Replace a directional selection, then join lines with Backspace and
	// Delete. All three operations must share the same optimistic replacement
	// path while the first Caliber request remains deliberately blocked.
	view.selection_anchor = 9
	view.caret_byte = 16
	editor_text_input(
		rawptr(&app),
		&rt,
		app.editor_scroll_owner,
		host.Application_Text_Input_Event{kind=.Commit, text="X"},
	)
	second_line, second_found := editor_window_line(&view.optimistic_window, 1)
	testing.expect(t, second_found, "optimistic multi-line source should retain the second logical line")
	if second_found {
		view.selection_anchor = second_line.source_start
		view.caret_byte = second_line.source_start
		_ = editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Backspace})
	}
	joined_line, joined_found := editor_window_line(&view.optimistic_window, 0)
	testing.expect(t, joined_found, "Backspace at line start should leave the joined line available")
	if joined_found {
		view.selection_anchor = joined_line.source_end
		view.caret_byte = joined_line.source_end
		_ = editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Delete})
	}
	fourth_line, fourth_found := editor_window_line(&view.optimistic_window, 1)
	testing.expect(t, fourth_found, "the trailing indented line should remain addressable after cross-line joins")
	if fourth_found {
		view.selection_anchor = fourth_line.source_start+2
		view.caret_byte = fourth_line.source_start+2
		first_enter_handled := application_key(rawptr(&app), &rt, .Return)
		second_enter_handled := application_key(rawptr(&app), &rt, .Return)
		testing.expect(t, first_enter_handled && second_enter_handled,
			"the focused editor viewport should consume both Enter keys")
		tab_handled := editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Tab})
		testing.expect(t, tab_handled && strings.has_suffix(string(view.optimistic_window.source), "      fourth"),
			"Tab should insert one four-space indentation unit immediately without yielding editor focus")
		shift_tab_handled := editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Tab, shift=true})
		testing.expect(t, shift_tab_handled && strings.has_suffix(string(view.optimistic_window.source), "  fourth"),
			"Shift+Tab should remove one indentation unit from the current line through the same replacement lane")
		editor_text_input(
			rawptr(&app),
			&rt,
			app.editor_scroll_owner,
			host.Application_Text_Input_Event{kind=.Commit, text="X"},
		)
	}
	expected_optimistic := "hello worXldsecondthird\r\n  \r\n  \r\n  Xfourth"
	testing.expect(t, bridge.editor_edit_lane_is_active(&app.editor_edit_lane) && len(app.editor_edits) == 15,
		"the first request should be held in flight while replacements, Enter, and Tab indentation accumulate locally")
	testing.expect(t, view.optimistic_window_ready && string(view.optimistic_window.source) == expected_optimistic,
		"typing, selection replacement, cross-line deletion, and Scratchpad-indented Enter should update the bounded projection before backend acknowledgement")
	testing.expect(t, view.caret_byte == u64(len("hello worXldsecondthird\r\n  \r\n  \r\n  X")) &&
		view.optimistic_pending_edits == 15 && view.optimistic_window.end_line == 4 &&
		view.optimistic_line_delta == 0,
		"the replacement queue should preserve the caret and reflect both deleted and inserted logical lines immediately")
	other_document_id := ""
	for candidate in app.backend.state.documents {
		if candidate.id != typing_document_id { other_document_id = candidate.id; break }
	}
	other_document_id_copy, other_id_error := strings.clone(other_document_id, context.allocator)
	testing.expect(t, other_id_error == nil && other_document_id_copy != "", "the second document identity should be available for a queued tab switch")
	defer delete(other_document_id_copy, context.allocator)
	select_document(&app, &rt, other_document_id_copy)
	testing.expect(t, len(app.deferred_actions) == 1 && app.backend.state.active == typing_document_id && app.error_message == "",
		"tab selection should queue invisibly behind the edits without changing the active document or showing a wait error")
	_ = build_app(rawptr(&app), &rt, 1000, 700, 1)
	optimistic_text_rendered := false
	chrome_became_disabled := false
	for node_id in rt.order {
		if node, found := rt.nodes[node_id]; found {
			if node.key == fmt.tprintf("scratchpad-line:%s:0", document.id) {
				optimistic_text_rendered = node.text == "hello worXldsecondthird"
			}
			if node.key == "action-file-open" || node.key == "action-workspace-open" ||
			   node.key == "action-document-close" || node.key == fmt.tprintf("tab:%s", typing_document_id) ||
			   node.key == fmt.tprintf("tab-close:%s", typing_document_id) {
				chrome_became_disabled = chrome_became_disabled || node.disabled
			}
		}
	}
	testing.expect(t, optimistic_text_rendered,
		"the rebuilt Alicorn description should visibly contain all committed characters before the backend lane is released")
	testing.expect(t, !chrome_became_disabled,
		"pending editor acknowledgements must not flash the toolbar or tab controls into disabled styling")
	testing.expect(t, app.file_items[0].state.enabled && app.file_items[1].state.enabled,
		"native menu availability should remain stable while source edits are pending")
	state_while_held, state_held_ok, state_held_error := bridge.backend_read_latest(&app.backend, context.temp_allocator)
	testing.expect(t, state_held_ok && !state_while_held && app.backend.state.application_rev == base_application_revision,
		fmt.tprintf("the held worker must not mutate or publish backend state before its dispatch gate opens: %s", state_held_error))
	canonical_before_ack := bridge.backend_command(
		&app.backend,
		"read_visible_lines",
		document_id=document.id,
		start_line=0,
		max_lines=bridge.MAX_VISIBLE_LINES,
		max_bytes=bridge.MAX_VISIBLE_BYTES,
		allocator=context.temp_allocator,
	)
	testing.expect(t, canonical_before_ack.ok && string(canonical_before_ack.visible_window.source) == "hello world\r\nsecond\r\nthird\r\n  fourth",
		"the authoritative document should remain unchanged while only the first local edit is queued")
	bridge.backend_command_result_destroy(&canonical_before_ack, context.temp_allocator)
	for _ in 0..<15 { sync.sema_post(&gate) }
	for _ in 0..<120 {
		if len(app.editor_edits) == 0 { break }
		_ = sync.sema_wait_with_timeout(&signal.sema, time.Duration(100_000_000))
		application_wake(rawptr(&app), &rt)
	}
	testing.expect(t, len(app.editor_edits) == 0 && len(app.deferred_actions) == 0 && view.optimistic_pending_edits == 0,
		"all delayed edits should be acknowledged serially and then drain the deferred tab selection")
	testing.expect(t, app.backend.state.active == other_document_id_copy,
		"the queued tab switch should execute after the final authoritative edit acknowledgement")
	document_after, found_after := find_document(&app.backend.state, document.id)
	testing.expect(t, found_after && document_after.editor_revision == base_editor_revision+15 && document_after.line_count == 4,
		"every replacement and Enter should converge through its own ordered revision and update authoritative line topology")
	canonical_after := bridge.backend_command(
		&app.backend,
		"read_visible_lines",
		document_id=typing_document_id,
		start_line=0,
		max_lines=bridge.MAX_VISIBLE_LINES,
		max_bytes=bridge.MAX_VISIBLE_BYTES,
		allocator=context.temp_allocator,
	)
	testing.expect(t, canonical_after.ok && canonical_after.visible_window_owned && string(canonical_after.visible_window.source) == expected_optimistic,
		"the final Caliber visible window should match the complete local replacement projection")
	bridge.backend_command_result_destroy(&canonical_after, context.temp_allocator)

	// Start a second chain, accept its first replacement, then mutate the
	// authoritative document before the next serialized request is dispatched.
	// The stale edit and all dependent local edits must be discarded together.
	select_document(&app, &rt, typing_document_id)
	document_before_stale, found_before_stale := find_document(&app.backend.state, typing_document_id)
	testing.expect(t, found_before_stale, "the source document should be active for stale-chain recovery")
	if !found_before_stale { return }
	stale_base_revision := document_before_stale.editor_revision
	publication_before_external_edit := app.backend.state_revision
	view_index, view_ok = editor_view_ensure(&app.editor_views, typing_document_id)
	testing.expect(t, view_ok, "the source document should retain its local editor view across tab changes")
	if !view_ok { return }
	view = &app.editor_views[view_index]
	view.caret_byte = view.optimistic_window.start_byte+u64(len(view.optimistic_window.source))
	view.selection_anchor = view.caret_byte
	stale_chain_commits := [4]string{"a", "b", "c", "d"}
	for text in stale_chain_commits {
		editor_text_input(
			rawptr(&app),
			&rt,
			app.editor_scroll_owner,
			host.Application_Text_Input_Event{kind=.Commit, text=text},
		)
	}
	testing.expect(t, len(app.editor_edits) == 4 &&
		string(view.optimistic_window.source) == fmt.tprintf("%sabcd", expected_optimistic),
		"four rapid local edits should be visible while only the first request is in flight")
	sync.sema_post(&gate)
	for _ in 0..<120 {
		if len(app.editor_edits) == 3 && view.authoritative_revision == stale_base_revision+1 { break }
		_ = sync.sema_wait_with_timeout(&signal.sema, time.Duration(100_000_000))
		application_wake(rawptr(&app), &rt)
	}
	testing.expect(t, len(app.editor_edits) == 3 && view.authoritative_revision == stale_base_revision+1,
		"the first edit should be accepted and the dependent second edit should be the sole in-flight request")
	canonical_after_first := bridge.backend_command(
		&app.backend,
		"read_visible_lines",
		document_id=typing_document_id,
		start_line=0,
		max_lines=bridge.MAX_VISIBLE_LINES,
		max_bytes=bridge.MAX_VISIBLE_BYTES,
		allocator=context.temp_allocator,
	)
	testing.expect(t, canonical_after_first.ok && canonical_after_first.visible_window_owned &&
		string(canonical_after_first.visible_window.source) == fmt.tprintf("%sa", expected_optimistic),
		"the first replacement should be authoritative before the dependent request is challenged")
	concurrent_change_byte := canonical_after_first.visible_window.start_byte+u64(len(canonical_after_first.visible_window.source))
	bridge.backend_command_result_destroy(&canonical_after_first, context.temp_allocator)
	concurrent_change := bridge.backend_command(
		&app.backend,
		"replace_document",
		document_id=typing_document_id,
		editor_revision=view.authoritative_revision,
		start_byte=concurrent_change_byte,
		end_byte=concurrent_change_byte,
		replacement=[]int{'!'},
		allocator=context.temp_allocator,
	)
	testing.expect(t, concurrent_change.ok,
		"an external authoritative edit should advance the revision while the next serial request remains gated")
	bridge.backend_command_result_destroy(&concurrent_change, context.temp_allocator)
	testing.expect(t, view.optimistic_pending_edits == 3 && len(app.editor_edits) == 3,
		"the optimistic dependent chain should remain local until the stale response is handled")
	// Reproduce a stale local publication: another command advanced the real
	// document, but this frontend has not yet adopted that newer state envelope.
	app.backend.state_revision = publication_before_external_edit
	for &stale_document in app.backend.state.documents {
		if stale_document.id == typing_document_id {
			stale_document.editor_revision = stale_base_revision+1
			break
		}
	}
	sync.sema_post(&gate)
	for _ in 0..<120 {
		if len(app.editor_edits) == 0 { break }
		_ = sync.sema_wait_with_timeout(&signal.sema, time.Duration(100_000_000))
		application_wake(rawptr(&app), &rt)
	}
	testing.expect(t, len(app.editor_edits) == 0 && view.optimistic_pending_edits == 0 &&
		!view.optimistic_window_ready && view.position_reconcile_pending,
		"a stale request must discard itself and every dependent optimistic edit, then invalidate the old bounded window")
	conflicted_document, conflicted_document_found := find_document(&app.backend.state, typing_document_id)
	testing.expect(t, conflicted_document_found && conflicted_document.editor_revision == stale_base_revision+2 &&
		app.backend.state_revision > publication_before_external_edit && !app.editor_window_ready,
		"stale rejection should adopt the newer state publication and evict any cached window before recovery")
	testing.expect(t, strings.contains(app.error_message, "reloading authoritative text"),
		"stale rejection should report the controlled recovery instead of silently diverging")

	// Rebuild asks the existing visible-window lane for the canonical revision.
	_ = build_app(rawptr(&app), &rt, 1000, 700, 1)
	for _ in 0..<120 {
		current_document, current_found := find_document(&app.backend.state, typing_document_id)
		if current_found && app.editor_window_ready &&
		   app.editor_window.document_id == typing_document_id &&
		   app.editor_window.editor_revision == current_document.editor_revision { break }
		_ = sync.sema_wait_with_timeout(&signal.sema, time.Duration(100_000_000))
		application_wake(rawptr(&app), &rt)
	}
	recovered_document, recovered_found := find_document(&app.backend.state, typing_document_id)
	testing.expect(t, recovered_found, "the authoritative source document should survive stale recovery")
	if !recovered_found { return }
	recovered_revision := recovered_document.editor_revision
	recovered_expected := fmt.tprintf("%sa!", expected_optimistic)
	_, caret_is_legal := editor_line_for_source(&app.editor_window, view.caret_byte)
	testing.expect(t, recovered_found && app.editor_window_ready &&
		app.editor_window.editor_revision == recovered_document.editor_revision &&
		string(app.editor_window.source) == recovered_expected,
		"the bounded window should reload the exact authoritative bytes, including the concurrent edit but excluding rejected dependents")
	testing.expect(t, !view.position_reconcile_pending &&
		view.authoritative_revision == recovered_revision &&
		view.caret_byte >= app.editor_window.start_byte &&
		view.caret_byte <= app.editor_window.start_byte+u64(len(app.editor_window.source)) &&
		caret_is_legal,
		"recovery should clamp and normalize the caret to a legal source boundary in the reloaded window")
	testing.expect(t, app.error_message == "",
		"a successful authoritative reload should clear the temporary stale-edit alert")

	// The recovered editor remains usable: a new local edit should be accepted
	// against the new authoritative revision and converge normally.
	editor_text_input(
		rawptr(&app),
		&rt,
		app.editor_scroll_owner,
		host.Application_Text_Input_Event{kind=.Commit, text="z"},
	)
	testing.expect(t, len(app.editor_edits) == 1 &&
		string(view.optimistic_window.source) == fmt.tprintf("%sz", recovered_expected),
		"typing should resume immediately on the recovered authoritative projection")
	sync.sema_post(&gate)
	for _ in 0..<120 {
		if len(app.editor_edits) == 0 { break }
		_ = sync.sema_wait_with_timeout(&signal.sema, time.Duration(100_000_000))
		application_wake(rawptr(&app), &rt)
	}
	final_document, final_found := find_document(&app.backend.state, typing_document_id)
	canonical_final := bridge.backend_command(
		&app.backend,
		"read_visible_lines",
		document_id=typing_document_id,
		start_line=0,
		max_lines=bridge.MAX_VISIBLE_LINES,
		max_bytes=bridge.MAX_VISIBLE_BYTES,
		allocator=context.temp_allocator,
	)
	final_expected := fmt.tprintf("%sz", recovered_expected)
	testing.expect(t, len(app.editor_edits) == 0 && view.optimistic_pending_edits == 0 &&
		final_found && final_document.editor_revision == recovered_revision+1 &&
		view.authoritative_revision == final_document.editor_revision &&
		canonical_final.ok && canonical_final.visible_window_owned &&
		string(canonical_final.visible_window.source) == final_expected &&
		string(view.optimistic_window.source) == string(canonical_final.visible_window.source),
		"post-recovery editing should converge with no pending edits and identical optimistic/canonical bytes")
	bridge.backend_command_result_destroy(&canonical_final, context.temp_allocator)
	testing.expect(t, app.backend.state_leases == 0 && app.backend.resource_leases == 0,
		"the success and stale-recovery paths should leave no Caliber publication or resource leases outstanding")
}
