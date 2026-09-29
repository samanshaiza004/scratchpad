package main

import "core:strings"
import "core:testing"
import "core:mem"
import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"
import bridge "./bridge"

editor_stale_window_test_render :: proc(app: ^App, rt: ^alicorn.Runtime, document: bridge.State_Document) {
	alicorn.invalidate_root(rt, "stale editor window regression")
	ui, should_build := alicorn.begin_frame(rt)
	if !should_build { return }
	clear(&app.editor_row_targets)
	alicorn.container_begin(
		&ui,
		.Root,
		key=alicorn.key_string("stale-window-test-root"),
		style=alicorn.layout_style(.Column, width=800, height=80, clip=true),
	)
	build_document_editor(app, &ui, rt, document)
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
}

editor_stale_window_test_line :: proc(rt: ^alicorn.Runtime, key: string) -> (id: alicorn.Node_ID, text: string, found: bool) {
	if rt == nil { return }
	for node_id in rt.order {
		node, node_found := rt.nodes[node_id]
		if node_found && node.key == key { return node_id, node.text, true }
	}
	return
}

@(test)
test_stale_document_window_remains_visible_and_read_only_until_fresh_revision :: proc(t: ^testing.T) {
	old_source := [?]u8{'a', 'l', 'p', 'h', 'a', '\n', 'b', 'e', 't', 'a', '\n', 'g', 'a', 'm', 'm', 'a'}
	old_bytes, old_allocation_error := make([]u8, len(old_source), allocator=context.allocator)
	if old_allocation_error != nil { testing.expect(t, false, "could not allocate the last-good source fixture"); return }
	mem.copy(rawptr(&old_bytes[0]), rawptr(&old_source[0]), len(old_source))
	old_visible := bridge.Visible_Window{
		document_id="stale-doc",
		application_rev=1,
		editor_revision=1,
		start_line=0,
		end_line=3,
		start_byte=0,
		line_byte_length=u64(len(old_source)),
		source=old_bytes,
	}
	old_window, old_ok, old_error := editor_window_from_visible(&old_visible, context.allocator)
	testing.expect(t, old_ok, old_error)
	if !old_ok { return }

	app: App
	app.backend.started = true
	app.backend.state.active = "stale-doc"
	app.backend.state.application_rev = 1
	documents := make([dynamic]bridge.State_Document, 0, allocator=context.allocator)
	append(&documents, bridge.State_Document{
		id="stale-doc",
		path="notes.txt",
		language="text",
		editor_revision=1,
		line_count=3,
		byte_length=u64(len(old_source)),
	})
	app.backend.state.documents = documents[:]
	app.editor_views = make([dynamic]Editor_View_State, 0, allocator=context.allocator)
	app.editor_row_targets = make([dynamic]Editor_Row_Target, 0, allocator=context.allocator)
	app.editor_edits = make([dynamic]Editor_Edit_Intent, 0, allocator=context.allocator)
	app.editor_window = old_window
	app.editor_window_ready = true
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 800, 100})
	defer {
		for index := len(app.editor_edits)-1; index >= 0; index -= 1 { editor_remove_edit(&app, index) }
		delete(app.editor_edits)
		delete(app.editor_row_targets)
		editor_views_destroy(&app.editor_views, context.allocator)
		delete(documents)
		editor_window_destroy(&app.editor_window, context.allocator)
		if len(app.editor_presented_document_id) > 0 { delete(app.editor_presented_document_id, context.allocator) }
		if len(app.editor_window_error) > 0 { delete(app.editor_window_error, context.allocator) }
		if len(app.error_message) > 0 { delete(app.error_message, context.allocator) }
		alicorn.destroy_runtime(&rt)
	}
	if !alicorn.text_engine_load_font(&rt.text_engine, ALICORN_TEST_UI_FONT_DATA) ||
	   !alicorn.text_engine_load_font_role(&rt.text_engine, .Monospace, ALICORN_TEST_MONO_FONT_DATA) {
		testing.expect(t, false, "stale-window regression should load the bundled UI and monospace fonts")
		return
	}
	document := app.backend.state.documents[0]
	editor_stale_window_test_render(&app, &rt, document)
	old_line_0, old_text_0, old_found_0 := editor_stale_window_test_line(&rt, "scratchpad-line:stale-doc:0")
	old_line_1, old_text_1, old_found_1 := editor_stale_window_test_line(&rt, "scratchpad-line:stale-doc:1")
	testing.expect(t, old_found_0 && old_found_1 && old_text_0 == "alpha" && old_text_1 == "beta",
		"the first authoritative presentation should retain the existing visible source rows")
	if !old_found_0 || !old_found_1 { return }

	// Model the state-publication interval before its matching bounded window
	// arrives. Keep the old rows visible, but reject all source interaction
	// until an exact-revision window can be installed.
	app.backend.state.application_rev = 2
	app.backend.state.documents[0].editor_revision = 2
	app.backend.state.documents[0].line_count = 4 // the authoritative undo reintroduced a line
	app.backend.state.documents[0].byte_length = 23
	document = app.backend.state.documents[0]
	editor_stale_window_test_render(&app, &rt, document)
	stale_line_0, stale_text_0, stale_found_0 := editor_stale_window_test_line(&rt, "scratchpad-line:stale-doc:0")
	stale_line_1, stale_text_1, stale_found_1 := editor_stale_window_test_line(&rt, "scratchpad-line:stale-doc:1")
	loading_found := false
	for node_id in rt.order {
		if node, node_found := rt.nodes[node_id]; node_found && strings.has_prefix(node.text, "Loading line ") {
			loading_found = true
		}
	}
	testing.expect(t, stale_found_0 && stale_found_1 && stale_text_0 == "alpha" && stale_text_1 == "beta",
		"a line-count-changing undo should keep the previous visible rows while its new window is unavailable")
	testing.expect(t, !loading_found,
		"the retained viewport should not expose Loading placeholders during stale-while-revalidate")
	testing.expect(t, stale_line_0 == old_line_0 && stale_line_1 == old_line_1,
		"stale-while-revalidate should preserve the retained line subtree identities")
	testing.expect(t, app.editor_scroll_owner != 0 && alicorn.text_input_target_is_suspended(&rt, app.editor_scroll_owner),
		"the native text-input target should be suspended while only stale source bytes are available")
	view_index := editor_view_find(app.editor_views[:], "stale-doc")
	if view_index < 0 { testing.expect(t, false, "the stale document should still have local view state"); return }
	view := &app.editor_views[view_index]
	view.caret_byte = 4
	view.selection_anchor = 4
	caret_before := view.caret_byte
	backspace_handled := editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Backspace})
	testing.expect(t, !backspace_handled && len(app.editor_edits) == 0 && view.caret_byte == caret_before,
		"a key edit must be rejected while its source window belongs to an older revision")

	new_source := [?]u8{
		'a', 'l', 'p', 'h', 'a', '!', '\n',
		'b', 'e', 't', 'a', '\n',
		'g', 'a', 'm', 'm', 'a', '\n',
		'd', 'e', 'l', 't', 'a',
	}
	new_bytes, new_allocation_error := make([]u8, len(new_source), allocator=context.allocator)
	if new_allocation_error != nil { testing.expect(t, false, "could not allocate the refreshed source fixture"); return }
	mem.copy(rawptr(&new_bytes[0]), rawptr(&new_source[0]), len(new_source))
	new_visible := bridge.Visible_Window{
		document_id="stale-doc",
		application_rev=2,
		editor_revision=2,
		start_line=0,
		end_line=4,
		start_byte=0,
		line_byte_length=u64(len(new_source)),
		source=new_bytes,
	}
	new_window, new_ok, new_error := editor_window_from_visible(&new_visible, context.allocator)
	testing.expect(t, new_ok, new_error)
	if !new_ok { return }
	editor_window_destroy(&app.editor_window, context.allocator)
	app.editor_window = new_window
	app.editor_window_ready = true
	app.backend.state.documents[0].byte_length = u64(len(new_source))
	document = app.backend.state.documents[0]
	editor_stale_window_test_render(&app, &rt, document)
	new_line_0, new_text_0, new_found_0 := editor_stale_window_test_line(&rt, "scratchpad-line:stale-doc:0")
	new_line_1, new_text_1, new_found_1 := editor_stale_window_test_line(&rt, "scratchpad-line:stale-doc:1")
	fresh_window, fresh_is_authoritative := editor_view_window(
		view,
		&app.editor_window,
		app.editor_window_ready,
		"stale-doc",
		document.editor_revision,
	)
	testing.expect(t, fresh_is_authoritative && fresh_window != nil && fresh_window.editor_revision == 2 &&
		string(fresh_window.source) == string(new_source[:]) && view.authoritative_revision == 2,
		"the new matching revision should replace stale bytes atomically and become edit-authoritative")
	testing.expect(t, new_found_0 && new_found_1 && new_text_0 == "alpha!" && new_text_1 == "beta" &&
		new_line_0 == old_line_0 && new_line_1 == old_line_1,
		"fresh rows should update in place without retiring and recreating the retained line subtree")
	testing.expect(t, !alicorn.text_input_target_is_suspended(&rt, app.editor_scroll_owner),
		"installing the matching revision should resume native text input")
}
