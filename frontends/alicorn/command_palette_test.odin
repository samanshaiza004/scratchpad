package main

import "core:testing"
import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"

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
