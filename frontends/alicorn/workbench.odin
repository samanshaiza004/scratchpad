package main

import "core:mem"
import "core:strings"

// The workbench model owns view identity and pane topology only. Resources
// remain owned by their existing application services and documents.

View_ID :: distinct u64
Pane_Group_ID :: distinct u64
Pane_Node_ID :: distinct u64
Window_ID :: distinct u64

Workbench_View_Kind :: enum u8 {
	Editor,
	History,
	Diff,
}

Workbench_Resource_Kind :: enum u8 {
	Document,
	Repository,
	Revision,
}

Workbench_Split_Axis :: enum u8 {
	Horizontal,
	Vertical,
}

Workbench_Node_Kind :: enum u8 {
	Group,
	Split,
}

Workbench_Resource_Ref :: struct {
	kind: Workbench_Resource_Kind,
	// Stable identity in the existing owner (for example DocumentID or repo path).
	id: string,
	instance_id: u64,
}

Workbench_View :: struct {
	id: View_ID,
	group_id: Pane_Group_ID,
	kind: Workbench_View_Kind,
	resource: Workbench_Resource_Ref,
	lifecycle_generation: u64,
	tab_order: u64,
}

Workbench_Pane_Group :: struct {
	id: Pane_Group_ID,
	node_id: Pane_Node_ID,
	active_view_id: View_ID,
	next_tab_order: u64,
}

Workbench_Pane_Node :: struct {
	id: Pane_Node_ID,
	parent_id: Pane_Node_ID,
	kind: Workbench_Node_Kind,
	group_id: Pane_Group_ID,
	first_child_id: Pane_Node_ID,
	second_child_id: Pane_Node_ID,
	axis: Workbench_Split_Axis,
	preferred_position: f32,
}

Workbench_State :: struct {
	window_id: Window_ID,
	allocator: mem.Allocator,
	root_node_id: Pane_Node_ID,
	focused_group_id: Pane_Group_ID,
	next_view_id: u64,
	next_group_id: u64,
	next_node_id: u64,
	views: [dynamic]Workbench_View,
	groups: [dynamic]Workbench_Pane_Group,
	nodes: [dynamic]Workbench_Pane_Node,
}

// Workbench_Model is application-scoped. Window-local split trees remain
// independent, while View IDs stay globally unique so a live view can move
// between windows without acquiring a new identity.
Workbench_Model :: struct {
	allocator: mem.Allocator,
	next_window_id: u64,
	next_view_id: u64,
	next_group_id: u64,
	next_node_id: u64,
	focused_window_id: Window_ID,
	windows: [dynamic]Workbench_State,
}

workbench_state_init :: proc(state: ^Workbench_State, window_id: Window_ID, allocator := context.allocator) -> bool {
	if state == nil || u64(window_id) == 0 { return false }
	state^ = Workbench_State{
		window_id=window_id,
		allocator=allocator,
		next_view_id=1,
		next_group_id=1,
		next_node_id=1,
		views=make([dynamic]Workbench_View, 0, allocator=allocator),
		groups=make([dynamic]Workbench_Pane_Group, 0, allocator=allocator),
		nodes=make([dynamic]Workbench_Pane_Node, 0, allocator=allocator),
	}
	group_id := workbench_group_id_next(state)
	node_id := workbench_node_id_next(state)
	append(&state.groups, Workbench_Pane_Group{id=group_id, node_id=node_id, next_tab_order=1})
	append(&state.nodes, Workbench_Pane_Node{id=node_id, kind=.Group, group_id=group_id})
	state.root_node_id = node_id
	state.focused_group_id = group_id
	return true
}

workbench_state_destroy :: proc(state: ^Workbench_State) {
	if state == nil { return }
	for &view in state.views {
		if len(view.resource.id) > 0 { delete(view.resource.id, state.allocator) }
	}
	delete(state.views)
	delete(state.groups)
	delete(state.nodes)
	state^ = {}
}

workbench_model_init :: proc(model: ^Workbench_Model, allocator := context.allocator) -> bool {
	if model == nil { return false }
	model^ = Workbench_Model{
		allocator=allocator,
		next_window_id=1,
		next_view_id=1,
		next_group_id=1,
		next_node_id=1,
		windows=make([dynamic]Workbench_State, 0, allocator=allocator),
	}
	return true
}

workbench_model_destroy :: proc(model: ^Workbench_Model) {
	if model == nil { return }
	for &window in model.windows { workbench_state_destroy(&window) }
	delete(model.windows)
	model^ = {}
}

workbench_model_window_find :: proc(model: ^Workbench_Model, window_id: Window_ID) -> int {
	if model == nil || u64(window_id) == 0 { return -1 }
	for window, index in model.windows {
		if window.window_id == window_id { return index }
	}
	return -1
}

workbench_model_window_add :: proc(model: ^Workbench_Model) -> (window_id: Window_ID, group_id: Pane_Group_ID, ok: bool) {
	if model == nil || model.next_window_id == 0 || model.next_group_id == 0 || model.next_node_id == 0 { return {}, {}, false }
	window_id = Window_ID(model.next_window_id)
	model.next_window_id += 1
	window: Workbench_State
	if !workbench_state_init(&window, window_id, model.allocator) { return {}, {}, false }
	group_id = Pane_Group_ID(model.next_group_id)
	node_id := Pane_Node_ID(model.next_node_id)
	model.next_group_id += 1
	model.next_node_id += 1
	window.groups[0].id = group_id
	window.groups[0].node_id = node_id
	window.nodes[0].id = node_id
	window.nodes[0].group_id = group_id
	window.root_node_id = node_id
	window.focused_group_id = group_id
	window.next_group_id = model.next_group_id
	window.next_node_id = model.next_node_id
	append(&model.windows, window)
	if u64(model.focused_window_id) == 0 { model.focused_window_id = window_id }
	return window_id, group_id, true
}

workbench_model_focus_window :: proc(model: ^Workbench_Model, window_id: Window_ID) -> bool {
	if workbench_model_window_find(model, window_id) < 0 { return false }
	model.focused_window_id = window_id
	return true
}

workbench_model_state_valid :: proc(model: ^Workbench_Model) -> bool {
	if model == nil { return false }
	if len(model.windows) == 0 {
		return u64(model.focused_window_id) == 0
	}
	if workbench_model_window_find(model, model.focused_window_id) < 0 { return false }
	for &window, index in model.windows {
		if u64(window.window_id) == 0 || !workbench_state_valid(&window) { return false }
		for &other, other_index in model.windows {
			if other_index < index && other.window_id == window.window_id { return false }
			if other_index >= index { continue }
			for group in other.groups {
				for current_group in window.groups {
					if group.id == current_group.id { return false }
				}
			}
			for node in other.nodes {
				for current_node in window.nodes {
					if node.id == current_node.id { return false }
				}
			}
		}
		for view, view_index in window.views {
			for &other_window, other_window_index in model.windows {
				for other_view, other_view_index in other_window.views {
					if (other_window_index < index ||
					    other_window_index == index && other_view_index < view_index) &&
					   other_view.id == view.id {
						return false
					}
				}
			}
		}
	}
	return true
}

workbench_group_id_next :: proc(state: ^Workbench_State) -> Pane_Group_ID {
	if state == nil || state.next_group_id == 0 { return {} }
	id := state.next_group_id
	state.next_group_id += 1
	return Pane_Group_ID(id)
}

workbench_node_id_next :: proc(state: ^Workbench_State) -> Pane_Node_ID {
	if state == nil || state.next_node_id == 0 { return {} }
	id := state.next_node_id
	state.next_node_id += 1
	return Pane_Node_ID(id)
}

workbench_view_id_next :: proc(state: ^Workbench_State) -> View_ID {
	if state == nil || state.next_view_id == 0 { return {} }
	id := state.next_view_id
	state.next_view_id += 1
	return View_ID(id)
}

workbench_group_find :: proc(state: ^Workbench_State, id: Pane_Group_ID) -> int {
	if state == nil || u64(id) == 0 { return -1 }
	for group, index in state.groups {
		if group.id == id { return index }
	}
	return -1
}

workbench_node_find :: proc(state: ^Workbench_State, id: Pane_Node_ID) -> int {
	if state == nil || u64(id) == 0 { return -1 }
	for node, index in state.nodes {
		if node.id == id { return index }
	}
	return -1
}

workbench_view_find :: proc(state: ^Workbench_State, id: View_ID) -> int {
	if state == nil || u64(id) == 0 { return -1 }
	for view, index in state.views {
		if view.id == id { return index }
	}
	return -1
}

workbench_view_add :: proc(
	state: ^Workbench_State,
	group_id: Pane_Group_ID,
	kind: Workbench_View_Kind,
	resource: Workbench_Resource_Ref,
	requested_view_id: View_ID = {},
	) -> (id: View_ID, ok: bool) {
	if state == nil || workbench_group_find(state, group_id) < 0 || resource.id == "" { return {}, false }
	group_index := workbench_group_find(state, group_id)
	if u64(requested_view_id) != 0 && workbench_view_find(state, requested_view_id) >= 0 { return {}, false }
	owned_resource_id, clone_error := strings.clone(resource.id, state.allocator)
	if clone_error != nil { return {}, false }
	id = requested_view_id if u64(requested_view_id) != 0 else workbench_view_id_next(state)
	if u64(id) == 0 {
		delete(owned_resource_id, state.allocator)
		return {}, false
	}
	if u64(requested_view_id) != 0 && requested_view_id >= View_ID(state.next_view_id) {
		state.next_view_id = u64(requested_view_id)+1
	}
	append(&state.views, Workbench_View{
		id=id,
		group_id=group_id,
		kind=kind,
		resource=Workbench_Resource_Ref{kind=resource.kind, id=owned_resource_id, instance_id=resource.instance_id},
		lifecycle_generation=1,
		tab_order=state.groups[group_index].next_tab_order,
	})
	state.groups[group_index].next_tab_order += 1
	if u64(state.groups[group_index].active_view_id) == 0 {
		state.groups[group_index].active_view_id = id
	}
	return id, true
}

workbench_model_view_add :: proc(
	model: ^Workbench_Model,
	window_id: Window_ID,
	group_id: Pane_Group_ID,
	kind: Workbench_View_Kind,
	resource: Workbench_Resource_Ref,
) -> (view_id: View_ID, ok: bool) {
	window_index := workbench_model_window_find(model, window_id)
	if model == nil || window_index < 0 || model.next_view_id == 0 { return {}, false }
	view_id = View_ID(model.next_view_id)
	model.next_view_id += 1
	return workbench_view_add(&model.windows[window_index], group_id, kind, resource, view_id)
}

workbench_group_activate_view :: proc(state: ^Workbench_State, group_id: Pane_Group_ID, view_id: View_ID) -> bool {
	group_index := workbench_group_find(state, group_id)
	view_index := workbench_view_find(state, view_id)
	if group_index < 0 || view_index < 0 || state.views[view_index].group_id != group_id { return false }
	state.groups[group_index].active_view_id = view_id
	state.focused_group_id = group_id
	return true
}

workbench_group_first_view :: proc(state: ^Workbench_State, group_id: Pane_Group_ID) -> View_ID {
	if state == nil { return {} }
	best_order := u64(0xFFFF_FFFF_FFFF_FFFF)
	result: View_ID
	for view in state.views {
		if view.group_id != group_id || view.tab_order >= best_order { continue }
		best_order = view.tab_order
		result = view.id
	}
	return result
}

workbench_group_collapse_if_empty :: proc(state: ^Workbench_State, group_id: Pane_Group_ID) -> bool {
	group_index := workbench_group_find(state, group_id)
	if group_index < 0 { return false }
	for view in state.views {
		if view.group_id == group_id { return true }
	}
	leaf_id := state.groups[group_index].node_id
	leaf_index := workbench_node_find(state, leaf_id)
	if leaf_index < 0 || state.nodes[leaf_index].kind != .Group { return false }
	parent_id := state.nodes[leaf_index].parent_id
	if u64(parent_id) == 0 {
		state.groups[group_index].active_view_id = {}
		return true
	}
	parent_index := workbench_node_find(state, parent_id)
	if parent_index < 0 || state.nodes[parent_index].kind != .Split { return false }
	parent := state.nodes[parent_index]
	sibling_id := parent.first_child_id if parent.first_child_id != leaf_id else parent.second_child_id
	sibling_index := workbench_node_find(state, sibling_id)
	if sibling_index < 0 { return false }
	sibling := state.nodes[sibling_index]
	grandparent_id := parent.parent_id
	if u64(grandparent_id) == 0 {
		state.root_node_id = sibling_id
	} else {
		grandparent_index := workbench_node_find(state, grandparent_id)
		if grandparent_index < 0 { return false }
		if state.nodes[grandparent_index].first_child_id == parent_id {
			state.nodes[grandparent_index].first_child_id = sibling_id
		} else if state.nodes[grandparent_index].second_child_id == parent_id {
			state.nodes[grandparent_index].second_child_id = sibling_id
		} else {
			return false
		}
	}
	state.nodes[sibling_index].parent_id = grandparent_id
	if sibling.kind == .Split {
		if first_index := workbench_node_find(state, sibling.first_child_id); first_index >= 0 {
			state.nodes[first_index].parent_id = sibling_id
		}
		if second_index := workbench_node_find(state, sibling.second_child_id); second_index >= 0 {
			state.nodes[second_index].parent_id = sibling_id
		}
	} else if sibling_group_index := workbench_group_find(state, sibling.group_id); sibling_group_index >= 0 {
		state.groups[sibling_group_index].node_id = sibling_id
	}
	// Remove the old leaf and split parent after their references have been replaced.
	remove_ids := [2]Pane_Node_ID{leaf_id, parent_id}
	for remove_id in remove_ids {
		if remove_index := workbench_node_find(state, remove_id); remove_index >= 0 {
			ordered_remove(&state.nodes, remove_index)
		}
	}
	ordered_remove(&state.groups, group_index)
	if state.focused_group_id == group_id {
		state.focused_group_id = sibling.group_id
		if sibling.kind == .Split {
			state.focused_group_id = workbench_first_group_in_subtree(state, sibling_id)
		}
	}
	return true
}

workbench_first_group_in_subtree :: proc(state: ^Workbench_State, node_id: Pane_Node_ID) -> Pane_Group_ID {
	index := workbench_node_find(state, node_id)
	if index < 0 { return {} }
	node := state.nodes[index]
	if node.kind == .Group { return node.group_id }
	return workbench_first_group_in_subtree(state, node.first_child_id)
}

workbench_view_move :: proc(state: ^Workbench_State, view_id: View_ID, target_group_id: Pane_Group_ID) -> bool {
	// The move and empty-group collapse below are failure-atomic for a valid
	// topology: validate the source tree before changing ownership or tab order.
	if !workbench_state_valid(state) { return false }
	view_index := workbench_view_find(state, view_id)
	target_index := workbench_group_find(state, target_group_id)
	if view_index < 0 || target_index < 0 { return false }
	source_group_id := state.views[view_index].group_id
	source_index := workbench_group_find(state, source_group_id)
	if source_index < 0 { return false }
	was_active := state.groups[source_index].active_view_id == view_id
	if source_group_id == target_group_id {
		state.views[view_index].tab_order = state.groups[target_index].next_tab_order
		state.groups[target_index].next_tab_order += 1
		return true
	}
	state.views[view_index].group_id = target_group_id
	state.views[view_index].tab_order = state.groups[target_index].next_tab_order
	state.groups[target_index].next_tab_order += 1
	if u64(state.groups[target_index].active_view_id) == 0 || was_active {
		state.groups[target_index].active_view_id = view_id
	}
	if was_active {
		state.groups[source_index].active_view_id = workbench_group_first_view(state, source_group_id)
		state.groups[target_index].active_view_id = view_id
		state.focused_group_id = target_group_id
	}
	collapsed := workbench_group_collapse_if_empty(state, source_group_id)
	assert(collapsed, "valid workbench topology must allow its emptied group to collapse")
	return true
}

workbench_view_close :: proc(state: ^Workbench_State, view_id: View_ID) -> bool {
	view_index := workbench_view_find(state, view_id)
	if view_index < 0 { return false }
	group_id := state.views[view_index].group_id
	group_index := workbench_group_find(state, group_id)
	if group_index < 0 { return false }
	was_active := state.groups[group_index].active_view_id == view_id
	if len(state.views[view_index].resource.id) > 0 {
		delete(state.views[view_index].resource.id, state.allocator)
	}
	ordered_remove(&state.views, view_index)
	if was_active { state.groups[group_index].active_view_id = workbench_group_first_view(state, group_id) }
	return workbench_group_collapse_if_empty(state, group_id)
}

workbench_state_valid :: proc(state: ^Workbench_State) -> bool {
	if state == nil || workbench_node_find(state, state.root_node_id) < 0 ||
	   workbench_group_find(state, state.focused_group_id) < 0 { return false }
	for group, group_index in state.groups {
		if u64(group.id) == 0 || workbench_group_find(state, group.id) != group_index { return false }
		node_index := workbench_node_find(state, group.node_id)
		if node_index < 0 || state.nodes[node_index].kind != .Group || state.nodes[node_index].group_id != group.id { return false }
		active_found := false
		group_view_count := 0
		for view in state.views {
			if view.group_id != group.id { continue }
			if view.resource.id == "" || u64(view.id) == 0 || view.lifecycle_generation == 0 { return false }
			group_view_count += 1
			if view.id == group.active_view_id { active_found = true }
		}
		is_root_group := group.node_id == state.root_node_id
		if group_view_count == 0 {
			if !is_root_group || u64(group.active_view_id) != 0 { return false }
		} else if !active_found { return false }
	}
	for view, view_index in state.views {
		if u64(view.id) == 0 || view.lifecycle_generation == 0 ||
		   workbench_group_find(state, view.group_id) < 0 || view.resource.id == "" { return false }
		for other_index in view_index+1..<len(state.views) {
			if state.views[other_index].id == view.id { return false }
		}
	}
	group_node_count := 0
	for node, node_index in state.nodes {
		if u64(node.id) == 0 { return false }
		for other, other_index in state.nodes {
			if other_index < node_index && other.id == node.id { return false }
		}
		if node.id == state.root_node_id && u64(node.parent_id) != 0 { return false }
		if node.kind == .Group {
			group_node_count += 1
			group_index := workbench_group_find(state, node.group_id)
			if group_index < 0 || state.groups[group_index].node_id != node.id { return false }
		}
		if u64(node.parent_id) != 0 {
			parent_index := workbench_node_find(state, node.parent_id)
			if parent_index < 0 || state.nodes[parent_index].kind != .Split ||
			   (state.nodes[parent_index].first_child_id != node.id && state.nodes[parent_index].second_child_id != node.id) { return false }
		}
		if node.kind == .Split {
			first_index := workbench_node_find(state, node.first_child_id)
			second_index := workbench_node_find(state, node.second_child_id)
			if first_index < 0 || second_index < 0 || node.first_child_id == node.second_child_id ||
			   state.nodes[first_index].parent_id != node.id || state.nodes[second_index].parent_id != node.id { return false }
		}
		cursor := node.id
		reached_root := cursor == state.root_node_id
		for _ in 0..<len(state.nodes) {
			if reached_root { break }
			cursor_index := workbench_node_find(state, cursor)
			if cursor_index < 0 { return false }
			parent_id := state.nodes[cursor_index].parent_id
			if u64(parent_id) == 0 { return false }
			cursor = parent_id
			reached_root = cursor == state.root_node_id
		}
		if !reached_root { return false }
	}
	return group_node_count == len(state.groups)
}

workbench_view_split :: proc(
	state: ^Workbench_State,
	view_id: View_ID,
	axis: Workbench_Split_Axis,
	preferred_position: f32 = 0.5,
	requested_duplicate_id: View_ID = {},
) -> (duplicate_id: View_ID, new_group_id: Pane_Group_ID, ok: bool) {
	view_index := workbench_view_find(state, view_id)
	if view_index < 0 { return {}, {}, false }
	old_view := state.views[view_index]
	old_group_index := workbench_group_find(state, old_view.group_id)
	if old_group_index < 0 { return {}, {}, false }
	old_group := state.groups[old_group_index]
	old_leaf_index := workbench_node_find(state, old_group.node_id)
	if old_leaf_index < 0 || state.nodes[old_leaf_index].kind != .Group { return {}, {}, false }
	owned_resource_id, clone_error := strings.clone(old_view.resource.id, state.allocator)
	if clone_error != nil { return {}, {}, false }
	if u64(requested_duplicate_id) != 0 && workbench_view_find(state, requested_duplicate_id) >= 0 {
		delete(owned_resource_id, state.allocator)
		return {}, {}, false
	}
	new_group_id = workbench_group_id_next(state)
	new_group_node_id := workbench_node_id_next(state)
	parent_id := workbench_node_id_next(state)
	duplicate_id = requested_duplicate_id if u64(requested_duplicate_id) != 0 else workbench_view_id_next(state)
	if u64(new_group_id) == 0 || u64(new_group_node_id) == 0 || u64(parent_id) == 0 || u64(duplicate_id) == 0 {
		delete(owned_resource_id, state.allocator)
		return {}, {}, false
	}
	if u64(requested_duplicate_id) != 0 && requested_duplicate_id >= View_ID(state.next_view_id) {
		state.next_view_id = u64(requested_duplicate_id)+1
	}

	old_leaf := state.nodes[old_leaf_index]
	parent_index := -1
	if u64(old_leaf.parent_id) != 0 {
		parent_index = workbench_node_find(state, old_leaf.parent_id)
		if parent_index < 0 {
			delete(owned_resource_id, state.allocator)
			return {}, {}, false
		}
		if state.nodes[parent_index].first_child_id != old_leaf.id &&
		   state.nodes[parent_index].second_child_id != old_leaf.id {
			delete(owned_resource_id, state.allocator)
			return {}, {}, false
		}
	}

	append(&state.groups, Workbench_Pane_Group{id=new_group_id, node_id=new_group_node_id, next_tab_order=1})
	append(&state.nodes, Workbench_Pane_Node{id=new_group_node_id, parent_id=parent_id, kind=.Group, group_id=new_group_id})
	append(&state.nodes, Workbench_Pane_Node{
		id=parent_id,
		parent_id=old_leaf.parent_id,
		kind=.Split,
		first_child_id=old_leaf.id,
		second_child_id=new_group_node_id,
		axis=axis,
		preferred_position=clamp(preferred_position, 0.1, 0.9),
	})
	if parent_index < 0 {
		state.root_node_id = parent_id
	} else if state.nodes[parent_index].first_child_id == old_leaf.id {
		state.nodes[parent_index].first_child_id = parent_id
	} else {
		state.nodes[parent_index].second_child_id = parent_id
	}
	state.nodes[old_leaf_index].parent_id = parent_id

	append(&state.views, Workbench_View{
		id=duplicate_id,
		group_id=new_group_id,
		kind=old_view.kind,
		resource=Workbench_Resource_Ref{kind=old_view.resource.kind, id=owned_resource_id, instance_id=old_view.resource.instance_id},
		lifecycle_generation=1,
		tab_order=1,
	})
	state.groups[workbench_group_find(state, new_group_id)].active_view_id = duplicate_id
	state.focused_group_id = new_group_id
	return duplicate_id, new_group_id, true
}

workbench_model_view_split :: proc(
	model: ^Workbench_Model,
	window_id: Window_ID,
	view_id: View_ID,
	axis: Workbench_Split_Axis,
	preferred_position: f32 = 0.5,
) -> (duplicate_id: View_ID, group_id: Pane_Group_ID, ok: bool) {
	window_index := workbench_model_window_find(model, window_id)
	if model == nil || window_index < 0 || model.next_view_id == 0 || model.next_group_id == 0 || model.next_node_id == 0 { return {}, {}, false }
	requested_id := View_ID(model.next_view_id)
	model.next_view_id += 1
	window := &model.windows[window_index]
	window.next_group_id = model.next_group_id
	window.next_node_id = model.next_node_id
	duplicate_id, group_id, ok = workbench_view_split(window, view_id, axis, preferred_position, requested_id)
	model.next_group_id = window.next_group_id
	model.next_node_id = window.next_node_id
	return
}

workbench_model_view_move :: proc(
	model: ^Workbench_Model,
	view_id: View_ID,
	target_window_id: Window_ID,
	target_group_id: Pane_Group_ID,
) -> bool {
	if model == nil || u64(view_id) == 0 || !workbench_model_state_valid(model) { return false }
	target_window_index := workbench_model_window_find(model, target_window_id)
	if target_window_index < 0 { return false }
	target_window := &model.windows[target_window_index]
	target_group_index := workbench_group_find(target_window, target_group_id)
	if target_group_index < 0 { return false }

	source_window_index := -1
	source_view_index := -1
	for &window, window_index in model.windows {
		if index := workbench_view_find(&window, view_id); index >= 0 {
			if source_view_index >= 0 { return false }
			source_window_index = window_index
			source_view_index = index
		}
	}
	if source_view_index < 0 { return false }
	if source_window_index == target_window_index {
		moved := workbench_view_move(target_window, view_id, target_group_id)
		assert(moved, "a prevalidated in-window move must complete")
		return true
	}
	source_window := &model.windows[source_window_index]
	source_view := source_window.views[source_view_index]
	source_group_index := workbench_group_find(source_window, source_view.group_id)
	if source_group_index < 0 || workbench_view_find(target_window, view_id) >= 0 { return false }
	target_resource_id, clone_error := strings.clone(source_view.resource.id, target_window.allocator)
	if clone_error != nil { return false }
	source_was_active := source_window.groups[source_group_index].active_view_id == view_id
	moved := source_view
	moved.group_id = target_group_id
	moved.resource.id = target_resource_id
	moved.tab_order = target_window.groups[target_group_index].next_tab_order
	target_window.groups[target_group_index].next_tab_order += 1
	append(&target_window.views, moved)
	if u64(target_window.groups[target_group_index].active_view_id) == 0 || source_was_active {
		target_window.groups[target_group_index].active_view_id = view_id
	}
	if source_window.views[source_view_index].resource.id != "" {
		delete(source_window.views[source_view_index].resource.id, source_window.allocator)
	}
	ordered_remove(&source_window.views, source_view_index)
	if source_was_active {
		source_window.groups[source_group_index].active_view_id = workbench_group_first_view(source_window, source_view.group_id)
	}
	if source_was_active {
		target_window.groups[target_group_index].active_view_id = view_id
		target_window.focused_group_id = target_group_id
	}
	collapsed := workbench_group_collapse_if_empty(source_window, source_view.group_id)
	assert(collapsed, "valid source topology must allow its emptied group to collapse")
	assert(workbench_state_valid(source_window) && workbench_state_valid(target_window),
		"a prevalidated cross-window move must preserve both topology invariants")
	return true
}

workbench_model_view_close :: proc(model: ^Workbench_Model, view_id: View_ID) -> bool {
	if model == nil { return false }
	for &window in model.windows {
		if workbench_view_find(&window, view_id) >= 0 {
			return workbench_view_close(&window, view_id)
		}
	}
	return false
}

workbench_model_window_close :: proc(model: ^Workbench_Model, window_id: Window_ID) -> bool {
	window_index := workbench_model_window_find(model, window_id)
	if model == nil || window_index < 0 || len(model.windows[window_index].views) > 0 { return false }
	workbench_state_destroy(&model.windows[window_index])
	ordered_remove(&model.windows, window_index)
	if model.focused_window_id == window_id {
		model.focused_window_id = model.windows[0].window_id if len(model.windows) > 0 else {}
	}
	return true
}
