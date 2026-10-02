package main

import "core:fmt"
import "core:strings"
import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"
import bridge "./bridge"

Shutdown_Intent :: enum {None, Quit_Application}
shutdown_has_uncommitted_work :: proc(app: ^App) -> bool {
	if app == nil { return false }
	if len(app.editor_edits) > 0 { return true }
	for document in app.backend.state.documents { if document.dirty { return true } }
	for view in app.editor_views {
		if view.preedit_active && view.preedit_recoverable { return true }
	}
	return false
}

shutdown_dirty_document_count :: proc(app: ^App) -> int {
	if app == nil { return 0 }
	count := 0
	for document in app.backend.state.documents { if document.dirty { count += 1 } }
	return count
}

shutdown_recoverable_document :: proc(app: ^App) -> string {
	if app == nil { return "" }
	for view in app.editor_views {
		if view.preedit_active && view.preedit_recoverable { return view.document_id }
	}
	return ""
}

shutdown_begin :: proc(app: ^App, rt: ^alicorn.Runtime, intent: Shutdown_Intent) {
	if app == nil || intent == .None { return }
	app.shutdown_intent = intent
	app.shutdown_edit_failed = false
	if rt != nil { alicorn.invalidate_root(rt, "Scratchpad deferred shutdown for unsaved editor work") }
}

application_close_requested :: proc(state: rawptr, rt: ^alicorn.Runtime) -> host.Application_Close_Result {
	app := cast(^App)state
	if app == nil || !app.backend.started { return .Allow }
	if app.shutdown_intent != .None { return .Defer }
	if !shutdown_has_uncommitted_work(app) { return .Allow }
	shutdown_begin(app, rt, .Quit_Application)
	return .Defer
}

shutdown_cancel :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil { return }
	app.shutdown_intent = .None
	app.shutdown_edit_failed = false
	if rt != nil { alicorn.invalidate_root(rt, "Scratchpad shutdown request cancelled") }
}

shutdown_finish :: proc(app: ^App) {
	if app == nil { return }
	intent := app.shutdown_intent
	app.shutdown_intent = .None
	app.shutdown_edit_failed = false
	if intent == .Quit_Application {
		host.application_request_quit(app.services.quit)
	}
}

shutdown_advance :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || app.shutdown_intent == .None || app.shutdown_edit_failed || len(app.editor_edits) > 0 { return }
	if shutdown_dirty_document_count(app) > 0 || shutdown_recoverable_document(app) != "" { return }
	shutdown_finish(app)
}

shutdown_save_all :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || !app.backend.started || len(app.editor_edits) > 0 { return }
	document_ids := make([dynamic]string, 0, allocator=context.allocator)
	for document in app.backend.state.documents {
		if !document.dirty { continue }
		id, clone_error := strings.clone(document.id, context.allocator)
		if clone_error != nil {
			for owned_id in document_ids { delete(owned_id, context.allocator) }
			delete(document_ids)
			set_error(app, "Could not retain document identities while saving before shutdown.")
			if rt != nil { alicorn.invalidate_root(rt, "Scratchpad could not prepare save-all shutdown") }
			return
		}
		append(&document_ids, id)
	}
	for id in document_ids {
		response := bridge.backend_command(&app.backend, "save_document", document_id=id)
		if !response.ok { handle_command_result(app, rt, &response) }
		ok := response.ok
		bridge.backend_command_result_destroy(&response, context.allocator)
		if !ok {
			for owned_id in document_ids { delete(owned_id, context.allocator) }
			delete(document_ids)
			return
		}
	}
	for owned_id in document_ids { delete(owned_id, context.allocator) }
	delete(document_ids)
	set_error(app, "")
	shutdown_advance(app, rt)
	if rt != nil { alicorn.invalidate_root(rt, "Scratchpad saved modified documents before shutdown") }
}

shutdown_discard_all :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || len(app.editor_edits) > 0 { return }
	for &view in app.editor_views {
		if view.preedit_active && view.preedit_recoverable {
			editor_preedit_clear(&view)
		}
	}
	shutdown_finish(app)
}

build_shutdown_dialog :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime) {
	if app == nil || ui == nil { return }
	alicorn.modal_overlay_begin(ui, alicorn.key_string("shutdown-overlay"), style=alicorn.layout_style(.Column, grow=1, align=.Center), backdrop_color=alicorn.Color{0.015, 0.02, 0.03, 0.72})
	alicorn.container_begin(ui, .Container, label="shutdown-dialog", style=alicorn.layout_style(.Column, width=540, height=320, padding=22, gap=12, align=.Start, clip=true), color=COLOR_PANEL)
	alicorn.text(ui, "Save changes before closing Scratchpad?")
	if len(app.editor_edits) > 0 {
		alicorn.text(ui, fmt.tprintf("Waiting for %d pending editor change(s) to finish.", len(app.editor_edits)))
	} else {
		dirty_count := shutdown_dirty_document_count(app)
		if dirty_count > 0 {
			alicorn.text(ui, fmt.tprintf("%d modified document(s) have unsaved changes.", dirty_count))
		}
		if app.shutdown_edit_failed {
			alicorn.text(ui, "An editor change could not be saved. Review the error above or explicitly discard it.")
		}
		recoverable_id := shutdown_recoverable_document(app)
		if recoverable_id != "" {
			if document, found := find_document(&app.backend.state, recoverable_id); found {
				alicorn.text(ui, fmt.tprintf("Committed input in %s is waiting to be copied or discarded.", document_title(document.path)))
			} else {
				alicorn.text(ui, "Committed input is waiting to be copied or discarded.")
			}
			alicorn.container_begin(ui, .Container, label="shutdown-recovery-actions", style=alicorn.layout_style(.Row, height=38, gap=8, align=.Center))
			if alicorn.button(ui, "Copy Recovery", key=alicorn.key_string("shutdown-copy-recovery"), style=alicorn.layout_style(.Row, width=135, height=34)) {
				_ = editor_copy_recoverable_preedit(app, rt, recoverable_id)
				shutdown_advance(app, rt)
			}
			if alicorn.button(ui, "Discard Recovery", key=alicorn.key_string("shutdown-discard-recovery"), style=alicorn.layout_style(.Row, width=145, height=34)) {
				_ = editor_discard_recoverable_preedit(app, rt, recoverable_id)
				shutdown_advance(app, rt)
			}
			alicorn.container_end(ui)
		}
		if dirty_count > 0 {
			alicorn.container_begin(ui, .Container, label="shutdown-document-actions", style=alicorn.layout_style(.Row, height=38, gap=8, align=.Center))
			if alicorn.button(ui, "Save All", key=alicorn.key_string("shutdown-save-all"), style=alicorn.layout_style(.Row, width=115, height=34)) {
				shutdown_save_all(app, rt)
			}
			if alicorn.button(ui, "Discard All", key=alicorn.key_string("shutdown-discard-all"), style=alicorn.layout_style(.Row, width=115, height=34)) {
				shutdown_discard_all(app, rt)
			}
			alicorn.container_end(ui)
		}
		if app.shutdown_edit_failed && dirty_count == 0 {
			if alicorn.button(ui, "Close Anyway", key=alicorn.key_string("shutdown-edit-failure-discard"), style=alicorn.layout_style(.Row, width=135, height=34)) {
				shutdown_discard_all(app, rt)
			}
		}
	}
	alicorn.container_begin(ui, .Container, label="shutdown-cancel-actions", style=alicorn.layout_style(.Row, height=38, gap=8, align=.End))
	if alicorn.button(ui, "Cancel", key=alicorn.key_string("shutdown-cancel"), style=alicorn.layout_style(.Row, width=90, height=34)) {
		shutdown_cancel(app, rt)
	}
	alicorn.container_end(ui)
	alicorn.container_end(ui)
	alicorn.modal_overlay_end(ui)
}

application_dialog :: proc(state: rawptr, rt: ^alicorn.Runtime, result: ^host.File_Dialog_Result) {
	app := cast(^App)state
	if result == nil { return }
	if result.status == .Error {
		app.dialog_action = ""
		clear_dialog_document(app)
		set_error(app, result.error)
		alicorn.invalidate_root(rt, "Scratchpad native dialog failed")
		deferred_actions_run(app, rt)
		return
	}
	if result.status != .Accepted || len(result.paths) == 0 {
		app.dialog_action = ""
		clear_dialog_document(app)
		deferred_actions_run(app, rt)
		return
	}
	path := result.paths[0]
	if app.dialog_action == ACTION_FILE_SAVE_AS {
		if len(app.editor_edits) > 0 {
			if !deferred_action_enqueue(app, .Save_As_Path, value=app.dialog_document_id, path=path) {
				set_error(app, "Could not queue the selected Save As destination behind pending edits.")
			}
		} else {
			save_as_to_path(app, rt, app.dialog_document_id, path)
		}
		app.dialog_action = ""
		clear_dialog_document(app)
		deferred_actions_run(app, rt)
		return
	}
	if len(app.editor_edits) > 0 {
		if !deferred_action_enqueue(app, .Open_Path, path=path) {
			set_error(app, "Could not queue the selected file behind pending edits.")
		}
	} else {
		open_path, clone_error := strings.clone(path, context.allocator)
		if clone_error != nil {
			set_error(app, "Could not retain the selected file path.")
			alicorn.invalidate_root(rt, "Scratchpad could not retain selected dialog path")
		} else {
			open_path_from_dialog(app, rt, open_path)
		}
	}
	app.dialog_action = ""
	clear_dialog_document(app)
	deferred_actions_run(app, rt)
}

clear_dialog_document :: proc(app: ^App) {
	if app == nil { return }
	if len(app.dialog_document_id) > 0 { delete(app.dialog_document_id, context.allocator) }
	app.dialog_document_id = ""
}

save_as_to_path :: proc(app: ^App, rt: ^alicorn.Runtime, document_id, path: string) {
	if app == nil || rt == nil || !app.backend.started || document_id == "" || path == "" { return }
	response := bridge.backend_command(&app.backend, "save_as_document", document_id=document_id, path=path)
	if !response.ok && response.code == "save_as_destination_exists" && response.save_as_conflict.token != 0 {
		save_as_confirmation_clear(app)
		app.save_as_confirmation_document_id, _ = strings.clone(document_id, context.allocator)
		app.save_as_confirmation_path, _ = strings.clone(response.save_as_conflict.path, context.allocator)
		if app.save_as_confirmation_document_id != "" && app.save_as_confirmation_path != "" {
			app.save_as_confirmation_token = response.save_as_conflict.token
			app.save_as_confirmation_open = true
			set_error(app, "")
		} else {
			save_as_confirmation_clear(app)
			set_error(app, "Could not retain the Save As overwrite confirmation.")
		}
		alicorn.invalidate_root(rt, "Scratchpad requested Save As overwrite confirmation")
	} else {
		if response.ok { editor_migrate_after_save_as(app, rt, document_id) }
		handle_command_result(app, rt, &response)
	}
	bridge.backend_command_result_destroy(&response, context.allocator)
}

save_as_confirm_overwrite :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil || !app.save_as_confirmation_open || app.save_as_confirmation_token == 0 { return }
	response := bridge.backend_command(
		&app.backend, "confirm_save_as",
		document_id=app.save_as_confirmation_document_id,
		save_as_token=app.save_as_confirmation_token,
	)
	if response.ok { editor_migrate_after_save_as(app, rt, app.save_as_confirmation_document_id) }
	save_as_confirmation_clear(app)
	handle_command_result(app, rt, &response)
	bridge.backend_command_result_destroy(&response, context.allocator)
	deferred_actions_run(app, rt)
}

save_as_cancel_overwrite :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil || !app.save_as_confirmation_open { return }
	response := bridge.backend_command(
		&app.backend, "cancel_save_as",
		document_id=app.save_as_confirmation_document_id,
		save_as_token=app.save_as_confirmation_token,
		read_latest_after=false,
	)
	bridge.backend_command_result_destroy(&response, context.allocator)
	save_as_confirmation_clear(app)
	deferred_actions_run(app, rt)
	alicorn.invalidate_root(rt, "Scratchpad cancelled Save As overwrite")
}

save_as_confirmation_clear :: proc(app: ^App) {
	if app == nil { return }
	if len(app.save_as_confirmation_document_id) > 0 { delete(app.save_as_confirmation_document_id, context.allocator) }
	if len(app.save_as_confirmation_path) > 0 { delete(app.save_as_confirmation_path, context.allocator) }
	app.save_as_confirmation_document_id = ""
	app.save_as_confirmation_path = ""
	app.save_as_confirmation_token = 0
	app.save_as_confirmation_open = false
}

editor_migrate_after_save_as :: proc(app: ^App, rt: ^alicorn.Runtime, old_id: string) {
	if app == nil || old_id == "" { return }
	new_id := app.backend.state.active
	if new_id == "" || new_id == old_id { return }
	if index := editor_view_find(app.editor_views[:], old_id); index >= 0 {
		copy, err := strings.clone(new_id, context.allocator)
		if err == nil {
			delete(app.editor_views[index].document_id, context.allocator)
			app.editor_views[index].document_id = copy
		}
	}
	if app.editor_presented_document_id == old_id {
		copy, err := strings.clone(new_id, context.allocator)
		if err == nil {
			delete(app.editor_presented_document_id, context.allocator)
			app.editor_presented_document_id = copy
		}
	}
	if app.editor_window_ready && app.editor_window.document_id == old_id {
		editor_window_destroy(&app.editor_window)
		app.editor_window_ready = false
		app.editor_request_generation += 1
		editor_window_rejection_clear(app)
		if rt != nil { alicorn.invalidate_root(rt, "Scratchpad reloaded editor projection after Save As identity change") }
	}
}

open_path_from_dialog :: proc(app: ^App, rt: ^alicorn.Runtime, path: string) {
	defer delete(path, context.allocator)
	if action, found := find_action(&app.backend.state, app.dialog_action); found {
		cause := alicorn.cause_begin(rt, .Application, "native file dialog selection", action_id_for(action.id))
		alicorn.trace_action(rt, action_id_for(action.id), action.title)
		response := bridge.backend_command(&app.backend, "open_path", path=path)
		handle_command_result(app, rt, &response)
		bridge.backend_command_result_destroy(&response, context.allocator)
		alicorn.cause_end(rt, cause)
	} else {
		set_error(app, "The file dialog completed without a matching Scratchpad action.")
		alicorn.invalidate_root(rt, "Scratchpad dialog action was unavailable")
	}
}

request_file_dialog :: proc(app: ^App, rt: ^alicorn.Runtime, kind: host.File_Dialog_Kind, title: string) {
	app.dialog_sequence += 1
	app.dialog_action = ACTION_WORKSPACE_OPEN
	if kind == .Open_File { app.dialog_action = ACTION_FILE_OPEN }
	if kind == .Save_File {
		app.dialog_action = ACTION_FILE_SAVE_AS
		clear_dialog_document(app)
		copy, clone_error := strings.clone(app.backend.state.active, context.allocator)
		if clone_error != nil {
			app.dialog_action = ""
			set_error(app, "Could not retain the active document for Save As.")
			alicorn.invalidate_root(rt, "Scratchpad could not retain the Save As document identity")
			return
		}
		app.dialog_document_id = copy
	}
	request := host.File_Dialog_Request{
		id=host.Dialog_ID(app.dialog_sequence),
		kind=kind,
		title=title,
		initial_location=app.backend.state.workspace_root,
		allow_many=false,
	}
	if !host.ShowFileDialog(app.services.dialogs, request) {
		app.dialog_action = ""
		clear_dialog_document(app)
		set_error(app, "The native file dialog could not be opened.")
		alicorn.invalidate_root(rt, "Scratchpad native dialog request failed")
		deferred_actions_run(app, rt)
	}
}

request_close_document :: proc(app: ^App, rt: ^alicorn.Runtime, document_id: string) {
	if document_id == "" { return }
	if editor_document_has_recoverable_preedit(app, document_id) {
		if app.close_document_id != document_id {
			clear_close_prompt(app)
			app.close_document_id, _ = strings.clone(document_id, context.allocator)
		}
		set_error(app, "Copy or explicitly discard the committed IME recovery text before closing this document.")
		if rt != nil { alicorn.invalidate_root(rt, "Scratchpad blocked close to preserve committed IME text") }
		return
	}
	if len(app.editor_edits) > 0 {
		if !deferred_action_enqueue(app, .Close_Document, value=document_id) {
			set_error(app, "Could not queue the document close behind pending edits.")
			alicorn.invalidate_root(rt, "Scratchpad document close queue is full")
		}
		return
	}
	response := bridge.backend_command(&app.backend, "close_document", document_id=document_id)
	handle_command_result(app, rt, &response)
	bridge.backend_command_result_destroy(&response, context.allocator)
}

close_after_save :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if editor_document_has_recoverable_preedit(app, app.close_document_id) {
		set_error(app, "Copy the committed IME recovery text with Edit > Copy before closing this document.")
		if rt != nil { alicorn.invalidate_root(rt, "Scratchpad blocked save-and-close to preserve committed IME text") }
		return
	}
	if len(app.editor_edits) > 0 {
		if !deferred_action_enqueue(app, .Close_After_Save) {
			set_error(app, "Could not queue save-and-close behind pending edits.")
			alicorn.invalidate_root(rt, "Scratchpad save-and-close queue is full")
		}
		return
	}
	document_id, clone_err := strings.clone(app.close_document_id, context.allocator)
	if clone_err != nil { set_error(app, "Could not retain the pending document identity."); return }
	saved := bridge.backend_command(&app.backend, "save_document", document_id=document_id)
	if !saved.ok {
		handle_command_result(app, rt, &saved)
		bridge.backend_command_result_destroy(&saved, context.allocator)
		delete(document_id, context.allocator)
		return
	}
	bridge.backend_command_result_destroy(&saved, context.allocator)
	closed := bridge.backend_command(&app.backend, "close_document", document_id=document_id)
	handle_command_result(app, rt, &closed)
	bridge.backend_command_result_destroy(&closed, context.allocator)
	delete(document_id, context.allocator)
	deferred_actions_run(app, rt)
}

close_with_discard :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if editor_document_has_recoverable_preedit(app, app.close_document_id) {
		set_error(app, "Copy the committed IME recovery text with Edit > Copy before closing this document.")
		if rt != nil { alicorn.invalidate_root(rt, "Scratchpad blocked discard-and-close to preserve committed IME text") }
		return
	}
	if len(app.editor_edits) > 0 {
		if !deferred_action_enqueue(app, .Close_With_Discard) {
			set_error(app, "Could not queue discard-and-close behind pending edits.")
			alicorn.invalidate_root(rt, "Scratchpad discard-and-close queue is full")
		}
		return
	}
	response := bridge.backend_command(&app.backend, "close_document", document_id=app.close_document_id, discard=true)
	handle_command_result(app, rt, &response)
	bridge.backend_command_result_destroy(&response, context.allocator)
	deferred_actions_run(app, rt)
}

clear_close_prompt :: proc(app: ^App) {
	if app == nil { return }
	if len(app.close_document_id) > 0 { delete(app.close_document_id, context.allocator) }
	app.close_document_id = ""
}
