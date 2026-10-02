package main

import "core:fmt"
import "core:os"
import "core:strings"
import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"
import bridge "./bridge"

Workspace_Mutation_Kind :: enum {
	None,
	Create_File,
	Create_Folder,
	Rename,
	Move,
	Trash,
}

Workspace_Document_Migration :: struct {
	old_id: string,
	new_path: string,
}

workspace_mutation_open_create :: proc(app: ^App, rt: ^alicorn.Runtime, kind: Workspace_Mutation_Kind) {
	if app == nil || rt == nil || !app.backend.state.has_workspace { return }
	parent := ""
	if app.tree_focused_path != "" {
		parent = app.tree_focused_path if app.tree_focused_is_dir else tree_parent_relative_path(app.tree_focused_path)
	}
	workspace_mutation_begin(app, rt, kind, parent, app.tree_focused_is_dir)
}

workspace_mutation_open_selected :: proc(app: ^App, rt: ^alicorn.Runtime, kind: Workspace_Mutation_Kind) {
	if app == nil || rt == nil || app.tree_focused_path == "" { return }
	workspace_mutation_begin(app, rt, kind, app.tree_focused_path, app.tree_focused_is_dir)
	if kind == .Rename {
		workspace_mutation_set_name(app, tree_basename(app.tree_focused_path))
	}
}

workspace_mutation_begin :: proc(app: ^App, rt: ^alicorn.Runtime, kind: Workspace_Mutation_Kind, source: string, source_is_dir: bool) {
	if app == nil || rt == nil { return }
	workspace_mutation_clear(app)
	app.workspace_mutation_restore_pending = false
	app.workspace_mutation_restore_editor = false
	app.workspace_mutation_restore_node = rt.focused
	app.workspace_mutation_restore_semantic = alicorn.semantic_focus_state(rt)
	source_copy, source_error := strings.clone(source, context.allocator)
	if source_error != nil {
		set_error(app, "Could not retain the selected workspace path.")
		alicorn.invalidate_root(rt, "Scratchpad could not retain workspace operation path")
		return
	}
	app.workspace_mutation_kind = kind
	app.workspace_mutation_source_is_dir = source_is_dir
	app.workspace_mutation_source = source_copy
	if kind == .Trash {
		app.workspace_mutation_dirty = false
	}
	app.workspace_mutation_focus_pending = true
	alicorn.invalidate_root(rt, "Scratchpad workspace operation opened")
}

workspace_mutation_handle_key :: proc(app: ^App, rt: ^alicorn.Runtime, key: host.Application_Key) -> bool {
	if app == nil || rt == nil || app.workspace_mutation_kind == .None { return false }
	#partial switch key {
	case .Escape:
		workspace_mutation_cancel(app, rt)
		return true
	case .Return:
		if app.workspace_mutation_kind != .Trash && !app.workspace_mutation_queued &&
		   app.workspace_mutation_name_node != 0 && rt.focused == app.workspace_mutation_name_node {
			workspace_mutation_submit(app, rt, false)
			return true
		}
		// A trash choice is always an explicit focused button, never a default
		// destructive action. Other dialog buttons keep normal Enter activation.
		return false
	case:
		// While the modal is open, mapped navigation/search/tree commands do not
		// leak through to the obscured editor or workspace tree. Tab traversal is
		// still handled by Alicorn's modal-scoped focus traversal.
		return true
	}
}

workspace_mutation_focus_after_frame :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil { return }
	if app.workspace_mutation_kind != .None && app.workspace_mutation_focus_pending {
		if app.workspace_mutation_queued || app.workspace_mutation_kind == .Trash {
			key := "workspace-mutation-cancel"
			if app.workspace_mutation_kind == .Trash { key = "workspace-trash-cancel" }
			for id, node in rt.nodes {
				if node.active && node.kind == .Button && node.key == key && alicorn.focus(rt, id) {
					app.workspace_mutation_focus_pending = false
					return
				}
			}
		} else if app.workspace_mutation_name_node != 0 && alicorn.focus(rt, app.workspace_mutation_name_node) {
			if app.workspace_mutation_kind == .Rename {
				if node, found := rt.nodes[app.workspace_mutation_name_node]; found {
					_ = alicorn.set_text_selection(rt, app.workspace_mutation_name_node, 0, workspace_mutation_stem_end(node.text))
				}
			}
			app.workspace_mutation_focus_pending = false
			return
		}
		return
	}
	if !app.workspace_mutation_restore_pending || app.workspace_mutation_kind != .None { return }
	target := app.workspace_mutation_restore_node
	semantic := app.workspace_mutation_restore_semantic
	if app.workspace_mutation_restore_editor {
		target = app.editor_scroll_owner
		semantic = {}
	} else if semantic.id.namespace != 0 && semantic.owner != 0 {
		target = semantic.owner
	}
	if target != 0 {
		if node, found := rt.nodes[target]; !found || !node.active { return }
		if !alicorn.focus(rt, target) { return }
	}
	if semantic.id.namespace != 0 && semantic.owner != 0 {
		_ = alicorn.semantic_focus_set(rt, semantic.id, semantic.owner)
	}
	app.workspace_mutation_restore_pending = false
	app.workspace_mutation_restore_editor = false
	app.workspace_mutation_restore_node = 0
	app.workspace_mutation_restore_semantic = {}
}

workspace_mutation_stem_end :: proc(name: string) -> int {
	last_dot := -1
	for index in 0..<len(name) { if name[index] == '.' { last_dot = index } }
	if last_dot > 0 { return last_dot }
	return len(name)
}

workspace_mutation_build_dialog :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime) {
	if app == nil || ui == nil || rt == nil { return }
	label := "Workspace operation"
	if app.workspace_mutation_kind == .Create_File { label = "New File" }
	if app.workspace_mutation_kind == .Create_Folder { label = "New Folder" }
	if app.workspace_mutation_kind == .Rename { label = "Rename" }
	if app.workspace_mutation_kind == .Move { label = "Move" }
	if app.workspace_mutation_kind == .Trash { label = "Move to Trash" }
	if app.workspace_mutation_kind == .Trash {
		alicorn.modal_overlay_begin(ui, alicorn.key_string("workspace-trash-overlay"), style=alicorn.layout_style(.Column, grow=1, align=.Center), backdrop_color=alicorn.Color{0.015, 0.02, 0.03, 0.72})
		alicorn.container_begin(ui, .Container, label="workspace-trash-dialog", style=alicorn.layout_style(.Column, width=500, height=220, padding=22, gap=12, align=.Start, clip=true), color=COLOR_PANEL)
		alicorn.text(ui, "Move this workspace item to the operating system Trash?")
		alicorn.text(ui, app.workspace_mutation_source)
		if app.workspace_mutation_queued {
			alicorn.text(ui, "Waiting for pending editor changes to finish…")
			if alicorn.button(ui, "Cancel", key=alicorn.key_string("workspace-trash-cancel"), style=alicorn.layout_style(.Row, width=88, height=34)) {
				workspace_mutation_cancel(app, rt)
			}
		} else if app.workspace_mutation_dirty {
			count := workspace_mutation_dirty_document_count(app)
			alicorn.text(ui, fmt.tprintf("%d open document(s) have unsaved changes.", count))
			if app.workspace_mutation_error != "" { alicorn.text(ui, app.workspace_mutation_error) }
			alicorn.container_begin(ui, .Container, label="workspace-trash-dirty-actions", style=alicorn.layout_style(.Row, height=38, gap=8, align=.Center))
			if alicorn.button(ui, "Save & Trash", key=alicorn.key_string("workspace-trash-save"), style=alicorn.layout_style(.Row, width=128, height=34)) {
				workspace_mutation_save_and_trash(app, rt)
			}
			if alicorn.button(ui, "Discard & Trash", key=alicorn.key_string("workspace-trash-discard"), style=alicorn.layout_style(.Row, width=138, height=34)) {
				workspace_mutation_submit(app, rt, true)
			}
			if alicorn.button(ui, "Cancel", key=alicorn.key_string("workspace-trash-cancel"), style=alicorn.layout_style(.Row, width=88, height=34)) {
				workspace_mutation_cancel(app, rt)
			}
			alicorn.container_end(ui)
		} else {
			if app.workspace_mutation_error != "" { alicorn.text(ui, app.workspace_mutation_error) }
			alicorn.container_begin(ui, .Container, label="workspace-trash-actions", style=alicorn.layout_style(.Row, height=38, gap=8, align=.Center))
			if alicorn.button(ui, "Move to Trash", key=alicorn.key_string("workspace-trash-confirm"), style=alicorn.layout_style(.Row, width=132, height=34)) {
				workspace_mutation_submit(app, rt, false)
			}
			if alicorn.button(ui, "Cancel", key=alicorn.key_string("workspace-trash-cancel"), style=alicorn.layout_style(.Row, width=88, height=34)) {
				workspace_mutation_cancel(app, rt)
			}
			alicorn.container_end(ui)
		}
		alicorn.container_end(ui)
		alicorn.modal_overlay_end(ui)
		return
	}

	alicorn.modal_overlay_begin(ui, alicorn.key_string("workspace-mutation-overlay"), style=alicorn.layout_style(.Column, grow=1, align=.Center), backdrop_color=alicorn.Color{0.015, 0.02, 0.03, 0.72})
	alicorn.container_begin(ui, .Container, label="workspace-mutation-dialog", style=alicorn.layout_style(.Column, width=500, height=190, padding=22, gap=12, align=.Start, clip=true), color=COLOR_PANEL)
	alicorn.text(ui, label)
	if app.workspace_mutation_queued {
		alicorn.text(ui, "Waiting for pending editor changes to finish…")
	} else if app.workspace_mutation_kind == .Move {
		alicorn.text(ui, fmt.tprintf("Move %s to a workspace-relative destination path.", app.workspace_mutation_source))
		app.workspace_mutation_name_node = alicorn.text_field(ui, app.workspace_mutation_name, key=alicorn.key_string("workspace-mutation-destination"), style=alicorn.layout_style(.Row, height=34))
	} else {
		if app.workspace_mutation_kind == .Rename { alicorn.text(ui, app.workspace_mutation_source) }
		app.workspace_mutation_name_node = alicorn.text_field(ui, app.workspace_mutation_name, key=alicorn.key_string("workspace-mutation-name"), style=alicorn.layout_style(.Row, height=34))
	}
	if app.workspace_mutation_error != "" { alicorn.text(ui, app.workspace_mutation_error) }
	alicorn.container_begin(ui, .Container, label="workspace-mutation-actions", style=alicorn.layout_style(.Row, height=38, gap=8, align=.Center))
	if alicorn.button(ui, "Cancel", key=alicorn.key_string("workspace-mutation-cancel"), style=alicorn.layout_style(.Row, width=88, height=34)) {
		workspace_mutation_cancel(app, rt)
	}
	if !app.workspace_mutation_queued && alicorn.button(ui, label if app.workspace_mutation_kind == .Rename || app.workspace_mutation_kind == .Move else "Create", key=alicorn.key_string("workspace-mutation-confirm"), style=alicorn.layout_style(.Row, width=118, height=34)) {
		workspace_mutation_submit(app, rt, false)
	}
	alicorn.container_end(ui)
	alicorn.container_end(ui)
	alicorn.modal_overlay_end(ui)
}

workspace_mutation_cancel :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app != nil && app.workspace_mutation_queued {
		for index := len(app.deferred_actions)-1; index >= 0; index -= 1 {
			if app.deferred_actions[index].kind != .Workspace_Mutation { continue }
			deferred_action_destroy(&app.deferred_actions[index])
			ordered_remove(&app.deferred_actions, index)
		}
	}
	workspace_mutation_clear(app)
	app.workspace_mutation_restore_pending = true
	app.workspace_mutation_restore_editor = false
	deferred_actions_run(app, rt)
	alicorn.invalidate_root(rt, "Scratchpad workspace operation cancelled")
}

workspace_mutation_clear :: proc(app: ^App) {
	if app == nil { return }
	if len(app.workspace_mutation_source) > 0 { delete(app.workspace_mutation_source, context.allocator) }
	if len(app.workspace_mutation_name) > 0 { delete(app.workspace_mutation_name, context.allocator) }
	if len(app.workspace_mutation_error) > 0 { delete(app.workspace_mutation_error, context.allocator) }
	app.workspace_mutation_source = ""
	app.workspace_mutation_name = ""
	app.workspace_mutation_error = ""
	app.workspace_mutation_name_node = 0
	app.workspace_mutation_focus_pending = false
	app.workspace_mutation_kind = .None
	app.workspace_mutation_source_is_dir = false
	app.workspace_mutation_dirty = false
	app.workspace_mutation_queued = false
}

workspace_mutation_set_name :: proc(app: ^App, value: string) {
	if app == nil { return }
	name_copy, clone_error := strings.clone(value, context.allocator)
	if clone_error != nil {
		workspace_mutation_set_error(app, "Could not retain the operation name.")
		return
	}
	if len(app.workspace_mutation_name) > 0 { delete(app.workspace_mutation_name, context.allocator) }
	app.workspace_mutation_name = name_copy
}

workspace_mutation_set_error :: proc(app: ^App, value: string) {
	if app == nil { return }
	error_copy, clone_error := strings.clone(value, context.allocator)
	if clone_error != nil { return }
	if len(app.workspace_mutation_error) > 0 { delete(app.workspace_mutation_error, context.allocator) }
	app.workspace_mutation_error = error_copy
}

workspace_mutation_submit :: proc(app: ^App, rt: ^alicorn.Runtime, discard: bool) {
	if app == nil || rt == nil || app.workspace_mutation_kind == .None { return }
	if app.workspace_mutation_queued { return }
	if app.workspace_mutation_kind != .Trash && app.workspace_mutation_name == "" {
		workspace_mutation_set_error(app, "Enter a name or destination path.")
		app.workspace_mutation_focus_pending = true
		alicorn.invalidate_root(rt, "Scratchpad workspace operation needs a value")
		return
	}
	if len(app.editor_edits) > 0 {
		queued := deferred_action_enqueue(
			app,
			.Workspace_Mutation,
			path=app.workspace_mutation_source,
			name=app.workspace_mutation_name,
			relative_path=app.workspace_mutation_name if app.workspace_mutation_kind == .Move else "",
			workspace_mutation_kind=app.workspace_mutation_kind,
			source_is_dir=app.workspace_mutation_source_is_dir,
			discard=discard,
			workspace_root=app.backend.state.workspace_root,
		)
		if !queued {
			workspace_mutation_set_error(app, "Could not queue this operation behind pending editor changes.")
			app.workspace_mutation_focus_pending = true
			alicorn.invalidate_root(rt, "Scratchpad workspace operation queue is full")
			return
		}
		app.workspace_mutation_queued = true
		app.workspace_mutation_focus_pending = true
		workspace_mutation_set_error(app, "")
		alicorn.invalidate_root(rt, "Scratchpad workspace operation queued behind editor edits")
		return
	}
	workspace_mutation_execute(
		app,
		rt,
		app.workspace_mutation_kind,
		app.workspace_mutation_source,
		app.workspace_mutation_name,
		app.workspace_mutation_name if app.workspace_mutation_kind == .Move else "",
		app.workspace_mutation_source_is_dir,
		discard,
		app.backend.state.workspace_root,
	)
}

workspace_mutation_execute :: proc(
	app: ^App,
	rt: ^alicorn.Runtime,
	kind: Workspace_Mutation_Kind,
	source, name, destination: string,
	source_is_dir, discard: bool,
	workspace_root: string,
) {
	if app == nil || rt == nil || kind == .None || !app.backend.started { return }
	if workspace_root != app.backend.state.workspace_root {
		workspace_mutation_set_error(app, "The workspace changed before this operation could run. Reopen it and try again.")
		app.workspace_mutation_focus_pending = true
		alicorn.invalidate_root(rt, "Scratchpad discarded a workspace operation from an old root")
		return
	}
	if len(app.editor_edits) > 0 {
		if !app.workspace_mutation_queued {
			if !deferred_action_enqueue(app, .Workspace_Mutation, path=source, name=name, relative_path=destination, workspace_mutation_kind=kind, source_is_dir=source_is_dir, discard=discard, workspace_root=workspace_root) {
				workspace_mutation_set_error(app, "Could not queue this operation behind pending editor changes.")
				alicorn.invalidate_root(rt, "Scratchpad workspace operation queue is full")
				return
			}
			app.workspace_mutation_queued = true
		}
		return
	}
	dest := destination
	if kind == .Create_File || kind == .Create_Folder {
		dest = tree_join_relative_path(source, name)
	}
	if kind == .Rename {
		dest = tree_join_relative_path(tree_parent_relative_path(source), name)
	}
	if kind == .Move && destination == "" {
		workspace_mutation_set_error(app, "Enter a workspace-relative destination path.")
		return
	}
	migrations := workspace_mutation_capture_documents(app, source, dest, source_is_dir, kind == .Trash)
	defer workspace_mutation_migrations_destroy(&migrations)
	response: bridge.Backend_Command_Result
	switch kind {
	case .Create_File:
		response = bridge.backend_command(&app.backend, "create_file", path=dest)
	case .Create_Folder:
		response = bridge.backend_command(&app.backend, "create_folder", path=dest)
	case .Rename:
		response = bridge.backend_command(&app.backend, "rename_path", path=source, name=name)
	case .Move:
		response = bridge.backend_command(&app.backend, "move_path", path=source, relative_path=destination)
	case .Trash:
		response = bridge.backend_command(&app.backend, "trash_path", path=source, discard=discard)
	case .None:
		return
	case:
		return
	}
	if !response.ok {
		if kind == .Trash && response.code == "trash_requires_decision" && !discard {
			if app.workspace_mutation_kind != .Trash || app.workspace_mutation_source != source {
				workspace_mutation_begin(app, rt, .Trash, source, source_is_dir)
			}
			app.workspace_mutation_dirty = true
			app.workspace_mutation_queued = false
			app.workspace_mutation_focus_pending = true
			workspace_mutation_set_error(app, "")
			alicorn.invalidate_root(rt, "Scratchpad requires a dirty-document trash decision")
		} else {
			workspace_mutation_set_error(app, response.message if response.message != "" else "The workspace operation failed.")
			app.workspace_mutation_focus_pending = true
			alicorn.invalidate_root(rt, "Scratchpad workspace operation failed")
		}
		bridge.backend_command_result_destroy(&response, context.allocator)
		return
	}
	if kind == .Rename || kind == .Move {
		workspace_mutation_migrate_editor_views(app, rt, migrations[:])
	}
	quick_open_invalidate_index(app)
	handle_command_result(app, rt, &response)
	bridge.backend_command_result_destroy(&response, context.allocator)
	refresh_ok := workspace_mutation_refresh_tree(app, rt, kind, source, dest, source_is_dir)
	app.workspace_mutation_restore_pending = true
	app.workspace_mutation_restore_editor = kind == .Create_File
	app.workspace_mutation_restore_node = app.tree_scroll_owner
	app.workspace_mutation_restore_semantic = alicorn.semantic_focus_state(rt)
	if app.workspace_mutation_restore_editor {
		app.workspace_mutation_restore_node = 0
		app.workspace_mutation_restore_semantic = {}
	}
	workspace_mutation_clear(app)
	if refresh_ok { set_error(app, "") }
	alicorn.invalidate_root(rt, "Scratchpad workspace operation committed")
}

workspace_mutation_capture_documents :: proc(app: ^App, source, destination: string, source_is_dir, skip: bool) -> [dynamic]Workspace_Document_Migration {
	result := make([dynamic]Workspace_Document_Migration, 0, allocator=context.temp_allocator)
	if app == nil || skip || source == "" { return result }
	root := app.backend.state.workspace_root
	source_absolute, source_error := os.join_path({root, source}, context.temp_allocator)
	destination_absolute, destination_error := os.join_path({root, destination}, context.temp_allocator)
	if source_error != nil || destination_error != nil { return result }
	for document in app.backend.state.documents {
		new_path, matches := tree_path_rewrite(document.path, source_absolute, destination_absolute, source_is_dir)
		if !matches { continue }
		old_id, old_error := strings.clone(document.id, context.temp_allocator)
		path_copy, path_error := strings.clone(new_path, context.temp_allocator)
		if old_error != nil || path_error != nil { continue }
		append(&result, Workspace_Document_Migration{old_id=old_id, new_path=path_copy})
	}
	return result
}

workspace_mutation_migrations_destroy :: proc(migrations: ^[dynamic]Workspace_Document_Migration) {
	if migrations == nil { return }
	for &migration in migrations {
		delete(migration.old_id, context.temp_allocator)
		delete(migration.new_path, context.temp_allocator)
	}
	delete(migrations^)
}

workspace_mutation_migrate_editor_views :: proc(app: ^App, rt: ^alicorn.Runtime, migrations: []Workspace_Document_Migration) {
	if app == nil { return }
	window_invalidated := false
	for migration in migrations {
		new_document: ^bridge.State_Document
		for &document in app.backend.state.documents {
			if document.path == migration.new_path { new_document = &document; break }
		}
		if new_document == nil { continue }
		if index := editor_view_find(app.editor_views[:], migration.old_id); index >= 0 {
			new_id, clone_error := strings.clone(new_document.id, context.allocator)
			if clone_error == nil {
				delete(app.editor_views[index].document_id, context.allocator)
				app.editor_views[index].document_id = new_id
			}
		}
		if app.editor_presented_document_id == migration.old_id {
			new_id, clone_error := strings.clone(new_document.id, context.allocator)
			if clone_error == nil {
				delete(app.editor_presented_document_id, context.allocator)
				app.editor_presented_document_id = new_id
			}
		}
		if app.editor_window_ready && app.editor_window.document_id == migration.old_id && !window_invalidated {
			editor_window_destroy(&app.editor_window)
			app.editor_window_ready = false
			app.editor_request_generation += 1
			editor_window_rejection_clear(app)
			window_invalidated = true
		}
	}
	if window_invalidated && rt != nil { alicorn.invalidate_root(rt, "Scratchpad invalidated source projection after path mutation") }
}

workspace_mutation_refresh_tree :: proc(app: ^App, rt: ^alicorn.Runtime, kind: Workspace_Mutation_Kind, source, destination: string, source_is_dir: bool) -> bool {
	if app == nil || rt == nil { return false }
	tree_destination := tree_normalize_separators(destination, tree_preferred_separator(app))
	expanded := make([dynamic]string, 0, allocator=context.temp_allocator)
	defer delete(expanded)
	if kind == .Move || kind == .Rename {
		for directory in app.tree_directories {
			if !directory.expanded { continue }
			path, matches := tree_path_rewrite(directory.path, source, tree_destination, source_is_dir)
			if matches { append(&expanded, path) }
		}
	}
	focused := app.tree_focused_path
	focus_kind := app.tree_focused_is_dir
	if kind == .Move || kind == .Rename {
		focused, _ = tree_path_rewrite(focused, source, tree_destination, source_is_dir)
	} else if kind == .Trash {
		focused = tree_parent_relative_path(source)
		focus_kind = true
	} else if kind == .Create_File || kind == .Create_Folder {
		focused = tree_destination
		focus_kind = kind == .Create_Folder
	}
	if kind == .Move || kind == .Rename || kind == .Trash {
		tree_remove_directory_subtree(app, source)
	}
	old_parent := tree_parent_relative_path(source)
	new_parent := tree_parent_relative_path(tree_destination)
	if kind == .Create_File || kind == .Create_Folder { old_parent = tree_parent_relative_path(tree_destination) }
	refresh_ok := tree_reload_directory(app, old_parent)
	if (kind == .Move || kind == .Rename) && new_parent != old_parent {
		if !tree_reload_directory(app, new_parent) { refresh_ok = false }
	}
	for path in expanded { if !tree_load_directory(app, path, true) { refresh_ok = false } }
	tree_restore_mutation_focus(app, rt, focused, focus_kind)
	return refresh_ok && app.error_message == ""
}

tree_reload_directory :: proc(app: ^App, path: string) -> bool {
	expanded := path == ""
	if index := tree_directory_index(app, path); index >= 0 {
		expanded = app.tree_directories[index].expanded
		tree_directory_destroy(&app.tree_directories[index])
		ordered_remove(&app.tree_directories, index)
	}
	return tree_load_directory(app, path, expanded)
}

tree_remove_directory_subtree :: proc(app: ^App, path: string) {
	if app == nil || path == "" { return }
	for index := len(app.tree_directories)-1; index >= 0; index -= 1 {
		_, matches := tree_path_rewrite(app.tree_directories[index].path, path, "", true)
		if matches {
			tree_directory_destroy(&app.tree_directories[index])
			ordered_remove(&app.tree_directories, index)
		}
	}
}

tree_restore_mutation_focus :: proc(app: ^App, rt: ^alicorn.Runtime, path: string, is_dir: bool) {
	if app == nil || rt == nil { return }
	tree_expand_ancestors(app, path)
	rows := make([dynamic]Tree_Row, 0, allocator=context.temp_allocator)
	defer delete(rows)
	tree_flatten_directory(app, "", 0, &rows)
	candidate := path
	candidate_is_dir := is_dir
	for {
		for row, index in rows {
			if row.path == candidate && row.is_dir == candidate_is_dir {
				tree_set_focused_row(app, rt, row, index)
				return
			}
		}
		if candidate == "" { break }
		candidate = tree_parent_relative_path(candidate)
		candidate_is_dir = true
	}
	tree_clear_focused_path(app)
	_ = alicorn.semantic_focus_clear(rt)
}

tree_move_horizontal_focus :: proc(app: ^App, rt: ^alicorn.Runtime, key: host.Application_Key) -> bool {
	if app == nil || rt == nil || (key != .Left && key != .Right) { return false }
	rows := make([dynamic]Tree_Row, 0, allocator=context.temp_allocator)
	defer delete(rows)
	tree_flatten_directory(app, "", 0, &rows)
	current := -1
	for row, index in rows {
		if row.path == app.tree_focused_path && row.is_dir == app.tree_focused_is_dir { current = index; break }
	}
	if current < 0 { return true }
	row := rows[current]
	if key == .Left {
		if row.is_dir && row.expanded {
			if index := tree_directory_index(app, row.path); index >= 0 { app.tree_directories[index].expanded = false }
			alicorn.invalidate_root(rt, "Scratchpad workspace directory collapsed by Left")
			return true
		}
		parent := tree_parent_relative_path(row.path)
		for candidate, index in rows {
			if candidate.is_dir && candidate.path == parent {
				tree_set_focused_row(app, rt, candidate, index)
				alicorn.invalidate_root(rt, "Scratchpad workspace tree moved to parent")
				return true
			}
		}
		return true
	}
	if row.is_dir {
		if !row.expanded {
			if tree_load_directory(app, row.path, true) {
				alicorn.invalidate_root(rt, "Scratchpad workspace directory expanded by Right")
			}
			return true
		}
		if current+1 < len(rows) && rows[current+1].depth == row.depth+1 {
			tree_set_focused_row(app, rt, rows[current+1], current+1)
			alicorn.invalidate_root(rt, "Scratchpad workspace tree moved to child")
		}
	}
	return true
}

tree_expand_ancestors :: proc(app: ^App, path: string) {
	if app == nil || path == "" { return }
	ancestors := make([dynamic]string, 0, allocator=context.temp_allocator)
	defer delete(ancestors)
	parent := tree_parent_relative_path(path)
	for parent != "" {
		append(&ancestors, parent)
		parent = tree_parent_relative_path(parent)
	}
	for index := len(ancestors)-1; index >= 0; index -= 1 {
		_ = tree_load_directory(app, ancestors[index], true)
	}
}

workspace_mutation_save_and_trash :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil || app.workspace_mutation_kind != .Trash { return }
	ids := make([dynamic]string, 0, allocator=context.temp_allocator)
	defer {
		for &id in ids { delete(id, context.temp_allocator) }
		delete(ids)
	}
	for document in app.backend.state.documents {
		if !document.dirty || !workspace_mutation_document_affected(app, document.path) { continue }
		id, clone_error := strings.clone(document.id, context.temp_allocator)
		if clone_error != nil {
			workspace_mutation_set_error(app, "Could not retain the affected document identity to save it.")
			alicorn.invalidate_root(rt, "Scratchpad could not prepare save-before-trash")
			return
		}
		append(&ids, id)
	}
	for id in ids {
		response := bridge.backend_command(&app.backend, "save_document", document_id=id)
		if !response.ok {
			workspace_mutation_set_error(app, response.message if response.message != "" else "Could not save an affected document.")
			bridge.backend_command_result_destroy(&response, context.allocator)
			alicorn.invalidate_root(rt, "Scratchpad save-before-trash failed")
			return
		}
		bridge.backend_command_result_destroy(&response, context.allocator)
	}
	workspace_mutation_submit(app, rt, false)
}

workspace_mutation_dirty_document_count :: proc(app: ^App) -> int {
	if app == nil { return 0 }
	count := 0
	for document in app.backend.state.documents {
		if document.dirty && workspace_mutation_document_affected(app, document.path) { count += 1 }
	}
	return count
}

workspace_mutation_document_affected :: proc(app: ^App, path: string) -> bool {
	if app == nil || app.workspace_mutation_kind != .Trash { return false }
	absolute, err := os.join_path({app.backend.state.workspace_root, app.workspace_mutation_source}, context.temp_allocator)
	if err != nil { return false }
	_, matches := tree_path_rewrite(path, absolute, "", app.workspace_mutation_source_is_dir)
	delete(absolute, context.temp_allocator)
	return matches
}

tree_join_relative_path :: proc(parent, name: string) -> string {
	if parent == "" { return name }
	separator := "/"
	if strings.contains(parent, `\`) { separator = `\` }
	return fmt.tprintf("%s%s%s", parent, separator, name)
}

tree_basename :: proc(path: string) -> string {
	separator := -1
	for index in 0..<len(path) {
		if path[index] == '/' || path[index] == '\\' { separator = index }
	}
	return path[separator+1:]
}

tree_path_rewrite :: proc(path, source, destination: string, recursive: bool) -> (rewritten: string, matches: bool) {
	if path == source { return destination, true }
	if !recursive || len(path) <= len(source) || len(source) == 0 || path[:len(source)] != source { return path, false }
	separator := path[len(source)]
	if separator != '/' && separator != '\\' { return path, false }
	return fmt.tprintf("%s%s", destination, path[len(source):]), true
}

tree_preferred_separator :: proc(app: ^App) -> u8 {
	if app != nil {
		for character in app.tree_root_path {
			if character == '\\' { return '\\' }
			if character == '/' { return '/' }
		}
	}
	return '/'
}

tree_normalize_separators :: proc(path: string, separator: u8) -> string {
	if path == "" { return path }
	bytes, allocation_error := make([]u8, len(path), allocator=context.temp_allocator)
	if allocation_error != nil { return path }
	for index in 0..<len(path) {
		character := path[index]
		bytes[index] = separator if character == '/' || character == '\\' else character
	}
	return string(bytes)
}
