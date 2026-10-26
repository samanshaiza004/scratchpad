package main

import alicorn "alicorn:runtime"
import bridge "./bridge"

select_document :: proc(app: ^App, rt: ^alicorn.Runtime, document_id: string) {
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

document_title :: proc(path: string) -> string {
	start := 0
	for character, index in path {
		if character == '/' || character == '\\' { start = index + 1 }
	}
	if start >= len(path) { return path }
	return path[start:]
}
