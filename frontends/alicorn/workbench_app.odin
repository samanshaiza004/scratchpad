package main

import "core:strings"
import alicorn "alicorn:runtime"

WORKBENCH_TAB_SEMANTIC_NAMESPACE :: u64(0x574F524B54414231)
WORKBENCH_GROUP_SEMANTIC_NAMESPACE :: u64(0x574F524B47525031)

workbench_view_semantic_id :: proc(view_id: View_ID) -> alicorn.Semantic_ID {
	return alicorn.Semantic_ID{namespace=WORKBENCH_TAB_SEMANTIC_NAMESPACE, value=u64(view_id)}
}

workbench_group_semantic_id :: proc(group_id: Pane_Group_ID) -> alicorn.Semantic_ID {
	return alicorn.Semantic_ID{namespace=WORKBENCH_GROUP_SEMANTIC_NAMESPACE, value=u64(group_id)}
}

app_workbench_window :: proc(app: ^App) -> ^Workbench_State {
	if app == nil || !app.workbench_model_ready { return nil }
	index := workbench_model_window_find(&app.workbench_model, app.primary_workbench_window_id)
	if index < 0 { return nil }
	return &app.workbench_model.windows[index]
}

app_workbench_group_count :: proc(app: ^App) -> int {
	window := app_workbench_window(app)
	return len(window.groups) if window != nil else 0
}

app_workbench_group_find_view_kind :: proc(app: ^App, kind: Workbench_View_Kind) -> (view_id: View_ID, group_id: Pane_Group_ID) {
	window := app_workbench_window(app)
	if window == nil { return }
	for view in window.views {
		if view.kind == kind { return view.id, view.group_id }
	}
	return
}

app_workbench_active_view :: proc(app: ^App) -> (view: Workbench_View, found: bool) {
	window := app_workbench_window(app)
	if window == nil { return }
	group_index := workbench_group_find(window, window.focused_group_id)
	if group_index < 0 { return }
	view_index := workbench_view_find(window, window.groups[group_index].active_view_id)
	if view_index < 0 { return }
	return window.views[view_index], true
}

app_workbench_active_content_kind :: proc(app: ^App) -> Workbench_Content_Kind {
	view, found := app_workbench_active_view(app)
	if !found { return .Document }
	switch view.kind {
	case .Editor: return .Document
	case .History: return .Git_History
	case .Diff: return .Git_Diff
	}
	return .Document
}

app_workbench_view_move_allowed :: proc(
	window: ^Workbench_State,
	source_view_id: View_ID,
	target_group_id: Pane_Group_ID,
) -> bool {
	if window == nil { return false }
	source_index := workbench_view_find(window, source_view_id)
	target_index := workbench_group_find(window, target_group_id)
	if source_index < 0 || target_index < 0 { return false }
	source := window.views[source_index]
	if source.group_id == target_group_id || source.kind != .Editor { return true }
	for view in window.views {
		if view.kind != .Editor { continue }
		if view.group_id == target_group_id { return false }
		if view.group_id == source.group_id && view.id != source_view_id { return false }
	}
	return true
}

app_workbench_view_kind_rendered :: proc(app: ^App, kind: Workbench_View_Kind) -> bool {
	window := app_workbench_window(app)
	if window == nil { return false }
	for group in window.groups {
		if app.workspace_search_mode && group.id == window.focused_group_id { continue }
		view_index := workbench_view_find(window, group.active_view_id)
		if view_index >= 0 && window.views[view_index].kind == kind { return true }
	}
	return false
}

app_workbench_editor_rendered :: proc(app: ^App) -> bool {
	window := app_workbench_window(app)
	if window == nil { return false }
	for group in window.groups {
		if app.workspace_search_mode && group.id == window.focused_group_id { continue }
		view_index := workbench_view_find(window, group.active_view_id)
		if view_index < 0 { continue }
		view := window.views[view_index]
		if view.kind == .Editor && view.resource.id == app.backend.state.active &&
		   !floating_window_contains(app, view.resource.id) {
			return true
		}
	}
	return false
}

app_workbench_view_scroll_capture_hidden :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil { return }
	if !app_workbench_view_kind_rendered(app, .History) {
		if app.git_history_list_node != 0 {
			state := alicorn.scroll_region_state(rt, app.git_history_list_node)
			if state.id != 0 {
				app.git_history_scroll_y = state.offset_y
				app.git_history_scroll_restore = true
			}
		}
		app.git_history_list_node = 0
		app.git_history_graph_node = 0
		app.git_history_graph_first = 0
		app.git_history_graph_last = 0
	}
	if !app_workbench_view_kind_rendered(app, .Diff) {
		if app.git_diff_scroll_owner != 0 {
			state := alicorn.scroll_region_state(rt, app.git_diff_scroll_owner)
			if state.id != 0 {
				app.git_diff_scroll_x = state.offset_x
				app.git_diff_scroll_y = state.offset_y
				app.git_diff_scroll_restore = true
			}
		}
		app.git_diff_scroll_owner = 0
	}
}

app_workbench_view_scroll_restore_after_frame :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil { return }
	if app.git_history_scroll_restore && app_workbench_view_kind_rendered(app, .History) && app.git_history_list_node != 0 {
		state := alicorn.scroll_region_state(rt, app.git_history_list_node)
		if state.id != 0 {
			_ = alicorn.scroll_region_set_offset(rt, app.git_history_list_node, app.git_history_scroll_y, "restore Git History view scroll")
			app.git_history_scroll_restore = false
		}
	}
	if app.git_diff_scroll_restore && app_workbench_view_kind_rendered(app, .Diff) && app.git_diff_scroll_owner != 0 {
		state := alicorn.scroll_region_state(rt, app.git_diff_scroll_owner)
		if state.id != 0 {
			_ = alicorn.scroll_region_set_offset_x(rt, app.git_diff_scroll_owner, app.git_diff_scroll_x, "restore Git Diff horizontal scroll")
			_ = alicorn.scroll_region_set_offset(rt, app.git_diff_scroll_owner, app.git_diff_scroll_y, "restore Git Diff vertical scroll")
			app.git_diff_scroll_restore = false
		}
	}
}

app_workbench_repository_identity :: proc(app: ^App) -> string {
	if app == nil { return "workspace" }
	if app.backend.state.git.root != "" { return app.backend.state.git.root }
	if app.backend.state.workspace_root != "" { return app.backend.state.workspace_root }
	if app.workspace_path != "" { return app.workspace_path }
	return "workspace"
}

app_workbench_view_ensure_kind :: proc(app: ^App, kind: Workbench_View_Kind) -> (view_id: View_ID, ok: bool) {
	window := app_workbench_window(app)
	if window == nil { return {}, false }
	if existing, _ := app_workbench_group_find_view_kind(app, kind); existing != 0 {
		if view_index := workbench_view_find(window, existing); view_index >= 0 {
			view := &window.views[view_index]
			identity := app_workbench_repository_identity(app)
			if view.resource.id != identity && !app_workbench_view_resource_rebind(app, existing, identity) {
				return {}, false
			}
		}
		return existing, true
	}
	resource_kind := Workbench_Resource_Kind.Repository
	if kind == .Diff { resource_kind = .Revision }
	group_id := window.focused_group_id
	if workbench_group_find(window, group_id) < 0 { group_id = app.primary_workbench_group_id }
	return workbench_model_view_add(
		&app.workbench_model,
		app.primary_workbench_window_id,
		group_id,
		kind,
		Workbench_Resource_Ref{kind=resource_kind, id=app_workbench_repository_identity(app)},
	)
}

app_workbench_activate_view :: proc(app: ^App, rt: ^alicorn.Runtime, view_id: View_ID) -> bool {
	window := app_workbench_window(app)
	if window == nil || rt == nil { return false }
	view_index := workbench_view_find(window, view_id)
	if view_index < 0 { return false }
	view := window.views[view_index]
	if !workbench_group_activate_view(window, view.group_id, view_id) { return false }
	app.workbench_pending_view_focus_id = view_id
	if view.kind == .Editor && app.backend.started && app.backend.state.active != view.resource.id {
		if !frame_deferred_action_schedule(app, .Select_Document, view.resource.id) {
			set_error(app, "Could not queue the document view selection until the current frame is complete.")
			return false
		}
	}
	return true
}

app_workbench_open_kind_beside :: proc(
	app: ^App,
	rt: ^alicorn.Runtime,
	kind: Workbench_View_Kind,
) -> bool {
	window := app_workbench_window(app)
	if window == nil || rt == nil { return false }
	source_group_id := window.focused_group_id
	if existing_id, existing_group_id := app_workbench_group_find_view_kind(app, kind); existing_id != 0 {
		if existing_group_id != source_group_id {
			activated := app_workbench_activate_view(app, rt, existing_id)
			if activated { alicorn.invalidate_root(rt, "Scratchpad focused an existing workbench pane") }
			return activated
		}
		group_view_count := 0
		for view in window.views { if view.group_id == source_group_id { group_view_count += 1 } }
		if group_view_count <= 1 {
			activated := app_workbench_activate_view(app, rt, existing_id)
			if activated { alicorn.invalidate_root(rt, "Scratchpad selected a workbench view") }
			return activated
		}
		_, moved := workbench_model_view_move_to_new_group(
			&app.workbench_model, app.primary_workbench_window_id, existing_id, .Horizontal, 0.55,
		)
		if moved {
			if !app_workbench_activate_view(app, rt, existing_id) { return false }
			alicorn.invalidate_root(rt, "Scratchpad moved a workbench view into a sibling pane")
		}
		return moved
	}
	opened_id, _, opened := workbench_model_group_split_add_view(
		&app.workbench_model,
		app.primary_workbench_window_id,
		source_group_id,
		kind,
		Workbench_Resource_Ref{
			kind=Workbench_Resource_Kind.Repository if kind == .History else .Revision,
			id=app_workbench_repository_identity(app),
		},
		.Horizontal,
		0.55,
	)
	if opened {
		if !app_workbench_activate_view(app, rt, opened_id) { return false }
		alicorn.invalidate_root(rt, "Scratchpad opened a workbench view in a sibling pane")
	}
	return opened
}

app_workbench_view_close_pending_apply :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil || app.workbench_pending_close_view_id == 0 { return }
	view_id := app.workbench_pending_close_view_id
	app.workbench_pending_close_view_id = {}
	window := app_workbench_window(app)
	if window == nil { return }
	view_index := workbench_view_find(window, view_id)
	if view_index < 0 || window.views[view_index].kind == .Editor { return }
	_ = workbench_model_view_close(&app.workbench_model, view_id)
	if active, found := app_workbench_active_view(app); found {
		app.workbench_pending_view_focus_id = active.id
	}
	alicorn.invalidate_root(rt, "Scratchpad closed a workbench view")
}

app_workbench_view_focus_after_frame :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil || app.workbench_pending_view_focus_id == 0 { return }
	window := app_workbench_window(app)
	if window == nil { app.workbench_pending_view_focus_id = {}; return }
	index := workbench_view_find(window, app.workbench_pending_view_focus_id)
	if index < 0 { app.workbench_pending_view_focus_id = {}; return }
	view := window.views[index]
	group_index := workbench_group_find(window, view.group_id)
	if group_index < 0 || window.groups[group_index].active_view_id != view.id {
		app.workbench_pending_view_focus_id = {}
		return
	}
	switch view.kind {
	case .Editor:
		if app.backend.state.active != view.resource.id { return }
		app.editor_focus_pending = true
		app.workbench_pending_view_focus_id = {}
	case .History:
		owner := app.git_history_list_node
		if owner == 0 { owner = app.git_history_filter_node }
		if owner != 0 && alicorn.focus(rt, owner) { app.workbench_pending_view_focus_id = {} }
	case .Diff:
		if app.git_diff_scroll_owner != 0 && alicorn.focus(rt, app.git_diff_scroll_owner) {
			app.workbench_pending_view_focus_id = {}
		}
	}
}

app_workbench_view_resource_rebind :: proc(app: ^App, view_id: View_ID, resource_id: string, instance_id: u64 = 0) -> bool {
	if app == nil || resource_id == "" { return false }
	window := app_workbench_window(app)
	if window == nil { return false }
	index := workbench_view_find(window, view_id)
	if index < 0 { return false }
	owned_id, clone_error := strings.clone(resource_id, window.allocator)
	if clone_error != nil { return false }
	view := &window.views[index]
	resource_changed := view.resource.id != resource_id ||
		(instance_id != 0 && view.resource.instance_id != instance_id)
	if !resource_changed {
		delete(owned_id, window.allocator)
		return true
	}
	delete(view.resource.id, window.allocator)
	view.resource.id = owned_id
	if instance_id != 0 { view.resource.instance_id = instance_id }
	view.lifecycle_generation += 1
	if view.lifecycle_generation == 0 { view.lifecycle_generation = 1 }
	return true
}
