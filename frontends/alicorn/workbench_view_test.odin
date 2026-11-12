package main

import "core:mem"
import "core:testing"
import bridge "./bridge"

workbench_test_fail_alloc :: proc(
	data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> ([]u8, mem.Allocator_Error) {
	if mode == .Alloc || mode == .Alloc_Non_Zeroed { return nil, .Out_Of_Memory }
	return context.allocator.procedure(context.allocator.data, mode, size, alignment, old_memory, old_size, location)
}

@(test)
test_two_editor_view_ids_keep_independent_state_for_one_document :: proc(t: ^testing.T) {
	views := make([dynamic]Editor_View_State, 0, allocator=context.allocator)
	defer editor_views_destroy(&views)

	first, first_ok := editor_view_ensure_for_id(&views, 11, "shared-document", context.allocator)
	second, second_ok := editor_view_ensure_for_id(&views, 12, "shared-document", context.allocator)
	testing.expect(t, first_ok && second_ok && first != second,
		"two stable view identities should create independent editor state for one document")
	if !first_ok || !second_ok { return }
	testing.expect(t, views[first].lifecycle_generation == 1 && views[second].lifecycle_generation == 1,
		"new editor views should start with a nonzero async lifecycle generation")

	views[first].caret_byte = 24
	views[first].scroll_y = 120
	views[second].caret_byte = 900
	views[second].scroll_y = 960

	first_again := editor_view_find_by_id(views[:], 11)
	second_again := editor_view_find_by_id(views[:], 12)
	testing.expect(t, first_again == first && second_again == second,
		"a view identity should resolve to the same retained presentation state")
	if first_again < 0 || second_again < 0 { return }
	testing.expect(t,
		views[first_again].document_id == views[second_again].document_id &&
		views[first_again].caret_byte == 24 && views[first_again].scroll_y == 120 &&
		views[second_again].caret_byte == 900 && views[second_again].scroll_y == 960,
		"views of one resource should preserve their own caret and viewport")
	focused := editor_view_set_focused(views[:], 12)
	testing.expect(t, focused && editor_view_find(views[:], "shared-document") == second &&
	               views[first].focused == false && views[second].focused,
	               "resource lookup should prefer the focused presentation when a document has multiple views")

	reused, reused_ok := editor_view_ensure_for_id(&views, 12, "shared-document", context.allocator)
	testing.expect(t, reused_ok && reused == second && len(views) == 2,
		"reconciling the same view identity should reuse it instead of creating another view")
	request := bridge.Visible_Window_Request{
		view_id=11,
		view_lifecycle_generation=1,
		document_id="shared-document",
		document_instance_id=91,
		editor_revision=7,
		start_line=24,
	}
	testing.expect(t, editor_view_request_rejection_set(&views[first], request),
		"retry suppression should be retainable by its originating editor view")
	testing.expect(t, editor_view_request_is_rejected(&views[first], request) &&
	               !editor_view_request_is_rejected(&views[second], request),
	               "one view's rejected source window must not suppress another view")
	new_lifecycle := request
	new_lifecycle.view_lifecycle_generation += 1
	testing.expect(t, !editor_view_request_is_rejected(&views[first], new_lifecycle),
	               "a resource replacement must not inherit retry suppression from an older view lifecycle")
	editor_view_request_rejection_clear(&views[first])
	wrong_resource, wrong_resource_ok := editor_view_ensure_for_id(&views, 12, "different-document", context.allocator)
	testing.expect(t, !wrong_resource_ok && wrong_resource < 0,
		"a live view identity must not be rebound to a different resource")
}

@(test)
test_workbench_split_move_and_close_preserve_resource_identity :: proc(t: ^testing.T) {
	state: Workbench_State
	initialized := workbench_state_init(&state, Window_ID(1))
	testing.expect(t, initialized, "a window should start with one pane group")
	if !initialized { return }
	defer workbench_state_destroy(&state)

	root_group := state.focused_group_id
	original, added := workbench_view_add(&state, root_group, .Editor,
		Workbench_Resource_Ref{kind=.Document, id="notes.md", instance_id=9})
	testing.expect(t, added && workbench_state_valid(&state), "the initial editor view should satisfy topology invariants")
	if !added { return }

	duplicate, second_group, split := workbench_view_split(&state, original, .Horizontal)
	testing.expect(t, split && duplicate != original && second_group != root_group,
		"splitting an editor should create a second view identity and pane group")
	testing.expect(t, workbench_state_valid(&state), "the split tree should retain valid parent and active-view relationships")
	if !split { return }

	first_index := workbench_view_find(&state, original)
	second_index := workbench_view_find(&state, duplicate)
	if first_index < 0 || second_index < 0 { testing.expect(t, false, "both split views should remain addressable"); return }
	testing.expect(t,
		state.views[first_index].resource.id == state.views[second_index].resource.id &&
		state.views[first_index].resource.instance_id == state.views[second_index].resource.instance_id,
		"both editor views should reference the same authoritative document instance")
	testing.expect(t, state.focused_group_id == second_group,
		"the duplicate created by split should receive focus")

	moved := workbench_view_move(&state, duplicate, root_group)
	testing.expect(t, moved && workbench_view_find(&state, duplicate) >= 0,
		"moving a tab should preserve its view identity")
	testing.expect(t, len(state.groups) == 1 && len(state.nodes) == 1 && state.focused_group_id == root_group,
		"moving the only tab out of a split group should collapse the empty group without stealing identity")
	testing.expect(t, workbench_state_valid(&state), "the collapsed tree should remain valid")

	closed_duplicate := workbench_view_close(&state, duplicate)
	closed_original := workbench_view_close(&state, original)
	testing.expect(t, closed_duplicate && closed_original && len(state.views) == 0,
		"closing editor views should not require destroying the separate document resource")
	testing.expect(t, workbench_state_valid(&state), "an empty single root group should remain a valid workbench")
}

@(test)
test_workbench_model_ids_and_cross_window_move_are_stable :: proc(t: ^testing.T) {
	model: Workbench_Model
	initialized := workbench_model_init(&model)
	testing.expect(t, initialized, "the application workbench should initialize")
	if !initialized { return }
	defer workbench_model_destroy(&model)

	first_window, first_group, first_ok := workbench_model_window_add(&model)
	second_window, second_group, second_ok := workbench_model_window_add(&model)
	testing.expect(t, first_ok && second_ok && first_window != second_window && first_group != second_group,
		"window and pane-group identities should be unique across the application")
	if !first_ok || !second_ok { return }
	testing.expect(t, model.focused_window_id == first_window,
		"creating another native window should not steal the existing window focus")
	first_view, first_view_ok := workbench_model_view_add(&model, first_window, first_group, .Editor,
		Workbench_Resource_Ref{kind=.Document, id="same-document", instance_id=23})
	background_view, background_view_ok := workbench_model_view_add(&model, first_window, first_group, .Editor,
		Workbench_Resource_Ref{kind=.Document, id="same-document", instance_id=23})
	testing.expect(t, first_view_ok && background_view_ok && first_view != background_view,
		"two views over one resource should have separate stable identities")
	if !first_view_ok || !background_view_ok { return }

	moved := workbench_model_view_move(&model, background_view, second_window, second_group)
	testing.expect(t, moved && workbench_model_state_valid(&model),
		"a view should move across native windows while preserving valid topology")
	if !moved { return }
	second_index := workbench_model_window_find(&model, second_window)
	if second_index < 0 { testing.expect(t, false, "destination window should remain present"); return }
	view_index := workbench_view_find(&model.windows[second_index], background_view)
	if view_index < 0 { testing.expect(t, false, "moved view identity should remain present"); return }
	view := model.windows[second_index].views[view_index]
	testing.expect(t, view.id == background_view && view.resource.id == "same-document" && view.resource.instance_id == 23,
		"moving a view should preserve both its identity and its authoritative resource reference")
	testing.expect(t, model.focused_window_id == first_window,
		"moving an inactive view must not steal native-window focus")
	testing.expect(t, model.windows[second_index].groups[0].active_view_id == background_view,
		"an empty destination pane group should select the moved view without changing native focus")
	if second_index >= 0 {
		first_index := workbench_model_window_find(&model, first_window)
		if first_index >= 0 {
			testing.expect(t, model.windows[first_index].groups[0].active_view_id == first_view,
				"the source group's active editor should remain selected after moving an inactive tab")
		}
	}
	testing.expect(t, workbench_model_focus_window(&model, second_window) && model.focused_window_id == second_window,
		"native focus should change through an explicit window-focus transition")
	testing.expect(t, workbench_model_state_valid(&model), "the multi-window model should satisfy global identity invariants")
}

@(test)
test_workbench_failed_moves_leave_source_and_destination_unchanged :: proc(t: ^testing.T) {
	model: Workbench_Model
	initialized := workbench_model_init(&model)
	testing.expect(t, initialized, "the application workbench should initialize")
	if !initialized { return }
	defer workbench_model_destroy(&model)

	source_window_id, source_group_id, source_ok := workbench_model_window_add(&model)
	target_window_id, target_group_id, target_ok := workbench_model_window_add(&model)
	if !source_ok || !target_ok { testing.expect(t, false, "move fixture windows should initialize"); return }
	view_id, view_ok := workbench_model_view_add(&model, source_window_id, source_group_id, .Editor,
		Workbench_Resource_Ref{kind=.Document, id="shared-resource", instance_id=8})
	if !view_ok { testing.expect(t, false, "move fixture view should initialize"); return }

	source_index := workbench_model_window_find(&model, source_window_id)
	target_index := workbench_model_window_find(&model, target_window_id)
	source_view_index := workbench_view_find(&model.windows[source_index], view_id)
	invalid_target_moved := workbench_model_view_move(&model, view_id, target_window_id, Pane_Group_ID(999))
	testing.expect(t, !invalid_target_moved && workbench_model_state_valid(&model),
		"an invalid destination group should be rejected without changing topology")
	testing.expect(t,
		len(model.windows[source_index].views) == 1 &&
		model.windows[source_index].views[source_view_index].group_id == source_group_id &&
		len(model.windows[target_index].views) == 0,
		"failed destination validation should leave both windows and the source view unchanged")

	original_target_allocator := model.windows[target_index].allocator
	model.windows[target_index].allocator = mem.Allocator{procedure=workbench_test_fail_alloc}
	copy_failed_move := workbench_model_view_move(&model, view_id, target_window_id, target_group_id)
	model.windows[target_index].allocator = original_target_allocator
	testing.expect(t, !copy_failed_move && workbench_model_state_valid(&model),
		"a resource-reference copy failure should be rejected while preserving valid topology")
	testing.expect(t,
		len(model.windows[source_index].views) == 1 &&
		model.windows[source_index].views[0].id == view_id &&
		model.windows[source_index].views[0].group_id == source_group_id &&
		len(model.windows[target_index].views) == 0,
		"resource-copy failure must not remove the source or add a partial destination view")
}

@(test)
test_app_editor_state_uses_workbench_view_identity :: proc(t: ^testing.T) {
	app: App
	app.editor_views = make([dynamic]Editor_View_State, 0, allocator=context.allocator)
	defer editor_views_destroy(&app.editor_views)
	if !workbench_model_init(&app.workbench_model) {
		testing.expect(t, false, "the app workbench model should initialize")
		return
	}
	defer workbench_model_destroy(&app.workbench_model)
	window_id, group_id, window_ok := workbench_model_window_add(&app.workbench_model)
	if !window_ok { testing.expect(t, false, "the app workbench should have one initial window and group"); return }
	app.primary_workbench_window_id = window_id
	app.primary_workbench_group_id = group_id
	app.workbench_model_ready = true

	workbench_view_id, view_ok := app_workbench_document_view_ensure(&app, "notes.md", 41)
	state_index, state_ok := app_editor_view_ensure(&app, "notes.md")
	testing.expect(t, view_ok && state_ok && u64(workbench_view_id) == app.editor_views[state_index].view_id,
		"the editor presentation should use the stable View ID owned by the workbench")
	if !view_ok || !state_ok { return }

	same_view_id, same_view_ok := app_workbench_document_view_ensure(&app, "notes.md", 41)
	second_state_index, second_state_ok := app_editor_view_ensure(&app, "notes.md")
	testing.expect(t, same_view_ok && second_state_ok && same_view_id == workbench_view_id &&
	               second_state_index == state_index && len(app.workbench_model.windows[0].views) == 1,
		"reconciling one open document should reuse one workbench view and its editor presentation")

	future_view_id, future_view_ok := workbench_model_view_add(&app.workbench_model, window_id, group_id, .Editor,
		Workbench_Resource_Ref{kind=.Document, id="future.md", instance_id=42})
	transient_index, transient_ok := app_editor_transient_view_ensure(&app, "pinned-only.md")
	future_state_index, future_state_ok := app_editor_view_ensure(&app, "future.md")
	testing.expect(t, future_view_ok && transient_ok && future_state_ok &&
	               app.editor_views[transient_index].view_id >= 0x8000_0000_0000_0000 &&
	               app.editor_views[future_state_index].view_id == u64(future_view_id),
		"transient pinned/recovery state must not collide with workbench IDs that have not instantiated editor caches yet")

	rekeyed := app_workbench_view_resource_rekey(&app, u64(workbench_view_id), "renamed-notes.md", 43)
	first_window := workbench_model_window_find(&app.workbench_model, window_id)
	rekeyed_view_index := workbench_view_find(&app.workbench_model.windows[first_window], workbench_view_id)
	testing.expect(t, rekeyed && rekeyed_view_index >= 0 &&
	               app.workbench_model.windows[first_window].views[rekeyed_view_index].resource.id == "renamed-notes.md" &&
	               app.workbench_model.windows[first_window].views[rekeyed_view_index].resource.instance_id == 43,
		"a path rekey should preserve the Workbench View ID while updating its authoritative resource reference")
	testing.expect(t, workbench_model_state_valid(&app.workbench_model),
		"the app-attached one-group model should preserve topology invariants")
}
