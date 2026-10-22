package main

import "core:strings"
import alicorn "alicorn:runtime"

// The Go session owns these application meanings. Runtime handles and request
// tokens below are acquired afresh; none are sent over the persistence boundary.
session_ui_prepare :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil || !app.backend.started || app.backend.state.revision == 0 { return }
	app.session_ui_runtime = rt
	if app.session_ui_initialized {
		focused := alicorn.focused_node(rt)
		if app.session_ui_restore_pending && focused != 0 && focused != app.tree_scroll_owner &&
		   focused != app.editor_scroll_owner && focused != app.image_scroll_owner {
			// User input before the delayed document/tree arrived takes priority.
			app.session_ui_restore_pending = false
			_ = alicorn.restore_cancel(rt, .Semantic_Focus, app.tree_scroll_owner, app.session_ui_restore_token)
		}
		return
	}
	app.session_ui_initialized = true
	saved := app.backend.state.session_ui
	app.session_ui.focus = "editor"
	if saved.focus == "tree" && app.backend.state.has_workspace { app.session_ui.focus = "tree" }
	app.session_ui.tree_path, _ = strings.clone(saved.tree_path, context.allocator)
	app.session_ui.tree_is_dir = saved.tree_is_dir
	app.session_ui.tree_scroll_y = saved.tree_scroll_y
	app.session_ui_restore_pending = saved.focus == "tree" || saved.focus == "editor"
	app.session_ui_restore_token = alicorn.restore_token_next(rt)
}

session_ui_expand_focus_ancestors :: proc(app: ^App) {
	if !app.session_ui_restore_pending || app.session_ui.focus != "tree" { return }
	path := app.session_ui.tree_path
	// Only the focused path's ancestors are loaded, never the entire tree.
	for character, index in path {
		if character != '/' && character != '\\' { continue }
		parent := tree_parent_relative_path(path[:index])
		parent_index := tree_directory_index(app, parent)
		if parent_index < 0 { return }
		directory_found := false
		for entry in app.tree_directories[parent_index].entries {
			if entry.path == path[:index] && entry.dir { directory_found = true; break }
		}
		if !directory_found { return }
		if !tree_load_directory(app, path[:index], true) { return }
	}
}

session_ui_tree_scroll_request :: proc(app: ^App) -> alicorn.Scroll_Restore_Request {
	if !app.session_ui_initialized || app.session_ui_tree_restore_complete { return {} }
	return alicorn.Scroll_Restore_Request{token=app.session_ui_restore_token, offset_y=app.session_ui.tree_scroll_y}
}

session_ui_restore_tree_focus :: proc(app: ^App, rt: ^alicorn.Runtime, rows: []Tree_Row) {
	if !app.session_ui_restore_pending || app.session_ui.focus != "tree" { return }
	for row in rows {
		if row.path != app.session_ui.tree_path || row.is_dir != app.session_ui.tree_is_dir { continue }
		if app.tree_focused_path != row.path {
			tree_clear_focused_path(app)
			app.tree_focused_path, _ = strings.clone(row.path, context.allocator)
			app.tree_focused_is_dir = row.is_dir
		}
		_ = alicorn.semantic_focus_restore_request(rt, tree_semantic_id(row.path, row.is_dir), app.tree_scroll_owner, app.session_ui_restore_token)
		return
	}
	// A deleted or hidden entry uses the ordinary editor fallback.
	app.session_ui.focus = "editor"
}

session_ui_after_frame :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if !app.session_ui_tree_restore_complete && app.tree_scroll_owner != 0 {
		state, found := alicorn.restore_state_query(rt, .Scroll, app.tree_scroll_owner, app.session_ui_restore_token)
		if found && state.outcome != .Requested && state.outcome != .Deferred {
			app.session_ui_tree_restore_complete = true
		}
	}
	if app.session_ui_restore_pending {
		owner := app.editor_scroll_owner
		if app.image_scroll_owner != 0 { owner = app.image_scroll_owner }
		if app.session_ui.focus == "tree" { owner = app.tree_scroll_owner }
		if owner == 0 && app.backend.state.active == "" { owner = app.tree_scroll_owner }
		if owner != 0 && alicorn.focus(rt, owner) {
			app.session_ui_restore_pending = false
			app.editor_focus_pending = false
		}
	}
	session_ui_capture(app, rt)
}

session_ui_capture :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if rt == nil || !app.session_ui_initialized || app.session_ui_restore_pending { return }
	if split, ok := alicorn.split_state(rt, app.workspace_editor_split_node); ok {
		app.workspace_sidebar_width = split.preferred_position
	}
	if app.session_ui_tree_restore_complete && app.tree_scroll_owner != 0 {
		app.session_ui.tree_scroll_y = alicorn.scroll_region_state(rt, app.tree_scroll_owner).offset_y
	}
	focused := alicorn.focused_node(rt)
	if focused != 0 && focused == app.tree_scroll_owner {
		app.session_ui.focus = "tree"
		app.session_ui.tree_scroll_y = alicorn.scroll_region_state(rt, app.tree_scroll_owner).offset_y
		if app.session_ui.tree_path != app.tree_focused_path {
			delete(app.session_ui.tree_path, context.allocator)
			app.session_ui.tree_path, _ = strings.clone(app.tree_focused_path, context.allocator)
		}
		app.session_ui.tree_is_dir = app.tree_focused_is_dir
	} else if focused != 0 && (focused == app.editor_scroll_owner || focused == app.image_scroll_owner) {
		app.session_ui.focus = "editor"
	}
}
