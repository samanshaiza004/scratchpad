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
	bridge.backend_command_result_destroy(&response, context.allocator)
}

navigate_tab :: proc(app: ^App, rt: ^alicorn.Runtime, direction: int) {
	documents := app.backend.state.documents
	if len(documents) < 2 { return }
	selected_index := -1
	for document, i in documents {
		if document.id == app.backend.state.active { selected_index = i; break }
	}
	navigation := alicorn.Tab_Bar_Navigation.Next
	if direction < 0 { navigation = .Previous }
	index, found := alicorn.tab_bar_navigate(len(documents), selected_index, navigation)
	if found { select_document(app, rt, documents[index].id) }
}

document_title :: proc(path: string) -> string {
	start := 0
	for character, index in path {
		if character == '/' || character == '\\' { start = index + 1 }
	}
	if start >= len(path) { return path }
	return path[start:]
}
