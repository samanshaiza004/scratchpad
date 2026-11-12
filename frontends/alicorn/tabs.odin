package main

import alicorn "alicorn:runtime"
import bridge "./bridge"

select_document :: proc(app: ^App, rt: ^alicorn.Runtime, document_id: string) {
	if app.pinned.editing && document_id!=app.pinned.edit_document_id {
		pinned_edit_finish(app,rt,false)
		if app.pinned.editing { return }
	}
	if len(app.editor_edits) > 0 {
		if !deferred_action_enqueue(app, .Select_Document, value=document_id) {
			set_error(app, "Could not queue document selection behind pending edits.")
			alicorn.invalidate_root(rt, "Scratchpad document selection queue is full")
		}
		return
	}
	response := bridge.backend_command(&app.backend, "select_document", document_id=document_id)
	handle_command_result(app, rt, &response)
	if response.ok && app.pinned.visible && app.pinned.single_pane {
		app.pinned.narrow_source=true
		app.editor_focus_pending=true
	}
	bridge.backend_command_result_destroy(&response, context.allocator)
}

navigate_tab :: proc(app: ^App, rt: ^alicorn.Runtime, direction: int) {
	if workbench_navigate_tab(app, rt, direction) { return }
	documents := app.backend.state.documents
	detached := ""
	if app.floating_window != nil { detached = app.floating_window.document_id }
	indices := floating_window_tab_document_indices(documents, detached, context.temp_allocator)
	defer delete(indices)
	if len(indices) < 1 { return }
	editor_was_focused := app.editor_scroll_owner != 0 &&
		alicorn.focused_node(rt) == app.editor_scroll_owner
	selected_index := -1
	for document_index, i in indices {
		if documents[document_index].id == app.backend.state.active { selected_index = i; break }
	}
	navigation := alicorn.Tab_Bar_Navigation.Next
	if direction < 0 { navigation = .Previous }
	index, found := alicorn.tab_bar_navigate(len(indices), selected_index, navigation)
	if found {
		select_document(app, rt, documents[indices[index]].id)
		if editor_was_focused { app.editor_focus_pending = true }
	}
}

workbench_navigate_tab :: proc(app: ^App, rt: ^alicorn.Runtime, direction: int) -> bool {
	if app == nil || rt == nil { return false }
	window := app_workbench_window(app)
	if window == nil { return false }
	group_index := workbench_group_find(window, window.focused_group_id)
	if group_index < 0 { return false }
	group_id := window.groups[group_index].id
	ordered := workbench_group_views_ordered(window, group_id)
	defer delete(ordered)
	entries := make([dynamic]Workbench_Tab_Entry, 0, len(ordered)+1, allocator=context.temp_allocator)
	defer delete(entries)
	for view_id in ordered {
		view_index := workbench_view_find(window, view_id)
		if view_index < 0 { continue }
		view := window.views[view_index]
		if app.floating_window != nil && view.kind == .Editor && view.resource.id == app.floating_window.document_id { continue }
		append(&entries, Workbench_Tab_Entry{view_id=view_id})
	}
	search_index := -1
	if app.workspace_search_tab_open {
		search_index = len(entries)
		append(&entries, Workbench_Tab_Entry{search=true})
	}
	if len(entries) == 0 { return false }

	selected_index := -1
	if app.workspace_search_mode && search_index >= 0 {
		selected_index = search_index
	} else {
		for entry, index in entries {
			if entry.view_id == window.groups[group_index].active_view_id { selected_index = index; break }
		}
	}
	navigation := alicorn.Tab_Bar_Navigation.Next
	if direction < 0 { navigation = .Previous }
	index, found := alicorn.tab_bar_navigate(len(entries), selected_index, navigation)
	if !found { return false }
	entry := entries[index]
	if entry.search {
		workspace_search_open_surface(app, rt)
		return true
	}
	if app.workspace_search_mode && !workspace_search_deactivate(app, rt) { return true }
	if !app_workbench_activate_view(app, rt, entry.view_id) { return false }
	if view_index := workbench_view_find(window, entry.view_id); view_index >= 0 {
		if window.views[view_index].kind == .Editor { app.editor_focus_pending = true }
	}
	alicorn.invalidate_root(rt, "Scratchpad navigated workbench tabs")
	return true
}

document_title :: proc(path: string) -> string {
	start := 0
	for character, index in path {
		if character == '/' || character == '\\' { start = index + 1 }
	}
	if start >= len(path) { return path }
	return path[start:]
}
