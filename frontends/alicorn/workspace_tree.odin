package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import alicorn "alicorn:runtime"
import gui "alicorn:ui"
import host "alicorn:native/sdl_gpu"
import alikit_tree "alikit:tree_view"
import bridge "./bridge"

TREE_SEMANTIC_NAMESPACE :: u64(0x5343524154434850)
TREE_ROW_HEIGHT :: 26
TREE_INDENT_WIDTH :: f32(12)
TREE_TYPE_ICON_SIZE :: f32(16)
TREE_ROW_PADDING :: f32(3)
TREE_ROW_GAP :: f32(6)
TREE_SCROLL_KEY :: "scratchpad-workspace-tree"

Tree_Directory :: struct {
	path:      string,
	entries:   []bridge.Directory_Entry,
	truncated: bool,
	expanded:  bool,
}

Tree_Row :: struct {
	name:      string,
	path:      string,
	depth:     int,
	is_dir:    bool,
	expanded:  bool,
}

build_workspace_tree :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime) {
	if !app.backend.state.has_workspace {
		app.tree_scroll_owner = 0
		alicorn.container_begin(ui, .Container, label="workspace-tree-empty", style=alicorn.layout_style(grow=1, padding=12), color=alicorn.style_color(ui, .Subtle_Surface))
		gui.text(ui, "Open a folder to browse files.")
		alicorn.container_end(ui)
		return
	}
	root_index := tree_directory_index(app, "")
	if root_index < 0 {
		app.tree_scroll_owner = 0
		alicorn.container_begin(ui, .Container, label="workspace-tree-loading", style=alicorn.layout_style(grow=1, padding=12), color=alicorn.style_color(ui, .Subtle_Surface))
		gui.text(ui, "Loading workspace…")
		alicorn.container_end(ui)
		return
	}

	session_ui_expand_focus_ancestors(app)
	rows := make([dynamic]Tree_Row, 0, allocator=context.temp_allocator)
	defer delete(rows)
	tree_flatten_directory(app, "", 0, &rows)
	window := workspace_tree_window(app, rows[:])
	active_document, has_active_document := find_document(&app.backend.state, app.backend.state.active)
	callbacks := Workspace_Tree_Callback_Data{
		app=app, rows=rows[:], active_document_path=active_document.path,
		has_active_document=has_active_document,
	}
	_ = alicorn.drop_target(ui, SCRATCHPAD_DRAG_WORKSPACE, tree_semantic_id("", true), .On)
	event := alikit_tree.build(
		ui, &app.workspace_tree_state, window, alicorn.key_string(TREE_SCROLL_KEY),
		workspace_tree_options(rawptr(&callbacks), session_ui_tree_scroll_request(app)),
	)
	app.tree_scroll_owner = app.workspace_tree_state.scroll_node
	session_ui_restore_tree_focus(app, rt, rows[:])
	workspace_tree_apply_event(app, rt, rows[:], event, false)
	if tree_any_truncated(app) { gui.text(ui, "Some folders show only the first 200 entries.") }
}

Workspace_Tree_Callback_Data :: struct {
	app: ^App,
	rows: []Tree_Row,
	active_document_path: string,
	has_active_document: bool,
}

workspace_tree_item_id :: proc(path: string, is_directory: bool) -> alikit_tree.Item_ID {
	semantic := tree_semantic_id(path, is_directory)
	return alikit_tree.Item_ID(semantic.value)
}

workspace_tree_window :: proc(app: ^App, rows: []Tree_Row) -> alikit_tree.Window {
	items := make([]alikit_tree.Item, len(rows), allocator=context.temp_allocator)
	for row, index in rows {
		parent_id: alikit_tree.Item_ID
		if row.depth > 0 { parent_id = workspace_tree_item_id(tree_parent_relative_path(row.path), true) }
		items[index] = alikit_tree.Item{
			id=workspace_tree_item_id(row.path, row.is_dir),
			parent_id=parent_id,
			label=row.name,
			depth=row.depth,
			expandable=row.is_dir,
			expanded=row.expanded,
		}
	}
	return alikit_tree.Window{
		total_count=len(items),
		revision=workspace_tree_projection_revision(app, rows),
		items=items,
	}
}

workspace_tree_projection_revision :: proc(app: ^App, rows: []Tree_Row) -> u64 {
	if app == nil { return 0 }
	hash: u64 = 14_695_981_039_346_656_037
	for row in rows {
		hash = (hash ~ u64(workspace_tree_item_id(row.path, row.is_dir))) * 1_099_511_628_211
		parent_id: u64
		if row.depth > 0 {
			parent_id = u64(workspace_tree_item_id(tree_parent_relative_path(row.path), true))
		}
		hash = (hash ~ parent_id) * 1_099_511_628_211
		hash = (hash ~ u64(row.depth)) * 1_099_511_628_211
		hash = (hash ~ (1 if row.expanded else 0)) * 1_099_511_628_211
	}
	if hash == 0 { hash = 1 }
	if app.workspace_tree_projection_signature != hash {
		app.workspace_tree_projection_signature = hash
		app.workspace_tree_projection_revision += 1
		if app.workspace_tree_projection_revision == 0 { app.workspace_tree_projection_revision = 1 }
	}
	return app.workspace_tree_projection_revision
}

workspace_tree_options :: proc(callback_data: rawptr, restore: alicorn.Scroll_Restore_Request) -> alikit_tree.Options {
	return alikit_tree.Options{
		accessible_label="Workspace files",
		empty_label="This workspace has no visible files.",
		loading_label="Loading workspace…",
		row_height=TREE_ROW_HEIGHT,
		row_padding=TREE_ROW_PADDING,
		row_gap=TREE_ROW_GAP,
		indent_width=TREE_INDENT_WIDTH-TREE_ROW_GAP,
		icon_size=TREE_TYPE_ICON_SIZE,
		semantic_namespace=TREE_SEMANTIC_NAMESPACE,
		scroll_restore=restore,
		icon_proc=workspace_tree_icon_proc,
		label_color_proc=workspace_tree_label_color_proc,
		row_hook_proc=workspace_tree_row_hook,
		label_paint_proc=workspace_tree_label_paint_proc,
		callback_data=callback_data,
		hide_disclosure=true,
		selection_enabled=true,
		select_on_focus=true,
		context_menu_enabled=true,
	}
}

workspace_tree_row_for_id :: proc(rows: []Tree_Row, id: alikit_tree.Item_ID) -> (row: Tree_Row, index: int, found: bool) {
	for candidate, candidate_index in rows {
		if workspace_tree_item_id(candidate.path, candidate.is_dir) == id {
			return candidate, candidate_index, true
		}
	}
	return
}

workspace_tree_icon_proc :: proc(_data: rawptr, item: alikit_tree.Item) -> alicorn.Icon_ID {
	if !item.expandable { return .File }
	if item.expanded { return .Folder_Open }
	return .Folder_Closed
}

workspace_tree_label_color_proc :: proc(data: rawptr, ctx: ^alicorn.UI, item: alikit_tree.Item) -> alicorn.Color {
	callbacks := cast(^Workspace_Tree_Callback_Data)data
	if callbacks == nil || ctx == nil { return {} }
	row, _, found := workspace_tree_row_for_id(callbacks.rows, item.id)
	if !found || !callbacks.has_active_document || row.is_dir ||
	   !tree_path_is_workspace_entry(callbacks.app.tree_root_path, row.path, callbacks.active_document_path) {
		return alicorn.style_color(ctx, .Text)
	}
	return alicorn.style_contrast_fallback(
		alicorn.style_color(ctx, .Accent),
		alicorn.style_color(ctx, .Subtle_Surface),
		4.5,
	)
}

workspace_tree_label_paint_proc :: proc(data: rawptr, ctx: ^alicorn.UI, item: alikit_tree.Item, label_node: alicorn.Node_ID) {
	callbacks := cast(^Workspace_Tree_Callback_Data)data
	if callbacks == nil || ctx == nil || ctx.runtime == nil || label_node == 0 { return }
	row, _, found := workspace_tree_row_for_id(callbacks.rows, item.id)
	if !found || !callbacks.has_active_document || row.is_dir ||
	   !tree_path_is_workspace_entry(callbacks.app.tree_root_path, row.path, callbacks.active_document_path) { return }
	accessibility := alicorn.style_root_accessibility_observation_get(ctx.runtime).preferences
	if accessibility.differentiate_without_color {
		spans := make([]alicorn.Text_Paint_Span, 1, allocator=alicorn.runtime_scratch_allocator(ctx.runtime))
		spans[0] = alicorn.Text_Paint_Span{start=0, end=len(item.label), underline=true}
		_ = alicorn.text_paint_spans(ctx, label_node, spans[:])
	}
}

workspace_tree_row_hook :: proc(_data: rawptr, ctx: ^alicorn.UI, item: alikit_tree.Item, semantic: alicorn.Semantic_ID) {
	_ = alicorn.drag_source(ctx, SCRATCHPAD_DRAG_WORKSPACE, semantic)
	if item.expandable { _ = alicorn.drop_target(ctx, SCRATCHPAD_DRAG_WORKSPACE, semantic, .On) }
}

workspace_tree_handle_key :: proc(app: ^App, rt: ^alicorn.Runtime, key: host.Application_Key) -> bool {
	if app == nil || rt == nil || app.tree_scroll_owner == 0 { return false }
	rows := make([dynamic]Tree_Row, 0, allocator=context.temp_allocator)
	defer delete(rows)
	tree_flatten_directory(app, "", 0, &rows)
	window := workspace_tree_window(app, rows[:])
	handled, event := alikit_tree.handle_key(
		&app.workspace_tree_state, rt, window, key,
		workspace_tree_options(nil, alicorn.Scroll_Restore_Request{}),
	)
	if handled { workspace_tree_apply_event(app, rt, rows[:], event, true) }
	return handled
}

workspace_tree_pointer :: proc(app: ^App, rt: ^alicorn.Runtime, event: alicorn.Pointer_Event, target: alicorn.Node_ID) -> bool {
	if app == nil || rt == nil || app.tree_scroll_owner == 0 ||
	   event.kind != .Down || event.button != alicorn.POINTER_BUTTON_SECONDARY { return false }
	rows := make([dynamic]Tree_Row, 0, allocator=context.temp_allocator)
	defer delete(rows)
	tree_flatten_directory(app, "", 0, &rows)
	window := workspace_tree_window(app, rows[:])
	options := workspace_tree_options(nil, alicorn.Scroll_Restore_Request{})
	handled, result := alikit_tree.pointer(
		&app.workspace_tree_state, rt, window, event, target, options,
	)
	if !handled {
		// Hit testing can report the label or icon child. Resolve its realized
		// Tree_Item owner, then let AliKit perform the normal focus, selection,
		// and context-menu transition on that owner.
		for row, index in rows {
			node, found := alicorn.semantic_node_lookup(rt, tree_semantic_id(row.path, row.is_dir))
			if !found || !node.has_bounds || node.visual_node == 0 ||
			   event.x < node.bounds.x || event.x >= node.bounds.x+node.bounds.w ||
			   event.y < node.bounds.y || event.y >= node.bounds.y+node.bounds.h {
				continue
			}
			handled, result = alikit_tree.pointer(
				&app.workspace_tree_state, rt, window, event, node.visual_node, options,
			)
			if handled { break }
		}
	}
	if !handled { return false }
	workspace_tree_apply_event(app, rt, rows[:], result, true)
	return true
}

workspace_tree_open_context_menu_focused :: proc(app: ^App, rt: ^alicorn.Runtime) -> bool {
	return workspace_tree_handle_key(app, rt, .Context_Menu)
}

workspace_tree_apply_event :: proc(
	app: ^App, rt: ^alicorn.Runtime, rows: []Tree_Row, event: alikit_tree.Event, menu_already_open: bool,
) {
	if app == nil || rt == nil || event.id == 0 { return }
	row, index, found := workspace_tree_row_for_id(rows, event.id)
	if !found { return }
	switch event.kind {
	case .Focus_Changed:
		tree_set_focused_row(app, rt, row, index)
	case .Pressed, .Activated:
		tree_set_focused_row(app, rt, row, index)
		tree_activate_row(app, rt, row)
	case .Expand_Requested:
		tree_set_focused_row(app, rt, row, index)
		if tree_load_directory(app, row.path, true) { alicorn.invalidate_root(rt, "Scratchpad workspace tree expanded") }
	case .Collapse_Requested:
		tree_set_focused_row(app, rt, row, index)
		if directory_index := tree_directory_index(app, row.path); directory_index >= 0 {
			app.tree_directories[directory_index].expanded = false
			alicorn.invalidate_root(rt, "Scratchpad workspace tree collapsed")
		}
	case .Parent_Focus_Requested:
		tree_set_focused_row(app, rt, row, index)
	case .Context_Menu_Requested:
		_ = workspace_context_menu_set_target(
			app, rt,
			Workspace_Tree_Row_Target{node=app.tree_scroll_owner, path=row.path, is_dir=row.is_dir, index=index},
			alikit_tree.context_anchor(&app.workspace_tree_state), menu_already_open,
		)
	case .None:
		return
	case .Range_Requested:
		// Scratchpad supplies its complete flattened row projection, so AliKit
		// has no unloaded range for the filesystem adapter to request here.
		return
	}
}

// tree_path_is_workspace_entry compares an absolute document path with a
// workspace-relative tree path without allocating a joined or relative path.
tree_path_is_workspace_entry :: proc(root, relative, absolute: string) -> bool {
	root_index, relative_index, absolute_index := 0, 0, 0
	for {
		root_start, root_end, root_next, root_found := tree_path_next_segment(root, root_index)
		if !root_found { break }
		absolute_start, absolute_end, absolute_next, absolute_found := tree_path_next_segment(absolute, absolute_index)
		if !absolute_found || !tree_path_segments_equal(root[root_start:root_end], absolute[absolute_start:absolute_end]) {
			return false
		}
		root_index, absolute_index = root_next, absolute_next
	}
	for {
		relative_start, relative_end, relative_next, relative_found := tree_path_next_segment(relative, relative_index)
		if !relative_found { break }
		absolute_start, absolute_end, absolute_next, absolute_found := tree_path_next_segment(absolute, absolute_index)
		if !absolute_found || !tree_path_segments_equal(relative[relative_start:relative_end], absolute[absolute_start:absolute_end]) {
			return false
		}
		relative_index, absolute_index = relative_next, absolute_next
	}
	_, _, _, absolute_has_more := tree_path_next_segment(absolute, absolute_index)
	return !absolute_has_more
}

tree_path_next_segment :: proc(path: string, index: int) -> (start, end, next: int, found: bool) {
	next = index
	for next < len(path) && (path[next] == '/' || path[next] == '\\') { next += 1 }
	if next >= len(path) { return }
	start = next
	for next < len(path) && path[next] != '/' && path[next] != '\\' { next += 1 }
	end = next
	return start, end, next, true
}

tree_path_segments_equal :: proc(a, b: string) -> bool {
	when ODIN_OS == .Windows {
		return strings.equal_fold(a, b)
	} else {
		return a == b
	}
}

tree_sync_workspace :: proc(app: ^App, rt: ^alicorn.Runtime = nil) {
	if app == nil || !app.backend.started { return }
	workspace_root := app.backend.state.workspace_root if app.backend.state.has_workspace else ""
	if app.tree_root_path == workspace_root && (workspace_root == "" || tree_directory_index(app, "") >= 0) { return }
	workspace_changed := app.tree_root_path != workspace_root
	if workspace_changed {
		app.workspace_tree_state = {}
		app.workspace_tree_projection_signature = 0
		app.workspace_tree_projection_revision = 0
		session_ui_workspace_changed(app, rt)
	}
	tree_clear_directories(app)
	delete(app.tree_directories)
	app.tree_directories = {}
	if len(app.tree_root_path) > 0 { delete(app.tree_root_path, context.allocator) }
	app.tree_root_path, _ = strings.clone(workspace_root, context.allocator)
	tree_clear_focused_path(app)
	if rt != nil { _ = alicorn.semantic_focus_clear(rt) }
	if workspace_root != "" {
		_ = tree_load_directory(app, "", true)
	}
}

tree_load_directory :: proc(app: ^App, relative_path: string, expanded := true) -> bool {
	if app == nil || !app.backend.started || !app.backend.state.has_workspace { return false }
	if index := tree_directory_index(app, relative_path); index >= 0 {
		app.tree_directories[index].expanded = expanded
		return true
	}
	response := bridge.backend_command(&app.backend, "list_directory", relative_path=relative_path, include_ignored=app.show_ignored_files)
	if !response.ok {
		set_error(app, response.message if response.message != "" else "Could not load this folder.")
		bridge.backend_command_result_destroy(&response, context.allocator)
		return false
	}
	if !response.directory_listing_owned || response.directory_listing.relative_path != relative_path {
		set_error(app, "Scratchpad returned an incomplete directory listing.")
		bridge.backend_command_result_destroy(&response, context.allocator)
		return false
	}
	stored := tree_store_listing(app, response.directory_listing, expanded)
	bridge.backend_command_result_destroy(&response, context.allocator)
	if !stored { set_error(app, "Could not retain this folder listing.") }
	return stored
}

// Changing ignore visibility reloads expanded directories that remain visible
// under the new policy. Expanded subtrees hidden by the toggle keep their last
// listing so they can be restored when ignored entries become visible again.
tree_set_show_ignored_files :: proc(app: ^App, rt: ^alicorn.Runtime, enabled: bool) {
	if app == nil || app.show_ignored_files == enabled { return }
	old_directories := app.tree_directories
	app.tree_directories = make([dynamic]Tree_Directory, 0, allocator=context.allocator)
	app.show_ignored_files = enabled
	_ = tree_load_directory(app, "", true)
	preserved_hidden_paths := make([dynamic]string, 0, allocator=context.temp_allocator)
	defer delete(preserved_hidden_paths)
	for old_directory, old_index in old_directories {
		if !old_directory.expanded || old_directory.path == "" { continue }
		parent_path := tree_parent_relative_path(old_directory.path)
		parent_hidden := tree_path_in_list(preserved_hidden_paths[:], parent_path)
		parent_visible := tree_directory_has_entry(app, parent_path, old_directory.path)
		if parent_hidden || !parent_visible {
			append(&app.tree_directories, old_directory)
			old_directories[old_index] = {}
			append(&preserved_hidden_paths, old_directory.path)
		} else {
			_ = tree_load_directory(app, old_directory.path, true)
		}
	}
	for &directory in old_directories { tree_directory_destroy(&directory) }
	delete(old_directories)
	rows := make([dynamic]Tree_Row, 0, allocator=context.temp_allocator)
	defer delete(rows)
	tree_flatten_directory(app, "", 0, &rows)
	focus_restored := false
	for row, index in rows {
		if row.path == app.tree_focused_path && row.is_dir == app.tree_focused_is_dir {
			tree_set_focused_row(app, rt, row, index)
			focus_restored = true
			break
		}
	}
	if len(app.tree_focused_path) > 0 && !focus_restored {
		tree_clear_focused_path(app)
		_ = alicorn.semantic_focus_clear(rt)
	}
	alicorn.invalidate_root(rt, "Scratchpad ignored-file visibility changed")
}

tree_parent_relative_path :: proc(path: string) -> string {
	last_separator := -1
	for index in 0..<len(path) {
		if path[index] == '/' || path[index] == '\\' { last_separator = index }
	}
	if last_separator < 0 { return "" }
	return path[:last_separator]
}

tree_path_in_list :: proc(paths: []string, target: string) -> bool {
	for path in paths { if path == target { return true } }
	return false
}

tree_directory_has_entry :: proc(app: ^App, directory_path, entry_path: string) -> bool {
	index := tree_directory_index(app, directory_path)
	if index < 0 { return false }
	for entry in app.tree_directories[index].entries {
		if entry.path == entry_path { return true }
	}
	return false
}

tree_store_listing :: proc(app: ^App, listing: bridge.Directory_Listing, expanded: bool) -> bool {
	directory := Tree_Directory{truncated=listing.truncated, expanded=expanded}
	clone_error: mem.Allocator_Error
	directory.path, clone_error = strings.clone(listing.relative_path, context.allocator)
	if clone_error != nil { tree_directory_destroy(&directory); return false }
	directory.entries = make([]bridge.Directory_Entry, len(listing.entries), allocator=context.allocator)
	for entry, i in listing.entries {
		directory.entries[i].name, clone_error = strings.clone(entry.name, context.allocator)
		if clone_error != nil { tree_directory_destroy(&directory); return false }
		directory.entries[i].path, clone_error = strings.clone(entry.path, context.allocator)
		if clone_error != nil { tree_directory_destroy(&directory); return false }
		directory.entries[i].dir = entry.dir
	}
	if index := tree_directory_index(app, listing.relative_path); index >= 0 {
		tree_directory_destroy(&app.tree_directories[index])
		app.tree_directories[index] = directory
	} else {
		append(&app.tree_directories, directory)
	}
	return true
}

tree_clear_directories :: proc(app: ^App) {
	if app == nil { return }
	for &directory in app.tree_directories { tree_directory_destroy(&directory) }
	delete(app.tree_directories)
	app.tree_directories = make([dynamic]Tree_Directory, 0, allocator=context.allocator)
}

tree_directory_destroy :: proc(directory: ^Tree_Directory) {
	if directory == nil { return }
	delete(directory.path, context.allocator)
	for &entry in directory.entries {
		delete(entry.name, context.allocator)
		delete(entry.path, context.allocator)
	}
	delete(directory.entries, context.allocator)
	directory^ = {}
}

tree_clear_focused_path :: proc(app: ^App) {
	if app == nil { return }
	if len(app.tree_focused_path) > 0 { delete(app.tree_focused_path, context.allocator) }
	app.tree_focused_path = ""
	app.tree_focused_is_dir = false
}

tree_directory_index :: proc(app: ^App, path: string) -> int {
	if app == nil { return -1 }
	for directory, index in app.tree_directories {
		if directory.path == path { return index }
	}
	return -1
}

tree_flatten_directory :: proc(app: ^App, path: string, depth: int, rows: ^[dynamic]Tree_Row) {
	if app == nil || rows == nil || depth > 64 { return }
	index := tree_directory_index(app, path)
	if index < 0 { return }
	directory := app.tree_directories[index]
	for entry in directory.entries {
		child_index := tree_directory_index(app, entry.path)
		expanded := entry.dir && child_index >= 0 && app.tree_directories[child_index].expanded
		append(rows, Tree_Row{name=entry.name, path=entry.path, depth=depth, is_dir=entry.dir, expanded=expanded})
		if expanded { tree_flatten_directory(app, entry.path, depth+1, rows) }
	}
}

tree_any_truncated :: proc(app: ^App) -> bool {
	if app == nil { return false }
	for directory in app.tree_directories { if directory.truncated { return true } }
	return false
}

tree_semantic_id :: proc(path: string, is_directory: bool) -> alicorn.Semantic_ID {
	hash: u64 = 14_695_981_039_346_656_037
	hash = (hash ~ (1 if is_directory else 2)) * 1_099_511_628_211
	for character in path { hash = (hash ~ u64(character)) * 1_099_511_628_211 }
	if hash == 0 { hash = 1 }
	return alicorn.Semantic_ID{namespace=TREE_SEMANTIC_NAMESPACE, value=hash}
}

tree_set_focused_row :: proc(app: ^App, rt: ^alicorn.Runtime, row: Tree_Row, index: int) {
	if app == nil || rt == nil { return }
	if len(app.tree_focused_path) > 0 { delete(app.tree_focused_path, context.allocator) }
	app.tree_focused_path, _ = strings.clone(row.path, context.allocator)
	app.tree_focused_is_dir = row.is_dir
	_ = alicorn.focus(rt, app.tree_scroll_owner)
	_ = alicorn.semantic_focus_set(rt, tree_semantic_id(row.path, row.is_dir), app.tree_scroll_owner)
	_ = alicorn.virtual_list_ensure_visible(rt, app.tree_scroll_owner, index, "Scratchpad tree keyboard focus moved")
}

tree_activate_row :: proc(app: ^App, rt: ^alicorn.Runtime, row: Tree_Row) {
	if app == nil || rt == nil { return }
	rows := make([dynamic]Tree_Row, 0, allocator=context.temp_allocator)
	defer delete(rows)
	tree_flatten_directory(app, "", 0, &rows)
	row_index := -1
	for candidate, index in rows {
		if candidate.path == row.path && candidate.is_dir == row.is_dir { row_index = index; break }
	}
	tree_set_focused_row(app, rt, row, row_index)
	if row.is_dir {
		if row.expanded {
			if child_index := tree_directory_index(app, row.path); child_index >= 0 { app.tree_directories[child_index].expanded = false }
		} else {
			_ = tree_load_directory(app, row.path, true)
		}
		alicorn.invalidate_root(rt, "Scratchpad workspace directory toggled")
		return
	}
	absolute_path, path_error := os.join_path({app.tree_root_path, row.path}, context.allocator)
	if path_error != nil {
		set_error(app, "Could not resolve the workspace file path.")
		alicorn.invalidate_root(rt, "Scratchpad workspace path resolution failed")
		return
	}
	if app.workspace_search_mode {
		if !workspace_search_deactivate(app, rt) {
			delete(absolute_path, context.allocator)
			return
		}
	}
	if len(app.editor_edits) > 0 {
		queued := deferred_action_enqueue(app, .Open_Path, path=absolute_path, disposition="preview")
		delete(absolute_path, context.allocator)
		if !queued { set_error(app, "Could not queue the file open behind pending edits.") }
		alicorn.invalidate_root(rt, "workspace file open queued behind editor edits")
		return
	}
	response := bridge.backend_command(&app.backend, "open_path", path=absolute_path, disposition="preview")
	delete(absolute_path, context.allocator)
	handle_command_result(app, rt, &response)
	bridge.backend_command_result_destroy(&response, context.allocator)
}
