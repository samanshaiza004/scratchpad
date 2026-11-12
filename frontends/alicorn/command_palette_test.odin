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

command_palette_motion_test_build :: proc(t: ^testing.T, app: ^App, rt: ^alicorn.Runtime) -> bool {
	if !scratchpad_styles_ensure(app, rt) {
		testing.expect(t, false, "palette motion fixture should register the workbench theme")
		return false
	}
	ui, should_build := alicorn.begin_frame(rt)
	if !should_build {
		testing.expect(t, false, "palette motion fixture should build its invalidated description")
		return false
	}
	alicorn.container_begin(&ui, .Root, key=alicorn.key_string("command-palette-content-root"), style=alicorn.layout_style(.Column, grow=1))
	scope := alicorn.style_environment_push(&ui, scratchpad_workbench_style_environment(app))
	command_palette_build(app, &ui, rt)
	alicorn.style_environment_pop(&ui, scope)
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
	return true
}

@(test)
test_command_palette_reveals_only_its_decoration_once :: proc(t: ^testing.T) {
	for reduce_motion in ([2]bool{false, true}) {
		rt := alicorn.new_runtime(alicorn.Rect{0, 0, 900, 650})
		app: App
		init_menus(&app)
		app.accessibility_appearance_override_enabled = true
		app.accessibility_appearance.reduce_motion = reduce_motion
		_ = alicorn.motion_clock_set_time(&rt, alicorn.Motion_Time(0))
		command_palette_open_surface(&app, &rt)
		testing.expect(t, app.command_palette_reveal_pending,
			"opening the palette should queue one decorative Reveal")
		if !command_palette_motion_test_build(t, &app, &rt) {
			alicorn.destroy_runtime(&rt)
			continue
		}
		command_palette_restore_focus_after_frame(&app, &rt)
		accent_id := app.command_palette_motion_accent_node
		accent, accent_ok := alicorn.node_info(&rt, accent_id)
		query_focus_ok := app.command_palette_node != 0 && rt.focused == app.command_palette_node
		stats := alicorn.motion_diagnostics_stats(&rt)
		handle, handle_status := alicorn.motion_owner_begin(&rt, accent_id)
		presentation := alicorn.motion_presentation(&rt, handle)
		testing.expect(t, accent_ok && app.command_palette_panel_node != 0 && app.command_palette_node != 0 &&
			query_focus_ok && !app.command_palette_reveal_pending,
			"the palette panel and query remain present and focused immediately while the accent reveals")
		testing.expect(t, stats.reveals == 1 && handle_status == .Ok,
			"the opt-in Reveal should belong only to the passive accent surface")
		if reduce_motion {
			testing.expect(t, !presentation.active && presentation.presented_opacity == 1 &&
				presentation.presented_translation == [2]f32{0, 0},
				"reduced motion should snap the palette accent to its final presentation")
		} else {
			testing.expect(t, presentation.active && presentation.presented_opacity == 0 &&
				presentation.presented_translation == [2]f32{0, -6},
				"normal motion should reveal the accent from a small offset and zero opacity")
		}

		find_set_message(&app.command_palette_query, "Open File")
		alicorn.invalidate_root(&rt, "palette query rebuild after Reveal")
		_ = alicorn.motion_clock_set_time(&rt, alicorn.Motion_Time(20_000_000))
		if command_palette_motion_test_build(t, &app, &rt) {
			command_palette_restore_focus_after_frame(&app, &rt)
			updated_accent, updated_ok := alicorn.node_info(&rt, app.command_palette_motion_accent_node)
			updated_stats := alicorn.motion_diagnostics_stats(&rt)
			testing.expect(t, updated_ok && app.command_palette_motion_accent_node == accent_id &&
				updated_accent.bounds == accent.bounds && updated_stats.reveals == 1 &&
				updated_stats.intent_declarations == stats.intent_declarations,
				"query updates should preserve accent geometry and never replay its birth animation")
			testing.expect(t, rt.focused == app.command_palette_node,
				"query rebuilds should keep keyboard focus on the palette field")
		}
		if !reduce_motion {
			_ = alicorn.motion_tick(&rt, alicorn.Motion_Time(5_000_000_000))
		}
		testing.expect(t, alicorn.motion_activity(&rt).active_owners == 0,
			"the palette accent should have no motion activity after settlement")
		command_palette_close_surface(&app, &rt, false)
		testing.expect(t, !app.command_palette_reveal_pending,
			"closing the palette should discard any pending entrance intent without an exit ghost")
		alicorn.destroy_runtime(&rt)
	}
}

@(test)
test_command_palette_reduce_motion_change_during_reveal_does_not_replay_birth :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 900, 650})
	defer alicorn.destroy_runtime(&rt)
	app: App
	init_menus(&app)
	app.accessibility_appearance_override_enabled = true
	_ = alicorn.motion_clock_set_time(&rt, alicorn.Motion_Time(0))
	command_palette_open_surface(&app, &rt)
	if !command_palette_motion_test_build(t, &app, &rt) { return }
	command_palette_restore_focus_after_frame(&app, &rt)
	accent_id := app.command_palette_motion_accent_node
	initial_stats := alicorn.motion_diagnostics_stats(&rt)
	initial := alicorn.motion_diagnostics_owner_snapshot(&rt, accent_id)
	testing.expect(t, initial.valid && initial.opacity.active && initial_stats.reveals == 1,
		"the normal-motion palette should begin its single decorative Reveal")

	app.accessibility_appearance.reduce_motion = true
	alicorn.invalidate_root(&rt, "Reduce Motion changed during command-palette Reveal")
	_ = alicorn.motion_clock_set_time(&rt, alicorn.Motion_Time(20_000_000))
	if command_palette_motion_test_build(t, &app, &rt) {
		command_palette_restore_focus_after_frame(&app, &rt)
		changed_stats := alicorn.motion_diagnostics_stats(&rt)
		handle, handle_status := alicorn.motion_owner_begin(&rt, accent_id)
		presentation := alicorn.motion_presentation(&rt, handle)
		testing.expect(t, changed_stats.intent_declarations > initial_stats.intent_declarations &&
			changed_stats.reveals == 1 && handle_status == .Ok && !presentation.active &&
			presentation.presented_opacity == 1 && presentation.presented_translation == [2]f32{0, 0},
			"a policy change should settle the existing entrance to its target without replaying Reveal")
		testing.expect(t, rt.focused == app.command_palette_node,
			"changing Reduce Motion during the accent entrance should preserve query focus")
		alicorn.invalidate_root(&rt, "repeat palette description after policy update")
		_ = alicorn.motion_clock_set_time(&rt, alicorn.Motion_Time(30_000_000))
		if command_palette_motion_test_build(t, &app, &rt) {
			repeated_stats := alicorn.motion_diagnostics_stats(&rt)
			testing.expect(t, repeated_stats.intent_declarations == changed_stats.intent_declarations &&
				repeated_stats.reveals == 1,
				"an unchanged motion policy should not add declarations or repeat the birth Reveal")
		}
	}
	command_palette_close_surface(&app, &rt, false)
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
	find_set_message(&app.command_palette_query, "Open File")

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

	find_set_message(&app.command_palette_query, "")
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
