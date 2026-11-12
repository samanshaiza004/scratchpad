package main

import "core:os"
import "core:strings"
import "core:testing"
import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"
import bridge "./bridge"

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
	testing.expect(t, scratchpad_theme_preferences_save(directory, .Warm),
		"a new selection should atomically replace an existing preference")
	choice, found = scratchpad_theme_preferences_load(path)
	testing.expect(t, found && choice == .Warm,
		"the replacement preference should be complete and readable")
	testing.expect(t, scratchpad_theme_preferences_save(directory, .Cool_Light),
		"the preference should be replaceable repeatedly")

	for optical in ([2]Scratchpad_Theme_Choice{.Flat, .Workbench_Relief}) {
		testing.expect(t, scratchpad_theme_preferences_save(directory, optical), "optical preference should save atomically")
		restored, restored_ok := scratchpad_theme_preferences_load(path)
		testing.expect(t, restored_ok && restored == optical, "optical preference should survive a restart")
	}
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

theme_preferences_test_paint_contains_color :: proc(rt: ^alicorn.Runtime, node_id: alicorn.Node_ID, expected: alicorn.Color) -> bool {
	if rt == nil || node_id == 0 { return false }
	node, found := rt.nodes[node_id]
	if !found { return false }
	for command in node.paint {
		color, color_ok := alicorn.paint_surface_color(command)
		if color_ok && color == expected { return true }
	}
	return false
}

@(test)
test_live_editor_theme_replacement_preserves_document_interaction_and_scroll :: proc(t: ^testing.T) {
	LINE_COUNT :: 180
	DOCUMENT_ID :: "live-theme-source"

	// Exercise Alicorn's in-place API through Scratchpad's actual editor theme
	// scope, with enough source to create a genuinely scrollable editor.
	source_text, source_error := strings.repeat("A retained Markdown paragraph for live theme dogfooding.\n", LINE_COUNT, context.temp_allocator)
	testing.expect(t, source_error == nil, "live-theme dogfood should create a multi-page Markdown source")
	if source_error != nil { return }
	source, source_alloc_error := make([]u8, len(source_text), allocator=context.allocator)
	testing.expect(t, source_alloc_error == nil, "live-theme dogfood should allocate mutable owned source bytes")
	if source_alloc_error != nil { return }
	for index in 0..<len(source_text) { source[index] = source_text[index] }
	source_snapshot, snapshot_error := strings.clone(string(source), context.temp_allocator)
	if snapshot_error != nil {
		delete(source)
		testing.expect(t, false, "live-theme dogfood should snapshot authoritative source bytes")
		return
	}
	defer delete(source_snapshot, context.temp_allocator)

	app: App
	app.backend.started = true
	app.backend.state.has_workspace = true
	app.backend.state.revision = 37
	app.backend.state.workspace_root = "/scratchpad/live-theme-dogfood"
	app.backend.state.active = DOCUMENT_ID
	app.tree_root_path = app.backend.state.workspace_root
	app.tree_directories = make([dynamic]Tree_Directory, 0, allocator=context.allocator)
	app.editor_views = make([dynamic]Editor_View_State, 0, allocator=context.allocator)
	app.editor_edits = make([dynamic]Editor_Edit_Intent, 0, allocator=context.allocator)
	app.editor_row_targets = make([dynamic]Editor_Row_Target, 0, allocator=context.allocator)
	app.deferred_actions = make([dynamic]Deferred_Action, 0, allocator=context.allocator)
	init_menus(&app)
	documents := [?]bridge.State_Document{{
		id=DOCUMENT_ID,
		instance_id=92,
		path="notes.md",
		status="synced",
		dirty=true,
		editor_revision=11,
		line_count=LINE_COUNT,
		byte_length=u64(len(source)),
		language="markdown",
		presentation_revision=11,
		presentation_ready=true,
	}}
	app.backend.state.documents = documents[:]

	visible := bridge.Visible_Window{
		document_id=DOCUMENT_ID,
		document_instance_id=92,
		application_rev=37,
		editor_revision=11,
		start_line=0,
		end_line=LINE_COUNT,
		start_byte=0,
		line_byte_length=u64(len(source)),
		source=source,
		presentation_revision=11,
		presentation_ready=true,
	}
	window, window_ok, window_error := editor_window_from_visible(&visible, context.allocator)
	if !window_ok {
		if len(visible.source) > 0 { delete(visible.source, context.allocator) }
		testing.expect(t, false, window_error)
		return
	}
	app.editor_window = window
	app.editor_window_ready = true
	source = {}
	testing.expect(t, scratchpad_workbench_test_initialize(&app), "the live-theme fixture should initialize its editor view")

	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 1000, 700})
	defer {
		scratchpad_workbench_test_destroy(&app)
		if len(app.editor_presented_document_id) > 0 { delete(app.editor_presented_document_id, context.allocator) }
		editor_window_destroy(&app.editor_window, context.allocator)
		editor_views_destroy(&app.editor_views, context.allocator)
		delete(app.editor_edits)
		delete(app.editor_row_targets)
		delete(app.tree_directories)
		deferred_actions_clear(&app)
		delete(app.deferred_actions)
		alicorn.destroy_runtime(&rt)
	}

	fonts_loaded := alicorn.text_engine_load_font(&rt.text_engine, ALICORN_TEST_UI_FONT_DATA) &&
		alicorn.text_engine_load_font_role(&rt.text_engine, .Monospace, ALICORN_TEST_MONO_FONT_DATA)
	styles_ready := fonts_loaded && scratchpad_styles_ensure(&app, &rt)
	testing.expect(t, styles_ready, "the real editor should load its fonts and generated theme")
	if !styles_ready { return }
	stable_theme_id := app.editor_theme
	registry_size := len(rt.style_themes)

	view_index, view_ok := editor_view_ensure(&app.editor_views, DOCUMENT_ID)
	testing.expect(t, view_ok, "the real document should have retained editor state")
	if !view_ok { return }
	view := &app.editor_views[view_index]
	view.document_instance_id = 92
	view.authoritative_revision = 11

	_ = build_app(rawptr(&app), &rt, 1000, 700, 1)
	if app.editor_scroll_owner == 0 { testing.expect(t, false, "the real editor should create its scroll owner"); return }
	_ = alicorn.scroll_region_set_offset(&rt, app.editor_scroll_owner, 900, "position live-theme dogfood in the document")
	_ = build_app(rawptr(&app), &rt, 1000, 700, 1)
	testing.expect(t, len(app.editor_row_targets) > 4, "the scrolled editor should realize several visible source rows")
	if len(app.editor_row_targets) <= 4 { return }

	target := app.editor_row_targets[len(app.editor_row_targets)/2]
	line, line_found := editor_window_line(&app.editor_window, target.logical_line)
	testing.expect(t, line_found && len(line.display) > 8, "the chosen visible row should map to a source line")
	if !line_found || len(line.display) <= 8 { return }
	view.selection_anchor = line.source_start+2
	view.caret_byte = line.source_start+8
	view.caret_affinity = .Trailing
	_ = alicorn.focus(&rt, app.editor_scroll_owner)
	_ = build_app(rawptr(&app), &rt, 1000, 700, 1)
	view_index = editor_view_find(app.editor_views[:], DOCUMENT_ID)
	if view_index < 0 { testing.expect(t, false, "the editor view should remain associated with the active document"); return }
	view = &app.editor_views[view_index]
	selected_line := line.logical_line
	selected_target, row_found := editor_row_target_for_source(app.editor_row_targets[:], selected_line, view.caret_byte)
	row_before, row_before_found := rt.nodes[selected_target.node]
	paper_id := theme_switch_test_find_label(&rt, "document-surface")
	paper_before, paper_before_found := rt.nodes[paper_id]
	selection_before, caret_before := view.selection_anchor, view.caret_byte
	owner_before := alicorn.scroll_region_state(&rt, app.editor_scroll_owner)
	active_before, active_before_found := alicorn.style_extension_color(&rt, stable_theme_id, scratchpad_editor_active_line_role())
	paper_before_color, paper_color_found := alicorn.style_extension_color(&rt, stable_theme_id, scratchpad_editor_paper_surface_role())
	active_row_node := alicorn.Node_ID(0)
	old_active_painted := false
	if row_before_found {
		if source_lane, lane_found := rt.nodes[row_before.parent]; lane_found { active_row_node = source_lane.parent }
		old_active_painted = theme_preferences_test_paint_contains_color(&rt, active_row_node, active_before)
	}
	old_paper_painted := paper_before_found && paper_color_found &&
		theme_preferences_test_paint_contains_color(&rt, paper_id, paper_before_color)
	testing.expect(t, row_found && row_before_found && row_before.text_interaction_show_caret &&
		row_before.text_interaction_focus.byte == int(view.caret_byte-line.source_start),
		"the active source row should have its real caret and focused editor interaction before replacement")
	testing.expect(t, owner_before.offset_y > 0 && row_before_found && row_before.bounds.y >= owner_before.viewport_bounds.y &&
		row_before.bounds.y+row_before.bounds.h <= owner_before.viewport_bounds.y+owner_before.viewport_height,
		"the focused source row should be visible in a genuinely scrolled editor")
	testing.expect(t, old_active_painted,
		"the focused logical-row container should paint Scratchpad's original active-line theme color")
	testing.expect(t, old_paper_painted,
		"the document surface should paint Scratchpad's original paper theme color")
	if !row_found || !row_before_found || !paper_before_found || !active_before_found || !paper_color_found { return }

	active_token, active_token_found := alicorn.style_extension_color_token(&rt, stable_theme_id, scratchpad_editor_active_line_role())
	paper_token, paper_token_found := alicorn.style_extension_color_token(&rt, stable_theme_id, scratchpad_editor_paper_surface_role())
	candidate := scratchpad_editor_theme(context.allocator)
	defer scratchpad_editor_theme_destroy(&candidate, context.allocator)
	testing.expect(t, active_token_found && paper_token_found && u32(active_token) <= u32(len(candidate.color_tokens)) &&
		u32(paper_token) <= u32(len(candidate.color_tokens)),
		"Scratchpad's generated editor theme should expose stable tokens for its real editor colors")
	if !active_token_found || !paper_token_found || u32(active_token) > u32(len(candidate.color_tokens)) ||
		u32(paper_token) > u32(len(candidate.color_tokens)) { return }
	new_active := alicorn.Color{0.88, 0.16, 0.54, 0.42}
	new_paper := alicorn.Color{0.70, 0.83, 0.92, 1}
	candidate.color_tokens[int(u32(active_token))-1] = new_active
	candidate.color_tokens[int(u32(paper_token))-1] = new_paper

	layout_before := rt.stats.layout_nodes_visited
	measure_before := rt.stats.measure_requests
	shape_before := rt.stats.text_shape_requests
	paint_before := rt.stats.paint_nodes_visited
	result := alicorn.style_theme_replace(&rt, stable_theme_id, candidate)
	testing.expect(t, result == .Replaced && app.editor_theme == stable_theme_id && len(rt.style_themes) == registry_size,
		"live editor-theme dogfooding should replace the same theme ID without growing the registry")
	if result != .Replaced { return }
	new_active_resolved, active_resolved := alicorn.style_extension_color(&rt, stable_theme_id, scratchpad_editor_active_line_role())
	new_paper_resolved, paper_resolved := alicorn.style_extension_color(&rt, stable_theme_id, scratchpad_editor_paper_surface_role())
	testing.expect(t, active_resolved && new_active_resolved == new_active && paper_resolved && new_paper_resolved == new_paper,
		"the active runtime theme should resolve the newly adopted Scratchpad colors")

	// Scratchpad bakes extension colors into active-row decoration at description
	// time, so it explicitly invalidates that derived app-owned paint once. The
	// runtime still resolves the paper role itself and performs no layout work.
	alicorn.invalidate_root(&rt, "Scratchpad live editor-theme candidate")
	_ = build_app(rawptr(&app), &rt, 1000, 700, 1)
	view_index = editor_view_find(app.editor_views[:], DOCUMENT_ID)
	view = &app.editor_views[view_index]
	row_after_target, row_after_target_found := editor_row_target_for_source(app.editor_row_targets[:], selected_line, view.caret_byte)
	row_after, row_after_found := rt.nodes[row_after_target.node]
	paper_after, paper_after_found := rt.nodes[paper_id]
	after_scroll := alicorn.scroll_region_state(&rt, app.editor_scroll_owner)
	active_row_after := alicorn.Node_ID(0)
	if row_after_found {
		if source_lane, lane_found := rt.nodes[row_after.parent]; lane_found { active_row_after = source_lane.parent }
	}
	active_painted := row_after_found && theme_preferences_test_paint_contains_color(&rt, active_row_after, new_active)
	paper_painted := paper_after_found && theme_preferences_test_paint_contains_color(&rt, paper_id, new_paper)
	document_after, document_found := find_document(&app.backend.state, DOCUMENT_ID)
	testing.expect(t, document_found && document_after.instance_id == 92 && document_after.editor_revision == 11 &&
		document_after.dirty && app.backend.state.active == DOCUMENT_ID && app.backend.state.revision == 37 &&
		app.backend.state.workspace_root == "/scratchpad/live-theme-dogfood" &&
		string(app.editor_window.source) == source_snapshot,
		"theme replacement must preserve Scratchpad's authoritative unsaved document and workspace state")
	testing.expect(t, view.selection_anchor == selection_before && view.caret_byte == caret_before &&
		alicorn.focused_node(&rt) == app.editor_scroll_owner && row_after_target_found &&
	row_after_target.node == selected_target.node && row_after_found && row_after.text_interaction_show_caret,
		"theme replacement must preserve source selection, caret, focus, and retained row identity")
	testing.expect(t, abs(after_scroll.offset_y-owner_before.offset_y) < 1 && row_after_found &&
		row_after.bounds.y >= after_scroll.viewport_bounds.y &&
		row_after.bounds.y+row_after.bounds.h <= after_scroll.viewport_bounds.y+after_scroll.viewport_height,
		"theme replacement must preserve the scroll offset and keep the focused source row visible")
	testing.expect(t, active_painted,
		"the next Scratchpad frame should paint the replacement active-line color on the focused logical row")
	testing.expect(t, paper_painted,
		"the next Scratchpad frame should paint the replacement paper color on the document surface")
	testing.expect(t, rt.stats.layout_nodes_visited == layout_before && rt.stats.measure_requests == measure_before &&
		rt.stats.text_shape_requests == shape_before && rt.stats.paint_nodes_visited > paint_before,
		"the real editor should adopt color-only replacement through paint without layout, measurement, or reshaping")
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
	cool_chrome := scratchpad_window_chrome_appearance(rawptr(&app), &rt)
	testing.expect(t, second.root == first.root && second.workbench == first.workbench &&
		second.field == first.field && second.paper == first.paper && second.paper_text == first.paper_text,
		"theme changes should preserve retained control and surface identities")
	testing.expect(t, app.theme_choice == .Cool_Light &&
		rt.nodes[second.workbench].style_environment.theme == app.cool_light_theme &&
		rt.nodes[second.paper_text].style_environment.theme == app.cool_light_theme &&
		second_workbench.color != before_paint_color,
		"the selected theme should reach both workbench and editor paint scopes")
	testing.expect(t, cool_chrome.defined &&
		cool_chrome.background == alicorn.style_theme_color(&rt, app.cool_light_theme, .Surface) &&
		cool_chrome.foreground == alicorn.style_theme_color(&rt, app.cool_light_theme, .Text),
		"the host chrome appearance should resolve from the selected Cool Light workbench theme")
	testing.expect(t, alicorn.focused_node(&rt) == first.field,
		"changing theme should retain keyboard focus on the same text field")
	testing.expect(t, rt.stats.layout_nodes_visited == before_layout_visits &&
		rt.stats.measure_requests == before_measure_requests,
		"color-only theme switching should trigger no layout visits or text measurements")
	testing.expect(t, rt.stats.paint_nodes_visited > before_paint_visits,
		"color-only theme switching should refresh paint for the retained presentation")
	stats_before_idle := rt.stats
	idle_ui, idle_should_build := alicorn.begin_frame(&rt)
	testing.expect(t, !idle_should_build,
		"after the application paints the selected theme, an idle frame should not request another description")
	if idle_should_build { alicorn.end_frame(&idle_ui) }
	testing.expect(t, rt.stats.frames_built == stats_before_idle.frames_built &&
		rt.stats.descriptions_emitted == stats_before_idle.descriptions_emitted &&
		rt.stats.reconcile_nodes_visited == stats_before_idle.reconcile_nodes_visited &&
		rt.stats.layout_nodes_visited == stats_before_idle.layout_nodes_visited &&
		rt.stats.paint_nodes_visited == stats_before_idle.paint_nodes_visited &&
		rt.stats.composition_nodes_visited == stats_before_idle.composition_nodes_visited &&
		rt.stats.measure_requests == stats_before_idle.measure_requests &&
		rt.stats.text_shape_requests == stats_before_idle.text_shape_requests &&
		rt.stats.idle_frames == stats_before_idle.idle_frames+1,
		"the theme switch should settle into a no-work idle frame")

	persisted, loaded := scratchpad_user_preferences_load(path, context.temp_allocator)
	testing.expect(t, loaded && persisted.color_theme == SCRATCHPAD_THEME_BUILTIN_COOL,
		"the theme chosen in the application should be persisted for the next launch")
	delete(persisted.theme, context.temp_allocator)
	delete(persisted.color_theme, context.temp_allocator)
	delete(persisted.surface_treatment, context.temp_allocator)
	delete(persisted.editor_font_family, context.temp_allocator)
	_ = scratchpad_theme_select(&app, &rt, .Warm)
	third := theme_switch_test_render(&app, &rt)
	warm_chrome := scratchpad_window_chrome_appearance(rawptr(&app), &rt)
	testing.expect(t, alicorn.focused_node(&rt) == first.field && third.field == first.field &&
		rt.nodes[third.workbench].style_environment.theme == app.warm_workbench_theme &&
		rt.nodes[third.paper_text].style_environment.theme == app.warm_editor_theme,
		"switching back should restore the warm theme pair without replacing focused controls")
	testing.expect(t, warm_chrome.defined &&
		warm_chrome.background == alicorn.style_theme_color(&rt, app.warm_workbench_theme, .Surface) &&
		warm_chrome.foreground == alicorn.style_theme_color(&rt, app.warm_workbench_theme, .Text),
		"switching back should restore matching Warm chrome colors")
}

theme_switch_test_find_label :: proc(rt: ^alicorn.Runtime, label: string) -> alicorn.Node_ID {
	if rt == nil { return 0 }
	for node_id in rt.order {
		node, found := rt.nodes[node_id]
		if found && node.active && node.label == label { return node_id }
	}
	return 0
}
@(test)
test_full_application_theme_switch_preserves_modal_tab_syntax_and_caret :: proc(t: ^testing.T) {
	app: App
	app.backend.started = true
	app.backend.state.has_workspace = true
	app.backend.state.revision = 5
	app.backend.state.workspace_root = "C:/theme-switch-fixture"
	source := "func main() { return 42 }"
	documents := [?]bridge.State_Document{{
		id="theme-source", path="sample.go", status="synced", dirty=false, preview=false,
		editor_revision=4, line_count=1, byte_length=u64(len(source)),
		language="go", presentation_revision=4, presentation_ready=true,
	}}
	app.backend.state.documents = documents[:]
	app.backend.state.active = "theme-source"
	app.tree_root_path = app.backend.state.workspace_root
	app.tree_directories = make([dynamic]Tree_Directory, 0, allocator=context.allocator)
	app.editor_views = make([dynamic]Editor_View_State, 0, allocator=context.allocator)
	app.editor_edits = make([dynamic]Editor_Edit_Intent, 0, allocator=context.allocator)
	app.editor_row_targets = make([dynamic]Editor_Row_Target, 0, allocator=context.allocator)
	app.find_open = false
	init_menus(&app)

	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 1000, 680})
	app.window_chrome_metrics = host.Window_Chrome_Metrics{
		header={0, 0, 1000, SCRATCHPAD_CONTENT_TITLEBAR_HEIGHT},
		content_start_x=80,
		display_scale=1,
	}
	defer {
		scratchpad_workbench_test_destroy(&app)
		if len(app.editor_presented_document_id) > 0 { delete(app.editor_presented_document_id, context.allocator) }
		editor_window_destroy(&app.editor_window, context.allocator)
		editor_views_destroy(&app.editor_views)
		delete(app.editor_edits)
		delete(app.editor_row_targets)
		delete(app.tree_directories)
		alicorn.destroy_runtime(&rt)
	}

	view_index, view_ok := editor_view_ensure(&app.editor_views, "theme-source")
	testing.expect(t, view_ok, "the full-app fixture should create editor state")
	if !view_ok { return }
	app.editor_views[view_index].selection_anchor = 5
	app.editor_views[view_index].caret_byte = 5

	source_bytes, source_error := make([]u8, len(source), context.allocator)
	testing.expect(t, source_error == nil, "the full-app fixture should allocate bounded source bytes")
	if source_error != nil { return }
	for index in 0..<len(source) { source_bytes[index] = source[index] }
	presentation_spans := make([dynamic]bridge.Presentation_Record, 0, allocator=context.allocator)
	append(&presentation_spans,
		bridge.Presentation_Record{kind=EDITOR_PRESENTATION_CODE_KEYWORD, start_byte=0, end_byte=4},
		bridge.Presentation_Record{kind=EDITOR_PRESENTATION_CODE_FUNCTION, start_byte=5, end_byte=9},
		bridge.Presentation_Record{kind=EDITOR_PRESENTATION_CODE_NUMBER, start_byte=21, end_byte=23},
	)
	visible := bridge.Visible_Window{
		document_id="theme-source",
		application_rev=5,
		editor_revision=4,
		start_line=0,
		end_line=1,
		start_byte=0,
		line_byte_length=u64(len(source)),
		source=source_bytes,
		presentation_revision=4,
		presentation_ready=true,
		presentation_spans=presentation_spans[:],
	}
	window, window_ok, window_error := editor_window_from_visible(&visible, context.allocator)
	testing.expect(t, window_ok, window_error)
	if !window_ok {
		if len(visible.source) > 0 { delete(visible.source) }
		if len(visible.presentation_spans) > 0 { delete(visible.presentation_spans) }
		return
	}
	app.editor_window = window
	app.editor_window_ready = true
	testing.expect(t, scratchpad_workbench_test_initialize(&app), "the full-app theme fixture should initialize its editor view")
	fonts_loaded := alicorn.text_engine_load_font(&rt.text_engine, ALICORN_TEST_UI_FONT_DATA) &&
		alicorn.text_engine_load_font_role(&rt.text_engine, .Monospace, ALICORN_TEST_MONO_FONT_DATA)
	testing.expect(t, fonts_loaded, "the full-app theme smoke should load UI and source fonts")
	if !fonts_loaded { return }
	_ = build_app(rawptr(&app), &rt, 1000, 680, 1)
	app.editor_focus_pending = true
	_ = build_app(rawptr(&app), &rt, 1000, 680, 1)
	focused := app.editor_scroll_owner != 0 && alicorn.focused_node(&rt) == app.editor_scroll_owner
	testing.expect(t, focused, "the full-app fixture should focus its source editor through Scratchpad's normal focus path")
	if !focused { return }
	_ = build_app(rawptr(&app), &rt, 1000, 680, 1)

	if len(app.editor_row_targets) == 0 {
		testing.expect(t, false, "the full-app fixture should realize its source row")
		return
	}
	row_id := app.editor_row_targets[0].node
	row_before, row_before_found := rt.nodes[row_id]
	paper_id := theme_switch_test_find_label(&rt, "document-surface")
	paper_before, paper_before_found := rt.nodes[paper_id]
	tab_variant, tab_selected, tab_found := scratchpad_test_tab_button_for_label(
		&rt, "sample.go", document_tab_semantic_id("theme-source"),
	)
	testing.expect(t, row_before_found && len(row_before.text_paint_spans) > 0,
		"the source editor should carry syntax highlighting in the full application")
	testing.expect(t, row_before_found && row_before.text_interaction_show_caret && row_before.text_interaction_focus.byte == 5,
		"the focused editor should expose its caret at the fixture's source byte")
	testing.expect(t, tab_found && tab_variant == .Tab && tab_selected,
		"the active document should remain a selected Tab recipe in the full application")
	testing.expect(t, paper_before_found, "the full application should retain its paper editor surface")
	if !paper_before_found { return }

	// Open a real modal above the editor, then change themes while both the
	// modal and the document's active interaction state remain in the tree.
	app.close_document_id = "theme-source"
	alicorn.invalidate_root(&rt, "show theme-switch modal fixture")
	_ = build_app(rawptr(&app), &rt, 1000, 680, 1)
	layout_visits_before := rt.stats.layout_nodes_visited
	measurements_before := rt.stats.measure_requests
	paint_visits_before := rt.stats.paint_nodes_visited
	selected := scratchpad_theme_select(&app, &rt, .Cool_Light)
	testing.expect(t, selected, "the full-app fixture should switch to Cool Light")
	if !selected { return }
	_ = build_app(rawptr(&app), &rt, 1000, 680, 1)

	modal_id := theme_switch_test_find_label(&rt, "dirty-close-dialog")
	row_after, row_after_found := rt.nodes[row_id]
	paper_after, paper_after_found := rt.nodes[paper_id]
	tab_after_variant, tab_after_selected, tab_after_found := scratchpad_test_tab_button_for_label(
		&rt, "sample.go", document_tab_semantic_id("theme-source"),
	)
	testing.expect(t, modal_id != 0 && row_after_found && paper_after_found,
		"the modal, editor row, and paper should all remain retained across a theme change")
	testing.expect(t, tab_after_found && tab_after_variant == .Tab && tab_after_selected,
		"the active document tab should remain selected after switching themes under a modal")
	testing.expect(t, row_after_found && len(row_after.text_paint_spans) > 0 &&
		row_after.text_interaction && row_after.text_interaction_focus.byte == 5,
		"syntax spans and the editor's source-byte caret should survive the theme switch")
	testing.expect(t, row_after_found && !row_after.text_interaction_show_caret,
		"the modal should hide the covered editor caret while retaining its source-byte position")
	paper_fill_is_cool := false
	if paper_after_found {
		for command in paper_after.paint {
			color, color_ok := alicorn.paint_surface_color(command)
			if color_ok && color.b > color.r { paper_fill_is_cool = true; break }
		}
	}
	testing.expect(t, paper_after_found && paper_after.style_environment.theme == app.cool_light_theme &&
		paper_fill_is_cool,
		"the cool theme should reach the rendered paper surface with a neutral-cool rather than yellow cast")
	testing.expect(t, rt.stats.layout_nodes_visited == layout_visits_before &&
		rt.stats.measure_requests == measurements_before && rt.stats.paint_nodes_visited > paint_visits_before,
		"a full-app color theme change should repaint without remeasuring or relaying out")
	for choice in ([3]Scratchpad_Theme_Choice{.Flat, .Workbench_Relief, .Warm}) {
		layout, measures := rt.stats.layout_nodes_visited, rt.stats.measure_requests
		before := alicorn.semantic_snapshot(&rt)
		_ = scratchpad_theme_select(&app, &rt, choice)
		_ = build_app(rawptr(&app), &rt, 1000, 680, 1)
		after := alicorn.semantic_snapshot(&rt)
		testing.expect(t, rt.stats.layout_nodes_visited == layout && rt.stats.measure_requests == measures,
			"changing optical appearance in the full document/modal scene must not perform layout or measurement")
		testing.expect(t, len(before.nodes) == len(after.nodes), "relief must not create semantic decorations")
		if len(before.nodes) == len(after.nodes) {
			for node, i in before.nodes {
				other := after.nodes[i]
				testing.expect(t, node.id == other.id && node.role == other.role && node.label == other.label && node.value == other.value && node.actions == other.actions && node.bounds == other.bounds,
					"optical themes preserve the full scene's semantics and geometry")
			}
		}
		testing.expect(t, rt.nodes[row_id].bounds == row_after.bounds && rt.nodes[row_id].text_interaction_focus.byte == 5,
			"optical themes preserve editor geometry and source-byte caret")
		alicorn.semantic_snapshot_destroy(&before)
		alicorn.semantic_snapshot_destroy(&after)
	}
}
