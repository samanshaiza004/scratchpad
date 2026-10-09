package main

import "core:testing"
import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"
import bridge "./bridge"

@(test)
test_command_palette_fuzzy_terms_cover_action_fields_and_aliases :: proc(t: ^testing.T) {
	fit_trace := Command_Palette_Result{
		action_id="view.fit-whole-trace",
		title="Fit Whole Trace",
		category="View",
	}
	trash := Command_Palette_Result{
		action_id="workspace.trash",
		title="Move to Trash",
		category="Workspace",
	}
	strong := Command_Palette_Result{
		action_id=ACTION_MARKDOWN_TOGGLE_STRONG,
		title="Strong",
		category="Markdown",
	}

	testing.expect(t, command_palette_match_score("fwt", fit_trace) >= 0,
		"initialism-like fuzzy search should find a word-boundary match")
	testing.expect(t, command_palette_match_score("workspace trash", trash) >= 0,
		"separate query terms should match across action category and title/aliases")
	testing.expect(t, command_palette_match_score("bold", strong) >= 0,
		"common command aliases should be searchable")
	testing.expect(t, command_palette_match_score("not-a-command", strong) < 0,
		"a query term absent from every searchable field must not match")
}

@(test)
test_command_palette_shortcut_search_and_binding_presentation :: proc(t: ^testing.T) {
	result := Command_Palette_Result{
		action_id="view.command-palette",
		title="Command Palette",
		category="View",
		shortcut="primary+shift+p",
	}
	testing.expect(t, command_palette_match_score("ctrl shift p", result) >= 0,
		"platform-neutral shortcut search should understand the displayed primary modifier")
	testing.expect(t, command_palette_binding_label(result.shortcut) == "Ctrl/Cmd+Shift+P",
		"primary shortcut presentation should name both common desktop conventions")
}

@(test)
test_command_palette_enabled_commands_and_recents_sort_stably :: proc(t: ^testing.T) {
	candidates := [?]Command_Palette_Result{
		{action_id="workspace.trash", title="Move to Trash", category="Workspace", enabled=false, order=0},
		{action_id="file.open", title="Open File", category="File", enabled=true, order=1},
		{action_id="workspace.new-file", title="New File", category="Workspace", enabled=true, order=2},
	}
	recent := [?]host.Application_Command_ID{action_id_for("workspace.new-file")}
	filtered := command_palette_filter_results(candidates[:], "", recent[:], context.temp_allocator)
	defer delete(filtered)
	testing.expect(t, len(filtered) == 3, "an empty query should show all currently visible commands")
	testing.expect(t, filtered[0].action_id == "workspace.new-file",
		"a recent enabled command should lead the empty-query list")
	testing.expect(t, filtered[1].enabled && filtered[2].action_id == "workspace.trash",
		"disabled commands should remain discoverable but sort after enabled commands")
}

@(test)
test_command_palette_projects_local_menu_commands_without_recursing :: proc(t: ^testing.T) {
	app: App
	init_menus(&app)
	results := command_palette_collect_results(&app, context.temp_allocator)
	defer delete(results)
	go_to_line_found := false
	wrap_found := false
	palette_found := false
	for result in results {
		if result.action_id == ACTION_DOCUMENT_GO_TO_LINE && result.title == "Go to Line…" { go_to_line_found = true }
		if result.action_id == ACTION_DOCUMENT_TOGGLE_WRAP && result.title == "Cycle Word Wrap" { wrap_found = true }
		if result.action_id == ACTION_VIEW_COMMAND_PALETTE { palette_found = true }
	}
	testing.expect(t, go_to_line_found && wrap_found,
		"frontend-local menu commands should also be discoverable in the palette")
	testing.expect(t, !palette_found,
		"the command palette launcher must not list itself as a recursively runnable command")
}

@(test)
test_command_palette_focus_keyboard_and_dismissal_are_local :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 800, 600})
	defer alicorn.destroy_runtime(&rt)
	app: App
	ui, should_build := alicorn.begin_frame(&rt)
	if !should_build { testing.expect(t, false, "palette focus test should describe its initial frame"); return }
	alicorn.container_begin(&ui, .Root, key=alicorn.key_string("command-palette-focus-root"), style=alicorn.layout_style(grow=1))
	previous_focus := alicorn.text_field(&ui, "", key=alicorn.key_string("command-palette-prior-focus"))
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
	_ = alicorn.focus(&rt, previous_focus)

	command_palette_open_surface(&app, &rt)
	ui, should_build = alicorn.begin_frame(&rt)
	if !should_build { testing.expect(t, false, "palette focus test should describe the open palette"); return }
	alicorn.container_begin(&ui, .Root, key=alicorn.key_string("command-palette-focus-root"), style=alicorn.layout_style(grow=1))
	_ = alicorn.text_field(&ui, "", key=alicorn.key_string("command-palette-prior-focus"))
	command_palette_build(&app, &ui, &rt)
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
	command_palette_restore_focus_after_frame(&app, &rt)
	testing.expect(t, app.command_palette_open && rt.focused == app.command_palette_node,
		"opening the palette should move focus into its query field after that node exists")

	down_handled := application_key(rawptr(&app), &rt, .Down)
	escape_handled := application_key(rawptr(&app), &rt, .Escape)
	testing.expect(t, down_handled && escape_handled && !app.command_palette_open,
		"palette navigation and Escape should be consumed locally instead of leaking to the workspace")

	ui, should_build = alicorn.begin_frame(&rt)
	if !should_build { testing.expect(t, false, "palette focus test should describe after dismissal"); return }
	alicorn.container_begin(&ui, .Root, key=alicorn.key_string("command-palette-focus-root"), style=alicorn.layout_style(grow=1))
	previous_focus = alicorn.text_field(&ui, "", key=alicorn.key_string("command-palette-prior-focus"))
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
	command_palette_restore_focus_after_frame(&app, &rt)
	testing.expect(t, rt.focused == previous_focus,
		"dismissing the palette should restore the prior retained focus target")
}

command_palette_test_build :: proc(t: ^testing.T, app: ^App, rt: ^alicorn.Runtime) -> bool {
	ui, should_build := alicorn.begin_frame(rt)
	if !should_build {
		testing.expect(t, false, "command palette fixture should build its invalidated description")
		return false
	}
	alicorn.container_begin(&ui, .Root, key=alicorn.key_string("command-palette-content-root"), style=alicorn.layout_style(.Column, grow=1))
	command_palette_build(app, &ui, rt)
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
	return true
}

@(test)
test_command_palette_sizes_from_results_and_caps_scroll_content :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 1000, 700})
	defer alicorn.destroy_runtime(&rt)
	app: App
	init_menus(&app)
	synthetic_actions := [?]bridge.Action_State{
		{id="file.open", title="Open File", category="File", visible=true, enabled=true},
		{id="demo.one", title="Demo One", category="Demo", visible=true, enabled=true},
		{id="demo.two", title="Demo Two", category="Demo", visible=true, enabled=true},
		{id="demo.three", title="Demo Three", category="Demo", visible=true, enabled=true},
		{id="demo.four", title="Demo Four", category="Demo", visible=true, enabled=true},
		{id="demo.five", title="Demo Five", category="Demo", visible=true, enabled=true},
		{id="demo.six", title="Demo Six", category="Demo", visible=true, enabled=true},
		{id="demo.seven", title="Demo Seven", category="Demo", visible=true, enabled=true},
		{id="demo.eight", title="Demo Eight", category="Demo", visible=true, enabled=true},
		{id="demo.nine", title="Demo Nine", category="Demo", visible=true, enabled=true},
		{id="demo.ten", title="Demo Ten", category="Demo", visible=true, enabled=true},
		{id="demo.eleven", title="Demo Eleven", category="Demo", visible=true, enabled=true},
		{id="demo.twelve", title="Demo Twelve", category="Demo", visible=true, enabled=true},
	}
	app.backend.state.actions = synthetic_actions[:]
	app.command_palette_open = true
	app.command_palette_query = "Open File"

	results := command_palette_collect_results(&app, context.temp_allocator)
	defer delete(results)
	sparse := command_palette_filter_results(results[:], app.command_palette_query, {}, context.temp_allocator)
	defer delete(sparse)
	visible_sparse := min(max(len(sparse), 1), COMMAND_PALETTE_MAX_VISIBLE_ROWS)
	if !command_palette_test_build(t, &app, &rt) { return }
	panel, panel_ok := alicorn.node_info(&rt, app.command_palette_panel_node)
	testing.expect(t, panel_ok && len(sparse) > 0 && len(sparse) < COMMAND_PALETTE_MAX_VISIBLE_ROWS,
		"the focused query should produce a short natural-height result list")
	if panel_ok {
		want_height := f32(104)+f32(visible_sparse)*COMMAND_PALETTE_ROW_HEIGHT
		testing.expect(t, panel.bounds.h == want_height,
			"the command palette panel height should come from its realized query, result, and footer contents")
	}

	app.command_palette_query = ""
	alicorn.invalidate_root(&rt, "command palette content sizing stress")
	all_results := command_palette_filter_results(results[:], "", {}, context.temp_allocator)
	defer delete(all_results)
	if !command_palette_test_build(t, &app, &rt) { return }
	panel, panel_ok = alicorn.node_info(&rt, app.command_palette_panel_node)
	list, list_ok := alicorn.node_info(&rt, app.command_palette_results_scroll_node)
	testing.expect(t, len(all_results) > COMMAND_PALETTE_MAX_VISIBLE_ROWS,
		"the real command set should exceed the palette's bounded visible row count")
	testing.expect(t, panel_ok && panel.bounds.h == f32(104)+COMMAND_PALETTE_MAX_LIST_HEIGHT,
		"many results should grow the panel only to the capped list height")
	testing.expect(t, list_ok && list.scroll_content_height == f32(len(all_results))*COMMAND_PALETTE_ROW_HEIGHT &&
		list.scroll_viewport_height <= COMMAND_PALETTE_MAX_LIST_HEIGHT,
		"the palette should retain the full result extent while keeping the scroll viewport bounded")
}
