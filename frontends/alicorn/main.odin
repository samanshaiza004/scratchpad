package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"
import bridge "./bridge"

COLOR_BACKGROUND :: alicorn.Color{0.055, 0.065, 0.09, 1}
COLOR_PANEL      :: alicorn.Color{0.08, 0.095, 0.13, 1}
COLOR_SUBTLE     :: alicorn.Color{0.10, 0.12, 0.16, 1}

ACTION_FILE_OPEN       :: "file.open"
ACTION_WORKSPACE_OPEN  :: "workspace.open"
ACTION_FILE_SAVE       :: "file.save"
ACTION_DOCUMENT_CLOSE  :: "document.close"
ACTION_TAB_NEXT        :: "tab.next"
ACTION_TAB_PREVIOUS    :: "tab.previous"
ACTION_WORKSPACE_REFRESH :: "workspace.refresh"
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

App :: struct {
	backend:                bridge.Backend,
	waker:                  host.Application_Waker,
	services:               host.Application_Services,
	workspace_path:         string,
	backend_library:        string,
	error_message:          string,
	close_document_id:      string,
	tree_root_path:         string,
	tree_directories:       [dynamic]Tree_Directory,
	tree_focused_path:      string,
	tree_focused_is_dir:    bool,
	tree_scroll_owner:      alicorn.Node_ID,
	dialog_sequence:        u64,
	dialog_action:          string,
	file_items:             [5]host.Application_Menu_Item,
	workspace_items:        [1]host.Application_Menu_Item,
	document_items:         [2]host.Application_Menu_Item,
	menus:                  [3]host.Application_Menu,
	smoke:                  bool,
	smoke_rendered:         bool,
	smoke_wake_observed:    bool,
	smoke_shutdown:         bool,
}

build_app :: proc(
	state: rawptr,
	rt: ^alicorn.Runtime,
	logical_width, logical_height: int,
	dpi_scale: f32,
) -> alicorn.Node_ID {
	app := cast(^App)state
	ui, should_build := alicorn.begin_frame(rt)
	if !should_build { return 0 }
	if app.backend.started {
		sync_runtime_actions(app, rt)
		sync_menu_states(app)
	}

	root := alicorn.container_begin(
		&ui,
		.Root,
		label="scratchpad-alicorn-workbench",
		style=alicorn.layout_style(.Column, grow=1, padding=18, gap=12, clip=true),
		color=COLOR_BACKGROUND,
	)

	status := "Backend stopped"
	if app.backend.started { status = "Backend running" }
	alicorn.container_begin(&ui, .Container, label="workbench-title-row", style=alicorn.layout_style(.Row, height=34, gap=10, align=.Center))
	alicorn.text(&ui, "Scratchpad")
	alicorn.text(&ui, "Alicorn · Workbench shell")
	alicorn.container_begin(&ui, .Container, label="title-row-spacer", style=alicorn.layout_style(.Row, grow=1))
	alicorn.container_end(&ui)
	alicorn.text(&ui, status)
	if app.backend.started {
		if alicorn.button(&ui, "Stop", key=alicorn.key_string("backend-stop"), style=alicorn.layout_style(.Row, width=76, height=32)) {
			disable_runtime_actions(app, rt)
			stopped, message := bridge.backend_stop(&app.backend)
			sync_menu_states(app)
			if stopped { set_error(app, "") } else { set_error(app, message) }
			alicorn.invalidate_root(rt, "Scratchpad backend stopped from diagnostic control")
		}
	} else {
		if alicorn.button(&ui, "Start", key=alicorn.key_string("backend-start"), style=alicorn.layout_style(.Row, width=76, height=32)) {
			start_backend(app)
			alicorn.invalidate_root(rt, "Scratchpad backend started from diagnostic control")
		}
	}
	alicorn.container_end(&ui)

	if app.error_message != "" {
		alicorn.container_begin(&ui, .Container, label="workbench-error", style=alicorn.layout_style(.Column, height=132, padding=9, gap=2), color=alicorn.Color{0.28, 0.11, 0.12, 1})
		alicorn.text(&ui, "Scratchpad backend could not be loaded.")
		alicorn.text(&ui, "Place the backend library beside scratchpad-alicorn, or set SCRATCHPAD_BACKEND_LIBRARY.")
		alicorn.text(&ui, app.error_message)
		alicorn.container_end(&ui)
	}

	if app.backend.started {
		state := &app.backend.state
		alicorn.container_begin(&ui, .Container, label="workbench-toolbar", style=alicorn.layout_style(.Row, height=38, gap=8, align=.Center))
		if alicorn.button(&ui, "Open File…", key=alicorn.key_string("action-file-open"), style=alicorn.layout_style(.Row, width=130, height=34)) {
			dispatch_action(app, rt, ACTION_FILE_OPEN)
		}
		if alicorn.button(&ui, "Open Folder…", key=alicorn.key_string("action-workspace-open"), style=alicorn.layout_style(.Row, width=140, height=34)) {
			dispatch_action(app, rt, ACTION_WORKSPACE_OPEN)
		}
		if save_enabled := action_enabled(state, ACTION_FILE_SAVE); alicorn.button(&ui, "Save", key=alicorn.key_string("action-file-save"), style=alicorn.layout_style(.Row, width=84, height=34), state=alicorn.Button_State{disabled=!save_enabled}) {
			dispatch_action(app, rt, ACTION_FILE_SAVE)
		}
		if close_enabled := action_enabled(state, ACTION_DOCUMENT_CLOSE); alicorn.button(&ui, "Close", key=alicorn.key_string("action-document-close"), style=alicorn.layout_style(.Row, width=84, height=34), state=alicorn.Button_State{disabled=!close_enabled}) {
			dispatch_action(app, rt, ACTION_DOCUMENT_CLOSE)
		}
		alicorn.container_end(&ui)

		alicorn.container_begin(&ui, .Container, label="workbench-content", style=alicorn.layout_style(.Row, grow=1, gap=12, clip=true))
		alicorn.container_begin(&ui, .Container, label="files-sidebar", style=alicorn.layout_style(.Column, width=250, grow=0, padding=14, gap=12, clip=true), color=COLOR_PANEL)
		alicorn.text(&ui, "FILES")
		alicorn.text(&ui, state.workspace_root if state.has_workspace else "No workspace open")
		alicorn.text(&ui, fmt.tprintf("%d open documents", len(state.documents)))
		if alicorn.button(&ui, "Open Folder…", key=alicorn.key_string("sidebar-open-folder"), style=alicorn.layout_style(.Row, height=34)) {
			dispatch_action(app, rt, ACTION_WORKSPACE_OPEN)
		}
		if alicorn.button(&ui, "Refresh Workspace", key=alicorn.key_string("sidebar-refresh"), style=alicorn.layout_style(.Row, height=34), state=alicorn.Button_State{disabled=!action_enabled(state, ACTION_WORKSPACE_REFRESH)}) {
			dispatch_action(app, rt, ACTION_WORKSPACE_REFRESH)
		}
		build_workspace_tree(app, &ui, rt)
		alicorn.container_end(&ui)

		alicorn.container_begin(&ui, .Container, label="document-workbench", style=alicorn.layout_style(.Column, grow=1, gap=0, clip=true), color=COLOR_PANEL)
		alicorn.container_begin(&ui, .Container, label="document-tabs", style=alicorn.layout_style(.Row, height=42, gap=2, padding=5, clip=true), color=COLOR_SUBTLE)
		for document in state.documents {
			title := document_title(document.path)
			if document.preview && !document.dirty { title = fmt.tprintf("%s (preview)", title) }
			if document.dirty { title = fmt.tprintf("%s •", title) }
			selected := state.active == document.id
			if alicorn.button(&ui, title, key=alicorn.key_string(fmt.tprintf("tab:%s", document.id)), style=alicorn.layout_style(.Row, width=180, height=32), state=alicorn.Button_State{selected=selected}, content_style=alicorn.button_content_style(.Start, padding_x=10)) {
				select_document(app, rt, document.id)
			}
			if alicorn.button(&ui, "×", key=alicorn.key_string(fmt.tprintf("tab-close:%s", document.id)), style=alicorn.layout_style(.Row, width=30, height=32)) {
				request_close_document(app, rt, document.id)
			}
		}
		if len(state.documents) == 0 {
			alicorn.text(&ui, "No documents open")
		}
		alicorn.container_end(&ui)

		alicorn.container_begin(&ui, .Container, label="document-placeholder", style=alicorn.layout_style(.Column, grow=1, padding=28, gap=12, align=.Start), color=COLOR_PANEL)
		if active, found := find_document(state, state.active); found {
			alicorn.text(&ui, document_title(active.path))
			alicorn.text(&ui, fmt.tprintf("Language: %s", active.language))
			alicorn.text(&ui, fmt.tprintf("Status: %s", active.status))
			alicorn.text(&ui, fmt.tprintf("Dirty: %v", active.dirty))
			alicorn.text(&ui, fmt.tprintf("Editor revision: %d", active.editor_revision))
			alicorn.text(&ui, "The document editor is intentionally not part of Phase 2.")
		} else {
			alicorn.text(&ui, "Open a file to begin")
			alicorn.text(&ui, "Scratchpad state and document navigation are live; editing comes later.")
		}
		alicorn.container_end(&ui)
		alicorn.container_end(&ui)
		alicorn.container_end(&ui)
	} else {
		alicorn.container_begin(&ui, .Container, label="backend-stopped-card", style=alicorn.layout_style(.Column, grow=1, padding=24, gap=12), color=COLOR_PANEL)
		alicorn.text(&ui, "Start the shared Scratchpad backend to load real workspace and document state.")
		alicorn.container_end(&ui)
	}
	alicorn.container_end(&ui)

	if app.close_document_id != "" {
		alicorn.modal_overlay_begin(&ui, alicorn.key_string("dirty-close-overlay"), style=alicorn.layout_style(.Column, grow=1, align=.Center), backdrop_color=alicorn.Color{0.015, 0.02, 0.03, 0.72})
		alicorn.container_begin(&ui, .Container, label="dirty-close-dialog", style=alicorn.layout_style(.Column, width=440, height=190, padding=22, gap=14, align=.Start, clip=true), color=COLOR_PANEL)
		alicorn.text(&ui, "Save changes before closing?")
		if document, found := find_document(&app.backend.state, app.close_document_id); found {
			alicorn.text(&ui, document_title(document.path))
		}
		alicorn.container_begin(&ui, .Container, label="dirty-close-actions", style=alicorn.layout_style(.Row, height=38, gap=8, align=.Center))
		if alicorn.button(&ui, "Save & Close", key=alicorn.key_string("dirty-close-save"), style=alicorn.layout_style(.Row, width=130, height=34)) {
			close_after_save(app, rt)
		}
		if alicorn.button(&ui, "Discard", key=alicorn.key_string("dirty-close-discard"), style=alicorn.layout_style(.Row, width=100, height=34)) {
			close_with_discard(app, rt)
		}
		if alicorn.button(&ui, "Cancel", key=alicorn.key_string("dirty-close-cancel"), style=alicorn.layout_style(.Row, width=90, height=34)) {
			clear_close_prompt(app)
			alicorn.invalidate_root(rt, "dirty close cancelled")
		}
		alicorn.container_end(&ui)
		alicorn.container_end(&ui)
		alicorn.modal_overlay_end(&ui)
	}

	alicorn.end_frame(&ui)
	if app.smoke && app.backend.started && app.backend.state.revision > 0 { app.smoke_rendered = true }
	return root
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
			key=alicorn.key_string(fmt.tprintf("workspace-entry:%s", row.path)),
			style=alicorn.layout_style(.Row, height=TREE_ROW_HEIGHT),
			state=alicorn.Button_State{selected=selected},
			content_style=alicorn.button_content_style(.Start, padding_x=8),
		)
		_ = alicorn.semantic_bind(ui, semantic_id)
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
	response := bridge.backend_command(&app.backend, "list_directory", relative_path=relative_path)
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

start_backend :: proc(app: ^App) {
	if app == nil { return }
	loaded, load_error := bridge.backend_load(&app.backend, app.backend_library)
	if !loaded { set_error(app, load_error); return }
	started, start_error := bridge.backend_start(&app.backend, app.workspace_path, app.waker.wake, app.waker.data)
	if !started { set_error(app, start_error) } else {
		set_error(app, "")
		tree_sync_workspace(app)
	}
}

application_start :: proc(state: rawptr, waker: host.Application_Waker) {
	app := cast(^App)state
	app.waker = waker
	start_backend(app)
}

application_services :: proc(state: rawptr, services: host.Application_Services) {
	app := cast(^App)state
	app.services = services
}

application_wake :: proc(state: rawptr, rt: ^alicorn.Runtime) {
	app := cast(^App)state
	if !app.backend.started { return }
	app.smoke_wake_observed = true
	changed, ok, message := bridge.backend_consume_wake(&app.backend)
	if !ok { set_error(app, message); alicorn.invalidate_root(rt, "Scratchpad backend state read failed"); return }
	if changed {
		sync_runtime_actions(app, rt)
		sync_menu_states(app)
		tree_sync_workspace(app, rt)
		alicorn.invalidate_root(rt, "Scratchpad Caliber state publication")
	}
}

application_dialog :: proc(state: rawptr, rt: ^alicorn.Runtime, result: ^host.File_Dialog_Result) {
	app := cast(^App)state
	if result == nil { return }
	if result.status == .Error {
		app.dialog_action = ""
		set_error(app, result.error)
		alicorn.invalidate_root(rt, "Scratchpad native dialog failed")
		return
	}
	if result.status != .Accepted || len(result.paths) == 0 { app.dialog_action = ""; return }
	path := result.paths[0]
	if action, found := find_action(&app.backend.state, app.dialog_action); found {
		cause := alicorn.cause_begin(rt, .Application, "native file dialog selection", action_id_for(action.id))
		alicorn.trace_action(rt, action_id_for(action.id), action.title)
		response := bridge.backend_command(&app.backend, "open_path", path=path)
		handle_command_result(app, rt, &response)
		bridge.backend_command_result_destroy(&response, context.allocator)
		alicorn.cause_end(rt, cause)
	} else {
		set_error(app, "The file dialog completed without a matching Scratchpad action.")
		alicorn.invalidate_root(rt, "Scratchpad dialog action was unavailable")
	}
	app.dialog_action = ""
}

application_menu_command :: proc(state: rawptr, rt: ^alicorn.Runtime, command: host.Application_Command_ID) {
	app := cast(^App)state
	for action in app.backend.state.actions {
		if action_id_for(action.id) == command {
			dispatch_action(app, rt, action.id)
			return
		}
	}
}

dispatch_action :: proc(app: ^App, rt: ^alicorn.Runtime, action_id: string) {
	if app == nil || !app.backend.started { return }
	if !action_enabled(&app.backend.state, action_id) { return }
	entry, found := find_action(&app.backend.state, action_id)
	if !found { return }
	command_token := action_id_for(action_id)
	cause := alicorn.cause_begin(rt, .Application, "Scratchpad semantic action", command_token)
	alicorn.trace_action(rt, command_token, entry.title)
	switch action_id {
	case ACTION_FILE_OPEN:
		request_file_dialog(app, rt, .Open_File, "Open File")
	case ACTION_WORKSPACE_OPEN:
		request_file_dialog(app, rt, .Open_Folder, "Open Folder")
	case ACTION_FILE_SAVE:
		if app.backend.state.active != "" {
			response := bridge.backend_command(&app.backend, "save_document", document_id=app.backend.state.active)
			handle_command_result(app, rt, &response)
			bridge.backend_command_result_destroy(&response, context.allocator)
		}
	case ACTION_DOCUMENT_CLOSE:
		request_close_document(app, rt, app.backend.state.active)
	case ACTION_TAB_NEXT:
		navigate_tab(app, rt, 1)
	case ACTION_TAB_PREVIOUS:
		navigate_tab(app, rt, -1)
	case ACTION_WORKSPACE_REFRESH:
		response := bridge.backend_command(&app.backend, "refresh_workspace")
		if response.ok {
			tree_clear_directories(app)
			if response.directory_listing_owned {
				if !tree_store_listing(app, response.directory_listing, true) { set_error(app, "Could not retain the refreshed workspace listing.") }
			} else {
				set_error(app, "Scratchpad did not return the refreshed workspace listing.")
			}
			sync_runtime_actions(app, rt)
			sync_menu_states(app)
			alicorn.invalidate_root(rt, "Scratchpad workspace refreshed")
		} else {
			handle_command_result(app, rt, &response)
		}
		bridge.backend_command_result_destroy(&response, context.allocator)
	case:
		set_error(app, fmt.tprintf("Action %s is not available in the Alicorn shell yet", action_id))
		alicorn.invalidate_root(rt, "unavailable Scratchpad action")
	}
	alicorn.cause_end(rt, cause)
}

request_file_dialog :: proc(app: ^App, rt: ^alicorn.Runtime, kind: host.File_Dialog_Kind, title: string) {
	app.dialog_sequence += 1
	app.dialog_action = ACTION_FILE_OPEN if kind == .Open_File else ACTION_WORKSPACE_OPEN
	request := host.File_Dialog_Request{
		id=host.Dialog_ID(app.dialog_sequence),
		kind=kind,
		title=title,
		initial_location=app.backend.state.workspace_root,
		allow_many=false,
	}
	if !host.ShowFileDialog(app.services.dialogs, request) {
		set_error(app, "The native file dialog could not be opened.")
		alicorn.invalidate_root(rt, "Scratchpad native dialog request failed")
	}
}

application_key :: proc(state: rawptr, rt: ^alicorn.Runtime, key: host.Application_Key) -> bool {
	app := cast(^App)state
	if key == .Escape && app.close_document_id != "" {
		clear_close_prompt(app)
		alicorn.invalidate_root(rt, "dirty close cancelled by Escape")
		return true
	}
	if app.tree_scroll_owner != 0 && rt.focused == app.tree_scroll_owner {
		#partial switch key {
		case .Up, .Down, .Page_Up, .Page_Down, .Home, .End:
			return tree_move_focus(app, rt, key)
		case .Return:
			return tree_activate_focused(app, rt)
		case:
		}
	}
	return false
}

request_close_document :: proc(app: ^App, rt: ^alicorn.Runtime, document_id: string) {
	if document_id == "" { return }
	response := bridge.backend_command(&app.backend, "close_document", document_id=document_id)
	handle_command_result(app, rt, &response)
	bridge.backend_command_result_destroy(&response, context.allocator)
}

close_after_save :: proc(app: ^App, rt: ^alicorn.Runtime) {
	document_id, clone_err := strings.clone(app.close_document_id, context.allocator)
	if clone_err != nil { set_error(app, "Could not retain the pending document identity."); return }
	saved := bridge.backend_command(&app.backend, "save_document", document_id=document_id)
	if !saved.ok {
		handle_command_result(app, rt, &saved)
		bridge.backend_command_result_destroy(&saved, context.allocator)
		delete(document_id, context.allocator)
		return
	}
	bridge.backend_command_result_destroy(&saved, context.allocator)
	closed := bridge.backend_command(&app.backend, "close_document", document_id=document_id)
	handle_command_result(app, rt, &closed)
	bridge.backend_command_result_destroy(&closed, context.allocator)
	delete(document_id, context.allocator)
}

close_with_discard :: proc(app: ^App, rt: ^alicorn.Runtime) {
	response := bridge.backend_command(&app.backend, "close_document", document_id=app.close_document_id, discard=true)
	handle_command_result(app, rt, &response)
	bridge.backend_command_result_destroy(&response, context.allocator)
}

handle_command_result :: proc(app: ^App, rt: ^alicorn.Runtime, result: ^bridge.Backend_Command_Result) {
	if result == nil { return }
	if len(result.close_decision.document_id) > 0 && result.close_decision.dirty {
		clear_close_prompt(app)
		app.close_document_id, _ = strings.clone(result.close_decision.document_id, context.allocator)
		set_error(app, "")
		alicorn.invalidate_root(rt, "Scratchpad requested a dirty-close decision")
		return
	}
	if !result.ok {
		set_error(app, result.message)
		alicorn.invalidate_root(rt, "Scratchpad command failed")
		return
	}
	set_error(app, "")
	if result.state_changed {
		sync_runtime_actions(app, rt)
		sync_menu_states(app)
		tree_sync_workspace(app, rt)
		alicorn.invalidate_root(rt, "Scratchpad command published new state")
	}
	if app.close_document_id != "" && !document_is_open(&app.backend.state, app.close_document_id) {
		clear_close_prompt(app)
		alicorn.invalidate_root(rt, "Scratchpad closed prompted document")
	}
}

select_document :: proc(app: ^App, rt: ^alicorn.Runtime, document_id: string) {
	response := bridge.backend_command(&app.backend, "select_document", document_id=document_id)
	handle_command_result(app, rt, &response)
	bridge.backend_command_result_destroy(&response, context.allocator)
}

navigate_tab :: proc(app: ^App, rt: ^alicorn.Runtime, direction: int) {
	documents := app.backend.state.documents
	if len(documents) < 2 { return }
	index := 0
	for document, i in documents {
		if document.id == app.backend.state.active { index = i; break }
	}
	index = (index + direction + len(documents)) % len(documents)
	select_document(app, rt, documents[index].id)
}

sync_runtime_actions :: proc(app: ^App, rt: ^alicorn.Runtime) {
	for action in app.backend.state.actions {
		if action.id == "" || action.title == "" { continue }
		accepted := alicorn.action_update(rt,
			alicorn.Action_Descriptor{id=action_id_for(action.id), name=action.id, label=action.title},
			alicorn.Action_State{enabled=action.enabled, checked=action.checked},
		)
		if !accepted { set_error(app, fmt.tprintf("Alicorn rejected action metadata for %s", action.id)) }
	}
}

disable_runtime_actions :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil { return }
	for action in app.backend.state.actions {
		_ = alicorn.action_update(rt,
			alicorn.Action_Descriptor{id=action_id_for(action.id), name=action.id, label=action.title},
			alicorn.Action_State{enabled=false, checked=action.checked},
		)
	}
}

sync_menu_states :: proc(app: ^App) {
	for &item in app.file_items {
		if item.kind != .Command { continue }
		item.state = menu_action_state(&app.backend.state, item.command)
	}
	for &item in app.workspace_items {
		if item.kind != .Command { continue }
		item.state = menu_action_state(&app.backend.state, item.command)
	}
	for &item in app.document_items {
		if item.kind != .Command { continue }
		item.state = menu_action_state(&app.backend.state, item.command)
	}
}

menu_action_state :: proc(state: ^bridge.State_Envelope, id: host.Application_Command_ID) -> alicorn.Action_State {
	for action in state.actions {
		if action_id_for(action.id) == id { return alicorn.Action_State{enabled=action.visible && action.enabled, checked=action.checked} }
	}
	return alicorn.Action_State{}
}

action_enabled :: proc(state: ^bridge.State_Envelope, id: string) -> bool {
	for action in state.actions {
		if action.id == id { return action.visible && action.enabled }
	}
	return false
}

find_action :: proc(state: ^bridge.State_Envelope, id: string) -> (action: bridge.Action_State, found: bool) {
	for action in state.actions { if action.id == id { return action, true } }
	return
}

find_document :: proc(state: ^bridge.State_Envelope, id: string) -> (document: bridge.State_Document, found: bool) {
	for document in state.documents { if document.id == id { return document, true } }
	return
}

document_is_open :: proc(state: ^bridge.State_Envelope, id: string) -> bool {
	_, found := find_document(state, id)
	return found
}

document_title :: proc(path: string) -> string {
	start := 0
	for character, index in path {
		if character == '/' || character == '\\' { start = index + 1 }
	}
	if start >= len(path) { return path }
	return path[start:]
}

action_id_for :: proc(name: string) -> host.Application_Command_ID {
	hash: u32 = 2_166_136_261
	for character in name {
		hash = (hash ~ u32(character)) * 16_777_619
	}
	if hash == 0 { hash = 1 }
	return host.Application_Command_ID(hash)
}

set_error :: proc(app: ^App, message: string) {
	if app == nil { return }
	if len(app.error_message) > 0 { delete(app.error_message, context.allocator) }
	app.error_message = ""
	if len(message) > 0 { app.error_message, _ = strings.clone(message, context.allocator) }
}

clear_close_prompt :: proc(app: ^App) {
	if app == nil { return }
	if len(app.close_document_id) > 0 { delete(app.close_document_id, context.allocator) }
	app.close_document_id = ""
}

init_menus :: proc(app: ^App) {
	app.file_items = [5]host.Application_Menu_Item{
		{kind=.Command, command=action_id_for(ACTION_FILE_OPEN), label="Open File…", state=alicorn.Action_State{enabled=true}, shortcut=host.Application_Menu_Shortcut{'O', {.Primary}}},
		{kind=.Command, command=action_id_for(ACTION_WORKSPACE_OPEN), label="Open Folder…", state=alicorn.Action_State{enabled=true}},
		{kind=.Separator},
		{kind=.Command, command=action_id_for(ACTION_FILE_SAVE), label="Save", shortcut=host.Application_Menu_Shortcut{'S', {.Primary}}},
		{kind=.Command, command=action_id_for(ACTION_DOCUMENT_CLOSE), label="Close Document", shortcut=host.Application_Menu_Shortcut{'W', {.Primary}}},
	}
	app.workspace_items = [1]host.Application_Menu_Item{
		{kind=.Command, command=action_id_for(ACTION_WORKSPACE_REFRESH), label="Refresh Workspace", shortcut=host.Application_Menu_Shortcut{'R', {.Primary, .Shift}}},
	}
	app.document_items = [2]host.Application_Menu_Item{
		{kind=.Command, command=action_id_for(ACTION_TAB_NEXT), label="Next Document"},
		{kind=.Command, command=action_id_for(ACTION_TAB_PREVIOUS), label="Previous Document"},
	}
	app.menus = [3]host.Application_Menu{
		{label="File", items=app.file_items[:]},
		{label="Workspace", items=app.workspace_items[:]},
		{label="Document", items=app.document_items[:]},
	}
}

application_stop :: proc(state: rawptr) {
	app := cast(^App)state
	if app.backend.started {
		stopped, message := bridge.backend_stop(&app.backend)
		app.smoke_shutdown = stopped && !app.backend.started && app.backend.waiter.thread == nil && app.backend.state_leases == 0
		if !stopped { fmt.eprintln("Scratchpad backend shutdown error:", message) }
	} else {
		app.smoke_shutdown = true
	}
	tree_clear_directories(app)
	if len(app.tree_root_path) > 0 { delete(app.tree_root_path, context.allocator) }
	app.tree_root_path = ""
	tree_clear_focused_path(app)
	app.tree_scroll_owner = 0
}

main :: proc() {
	app: App
	app.tree_directories = make([dynamic]Tree_Directory, 0, allocator=context.allocator)
	init_menus(&app)
	if library, found := os.lookup_env("SCRATCHPAD_BACKEND_LIBRARY", context.allocator); found { app.backend_library = library }
	if workspace, found := os.lookup_env("SCRATCHPAD_ALICORN_WORKSPACE", context.allocator); found { app.workspace_path = workspace }
	if smoke, found := os.lookup_env("SCRATCHPAD_ALICORN_SMOKE", context.allocator); found { app.smoke = smoke == "1" || smoke == "true" }
	host.Run(host.Application{
		state=rawptr(&app),
		title="Scratchpad — Alicorn",
		width=1200,
		height=760,
		menus=app.menus[:],
		build=build_app,
		on_key=application_key,
		on_services=application_services,
		on_start=application_start,
		on_dialog=application_dialog,
		on_wake=application_wake,
		on_stop=application_stop,
		on_menu_command=application_menu_command,
	}, app.smoke)
	if app.smoke {
		passed := app.smoke_rendered && app.smoke_wake_observed && app.smoke_shutdown
		fmt.println("alicorn-smoke", "publication_rendered", app.smoke_rendered, "wake_observed", app.smoke_wake_observed, "ordered_shutdown", app.smoke_shutdown)
		if !passed { os.exit(1) }
	}
}
