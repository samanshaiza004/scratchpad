package main

import "core:strings"
import alicorn "alicorn:runtime"
import bridge "./bridge"

Deferred_Action_Kind :: enum {
	Action,
	Select_Document,
	Close_Document,
	Open_Path,
	Workspace_Mutation,
	Close_After_Save,
	Close_With_Discard,
	Cancel_Close_Prompt,
	Save_As_Path,
	Conflict_Reload,
	Conflict_Keep_Mine,
}

Deferred_Action :: struct {
	kind:        Deferred_Action_Kind,
	value:       string,
	path:        string,
	relative_path: string,
	name:        string,
	disposition: string,
	workspace_root: string,
	workspace_mutation_kind: Workspace_Mutation_Kind,
	source_is_dir: bool,
	discard:     bool,
}

MAX_DEFERRED_ACTIONS :: 64
deferred_action_enqueue :: proc(
	app: ^App,
	kind: Deferred_Action_Kind,
	value: string = "",
	path: string = "",
	disposition: string = "",
	relative_path: string = "",
	name: string = "",
	workspace_mutation_kind: Workspace_Mutation_Kind = .None,
	source_is_dir := false,
	discard := false,
	workspace_root := "",
) -> bool {
	if app == nil || len(app.deferred_actions) >= MAX_DEFERRED_ACTIONS { return false }
	action := Deferred_Action{kind=kind}
	if len(value) > 0 {
		value_copy, err := strings.clone(value, context.allocator)
		if err != nil { deferred_action_destroy(&action); return false }
		action.value = value_copy
	}
	if len(path) > 0 {
		path_copy, err := strings.clone(path, context.allocator)
		if err != nil { deferred_action_destroy(&action); return false }
		action.path = path_copy
	}
	if len(relative_path) > 0 {
		path_copy, err := strings.clone(relative_path, context.allocator)
		if err != nil { deferred_action_destroy(&action); return false }
		action.relative_path = path_copy
	}
	if len(name) > 0 {
		name_copy, err := strings.clone(name, context.allocator)
		if err != nil { deferred_action_destroy(&action); return false }
		action.name = name_copy
	}
	if len(workspace_root) > 0 {
		root_copy, err := strings.clone(workspace_root, context.allocator)
		if err != nil { deferred_action_destroy(&action); return false }
		action.workspace_root = root_copy
	}
	action.workspace_mutation_kind = workspace_mutation_kind
	action.source_is_dir = source_is_dir
	action.discard = discard
	if len(disposition) > 0 {
		disposition_copy, err := strings.clone(disposition, context.allocator)
		if err != nil { deferred_action_destroy(&action); return false }
		action.disposition = disposition_copy
	}
	append(&app.deferred_actions, action)
	return true
}

deferred_action_destroy :: proc(action: ^Deferred_Action) {
	if action == nil { return }
	if len(action.value) > 0 { delete(action.value, context.allocator) }
	if len(action.path) > 0 { delete(action.path, context.allocator) }
	if len(action.relative_path) > 0 { delete(action.relative_path, context.allocator) }
	if len(action.name) > 0 { delete(action.name, context.allocator) }
	if len(action.disposition) > 0 { delete(action.disposition, context.allocator) }
	if len(action.workspace_root) > 0 { delete(action.workspace_root, context.allocator) }
	action^ = Deferred_Action{}
}

frame_deferred_action_schedule :: proc(app: ^App, kind: Deferred_Action_Kind, value: string = "") -> bool {
	if app == nil || app.frame_deferred_action_pending { return false }
	action := Deferred_Action{kind=kind}
	if len(value) > 0 {
		value_copy, err := strings.clone(value, context.allocator)
		if err != nil { return false }
		action.value = value_copy
	}
	app.frame_deferred_action = action
	app.frame_deferred_action_pending = true
	return true
}

frame_deferred_action_run :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || !app.frame_deferred_action_pending { return }
	action := app.frame_deferred_action
	app.frame_deferred_action = Deferred_Action{}
	app.frame_deferred_action_pending = false
	#partial switch action.kind {
	case .Select_Document:
		select_document(app, rt, action.value)
	case .Close_Document:
		request_close_document(app, rt, action.value)
	case .Open_Path:
		quick_open_open_path(app, rt, action.value)
	case .Save_As_Path:
		save_as_to_path(app, rt, action.value, action.path)
	case .Close_After_Save:
		close_after_save(app, rt)
	case .Close_With_Discard:
		close_with_discard(app, rt)
	case .Cancel_Close_Prompt:
		clear_close_prompt(app)
		deferred_actions_run(app, rt)
		alicorn.invalidate_root(rt, "dirty close cancelled")
		case .Action:
			application_menu_command(rawptr(app), rt, action_id_for(action.value))
	case:
		set_error(app, "Scratchpad received an unsupported deferred frame action.")
		alicorn.invalidate_root(rt, "Scratchpad rejected an unsupported deferred frame action")
	}
	deferred_action_destroy(&action)
}

deferred_actions_clear :: proc(app: ^App) {
	if app == nil { return }
	for index := len(app.deferred_actions)-1; index >= 0; index -= 1 {
		deferred_action_destroy(&app.deferred_actions[index])
	}
	clear(&app.deferred_actions)
}

deferred_actions_run :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil || !app.backend.started || len(app.editor_edits) > 0 || app.dialog_action != "" || app.save_as_confirmation_open {
		return
	}
	if app.close_document_id != "" {
		// A close decision owns the modal until Save & Close or Discard is
		// chosen. Let that decision pass queued work so it cannot deadlock
		// behind actions that the modal itself prevents from running.
		close_action_index := -1
		for action, index in app.deferred_actions {
			if action.kind == .Close_After_Save || action.kind == .Close_With_Discard {
				close_action_index = index
				break
			}
		}
		if close_action_index < 0 { return }
		if close_action_index > 0 {
			close_action := app.deferred_actions[close_action_index]
			for index := close_action_index; index > 0; index -= 1 {
				app.deferred_actions[index] = app.deferred_actions[index-1]
			}
			app.deferred_actions[0] = close_action
		}
	}
	for len(app.deferred_actions) > 0 {
		action := app.deferred_actions[0]
		ordered_remove(&app.deferred_actions, 0)
		switch action.kind {
		case .Action:
			dispatch_action(app, rt, action.value)
		case .Select_Document:
			select_document(app, rt, action.value)
		case .Close_Document:
			request_close_document(app, rt, action.value)
		case .Open_Path:
			if action.disposition != "" {
				response := bridge.backend_command(&app.backend, "open_path", path=action.path, disposition=action.disposition)
				handle_command_result(app, rt, &response)
				bridge.backend_command_result_destroy(&response, context.allocator)
			} else {
				response := bridge.backend_command(&app.backend, "open_path", path=action.path)
				handle_command_result(app, rt, &response)
				bridge.backend_command_result_destroy(&response, context.allocator)
			}
		case .Save_As_Path:
			save_as_to_path(app, rt, action.value, action.path)
		case .Conflict_Reload:
			editor_resolve_conflict_now(app, rt, action.value, false)
		case .Conflict_Keep_Mine:
			editor_resolve_conflict_now(app, rt, action.value, true)
		case .Workspace_Mutation:
			app.workspace_mutation_queued = false
			workspace_mutation_execute(
				app,
				rt,
				action.workspace_mutation_kind,
				action.path,
				action.name,
				action.relative_path,
				action.source_is_dir,
				action.discard,
				action.workspace_root,
			)
		case .Close_After_Save:
			close_after_save(app, rt)
		case .Close_With_Discard:
			close_with_discard(app, rt)
		case .Cancel_Close_Prompt:
			clear_close_prompt(app)
			alicorn.invalidate_root(rt, "dirty close cancelled")
		}
		deferred_action_destroy(&action)
		if app.dialog_action != "" || app.close_document_id != "" || app.save_as_confirmation_open || app.workspace_mutation_kind != .None { break }
	}
}
