package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"
import bridge "./bridge"

TREE_SEMANTIC_NAMESPACE :: u64(0x5343524154434850)
TREE_ROW_HEIGHT :: 28
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
		alicorn.container_begin(ui, .Container, label="workspace-tree-empty", style=alicorn.layout_style(grow=1, padding=12), color=COLOR_SUBTLE)
		alicorn.text(ui, "Open a folder to browse files.")
		alicorn.container_end(ui)
		return
	}
	root_index := tree_directory_index(app, "")
	if root_index < 0 {
		alicorn.container_begin(ui, .Container, label="workspace-tree-loading", style=alicorn.layout_style(grow=1, padding=12), color=COLOR_SUBTLE)
		alicorn.text(ui, "Loading workspace…")
		alicorn.container_end(ui)
		return
	}

	rows := make([dynamic]Tree_Row, 0, allocator=context.temp_allocator)
	defer delete(rows)
	tree_flatten_directory(app, "", 0, &rows)
	list := alicorn.virtual_list_begin(
		ui,
		len(rows),
		TREE_ROW_HEIGHT,
		key=alicorn.key_string(TREE_SCROLL_KEY),
		style=alicorn.layout_style(grow=1, clip=true),
		label="scratchpad-workspace-tree",
		focusable=true,
	)
	app.tree_scroll_owner = list.scroll.id
	_ = alicorn.drop_target(ui, SCRATCHPAD_DRAG_WORKSPACE, tree_semantic_id("", true), .On)
	focus_state := alicorn.semantic_focus_state(rt)
	for position := list.first; position < list.last; position += 1 {
		row := rows[position]
		indent, _ := strings.repeat("  ", row.depth, context.temp_allocator)
		marker := "   "
		if row.is_dir { marker = ">  "; if row.expanded { marker = "v  " } }
		label := fmt.tprintf("%s%s%s", indent, marker, row.name)
		semantic_id := tree_semantic_id(row.path, row.is_dir)
		selected := focus_state.id == semantic_id
		clicked := alicorn.button(
			ui,
			label,
			key=alicorn.key_string(row.path),
			style=alicorn.layout_style(.Row, height=TREE_ROW_HEIGHT),
			state=alicorn.Button_State{selected=selected},
			content_style=alicorn.button_content_style(.Start, padding_x=8),
		)
		_ = alicorn.semantic_bind(ui, semantic_id)
		_ = alicorn.drag_source(ui, SCRATCHPAD_DRAG_WORKSPACE, semantic_id)
		if row.is_dir { _ = alicorn.drop_target(ui, SCRATCHPAD_DRAG_WORKSPACE, semantic_id, .On) }
		if clicked { tree_activate_row(app, rt, row) }
	}
	alicorn.virtual_list_end(ui, list)
	if tree_any_truncated(app) {
		alicorn.text(ui, "Some folders show only the first 200 entries.")
	}
}

tree_sync_workspace :: proc(app: ^App, rt: ^alicorn.Runtime = nil) {
	if app == nil || !app.backend.started { return }
	workspace_root := app.backend.state.workspace_root if app.backend.state.has_workspace else ""
	if app.tree_root_path == workspace_root && (workspace_root == "" || tree_directory_index(app, "") >= 0) { return }
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

tree_move_focus :: proc(app: ^App, rt: ^alicorn.Runtime, key: host.Application_Key) -> bool {
	rows := make([dynamic]Tree_Row, 0, allocator=context.temp_allocator)
	defer delete(rows)
	tree_flatten_directory(app, "", 0, &rows)
	if len(rows) == 0 { return false }
	current := -1
	for row, index in rows {
		if row.path == app.tree_focused_path && row.is_dir == app.tree_focused_is_dir { current = index; break }
	}
	next := current
	#partial switch key {
	case .Up: next -= 1
	case .Down: next += 1
	case .Page_Up, .Page_Down:
		page := 8
		if metrics := alicorn.scroll_region_state(rt, app.tree_scroll_owner); metrics.viewport_bounds.h > 0 {
			page = max(1, int(metrics.viewport_bounds.h/f32(TREE_ROW_HEIGHT))-1)
		}
		if key == .Page_Up { next -= page } else { next += page }
	case .Home: next = 0
	case .End: next = len(rows)-1
	case: return false
	}
	if next < 0 { next = 0 }
	if next >= len(rows) { next = len(rows)-1 }
	if next == current { return true }
	tree_set_focused_row(app, rt, rows[next], next)
	alicorn.invalidate_root(rt, "Scratchpad workspace tree keyboard navigation")
	return true
}

tree_activate_focused :: proc(app: ^App, rt: ^alicorn.Runtime) -> bool {
	rows := make([dynamic]Tree_Row, 0, allocator=context.temp_allocator)
	defer delete(rows)
	tree_flatten_directory(app, "", 0, &rows)
	for row in rows {
		if row.path == app.tree_focused_path && row.is_dir == app.tree_focused_is_dir {
			tree_activate_row(app, rt, row)
			return true
		}
	}
	return false
}
