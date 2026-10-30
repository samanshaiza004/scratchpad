package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"
import bridge "./bridge"

@(test)
test_rejected_editor_window_request_does_not_repeat_until_request_changes :: proc(t: ^testing.T) {
	app: App
	defer editor_window_rejection_clear(&app)
	request := bridge.Visible_Window_Request{
		document_id="doc-1",
		application_rev=12,
		editor_revision=3,
		start_line=10,
		anchor_byte=0,
		max_lines=bridge.MAX_VISIBLE_LINES,
		max_bytes=bridge.MAX_VISIBLE_BYTES,
	}
	set := editor_window_rejection_set(&app, request)
	testing.expect(t, set && editor_window_request_is_rejected(&app, request),
		"a rejected window request should be suppressed when the same request is rebuilt")

	scrolled := request
	scrolled.start_line += 1
	testing.expect(t, !editor_window_request_is_rejected(&app, scrolled),
		"moving to a different visible range should permit a fresh request")
	new_revision := request
	new_revision.editor_revision += 1
	testing.expect(t, !editor_window_request_is_rejected(&app, new_revision),
		"a changed authoritative editor revision should permit a fresh request")
	other_document := request
	other_document.document_id = "doc-2"
	testing.expect(t, !editor_window_request_is_rejected(&app, other_document),
		"switching documents should permit a fresh request")
	ready_tuple := request
	ready_tuple.include_presentation = true
	ready_tuple.presentation_revision = 3
	ready_tuple.presentation_ready = true
	testing.expect(t, !editor_window_request_is_rejected(&app, ready_tuple),
		"a ready metadata publication should make the pending request identity eligible again")
}

@(test)
test_pending_presentation_response_deduplicates_only_its_readiness_tuple :: proc(t: ^testing.T) {
	request := bridge.Visible_Window_Request{
		document_id="doc-md", editor_revision=7, include_presentation=true,
		presentation_revision=6, presentation_ready=false,
	}
	document := bridge.State_Document{
		id="doc-md", language="markdown", editor_revision=7,
		presentation_revision=6, presentation_ready=false,
	}
	pending_window := bridge.Visible_Window{document_id="doc-md", editor_revision=7, presentation_revision=6}
	testing.expect(t, editor_metadata_result_should_suppress_retry(request, document, pending_window),
		"an unchanged pending presentation tuple should not request metadata on every wake")
	document.presentation_revision = 7
	document.presentation_ready = true
	testing.expect(t, !editor_metadata_result_should_suppress_retry(request, document, pending_window),
		"a pending result delivered after the matching readiness publication must not suppress its refresh")
	ready_request := request
	ready_request.presentation_revision = 7
	ready_request.presentation_ready = true
	ready_window := bridge.Visible_Window{document_id="doc-md", editor_revision=7, presentation_revision=7, presentation_ready=true}
	testing.expect(t, !editor_metadata_result_should_suppress_retry(ready_request, document, ready_window),
		"an exact ready metadata result should not be marked as pending")
}


@(test)
test_recoverable_ime_text_survives_document_switch_and_blocks_close :: proc(t: ^testing.T) {
	app: App
	app.editor_views = make([dynamic]Editor_View_State, 0, allocator=context.allocator)
	app.editor_edits = make([dynamic]Editor_Edit_Intent, 0, allocator=context.allocator)
	defer {
		delete(app.editor_edits)
		editor_views_destroy(&app.editor_views)
		if len(app.error_message) > 0 { delete(app.error_message, context.allocator) }
		if len(app.close_document_id) > 0 { delete(app.close_document_id, context.allocator) }
	}
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 320, 200})
	defer alicorn.destroy_runtime(&rt)
	index, ok := editor_view_ensure(&app.editor_views, "recoverable-doc", context.allocator)
	if !ok { testing.expect(t, false, "recovery view should be retained"); return }
	view := &app.editor_views[index]
	view.selection_anchor, view.caret_byte = 2, 4
	if !editor_preedit_update(view, "committed", 0, len("committed"), context.allocator) {
		testing.expect(t, false, "recovery fixture text should be retained")
		return
	}
	view.preedit_replace_start, view.preedit_replace_end = 2, 4
	view.preedit_recoverable = true
	editor_preedit_clear_for_document_switch(view, context.allocator)
	testing.expect(t, view.preedit_active && view.preedit_recoverable && string(view.preedit_text) == "committed",
		"switching away from a document must preserve its committed IME recovery text")
	request_close_document(&app, &rt, "recoverable-doc")
	testing.expect(t, view.preedit_active && view.preedit_recoverable && string(view.preedit_text) == "committed" &&
		app.close_document_id == "recoverable-doc" && strings.contains(app.error_message, "Copy or explicitly discard"),
		"closing a document with committed IME text must open an explicit copy-or-discard recovery prompt")
	close_after_save(&app, &rt)
	close_with_discard(&app, &rt)
	testing.expect(t, view.preedit_active && view.preedit_recoverable && string(view.preedit_text) == "committed",
		"save-and-close and discard-and-close backstops must preserve recovery until an explicit recovery choice")
	testing.expect(t, editor_discard_recoverable_preedit(&app, &rt, "recoverable-doc") && !view.preedit_active &&
		!view.preedit_recoverable && len(view.preedit_text) == 0 &&
		strings.contains(app.error_message, "explicitly discarded"),
		"the recovery prompt's explicit discard choice should clear only the held composition, not edit source bytes")
}


ALICORN_TEST_UI_FONT_DATA :: #load("../../.deps/alicorn/assets/fonts/AtkinsonHyperlegibleNext-Variable.ttf")
ALICORN_TEST_MONO_FONT_DATA :: #load("../../.deps/alicorn/assets/fonts/AtkinsonHyperlegibleMono-Variable.ttf")

@(test)
test_macos_content_titlebar_uses_retained_tab_and_drag_regions :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 900, 600})
	defer alicorn.destroy_runtime(&rt)
	if !alicorn.text_engine_load_font(&rt.text_engine, ALICORN_TEST_UI_FONT_DATA) {
		testing.expect(t, false, "titlebar tabs should use the bundled application font")
		return
	}
	app: App
	documents := [1]bridge.State_Document{{id="doc-one", path="/workspace/One.md"}}
	app.backend.state.documents = documents[:]
	app.backend.state.active = "doc-one"
	scratchpad_content_titlebar_metrics(rawptr(&app), &rt, host.Window_Chrome_Metrics{
		header={0, 0, 900, SCRATCHPAD_CONTENT_TITLEBAR_HEIGHT},
		content_start_x=80,
		display_scale=2,
	})

	ui, ready := alicorn.begin_frame(&rt)
	testing.expect(t, ready, "titlebar fixture should begin a normal application description")
	if !ready { return }
	alicorn.container_begin(&ui, .Root, style=alicorn.layout_style(.Column, grow=1))
	scratchpad_content_titlebar_build(&app, &ui, &rt, 900)
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)

	layout := scratchpad_content_titlebar_layout(rawptr(&app), &rt)
	header, header_found := alicorn.node_info(&rt, layout.header)
	testing.expect(t, header_found && header.bounds == alicorn.Rect{0, 0, 900, SCRATCHPAD_CONTENT_TITLEBAR_HEIGHT},
		"the measured titlebar header should match the retained top-row bounds")
	testing.expect(t, len(layout.regions) == 3 &&
		layout.regions[0].kind == .Interactive &&
		layout.regions[1].kind == .Window_Drag &&
		layout.regions[2].kind == .Window_Drag,
		"native-light reservation and trailing blank space should remain draggable around the ordinary tab strip")
	if len(layout.regions) == 3 {
		leading, leading_found := alicorn.node_info(&rt, layout.regions[1].node)
		tabs, tabs_found := alicorn.node_info(&rt, layout.regions[0].node)
		trailing, trailing_found := alicorn.node_info(&rt, layout.regions[2].node)
		testing.expect(t, leading_found && tabs_found && trailing_found &&
			leading.bounds == alicorn.Rect{0, 0, 80, SCRATCHPAD_CONTENT_TITLEBAR_HEIGHT} &&
			tabs.bounds.x == 80 && tabs.bounds.w == 180 &&
			trailing.bounds.x == 260 && trailing.bounds.w == 640,
			"the public chrome layout should publish exact resolved node geometry without fixed window-offset guesses")
	}
}

@(test)
test_workbench_errors_use_non_reflowing_notice_overlay :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 900, 600})
	defer alicorn.destroy_runtime(&rt)
	fonts_loaded := alicorn.text_engine_load_font(&rt.text_engine, ALICORN_TEST_UI_FONT_DATA) &&
		alicorn.text_engine_load_font_role(&rt.text_engine, .Monospace, ALICORN_TEST_MONO_FONT_DATA)
	testing.expect(t, fonts_loaded, "error-banner appearance fixture should load the bundled fonts")
	if !fonts_loaded { return }

	app: App
	app.error_message = "The selected workspace file could not be opened."
	choices := [?]Scratchpad_Theme_Choice{.Warm, .Cool_Light}
	for choice in choices {
		app.theme_choice = choice
		alicorn.invalidate_root(&rt, "verify themed operation notice")
		_ = build_app(rawptr(&app), &rt, 900, 600, 1)
		flow_error_node_found := false
		for node_id in rt.order {
			node, found := rt.nodes[node_id]
			if found && node.label == "workbench-error" { flow_error_node_found = true; break }
		}
		testing.expect(t, !flow_error_node_found, "operation errors should not be ordinary workbench layout children")
		testing.expect(t, rt.notice_count == 1, "operation errors should use Alicorn's persistent notice queue")
	}
}


SCRATCHPAD_WORKBENCH_EXPECTED_COLORS :: [18]alicorn.Color{
	alicorn.Color{0.16, 0.16, 0.14, 1},
	alicorn.Color{0.22, 0.22, 0.19, 1},
	alicorn.Color{0.28, 0.28, 0.24, 1},
	alicorn.Color{0.92, 0.89, 0.82, 1},
	alicorn.Color{0.87, 0.85, 0.78, 1},
	alicorn.Color{0.67, 0.65, 0.58, 1},
	alicorn.Color{0.56, 0.34, 0.18, 1},
	alicorn.Color{0.65, 0.41, 0.22, 1},
	alicorn.Color{0.47, 0.27, 0.15, 1},
	alicorn.Color{0.98, 0.95, 0.87, 1},
	alicorn.Color{0.72, 0.52, 0.27, 0.38},
	alicorn.Color{0.83, 0.63, 0.35, 1},
	alicorn.Color{0.47, 0.62, 0.47, 1},
	alicorn.Color{0.39, 0.38, 0.33, 1},
	alicorn.Color{0.55, 0.24, 0.20, 1},
	alicorn.Color{0.34, 0.48, 0.34, 1},
	alicorn.Color{0.19, 0.19, 0.17, 1},
	alicorn.Color{0.48, 0.46, 0.39, 1},
}

SCRATCHPAD_PAPER_EXPECTED_COLORS :: [18]alicorn.Color{
	alicorn.Color{0.92, 0.89, 0.82, 1},
	alicorn.Color{0.95, 0.93, 0.87, 1},
	alicorn.Color{0.87, 0.84, 0.76, 1},
	alicorn.Color{0.94, 0.92, 0.86, 1},
	alicorn.Color{0.17, 0.17, 0.15, 1},
	alicorn.Color{0.43, 0.42, 0.37, 1},
	alicorn.Color{0.51, 0.29, 0.14, 1},
	alicorn.Color{0.62, 0.36, 0.18, 1},
	alicorn.Color{0.41, 0.23, 0.13, 1},
	alicorn.Color{0.98, 0.95, 0.88, 1},
	alicorn.Color{0.76, 0.57, 0.30, 0.42},
	alicorn.Color{0.65, 0.40, 0.20, 1},
	alicorn.Color{0.28, 0.48, 0.34, 1},
	alicorn.Color{0.70, 0.67, 0.59, 1},
	alicorn.Color{0.56, 0.22, 0.18, 1},
	alicorn.Color{0.29, 0.46, 0.32, 1},
	alicorn.Color{0.86, 0.83, 0.76, 1},
	alicorn.Color{0.58, 0.55, 0.48, 1},
}
@(test)
test_workbench_and_editor_use_registered_warm_palettes :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 640, 400})
	defer alicorn.destroy_runtime(&rt)
	app: App
	expect_fonts := alicorn.text_engine_load_font(&rt.text_engine, ALICORN_TEST_UI_FONT_DATA)
	testing.expect(t, expect_fonts, "warm palette integration test should load the UI font")
	if !expect_fonts { return }
	testing.expect(t, scratchpad_styles_ensure(&app, &rt), "Scratchpad should register both warm palettes for its runtime")
	workbench_expected := SCRATCHPAD_WORKBENCH_EXPECTED_COLORS
	paper_expected := SCRATCHPAD_PAPER_EXPECTED_COLORS
	for role in alicorn.Style_Color_Role {
		if role == .Count { continue }
		index := int(role)
		testing.expect(t, alicorn.style_theme_color(&rt, app.workbench_theme, role) == workbench_expected[index],
			"workbench theme must preserve the exact pre-compiler role colors")
		testing.expect(t, alicorn.style_theme_color(&rt, app.editor_theme, role) == paper_expected[index],
			"paper theme must preserve the exact pre-compiler role colors")
	}

	ui, should_build := alicorn.begin_frame(&rt)
	testing.expect(t, should_build, "warm palette fixture should build its first frame")
	if !should_build { return }
	root := alicorn.container_begin(&ui, .Root, key="palette-root", style=alicorn.layout_style(grow=1), color=alicorn.style_theme_color(&rt, app.workbench_theme, .Window_Background))
	workbench_scope := alicorn.style_environment_push(&ui, alicorn.Style_Environment{theme=app.workbench_theme})
	shell_text := alicorn.text_ex(&ui, "Workbench", key="palette-shell-text", explicit_key=true)
	editor_scope := alicorn.style_environment_push(&ui, alicorn.Style_Environment{theme=app.editor_theme})
	paper := alicorn.surface_begin(&ui, alicorn.surface_extension_color_role(scratchpad_editor_paper_surface_role()), key=alicorn.key_string("palette-paper"), style=alicorn.layout_style(width=300, height=220), material=app.paper_surface_material, physical_height=-0.75)
	paper_text := alicorn.text_ex(&ui, "Paper text", key="palette-paper-text", explicit_key=true)
	alicorn.surface_end(&ui)
	alicorn.style_environment_pop(&ui, editor_scope)
	alicorn.style_environment_pop(&ui, workbench_scope)
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)

	workbench_ink := alicorn.style_theme_color(&rt, app.workbench_theme, .Text)
	paper_ink := alicorn.style_theme_color(&rt, app.editor_theme, .Text)
	paper_color := alicorn.style_theme_color(&rt, app.editor_theme, .Editor_Background)
	testing.expect(t, root != 0 && paper != 0, "palette fixture should retain the shell and paper surfaces")
	testing.expect(t, rt.nodes[shell_text].color == workbench_ink && rt.nodes[paper_text].color == paper_ink,
		"text should resolve to the active workbench or paper theme role")
	paper_fill: alicorn.Color
	paper_paint_ok := false
	if len(rt.nodes[paper].paint) > 0 {
		paper_fill, paper_paint_ok = alicorn.paint_surface_color(rt.nodes[paper].paint[0])
	}
	testing.expect(t, paper_paint_ok && paper_fill == paper_color && paper_color.r > paper_ink.r,
		"the editor paper surface should be light with dark readable text")
	paper_role_color, paper_role_found := alicorn.style_extension_color(&rt, app.editor_theme, scratchpad_editor_paper_surface_role())
	testing.expect(t, paper_role_found && paper_role_color == paper_color,
		"Scratchpad's app-namespaced paper role should resolve to the paper surface token")
	testing.expect(t, paper_role_found && paper_fill == paper_role_color,
		"the paper surface paint fill should equal its resolved app-namespaced role")

	paper_paint: alicorn.Surface_Paint
	if len(rt.nodes[paper].paint) > 0 {
		paper_paint, paper_paint_ok = rt.nodes[paper].paint[0].payload.(alicorn.Surface_Paint)
	}
	testing.expect(t, paper_paint_ok &&
		paper_paint.material == app.paper_surface_material &&
		paper_paint.material != alicorn.MATERIAL_FLAT &&
		paper_paint.physical_height == -0.75,
		"the paper surface paint should retain its non-flat material and optical height")
	resolved_paper_material, paper_material_ok := alicorn.style_material_resolve(&rt, paper_paint.material)
	testing.expect(t, paper_material_ok &&
		resolved_paper_material.kind == .Analytic_Relief &&
		resolved_paper_material.bevel_strength > 0 &&
		resolved_paper_material.inner_shadow_strength > 0,
		"the paper material should resolve to its registered analytic relief treatment")

	paper_description, paper_description_found := rt.semantic_surfaces[paper]
	paper_role_retained := false
	if paper_description_found {
		switch retained_role in paper_description.role {
		case alicorn.Style_Color_Role:
			paper_role_retained = false
		case alicorn.Style_Extension_Color_Role_ID:
			paper_role_retained = retained_role == scratchpad_editor_paper_surface_role()
		}
	}
	testing.expect(t, paper_role_retained,
		"the retained surface description should preserve the app paper role identity")

	inspection := alicorn.inspect(&rt)
	testing.expect(t, strings.contains(inspection, "semantic surface: role=app.scratchpad.editor.paper_surface") &&
		strings.contains(inspection, "analytic-relief) height=-0.75") &&
		strings.contains(inspection, "resolution=retained-cache dependencies=paint,material"),
		"the inspector should explain paper-role provenance, material, optical height, and invalidation ownership")
	delete(inspection, context.allocator)

	cached_workbench_theme := app.workbench_theme
	cached_editor_theme := app.editor_theme
	cached_paper_material := app.paper_surface_material
	testing.expect(t, scratchpad_styles_ensure(&app, &rt) &&
		app.workbench_theme == cached_workbench_theme &&
		app.editor_theme == cached_editor_theme &&
		app.paper_surface_material == cached_paper_material,
		"reusing a Runtime should retain the registered theme and paper-material identities")
	testing.expect(t, rt.nodes[shell_text].style_environment.theme == app.workbench_theme &&
		rt.nodes[paper_text].style_environment.theme == app.editor_theme,
		"theme scopes should stay local and must not leak across the editor boundary")
}


@(test)
test_workbench_accessibility_preferences_reach_recipe_and_material_consumers :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 640, 480})
	defer alicorn.destroy_runtime(&rt)
	app: App
	fonts_loaded := alicorn.text_engine_load_font(&rt.text_engine, ALICORN_TEST_UI_FONT_DATA)
	testing.expect(t, fonts_loaded, "accessibility dogfood fixture should load the UI font")
	if !fonts_loaded { return }
	if !scratchpad_styles_ensure(&app, &rt) { testing.expect(t, false, "accessibility dogfood fixture should register Scratchpad styles"); return }
	app.accessibility_appearance_override_enabled = true
	app.accessibility_appearance = alicorn.Accessibility_Appearance_Preferences{
		increased_contrast=true,
		reduce_motion=true,
		reduce_transparency=true,
		differentiate_without_color=true,
	}

	ui, should_build := alicorn.begin_frame(&rt)
	testing.expect(t, should_build, "accessibility dogfood fixture should build its first frame")
	if !should_build { return }
	alicorn.container_begin(&ui, .Root, key="appearance-root", style=alicorn.layout_style(grow=1), color=alicorn.style_theme_color(&rt, app.workbench_theme, .Window_Background))
	workbench_scope := alicorn.style_environment_push(&ui, scratchpad_workbench_style_environment(&app))
	workbench_text := alicorn.text_ex(&ui, "Workbench accessibility sample", key="appearance-workbench-text", explicit_key=true)
	_ = alicorn.button(
		&ui,
		"Selected state sample",
		key=alicorn.key_string("appearance-selected-button"),
		style=alicorn.layout_style(.Row, width=220, height=36),
		state=alicorn.Button_State{selected=true},
		variant=.Quiet,
	)
	surface := alicorn.surface_begin(
		&ui,
		alicorn.surface_core_color_role(.Subtle_Surface),
		key=alicorn.key_string("appearance-material-sample"),
		label="appearance-material-sample",
		style=alicorn.layout_style(.Column, width=240, height=64, padding=8),
		material=app.floating_surface_material,
		physical_height=0.5,
	)
	alicorn.text(&ui, "Surface alpha and relief")
	alicorn.surface_end(&ui)
	editor_scope := alicorn.style_environment_push(&ui, alicorn.Style_Environment{theme=app.editor_theme})
	editor_text := alicorn.text_ex(&ui, "Editor inherits appearance", key="appearance-editor-text", explicit_key=true)
	alicorn.style_environment_pop(&ui, editor_scope)
	alicorn.style_environment_pop(&ui, workbench_scope)
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)

	selected_button_node: alicorn.Node_ID
	for node_id in rt.order {
		if node, found := rt.nodes[node_id]; found && node.key == "appearance-selected-button" {
			selected_button_node = node_id
			break
		}
	}
	preferences := app.accessibility_appearance
	appearance_nodes := [4]alicorn.Node_ID{workbench_text, selected_button_node, surface, editor_text}
	for node_id in appearance_nodes {
		node, found := rt.nodes[node_id]
		testing.expect(t, found &&
			node.style_environment.accessibility.increased_contrast == preferences.increased_contrast &&
			node.style_environment.accessibility.reduce_motion == preferences.reduce_motion &&
			node.style_environment.accessibility.reduce_transparency == preferences.reduce_transparency &&
			node.style_environment.accessibility.differentiate_without_color == preferences.differentiate_without_color,
			"all four app appearance preferences should reach retained workbench and nested editor consumers")
	}
	button_underline_found := false
	if button_node, found := rt.nodes[selected_button_node]; found {
		button_style := alicorn.style_button_resolve_retained(&rt, button_node, alicorn.Button_Visual_State{selected=true})
		button_underline_found = button_style.selected_indicator == .Underline
	}
	testing.expect(t, button_underline_found,
		"differentiate-without-color should expose the generic selected-button underline in Scratchpad's style scope")

	surface_paint: alicorn.Surface_Paint
	surface_paint_found := false
	if len(rt.nodes[surface].paint) > 0 {
		surface_paint, surface_paint_found = rt.nodes[surface].paint[0].payload.(alicorn.Surface_Paint)
	}
	resolved_material, material_found := alicorn.style_material_resolve(&rt, surface_paint.material)
	testing.expect(t, surface_paint_found && surface_paint.fill.a == 1 &&
		surface_paint.material != app.floating_surface_material && material_found &&
		resolved_material.outer_shadow_strength == 0 && resolved_material.bevel_strength >= 0.75,
		"reduced transparency and increased contrast should adapt the real Scratchpad relief sample through Alicorn")
}

@(test)
test_workbench_uses_system_accessibility_appearance_by_default :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 640, 480})
	defer alicorn.destroy_runtime(&rt)
	app: App
	fonts_loaded := alicorn.text_engine_load_font(&rt.text_engine, ALICORN_TEST_UI_FONT_DATA)
	testing.expect(t, fonts_loaded, "system appearance fixture should load the UI font")
	if !fonts_loaded { return }
	if !scratchpad_styles_ensure(&app, &rt) { testing.expect(t, false, "system appearance fixture should register Scratchpad styles"); return }
	host_preferences := alicorn.Accessibility_Appearance_Preferences{
		increased_contrast=true,
		reduce_motion=true,
		differentiate_without_color=true,
	}
	testing.expect(t, alicorn.style_root_accessibility_set(&rt, host_preferences),
		"the fixture should install a simulated native host appearance")

	environment := scratchpad_workbench_style_environment(&app)
	testing.expect(t, !app.accessibility_appearance_override_enabled && !environment.accessibility_set,
		"the workbench should inherit Alicorn's host accessibility appearance unless an explicit app override is enabled")
	ui, should_build := alicorn.begin_frame(&rt)
	testing.expect(t, should_build, "system appearance fixture should build its first frame")
	if !should_build { return }
	workbench_scope := alicorn.style_environment_push(&ui, environment)
	text_node := alicorn.text_ex(&ui, "Host appearance is inherited", key="system-appearance-text", explicit_key=true)
	alicorn.style_environment_pop(&ui, workbench_scope)
	alicorn.end_frame(&ui)
	if node, found := rt.nodes[text_node]; found {
		testing.expect(t, node.style_environment.accessibility == host_preferences,
			"system preferences from Alicorn should flow through Scratchpad's theme-only workbench scope")
	} else {
		testing.expect(t, false, "system appearance fixture should retain its text node")
	}
}


@(test)
test_workbench_cleanup_keeps_actions_in_menus_and_settings :: proc(t: ^testing.T) {
	app: App
	app.backend.started = true
	app.editor_row_targets = make([dynamic]Editor_Row_Target, 0, allocator=context.temp_allocator)
	defer delete(app.editor_row_targets)
	init_menus(&app)

	settings_item_found := false
	new_file_found := false
	new_folder_found := false
	refresh_found := false
	for item in app.workspace_items {
		if item.label == "Settings…" { settings_item_found = true }
		if item.label == "New File" { new_file_found = true }
		if item.label == "New Folder" { new_folder_found = true }
		if item.label == "Refresh Workspace" { refresh_found = true }
	}
	testing.expect(t, settings_item_found && new_file_found && new_folder_found && refresh_found,
		"workspace actions removed from the sidebar should remain available from the Workspace menu")

	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 900, 600})
	defer alicorn.destroy_runtime(&rt)
	fonts_loaded := alicorn.text_engine_load_font(&rt.text_engine, ALICORN_TEST_UI_FONT_DATA) &&
		alicorn.text_engine_load_font_role(&rt.text_engine, .Monospace, ALICORN_TEST_MONO_FONT_DATA)
	testing.expect(t, fonts_loaded, "workbench UI cleanup test should load the bundled UI fonts")
	if !fonts_loaded { return }

	_ = build_app(rawptr(&app), &rt, 900, 600, 1)
	start_file_found := false
	start_folder_found := false
	start_commands_found := false
	sidebar_recent_found := false
	for node_id in rt.order {
		node, found := rt.nodes[node_id]
		if !found { continue }
		if node.key == "start-open-file" { start_file_found = true }
		if node.key == "start-open-folder" { start_folder_found = true }
		if node.key == "start-command-palette" { start_commands_found = true }
		if node.key == "workspace-open-recent" { sidebar_recent_found = true }
		if node.key == "backend-stop" || node.key == "backend-start" || node.key == "workbench-toolbar" ||
		   node.key == "sidebar-refresh" || node.key == "sidebar-open-folder" ||
		   node.key == "workspace-mutation-create" || node.key == "workspace-show-ignored" {
			testing.expect(t, false, fmt.tprintf("obsolete persistent control remains in the empty shell: %s", node.key))
		}
	}
	testing.expect(t, start_file_found && start_folder_found && start_commands_found,
		"the fresh empty screen should expose Open File, Open Folder, and the command palette")
	testing.expect(t, !sidebar_recent_found,
		"recent workspaces should stay in global navigation instead of taking space from the workspace path")

	app.backend.state.has_workspace = true
	app.backend.state.workspace_root = "C:/scratchpad-test"
	alicorn.invalidate_root(&rt, "show a workspace with no active document")
	_ = build_app(rawptr(&app), &rt, 900, 600, 1)
	empty_workspace_quick_open_found := false
	for node_id in rt.order {
		node, found := rt.nodes[node_id]
		if found && node.key == "empty-editor-quick-open" {
			empty_workspace_quick_open_found = true
			testing.expect(t, node.button_variant == .Primary,
				"Quick Open should be the primary action when a workspace has no open document")
		}
	}
	testing.expect(t, empty_workspace_quick_open_found,
		"a workspace without open documents should show Quick Open in the editor area")

	app.settings_surface_open = true
	for category in Settings_Category {
		app.settings_category = category
		alicorn.invalidate_root(&rt, "show Settings category in workbench cleanup test")
		_ = build_app(rawptr(&app), &rt, 900, 600, 1)
		panel := settings_test_find_node(&rt, "", "scratchpad-settings")
		scroll := settings_test_find_node(&rt, "scratchpad-settings-scroll", "")
		done := settings_test_find_node(&rt, "settings-done", "")
		testing.expect(t, panel != 0 && scroll != 0 && done != 0,
			"each Settings page should retain its panel, scroll body and fixed Done action")
		switch category {
		case .Appearance:
			testing.expect(t, settings_test_find_node(&rt, "settings-workbench-appearance", "") != 0, "Appearance should expose the persisted workbench appearance selector")
		case .Editor:
			testing.expect(t, settings_test_find_node(&rt, "settings-editor-font-family", "") != 0, "Editor should expose the font picker")
		case .Workspace:
			testing.expect(t, settings_test_find_node(&rt, "settings-show-ignored-files", "") != 0 && settings_test_find_node(&rt, "workspace-show-ignored", "") == 0, "ignored-file visibility should be available in Settings")
		case .Accessibility:
			for key in ([4]string{"settings-accessibility-increased-contrast", "settings-accessibility-reduce-motion", "settings-accessibility-reduce-transparency", "settings-accessibility-differentiate-without-color"}) {
				testing.expect(t, settings_test_find_node(&rt, key, "") != 0, "Accessibility should expose the four appearance controls")
			}
		}
	}
}
tree_test_wake :: proc(data: rawptr) {}

backend_integration_test_mutex: sync.Mutex


@(test)
test_workspace_directory_move_preserves_editor_views_tree_expansion_and_focus :: proc(t: ^testing.T) {
	sync.mutex_lock(&backend_integration_test_mutex)
	defer sync.mutex_unlock(&backend_integration_test_mutex)
	workspace, workspace_error := os.make_directory_temp("", "scratchpad-alicorn-move-*", context.temp_allocator)
	if workspace_error != nil { testing.expect(t, false, "could not create a temporary workspace for mutation migration"); return }
	defer _ = os.remove_all(workspace)
	fixture_directories := [?]string{"src", "src/nested", "archive"}
	for directory in fixture_directories {
		if err := os.make_directory(fmt.tprintf("%s/%s", workspace, directory)); err != nil {
			testing.expect(t, false, fmt.tprintf("could not create mutation fixture directory %s", directory))
			return
		}
	}
	first_path := fmt.tprintf("%s/src/nested/first.txt", workspace)
	second_path := fmt.tprintf("%s/src/nested/second.txt", workspace)
	stable_path := fmt.tprintf("%s/stable.txt", workspace)
	collision_path := fmt.tprintf("%s/archive/stable.txt", workspace)
	move_file_path := fmt.tprintf("%s/move-me.txt", workspace)
	if err := os.write_entire_file_from_string(first_path, "first\n"); err != nil { testing.expect(t, false, "could not create first open fixture"); return }
	if err := os.write_entire_file_from_string(second_path, "second\n"); err != nil { testing.expect(t, false, "could not create second open fixture"); return }
	if err := os.write_entire_file_from_string(stable_path, "stable\n"); err != nil { testing.expect(t, false, "could not create unaffected sibling fixture"); return }
	if err := os.write_entire_file_from_string(collision_path, "keep destination\n"); err != nil { testing.expect(t, false, "could not create move collision fixture"); return }
	if err := os.write_entire_file_from_string(move_file_path, "move me\n"); err != nil { testing.expect(t, false, "could not create file drag fixture"); return }
	backend_library, found_library := os.lookup_env("SCRATCHPAD_BACKEND_LIBRARY", context.temp_allocator)
	if !found_library { testing.expect(t, false, "workspace mutation integration test requires the staged shared backend"); return }
	defer delete(backend_library, context.temp_allocator)
	app: App
	app.tree_directories = make([dynamic]Tree_Directory, 0, allocator=context.allocator)
	app.editor_views = make([dynamic]Editor_View_State, 0, allocator=context.allocator)
	app.editor_edits = make([dynamic]Editor_Edit_Intent, 0, allocator=context.allocator)
	app.deferred_actions = make([dynamic]Deferred_Action, 0, allocator=context.allocator)
	defer {
		for index := len(app.editor_edits)-1; index >= 0; index -= 1 { editor_remove_edit(&app, index) }
		delete(app.editor_edits)
		deferred_actions_clear(&app)
		delete(app.deferred_actions)
	}
	loaded, load_message := bridge.backend_load(&app.backend, backend_library)
	testing.expect(t, loaded, fmt.tprintf("shared backend should load for workspace mutation: %s", load_message))
	if !loaded { return }
	started, start_message := bridge.backend_start(&app.backend, workspace, tree_test_wake, nil, context.allocator)
	testing.expect(t, started, fmt.tprintf("shared backend should start for workspace mutation: %s", start_message))
	if !started { return }
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 800, 600})
	defer tree_test_cleanup(t, &app, &rt)
	defer editor_views_destroy(&app.editor_views)
	tree_sync_workspace(&app, &rt)
	fixture_files := [?]string{first_path, second_path}
	for path in fixture_files {
		response := bridge.backend_command(&app.backend, "open_path", path=path)
		if !response.ok { testing.expect(t, false, fmt.tprintf("open mutation fixture failed: %s", response.message)) }
		bridge.backend_command_result_destroy(&response, context.allocator)
	}
	_ = tree_load_directory(&app, "src", true)
	nested_source_path := tree_normalize_separators("src/nested", tree_preferred_separator(&app))
	_ = tree_load_directory(&app, nested_source_path, true)
	alicorn.invalidate_root(&rt, "describe workspace before path mutation")
	if !test_render_workspace_tree(t, &app, &rt) { testing.expect(t, false, "workspace tree should build before path mutation"); return }
	stable_id, stable_found := test_workspace_tree_row(&rt, "stable.txt")
	testing.expect(t, stable_found, "unaffected root sibling should be present before the move")
	tree_scroll_owner := app.tree_scroll_owner
	rows := make([dynamic]Tree_Row, 0, allocator=context.temp_allocator)
	tree_flatten_directory(&app, "", 0, &rows)
	for row, index in rows {
		if tree_test_paths_equal(row.path, "src/nested") && row.is_dir {
			tree_set_focused_row(&app, &rt, row, index)
			break
		}
	}
	delete(rows)
	_ = application_key(rawptr(&app), &rt, .Right)
	testing.expect(t, tree_test_paths_equal(app.tree_focused_path, "src/nested/first.txt"), "Right on an expanded folder should focus its first child")
	_ = application_key(rawptr(&app), &rt, .Left)
	testing.expect(t, tree_test_paths_equal(app.tree_focused_path, "src/nested"), "Left on a child should focus its parent folder")
	_ = application_key(rawptr(&app), &rt, .Left)
	navigation_nested_index := tree_directory_index(&app, nested_source_path)
	testing.expect(t, navigation_nested_index >= 0 && !app.tree_directories[navigation_nested_index].expanded, "Left on an expanded folder should collapse it")
	_ = application_key(rawptr(&app), &rt, .Right)
	navigation_nested_index = tree_directory_index(&app, nested_source_path)
	testing.expect(t, navigation_nested_index >= 0 && app.tree_directories[navigation_nested_index].expanded, "Right on a collapsed folder should expand it")
	rows = make([dynamic]Tree_Row, 0, allocator=context.temp_allocator)
	tree_flatten_directory(&app, "", 0, &rows)
	for row, index in rows {
		if tree_test_paths_equal(row.path, "src/nested/first.txt") {
			tree_set_focused_row(&app, &rt, row, index)
			break
		}
	}
	delete(rows)
	_ = application_key(rawptr(&app), &rt, .Workspace_Rename)
	testing.expect(t, app.workspace_mutation_kind == .Rename && app.workspace_mutation_name == "first.txt",
		"F2 on the focused workspace item should open Rename with its current basename")
	workspace_mutation_cancel(&app, &rt)
	workspace_mutation_focus_after_frame(&app, &rt)
	if !test_render_workspace_tree(t, &app, &rt) { testing.expect(t, false, "workspace tree should build before context-menu invocation"); return }
	context_row, context_row_found := test_workspace_tree_row(&rt, "src/nested/first.txt")
	if !context_row_found { testing.expect(t, false, "context-menu target row should be realized"); return }
	context_bounds := rt.nodes[context_row].bounds
	context_x, context_y := context_bounds.x+context_bounds.w/2, context_bounds.y+context_bounds.h/2
	context_event := alicorn.Pointer_Event{kind=.Down, x=context_x, y=context_y, button=alicorn.POINTER_BUTTON_SECONDARY}
	context_target := alicorn.process_pointer(&rt, context_event)
	context_key, context_key_found := alicorn.node_identity_key(&rt, context_target)
	testing.expect(t, context_target == context_row && context_key_found,
		"Alicorn pointer hit testing should resolve the context-menu row and its semantic key")
	resolved_context, resolved_context_found := workspace_context_menu_target_for_key(&app, context_key)
	testing.expect(t, resolved_context_found && tree_test_paths_equal(resolved_context.path, "src/nested/first.txt"),
		"the pointer target key should resolve to the matching workspace path")
	context_node_info, context_node_found := alicorn.node_info(&rt, context_target)
	testing.expect(t, context_node_found && context_node_info.active,
		"the context-menu pointer target should remain active after hit testing")
	context_event.target_key = context_key
	application_pointer(
		rawptr(&app),
		&rt,
		context_event,
		context_target,
	)
	testing.expect(t, alicorn.context_menu_is_open(&rt) && app.workspace_context_target == .Item &&
		tree_test_paths_equal(app.workspace_context_path, "src/nested/first.txt"),
		"secondary-click should open the context menu for the row under the pointer")
	if !test_render_workspace_tree(t, &app, &rt) { testing.expect(t, false, "context menu should describe after secondary-click"); return }
	rename_item := test_workspace_context_menu_item(&rt, "Rename")
	if rename_item == 0 { testing.expect(t, false, "workspace context menu should contain its registered Rename action"); return }
	testing.expect(t, !rt.nodes[rename_item].disabled, "Rename should be enabled for a workspace tree item")
	testing.expect(t, alicorn.context_menu_handle_key(&rt, .Activate), "Enter should activate the focused workspace context-menu action")
	if !test_render_workspace_tree(t, &app, &rt) { testing.expect(t, false, "Rename action should dispatch through the existing mutation flow"); return }
	testing.expect(t, app.workspace_mutation_kind == .Rename &&
		tree_test_paths_equal(app.workspace_mutation_source, "src/nested/first.txt") &&
		app.workspace_mutation_name == "first.txt",
		"context-menu Rename should open the existing dialog for the exact right-clicked item")
	workspace_mutation_cancel(&app, &rt)
	workspace_mutation_focus_after_frame(&app, &rt)
	if !test_render_workspace_tree(t, &app, &rt) { return }
	_ = application_key(rawptr(&app), &rt, .Context_Menu)
	testing.expect(t, alicorn.context_menu_is_open(&rt), "Shift+F10 should open the context menu for the focused tree item")
	testing.expect(t, tree_test_paths_equal(app.workspace_context_path, "src/nested/first.txt"),
		"keyboard invocation should preserve the focused semantic tree target")
	alicorn.context_menu_close(&rt)
	if !test_render_workspace_tree(t, &app, &rt) { return }
	for document in app.backend.state.documents {
		index, ok := editor_view_ensure(&app.editor_views, document.id)
		if !ok { testing.expect(t, false, "could not allocate a per-document editor view"); return }
		view := &app.editor_views[index]
		if strings.contains(document.path, "first.txt") {
			view.caret_byte, view.selection_anchor, view.scroll_y = 2, 1, 37
		} else {
			view.caret_byte, view.selection_anchor, view.scroll_y = 5, 3, 91
		}
	}
	rows = make([dynamic]Tree_Row, 0, allocator=context.temp_allocator)
	tree_flatten_directory(&app, "", 0, &rows)
	for row, index in rows {
		if tree_test_paths_equal(row.path, "src/nested/first.txt") {
			tree_set_focused_row(&app, &rt, row, index)
			break
		}
	}
	delete(rows)
	old_ids := make([dynamic]string, 0, allocator=context.temp_allocator)
	for document in app.backend.state.documents {
		id, clone_error := strings.clone(document.id, context.temp_allocator)
		if clone_error == nil { append(&old_ids, id) }
	}
	application_drag(rawptr(&app), &rt, alicorn.Drag_Event{
		kind=.Started,
		drag_type=SCRATCHPAD_DRAG_WORKSPACE,
		source=tree_semantic_id("src", true),
	})
	testing.expect(t, app.workspace_drag_kind == .Workspace && app.workspace_drag_source_path == "src",
		fmt.tprintf("drag should capture the src directory (kind=%v path=%s)", app.workspace_drag_kind, app.workspace_drag_source_path))
	drag_target_path, drag_target_found := workspace_drag_target_path(&app, tree_semantic_id("archive", true))
	defer delete(drag_target_path, context.allocator)
	drag_destination, drag_should_move := workspace_drag_move_destination(app.workspace_drag_source_path, drag_target_path, app.workspace_drag_source_is_dir, tree_preferred_separator(&app))
	expected_drag_destination := tree_normalize_separators("archive/src", tree_preferred_separator(&app))
	testing.expect(t, drag_target_found && drag_should_move && drag_destination == expected_drag_destination,
		fmt.tprintf("drag should resolve archive/src destination (target_found=%t target=%s move=%t destination=%s expected=%s sep=%c)", drag_target_found, drag_target_path, drag_should_move, drag_destination, expected_drag_destination, tree_preferred_separator(&app)))
	application_drag(rawptr(&app), &rt, alicorn.Drag_Event{
		kind=.Dropped,
		drag_type=SCRATCHPAD_DRAG_WORKSPACE,
		source=tree_semantic_id("src", true),
		target=tree_semantic_id("archive", true),
		position=.On,
	})
	move_state_changed, move_state_ok, move_state_message := bridge.backend_read_latest(&app.backend, context.temp_allocator)
	testing.expect(t, app.workspace_drag_kind == .None, "a completed tree drop should clear the retained application payload")
	testing.expect(t, app.error_message == "", fmt.tprintf("moving src into archive should succeed without a workspace error (got %s)", app.error_message))
	testing.expect(t, app.workspace_mutation_error == "", fmt.tprintf("workspace move should not report a mutation error (got %s)", app.workspace_mutation_error))
	testing.expect(t, len(app.editor_edits) == 0 && !app.workspace_mutation_queued,
		fmt.tprintf("workspace drop should execute immediately without pending editor edits (edits=%d queued=%t backend_started=%t)", len(app.editor_edits), app.workspace_mutation_queued, app.backend.started))
	moved_path_summary := ""
	for document in app.backend.state.documents { moved_path_summary = fmt.tprintf("%s | %s", moved_path_summary, document.path) }
	expected_moved_subpath := tree_normalize_separators("archive/src/nested", tree_preferred_separator(&app))
	testing.expect(t, strings.contains(moved_path_summary, expected_moved_subpath),
		fmt.tprintf("workspace drop should publish moved document paths (changed=%t read_ok=%t read_error=%s workspace=%s paths=%s)", move_state_changed, move_state_ok, move_state_message, app.backend.state.workspace_root, moved_path_summary))
	for id in old_ids {
		testing.expect(t, editor_view_find(app.editor_views[:], id) < 0, "old backend document identity should be replaced after a successful directory move")
	}
	for document in app.backend.state.documents {
		view_index := editor_view_find(app.editor_views[:], document.id)
		testing.expect(t, view_index >= 0, "each open descendant must retain its Alicorn view under the backend-assigned new document ID")
		if view_index < 0 { continue }
		view := app.editor_views[view_index]
		if strings.contains(document.path, "first.txt") {
			testing.expect(t, view.caret_byte == 2 && view.selection_anchor == 1 && view.scroll_y == 37, fmt.tprintf("the first document's independent caret, selection, and scroll state should migrate (caret=%d anchor=%d y=%v)", view.caret_byte, view.selection_anchor, view.scroll_y))
		} else if strings.contains(document.path, "second.txt") {
			testing.expect(t, view.caret_byte == 5 && view.selection_anchor == 3 && view.scroll_y == 91, "the second document's independent caret, selection, and scroll state should migrate")
		} else {
			testing.expect(t, false, fmt.tprintf("unexpected moved document path %s", document.path))
		}
	}
	testing.expect(t, tree_test_paths_equal(app.tree_focused_path, "archive/src/nested/first.txt"), fmt.tprintf("tree focus should follow a moved descendant by component-aware path remapping (got %s)", app.tree_focused_path))
	application_drag(rawptr(&app), &rt, alicorn.Drag_Event{
		kind=.Started,
		drag_type=SCRATCHPAD_DRAG_WORKSPACE,
		source=tree_semantic_id("stable.txt", false),
	})
	application_drag(rawptr(&app), &rt, alicorn.Drag_Event{
		kind=.Dropped,
		drag_type=SCRATCHPAD_DRAG_WORKSPACE,
		source=tree_semantic_id("stable.txt", false),
		target=tree_semantic_id("archive", true),
		position=.On,
	})
	testing.expect(t, strings.contains(app.error_message, "already exists"),
		fmt.tprintf("a rejected file drop should explain the destination collision in the workbench banner (got %s)", app.error_message))
	collision_entry := tree_normalize_separators("archive/stable.txt", tree_preferred_separator(&app))
	testing.expect(t, tree_directory_has_entry(&app, "", "stable.txt") && tree_directory_has_entry(&app, "archive", collision_entry),
		"a file-drop collision should preserve both source and destination entries")
	application_drag(rawptr(&app), &rt, alicorn.Drag_Event{
		kind=.Started,
		drag_type=SCRATCHPAD_DRAG_WORKSPACE,
		source=tree_semantic_id("move-me.txt", false),
	})
	application_drag(rawptr(&app), &rt, alicorn.Drag_Event{
		kind=.Dropped,
		drag_type=SCRATCHPAD_DRAG_WORKSPACE,
		source=tree_semantic_id("move-me.txt", false),
		target=tree_semantic_id("archive", true),
		position=.On,
	})
	moved_file_entry := tree_normalize_separators("archive/move-me.txt", tree_preferred_separator(&app))
	testing.expect(t, tree_directory_has_entry(&app, "archive", moved_file_entry) && !tree_directory_has_entry(&app, "", "move-me.txt"),
		"dropping a file onto a directory should move it under that directory")
	archive_path := tree_normalize_separators("archive/src", tree_preferred_separator(&app))
	nested_path := tree_normalize_separators("archive/src/nested", tree_preferred_separator(&app))
	archive_index := tree_directory_index(&app, archive_path)
	nested_index := tree_directory_index(&app, nested_path)
	testing.expect(t, archive_index >= 0 && app.tree_directories[archive_index].expanded, "the moved directory's expanded state should be preserved")
	testing.expect(t, nested_index >= 0 && app.tree_directories[nested_index].expanded, "the moved nested directory's expanded state should be preserved")
	testing.expect(t, app.tree_scroll_owner == tree_scroll_owner, "path mutation should preserve the durable workspace-tree scroll owner")
	alicorn.invalidate_root(&rt, "render migrated workspace tree")
	if test_render_workspace_tree(t, &app, &rt) {
		new_stable_id, still_found := test_workspace_tree_row(&rt, "stable.txt")
		testing.expect(t, stable_found && still_found && new_stable_id == stable_id, "unaffected sibling retained identity should survive path mutation")
		_, moved_file_visible := test_workspace_tree_row(&rt, "archive/src/nested/first.txt")
		testing.expect(t, moved_file_visible, "moved descendant should remain visible after expansion and focus restoration")
	}
	workspace_mutation_execute(&app, &rt, .Create_Folder, "", "notes", "", false, false, app.backend.state.workspace_root)
	testing.expect(t, tree_directory_has_entry(&app, "", "notes"), "new folder should appear after refreshing its parent listing")
	notes_path := tree_normalize_separators("notes", tree_preferred_separator(&app))
	workspace_mutation_execute(&app, &rt, .Create_File, notes_path, "new.txt", "", false, false, app.backend.state.workspace_root)
	created_document: ^bridge.State_Document
	for &document in app.backend.state.documents {
		if strings.contains(document.path, "notes") && strings.contains(document.path, "new.txt") { created_document = &document; break }
	}
	testing.expect(t, created_document != nil, "new file should use the normal create-and-open document flow")
	if created_document != nil {
		view_index, view_ok := editor_view_ensure(&app.editor_views, created_document.id)
		testing.expect(t, view_ok, "created document should get frontend-local view state")
		if view_ok {
			app.editor_views[view_index].caret_byte = 3
			app.editor_views[view_index].selection_anchor = 1
			app.editor_views[view_index].scroll_y = 23
		}
		old_created_id, id_clone_error := strings.clone(created_document.id, context.temp_allocator)
		new_file_path := tree_join_relative_path(notes_path, "new.txt")
		workspace_mutation_execute(&app, &rt, .Rename, new_file_path, "renamed.txt", "", false, false, app.backend.state.workspace_root)
		renamed_document: ^bridge.State_Document
		for &document in app.backend.state.documents {
			if strings.contains(document.path, "notes") && strings.contains(document.path, "renamed.txt") { renamed_document = &document; break }
		}
		testing.expect(t, renamed_document != nil, "rename should publish the new backend-owned document identity")
		if renamed_document != nil {
			renamed_view_index := editor_view_find(app.editor_views[:], renamed_document.id)
			testing.expect(t, renamed_view_index >= 0, "rename should migrate the created file's Alicorn view before pruning")
			if renamed_view_index >= 0 {
				renamed_view := app.editor_views[renamed_view_index]
				testing.expect(t, renamed_view.caret_byte == 3 && renamed_view.selection_anchor == 1 && renamed_view.scroll_y == 23, "rename should preserve the created file's local caret, selection, and scroll state")
			}
		}
		if id_clone_error == nil { delete(old_created_id, context.temp_allocator) }
	}
	workspace_mutation_begin(&app, &rt, .Create_File, notes_path, false)
	workspace_mutation_set_name(&app, "renamed.txt")
	workspace_mutation_submit(&app, &rt, false)
	testing.expect(t, app.workspace_mutation_kind == .Create_File && app.workspace_mutation_error != "", "a destination collision should keep the operation UI open with a useful error")
	workspace_mutation_cancel(&app, &rt)
	workspace_mutation_begin(&app, &rt, .Create_File, notes_path, false)
	workspace_mutation_set_name(&app, "renamed.txt")
	append(&app.editor_edits, Editor_Edit_Intent{})
	workspace_mutation_submit(&app, &rt, false)
	testing.expect(t, app.workspace_mutation_queued && app.workspace_mutation_kind == .Create_File && len(app.deferred_actions) == 1,
		"a workspace mutation should remain visible and cancellable while it waits behind pending editor edits")
	editor_remove_edit(&app, 0)
	deferred_actions_run(&app, &rt)
	testing.expect(t, !app.workspace_mutation_queued && app.workspace_mutation_kind == .Create_File && app.workspace_mutation_error != "",
		"a queued filesystem failure should return to its still-open form with a useful error")
	workspace_mutation_cancel(&app, &rt)
	trash_document: ^bridge.State_Document
	for &document in app.backend.state.documents {
		if strings.contains(document.path, "renamed.txt") { trash_document = &document; break }
	}
	if trash_document != nil {
		dirty_edit := bridge.backend_command(
			&app.backend,
			"replace_document",
			document_id=trash_document.id,
			editor_revision=trash_document.editor_revision,
			start_byte=0,
			end_byte=0,
			replacement=[]int{'x'},
		)
		testing.expect(t, dirty_edit.ok, "a temporary open document should become dirty for the queued-trash decision test")
		bridge.backend_command_result_destroy(&dirty_edit, context.allocator)
		trash_relative := tree_join_relative_path(notes_path, "renamed.txt")
		append(&app.editor_edits, Editor_Edit_Intent{})
		workspace_mutation_begin(&app, &rt, .Trash, trash_relative, false)
		workspace_mutation_submit(&app, &rt, false)
		editor_remove_edit(&app, 0)
		deferred_actions_run(&app, &rt)
		testing.expect(t, app.workspace_mutation_kind == .Trash && app.workspace_mutation_dirty && !app.workspace_mutation_queued &&
			workspace_mutation_dirty_document_count(&app) == 1,
			"a deferred dirty-trash rejection should restore the correct path and offer the explicit save/discard/cancel decision")
		workspace_mutation_cancel(&app, &rt)
	} else {
		testing.expect(t, false, "renamed fixture should remain open for the dirty-trash decision test")
	}
	for &id in old_ids { delete(id, context.temp_allocator) }
	delete(old_ids)
}

scratchpad_test_recipe_button :: proc(rt: ^alicorn.Runtime, label: string) -> (variant: alicorn.Button_Variant, selected: bool, found: bool) {
	for node_id in rt.order {
		node, exists := rt.nodes[node_id]
		if exists && node.active && (node.kind == .Button || node.kind == .Tab) && node.label == label {
			return node.button_variant, node.selected, true
		}
	}
	// Composite TabBar labels live in retained Text children, so resolve the
	// owning Button when the visible label is not duplicated on its owner node.
	for text_id in rt.order {
		text_node, exists := rt.nodes[text_id]
		if !exists || !text_node.active || text_node.kind != .Text || text_node.text != label { continue }
		parent_id := text_node.parent
		for parent_id != 0 {
			parent, parent_exists := rt.nodes[parent_id]
			if !parent_exists { break }
			if parent.active && (parent.kind == .Button || parent.kind == .Tab) {
				return parent.button_variant, parent.selected, true
			}
			parent_id = parent.parent
		}
	}
	return .Default, false, false
}

scratchpad_test_tab_button_for_label :: proc(rt: ^alicorn.Runtime, label: string, semantic_id: alicorn.Semantic_ID) -> (variant: alicorn.Button_Variant, selected: bool, found: bool) {
	for node_id in rt.order {
		label_node, exists := rt.nodes[node_id]
		if !exists || !label_node.active || label_node.kind != .Text || label_node.text != label { continue }
		parent_id := label_node.parent
		for parent_id != 0 {
			parent, parent_exists := rt.nodes[parent_id]
			if !parent_exists { break }
			if parent.kind == .Button && parent.button_variant == .Tab {
				return parent.button_variant, parent.selected, parent.semantic_id == semantic_id
			}
			parent_id = parent.parent
		}
	}
	return .Default, false, false
}

scratchpad_test_status_contents_fit :: proc(rt: ^alicorn.Runtime, status_id: alicorn.Node_ID) -> (bool, string) {
	status, ok := alicorn.node_info(rt, status_id)
	if !ok { return false, "missing status node" }
	right := status.bounds.x+status.bounds.w
	for id in rt.order {
		node, found := rt.nodes[id]
		if !found || !node.active || id == status_id || !alicorn.node_is_presentation_active(rt, id) { continue }
		ancestor := node.parent
		inside := false
		for ancestor != 0 {
			if ancestor == status_id { inside = true; break }
			parent, parent_found := rt.nodes[ancestor]
			if !parent_found { break }
			ancestor = parent.parent
		}
		if !inside { continue }
		bounds := node.bounds
		if bounds.x < status.bounds.x-1 || bounds.x+bounds.w > right+1 {
			parent, parent_found := rt.nodes[node.parent]
			return false, fmt.tprintf("%s at %v parent=%s %v exceeds %v", node.label, bounds, parent.label if parent_found else "?", parent.bounds if parent_found else alicorn.Rect{}, status.bounds)
		}
	}
	return true, ""
}

scratchpad_test_sidebar_titlebar_frame :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil { return }
	ui, should_build := alicorn.begin_frame(rt)
	if !should_build { return }
	root := alicorn.container_begin(&ui, .Root, label="sidebar-titlebar-focus-fixture-root",
		key=alicorn.key_string("sidebar-titlebar-focus-fixture-root"),
		style=alicorn.layout_style(.Column, grow=1))
	pane := alicorn.container_begin(&ui, .Container, label="sidebar-titlebar-focus-fixture-pane",
		key=alicorn.key_string("sidebar-titlebar-focus-fixture-pane"),
		style=alicorn.layout_style(.Column, width=app.workspace_sidebar_width, grow=1))
	scratchpad_sidebar_titlebar_build(app, &ui)
	alicorn.container_end(&ui)
	alicorn.container_end(&ui)
	_ = root
	_ = pane
	alicorn.end_frame(&ui)
}

@(test)
test_workspace_titlebar_switcher_keeps_focus_and_fits_safe_area :: proc(t: ^testing.T) {
	app: App
	app.window_chrome_metrics = host.Window_Chrome_Metrics{
		header={0, 0, 900, SCRATCHPAD_CONTENT_TITLEBAR_HEIGHT},
		content_start_x=80,
		display_scale=1,
	}
	app.workspace_sidebar_width = 180
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 900, 120})
	defer alicorn.destroy_runtime(&rt)
	if !alicorn.text_engine_load_font(&rt.text_engine, ALICORN_TEST_UI_FONT_DATA) {
		testing.expect(t, false, "workspace titlebar controls should use the bundled application font")
		return
	}
	app.window_chrome_region_count = 0
	scratchpad_test_sidebar_titlebar_frame(&app, &rt)
	files_variant, files_selected, files_found := scratchpad_test_recipe_button(&rt, "Files")
	search_variant, search_selected, search_found := scratchpad_test_recipe_button(&rt, "Search")
	files_id, search_id, switcher_id, drag_id: alicorn.Node_ID
	for node_id in rt.order {
		node, found := rt.nodes[node_id]
		if !found || !node.active { continue }
		if node.kind == .Button && node.label == "Files" { files_id = node_id }
		if node.kind == .Button && node.label == "Search" { search_id = node_id }
		if node.label == "workspace-panel-tabs" { switcher_id = node_id }
		if node.label == "scratchpad-titlebar-sidebar-drag-space" { drag_id = node_id }
	}
	band_id: alicorn.Node_ID
	for node_id in rt.order {
		if node, found := rt.nodes[node_id]; found && node.active && node.label == "scratchpad-titlebar-sidebar-band" { band_id = node_id; break }
	}
	files, files_node_found := rt.nodes[files_id]
	search, search_node_found := rt.nodes[search_id]
	switcher, switcher_found := rt.nodes[switcher_id]
	drag, drag_found := rt.nodes[drag_id]
	band, band_found := rt.nodes[band_id]
	interactive_files, interactive_search, draggable_tail := false, false, false
	for region in app.window_chrome_regions[:app.window_chrome_region_count] {
		if region.node == files_id && region.kind == .Interactive { interactive_files = true }
		if region.node == search_id && region.kind == .Interactive { interactive_search = true }
		if region.node == drag_id && region.kind == .Window_Drag { draggable_tail = true }
	}
	expected_x := f32(8)
	when ODIN_OS == .Darwin { expected_x = app.window_chrome_metrics.content_start_x }
	testing.expect(t, files_found && search_found && files_variant == .Toolbar && search_variant == .Toolbar &&
		files_selected && !search_selected && files_node_found && search_node_found && switcher_found && drag_found &&
		abs(files.bounds.x-expected_x) < 1 && files.bounds.w > 0 && search.bounds.w > 0 &&
		files.bounds.x+files.bounds.w <= search.bounds.x+1 && abs(search.bounds.x+search.bounds.w-drag.bounds.x) < 1 &&
		abs(switcher.bounds.x-files.bounds.x) < 1 && abs(search.bounds.x+search.bounds.w-(switcher.bounds.x+switcher.bounds.w)) < 1 &&
		band_found && abs(drag.bounds.x+drag.bounds.w-(band.bounds.x+band.bounds.w)) < 1 &&
			drag.bounds.w == 8 && switcher.bounds.h == 32 && switcher.bounds.w > 0 && interactive_files && interactive_search && draggable_tail,
		fmt.tprintf("narrow sidebar titlebar controls should fit beside native reservations with distinct hit regions: files=%v search=%v switcher=%v drag=%v expected_x=%.1f found=%v/%v/%v/%v interactive=%v/%v drag_region=%v",
			files.bounds, search.bounds, switcher.bounds, drag.bounds, expected_x, files_node_found, search_node_found, switcher_found, drag_found, interactive_files, interactive_search, draggable_tail))
	testing.expect(t, alicorn.focus(&rt, search_id), "Search should remain keyboard-focusable in the titlebar")
	app.workspace_search_mode = true
	app.window_chrome_region_count = 0
	alicorn.invalidate_root(&rt, "toggle titlebar workspace switcher selection")
	scratchpad_test_sidebar_titlebar_frame(&app, &rt)
	search, search_node_found = rt.nodes[search_id]
	testing.expect(t, search_node_found && search.selected && rt.focused == search_id,
		"switching to Search should preserve titlebar focus while updating selected state")
	app.workspace_search_mode = false
	app.window_chrome_region_count = 0
	alicorn.invalidate_root(&rt, "restore titlebar workspace switcher selection")
	scratchpad_test_sidebar_titlebar_frame(&app, &rt)
	search, search_node_found = rt.nodes[search_id]
	testing.expect(t, search_node_found && !search.selected && rt.focused == search_id,
		"switching back to Files should preserve titlebar focus while restoring selected state")
}

@(test)
test_scratchpad_buttons_use_explicit_recipe_intents :: proc(t: ^testing.T) {
	app: App
	app.backend.started = true
	app.backend.state.has_workspace = true
	app.backend.state.workspace_root = "C:/recipe-fixture"
	documents := [?]bridge.State_Document{{
		id="recipe-doc", path="notes.md", status="synced", preview=false,
		editor_revision=1, line_count=0, language="markdown",
	}}
	app.backend.state.documents = documents[:]
	app.backend.state.active = "recipe-doc"
	app.tree_root_path = app.backend.state.workspace_root
	app.tree_directories = make([dynamic]Tree_Directory, 0, allocator=context.allocator)
	entries := [?]bridge.Directory_Entry{{name="sample.md", path="sample.md", dir=false}}
	append(&app.tree_directories, Tree_Directory{path="", entries=entries[:], expanded=true})
	app.editor_views = make([dynamic]Editor_View_State, 0, allocator=context.allocator)
	app.editor_edits = make([dynamic]Editor_Edit_Intent, 0, allocator=context.allocator)
	app.editor_row_targets = make([dynamic]Editor_Row_Target, 0, allocator=context.allocator)
	app.find_open = true
	app.find_match_case = true
	app.find_presentation = Find_Presentation{
		document_id="recipe-doc", editor_revision=1, query="", match_case=true,
		active_match=-1,
	}
	app.workspace_mutation_kind = .Create_File
	app.workspace_mutation_name = "draft.md"
	init_menus(&app)

	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 900, 600})
	app.window_chrome_metrics = host.Window_Chrome_Metrics{
		header={0, 0, 900, SCRATCHPAD_CONTENT_TITLEBAR_HEIGHT},
		content_start_x=80,
		display_scale=1,
	}
	defer {
		if len(app.editor_presented_document_id) > 0 { delete(app.editor_presented_document_id, context.allocator) }
		editor_views_destroy(&app.editor_views)
		delete(app.editor_edits)
		delete(app.editor_row_targets)
		delete(app.tree_directories)
		alicorn.destroy_runtime(&rt)
	}
	fonts_loaded := alicorn.text_engine_load_font(&rt.text_engine, ALICORN_TEST_UI_FONT_DATA) &&
		alicorn.text_engine_load_font_role(&rt.text_engine, .Monospace, ALICORN_TEST_MONO_FONT_DATA)
	testing.expect(t, fonts_loaded, "recipe dogfood test should load the bundled UI fonts")
	if !fonts_loaded { return }

	_ = build_app(rawptr(&app), &rt, 900, 600, 1)
	files_variant, files_selected, files_found := scratchpad_test_recipe_button(&rt, "Files")
	search_variant, search_selected, search_found := scratchpad_test_recipe_button(&rt, "Search")
	tab_variant, tab_selected, tab_found := scratchpad_test_tab_button_for_label(&rt, "notes.md", document_tab_semantic_id("recipe-doc"))
	tab_bar_found := false
	tab_bar_fills_viewport := false
	for node_id in rt.order {
		node, exists := rt.nodes[node_id]
		if exists && node.active && node.kind == .Scroll_Region && node.label == "tab-bar" {
			tab_bar_found = true
			tab_bar_fills_viewport = node.bounds.w > 0 && abs(node.bounds.w-node.scroll_viewport_width) < 1
			break
		}
	}
	tree_variant, _, tree_found := scratchpad_test_recipe_button(&rt, "sample.md")
	find_variant, find_selected, find_found := scratchpad_test_recipe_button(&rt, "Aa")
	primary_variant, _, primary_found := scratchpad_test_recipe_button(&rt, "Create")
	sidebar_id, panel_tabs_id, workspace_root_id: alicorn.Node_ID
	sidebar_titlebar_id, files_switch_id, search_switch_id: alicorn.Node_ID
	workspace_title_label_found := false
	status_bar_id, status_responsive_id: alicorn.Node_ID
	wrap_semantic_id, goto_semantic_id: alicorn.Semantic_ID
	for node_id in rt.order {
		node, found := rt.nodes[node_id]
		if !found || !node.active { continue }
		if node.label == "files-sidebar" { sidebar_id = node_id }
		if node.label == "workspace-panel-tabs" { panel_tabs_id = node_id }
		if node.label == "workspace-root-row" { workspace_root_id = node_id }
		if node.label == "scratchpad-titlebar-sidebar-band" { sidebar_titlebar_id = node_id }
		if node.kind == .Button && node.label == "Files" { files_switch_id = node_id }
		if node.kind == .Button && node.label == "Search" { search_switch_id = node_id }
		if node.kind == .Text && node.text == "Workspace" { workspace_title_label_found = true }
		if node.label == "document-status-bar" { status_bar_id = node_id }
		if node.label == "document-status-responsive" { status_responsive_id = node_id }
		if node.kind == .Button && node.label == "Wrap: Auto" && alicorn.node_is_presentation_active(&rt, node_id) { wrap_semantic_id = node.semantic_id }
		if node.kind == .Button && node.label == "Go to Line…" && alicorn.node_is_presentation_active(&rt, node_id) { goto_semantic_id = node.semantic_id }
	}

	testing.expect(t, files_found && files_variant == .Toolbar && files_selected,
		"the active Files workspace switch should use the quiet Toolbar recipe and selected state")
	testing.expect(t, search_found && search_variant == .Toolbar && !search_selected,
		"the Search workspace switch should use the quiet Toolbar recipe and remain unselected")
	testing.expect(t, tab_found && tab_variant == .Tab && tab_selected,
		"the active document should be represented by a selected semantic Tab control")
	testing.expect(t, tab_bar_found && tab_bar_fills_viewport,
		"the composite tab bar should size its scroll viewport from the resolved workbench width on its first description")
	testing.expect(t, tree_found && tree_variant == .Quiet,
		"the workspace tree item should retain Quiet recipe intent")
	testing.expect(t, find_found && find_variant == .Toolbar && find_selected,
		"the selected Match Case find control should retain Toolbar recipe intent and selected state")
	testing.expect(t, primary_found && primary_variant == .Primary,
		"the workspace mutation confirmation should retain Primary recipe intent")
	testing.expect(t, sidebar_id != 0 && panel_tabs_id != 0 && workspace_root_id != 0,
		"the compact workspace sidebar should retain its view switches and root row")
	if sidebar_id != 0 && panel_tabs_id != 0 && workspace_root_id != 0 {
		sidebar_style := rt.nodes[sidebar_id].style
		tabs_style := rt.nodes[panel_tabs_id].style
		root_style := rt.nodes[workspace_root_id].style
		testing.expect(t, sidebar_style.padding == 8 && sidebar_style.gap == 6,
			"the workspace sidebar should use compact outer padding and section spacing")
			when ODIN_OS == .Darwin || ODIN_OS == .Windows {
				testing.expect(t, tabs_style.height == 32 && tabs_style.gap == 2 && root_style.height == 26,
					"titlebar workspace switches and root path should use compact aligned heights")
			} else {
				testing.expect(t, tabs_style.height == 30 && tabs_style.gap == 4 && root_style.height == 26,
					"Linux should retain its existing sidebar switcher row and compact root path")
			}
	}
	when ODIN_OS == .Darwin || ODIN_OS == .Windows {
		titlebar, titlebar_found := rt.nodes[sidebar_titlebar_id]
		tabs, tabs_found := rt.nodes[panel_tabs_id]
		files, files_node_found := rt.nodes[files_switch_id]
		search, search_node_found := rt.nodes[search_switch_id]
		drag_id: alicorn.Node_ID
		for node_id in rt.order {
			node, found := rt.nodes[node_id]
			if found && node.active && node.label == "scratchpad-titlebar-sidebar-drag-space" { drag_id = node_id; break }
		}
		drag, drag_found := rt.nodes[drag_id]
		chrome := scratchpad_content_titlebar_layout(rawptr(&app), &rt)
		files_interactive, search_interactive, trailing_drag := false, false, false
		for region in chrome.regions {
			if region.node == files_switch_id && region.kind == .Interactive { files_interactive = true }
			if region.node == search_switch_id && region.kind == .Interactive { search_interactive = true }
			if region.node == drag_id && region.kind == .Window_Drag { trailing_drag = true }
		}
		expected_switcher_x := f32(8)
		when ODIN_OS == .Darwin {
			expected_switcher_x = max(app.window_chrome_metrics.content_start_x, f32(8))
		}
		pane, pane_found := rt.nodes[titlebar.parent]
		testing.expect(t, titlebar_found && tabs_found && tabs.parent == sidebar_titlebar_id &&
			files_node_found && search_node_found && files.parent == panel_tabs_id && search.parent == panel_tabs_id &&
			abs(files.bounds.x-expected_switcher_x) < 1 &&
			files.bounds.w > 0 && search.bounds.w > 0 && files.bounds.x+files.bounds.w <= search.bounds.x+1 &&
			drag_found && search.bounds.x+search.bounds.w <= drag.bounds.x+1 && drag.bounds.w == 8 &&
			titlebar.bounds.h == SCRATCHPAD_CONTENT_TITLEBAR_HEIGHT &&
			pane_found && abs(titlebar.bounds.w-pane.bounds.w) < 1 && abs(tabs.bounds.w-(titlebar.bounds.w-(expected_switcher_x-titlebar.bounds.x)-drag.bounds.w)) < 1 &&
			files_interactive && search_interactive && trailing_drag && !workspace_title_label_found,
			"Files/Search should sit in the sidebar titlebar after the macOS safe area, with separate interactive and draggable regions and no redundant Workspace label")
	} else {
		tabs, tabs_found := rt.nodes[panel_tabs_id]
		sidebar, sidebar_found := rt.nodes[sidebar_id]
		testing.expect(t, tabs_found && sidebar_found && tabs.parent == sidebar_id,
			"Linux should keep the Files/Search switcher in the sidebar body")
	}
	status_bar, status_bar_found := rt.nodes[status_bar_id]
	wrap_semantic, wrap_semantic_found := alicorn.semantic_node_lookup(&rt, wrap_semantic_id)
	goto_semantic, goto_semantic_found := alicorn.semantic_node_lookup(&rt, goto_semantic_id)
	testing.expect(t, status_bar_found && status_bar.style.height == alicorn.LAYOUT_SIZE_FIT_CONTENT &&
		status_bar.style.min_height == 40 && status_bar.bounds.h >= 40,
		"the editor status toolbar should opt into Row content-height measurement and contain its padded controls")
	adaptive := alicorn.adaptive_selection_state(&rt, status_responsive_id)
	wide_fits, wide_overflow := scratchpad_test_status_contents_fit(&rt, status_bar_id)
	testing.expect(t, status_responsive_id != 0 && adaptive.valid && adaptive.selected_name == "Wide" && wide_fits,
		fmt.tprintf("wide status should fit: owner=%d valid=%t selection=%s available=%.1f bar=%v fit=%t %s", status_responsive_id, adaptive.valid, adaptive.selected_name, adaptive.available_width, status_bar.bounds, wide_fits, wide_overflow))
	testing.expect(t, wrap_semantic_found && wrap_semantic.role == .Button &&
		goto_semantic_found && goto_semantic.role == .Button,
		"the measured toolbar should keep Wrap and Go to Line available as semantic controls")

	inspection := alicorn.inspect(&rt)
	testing.expect(t, strings.contains(inspection, "button recipe: variant=tab") &&
		strings.contains(inspection, "button recipe: variant=quiet") &&
		strings.contains(inspection, "button recipe: variant=toolbar") &&
		strings.contains(inspection, "button recipe: variant=primary"),
		"the Alicorn inspector should explain the resolved recipe provenance for dogfood controls")
	delete(inspection, context.allocator)

	// The editor pane, not the outer window, determines whether its status row
	// can show every action. At this width the adaptive region should use its
	// compact form and keep the Go to Line menu command available elsewhere.
	rt.viewport = alicorn.Rect{0, 0, 820, 600}
	app.window_chrome_metrics.header = alicorn.Rect{0, 0, 820, SCRATCHPAD_CONTENT_TITLEBAR_HEIGHT}
	alicorn.invalidate_root(&rt, "status responsive-width regression")
	_ = build_app(rawptr(&app), &rt, 820, 600, 1)
	status_bar_id, status_responsive_id = 0, 0
	for node_id in rt.order {
		node, found := rt.nodes[node_id]
		if !found || !node.active { continue }
		if node.label == "document-status-bar" { status_bar_id = node_id }
		if node.label == "document-status-responsive" { status_responsive_id = node_id }
	}
	adaptive = alicorn.adaptive_selection_state(&rt, status_responsive_id)
	compact_goto_visible := false
	for node_id in rt.order {
		node, found := rt.nodes[node_id]
		if found && node.kind == .Button && node.label == "Go to Line…" && alicorn.node_is_presentation_active(&rt, node_id) {
			compact_goto_visible = true
		}
	}
	compact_fits, compact_overflow := scratchpad_test_status_contents_fit(&rt, status_bar_id)
	testing.expect(t, adaptive.valid && adaptive.selected_name == "Compact" &&
		!compact_goto_visible && compact_fits,
		fmt.tprintf("compact status should fit: valid=%t selection=%s available=%.1f bar=%v goto=%t fit=%t %s", adaptive.valid, adaptive.selected_name, adaptive.available_width, rt.nodes[status_bar_id].bounds, compact_goto_visible, compact_fits, compact_overflow))
}
