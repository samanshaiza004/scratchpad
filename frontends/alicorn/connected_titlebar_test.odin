package main

import "core:testing"
import "core:fmt"
import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"
import bridge "./bridge"

connected_titlebar_test_node :: proc(rt: ^alicorn.Runtime, label: string) -> alicorn.Node_ID {
	for id in rt.order {
		if node, found := rt.nodes[id]; found && node.active && node.label == label { return id }
	}
	return 0
}

connected_titlebar_test_prepare :: proc(app: ^App, rt: ^alicorn.Runtime, documents: []bridge.State_Document, width, scale: f32) -> bool {
	app.backend.started = true
	app.backend.state.has_workspace = true
	app.backend.state.workspace_root = "C:/connected-titlebar-fixture"
	app.backend.state.sidebar_width = 300
	app.backend.state.documents = documents
	app.backend.state.active = documents[0].id
	app.tree_root_path = app.backend.state.workspace_root
	app.tree_directories = make([dynamic]Tree_Directory, 0, allocator=context.allocator)
	app.editor_views = make([dynamic]Editor_View_State, 0, allocator=context.allocator)
	app.editor_edits = make([dynamic]Editor_Edit_Intent, 0, allocator=context.allocator)
	app.editor_row_targets = make([dynamic]Editor_Row_Target, 0, allocator=context.allocator)
	app.window_chrome_metrics = host.Window_Chrome_Metrics{
		header={0, 0, width, SCRATCHPAD_CONTENT_TITLEBAR_HEIGHT},
		content_start_x=80, content_end_x=width-144, display_scale=scale,
	}
	init_menus(app)
	_ = alicorn.set_presentation_scale(rt, scale, scale)
	return alicorn.text_engine_load_font(&rt.text_engine, ALICORN_TEST_UI_FONT_DATA) &&
		alicorn.text_engine_load_font_role(&rt.text_engine, .Monospace, ALICORN_TEST_MONO_FONT_DATA)
}

connected_titlebar_test_destroy :: proc(app: ^App) {
	if len(app.editor_presented_document_id) > 0 { delete(app.editor_presented_document_id, context.allocator) }
	if len(app.editor_window_error) > 0 { delete(app.editor_window_error, context.allocator) }
	find_presentation_destroy(&app.find_presentation, context.allocator)
	editor_views_destroy(&app.editor_views)
	delete(app.editor_edits)
	delete(app.editor_row_targets)
	delete(app.tree_directories)
}

connected_titlebar_test_expect_join :: proc(t: ^testing.T, app: ^App, rt: ^alicorn.Runtime) {
	tabs_id := connected_titlebar_test_node(rt, "scratchpad-titlebar-tabs-region")
	paper_id := connected_titlebar_test_node(rt, "document-surface")
	tabs, tabs_ok := alicorn.node_info(rt, tabs_id)
	paper, paper_ok := alicorn.node_info(rt, paper_id)
	selected, selected_ok := alicorn.node_info(rt, app.document_connected_tab_node)
	testing.expect(t, tabs_ok && paper_ok && selected_ok,
		"the document pane should retain its tab region, selected tab, and paper surface")
	if !tabs_ok || !paper_ok || !selected_ok { return }
	testing.expect(t, tabs.bounds.x == paper.bounds.x && tabs.bounds.y+tabs.bounds.h == paper.bounds.y &&
		selected.bounds.y+selected.bounds.h == paper.bounds.y,
		"the same finalized Split pane must align tabs and paper, with no vertical join gap")
	testing.expect(t, rt.nodes[tabs_id].bounds.x == rt.nodes[paper_id].bounds.x,
		"target geometry must align before physical-pixel finalization")
	testing.expect(t, tabs.bounds.x+tabs.bounds.w <= app.window_chrome_metrics.content_end_x-SCRATCHPAD_CONTENT_TITLEBAR_DRAG_WIDTH+1,
		"tabs must leave the measured caption reservation and a usable drag target")
}

@(test)
test_connected_titlebar_tracks_shared_split_in_retained_layout :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows && ODIN_OS != .Darwin { return }
	for scale in ([4]f32{1, 1.25, 1.5, 2}) {
		rt := alicorn.new_runtime({0, 0, 1200, 760})
		app: App
		documents := [?]bridge.State_Document{{id="connected-doc", path="sample.bin", view_kind="unsupported"}}
		loaded := connected_titlebar_test_prepare(&app, &rt, documents[:], 1200, scale)
		testing.expect(t, loaded, "the connected titlebar fixture should load both bundled font roles")
		if !loaded { connected_titlebar_test_destroy(&app); alicorn.destroy_runtime(&rt); continue }
		_ = build_app(rawptr(&app), &rt, 1200, 760, scale)
		connected_titlebar_test_expect_join(t, &app, &rt)
		for _ in 0..<3 { if rt.invalidated { _ = build_app(rawptr(&app), &rt, 1200, 760, scale) } }
		divider_id := connected_titlebar_test_node(&rt, "split-divider")
		divider, divider_ok := alicorn.node_info(&rt, divider_id)
		testing.expect(t, divider_ok, "the workspace divider should remain a retained header interaction target")
		if divider_ok {
			frames_built := rt.stats.frames_built
			x, y := divider.bounds.x+divider.bounds.w*0.5, SCRATCHPAD_CONTENT_TITLEBAR_HEIGHT*0.5
			target := alicorn.process_pointer(&rt, {kind=.Down, x=x, y=y, button=alicorn.POINTER_BUTTON_PRIMARY})
			testing.expect(t, target == divider_id, "the full-height divider should be operable inside the native titlebar band")
			_ = alicorn.process_pointer(&rt, {kind=.Move, x=x+137.25, y=y})
			presentation, ready := alicorn.begin_presentation_frame(&rt)
			testing.expect(t, ready, "a sidebar drag should be presentable without rebuilding application descriptions")
			if ready { alicorn.end_presentation_frame(&presentation) }
			connected_titlebar_test_expect_join(t, &app, &rt)
			testing.expect(t, rt.stats.frames_built == frames_built,
				"header and editor alignment must update in the same retained presentation pass")
			_ = alicorn.process_pointer(&rt, {kind=.Up, x=x+137.25, y=y, button=alicorn.POINTER_BUTTON_PRIMARY})
		}
		connected_titlebar_test_destroy(&app)
		alicorn.destroy_runtime(&rt)
	}
}

@(test)
test_connected_titlebar_resolves_editor_theme_and_disconnects_for_find :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows && ODIN_OS != .Darwin { return }
	rt := alicorn.new_runtime({0, 0, 1000, 680})
	defer alicorn.destroy_runtime(&rt)
	app: App
	documents := [?]bridge.State_Document{{id="connected-theme-doc", path="sample.txt", language="plain-text", line_count=1, preview=true}}
	loaded := connected_titlebar_test_prepare(&app, &rt, documents[:], 1000, 1)
	defer connected_titlebar_test_destroy(&app)
	testing.expect(t, loaded, "the connected theme fixture should load its bundled font roles")
	if !loaded { return }
	for choice in ([3]Scratchpad_Theme_Choice{.Warm, .Cool_Light, .Workbench_Relief}) {
		app.theme_choice = choice
		if app.style_theme_runtime == &rt { scratchpad_theme_apply_registered(&app) }
		alicorn.invalidate_root(&rt, "connected tab theme fixture")
		_ = build_app(rawptr(&app), &rt, 1000, 680, 1)
		paper_fill, paper_ok := alicorn.style_extension_color(&rt, app.editor_theme, scratchpad_editor_paper_surface_role())
		paper_ink := alicorn.style_theme_color(&rt, app.editor_theme, .Text)
		selected, selected_ok := rt.nodes[app.document_connected_tab_node]
		matched := false
		label_matched := false
		if selected_ok {
			for command in selected.paint {
				if surface, ok := command.payload.(alicorn.Surface_Paint); ok && surface.fill == paper_fill { matched = true }
			}
		}
		for id in rt.order {
			node, found := rt.nodes[id]
			if !found || !node.active || node.kind != .Text || node.text != "sample.txt" { continue }
			for command in node.paint {
				if text, ok := command.payload.(alicorn.Text_Paint); ok && text.color == paper_ink && len(text.spans) == 0 { label_matched = true }
			}
		}
		testing.expect(t, paper_ok && matched,
			"the active document tab must paint with the actual editor-paper extension role in every theme")
		testing.expect(t, label_matched,
			"a selected preview tab keeps italic intent but uses readable paper ink without a workbench-muted color span")
	}
	app.find_open = true
	alicorn.invalidate_root(&rt, "find interrupts the paper join")
	_ = build_app(rawptr(&app), &rt, 1000, 680, 1)
	testing.expect(t, app.document_connected_tab_node == 0,
		"Find inserts another surface, so the tab must not advertise a direct connection to paper")
}

@(test)
test_connected_titlebar_narrow_overflow_reserves_native_caption_band :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows && ODIN_OS != .Darwin { return }
	for width in ([3]f32{600, 700, 1000}) {
		rt := alicorn.new_runtime({0, 0, width, 680})
		app: App
		documents := [?]bridge.State_Document{
			{id="narrow-tab-1", path="one.bin", view_kind="unsupported"},
			{id="narrow-tab-2", path="two.bin", view_kind="unsupported"},
			{id="narrow-tab-3", path="three.bin", view_kind="unsupported"},
			{id="narrow-tab-4", path="four.bin", view_kind="unsupported"},
			{id="narrow-tab-5", path="five.bin", view_kind="unsupported"},
			{id="narrow-tab-6", path="six.bin", view_kind="unsupported"},
		}
		loaded := connected_titlebar_test_prepare(&app, &rt, documents[:], width, 1.25)
		app.backend.state.active = "narrow-tab-6"
		testing.expect(t, loaded, "the narrow titlebar fixture should load its bundled font roles")
		if loaded {
			_ = build_app(rawptr(&app), &rt, int(width), 680, 1.25)
			connected_titlebar_test_expect_join(t, &app, &rt)
			scroll_id := connected_titlebar_test_node(&rt, "tab-bar")
			scroll, scroll_ok := alicorn.node_info(&rt, scroll_id)
			selected, selected_ok := alicorn.node_info(&rt, app.document_connected_tab_node)
			testing.expect(t, scroll_ok && selected_ok && scroll.scroll_content_width > scroll.scroll_viewport_width,
				"many document tabs should use horizontal overflow inside the narrowed pane")
			if scroll_ok && selected_ok {
				testing.expect(t, selected.bounds.x >= scroll.bounds.x-1 &&
					selected.bounds.x+selected.bounds.w <= scroll.bounds.x+scroll.bounds.w+1,
					fmt.tprintf("selected tab must fit native-safe scroller: window=%.1f selected=%v scroll=%v offset=%.1f content=%.1f",
						width, selected.bounds, scroll.bounds, scroll.scroll_offset_x, scroll.scroll_content_width))
			}
		}
		connected_titlebar_test_destroy(&app)
		alicorn.destroy_runtime(&rt)
	}
}
