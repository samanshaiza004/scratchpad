package main

import "core:strings"
import alicorn "alicorn:runtime"

Workspace_Context_Target :: enum {
	None,
	Item,
	Workspace_Root,
}

Workspace_Tree_Row_Target :: struct {
	node: alicorn.Node_ID,
	path: string,
	is_dir: bool,
	index: int,
}

workspace_context_menu_clear :: proc(app: ^App) {
	if app == nil { return }
	app.workspace_context_target = .None
	if len(app.workspace_context_path) > 0 { delete(app.workspace_context_path, context.allocator) }
	app.workspace_context_path = ""
	app.workspace_context_is_dir = false
}

workspace_context_menu_set_target :: proc(app: ^App, rt: ^alicorn.Runtime, target: Workspace_Tree_Row_Target, anchor: alicorn.Rect, menu_already_open := false) -> bool {
	if app == nil || rt == nil || app.tree_scroll_owner == 0 { return false }
	row := Tree_Row{path=target.path, is_dir=target.is_dir}
	tree_set_focused_row(app, rt, row, target.index)
	workspace_context_menu_clear(app)
	path_copy, clone_error := strings.clone(target.path, context.allocator)
	if clone_error != nil {
		set_error(app, "Could not retain the workspace item for its context menu.")
		if menu_already_open { alicorn.context_menu_close(rt) }
		return false
	}
	app.workspace_context_path = path_copy
	app.workspace_context_is_dir = target.is_dir
	app.workspace_context_target = .Item
	if !menu_already_open && !alicorn.context_menu_open(rt, anchor, app.tree_scroll_owner) {
		workspace_context_menu_clear(app)
		return false
	}
	return true
}

workspace_context_menu_set_root_target :: proc(app: ^App, rt: ^alicorn.Runtime, anchor: alicorn.Rect) -> bool {
	if app == nil || rt == nil || app.tree_scroll_owner == 0 || !app.backend.state.has_workspace { return false }
	workspace_context_menu_clear(app)
	app.workspace_context_is_dir = true
	app.workspace_context_target = .Workspace_Root
	if !alicorn.context_menu_open(rt, anchor, alicorn.focused_node(rt)) {
		workspace_context_menu_clear(app)
		return false
	}
	return true
}

workspace_context_menu_pointer :: proc(app: ^App, rt: ^alicorn.Runtime, event: alicorn.Pointer_Event, target_node: alicorn.Node_ID) -> bool {
	if event.kind != .Down || event.button != alicorn.POINTER_BUTTON_SECONDARY { return false }
	if app == nil || rt == nil || app.tree_scroll_owner == 0 || !app.backend.state.has_workspace { return false }
	if target_node != 0 {
		if target, found := alicorn.node_info(rt, target_node); found &&
		   target.semantic_id.namespace == TREE_SEMANTIC_NAMESPACE {
			return false
		}
	}
	viewport := alicorn.scroll_region_state(rt, app.tree_scroll_owner).viewport_bounds
	inside_tree := viewport.w > 0 && viewport.h > 0 && event.x >= viewport.x && event.x < viewport.x+viewport.w &&
	               event.y >= viewport.y && event.y < viewport.y+viewport.h
	if !inside_tree { return false }
	return workspace_context_menu_set_root_target(app, rt, alicorn.Rect{event.x, event.y, 0, 0})
}

workspace_context_menu_open_focused :: proc(app: ^App, rt: ^alicorn.Runtime) -> bool {
	return workspace_tree_open_context_menu_focused(app, rt)
}

workspace_context_menu_item_is_current :: proc(app: ^App) -> bool {
	if app == nil || app.workspace_context_target != .Item { return false }
	rows := make([dynamic]Tree_Row, 0, allocator=context.temp_allocator)
	defer delete(rows)
	tree_flatten_directory(app, "", 0, &rows)
	for row in rows {
		if row.path == app.workspace_context_path && row.is_dir == app.workspace_context_is_dir { return true }
	}
	return false
}

workspace_context_menu_build :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime) {
	if app == nil || ui == nil || rt == nil { return }
	if app.pinned.context_menu_open { return }
	if app.workspace_search_context_menu_open {
		if !alicorn.context_menu_is_open(rt) {
			app.workspace_search_context_menu_open = false
			app.workspace_search_context_generation = 0
			app.workspace_search_context_projection_key = 0
			return
		}
		index := workspace_search_result_index_for_key(
			app,
			app.workspace_search_context_generation,
			app.workspace_search_context_projection_key,
		)
		if index < 0 {
			alicorn.context_menu_close(rt)
			app.workspace_search_context_menu_open = false
			app.workspace_search_context_generation = 0
			app.workspace_search_context_projection_key = 0
			return
		}
		if !alicorn.context_menu_begin(ui, alicorn.key_string("scratchpad-workspace-search-context-menu")) { return }
		can_go_to_source := true
		if app.workspace_search_edit_active {
			can_go_to_source = !workspace_search_edit_has_pending_intents(app)
			if app.workspace_search_edit_node != 0 {
				interaction, found := alicorn.text_field_interaction(rt, app.workspace_search_edit_node)
				if found && interaction.composition_active { can_go_to_source = false }
			}
		}
		alicorn.context_menu_item(ui, action_id_for(ACTION_WORKSPACE_SEARCH_GO_TO_SOURCE), "Go to source", can_go_to_source)
		action := alicorn.context_menu_end(ui)
		if action == action_id_for(ACTION_WORKSPACE_SEARCH_GO_TO_SOURCE) && can_go_to_source {
			app.workspace_search_context_menu_open = false
			_ = workspace_search_go_to_source(app, rt, index)
		}
		return
	}
	if !alicorn.context_menu_is_open(rt) {
		workspace_context_menu_clear(app)
		return
	}
	if app.workspace_context_target == .None || !app.backend.state.has_workspace ||
	   (app.workspace_context_target == .Item && !workspace_context_menu_item_is_current(app)) {
		alicorn.context_menu_close(rt)
		workspace_context_menu_clear(app)
		return
	}
	if !alicorn.context_menu_begin(ui, alicorn.key_string("scratchpad-workspace-context-menu")) { return }
	if app.workspace_context_target == .Workspace_Root {
		can_create := app.backend.started && app.backend.state.has_workspace
		alicorn.context_menu_item(ui, action_id_for(ACTION_WORKSPACE_NEW_FILE), "New File…", can_create)
		alicorn.context_menu_item(ui, action_id_for(ACTION_WORKSPACE_NEW_FOLDER), "New Folder…", can_create)
	} else {
		alicorn.context_menu_item(ui, action_id_for(ACTION_WORKSPACE_RENAME), "Rename", action_enabled(&app.backend.state, ACTION_WORKSPACE_RENAME))
		alicorn.context_menu_item(ui, action_id_for(ACTION_WORKSPACE_MOVE), "Move…", action_enabled(&app.backend.state, ACTION_WORKSPACE_MOVE))
		alicorn.context_menu_separator(ui)
		alicorn.context_menu_item(ui, action_id_for(ACTION_WORKSPACE_TRASH), "Move to Trash", action_enabled(&app.backend.state, ACTION_WORKSPACE_TRASH))
	}
	action := alicorn.context_menu_end(ui)
	if action == 0 { return }
	if app.workspace_context_target == .Workspace_Root {
		if action == action_id_for(ACTION_WORKSPACE_NEW_FILE) {
			dispatch_action(app, rt, ACTION_WORKSPACE_NEW_FILE)
		} else if action == action_id_for(ACTION_WORKSPACE_NEW_FOLDER) {
			dispatch_action(app, rt, ACTION_WORKSPACE_NEW_FOLDER)
		}
		workspace_context_menu_clear(app)
		return
	}
	kind := Workspace_Mutation_Kind.None
	if action == action_id_for(ACTION_WORKSPACE_RENAME) { kind = .Rename }
	if action == action_id_for(ACTION_WORKSPACE_MOVE) { kind = .Move }
	if action == action_id_for(ACTION_WORKSPACE_TRASH) { kind = .Trash }
	if kind != .None {
		workspace_mutation_begin(app, rt, kind, app.workspace_context_path, app.workspace_context_is_dir)
		if kind == .Rename {
			workspace_mutation_set_name(app, tree_basename(app.workspace_context_path))
		}
	}
	workspace_context_menu_clear(app)
}

application_pointer :: proc(state: rawptr, rt: ^alicorn.Runtime, event: alicorn.Pointer_Event, target: alicorn.Node_ID) {
	app := cast(^App)state
	if app.editor_font_picker_open {
		_ = scratchpad_editor_font_picker_pointer(app, rt, event, target)
		return
	}
	if app.quick_open_open {
		_ = quick_open_pointer(app, rt, event, target)
		return
	}
	if app.symbol_picker_open {
		_ = symbol_picker_pointer(app, rt, event, target)
		return
	}
	if app.command_palette_open {
		_ = command_palette_pointer(app, rt, event, target)
		return
	}
	if pinned_context_pointer(app,rt,event) { return }
	if workspace_search_pointer(app, rt, event, target) { return }
	if workspace_tree_pointer(app, rt, event, target) { return }
	if workspace_context_menu_pointer(app, rt, event, target) { return }
	workbench_group_activate_from_pointer(app, rt, event)
	editor_pointer(state, rt, event, target)
}
