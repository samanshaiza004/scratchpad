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

connected_titlebar_test_key :: proc(rt: ^alicorn.Runtime, key: string) -> alicorn.Node_ID {
	for id in rt.order {
		if node, found := rt.nodes[id]; found && node.active && node.key == key { return id }
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
	sidebar_header_id := connected_titlebar_test_node(rt, "scratchpad-titlebar-sidebar-band")
	switcher_id := connected_titlebar_test_node(rt, "workspace-panel-tabs")
	path_id := connected_titlebar_test_key(rt, "workspace-panel-root-path")
	path_text_id := connected_titlebar_test_key(rt, "workspace-panel-root-path-text")
	search_id := connected_titlebar_test_key(rt, "workspace-panel-search")
	testing.expect(t, connected_titlebar_test_key(rt, "workspace-panel-files") == 0 &&
		connected_titlebar_test_key(rt, "workspace-panel-tasks") == 0 &&
		connected_titlebar_test_key(rt, "workspace-panel-links") == 0,
		"the sidebar titlebar should omit permanent view switches")
	drag_id := connected_titlebar_test_node(rt, "scratchpad-titlebar-sidebar-drag-space")
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
	sidebar_header, sidebar_header_ok := alicorn.node_info(rt, sidebar_header_id)
	switcher, switcher_ok := alicorn.node_info(rt, switcher_id)
	path, path_ok := alicorn.node_info(rt, path_id)
	path_text, path_text_ok := rt.nodes[path_text_id]
	search, search_ok := alicorn.node_info(rt, search_id)
	drag, drag_ok := alicorn.node_info(rt, drag_id)
	path_interactive := false
	search_interactive := false
	for region in app.window_chrome_regions[:app.window_chrome_region_count] {
		if region.node == path_id && region.kind == .Interactive { path_interactive = true }
		if region.node == search_id && region.kind == .Interactive { search_interactive = true }
	}
	parent_id: alicorn.Node_ID
	if sidebar_node, found := rt.nodes[sidebar_header_id]; found { parent_id = sidebar_node.parent }
	parent, parent_ok := alicorn.node_info(rt, parent_id)
	if sidebar_header_ok && parent_ok {
		testing.expect(t, switcher_ok && path_ok && path_text_ok && path_text.kind == .Button && search_ok && drag_ok && path_interactive && search_interactive &&
			path_text.label == app.backend.state.workspace_root && abs(sidebar_header.bounds.w-parent.bounds.w) < 1 &&
			path.bounds.x+path.bounds.w <= search.bounds.x+1 &&
			abs(search.bounds.x+search.bounds.w-drag.bounds.x) < 1 &&
			abs(drag.bounds.x+drag.bounds.w-(sidebar_header.bounds.x+sidebar_header.bounds.w)) < 1 &&
			abs((search.bounds.x+search.bounds.w)-(switcher.bounds.x+switcher.bounds.w)) < 1 && drag.bounds.w == 8,
			fmt.tprintf("sidebar titlebar should show the workspace path beside Search and retain its trailing caption drag inset: header=%v parent=%v path=%v search=%v drag=%v pathLabel=%q pathInteractive=%t searchInteractive=%t",
				sidebar_header.bounds, parent.bounds, path.bounds, search.bounds, drag.bounds, path_text.label, path_interactive, search_interactive))
	} else {
		testing.expect(t, false, "the sidebar titlebar should remain a child of the retained Split pane")
	}
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
			path_before, path_before_ok := alicorn.node_info(&rt, connected_titlebar_test_key(&rt, "workspace-panel-root-path"))
			search_before, search_before_ok := alicorn.node_info(&rt, connected_titlebar_test_key(&rt, "workspace-panel-search"))
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
			path_after, path_after_ok := alicorn.node_info(&rt, connected_titlebar_test_key(&rt, "workspace-panel-root-path"))
			search_after, search_after_ok := alicorn.node_info(&rt, connected_titlebar_test_key(&rt, "workspace-panel-search"))
			testing.expect(t, path_before_ok && search_before_ok && path_after_ok && search_after_ok &&
				path_after.bounds.w-path_before.bounds.w > 50 && abs(search_before.bounds.w-search_after.bounds.w) < 1,
				fmt.tprintf("a retained sidebar drag should grow the workspace path region without resizing Search: scale=%v path=%v→%v search=%v→%v",
					scale, path_before.bounds.w, path_after.bounds.w, search_before.bounds.w, search_after.bounds.w))
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

connected_titlebar_test_semantic_selection_matches :: proc(
	rt: ^alicorn.Runtime,
	tab_ids: []alicorn.Semantic_ID,
	selected_id: alicorn.Semantic_ID,
) -> bool {
	snapshot := alicorn.semantic_snapshot(rt, context.temp_allocator)
	defer alicorn.semantic_snapshot_destroy(&snapshot)
	selected_count := 0
	for semantic_id in tab_ids {
		node_found := false
		for node in snapshot.nodes {
			if node.id != semantic_id { continue }
			node_found = true
			node_selected := alicorn.semantic_states_has(node.states, .Selected)
			if node.role != .Tab || node_selected != (semantic_id == selected_id) { return false }
			if node_selected { selected_count += 1 }
			break
		}
		if !node_found { return false }
	}
	return selected_count == 1
}

connected_titlebar_test_tab_semantics_unchanged :: proc(
	before, after: alicorn.Semantic_Snapshot,
	ids: []alicorn.Semantic_ID,
) -> bool {
	for id in ids {
		old_node: alicorn.Semantic_Node
		new_node: alicorn.Semantic_Node
		old_found, new_found := false, false
		for node in before.nodes {
			if node.id == id { old_node, old_found = node, true; break }
		}
		for node in after.nodes {
			if node.id == id { new_node, new_found = node, true; break }
		}
		if !old_found || !new_found { return false }
		if old_node.role != new_node.role || old_node.label != new_node.label ||
		   old_node.states != new_node.states || old_node.actions != new_node.actions ||
		   old_node.parent != new_node.parent || old_node.bounds != new_node.bounds ||
		   old_node.has_bounds != new_node.has_bounds || old_node.tree_order != new_node.tree_order ||
		   old_node.position_in_set != new_node.position_in_set || old_node.size_of_set != new_node.size_of_set {
			return false
		}
	}
	return true
}
connected_titlebar_test_chrome_regions_match :: proc(
	app: ^App,
	rt: ^alicorn.Runtime,
	expected: []host.Window_Chrome_Region,
	expected_bounds: map[alicorn.Node_ID]alicorn.Rect,
) -> bool {
	if app.window_chrome_region_count != len(expected) { return false }
	for index in 0..<len(expected) {
		region := app.window_chrome_regions[index]
		if region.node != expected[index].node || region.kind != expected[index].kind { return false }
		before, before_found := expected_bounds[region.node]
		node, node_found := alicorn.node_info(rt, region.node)
		if !before_found || !node_found || node.bounds != before { return false }
	}
	return true
}
connected_titlebar_test_button_in_tab_tree :: proc(rt: ^alicorn.Runtime, id: alicorn.Node_ID, tabs: []alicorn.Semantic_ID) -> bool {
	for current := id; current != 0; {
		node, found := rt.nodes[current]
		if !found { return false }
		for semantic_id in tabs {
			if node.semantic_id == semantic_id { return true }
		}
		current = node.parent
	}
	return false
}

connected_titlebar_test_tab_node :: proc(rt: ^alicorn.Runtime, semantic_id: alicorn.Semantic_ID) -> alicorn.Node_ID {
	if rt == nil { return 0 }
	for id in rt.order {
		node, found := rt.nodes[id]
		if found && node.active && node.kind == .Button && node.button_variant == .Tab && node.semantic_id == semantic_id {
			return id
		}
	}
	return 0
}

connected_titlebar_test_selection_decoration_case :: proc(t: ^testing.T, reduce_motion: bool) {
	when ODIN_OS != .Windows && ODIN_OS != .Darwin { return }
	rt := alicorn.new_runtime({0, 0, 1200, 760})
	defer alicorn.destroy_runtime(&rt)
	app: App
	documents := [?]bridge.State_Document{
		{id="motion-tab-a", path="alpha.txt", language="plain-text", line_count=1, preview=true},
		{id="motion-tab-b", path="beta.txt", language="plain-text", line_count=1, preview=true},
		{id="motion-tab-c", path="gamma.txt", language="plain-text", line_count=1, preview=true},
	}
	loaded := connected_titlebar_test_prepare(&app, &rt, documents[:], 1200, 1)
	defer connected_titlebar_test_destroy(&app)
	testing.expect(t, loaded, "the connected-tab motion fixture should load its font roles")
	if !loaded { return }
	app.accessibility_appearance_override_enabled = true
	app.accessibility_appearance.reduce_motion = reduce_motion
	_ = alicorn.motion_clock_set_time(&rt, alicorn.Motion_Time(0))
	_ = build_app(rawptr(&app), &rt, 1200, 760, 1)
	initial_stats := alicorn.motion_diagnostics_stats(&rt)
	_, paper_ok := alicorn.style_extension_color(&rt, app.editor_theme, scratchpad_editor_paper_surface_role())
	testing.expect(t, paper_ok && app.document_connected_tab_node != 0 && alicorn.motion_activity(&rt).active_owners == 0,
		fmt.tprintf("connected tabs should begin settled with the editor paper surface: paper=%v theme=%d find=%v connected_node=%d",
			paper_ok, app.editor_theme, app.find_open, app.document_connected_tab_node))

	tab_semantic_ids := [?]alicorn.Semantic_ID{
		document_tab_semantic_id("motion-tab-a"),
		document_tab_semantic_id("motion-tab-b"),
		document_tab_semantic_id("motion-tab-c"),
	}
	testing.expect(t, connected_titlebar_test_semantic_selection_matches(&rt, tab_semantic_ids[:], tab_semantic_ids[0]),
		"the selected tab semantic state should be immediate without a selection-line transition")
	chrome_regions_before := make([dynamic]host.Window_Chrome_Region, 0, app.window_chrome_region_count, allocator=context.temp_allocator)
	chrome_bounds_before := make(map[alicorn.Node_ID]alicorn.Rect, allocator=context.temp_allocator)
	for region in app.window_chrome_regions[:app.window_chrome_region_count] {
		append(&chrome_regions_before, region)
		node, node_found := alicorn.node_info(&rt, region.node)
		if node_found { chrome_bounds_before[region.node] = node.bounds }
	}
	testing.expect(t, len(chrome_regions_before) > 0, "the motion fixture should register native caption and drag regions")
	keyboard_focus_before := rt.focused
	semantic_focus_before := rt.semantic_keyboard_focus
	button_bounds := make(map[alicorn.Node_ID]alicorn.Rect, allocator=context.temp_allocator)
	for id in rt.order {
		node, found := rt.nodes[id]
		if !found || !node.active || node.kind != .Button ||
			!connected_titlebar_test_button_in_tab_tree(&rt, id, tab_semantic_ids[:]) { continue }
		info, info_ok := alicorn.node_info(&rt, id)
		if info_ok { button_bounds[id] = info.hit_bounds }
	}

	app.backend.state.active = "motion-tab-b"
	alicorn.invalidate_root(&rt, "motion tab selection B")
	_ = alicorn.motion_clock_set_time(&rt, alicorn.Motion_Time(10_000_000))
	_ = build_app(rawptr(&app), &rt, 1200, 760, 1)
	after_b := alicorn.motion_diagnostics_stats(&rt)
	testing.expect(t, connected_titlebar_test_chrome_regions_match(&app, &rt, chrome_regions_before[:], chrome_bounds_before) && rt.focused == keyboard_focus_before && rt.semantic_keyboard_focus == semantic_focus_before, "tab motion should preserve caption hit regions and both focus states")
	testing.expect(t, connected_titlebar_test_semantic_selection_matches(&rt, tab_semantic_ids[:], tab_semantic_ids[1]),
		"the B tab should become semantically selected immediately")
	testing.expect(t, after_b.intent_declarations == initial_stats.intent_declarations && alicorn.motion_activity(&rt).active_owners == 0,
		"changing selection should not animate or declare a colored underline, regardless of reduced-motion preference")

	app.backend.state.active = "motion-tab-c"
	alicorn.invalidate_root(&rt, "motion tab selection C")
	_ = alicorn.motion_clock_set_time(&rt, alicorn.Motion_Time(20_000_000))
	_ = build_app(rawptr(&app), &rt, 1200, 760, 1)
	after_c := alicorn.motion_diagnostics_stats(&rt)
	testing.expect(t, connected_titlebar_test_chrome_regions_match(&app, &rt, chrome_regions_before[:], chrome_bounds_before) && rt.focused == keyboard_focus_before && rt.semantic_keyboard_focus == semantic_focus_before, "rapid retargeting should preserve caption hit regions and both focus states")
	testing.expect(t, connected_titlebar_test_semantic_selection_matches(&rt, tab_semantic_ids[:], tab_semantic_ids[2]),
		"the C tab should become semantically selected immediately after rapid selection")
	testing.expect(t, after_c.intent_declarations == after_b.intent_declarations && alicorn.motion_activity(&rt).active_owners == 0,
		"rapid selection changes should not create underline motion work")

	// Exercise an actual click on the already-visible selected tab. The tab must
	// remain a true no-op in the document view, while the same active document
	// must still be selectable from another workbench presentation.
	selected_tab := connected_titlebar_test_tab_node(&rt, tab_semantic_ids[2])
	selected_tab_info, selected_tab_ok := alicorn.node_info(&rt, selected_tab)
	selection_revision := app.backend.state.revision
	selection_application_revision := app.backend.state.application_rev
	if selected_tab_ok {
		x := selected_tab_info.hit_bounds.x + selected_tab_info.hit_bounds.w*0.5
		y := selected_tab_info.hit_bounds.y + selected_tab_info.hit_bounds.h*0.5
		for kind in ([2]alicorn.Pointer_Kind{.Down, .Up}) {
			event := alicorn.Pointer_Event{kind=kind, x=x, y=y, button=alicorn.POINTER_BUTTON_PRIMARY}
			target := alicorn.process_pointer(&rt, event)
			application_pointer(rawptr(&app), &rt, event, target)
		}
		_ = build_app(rawptr(&app), &rt, 1200, 760, 1)
	}
	no_op_click_preserved_state := selected_tab_ok && app.backend.state.active == "motion-tab-c" &&
		app.backend.state.revision == selection_revision &&
		app.backend.state.application_rev == selection_application_revision &&
		!app.frame_deferred_action_pending && app.error_message == ""
	testing.expect(t, no_op_click_preserved_state,
		"clicking the already-selected tab should submit no selection command or change application state")
	view_noop := scratchpad_document_tab_selection_is_noop(&app, "motion-tab-c")
	app.workbench_view = .Git_History
	history_noop := scratchpad_document_tab_selection_is_noop(&app, "motion-tab-c")
	app.workbench_view = .Document
	app.workspace_search_mode = true
	search_noop := scratchpad_document_tab_selection_is_noop(&app, "motion-tab-c")
	app.workspace_search_mode = false
	app.pinned.visible, app.pinned.single_pane = true, true
	pinned_noop := scratchpad_document_tab_selection_is_noop(&app, "motion-tab-c")
	app.pinned.visible, app.pinned.single_pane = false, false
	testing.expect(t, view_noop && !history_noop && !search_noop && !pinned_noop,
		"the same tab should remain actionable when returning from History, Search, or single-pane Pinned")

	// Re-describe the same selection to model an unrelated application update.
	alicorn.invalidate_root(&rt, "repeat selected tab description")
	_ = alicorn.motion_clock_set_time(&rt, alicorn.Motion_Time(30_000_000))
	_ = build_app(rawptr(&app), &rt, 1200, 760, 1)
	repeated := alicorn.motion_diagnostics_stats(&rt)
	testing.expect(t, connected_titlebar_test_chrome_regions_match(&app, &rt, chrome_regions_before[:], chrome_bounds_before) && rt.focused == keyboard_focus_before && rt.semantic_keyboard_focus == semantic_focus_before, "repeated selection should leave native caption regions and focus unchanged")
	testing.expect(t, connected_titlebar_test_semantic_selection_matches(&rt, tab_semantic_ids[:], tab_semantic_ids[2]),
		"a repeated selection description should preserve exactly the same semantic selection")
	testing.expect(t, repeated.intent_declarations == after_c.intent_declarations,
		"repeating the current selection should declare no motion")
	hit_geometry_stable := len(button_bounds) == 6
	mismatch := ""
	for id, bounds in button_bounds {
		info, found := alicorn.node_info(&rt, id)
		if !found || !info.active || info.hit_bounds != bounds {
			hit_geometry_stable = false
			if found { mismatch = fmt.tprintf("node=%d before=%v after=%v", id, bounds, info.hit_bounds) }
			break
		}
	}
	testing.expect(t, hit_geometry_stable,
		fmt.tprintf("selection changes must leave tab/close hit targets stable: count=%d %s", len(button_bounds), mismatch))

	settled := alicorn.motion_activity(&rt)
	settled_stats := alicorn.motion_diagnostics_stats(&rt)
	testing.expect(t, settled.active_owners == 0 && settled.active_properties == 0,
		"tab selection should require no motion and remain settled")
	alicorn.invalidate_root(&rt, "settled selected tab description")
	_ = alicorn.motion_clock_set_time(&rt, alicorn.Motion_Time(5_000_000_000))
	_ = build_app(rawptr(&app), &rt, 1200, 760, 1)
	after_settlement := alicorn.motion_diagnostics_stats(&rt)
	testing.expect(t, after_settlement.intent_declarations == settled_stats.intent_declarations &&
		alicorn.motion_activity(&rt).active_owners == 0,
		"settled selections should add no declarations or motion activity on later descriptions")
	delete(button_bounds)
	delete(chrome_regions_before)
	delete(chrome_bounds_before)
}

connected_titlebar_test_reorder_motion_case :: proc(t: ^testing.T, reduce_motion: bool) {
	when ODIN_OS != .Windows && ODIN_OS != .Darwin { return }
	rt := alicorn.new_runtime({0, 0, 1200, 760})
	defer alicorn.destroy_runtime(&rt)
	app: App
	documents := [?]bridge.State_Document{
		{id="reorder-tab-a", path="alpha.txt", language="plain-text", line_count=1, preview=true},
		{id="reorder-tab-b", path="beta.txt", language="plain-text", line_count=1, preview=true},
		{id="reorder-tab-c", path="gamma.txt", language="plain-text", line_count=1, preview=true},
	}
	loaded := connected_titlebar_test_prepare(&app, &rt, documents[:], 1200, 1)
	defer connected_titlebar_test_destroy(&app)
	testing.expect(t, loaded, "the tab reorder fixture should load its font roles")
	if !loaded { return }
	app.accessibility_appearance_override_enabled = true
	app.accessibility_appearance.reduce_motion = reduce_motion
	_ = alicorn.motion_clock_set_time(&rt, alicorn.Motion_Time(0))
	_ = build_app(rawptr(&app), &rt, 1200, 760, 1)
	for _ in 0..<3 {
		alicorn.invalidate_root(&rt, "settle connected titlebar reorder fixture layout")
		_ = build_app(rawptr(&app), &rt, 1200, 760, 1)
	}
	ids := [?]alicorn.Semantic_ID{
		document_tab_semantic_id("reorder-tab-a"),
		document_tab_semantic_id("reorder-tab-b"),
		document_tab_semantic_id("reorder-tab-c"),
	}
	tab_nodes := [?]alicorn.Node_ID{
		connected_titlebar_test_tab_node(&rt, ids[0]),
		connected_titlebar_test_tab_node(&rt, ids[1]),
		connected_titlebar_test_tab_node(&rt, ids[2]),
	}
	for id in tab_nodes { testing.expect(t, id != 0, "all three document tabs should have retained roots") }
	if tab_nodes[0] == 0 || tab_nodes[1] == 0 || tab_nodes[2] == 0 { return }
	chrome_regions_before := make([dynamic]host.Window_Chrome_Region, 0, app.window_chrome_region_count, allocator=context.temp_allocator)
	chrome_bounds_before := make(map[alicorn.Node_ID]alicorn.Rect, allocator=context.temp_allocator)
	button_bounds_before := make(map[alicorn.Node_ID]alicorn.Rect, allocator=context.temp_allocator)
	for region in app.window_chrome_regions[:app.window_chrome_region_count] {
		append(&chrome_regions_before, region)
		if node, found := alicorn.node_info(&rt, region.node); found { chrome_bounds_before[region.node] = node.bounds }
	}
	for id in rt.order {
		node, found := rt.nodes[id]
		if !found || !node.active || node.kind != .Button || !connected_titlebar_test_button_in_tab_tree(&rt, id, ids[:]) { continue }
		if info, found := alicorn.node_info(&rt, id); found { button_bounds_before[id] = info.hit_bounds }
	}
	semantics_before := alicorn.semantic_snapshot(&rt, context.temp_allocator)
	defer alicorn.semantic_snapshot_destroy(&semantics_before)
	focus_before, semantic_focus_before := rt.focused, rt.semantic_keyboard_focus
	authoritative_before := [3]string{app.backend.state.documents[0].id, app.backend.state.documents[1].id, app.backend.state.documents[2].id}

	// Describe the proposal C→before A without touching the application-owned
	// document array, matching the state delivered by a live drag target change.
	application_drag(rawptr(&app), &rt, alicorn.Drag_Event{
		kind=.Started,
		drag_type=SCRATCHPAD_DRAG_TABS,
		source=ids[2],
		target=ids[0],
		position=.Before,
	})
	_ = alicorn.motion_clock_set_time(&rt, alicorn.Motion_Time(10_000_000))
	_ = build_app(rawptr(&app), &rt, 1200, 760, 1)
	first_stats := alicorn.motion_diagnostics_stats(&rt)
	testing.expect(t, app.document_tab_reorder_motion_cleanup_needed,
		"moving C before A should remember that the gesture has displaced neighbors")
	if reduce_motion {
		testing.expect(t, alicorn.motion_activity(&rt).active_owners == 0,
			"reduced motion should apply the proposed tab slot positions immediately")
	} else {
		testing.expect(t, alicorn.motion_activity(&rt).active_owners > 0,
			"normal motion should animate neighboring tabs into the proposed slots")
	}
	selection_stable := connected_titlebar_test_semantic_selection_matches(&rt, ids[:], ids[0])
	testing.expect(t, selection_stable,
		"live drag displacement must leave the selected tab's semantic state immediately correct")
	semantics_after := alicorn.semantic_snapshot(&rt, context.temp_allocator)
	defer alicorn.semantic_snapshot_destroy(&semantics_after)
	testing.expect(t, connected_titlebar_test_tab_semantics_unchanged(semantics_before, semantics_after, ids[:]),
		"paint-only drag displacement must leave each tab's role, label, selection, order, actions, and bounds unchanged")
	testing.expect(t, connected_titlebar_test_chrome_regions_match(&app, &rt, chrome_regions_before[:], chrome_bounds_before) &&
		rt.focused == focus_before && rt.semantic_keyboard_focus == semantic_focus_before,
		"tab displacement must preserve native caption regions and both focus states")
	for id, bounds in button_bounds_before {
		info, found := alicorn.node_info(&rt, id)
		testing.expect(t, found && info.active && info.hit_bounds == bounds,
			"paint-only slot movement must preserve tab and close-action hit targets")
	}
	for index in 0..<3 {
		testing.expect(t, app.backend.state.documents[index].id == authoritative_before[index],
			"the proposed order must not mutate authoritative Scratchpad document order")
	}

	// Return C to its original slot while its neighbors are still moving. The
	// sampled position and velocity must remain continuous as A retargets to zero.
	app.workspace_drag_target = ids[1]
	app.workspace_drag_position = .After
	_ = alicorn.motion_clock_set_time(&rt, alicorn.Motion_Time(20_000_000))
	_ = alicorn.motion_tick(&rt, alicorn.Motion_Time(20_000_000))
	before_retarget := alicorn.motion_diagnostics_owner_snapshot(&rt, tab_nodes[0])
	alicorn.invalidate_root(&rt, "return dragged tab to its original slot")
	_ = alicorn.motion_clock_set_time(&rt, alicorn.Motion_Time(20_000_000))
	_ = build_app(rawptr(&app), &rt, 1200, 760, 1)
	reversed_stats := alicorn.motion_diagnostics_stats(&rt)
	after_retarget := alicorn.motion_diagnostics_owner_snapshot(&rt, tab_nodes[0])
	retarget_behavior := false
	if reduce_motion {
		retarget_behavior = before_retarget.valid && after_retarget.valid &&
			before_retarget.translation.target.x != after_retarget.translation.target.x &&
			after_retarget.translation.target.x == 0 && after_retarget.translation.presented.x == 0 &&
			after_retarget.translation.velocity.x == 0 && !after_retarget.translation.active
	} else {
		retarget_behavior = before_retarget.valid && after_retarget.valid &&
			before_retarget.translation.target.x != after_retarget.translation.target.x &&
			after_retarget.translation.target.x == 0 &&
			abs(before_retarget.translation.presented.x-after_retarget.translation.presented.x) < 1e-7 &&
			abs(before_retarget.translation.presented.y-after_retarget.translation.presented.y) < 1e-7 &&
			abs(before_retarget.translation.velocity.x-after_retarget.translation.velocity.x) < 1e-5 &&
			abs(before_retarget.translation.velocity.y-after_retarget.translation.velocity.y) < 1e-5
	}
	testing.expect(t, reversed_stats.intent_declarations > first_stats.intent_declarations &&
		retarget_behavior,
		fmt.tprintf("tab retarget should preserve normal position/velocity or snap immediately for reduced motion: before=%v after=%v",
			before_retarget.translation, after_retarget.translation))
	testing.expect(t, app.document_tab_reorder_motion_cleanup_needed,
		"returning to zero insertion offsets must retain gesture-lifetime cleanup responsibility")
	alicorn.invalidate_root(&rt, "repeat unchanged tab insertion target")
	_ = alicorn.motion_clock_set_time(&rt, alicorn.Motion_Time(30_000_000))
	_ = build_app(rawptr(&app), &rt, 1200, 760, 1)
	repeated_stats := alicorn.motion_diagnostics_stats(&rt)
	testing.expect(t, repeated_stats.intent_declarations == reversed_stats.intent_declarations,
		"re-describing an unchanged insertion target should declare no additional motion")
	testing.expect(t, connected_titlebar_test_semantic_selection_matches(&rt, ids[:], ids[0]) &&
		connected_titlebar_test_chrome_regions_match(&app, &rt, chrome_regions_before[:], chrome_bounds_before),
		"rapid reversal must keep selection semantics and caption hit regions stable")

	if !reduce_motion {
		// Reduce Motion can change while a gesture is in flight. Re-declaring the
		// unchanged target applies the current policy and snaps without restarting
		// or leaving a moving visual behind the logical hit geometry.
		app.accessibility_appearance.reduce_motion = true
		alicorn.invalidate_root(&rt, "Reduce Motion changed during tab reorder")
		_ = alicorn.motion_clock_set_time(&rt, alicorn.Motion_Time(35_000_000))
		_ = build_app(rawptr(&app), &rt, 1200, 760, 1)
		policy_changed_stats := alicorn.motion_diagnostics_stats(&rt)
		policy_snapshot := alicorn.motion_diagnostics_owner_snapshot(&rt, tab_nodes[0])
		testing.expect(t, policy_changed_stats.intent_declarations > repeated_stats.intent_declarations &&
			alicorn.motion_activity(&rt).active_owners == 0 && policy_snapshot.translation.presented.x == 0,
			"a mid-flight Reduce Motion change should reapply policy and snap neighbors to their current logical slots")
	}

	// Cancel after the nonzero→zero reversal. Cleanup must still be queued and
	// snap before the gesture is retired, even though the latest target is zero.
	application_drag(rawptr(&app), &rt, alicorn.Drag_Event{
		kind=.Cancelled,
		drag_type=SCRATCHPAD_DRAG_TABS,
	})
	testing.expect(t, app.workspace_drag_motion_reset_pending && app.workspace_drag_motion_reset_snap,
		"cancel must queue snap cleanup after any displaced target, including a zero-offset reversal")
	alicorn.invalidate_root(&rt, "cancel reversed tab reorder")
	_ = alicorn.motion_clock_set_time(&rt, alicorn.Motion_Time(40_000_000))
	_ = build_app(rawptr(&app), &rt, 1200, 760, 1)
	testing.expect(t, app.workspace_drag_kind == .None &&
		!app.document_tab_reorder_motion_cleanup_needed && !app.workspace_drag_motion_reset_pending &&
		alicorn.motion_activity(&rt).active_owners == 0 &&
		app.backend.state.documents[0].id == authoritative_before[0] &&
		app.backend.state.documents[1].id == authoritative_before[1] &&
		app.backend.state.documents[2].id == authoritative_before[2],
		"cancel should release gesture cleanup, leave no motion, and preserve authoritative tab order")

	// A successful drop commits the authoritative order once; zeroing paint
	// translations against the reordered layout should not leave motion active.
	application_drag(rawptr(&app), &rt, alicorn.Drag_Event{
		kind=.Started,
		drag_type=SCRATCHPAD_DRAG_TABS,
		source=ids[2],
		target=ids[0],
		position=.Before,
	})
	_ = alicorn.motion_clock_set_time(&rt, alicorn.Motion_Time(50_000_000))
	_ = build_app(rawptr(&app), &rt, 1200, 760, 1)
	testing.expect(t, app.document_tab_reorder_motion_cleanup_needed,
		"the successful-drop fixture should create a live displaced gesture")
	app.backend.state.documents[1], app.backend.state.documents[2] =
		app.backend.state.documents[2], app.backend.state.documents[1]
	workspace_drag_clear(&app, reset_motion=true, snap_motion=true)
	alicorn.invalidate_root(&rt, "commit proposed tab order")
	_ = alicorn.motion_clock_set_time(&rt, alicorn.Motion_Time(60_000_000))
	_ = build_app(rawptr(&app), &rt, 1200, 760, 1)
	testing.expect(t, app.backend.state.documents[0].id == "reorder-tab-a" &&
		app.backend.state.documents[1].id == "reorder-tab-c" &&
		app.backend.state.documents[2].id == "reorder-tab-b" &&
		!app.document_tab_reorder_motion_cleanup_needed && !app.workspace_drag_motion_reset_pending &&
		alicorn.motion_activity(&rt).active_owners == 0,
		"drop should commit the displayed order and snap to new logical geometry without residual motion")

	// A canceled moved gesture snaps neighboring tabs back to the current order.
	application_drag(rawptr(&app), &rt, alicorn.Drag_Event{
		kind=.Started,
		drag_type=SCRATCHPAD_DRAG_TABS,
		source=ids[1],
		target=ids[0],
		position=.Before,
	})
	_ = alicorn.motion_clock_set_time(&rt, alicorn.Motion_Time(70_000_000))
	_ = build_app(rawptr(&app), &rt, 1200, 760, 1)
	testing.expect(t, app.document_tab_reorder_motion_cleanup_needed,
		"a second live drag should establish neighbors to snap on cancellation")
	application_drag(rawptr(&app), &rt, alicorn.Drag_Event{
		kind=.Cancelled,
		drag_type=SCRATCHPAD_DRAG_TABS,
	})
	order_before_cancel_build := [3]string{
		app.backend.state.documents[0].id,
		app.backend.state.documents[1].id,
		app.backend.state.documents[2].id,
	}
	_ = alicorn.motion_clock_set_time(&rt, alicorn.Motion_Time(80_000_000))
	_ = build_app(rawptr(&app), &rt, 1200, 760, 1)
	testing.expect(t, app.workspace_drag_kind == .None &&
		!app.document_tab_reorder_motion_cleanup_needed && !app.workspace_drag_motion_reset_pending &&
		alicorn.motion_activity(&rt).active_owners == 0 &&
		app.backend.state.documents[0].id == order_before_cancel_build[0] &&
		app.backend.state.documents[1].id == order_before_cancel_build[1] &&
		app.backend.state.documents[2].id == order_before_cancel_build[2],
		"cancel should reset transient motion without changing authoritative document order")
	delete(button_bounds_before)
	delete(chrome_regions_before)
	delete(chrome_bounds_before)
}

@(test)
test_connected_titlebar_live_reorder_motion_preserves_semantics_and_geometry :: proc(t: ^testing.T) {
	connected_titlebar_test_reorder_motion_case(t, false)
	connected_titlebar_test_reorder_motion_case(t, true)
}

@(test)
test_connected_tab_selection_has_no_underline_motion :: proc(t: ^testing.T) {
	connected_titlebar_test_selection_decoration_case(t, false)
	connected_titlebar_test_selection_decoration_case(t, true)
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
