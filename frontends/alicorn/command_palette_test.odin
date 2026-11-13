package main

import "core:testing"
import "core:strings"
import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"
import alikit "alikit:command_palette"
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
test_command_palette_projects_fuzzy_ranked_results_to_stable_alikit_items :: proc(t: ^testing.T) {
	candidates := [?]Command_Palette_Result{
		{action_id="workspace.open", title="Open Workspace", category="Workspace", shortcut="primary+o", enabled=true},
		{action_id="file.open", title="Open File", category="File", shortcut="primary+o", enabled=false},
	}
	ranked := command_palette_filter_results(candidates[:], "wrkspc", {}, context.temp_allocator)
	defer delete(ranked)
	items := command_palette_alikit_items(ranked[:], context.temp_allocator)
	defer delete(items)
	command_id := action_id_for(ranked[0].action_id)
	testing.expect(t, len(items) == 1 && u64(items[0].id) == u64(command_id),
		"Scratchpad's fuzzy matcher and ranking should supply the exact stable actions shown by AliKit")
	testing.expect(t, items[0].title == "Open Workspace" && strings.contains(items[0].description, "Workspace") &&
		strings.contains(items[0].description, "Ctrl/Cmd+O") && !items[0].disabled,
		"the AliKit projection should preserve category, shortcut presentation, and enabled state")
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
	warm_theme_found := false
	cool_light_theme_found := false
	for result in results {
		if result.action_id == ACTION_DOCUMENT_GO_TO_LINE && result.title == "Go to Line…" { go_to_line_found = true }
		if result.action_id == ACTION_DOCUMENT_TOGGLE_WRAP && result.title == "Cycle Word Wrap" { wrap_found = true }
		if result.action_id == ACTION_VIEW_COMMAND_PALETTE { palette_found = true }
		if result.action_id == ACTION_VIEW_THEME_WARM && result.title == "Use Warm Theme" { warm_theme_found = true }
		if result.action_id == ACTION_VIEW_THEME_COOL_LIGHT && result.title == "Use Cool Light Theme" { cool_light_theme_found = true }
	}
	testing.expect(t, go_to_line_found && wrap_found && warm_theme_found && cool_light_theme_found,
		"frontend-local menu commands, including both theme choices, should be discoverable in the palette")
	testing.expect(t, !palette_found,
		"the command palette launcher must not list itself as a recursively runnable command")
}

@(test)
test_command_palette_focus_keyboard_and_dismissal_are_local :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 800, 600})
	defer alicorn.destroy_runtime(&rt)
	app: App
	defer alikit.destroy(&app.command_palette_component)
	ui, should_build := alicorn.begin_frame(&rt)
	if !should_build { testing.expect(t, false, "palette focus test should describe its initial frame"); return }
	alicorn.container_begin(&ui, .Root, key=alicorn.key_string("command-palette-content-root"), style=alicorn.layout_style(.Column, grow=1))
	previous_focus := alicorn.text_field(&ui, "", key=alicorn.key_string("command-palette-prior-focus"))
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
	_ = alicorn.focus(&rt, previous_focus)

	command_palette_open_surface(&app, &rt)
	ui, should_build = alicorn.begin_frame(&rt)
	if !should_build { testing.expect(t, false, "palette focus test should describe the open palette"); return }
	alicorn.container_begin(&ui, .Root, key=alicorn.key_string("command-palette-content-root"), style=alicorn.layout_style(.Column, grow=1))
	_ = alicorn.text_field(&ui, "", key=alicorn.key_string("command-palette-prior-focus"))
	alicorn.container_end(&ui)
	command_palette_build(&app, &ui, &rt)
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
	alicorn.container_begin(&ui, .Root, key=alicorn.key_string("command-palette-content-root"), style=alicorn.layout_style(.Column, grow=1))
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
	_ = alicorn.text_field(&ui, "", key=alicorn.key_string("command-palette-prior-focus"))
	alicorn.container_end(&ui)
	command_palette_build(app, &ui, rt)
	alicorn.end_frame(&ui)
	return true
}

command_palette_styled_test_build :: proc(t: ^testing.T, app: ^App, rt: ^alicorn.Runtime) -> bool {
	if !scratchpad_styles_ensure(app, rt) {
		testing.expect(t, false, "palette motion fixture should register the workbench theme")
		return false
	}
	ui, should_build := alicorn.begin_frame(rt)
	if !should_build {
		testing.expect(t, false, "palette fixture should build its invalidated description")
		return false
	}
	alicorn.container_begin(&ui, .Root, key=alicorn.key_string("command-palette-content-root"), style=alicorn.layout_style(.Column, grow=1))
	_ = alicorn.text_field(&ui, "", key=alicorn.key_string("command-palette-prior-focus"))
	alicorn.container_end(&ui)
	scope := alicorn.style_environment_push(&ui, scratchpad_workbench_style_environment(app))
	command_palette_build(app, &ui, rt)
	alicorn.style_environment_pop(&ui, scope)
	alicorn.end_frame(&ui)
	return true
}

@(test)
test_command_palette_component_owns_pointer_dismissal_and_focus_restoration :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 900, 650})
	defer alicorn.destroy_runtime(&rt)
	app: App
	defer alikit.destroy(&app.command_palette_component)
	if !scratchpad_styles_ensure(&app, &rt) { testing.expect(t, false, "palette fixture should register its theme"); return }
	ui, should_build := alicorn.begin_frame(&rt)
	if !should_build { testing.expect(t, false, "initial focus frame should build"); return }
	alicorn.container_begin(&ui, .Root, key=alicorn.key_string("command-palette-content-root"), style=alicorn.layout_style(.Column, grow=1))
	previous_focus := alicorn.text_field(&ui, "", key=alicorn.key_string("command-palette-prior-focus"))
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
	_ = alicorn.focus(&rt, previous_focus)
	command_palette_open_surface(&app, &rt)
	if !command_palette_styled_test_build(t, &app, &rt) { return }
	command_palette_restore_focus_after_frame(&app, &rt)
	overlay := app.command_palette_overlay_node
	panel, panel_found := alicorn.node_info(&rt, app.command_palette_panel_node)
	testing.expect(t, panel_found && app.command_palette_node != 0 && rt.focused == app.command_palette_node,
		"AliKit should render the themed palette and focus its controlled query")
	outside_click := alicorn.Pointer_Event{kind=.Down, button=alicorn.POINTER_BUTTON_PRIMARY, x=1, y=1}
	outside_target := alicorn.process_pointer(&rt, outside_click)
	testing.expect(t, outside_target == overlay,
		"the modal backdrop should own a physical hit outside the palette panel")
	command_palette_pointer(&app, &rt, outside_click, outside_target)
	testing.expect(t, !app.command_palette_open,
		"a primary pointer down on the modal backdrop should dismiss the palette")
	ui, should_build = alicorn.begin_frame(&rt)
	if !should_build { testing.expect(t, false, "dismissal should build the frame that retires the modal"); return }
	alicorn.container_begin(&ui, .Root, key=alicorn.key_string("command-palette-content-root"), style=alicorn.layout_style(.Column, grow=1))
	previous_focus = alicorn.text_field(&ui, "", key=alicorn.key_string("command-palette-prior-focus"))
	alicorn.container_end(&ui)
	command_palette_build(&app, &ui, &rt)
	alicorn.end_frame(&ui)
	command_palette_restore_focus_after_frame(&app, &rt)
	testing.expect(t, rt.focused == previous_focus,
		"outside dismissal should restore the focus owner captured before opening")
	_ = panel
}

@(test)
test_command_palette_pointer_activation_defers_current_scratchpad_action :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 900, 650})
	defer alicorn.destroy_runtime(&rt)
	app: App
	defer alikit.destroy(&app.command_palette_component)
	actions := [?]bridge.Action_State{
		{id="file.open", title="Open File", category="File", visible=true, enabled=true},
	}
	app.backend.state.actions = actions[:]
	ui, should_build := alicorn.begin_frame(&rt)
	if !should_build { testing.expect(t, false, "initial focus frame should build"); return }
	alicorn.container_begin(&ui, .Root, key=alicorn.key_string("command-palette-content-root"), style=alicorn.layout_style(.Column, grow=1))
	previous_focus := alicorn.text_field(&ui, "", key=alicorn.key_string("command-palette-prior-focus"))
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
	_ = alicorn.focus(&rt, previous_focus)
	command_palette_open_surface(&app, &rt)
	if !command_palette_styled_test_build(t, &app, &rt) { return }
	command_palette_restore_focus_after_frame(&app, &rt)

	button_id, button_found := alicorn.node_by_key(
		&rt,
		alicorn.key_pair(0xA11C_0001, u64(action_id_for("file.open"))),
		.Button,
	)
	button, button_ok := alicorn.node_info(&rt, button_id)
	testing.expect(t, button_found && button_ok,
		"the current Scratchpad action should be realized as an AliKit result button")
	if !button_found || !button_ok { return }
	x := button.bounds.x+button.bounds.w/2
	y := button.bounds.y+button.bounds.h/2
	down := alicorn.Pointer_Event{kind=.Down, button=alicorn.POINTER_BUTTON_PRIMARY, x=x, y=y}
	down_target := alicorn.process_pointer(&rt, down)
	command_palette_pointer(&app, &rt, down, down_target)
	up := alicorn.Pointer_Event{kind=.Up, button=alicorn.POINTER_BUTTON_PRIMARY, x=x, y=y}
	up_target := alicorn.process_pointer(&rt, up)
	command_palette_pointer(&app, &rt, up, up_target)
	testing.expect(t, down_target == button_id && up_target == button_id,
		"a physical pointer sequence should hit and release on the selected result")

	ui, should_build = alicorn.begin_frame(&rt)
	if !should_build { testing.expect(t, false, "the clicked result should schedule a palette description"); return }
	alicorn.container_begin(&ui, .Root, key=alicorn.key_string("command-palette-content-root"), style=alicorn.layout_style(.Column, grow=1))
	_ = alicorn.text_field(&ui, "", key=alicorn.key_string("command-palette-prior-focus"))
	alicorn.container_end(&ui)
	command_palette_build(&app, &ui, &rt)
	alicorn.end_frame(&ui)
	testing.expect(t, !app.command_palette_open && app.frame_deferred_action_pending &&
		app.frame_deferred_action.kind == .Action && app.frame_deferred_action.value == "file.open" &&
		app.command_palette_recent_count == 1 && app.command_palette_recent[0] == action_id_for("file.open"),
		"pointer activation should queue and record the exact current Scratchpad action after closing the palette")
	if app.frame_deferred_action_pending { deferred_action_destroy(&app.frame_deferred_action) }
}

@(test)
test_command_palette_yields_navigation_during_ime_composition :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 900, 650})
	defer alicorn.destroy_runtime(&rt)
	app: App
	defer alikit.destroy(&app.command_palette_component)
	init_menus(&app)
	command_palette_open_surface(&app, &rt)
	if !command_palette_styled_test_build(t, &app, &rt) { return }
	command_palette_restore_focus_after_frame(&app, &rt)
	query_node := app.command_palette_node
	if !alicorn.process_text_editing(&rt, query_node, "候補", 0, 0) {
		testing.expect(t, false, "the command query should accept native-style preedit text")
		return
	}
	selection_before := app.command_palette_component.selection.id
	handled := application_key(rawptr(&app), &rt, .Down)
	interaction, found := alicorn.text_field_interaction(&rt, query_node)
	testing.expect(t, !handled && app.command_palette_open && found && interaction.composition_active &&
		app.command_palette_component.selection.id == selection_before,
		"Up/Down/Return handling should yield to active input-method candidate navigation")
}

@(test)
test_command_palette_sizes_from_results_and_caps_scroll_content :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 1000, 700})
	defer alicorn.destroy_runtime(&rt)
	app: App
	defer alikit.destroy(&app.command_palette_component)
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
	command_palette_open_surface(&app, &rt)
	_ = alikit.set_query(&app.command_palette_component, &rt, "Open File")

	results := command_palette_collect_results(&app, context.temp_allocator)
	defer delete(results)
	sparse := command_palette_filter_results(results[:], alikit.query_text(&app.command_palette_component), {}, context.temp_allocator)
	defer delete(sparse)
	visible_sparse := min(max(len(sparse), 1), COMMAND_PALETTE_MAX_VISIBLE_ROWS)
	if !command_palette_test_build(t, &app, &rt) { return }
	panel, panel_ok := alicorn.node_info(&rt, app.command_palette_panel_node)
	testing.expect(t, panel_ok && len(sparse) > 0 && len(sparse) < COMMAND_PALETTE_MAX_VISIBLE_ROWS,
		"the focused query should produce a short natural-height result list")
	if panel_ok {
		want_height := f32(108)+f32(visible_sparse)*COMMAND_PALETTE_ROW_HEIGHT
		testing.expect(t, panel.bounds.h == want_height,
			"the command palette panel height should come from its realized query, result, and footer contents")
	}

	_ = alikit.set_query(&app.command_palette_component, &rt, "")
	alicorn.invalidate_root(&rt, "command palette content sizing stress")
	all_results := command_palette_filter_results(results[:], "", {}, context.temp_allocator)
	defer delete(all_results)
	if !command_palette_test_build(t, &app, &rt) { return }
	panel, panel_ok = alicorn.node_info(&rt, app.command_palette_panel_node)
	list, list_ok := alicorn.node_info(&rt, app.command_palette_results_scroll_node)
	testing.expect(t, len(all_results) > COMMAND_PALETTE_MAX_VISIBLE_ROWS,
		"the real command set should exceed the palette's bounded visible row count")
	testing.expect(t, panel_ok && panel.bounds.h == f32(108)+COMMAND_PALETTE_MAX_LIST_HEIGHT,
		"many results should grow the panel only to the capped list height")
	testing.expect(t, list_ok && list.scroll_content_height == f32(len(all_results))*COMMAND_PALETTE_ROW_HEIGHT &&
		list.scroll_viewport_height <= COMMAND_PALETTE_MAX_LIST_HEIGHT,
		"the palette should retain the full result extent while keeping the scroll viewport bounded")
}
