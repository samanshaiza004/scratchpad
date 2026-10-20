package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import alicorn "alicorn:runtime"
import bridge "./bridge"

semantic_view_test_node :: proc(rt: ^alicorn.Runtime, key: string) -> (id: alicorn.Node_ID, found: bool) {
	if rt == nil { return }
	for candidate in rt.order {
		node, exists := rt.nodes[candidate]
		if exists && node.key == key { return candidate, true }
	}
	return 0, false
}

@(test)
test_semantic_view_controls_render_all_modes_and_select_current_density :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 800, 520})
	defer alicorn.destroy_runtime(&rt)
	fonts_loaded := alicorn.text_engine_load_font(&rt.text_engine, ALICORN_TEST_UI_FONT_DATA) &&
		alicorn.text_engine_load_font_role(&rt.text_engine, .Monospace, ALICORN_TEST_MONO_FONT_DATA)
	testing.expect(t, fonts_loaded, "semantic-view toolbar fixture should load bundled fonts")
	if !fonts_loaded { return }

	app: App
	document := bridge.State_Document{id="semantic-doc", view_density="skim"}
	ui, build := alicorn.begin_frame(&rt)
	testing.expect(t, build, "semantic-view toolbar should begin a root description")
	if !build { return }
	alicorn.container_begin(&ui, .Root, label="semantic-view-test-root", style=alicorn.layout_style(grow=1, gap=8))
	semantic_view_controls(&app, &ui, &rt, document)
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)

	modes := [?]string{"full", "skim", "outline"}
	for mode in modes {
		id, found := semantic_view_test_node(&rt, fmt.tprintf("document-density-%s", mode))
		testing.expect(t, found, "Full, Skim and Outline must all be reachable from the document toolbar")
		if !found { continue }
		node := rt.nodes[id]
		testing.expect(t, node.kind == .Button && node.bounds.w > 0 && node.bounds.h > 0,
			"each semantic density must be a visible button control")
		testing.expect(t, node.selected == (mode == "skim"),
			"the toolbar should visibly select the document's current density")
	}
}

@(test)
test_semantic_view_frontend_bridge_keeps_source_authoritative :: proc(t: ^testing.T) {
	sync.mutex_lock(&backend_integration_test_mutex)
	defer sync.mutex_unlock(&backend_integration_test_mutex)
	workspace, workspace_error := os.make_directory_temp("", "scratchpad-semantic-view-*", context.temp_allocator)
	if workspace_error != nil { testing.expect(t, false, "semantic-view fixture directory should exist"); return }
	defer _ = os.remove_all(workspace)
	path := fmt.tprintf("%s/outline.md", workspace)
	source := "# Introduction\n\nOpening source.\n\n## Details\n\nMore source.\n"
	if os.write_entire_file_from_string(path, source) != nil { testing.expect(t, false, "semantic-view fixture should be writable"); return }
	library, found := os.lookup_env("SCRATCHPAD_BACKEND_LIBRARY", context.temp_allocator)
	if !found { testing.expect(t, false, "semantic-view integration requires the real backend"); return }
	defer delete(library, context.temp_allocator)
	app: App
	loaded, load_message := bridge.backend_load(&app.backend, library)
	testing.expect(t, loaded, fmt.tprintf("backend should load for semantic-view smoke: %s", load_message))
	if !loaded { return }
	started, start_message := bridge.backend_start(&app.backend, workspace, tree_test_wake, nil, context.allocator)
	testing.expect(t, started, fmt.tprintf("backend should start for semantic-view smoke: %s", start_message))
	if !started { return }
	defer {
		if app.backend.started { _, _ = bridge.backend_stop(&app.backend, context.allocator) }
		editor_views_destroy(&app.editor_views, context.allocator)
	}

	opened := bridge.backend_command(&app.backend, "open_path", path=path, allocator=context.allocator)
	testing.expect(t, opened.ok, "the backend should open the authoritative Markdown source")
	bridge.backend_command_result_destroy(&opened, context.allocator)
	document, document_found := find_document(&app.backend.state, app.backend.state.active)
	if !document_found { testing.expect(t, false, "opened semantic-view source should be published"); return }
	document_id, id_error := strings.clone(document.id, context.allocator)
	if id_error != nil { testing.expect(t, false, "semantic-view document identity should be retained"); return }
	defer delete(document_id, context.allocator)
	before_revision := document.editor_revision
	before_length := document.byte_length
	before := bridge.backend_command(
		&app.backend, "read_visible_lines", document_id=document_id, start_line=0,
		max_lines=bridge.MAX_VISIBLE_LINES, max_bytes=bridge.MAX_VISIBLE_BYTES,
		allocator=context.allocator,
	)
	if !before.ok || !before.visible_window_owned { testing.expect(t, false, "the canonical source should be readable before changing density"); bridge.backend_command_result_destroy(&before, context.allocator); return }

	changed := bridge.backend_command(
		&app.backend, "set_view_density", document_id=document_id, view_density="outline",
		allocator=context.allocator,
	)
	testing.expect(t, changed.ok, "the frontend should be able to select Outline through the backend command")
	bridge.backend_command_result_destroy(&changed, context.allocator)
	window_result: bridge.Backend_Command_Result
	ready := false
	wait_started := time.tick_now()
	for time.tick_since(wait_started) < 5*time.Second {
		window_result = bridge.backend_command(
			&app.backend, "read_view_window", document_id=document_id,
			projection_first=0, projection_limit=16, read_latest_after=false,
			allocator=context.allocator,
		)
		if window_result.ok && window_result.semantic_view_window_owned && window_result.semantic_view_window.ready {
			ready = true
			break
		}
		bridge.backend_command_result_destroy(&window_result, context.allocator)
		_, _, _ = bridge.backend_consume_wake(&app.backend, context.allocator)
		time.sleep(10*time.Millisecond)
	}
	testing.expect(t, ready, "the frontend should eventually receive a current bounded outline window")
	if !ready { bridge.backend_command_result_destroy(&before, context.allocator); return }
	window := window_result.semantic_view_window
	testing.expect(t,
		window.document_id == document_id && window.mode == "outline" && window.revision == before_revision &&
		window.supported && window.total == 2 && len(window.segments) == 2,
		"the reduced view must identify its document, selected density, current revision and bounded outline")
	if len(window.segments) == 2 {
		first := window.segments[0]
		testing.expect(t, first.status == "current" && first.source_revision == before_revision &&
			first.start_byte >= 0 && first.end_byte > first.start_byte && first.source_start_line == 1 &&
			first.text == "# Introduction",
			"each displayed excerpt must carry a current source range and source line mapping")
	}
	bridge.backend_command_result_destroy(&window_result, context.allocator)

	after := bridge.backend_command(
		&app.backend, "read_visible_lines", document_id=document_id, start_line=0,
		max_lines=bridge.MAX_VISIBLE_LINES, max_bytes=bridge.MAX_VISIBLE_BYTES,
		allocator=context.allocator,
	)
	if after.ok && after.visible_window_owned {
		after_document, after_document_found := find_document(&app.backend.state, document_id)
		same_source := after_document_found && before_revision == after_document.editor_revision &&
			before_length == u64(len(after.visible_window.source)) && len(before.visible_window.source) == len(after.visible_window.source)
		if same_source {
			for index in 0..<len(before.visible_window.source) {
				if before.visible_window.source[index] != after.visible_window.source[index] { same_source = false; break }
			}
		}
		testing.expect(t, same_source, "switching density must preserve every authoritative source byte and its revision")
	} else {
		testing.expect(t, false, "the canonical source should remain readable after changing density")
	}
	bridge.backend_command_result_destroy(&after, context.allocator)
	bridge.backend_command_result_destroy(&before, context.allocator)
}
