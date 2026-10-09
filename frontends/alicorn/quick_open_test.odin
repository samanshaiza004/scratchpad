package main

import "core:testing"
import alicorn "alicorn:runtime"

@(test)
test_quick_open_matches_basenames_paths_and_multiple_terms :: proc(t: ^testing.T) {
	readme := "docs/README.md"
	config := "frontends/alicorn/caliber.config.json"
	other := "docs/RESEARCH.md"

	testing.expect(t, quick_open_match_score("readme", readme) >= 0,
		"Quick Open should match a filename without requiring its directory")
	testing.expect(t, quick_open_match_score("front alicorn config", config) >= 0,
		"separate fuzzy terms should match across a relative path")
	testing.expect(t, quick_open_match_score("missing-file", readme) < 0,
		"a path missing a query term should not be returned")
	testing.expect(t, quick_open_match_score("", readme) == 0,
		"an empty query should keep the stable backend path ordering")
}

@(test)
test_quick_open_filter_orders_by_match_then_source_order :: proc(t: ^testing.T) {
	paths := [?]string{
		"src/README.md.backup",
		"README.md",
		"docs/README.md.old",
	}
	results := quick_open_filter(paths[:], "readme.md", context.temp_allocator)
	defer delete(results)
	testing.expect(t, len(results) == 3,
		"all matching paths should be retained in the filtered result set")
	testing.expect(t, results[0].path == "README.md",
		"an exact basename match should rank ahead of weaker path matches")
}

@(test)
test_quick_open_is_a_file_menu_command_with_primary_p_shortcut :: proc(t: ^testing.T) {
	app: App
	init_menus(&app)
	found := false
	for item in app.file_items {
		if item.kind == .Command && item.command == action_id_for(ACTION_FILE_QUICK_OPEN) && item.label == "Quick Open…" &&
		   item.shortcut.key == 'P' && item.shortcut.modifiers == {.Primary} {
			found = true
			break
		}
	}
	testing.expect(t, found,
		"Quick Open should be discoverable from the File menu with its registered action identity")
}

quick_open_test_render :: proc(t: ^testing.T, app: ^App, rt: ^alicorn.Runtime) -> bool {
	ui, should_build := alicorn.begin_frame(rt)
	if !should_build {
		testing.expect(t, false, "Quick Open fixture should build its invalidated description")
		return false
	}
	alicorn.container_begin(&ui, .Root, key=alicorn.key_string("quick-open-content-root"), style=alicorn.layout_style(.Column, grow=1))
	quick_open_build(app, &ui, rt)
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
	quick_open_restore_focus_after_frame(app, rt)
	return true
}

@(test)
test_quick_open_panel_sizes_from_content_caps_results_and_preserves_focus :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 1000, 700})
	defer alicorn.destroy_runtime(&rt)
	app: App
	app.quick_open_open = true
	app.quick_open_ready = true
	app.quick_open_focus_pending = true
	if !quick_open_test_render(t, &app, &rt) { return }
	empty_panel, empty_panel_ok := alicorn.node_info(&rt, app.quick_open_panel_node)
	testing.expect(t, empty_panel_ok && empty_panel.bounds.h > 0,
		"the empty-results message should give Quick Open a natural content height")
	testing.expect(t, alicorn.focused_node(&rt) == app.quick_open_node,
		"the query field should receive focus when Quick Open opens")

	short_paths := [?]string{"README.md", "src/main.odin", "docs/guide.md"}
	app.quick_open_paths = short_paths[:]
	alicorn.invalidate_root(&rt, "Quick Open short result fixture")
	if !quick_open_test_render(t, &app, &rt) { return }
	short_panel, short_panel_ok := alicorn.node_info(&rt, app.quick_open_panel_node)
	short_list, short_list_ok := alicorn.node_info(&rt, app.quick_open_results_scroll_node)
	testing.expect(t, short_panel_ok && short_panel.bounds.h > empty_panel.bounds.h,
		"a short result set should grow the panel to its actual contents")
	testing.expect(t, short_list_ok && short_list.scroll_content_height == f32(len(short_paths))*QUICK_OPEN_ROW_HEIGHT &&
		short_list.scroll_viewport_height == f32(len(short_paths))*QUICK_OPEN_ROW_HEIGHT,
		"a short result set should use its natural list height")

	full_paths := [?]string{
		"README.md", "src/main.odin", "docs/guide.md", "themes/paper.json", "themes/workbench.json",
		"tools/run.ps1", "application/app.go", "document/model.go", "editor/buffer.go", "workspace/tree.go",
		"tests/one.odin", "tests/two.odin",
	}
	app.quick_open_paths = full_paths[:]
	alicorn.invalidate_root(&rt, "Quick Open capped result fixture")
	if !quick_open_test_render(t, &app, &rt) { return }
	full_panel, full_panel_ok := alicorn.node_info(&rt, app.quick_open_panel_node)
	full_list, full_list_ok := alicorn.node_info(&rt, app.quick_open_results_scroll_node)
	testing.expect(t, full_panel_ok && full_panel.bounds.h > short_panel.bounds.h,
		"a full result set should grow the panel beyond a short result set")
	testing.expect(t, full_list_ok && full_list.scroll_content_height == f32(len(full_paths))*QUICK_OPEN_ROW_HEIGHT &&
		full_list.scroll_viewport_height <= f32(QUICK_OPEN_MAX_VISIBLE_ROWS)*QUICK_OPEN_ROW_HEIGHT,
		"the virtual list should retain all results while capping its visible height at ten rows")

	app.quick_open_paths = full_paths[:QUICK_OPEN_MAX_VISIBLE_ROWS]
	alicorn.invalidate_root(&rt, "Quick Open exact cap fixture")
	if !quick_open_test_render(t, &app, &rt) { return }
	cap_panel, cap_panel_ok := alicorn.node_info(&rt, app.quick_open_panel_node)
	testing.expect(t, cap_panel_ok && cap_panel.bounds.h == full_panel.bounds.h,
		"result counts beyond the ten-row cap should not increase panel height")

	app.quick_open_paths = full_paths[:]
	alicorn.invalidate_root(&rt, "Quick Open restore full result set")
	if !quick_open_test_render(t, &app, &rt) { return }
	app.quick_open_selected_index = 0
	if !quick_open_move_selection(&app, &rt, 10) { testing.expect(t, false, "Quick Open should move selection to a later result"); return }
	_ = quick_open_test_render(t, &app, &rt)
	list_state := alicorn.scroll_region_state(&rt, app.quick_open_results_scroll_node)
	testing.expect(t, list_state.offset_y > 0 && app.quick_open_selected_index == 10,
		"keyboard selection should scroll later results into the bounded viewport")
	testing.expect(t, alicorn.focused_node(&rt) == app.quick_open_node,
		"navigating and scrolling results should preserve query-field focus")
}

@(test)
test_quick_open_content_sized_panel_fits_narrow_windows :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 360, 600})
	defer alicorn.destroy_runtime(&rt)
	app: App
	app.quick_open_open = true
	app.quick_open_ready = true
	app.quick_open_focus_pending = true
	paths := [?]string{"README.md", "src/a-very-long-file-name.odin", "docs/guide.md"}
	app.quick_open_paths = paths[:]
	if !quick_open_test_render(t, &app, &rt) { return }
	panel, panel_ok := alicorn.node_info(&rt, app.quick_open_panel_node)
	query, query_ok := alicorn.node_info(&rt, app.quick_open_node)
	testing.expect(t, panel_ok && panel.bounds.x >= 0 && panel.bounds.x+panel.bounds.w <= 360,
		"the naturally sized Quick Open panel should remain inside a narrow viewport")
	testing.expect(t, query_ok && panel_ok && query.bounds.x >= panel.bounds.x &&
		query.bounds.x+query.bounds.w <= panel.bounds.x+panel.bounds.w,
		"the query control should remain bounded by the panel in a narrow window")
	testing.expect(t, alicorn.focused_node(&rt) == app.quick_open_node,
		"the query field should remain focusable at narrow window widths")
}
