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

semantic_view_test_frame :: proc(rt: ^alicorn.Runtime, app: ^App, document: bridge.State_Document, view: ^Editor_View_State, mode := "skim") {
	ui, build := alicorn.begin_frame(rt)
	if !build { return }
	alicorn.container_begin(&ui, .Root, style=alicorn.layout_style(.Column, grow=1))
	_ = semantic_view_render(app, &ui, document, view, mode)
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
}

semantic_view_test_dispatch_source_navigation :: proc(
	app: ^App,
	rt: ^alicorn.Runtime,
	document_id: string,
	revision, source_start, source_end, source_line: u64,
) -> bool {
	alicorn.invalidate_root(rt, "schedule semantic source navigation from a row action")
	ui, build := alicorn.begin_frame(rt)
	if !build { return false }
	alicorn.container_begin(&ui, .Root, style=alicorn.layout_style(.Column, grow=1))
	queued := frame_deferred_action_schedule(
		app, .Go_To_Projection_Source,
		document_id=document_id,
		editor_revision=revision,
		source_start=source_start,
		source_end=source_end,
		source_line=source_line,
	)
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
	if queued { frame_deferred_action_run(app, rt) }
	return queued
}

@(test)
test_semantic_view_excerpt_layout_is_compact_and_unclipped :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 800, 520})
	defer alicorn.destroy_runtime(&rt)
	if !alicorn.text_engine_load_font(&rt.text_engine, ALICORN_TEST_UI_FONT_DATA) ||
	   !alicorn.text_engine_load_font_role(&rt.text_engine, .Monospace, ALICORN_TEST_MONO_FONT_DATA) {
		testing.expect(t, false, "semantic excerpt layout requires the real bundled fonts")
		return
	}
	document := bridge.State_Document{id="excerpt-doc", language="tsx", view_density="skim", editor_revision=1, presentation_ready=true}
	segments := [?]bridge.Semantic_View_Segment{{
		document_id=document.id, source_revision=1, start_byte=10, end_byte=80,
		source_start_line=18, source_end_line=19, label="function", section_context="App",
		status="current", text="function App() {\n  const rows = useState([]);", omitted_before=true, omitted_after=true,
		omitted_before_lines=12, omitted_after_lines=3,
	}}
	view := Editor_View_State{semantic_window_owned=true, semantic_window=bridge.Semantic_View_Window{
		document_id=document.id, mode="skim", revision=1, ready=true, supported=true, total=1, segments=segments[:],
	}}
	defer semantic_view_layout_destroy(&view.semantic_layout)
	app: App
	for frame in 0..<3 {
		alicorn.invalidate_root(&rt, "settle semantic excerpt fixture")
		ui, build := alicorn.begin_frame(&rt)
		if !build { continue }
		alicorn.container_begin(&ui, .Root, style=alicorn.layout_style(.Column, grow=1))
		_ = semantic_view_render(&app, &ui, document, &view, "skim")
		alicorn.container_end(&ui)
		alicorn.end_frame(&ui)
	}
	rows, markers, snippets, actions := 0, 0, 0, 0
	for id in rt.order {
		node := rt.nodes[id]
		if node.label == "scratchpad-semantic-view-row" {
			rows += 1
			testing.expect(t, node.bounds.h < 140, fmt.tprintf("a two-line excerpt must not occupy a fixed oversized card: height=%g", node.bounds.h))
		}
		if strings.has_prefix(node.text, "···") {
			markers += 1
			testing.expect(t, node.text_run_valid && node.bounds.h+0.1 >= node.text_run.height,
				fmt.tprintf("omission label must fit its shaped text: bounds=%g text=%g", node.bounds.h, node.text_run.height))
			if node.text == "··· 3 lines omitted ···" {
				for candidate in rt.order {
					if rt.nodes[candidate].text == segments[0].text {
						snippet := rt.nodes[candidate]
						testing.expect(t, node.bounds.y >= snippet.bounds.y+snippet.bounds.h,
						"trailing omission must follow the source excerpt")
					}
				}
			}
		}
		if node.kind == .Text && node.text == segments[0].text {
			snippets += 1
			testing.expect(t, node.font == .Monospace, "code excerpts must use the editor's monospace font")
		}
		if node.kind == .Button && node.label == "Go to source" {
			actions += 1
			testing.expect(t, node.focusable && node.bounds.w > 0, "every source excerpt must have a keyboard-reachable source action")
		}
	}
	testing.expect(t, rows == 1 && markers == 2 && snippets == 1 && actions == 1, fmt.tprintf("fixture must exercise the real semantic row, source action and both compact omission labels: rows=%d markers=%d snippets=%d actions=%d", rows, markers, snippets, actions))
}

@(test)
test_semantic_outline_indents_markdown_heading_levels :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 800, 600})
	defer alicorn.destroy_runtime(&rt)
	if !alicorn.text_engine_load_font(&rt.text_engine, ALICORN_TEST_UI_FONT_DATA) { testing.expect(t, false, "outline hierarchy requires the bundled UI font"); return }
	document := bridge.State_Document{id="hierarchy-doc", language="markdown", view_density="outline", editor_revision=1, presentation_ready=true}
	segments := [?]bridge.Semantic_View_Segment{
		{document_id=document.id, source_revision=1, start_byte=0, end_byte=12, source_start_line=1, label="heading", depth=0, status="current", text="# Root", ordinal=0},
		{document_id=document.id, source_revision=1, start_byte=20, end_byte=32, source_start_line=4, label="heading", depth=1, status="current", text="## Child", ordinal=1, omitted_before=true, omitted_before_lines=2},
		{document_id=document.id, source_revision=1, start_byte=40, end_byte=54, source_start_line=7, label="heading", depth=2, status="current", text="### Nested", ordinal=2, omitted_before=true, omitted_before_lines=2},
	}
	view := Editor_View_State{semantic_window_owned=true, semantic_window=bridge.Semantic_View_Window{
		document_id=document.id, mode="outline", revision=1, ready=true, supported=true, generation=1, total=3, segments=segments[:],
	}}
	defer semantic_view_layout_destroy(&view.semantic_layout)
	app: App
	for frame in 0..<4 {
		alicorn.invalidate_root(&rt, "settle semantic outline hierarchy")
		semantic_view_test_frame(&rt, &app, document, &view, "outline")
	}
	positions: [3]f32
	found := [3]bool{}
	heading_texts := [?]string{"# Root", "## Child", "### Nested"}
	for id in rt.order {
		node := rt.nodes[id]
		for text, index in heading_texts {
			if node.kind == .Text && node.text == text { positions[index], found[index] = node.bounds.x, true }
		}
	}
	for index in 0..<3 { testing.expect(t, found[index], "all heading levels should appear in the Outline") }
	if found[0] && found[1] && found[2] {
		testing.expect(t, positions[1] > positions[0]+10 && positions[2] > positions[1]+10,
			fmt.tprintf("heading depth should be visible through indentation: x=%v", positions))
	}
}

@(test)
test_semantic_view_prose_reflows_at_narrow_width_and_editor_zoom :: proc(t: ^testing.T) {
	scales := [?]f32{1, 1.5}
	widths := [?]f32{280, 800}
	for scale in scales {
		for width in widths {
			rt := alicorn.new_runtime(alicorn.Rect{0, 0, width, 700})
			defer alicorn.destroy_runtime(&rt)
			if !alicorn.text_engine_load_font(&rt.text_engine, ALICORN_TEST_UI_FONT_DATA) { testing.expect(t, false, "prose requires the bundled UI font"); return }
			document := bridge.State_Document{id="prose-doc", language="markdown", view_density="skim", editor_revision=1, presentation_ready=true}
			segments := [?]bridge.Semantic_View_Segment{
				{document_id=document.id, source_revision=1, start_byte=0, end_byte=9, status="current", text="# Heading", label="heading", ordinal=0},
				{document_id=document.id, source_revision=1, start_byte=10, end_byte=200, status="current", label="paragraph opening", ordinal=1, omitted_before=true,
				 text="This deliberately long paragraph must wrap into its measured row. Resizing the viewport or changing editor zoom must preserve all of these words without clipping text or leaving an oversized empty card."},
			}
			view := Editor_View_State{semantic_window_owned=true, semantic_window=bridge.Semantic_View_Window{
				document_id=document.id, mode="skim", revision=1, ready=true, supported=true, generation=1, total=2, segments=segments[:],
			}}
			defer semantic_view_layout_destroy(&view.semantic_layout)
			app := App{editor_text_scale=scale}
			for frame in 0..<4 {
				alicorn.invalidate_root(&rt, "settle wrapped semantic view")
				semantic_view_test_frame(&rt, &app, document, &view)
			}
			shapes := rt.text_engine.shape_calls
			alicorn.invalidate_root(&rt, "unrelated description rebuild")
			semantic_view_test_frame(&rt, &app, document, &view)
			testing.expect(t, rt.text_engine.shape_calls == shapes, "unchanged excerpts must reuse their measured text across unrelated rebuilds")
			for id in rt.order {
				node := rt.nodes[id]
				if node.kind != .Text { continue }
				for segment in segments {
					if node.text == segment.text {
						testing.expect(t, node.text_run_valid && node.bounds.h+0.1 >= node.text_run.height,
							fmt.tprintf("wrapped excerpt must fit at width=%g scale=%g: bounds=%g text=%g actual_width=%g measured_width=%g", width, scale, node.bounds.h, node.text_run.height, node.bounds.w, view.semantic_layout.width))
					}
				}
			}
			testing.expect(t, alicorn.virtual_list_height_index_item_height(&view.semantic_layout.index, 1) >
				alicorn.virtual_list_height_index_item_height(&view.semantic_layout.index, 0), "paragraph and heading must use their individual content heights")
		}
	}
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
	semantic_view_controls(&app, &ui, &rt, document, nil)
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
		set_error(&app, "")
		tree_clear_directories(&app)
		delete(app.tree_directories)
		if app.tree_root_path != "" { delete(app.tree_root_path, context.allocator) }
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
		fmt.tprintf("the reduced view must identify its document, selected density, current revision and bounded outline: id=%s mode=%s revision=%d expected=%d supported=%v total=%d returned=%d", window.document_id, window.mode, window.revision, before_revision, window.supported, window.total, len(window.segments)))
	if len(window.segments) == 2 {
		testing.expect(t, window.segments[1].depth == 1,
			fmt.tprintf("Outline bridge must preserve heading depth: got %d, want 1", window.segments[1].depth))
	}
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

	// A toolbar command runs during description. The borrowed document strings
	// must remain alive until this frame finishes, just as for tab switching.
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 800, 520})
	defer alicorn.destroy_runtime(&rt)
	defer deferred_action_destroy(&app.frame_deferred_action)
	application_revision := app.backend.state.application_rev
	ui, build := alicorn.begin_frame(&rt)
	if build {
		alicorn.container_begin(&ui, .Root, style=alicorn.layout_style(grow=1))
		semantic_view_set_density(&app, &rt, document_id, "skim")
		testing.expect(t, app.backend.state.application_rev == application_revision,
			"changing a view during description must not replace the borrowed document snapshot")
		testing.expect(t, app.frame_deferred_action_pending,
			"the mode change must own its document ID until the frame has finished")
		alicorn.container_end(&ui)
		alicorn.end_frame(&ui)
		frame_deferred_action_run(&app, &rt)
		current, exists := find_document(&app.backend.state, document_id)
		testing.expect(t, exists && current.view_density == "skim", "the deferred mode change must target the original document")
		if exists {
			source_start := u64(len(source)-len("More source.\n"))
			source_end := source_start+u64(len("More source."))
			queued := semantic_view_test_dispatch_source_navigation(
				&app, &rt, document_id, before_revision, source_start, source_end, 7,
			)
			testing.expect(t, queued, "the excerpt's Go to source action must queue a post-description navigation")
			navigated, still_open := find_document(&app.backend.state, document_id)
			view_index := editor_view_find(app.editor_views[:], document_id)
			navigation_ok := still_open && navigated.view_density == "full" && view_index >= 0
			if navigation_ok {
				source_view := &app.editor_views[view_index]
				navigation_ok = source_view.caret_byte == source_start && source_view.selection_anchor == source_start &&
					source_view.reveal_request.pending &&
					source_view.reveal_request.editor_revision == before_revision &&
					source_view.reveal_request.logical_line == 6 &&
					source_view.reveal_request.source_start == source_start &&
					source_view.reveal_request.source_end == source_end
			}
			testing.expect(t, navigation_ok, "Go to source must switch to Full and queue a revision-matched reveal to the excerpt's source location")
			caret_before_stale := app.editor_views[view_index].caret_byte if view_index >= 0 else 0
			stale_queued := semantic_view_test_dispatch_source_navigation(
				&app, &rt, document_id, before_revision+1, 0, 1, 1,
			)
			view_index = editor_view_find(app.editor_views[:], document_id)
			stale_unchanged := view_index >= 0 && app.editor_views[view_index].caret_byte == caret_before_stale
			testing.expect(t, stale_queued && stale_unchanged && app.error_message != "", "a stale excerpt must report an error without moving the caret")
		}
	}
}
