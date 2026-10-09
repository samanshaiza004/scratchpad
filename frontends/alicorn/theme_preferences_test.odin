package main

import "core:os"
import "core:strings"
import "core:testing"
import alicorn "alicorn:runtime"

Theme_Switch_Test_Nodes :: struct {
	root:        alicorn.Node_ID,
	workbench:   alicorn.Node_ID,
	field:       alicorn.Node_ID,
	paper:       alicorn.Node_ID,
	paper_text:  alicorn.Node_ID,
}

theme_switch_test_render :: proc(app: ^App, rt: ^alicorn.Runtime) -> Theme_Switch_Test_Nodes {
	ui, should_build := alicorn.begin_frame(rt)
	if !should_build { return {} }
	result := Theme_Switch_Test_Nodes{}
	result.root = alicorn.container_begin(
		&ui,
		.Root,
		key=alicorn.key_string("theme-switch-test-root"),
		style=alicorn.layout_style(.Column, grow=1),
		color=alicorn.style_theme_color(rt, app.workbench_theme, .Window_Background),
	)
	workbench_scope := alicorn.style_environment_push(&ui, scratchpad_workbench_style_environment(app))
	result.workbench = alicorn.text(&ui, "Workbench", key=alicorn.key_string("theme-switch-test-workbench"))
	result.field = alicorn.text_field(
		&ui,
		"Keep focus",
		key=alicorn.key_string("theme-switch-test-field"),
		style=alicorn.layout_style(width=220, height=40),
	)
	editor_scope := alicorn.style_environment_push(&ui, alicorn.Style_Environment{theme=app.editor_theme})
	result.paper = alicorn.surface_begin(
		&ui,
		alicorn.surface_extension_color_role(scratchpad_editor_paper_surface_role()),
		key=alicorn.key_string("theme-switch-test-paper"),
		style=alicorn.layout_style(width=320, height=180, padding=10),
		material=app.paper_surface_material,
		physical_height=-0.75,
	)
	result.paper_text = alicorn.text(&ui, "Editor surface", key=alicorn.key_string("theme-switch-test-paper-text"))
	alicorn.surface_end(&ui)
	alicorn.style_environment_pop(&ui, editor_scope)
	alicorn.style_environment_pop(&ui, workbench_scope)
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
	return result
}

@(test)
test_theme_preferences_round_trip_and_fallback :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp("", "scratchpad-theme-preferences-*", context.temp_allocator)
	if root_error != nil {
		testing.expect(t, false, "could not create a temporary theme-preferences directory")
		return
	}
	defer _ = os.remove_all(root)
	directory, path, location_ok := scratchpad_theme_preferences_location(root, context.temp_allocator)
	testing.expect(t, location_ok, "theme preferences should use a small app-specific directory")
	if !location_ok { return }
	choice, found := scratchpad_theme_preferences_load(path)
	testing.expect(t, !found && choice == .Warm,
		"a missing preference should select the built-in Warm theme without error")

	testing.expect(t, scratchpad_theme_preferences_save(directory, .Cool_Light),
		"choosing a theme should persist the versioned user preference")
	bytes, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error == nil {
		defer delete(bytes, context.temp_allocator)
		testing.expect(t, strings.contains(string(bytes), `"version":1`) && strings.contains(string(bytes), `"theme":"cool-light"`),
			"the preference file should carry its schema version and stable theme name")
	} else {
		testing.expect(t, false, "the saved theme preference should be readable")
	}
	choice, found = scratchpad_theme_preferences_load(path)
	testing.expect(t, found && choice == .Cool_Light,
		"the selected theme should survive a preference-file reload")

	invalid_sources := [?]string{
		`{"version":1,"theme":"removed-theme"}`,
		`{"version":9,"theme":"cool-light"}`,
		`{"version":1,"theme":`,
	}
	for invalid in invalid_sources {
		if os.write_entire_file(path, invalid) != nil {
			testing.expect(t, false, "could not write a fallback fixture")
			continue
		}
		choice, found = scratchpad_theme_preferences_load(path)
		testing.expect(t, !found && choice == .Warm,
			"unknown themes, unsupported versions, and malformed JSON should fall back to Warm")
	}
}

@(test)
test_theme_preferences_use_platform_configuration_root :: proc(t: ^testing.T) {
	config_root, err := os.user_config_dir(context.temp_allocator)
	testing.expect(t, err == nil && config_root != "",
		"theme persistence should resolve through Odin's native per-user configuration directory")
	if err != nil { return }
	directory, path, ok := scratchpad_theme_preferences_location(config_root, context.temp_allocator)
	testing.expect(t, ok && strings.contains(path, "Scratchpad") && strings.contains(path, "preferences.json"),
		"all supported hosts should place a versioned preference under the Scratchpad config directory")
	when ODIN_OS == .Windows {
		testing.expect(t, strings.contains(config_root, "AppData"),
			"Windows preferences should live in the user's AppData configuration root")
	}
	when ODIN_OS == .Darwin {
		testing.expect(t, strings.contains(config_root, "Application Support"),
			"macOS preferences should live in the user's Application Support directory")
	}
	delete(directory, context.temp_allocator)
	delete(path, context.temp_allocator)
}

@(test)
test_theme_switch_is_paint_only_and_preserves_focus_and_identity :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 900, 600})
	defer alicorn.destroy_runtime(&rt)
	if !alicorn.text_engine_load_font(&rt.text_engine, ALICORN_TEST_UI_FONT_DATA) {
		testing.expect(t, false, "theme-switch test should load its UI font")
		return
	}
	app: App
	if !scratchpad_styles_ensure(&app, &rt) {
		testing.expect(t, false, "theme-switch test should register both theme choices")
		return
	}
	root, root_error := os.make_directory_temp("", "scratchpad-theme-switch-*", context.temp_allocator)
	if root_error != nil {
		testing.expect(t, false, "could not create a temporary preference directory")
		return
	}
	defer _ = os.remove_all(root)
	directory, path, location_ok := scratchpad_theme_preferences_location(root, context.temp_allocator)
	if !location_ok { testing.expect(t, false, "theme-switch test should form a preference path"); return }
	app.theme_preferences_directory = directory
	app.theme_preferences_path = path
	defer delete(directory, context.temp_allocator)
	defer delete(path, context.temp_allocator)

	first := theme_switch_test_render(&app, &rt)
	focused := alicorn.focus(&rt, first.field)
	before_paint_color := rt.nodes[first.workbench].color
	before_layout_visits := rt.stats.layout_nodes_visited
	before_measure_requests := rt.stats.measure_requests
	before_paint_visits := rt.stats.paint_nodes_visited
	testing.expect(t, focused && alicorn.focused_node(&rt) == first.field,
		"the theme-switch fixture should focus its retained input before switching")
	palette_selected := command_palette_execute(&app, &rt, Command_Palette_Result{
		action_id=ACTION_VIEW_THEME_COOL_LIGHT,
		title="Use Cool Light Theme",
		category="View",
		enabled=true,
	}, false)
	if !palette_selected || app.theme_choice != .Cool_Light {
		testing.expect(t, false, "the command palette should select and persist the Cool Light theme")
		return
	}
	second := theme_switch_test_render(&app, &rt)
	second_workbench := rt.nodes[second.workbench]
	testing.expect(t, second.root == first.root && second.workbench == first.workbench &&
		second.field == first.field && second.paper == first.paper && second.paper_text == first.paper_text,
		"theme changes should preserve retained control and surface identities")
	testing.expect(t, app.theme_choice == .Cool_Light &&
		rt.nodes[second.workbench].style_environment.theme == app.cool_light_theme &&
		rt.nodes[second.paper_text].style_environment.theme == app.cool_light_theme &&
		second_workbench.color != before_paint_color,
		"the selected theme should reach both workbench and editor paint scopes")
	testing.expect(t, alicorn.focused_node(&rt) == first.field,
		"changing theme should retain keyboard focus on the same text field")
	testing.expect(t, rt.stats.layout_nodes_visited == before_layout_visits &&
		rt.stats.measure_requests == before_measure_requests,
		"color-only theme switching should trigger no layout visits or text measurements")
	testing.expect(t, rt.stats.paint_nodes_visited > before_paint_visits,
		"color-only theme switching should refresh paint for the retained presentation")

	choice, loaded := scratchpad_theme_preferences_load(path)
	testing.expect(t, loaded && choice == .Cool_Light,
		"the theme chosen in the application should be persisted for the next launch")
	_ = scratchpad_theme_select(&app, &rt, .Warm)
	third := theme_switch_test_render(&app, &rt)
	testing.expect(t, alicorn.focused_node(&rt) == first.field && third.field == first.field &&
		rt.nodes[third.workbench].style_environment.theme == app.warm_workbench_theme &&
		rt.nodes[third.paper_text].style_environment.theme == app.warm_editor_theme,
		"switching back should restore the warm theme pair without replacing focused controls")
}
