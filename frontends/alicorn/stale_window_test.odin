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
		style=alicorn.layout_style(.Column, width=800, height=180, clip=true),
	)
	build_document_editor(app, &ui, rt, document)
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
}

editor_stale_window_test_line :: proc(app: ^App, rt: ^alicorn.Runtime, logical_line: u64) -> (id: alicorn.Node_ID, text: string, found: bool) {
	if app == nil || rt == nil { return }
	for target in app.editor_row_targets {
		if target.logical_line != logical_line { continue }
		if node, node_found := rt.nodes[target.node]; node_found { return target.node, node.text, true }
	}
	return
}

editor_stale_window_test_span_rows :: proc(app: ^App, rt: ^alicorn.Runtime) -> (style_rows, paint_rows: int) {
	if app == nil || rt == nil { return }
	for target in app.editor_row_targets {
		node, found := rt.nodes[target.node]
		if !found { continue }
		if len(node.text_style_spans) > 0 { style_rows += 1 }
		if len(node.text_paint_spans) > 0 { paint_rows += 1 }
	}
	return
}

@(test)
test_published_presentation_window_supersedes_the_rebased_optimistic_window :: proc(t: ^testing.T) {
	source_text := "package main\n\nfunc main() {}\n"
	line_count := u64(3)

	app: App
	app.backend.started = true
	app.backend.state.active = "highlight-doc"
	app.backend.state.application_rev = 2
	documents := make([dynamic]bridge.State_Document, 0, allocator=context.allocator)
	append(&documents, bridge.State_Document{
		id="highlight-doc",
		path="main.go",
		language="go",
		editor_revision=2,
		line_count=line_count,
		byte_length=u64(len(source_text)),
		presentation_revision=2,
		presentation_ready=true,
	})
	app.backend.state.documents = documents[:]
	app.editor_views = make([dynamic]Editor_View_State, 0, allocator=context.allocator)
	app.editor_row_targets = make([dynamic]Editor_Row_Target, 0, allocator=context.allocator)
	app.editor_edits = make([dynamic]Editor_Edit_Intent, 0, allocator=context.allocator)
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 800, 180})
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
		testing.expect(t, false, "highlight persistence fixture should load the bundled fonts")
		return
	}
	document := app.backend.state.documents[0]
	editor_stale_window_test_render(&app, &rt, document)
	view_index := editor_view_find(app.editor_views[:], "highlight-doc")
	if view_index < 0 {
		testing.expect(t, false, "the highlight document should gain local view state on first presentation")
		return
	}
	view := &app.editor_views[view_index]
	view.view_id = 73
	view.lifecycle_generation = 4
	view.source_request_generation = 11
	view.document_instance_id = document.instance_id
	view.authoritative_revision = 2

	// Model the post-acknowledgement state: the optimistic window carries the
	// accepted revision but only pre-edit presentation, so it can never satisfy
	// the exact-presentation gate.
	optimistic_bytes, optimistic_error := make([]u8, len(source_text), allocator=context.allocator)
	if optimistic_error != nil { testing.expect(t, false, "could not allocate the optimistic fixture"); return }
	mem.copy(rawptr(&optimistic_bytes[0]), rawptr(raw_data(source_text)), len(source_text))
	optimistic_spans := make([]bridge.Presentation_Record, 1, allocator=context.allocator)
	optimistic_spans[0] = bridge.Presentation_Record{kind=EDITOR_PRESENTATION_CODE_KEYWORD, start_byte=0, end_byte=7}
	optimistic_visible := bridge.Visible_Window{
		document_id="highlight-doc",
		application_rev=2,
		editor_revision=2,
		start_line=0,
		end_line=line_count,
		start_byte=0,
		line_byte_length=u64(len(source_text)),
		source=optimistic_bytes,
		presentation_revision=1,
		presentation_ready=true,
		presentation_spans=optimistic_spans,
	}
	optimistic_window, optimistic_ok, optimistic_message := editor_window_from_visible(&optimistic_visible, context.allocator)
	testing.expect(t, optimistic_ok, optimistic_message)
	if !optimistic_ok { return }
	optimistic_window.presentation_stale = true
	view.optimistic_window = optimistic_window
	view.optimistic_window_ready = true
	view.optimistic_pending_edits = 0

	editor_stale_window_test_render(&app, &rt, document)
	_, rebased_paint_rows := editor_stale_window_test_span_rows(&app, &rt)
	testing.expect(t, rebased_paint_rows == 0,
		"the rebased snapshot alone must not claim published spans while an exact refresh is pending")

	exact_bytes, exact_error := make([]u8, len(source_text), allocator=context.allocator)
	if exact_error != nil { testing.expect(t, false, "could not allocate the published fixture"); return }
	mem.copy(rawptr(&exact_bytes[0]), rawptr(raw_data(source_text)), len(source_text))
	exact_spans := make([]bridge.Presentation_Record, 3, allocator=context.allocator)
	exact_spans[0] = bridge.Presentation_Record{kind=EDITOR_PRESENTATION_CODE_KEYWORD, start_byte=0, end_byte=7}
	exact_spans[1] = bridge.Presentation_Record{kind=EDITOR_PRESENTATION_CODE_KEYWORD, start_byte=14, end_byte=18}
	exact_spans[2] = bridge.Presentation_Record{kind=EDITOR_PRESENTATION_CODE_FUNCTION, start_byte=19, end_byte=23}
	result := bridge.Visible_Window_Lane_Result{
		generation=view.source_request_generation,
		request=bridge.Visible_Window_Request{
			view_id=view.view_id,
			view_lifecycle_generation=view.lifecycle_generation,
			document_id="highlight-doc",
			document_instance_id=document.instance_id,
			editor_revision=document.editor_revision,
		},
		window=bridge.Visible_Window{
			document_id="highlight-doc",
			application_rev=2,
			editor_revision=2,
			start_line=0,
			end_line=line_count,
			start_byte=0,
			line_byte_length=u64(len(source_text)),
			source=exact_bytes,
			presentation_revision=2,
			presentation_ready=true,
			presentation_spans=exact_spans,
		},
		window_owned=true,
	}
	installed, _ := application_install_view_visible_window(&app, &rt, &result)
	testing.expect(t, installed && view.source_window_ready,
		"the exact published window should install as the view's source window")
	testing.expect(t, !view.optimistic_window_ready && len(view.optimistic_window.source) == 0,
		"installing exact presentation should retire the matching-revision optimistic snapshot")

	published, authoritative := editor_view_window(view, &app.editor_window, app.editor_window_ready, "highlight-doc", document.editor_revision)
	testing.expect(t, authoritative && published == &view.source_window,
		"an exact presentation-ready source window must win over a matching-revision optimistic snapshot")

	editor_stale_window_test_render(&app, &rt, document)
	_, published_paint_rows := editor_stale_window_test_span_rows(&app, &rt)
	testing.expect(t, published_paint_rows == 2,
		"the published window should restore token-bearing runs on the untouched and edited lines")
	line_0, text_0, found_0 := editor_stale_window_test_line(&app, &rt, 0)
	line_2, text_2, found_2 := editor_stale_window_test_line(&app, &rt, 2)
	testing.expect(t, found_0 && found_2 && text_0 == "package main" && text_2 == "func main() {}",
		"publishing exact presentation must not change visible source text")
	testing.expect(t, line_0 != 0 && line_2 != 0,
		"the visible rows should retain their own node identity across publication")
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
		editor_revision=0,
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
		editor_revision=0,
		line_count=3,
		byte_length=u64(len(old_source)),
	})
	app.backend.state.documents = documents[:]
	app.editor_views = make([dynamic]Editor_View_State, 0, allocator=context.allocator)
	app.editor_row_targets = make([dynamic]Editor_Row_Target, 0, allocator=context.allocator)
	app.editor_edits = make([dynamic]Editor_Edit_Intent, 0, allocator=context.allocator)
	app.editor_window = old_window
	app.editor_window_ready = true
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 800, 180})
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
	old_line_0, old_text_0, old_found_0 := editor_stale_window_test_line(&app, &rt, 0)
	old_line_1, old_text_1, old_found_1 := editor_stale_window_test_line(&app, &rt, 1)
	testing.expect(t, old_found_0 && old_found_1 && old_text_0 == "alpha" && old_text_1 == "beta",
		"the first authoritative presentation should retain the existing visible source rows")
	if !old_found_0 || !old_found_1 { return }

	view_index := editor_view_find(app.editor_views[:], "stale-doc")
	if view_index < 0 { testing.expect(t, false, "the document should have local view state after its first presentation"); return }
	view := &app.editor_views[view_index]
	optimistic_source := [?]u8{
		'd', 'r', 'a', 'f', 't', '\n',
		'b', 'e', 't', 'a', '\n',
		'g', 'a', 'm', 'm', 'a',
	}
	optimistic_bytes, optimistic_allocation_error := make([]u8, len(optimistic_source), allocator=context.allocator)
	if optimistic_allocation_error != nil { testing.expect(t, false, "could not allocate the last-presented optimistic source fixture"); return }
	mem.copy(rawptr(&optimistic_bytes[0]), rawptr(&optimistic_source[0]), len(optimistic_source))
	optimistic_visible := bridge.Visible_Window{
		document_id="stale-doc",
		application_rev=3,
		editor_revision=3,
		start_line=0,
		end_line=3,
		start_byte=0,
		line_byte_length=u64(len(optimistic_source)),
		source=optimistic_bytes,
	}
	optimistic_window, optimistic_ok, optimistic_error := editor_window_from_visible(&optimistic_visible, context.allocator)
	testing.expect(t, optimistic_ok, optimistic_error)
	if !optimistic_ok { return }
	view.optimistic_window = optimistic_window
	view.optimistic_window_ready = true
	view.optimistic_pending_edits = 0
	view.authoritative_revision = 3

	// Model the state-publication interval before its matching bounded window
	// arrives. Keep the newest optimistic rows visible rather than regressing
	// to the older backend base, but reject source interaction until an exact
	// revision window can be installed.
	app.backend.state.application_rev = 2
	app.backend.state.documents[0].editor_revision = 2
	app.backend.state.documents[0].line_count = 8 // the authoritative undo reintroduced several visible rows
	app.backend.state.documents[0].byte_length = u64(len("alpha!\nbeta\ngamma\ndelta\nepsilon\nzeta\neta\ntheta"))
	document = app.backend.state.documents[0]
	editor_stale_window_test_render(&app, &rt, document)
	stale_line_0, stale_text_0, stale_found_0 := editor_stale_window_test_line(&app, &rt, 0)
	stale_line_1, stale_text_1, stale_found_1 := editor_stale_window_test_line(&app, &rt, 1)
	loading_found := false
	for node_id in rt.order {
		if node, node_found := rt.nodes[node_id]; node_found && strings.has_prefix(node.text, "Loading line ") {
			loading_found = true
		}
	}
	testing.expect(t, stale_found_0 && stale_found_1 && stale_text_0 == "draft" && stale_text_1 == "beta",
		"an undo awaiting its new window should keep the latest optimistic presentation instead of flashing the older backend base")
	testing.expect(t, !loading_found,
		"the retained viewport should not expose Loading placeholders during stale-while-revalidate")
	testing.expect(t, stale_line_0 == old_line_0 && stale_line_1 == old_line_1,
		"stale-while-revalidate should preserve the retained line subtree identities")
	stale_placeholder_count := 0
	for node_id in rt.order {
		if node, node_found := rt.nodes[node_id]; node_found && node.kind == .Text &&
		   node.identity_key_numeric && node.identity_key_u64 >= 3 && node.identity_key_u64 < 8 && node.text == "" {
			stale_placeholder_count += 1
		}
	}
	testing.expect(t, stale_placeholder_count >= 2,
		"each visible row beyond the last-good bounded window should have a retained placeholder")
	inspector := alicorn.inspect(&rt)
	defer delete(inspector, context.allocator)
	testing.expect(t, !strings.contains(inspector, "HARD ERROR: repeated unkeyed sibling"),
		"visible rows beyond the bounded window must not collide on an unkeyed retained identity")
	testing.expect(t, app.editor_scroll_owner != 0 && alicorn.text_input_target_is_suspended(&rt, app.editor_scroll_owner),
		"the native text-input target should be suspended while only stale source bytes are available")
	view.caret_byte = 4
	view.selection_anchor = 4
	caret_before := view.caret_byte
	backspace_handled := editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Backspace})
	testing.expect(t, !backspace_handled && len(app.editor_edits) == 0 && view.caret_byte == caret_before &&
		view.optimistic_window_ready && string(view.optimistic_window.source) == string(optimistic_source[:]),
		"stale presentation must reject edits without destroying the newest optimistic source snapshot")

	new_source := [?]u8{
		'a', 'l', 'p', 'h', 'a', '!', '\n',
		'b', 'e', 't', 'a', '\n',
		'g', 'a', 'm', 'm', 'a', '\n',
		'd', 'e', 'l', 't', 'a', '\n',
		'e', 'p', 's', 'i', 'l', 'o', 'n', '\n',
		'z', 'e', 't', 'a', '\n',
		'e', 't', 'a', '\n',
		't', 'h', 'e', 't', 'a',
	}
	new_bytes, new_allocation_error := make([]u8, len(new_source), allocator=context.allocator)
	if new_allocation_error != nil { testing.expect(t, false, "could not allocate the refreshed source fixture"); return }
	mem.copy(rawptr(&new_bytes[0]), rawptr(&new_source[0]), len(new_source))
	app.backend.state.documents[0].byte_length = u64(len(new_source))
	new_visible := bridge.Visible_Window{
		document_id="stale-doc",
		application_rev=2,
		editor_revision=2,
		start_line=0,
		end_line=8,
		start_byte=0,
		line_byte_length=u64(len(new_source)),
		source=new_bytes,
	}
	new_window, new_ok, new_error := editor_window_from_visible(&new_visible, context.allocator)
	testing.expect(t, new_ok, new_error)
	if !new_ok { return }
	if view.optimistic_window_ready {
		editor_window_destroy(&view.optimistic_window, context.allocator)
		view.optimistic_window_ready = false
	}
	view.authoritative_revision = 2
	editor_window_destroy(&app.editor_window, context.allocator)
	app.editor_window = new_window
	app.editor_window_ready = true
	app.backend.state.documents[0].byte_length = u64(len(new_source))
	document = app.backend.state.documents[0]
	editor_stale_window_test_render(&app, &rt, document)
	new_line_0, new_text_0, new_found_0 := editor_stale_window_test_line(&app, &rt, 0)
	new_line_1, new_text_1, new_found_1 := editor_stale_window_test_line(&app, &rt, 1)
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
