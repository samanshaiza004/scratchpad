package main

import "core:strings"
import alicorn "alicorn:runtime"
Workspace_Tree_Row_Target :: struct {
	node: alicorn.Node_ID,
	path: string,
	is_dir: bool,
	index: int,
}

workspace_context_menu_clear :: proc(app: ^App) {
	if app == nil { return }
	if len(app.workspace_context_path) > 0 { delete(app.workspace_context_path, context.allocator) }
	app.workspace_context_path = ""
	app.workspace_context_is_dir = false
}

workspace_context_menu_set_target :: proc(app: ^App, rt: ^alicorn.Runtime, target: Workspace_Tree_Row_Target, anchor: alicorn.Rect) -> bool {
	if app == nil || rt == nil || target.node == 0 || app.tree_scroll_owner == 0 { return false }
	row := Tree_Row{path=target.path, is_dir=target.is_dir}
	tree_set_focused_row(app, rt, row, target.index)
	workspace_context_menu_clear(app)
	path_copy, clone_error := strings.clone(target.path, context.allocator)
	if clone_error != nil {
		set_error(app, "Could not retain the workspace item for its context menu.")
		return false
	}
	app.workspace_context_path = path_copy
	app.workspace_context_is_dir = target.is_dir
	if !alicorn.context_menu_open(rt, anchor, app.tree_scroll_owner) {
		workspace_context_menu_clear(app)
		return false
	}
	return true
}

workspace_context_menu_target_for_node :: proc(app: ^App, rt: ^alicorn.Runtime, node: alicorn.Node_ID) -> (target: Workspace_Tree_Row_Target, found: bool) {
	if app == nil || rt == nil || node == 0 { return }
	retained, retained_found := rt.nodes[node]
	if !retained_found || !strings.has_prefix(retained.key, "workspace-entry:") { return }
	path := retained.key[len("workspace-entry:"):]
	rows := make([dynamic]Tree_Row, 0, allocator=context.temp_allocator)
	defer delete(rows)
	tree_flatten_directory(app, "", 0, &rows)
	for row, index in rows {
		if row.path == path {
			return Workspace_Tree_Row_Target{node=node, path=row.path, is_dir=row.is_dir, index=index}, true
		}
	}
	return
}

workspace_context_menu_open_node :: proc(app: ^App, rt: ^alicorn.Runtime, node: alicorn.Node_ID, anchor: alicorn.Rect) -> bool {
	target, found := workspace_context_menu_target_for_node(app, rt, node)
	if !found { return false }
	row, row_found := rt.nodes[node]
	if !row_found || !row.active { return false }
	return workspace_context_menu_set_target(app, rt, target, anchor)
}

workspace_context_menu_pointer :: proc(app: ^App, rt: ^alicorn.Runtime, event: alicorn.Pointer_Event, target_node: alicorn.Node_ID) -> bool {
	if event.kind != .Down || event.button != alicorn.POINTER_BUTTON_SECONDARY { return false }
	if !workspace_context_menu_open_node(app, rt, target_node, alicorn.Rect{event.x, event.y, 0, 0}) { return false }
	return true
}

workspace_context_menu_open_focused :: proc(app: ^App, rt: ^alicorn.Runtime) -> bool {
	if app == nil || rt == nil || app.tree_scroll_owner == 0 || rt.focused != app.tree_scroll_owner || app.tree_focused_path == "" {
		return false
	}
	semantic := alicorn.semantic_focus_state(rt)
	if semantic.realized_node == 0 { return false }
	target, found := workspace_context_menu_target_for_node(app, rt, semantic.realized_node)
	if !found || target.path != app.tree_focused_path || target.is_dir != app.tree_focused_is_dir { return false }
	row, row_found := rt.nodes[semantic.realized_node]
	if !row_found { return false }
	return workspace_context_menu_open_node(app, rt, semantic.realized_node, row.bounds)
}

workspace_context_menu_build :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime) {
	if app == nil || ui == nil || rt == nil { return }
	if !alicorn.context_menu_is_open(rt) {
		workspace_context_menu_clear(app)
		return
	}
	if app.workspace_context_path == "" || !app.backend.state.has_workspace {
		alicorn.context_menu_close(rt)
		workspace_context_menu_clear(app)
		return
	}
	if !alicorn.context_menu_begin(ui, alicorn.key_string("scratchpad-workspace-context-menu")) { return }
	alicorn.context_menu_item(ui, action_id_for(ACTION_WORKSPACE_RENAME), "Rename", action_enabled(&app.backend.state, ACTION_WORKSPACE_RENAME))
	alicorn.context_menu_item(ui, action_id_for(ACTION_WORKSPACE_MOVE), "Move…", action_enabled(&app.backend.state, ACTION_WORKSPACE_MOVE))
	alicorn.context_menu_separator(ui)
	alicorn.context_menu_item(ui, action_id_for(ACTION_WORKSPACE_TRASH), "Move to Trash", action_enabled(&app.backend.state, ACTION_WORKSPACE_TRASH))
	action := alicorn.context_menu_end(ui)
	if action == 0 { return }
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
	if app.quick_open_open {
		_ = quick_open_pointer(app, rt, event, target)
		return
	}
	if app.command_palette_open {
		_ = command_palette_pointer(app, rt, event, target)
		return
	}
	if workspace_context_menu_pointer(app, rt, event, target) { return }
	editor_pointer(state, rt, event, target)
}
