package main

import "core:strings"
import "core:testing"
import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"
import bridge "./bridge"

Scratchpad_Drag_Kind :: enum { None, Tabs, Workspace }

SCRATCHPAD_DRAG_TABS      :: alicorn.Drag_Type(0x5343524150544142)
SCRATCHPAD_DRAG_WORKSPACE :: alicorn.Drag_Type(0x5343524154434850)
TAB_SEMANTIC_NAMESPACE   :: u64(0x5343524150544142)

TAB_REORDER_MAX_ITEMS :: 4096

document_tab_semantic_id :: proc(document_id: string) -> alicorn.Semantic_ID {
	hash: u64 = 14_695_981_039_346_656_037
	for character in document_id { hash = (hash ~ u64(character)) * 1_099_511_628_211 }
	if hash == 0 { hash = 1 }
	return alicorn.Semantic_ID{namespace=TAB_SEMANTIC_NAMESPACE, value=hash}
}

application_drag :: proc(state: rawptr, rt: ^alicorn.Runtime, event: alicorn.Drag_Event) {
	app := cast(^App)state
	if app == nil || rt == nil { return }
	switch event.kind {
	case .Started:
		workspace_drag_clear(app, reset_motion=true, snap_motion=true)
		if !workspace_drag_capture_source(app, event) {
			set_error(app, "The dragged item is no longer available.")
			alicorn.invalidate_root(rt, "Scratchpad could not resolve the stable drag source")
		} else if app.workspace_drag_kind == .Tabs {
			workspace_drag_target_set(app, event.target, event.position)
			alicorn.invalidate_root(rt, "Scratchpad tab drag started")
		}
	case .Dropped:
		workspace_drag_apply_drop(app, rt, event)
		workspace_drag_clear(app, reset_motion=true, snap_motion=true)
		alicorn.invalidate_root(rt, "Scratchpad tab drag completed")
	case .Cancelled:
		if app.workspace_drag_kind == .Tabs && app.workspace_drag_source_document_id != "" &&
		   floating_window_drag_detached(rt, event) {
			_ = floating_window_open(app, rt, app.workspace_drag_source_document_id)
		}
		workspace_drag_clear(app, reset_motion=true, snap_motion=true)
		alicorn.invalidate_root(rt, "Scratchpad drag canceled")
	case .Target_Changed:
		if app.workspace_drag_kind == .Tabs && event.drag_type == SCRATCHPAD_DRAG_TABS {
			previous_target := app.workspace_drag_target
			previous_position := app.workspace_drag_position
			workspace_drag_target_set(app, event.target, event.position)
			if previous_target != app.workspace_drag_target || previous_position != app.workspace_drag_position {
				alicorn.invalidate_root(rt, "Scratchpad tab insertion slot changed")
			}
		}
	}
}

workspace_drag_target_set :: proc(app: ^App, target: alicorn.Semantic_ID, position: alicorn.Drop_Position) {
	if app == nil { return }
	valid_tab_target := (target.namespace == WORKBENCH_TAB_SEMANTIC_NAMESPACE || target.namespace == TAB_SEMANTIC_NAMESPACE) &&
		(position == .Before || position == .After)
	valid_group_target := target.namespace == WORKBENCH_GROUP_SEMANTIC_NAMESPACE && position == .On
	if !valid_tab_target && !valid_group_target {
		app.workspace_drag_target = {}
		app.workspace_drag_position = .None
		return
	}
	app.workspace_drag_target = target
	app.workspace_drag_position = position
}

workspace_drag_capture_source :: proc(app: ^App, event: alicorn.Drag_Event) -> bool {
	if app == nil || !app.backend.started { return false }
	switch event.drag_type {
	case SCRATCHPAD_DRAG_TABS:
		window := app_workbench_window(app)
		if window == nil { return false }
		view_id: View_ID
		view_index := -1
		if event.source.namespace == WORKBENCH_TAB_SEMANTIC_NAMESPACE {
			view_id = View_ID(event.source.value)
			view_index = workbench_view_find(window, view_id)
		} else if event.source.namespace == TAB_SEMANTIC_NAMESPACE {
			for view, index in window.views {
				if view.kind == .Editor && document_tab_semantic_id(view.resource.id) == event.source {
					view_id, view_index = view.id, index
					break
				}
			}
		} else {
			return false
		}
		if view_index < 0 { return false }
		app.workspace_drag_kind = .Tabs
		app.workspace_drag_source_view_id = view_id
		if window.views[view_index].kind == .Editor {
			copy, err := strings.clone(window.views[view_index].resource.id, context.allocator)
			if err != nil { app.workspace_drag_source_view_id = {}; return false }
			app.workspace_drag_source_document_id = copy
		}
		return true
	case SCRATCHPAD_DRAG_WORKSPACE:
		rows := make([dynamic]Tree_Row, 0, allocator=context.temp_allocator)
		defer delete(rows)
		tree_flatten_directory(app, "", 0, &rows)
		for row in rows {
			if tree_semantic_id(row.path, row.is_dir) != event.source { continue }
			copy, err := strings.clone(row.path, context.allocator)
			if err != nil { return false }
			app.workspace_drag_kind = .Workspace
			app.workspace_drag_source_path = copy
			app.workspace_drag_source_is_dir = row.is_dir
			return true
		}
	}
	return false
}

workspace_drag_apply_drop :: proc(app: ^App, rt: ^alicorn.Runtime, event: alicorn.Drag_Event) {
	if app == nil || rt == nil || !app.backend.started { return }
	switch app.workspace_drag_kind {
	case .Tabs:
		if event.drag_type != SCRATCHPAD_DRAG_TABS || app.workspace_drag_source_view_id == 0 { return }
		window := app_workbench_window(app)
		if window == nil { return }
		changed := false
		source_was_active := false
		if source_index := workbench_view_find(window, app.workspace_drag_source_view_id); source_index >= 0 {
			if source_group_index := workbench_group_find(window, window.views[source_index].group_id); source_group_index >= 0 {
				source_was_active = window.groups[source_group_index].active_view_id == app.workspace_drag_source_view_id
			}
		}
		reorder_group_id := Pane_Group_ID{}
		persist_document_order := false
		if event.target.namespace == WORKBENCH_GROUP_SEMANTIC_NAMESPACE && event.position == .On {
			group_id := Pane_Group_ID(event.target.value)
			if app_workbench_view_move_allowed(window, app.workspace_drag_source_view_id, group_id) {
				changed = workbench_model_view_move(
					&app.workbench_model, app.workspace_drag_source_view_id,
					app.primary_workbench_window_id, group_id,
				)
			}
		} else if (event.target.namespace == WORKBENCH_TAB_SEMANTIC_NAMESPACE ||
		          event.target.namespace == TAB_SEMANTIC_NAMESPACE) &&
		         (event.position == .Before || event.position == .After) {
			target_view_id := View_ID(event.target.value)
			if event.target.namespace == TAB_SEMANTIC_NAMESPACE {
				for view in window.views {
					if view.kind == .Editor && document_tab_semantic_id(view.resource.id) == event.target {
						target_view_id = view.id
						break
					}
				}
			}
			if target_index := workbench_view_find(window, target_view_id); target_index >= 0 {
				target_group_id := window.views[target_index].group_id
				source_index := workbench_view_find(window, app.workspace_drag_source_view_id)
				if source_index >= 0 && window.views[source_index].group_id == target_group_id &&
				   window.views[source_index].kind == .Editor && window.views[target_index].kind == .Editor {
					reorder_group_id = target_group_id
					persist_document_order = true
				}
				if app_workbench_view_move_allowed(window, app.workspace_drag_source_view_id, target_group_id) {
					changed = workbench_model_view_drop_relative(
						&app.workbench_model, app.primary_workbench_window_id,
						app.workspace_drag_source_view_id, target_view_id,
						event.position == .After,
					)
				}
			}
		}
		if changed {
			if source_was_active { app.workbench_pending_view_focus_id = app.workspace_drag_source_view_id }
			if persist_document_order {
				workbench_persist_editor_tab_order(app, rt, reorder_group_id)
			}
			alicorn.invalidate_root(rt, "Scratchpad moved a workbench view")
		}
	case .Workspace:
		if event.drag_type != SCRATCHPAD_DRAG_WORKSPACE { return }
		target_path, found := workspace_drag_target_path(app, event.target)
		if !found { return }
		defer delete(target_path, context.allocator)
		destination, should_move := workspace_drag_move_destination(
			app.workspace_drag_source_path,
			target_path,
			app.workspace_drag_source_is_dir,
			tree_preferred_separator(app),
		)
		if !should_move { return }
		// A prior refused drop may have left its reason in the workbench banner.
		// Clear it before this attempt so a successful tree refresh is not
		// mistaken for a failed one and a new refusal can report its own reason.
		set_error(app, "")
		workspace_mutation_execute(
			app, rt, .Move,
			app.workspace_drag_source_path, "", destination,
			app.workspace_drag_source_is_dir, false,
			app.backend.state.workspace_root,
		)
	case .None:
	}
}

workbench_persist_editor_tab_order :: proc(app: ^App, rt: ^alicorn.Runtime, group_id: Pane_Group_ID) {
	if app == nil || rt == nil || !app.backend.started { return }
	window := app_workbench_window(app)
	if window == nil { return }
	ordered_views := workbench_group_views_ordered(window, group_id)
	defer delete(ordered_views)
	if len(ordered_views) == 0 { return }
	for view_id in ordered_views {
		index := workbench_view_find(window, view_id)
		if index < 0 || window.views[index].kind != .Editor { return }
	}
	visible_indices := floating_window_tab_document_indices(
		app.backend.state.documents,
		app.floating_window.document_id if app.floating_window != nil else "",
		context.temp_allocator,
	)
	defer delete(visible_indices)
	if len(visible_indices) != len(ordered_views) { return }
	order := make([dynamic]string, 0, len(app.backend.state.documents), allocator=context.temp_allocator)
	defer delete(order)
	for document in app.backend.state.documents { append(&order, document.id) }
	for view_id, index in ordered_views {
		view_index := workbench_view_find(window, view_id)
		if view_index < 0 || index >= len(visible_indices) { return }
		order[visible_indices[index]] = window.views[view_index].resource.id
	}
	response := bridge.backend_command(&app.backend, "reorder_documents", document_order=order[:])
	handle_command_result(app, rt, &response)
	bridge.backend_command_result_destroy(&response, context.allocator)
}

workspace_drag_clear :: proc(app: ^App, reset_motion := false, snap_motion := false) {
	if app == nil { return }
	if len(app.workspace_drag_source_document_id) > 0 { delete(app.workspace_drag_source_document_id, context.allocator) }
	if len(app.workspace_drag_source_path) > 0 { delete(app.workspace_drag_source_path, context.allocator) }
	app.workspace_drag_source_document_id = ""
	app.workspace_drag_source_view_id = {}
	app.workspace_drag_source_path = ""
	app.workspace_drag_source_is_dir = false
	app.workspace_drag_kind = .None
	app.workspace_drag_target = {}
	app.workspace_drag_position = .None
	app.document_tab_reorder_motion_signature = 0
	if reset_motion && app.document_tab_reorder_motion_cleanup_needed {
		app.workspace_drag_motion_reset_pending = true
		app.workspace_drag_motion_reset_snap = snap_motion
		app.document_tab_reorder_motion_cleanup_needed = false
	}
}

workspace_drag_target_path :: proc(app: ^App, target: alicorn.Semantic_ID) -> (path: string, found: bool) {
	if app == nil { return }
	if target == tree_semantic_id("", true) { return "", true }
	rows := make([dynamic]Tree_Row, 0, allocator=context.temp_allocator)
	defer delete(rows)
	tree_flatten_directory(app, "", 0, &rows)
	for row in rows {
		if row.is_dir && tree_semantic_id(row.path, true) == target {
			path_copy, err := strings.clone(row.path, context.allocator)
			return path_copy, err == nil
		}
	}
	return
}

workspace_drag_move_destination :: proc(source, target_directory: string, source_is_dir: bool, separator: u8) -> (destination: string, should_move: bool) {
	if source == "" { return }
	source_path := tree_normalize_separators(source, separator)
	target_path := tree_normalize_separators(target_directory, separator)
	if target_path == source_path || tree_parent_relative_path(source_path) == target_path { return }
	if source_is_dir {
		_, target_is_inside_source := tree_path_rewrite(target_path, source_path, "", true)
		if target_is_inside_source { return }
	}
	destination = tree_normalize_separators(
		tree_join_relative_path(target_path, tree_basename(source_path)),
		separator,
	)
	if destination == source_path { return "", false }
	return destination, true
}

workspace_tab_order_after_drop :: proc(
	documents: []bridge.State_Document,
	source_id, target_id: string,
	position: alicorn.Drop_Position,
	allocator := context.temp_allocator,
) -> (order: [dynamic]string, changed: bool) {
	order = make([dynamic]string, 0, len(documents), allocator=allocator)
	if len(documents) < 2 || len(documents) > TAB_REORDER_MAX_ITEMS || position == .None || position == .On {
		return order, false
	}
	source_index, target_index := -1, -1
	for document, index in documents {
		if document.id == source_id { source_index = index }
		if document.id == target_id { target_index = index }
	}
	if source_index < 0 || target_index < 0 || source_index == target_index { return order, false }
	insertion_index := target_index
	if source_index < target_index { insertion_index -= 1 }
	if position == .After { insertion_index += 1 }
	remaining_index := 0
	inserted := false
	for document in documents {
		if document.id == source_id { continue }
		if remaining_index == insertion_index {
			append(&order, source_id)
			inserted = true
		}
		append(&order, document.id)
		remaining_index += 1
	}
	if !inserted { append(&order, source_id) }
	changed = false
	for id, index in order {
		if index >= len(documents) || documents[index].id != id { changed = true; break }
	}
	return
}

workspace_tab_reorder_translation :: proc(order: []string, document_id: string, current_index: int, stride: f32) -> f32 {
	for id, destination in order {
		if id == document_id { return f32(destination-current_index)*stride }
	}
	return 0
}

@(test)
test_workspace_drag_destination_quietly_ignores_self_parent_and_descendant :: proc(t: ^testing.T) {
	destination, move := workspace_drag_move_destination("src/nested", "src/nested", true, '/')
	testing.expect(t, !move && destination == "", "dropping a directory onto itself should be a quiet no-op")
	destination, move = workspace_drag_move_destination("src/nested", "src", true, '/')
	testing.expect(t, !move && destination == "", "dropping into the current parent should be a quiet no-op")
	destination, move = workspace_drag_move_destination("src", "src/nested", true, '/')
	testing.expect(t, !move && destination == "", "dropping a directory inside itself should be a quiet no-op")
	destination, move = workspace_drag_move_destination("notes/today.md", "", false, '/')
	testing.expect(t, move && destination == "today.md", "dropping onto blank tree space should move a nested file to workspace root")
}

@(test)
test_tab_drop_order_uses_before_after_and_preserves_unmoved_documents :: proc(t: ^testing.T) {
	documents := [?]bridge.State_Document{{id="a"}, {id="b"}, {id="c"}, {id="d"}}
	order, changed := workspace_tab_order_after_drop(documents[:], "d", "b", .Before, context.temp_allocator)
	defer delete(order)
	testing.expect(t, changed && len(order) == 4, "moving the last tab before B should produce a complete changed order")
	if len(order) == 4 {
		testing.expect(t, order[0] == "a" && order[1] == "d" && order[2] == "b" && order[3] == "c", "Before should place the source immediately before the target")
	}
	order_after, after_changed := workspace_tab_order_after_drop(documents[:], "a", "c", .After, context.temp_allocator)
	defer delete(order_after)
	testing.expect(t, after_changed && len(order_after) == 4, "moving the first tab after C should produce a complete changed order")
	if len(order_after) == 4 {
		testing.expect(t, order_after[0] == "b" && order_after[1] == "c" && order_after[2] == "a" && order_after[3] == "d", "After should place the source immediately after the target")
	}
	no_change, moved := workspace_tab_order_after_drop(documents[:], "b", "c", .Before, context.temp_allocator)
	defer delete(no_change)
	testing.expect(t, !moved, "dropping a tab into its current insertion position should be a quiet no-op")
}

@(test)
test_tab_reorder_motion_tracks_slot_changes_without_mutating_authoritative_order :: proc(t: ^testing.T) {
	documents := [?]bridge.State_Document{{id="a"}, {id="b"}, {id="c"}}
	initial_order := [?]string{"a", "b", "c"}

	first, first_changed := workspace_tab_order_after_drop(documents[:], "c", "a", .Before, context.temp_allocator)
	defer delete(first)
	testing.expect(t, first_changed && len(first) == 3 && first[0] == "c" && first[1] == "a" && first[2] == "b",
		"dragging C before A should preview C,A,B while authoritative document order remains A,B,C")
	testing.expect(t, workspace_tab_reorder_translation(first[:], "a", 0, 100) == 100 &&
		workspace_tab_reorder_translation(first[:], "b", 1, 100) == 100,
		"neighbor tabs should shift one stable slot toward the proposed insertion")

	reversed, reversed_changed := workspace_tab_order_after_drop(documents[:], "c", "b", .Before, context.temp_allocator)
	defer delete(reversed)
	testing.expect(t, reversed_changed && len(reversed) == 3 &&
		reversed[0] == "a" && reversed[1] == "c" && reversed[2] == "b",
		"rapidly reversing the insertion target should retarget the preview order")
	testing.expect(t, workspace_tab_reorder_translation(reversed[:], "a", 0, 100) == 0 &&
		workspace_tab_reorder_translation(reversed[:], "b", 1, 100) == 100,
		"reversing the target should move only the neighbor whose slot changed")

	noop, noop_changed := workspace_tab_order_after_drop(documents[:], "c", "b", .After, context.temp_allocator)
	defer delete(noop)
	testing.expect(t, !noop_changed && len(noop) == 3 &&
		workspace_tab_reorder_translation(noop[:], "a", 0, 100) == 0 &&
		workspace_tab_reorder_translation(noop[:], "b", 1, 100) == 0,
		"moving back to the current insertion slot should be a zero-translation no-op")
	testing.expect(t, documents[0].id == initial_order[0] && documents[1].id == initial_order[1] &&
		documents[2].id == initial_order[2],
		"proposed display order must not mutate authoritative document order before drop")
}
