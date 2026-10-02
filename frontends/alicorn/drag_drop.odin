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
		workspace_drag_clear(app)
		if !workspace_drag_capture_source(app, event) {
			set_error(app, "The dragged item is no longer available.")
			alicorn.invalidate_root(rt, "Scratchpad could not resolve the stable drag source")
		}
	case .Dropped:
		workspace_drag_apply_drop(app, rt, event)
		workspace_drag_clear(app)
	case .Cancelled:
		workspace_drag_clear(app)
	case .Target_Changed:
	}
}

workspace_drag_capture_source :: proc(app: ^App, event: alicorn.Drag_Event) -> bool {
	if app == nil || !app.backend.started { return false }
	switch event.drag_type {
	case SCRATCHPAD_DRAG_TABS:
		for document in app.backend.state.documents {
			if document_tab_semantic_id(document.id) != event.source { continue }
			copy, err := strings.clone(document.id, context.allocator)
			if err != nil { return false }
			app.workspace_drag_kind = .Tabs
			app.workspace_drag_source_document_id = copy
			return true
		}
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
		if event.drag_type != SCRATCHPAD_DRAG_TABS || event.target.namespace != TAB_SEMANTIC_NAMESPACE { return }
		target_id := ""
		for document in app.backend.state.documents {
			if document_tab_semantic_id(document.id) == event.target {
				target_id = document.id
				break
			}
		}
		if target_id == "" { return }
		order, changed := workspace_tab_order_after_drop(
			app.backend.state.documents,
			app.workspace_drag_source_document_id,
			target_id,
			event.position,
			context.temp_allocator,
		)
		defer delete(order)
		if len(order) == 0 { return }
		source_preview := false
		for document in app.backend.state.documents {
			if document.id == app.workspace_drag_source_document_id {
				source_preview = document.preview
				break
			}
		}
		if !changed && !source_preview { return }
		response := bridge.backend_command(&app.backend, "reorder_documents", document_order=order[:])
		handle_command_result(app, rt, &response)
		bridge.backend_command_result_destroy(&response, context.allocator)
	case .Workspace:
		if event.drag_type != SCRATCHPAD_DRAG_WORKSPACE { return }
		target_path, found := workspace_drag_target_path(app, event.target)
		if !found { return }
		destination, should_move := workspace_drag_move_destination(
			app.workspace_drag_source_path,
			target_path,
			app.workspace_drag_source_is_dir,
			tree_preferred_separator(app),
		)
		if !should_move { return }
		workspace_mutation_execute(
			app, rt, .Move,
			app.workspace_drag_source_path, "", destination,
			app.workspace_drag_source_is_dir, false,
			app.backend.state.workspace_root,
		)
	case .None:
	}
}

workspace_drag_clear :: proc(app: ^App) {
	if app == nil { return }
	if len(app.workspace_drag_source_document_id) > 0 { delete(app.workspace_drag_source_document_id, context.allocator) }
	if len(app.workspace_drag_source_path) > 0 { delete(app.workspace_drag_source_path, context.allocator) }
	app.workspace_drag_source_document_id = ""
	app.workspace_drag_source_path = ""
	app.workspace_drag_source_is_dir = false
	app.workspace_drag_kind = .None
}

workspace_drag_target_path :: proc(app: ^App, target: alicorn.Semantic_ID) -> (path: string, found: bool) {
	if app == nil { return }
	if target == tree_semantic_id("", true) { return "", true }
	rows := make([dynamic]Tree_Row, 0, allocator=context.temp_allocator)
	defer delete(rows)
	tree_flatten_directory(app, "", 0, &rows)
	for row in rows {
		if row.is_dir && tree_semantic_id(row.path, true) == target { return row.path, true }
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
	destination = tree_join_relative_path(target_path, tree_basename(source_path))
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
