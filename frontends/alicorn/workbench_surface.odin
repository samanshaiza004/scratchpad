package main

import "core:fmt"
import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"
import bridge "./bridge"

RECENT_WORKSPACE_ROW_HEIGHT :: f32(36)
RECENT_WORKSPACE_MODAL_LIST_HEIGHT :: f32(324)
RECENT_WORKSPACE_START_LIST_HEIGHT :: f32(238)

build_start_screen :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime) {
	if app == nil || ui == nil || rt == nil { return }
	viewport := alicorn.viewport_bounds(rt)
	card_width := min(520, max(viewport.w-48, 200))
	card_max_height := min(640, max(viewport.h-40, 180))
	recent_height := max(min(RECENT_WORKSPACE_START_LIST_HEIGHT, card_max_height-220), RECENT_WORKSPACE_ROW_HEIGHT)
	alicorn.container_begin(ui, .Container, label="scratchpad-start-screen", style=alicorn.layout_style(.Column, grow=1, align=.Center, justify=.Center, padding=20))
	alicorn.container_begin(ui, .Container, label="scratchpad-start-content", style=alicorn.layout_style(.Column, width=card_width, height=alicorn.LAYOUT_SIZE_FIT_CONTENT, max_height=card_max_height, padding=28, gap=14, clip=true), color=alicorn.style_color(ui, .Surface))
	alicorn.text(ui, "Scratchpad")
	alicorn.text(ui, "Files first. Your workspace, your way.")
	alicorn.container_begin(ui, .Container, label="scratchpad-start-actions", style=alicorn.layout_style(.Row, height=42, gap=8, align=.Center))
	if alicorn.button(ui, "Open File…", key=alicorn.key_string("start-open-file"), style=alicorn.layout_style(.Row, grow=1, height=38)) {
		dispatch_action(app, rt, ACTION_FILE_OPEN)
	}
	if alicorn.button(ui, "Open Folder…", key=alicorn.key_string("start-open-folder"), style=alicorn.layout_style(.Row, grow=1, height=38), variant=.Primary) {
		dispatch_action(app, rt, ACTION_WORKSPACE_OPEN)
	}
	alicorn.container_end(ui)
	if alicorn.button(ui, "Command Palette…", key=alicorn.key_string("start-command-palette"), style=alicorn.layout_style(.Row, grow=1, height=36), variant=.Quiet) {
		command_palette_open_surface(app, rt)
	}
	if len(app.backend.state.recent_workspaces) > 0 {
		alicorn.text(ui, "Recent Workspaces")
		list := alicorn.virtual_list_begin(
			ui,
			len(app.backend.state.recent_workspaces),
			RECENT_WORKSPACE_ROW_HEIGHT,
			key=alicorn.key_string("scratchpad-start-recent-workspaces"),
			style=alicorn.layout_style(height=alicorn.LAYOUT_SIZE_FIT_CONTENT, max_height=recent_height, grow=1, clip=true),
			label="scratchpad-start-recent-workspaces",
		)
		for index := list.first; index < list.last; index += 1 {
			path := app.backend.state.recent_workspaces[index]
			if alicorn.button(ui, path, key=alicorn.key_string(path), style=alicorn.layout_style(.Row, height=RECENT_WORKSPACE_ROW_HEIGHT), text_style=alicorn.Text_Style{overflow=.Ellipsis}, variant=.Quiet) {
				recent_workspace_open(app, rt, path)
			}
		}
		alicorn.virtual_list_end(ui, list)
	}
	alicorn.container_end(ui)
	alicorn.container_end(ui)
}
recent_workspace_open :: proc(app: ^App, rt: ^alicorn.Runtime, path: string) {
	if app == nil || rt == nil || !app.backend.started || path == "" { return }
	response := bridge.backend_command(&app.backend, "open_path", path=path)
	handle_command_result(app, rt, &response)
	bridge.backend_command_result_destroy(&response, context.allocator)
	app.recent_workspaces_open = false
	alicorn.invalidate_root(rt, "Scratchpad opened a recent workspace")
}

recent_workspace_clear :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil || !app.backend.started { return }
	response := bridge.backend_command(&app.backend, "clear_recent_workspaces")
	handle_command_result(app, rt, &response)
	bridge.backend_command_result_destroy(&response, context.allocator)
	alicorn.invalidate_root(rt, "Scratchpad cleared recent workspaces")
}

recent_workspaces_surface_build :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime) {
	if app == nil || ui == nil || rt == nil || !app.recent_workspaces_open { return }
	alicorn.modal_overlay_begin(ui, alicorn.key_string("recent-workspaces-overlay"), style=alicorn.layout_style(.Column, grow=1, align=.Center, justify=.Center), backdrop_color=alicorn.Color{0.015, 0.02, 0.03, 0.72})
	alicorn.surface_begin(ui, alicorn.surface_core_color_role(.Surface), key=alicorn.key_string("recent-workspaces-panel"), label="recent-workspaces-panel", style=alicorn.layout_style(.Column, max_width=680, height=alicorn.LAYOUT_SIZE_FIT_CONTENT, max_height=560, padding=18, gap=8, clip=true), material=app.floating_surface_material, physical_height=1)
	alicorn.text(ui, "Recent Workspaces")
	if len(app.backend.state.recent_workspaces) == 0 {
		alicorn.text(ui, "No workspaces have been opened yet.")
	} else {
		list := alicorn.virtual_list_begin(
			ui,
			len(app.backend.state.recent_workspaces),
			RECENT_WORKSPACE_ROW_HEIGHT,
			key=alicorn.key_string("recent-workspaces-list"),
			style=alicorn.layout_style(height=alicorn.LAYOUT_SIZE_FIT_CONTENT, max_height=RECENT_WORKSPACE_MODAL_LIST_HEIGHT, grow=1, clip=true),
			label="recent-workspaces-list",
		)
		for index := list.first; index < list.last; index += 1 {
			path := app.backend.state.recent_workspaces[index]
			if alicorn.button(ui, path, key=alicorn.key_string(path), style=alicorn.layout_style(.Row, height=RECENT_WORKSPACE_ROW_HEIGHT), text_style=alicorn.Text_Style{overflow=.Ellipsis}, content_style=alicorn.button_content_style(.Start, padding_x=8), variant=.Quiet) {
				recent_workspace_open(app, rt, path)
			}
		}
		alicorn.virtual_list_end(ui, list)
	}
	alicorn.container_begin(ui, .Container, label="recent-workspaces-actions", style=alicorn.layout_style(.Row, height=38, gap=8, align=.End))
	if alicorn.button(ui, "Clear Recent", key=alicorn.key_string("recent-workspaces-clear"), style=alicorn.layout_style(.Row, width=120, height=34), state=alicorn.Button_State{disabled=len(app.backend.state.recent_workspaces) == 0}, variant=.Quiet) {
		recent_workspace_clear(app, rt)
	}
	if alicorn.button(ui, "Done", key=alicorn.key_string("recent-workspaces-done"), style=alicorn.layout_style(.Row, width=88, height=34)) {
		app.recent_workspaces_open = false
		alicorn.invalidate_root(rt, "Scratchpad closed recent workspaces")
	}
	alicorn.container_end(ui)
	alicorn.surface_end(ui)
	alicorn.modal_overlay_end(ui)
}

settings_surface_build :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime, text_scale: f32 = 1) {
	if app == nil || ui == nil || rt == nil { return }
	scale := max(text_scale, 1)
	viewport := alicorn.viewport_bounds(rt)
	panel_width := min(640, max(viewport.w-32, 200))
	panel_height := min(700, max(viewport.h-32, 180))
	header_height := max(30, 26*scale)
	footer_height := max(42, 38*scale)
	control_height := max(32, 30*scale)
	body_height := max(panel_height-28-header_height-footer_height-12, 24)

	host_appearance := alicorn.style_root_accessibility_observation_get(rt)
	status_summary := fmt.tprintf(
		"Contrast: %s  ·  Reduce motion: %s  ·  Reduce transparency: %s  ·  Differentiate without color: %s",
		settings_accessibility_observed_value(host_appearance, .Increased_Contrast, host_appearance.preferences.increased_contrast),
		settings_accessibility_observed_value(host_appearance, .Reduce_Motion, host_appearance.preferences.reduce_motion),
		settings_accessibility_observed_value(host_appearance, .Reduce_Transparency, host_appearance.preferences.reduce_transparency),
		settings_accessibility_observed_value(host_appearance, .Differentiate_Without_Color, host_appearance.preferences.differentiate_without_color),
	)
	row_gap := max(8, 6*scale)
	option_gap := max(3, 3*scale)
	sample_gap := max(6, 4*scale)
	sample_inner_gap := max(5, 3*scale)
	section_gap := max(12, 8*scale)
	section_heights := settings_form_section_heights(rt, panel_width, scale, status_summary, scratchpad_editor_font_size(app))
	section_row_heights := [4]f32{
		section_heights[0]+section_gap,
		section_heights[1]+section_gap,
		section_heights[2]+section_gap,
		section_heights[3],
	}
	form_content_height := section_row_heights[0]+section_row_heights[1]+section_row_heights[2]+section_row_heights[3]
	_ = form_content_height
	height_index: alicorn.Virtual_List_Height_Index
	if !alicorn.virtual_list_height_index_init(&height_index, len(section_row_heights), control_height, context.temp_allocator) { return }
	defer alicorn.virtual_list_height_index_destroy(&height_index)
	for row_height, row_index in section_row_heights {
		_ = alicorn.virtual_list_height_index_set_height(&height_index, row_index, row_height)
	}

	alicorn.modal_overlay_begin(ui, alicorn.key_string("scratchpad-settings-overlay"), style=alicorn.layout_style(.Column, grow=1, align=.Center, justify=.Center), backdrop_color=alicorn.Color{0.015, 0.02, 0.03, 0.72})
	alicorn.container_begin(ui, .Container, label="scratchpad-settings", style=alicorn.layout_style(.Column, width=panel_width, height=panel_height, padding=14, gap=6, align=.Start, clip=true), color=alicorn.style_color(ui, .Surface))
	alicorn.container_begin(ui, .Container, label="scratchpad-settings-header", style=alicorn.layout_style(.Row, height=header_height, align=.Center))
	alicorn.text(ui, "Settings", style=alicorn.layout_style(.Row, height=header_height, grow=1))
	alicorn.container_end(ui)

	settings_list := alicorn.virtual_list_begin_variable(
		ui,
		&height_index,
		key=alicorn.key_string("scratchpad-settings-scroll"),
		style=alicorn.layout_style(.Column, width=-1, height=body_height, clip=true),
		label="scratchpad-settings-scroll",
		axes=.Vertical,
		focusable=true,
	)
	settings_scroll := settings_list.scroll

	if settings_list.first <= 0 && settings_list.last > 0 {
	alicorn.container_begin(ui, .Container, label="settings-section-appearance", key=alicorn.key_string("settings-section-appearance"), style=alicorn.layout_style(.Column, width=-1, height=section_row_heights[0], gap=row_gap, align=.Start))
	alicorn.text(ui, "Appearance", key=alicorn.key_string("settings-appearance-heading"), style=alicorn.layout_style(.Row, width=-1, height=max(22, 20*scale)))
	alicorn.text(ui, "Theme", key=alicorn.key_string("settings-theme-heading"), style=alicorn.layout_style(.Row, width=-1, height=max(20, 18*scale)))
	alicorn.container_begin(ui, .Container, label="settings-theme-choice-row", style=alicorn.layout_style(.Row, height=max(36, 32*scale), gap=6, align=.Center))
	if alicorn.button(ui, "Warm", key=alicorn.key_string("settings-theme-warm"), style=alicorn.layout_style(.Row, grow=1, height=max(34, 30*scale)), state=alicorn.Button_State{selected=app.theme_choice == .Warm}, variant=.Quiet) {
		if !frame_deferred_action_schedule(app, .Action, ACTION_VIEW_THEME_WARM) { set_error(app, "Could not queue the Warm theme change.") }
	}
	if alicorn.button(ui, "Cool Light", key=alicorn.key_string("settings-theme-cool-light"), style=alicorn.layout_style(.Row, grow=1, height=max(34, 30*scale)), state=alicorn.Button_State{selected=app.theme_choice == .Cool_Light}, variant=.Quiet) {
		if !frame_deferred_action_schedule(app, .Action, ACTION_VIEW_THEME_COOL_LIGHT) { set_error(app, "Could not queue the Cool Light theme change.") }
	}
	alicorn.container_end(ui)
	alicorn.container_end(ui)

	}
	if settings_list.first <= 1 && settings_list.last > 1 {
	alicorn.container_begin(ui, .Container, label="settings-section-workspace", key=alicorn.key_string("settings-section-workspace"), style=alicorn.layout_style(.Column, width=-1, height=section_row_heights[1], gap=row_gap, align=.Start))
	alicorn.text(ui, "Workspace", key=alicorn.key_string("settings-workspace-heading"), style=alicorn.layout_style(.Row, width=-1, height=max(22, 20*scale)))
	ignored_change := alicorn.checkbox(ui, "Show ignored files in the file tree", app.show_ignored_files, key=alicorn.key_string("settings-show-ignored-files"), style=alicorn.layout_style(.Row, width=-1, height=alicorn.LAYOUT_SIZE_FIT_CONTENT, min_height=control_height), disabled=!app.backend.started || !app.backend.state.has_workspace)
	if ignored_change.changed { tree_set_show_ignored_files(app, rt, ignored_change.value) }
	alicorn.text(ui, "Workspace search continues to honor ignore rules.", key=alicorn.key_string("settings-workspace-search-note"), style=alicorn.layout_style(.Row, width=-1, height=alicorn.LAYOUT_SIZE_FIT_CONTENT), text_style=alicorn.Text_Style{overflow=.Wrap})
	alicorn.container_end(ui)

	}
	if settings_list.first <= 2 && settings_list.last > 2 {
	alicorn.container_begin(ui, .Container, label="settings-section-accessibility", key=alicorn.key_string("settings-section-accessibility"), style=alicorn.layout_style(.Column, width=-1, height=section_row_heights[2], gap=row_gap, align=.Start))
	alicorn.text(ui, "Accessibility appearance", key=alicorn.key_string("settings-accessibility-heading"), style=alicorn.layout_style(.Row, width=-1, height=max(22, 20*scale)))
	system_preferences_change := alicorn.checkbox(ui, "Use system accessibility preferences", !app.accessibility_appearance_override_enabled, key=alicorn.key_string("settings-accessibility-use-system"), style=alicorn.layout_style(.Row, width=-1, height=alicorn.LAYOUT_SIZE_FIT_CONTENT, min_height=control_height))
	if system_preferences_change.changed {
		app.accessibility_appearance_override_enabled = !system_preferences_change.value
		alicorn.invalidate_root(rt, "Scratchpad accessibility appearance source changed")
	}
	alicorn.text(ui, "Turn this off to apply an app-level override for testing; it does not change OS settings.", key=alicorn.key_string("settings-accessibility-override-note"), style=alicorn.layout_style(.Row, width=-1, height=alicorn.LAYOUT_SIZE_FIT_CONTENT), text_style=alicorn.Text_Style{overflow=.Wrap})
	alicorn.text(ui, "System detected (host values; app overrides below do not change these):", key=alicorn.key_string("settings-accessibility-observed-label"), style=alicorn.layout_style(.Row, width=-1, height=alicorn.LAYOUT_SIZE_FIT_CONTENT), text_style=alicorn.Text_Style{overflow=.Wrap})
	alicorn.text(ui, status_summary, key=alicorn.key_string("settings-accessibility-observed-summary"), style=alicorn.layout_style(.Row, width=-1, height=alicorn.LAYOUT_SIZE_FIT_CONTENT), text_style=alicorn.Text_Style{overflow=.Wrap})

	alicorn.container_begin(ui, .Container, label="settings-accessibility-options", style=alicorn.layout_style(.Column, width=-1, height=alicorn.LAYOUT_SIZE_FIT_CONTENT, gap=option_gap, align=.Start))
	contrast_change := alicorn.checkbox(ui, "Increase contrast", app.accessibility_appearance.increased_contrast, key=alicorn.key_string("settings-accessibility-increased-contrast"), style=alicorn.layout_style(.Row, width=-1, height=alicorn.LAYOUT_SIZE_FIT_CONTENT, min_height=control_height), disabled=!app.accessibility_appearance_override_enabled)
	if contrast_change.changed {
		app.accessibility_appearance.increased_contrast = contrast_change.value
		alicorn.invalidate_root(rt, "Scratchpad increased-contrast preference changed")
	}
	motion_change := alicorn.checkbox(ui, "Reduce motion", app.accessibility_appearance.reduce_motion, key=alicorn.key_string("settings-accessibility-reduce-motion"), style=alicorn.layout_style(.Row, width=-1, height=alicorn.LAYOUT_SIZE_FIT_CONTENT, min_height=control_height), disabled=!app.accessibility_appearance_override_enabled)
	if motion_change.changed {
		app.accessibility_appearance.reduce_motion = motion_change.value
		alicorn.invalidate_root(rt, "Scratchpad reduce-motion preference changed")
	}
	transparency_change := alicorn.checkbox(ui, "Reduce transparency", app.accessibility_appearance.reduce_transparency, key=alicorn.key_string("settings-accessibility-reduce-transparency"), style=alicorn.layout_style(.Row, width=-1, height=alicorn.LAYOUT_SIZE_FIT_CONTENT, min_height=control_height), disabled=!app.accessibility_appearance_override_enabled)
	if transparency_change.changed {
		app.accessibility_appearance.reduce_transparency = transparency_change.value
		alicorn.invalidate_root(rt, "Scratchpad reduce-transparency preference changed")
	}
	differentiate_change := alicorn.checkbox(ui, "Differentiate without color", app.accessibility_appearance.differentiate_without_color, key=alicorn.key_string("settings-accessibility-differentiate-without-color"), style=alicorn.layout_style(.Row, width=-1, height=alicorn.LAYOUT_SIZE_FIT_CONTENT, min_height=control_height), disabled=!app.accessibility_appearance_override_enabled)
	if differentiate_change.changed {
		app.accessibility_appearance.differentiate_without_color = differentiate_change.value
		alicorn.invalidate_root(rt, "Scratchpad differentiate-without-color preference changed")
	}
	alicorn.container_end(ui)

	alicorn.container_begin(ui, .Container, label="settings-appearance-samples", style=alicorn.layout_style(.Column, width=-1, height=alicorn.LAYOUT_SIZE_FIT_CONTENT, gap=sample_gap, align=.Start))
	alicorn.surface_begin(ui, alicorn.surface_core_color_role(.Selection), key=alicorn.key_string("settings-accessibility-material-sample"), label="settings-accessibility-material-sample", style=alicorn.layout_style(.Column, width=-1, height=alicorn.LAYOUT_SIZE_FIT_CONTENT, padding=8, gap=sample_inner_gap, align=.Start), material=app.floating_surface_material, physical_height=0.5)
	alicorn.text(ui, "Selection tint + relief", key=alicorn.key_string("settings-accessibility-material-title"), style=alicorn.layout_style(.Row, width=-1, height=alicorn.LAYOUT_SIZE_FIT_CONTENT))
	alicorn.text(ui, "Transparency makes it opaque and removes shadows.", key=alicorn.key_string("settings-accessibility-material-note"), style=alicorn.layout_style(.Row, width=-1, height=alicorn.LAYOUT_SIZE_FIT_CONTENT), text_style=alicorn.Text_Style{overflow=.Wrap})
	alicorn.surface_end(ui)
	if alicorn.button(ui, "Selected state sample", key=alicorn.key_string("settings-accessibility-selected-sample"), style=alicorn.layout_style(.Row, width=min(260*scale, panel_width-56), height=control_height), state=alicorn.Button_State{selected=true}, variant=.Quiet) {
		// This sample has no action; selection is held to expose the recipe's
		// non-color indicator while the preference is toggled.
	}
	alicorn.container_end(ui)

	alicorn.text(ui, "Tab through controls to inspect focus contrast. The selected sample gains an underline without color differentiation.", key=alicorn.key_string("settings-accessibility-focus-note"), style=alicorn.layout_style(.Row, width=-1, height=alicorn.LAYOUT_SIZE_FIT_CONTENT), text_style=alicorn.Text_Style{overflow=.Wrap})
	alicorn.text(ui, "Reduce Motion is forwarded to Alicorn; current controls have no animated style transitions. View → Zoom tests text scaling.", key=alicorn.key_string("settings-accessibility-motion-note"), style=alicorn.layout_style(.Row, width=-1, height=alicorn.LAYOUT_SIZE_FIT_CONTENT), text_style=alicorn.Text_Style{overflow=.Wrap})
	alicorn.container_end(ui)
	}
	if settings_list.first <= 3 && settings_list.last > 3 {
	alicorn.container_begin(ui, .Container, label="settings-section-typography", key=alicorn.key_string("settings-section-typography"), style=alicorn.layout_style(.Column, width=-1, height=section_row_heights[3], gap=row_gap, align=.Start))
	alicorn.text(ui, "Typography", key=alicorn.key_string("settings-typography-heading"), style=alicorn.layout_style(.Row, width=-1, height=max(22, 20*scale)))
	alicorn.text(ui, "Editor font family", key=alicorn.key_string("settings-editor-font-family-label"), style=alicorn.layout_style(.Row, width=-1, height=max(20, 18*scale)))
	family_label := app.editor_font_family
	if family_label == "" { family_label = "Atkinson Hyperlegible Mono (bundled default)" }
	if alicorn.button(ui, fmt.tprintf("%s  ▾", family_label), key=alicorn.key_string("settings-editor-font-family"), style=alicorn.layout_style(.Row, width=-1, height=control_height), text_style=alicorn.Text_Style{overflow=.Ellipsis}, content_style=alicorn.button_content_style(.Start, padding_x=8), variant=.Quiet) {
		scratchpad_editor_font_picker_open(app, rt)
	}
	alicorn.text(ui, "Editor font size", key=alicorn.key_string("settings-editor-font-size-label"), style=alicorn.layout_style(.Row, width=-1, height=max(20, 18*scale)))
	alicorn.container_begin(ui, .Container, label="settings-editor-font-size-controls", style=alicorn.layout_style(.Row, width=-1, height=control_height, gap=6, align=.Center))
	editor_font_size := scratchpad_editor_font_size(app)
	if alicorn.button(ui, "−", key=alicorn.key_string("settings-editor-font-size-down"), style=alicorn.layout_style(.Row, width=control_height, height=control_height), state=alicorn.Button_State{disabled=editor_font_size <= EDITOR_FONT_SIZE_MIN}, variant=.Quiet) {
		_ = scratchpad_editor_font_request(app, rt, app.editor_font_family, max(EDITOR_FONT_SIZE_MIN, editor_font_size-1))
	}
	alicorn.text(ui, fmt.tprintf("%.1f px", editor_font_size), key=alicorn.key_string("settings-editor-font-size-value"), style=alicorn.layout_style(.Row, width=72, height=control_height))
	if alicorn.button(ui, "+", key=alicorn.key_string("settings-editor-font-size-up"), style=alicorn.layout_style(.Row, width=control_height, height=control_height), state=alicorn.Button_State{disabled=editor_font_size >= EDITOR_FONT_SIZE_MAX}, variant=.Quiet) {
		_ = scratchpad_editor_font_request(app, rt, app.editor_font_family, min(EDITOR_FONT_SIZE_MAX, editor_font_size+1))
	}
	alicorn.container_end(ui)
	alicorn.text(ui, "Editor only; monospaced families first. Preview updates when selected.", key=alicorn.key_string("settings-editor-font-note"), style=alicorn.layout_style(.Row, width=-1, height=alicorn.LAYOUT_SIZE_FIT_CONTENT), text_style=alicorn.Text_Style{overflow=.Wrap})
	alicorn.text(ui, "Live editor preview", key=alicorn.key_string("settings-editor-font-preview-label"), style=alicorn.layout_style(.Row, width=-1, height=max(20, 18*scale)))
	editor_preview := "┌─ Editor ───────────┐\n│ Café  λ = 0.1     │\n└────────────────────┘"
	preview_height := settings_measured_font_preview_height(rt, editor_preview, max(panel_width-28-alicorn.SCROLLBAR_THICKNESS-4, 1), editor_font_size*scale)
	alicorn.text(ui, editor_preview, key=alicorn.key_string("settings-editor-font-preview"), style=alicorn.layout_style(.Row, width=-1, height=preview_height), font=.Monospace, text_style=alicorn.Text_Style{font_size=editor_font_size, overflow=.Clip})
	if alicorn.button(ui, "Reset typography", key=alicorn.key_string("settings-editor-font-reset"), style=alicorn.layout_style(.Row, width=160, height=control_height), variant=.Quiet) {
		_ = scratchpad_editor_font_request(app, rt, "", EDITOR_FONT_SIZE_DEFAULT)
	}
	alicorn.container_end(ui)
	}
	alicorn.virtual_list_end(ui, settings_list)

	alicorn.container_begin(ui, .Container, label="scratchpad-settings-footer", style=alicorn.layout_style(.Row, height=footer_height, gap=8, align=.Center))
	alicorn.container_begin(ui, .Container, label="scratchpad-settings-footer-spacer", style=alicorn.layout_style(.Row, grow=1))
	alicorn.container_end(ui)
	if alicorn.button(ui, "Done", key=alicorn.key_string("settings-done"), style=alicorn.layout_style(.Row, width=88, height=control_height)) {
		settings_surface_close(app, rt)
	}
	alicorn.container_end(ui)
	alicorn.container_end(ui)
	alicorn.modal_overlay_end(ui)
}

settings_column_height :: proc(heights: []f32, gap: f32, padding: f32 = 0) -> f32 {
	total := max(padding, f32(0))*2
	for height, index in heights {
		if index > 0 { total += max(gap, f32(0)) }
		total += max(height, f32(0))
	}
	return total
}

settings_measured_text_height :: proc(
	rt: ^alicorn.Runtime,
	value: string,
	width: f32,
	scale: f32,
) -> f32 {
	if rt == nil || value == "" { return 0 }
	size := alicorn.DEFAULT_TEXT_SIZE*scale
	run, ok := alicorn.runtime_text_run_build(rt, value, size, max(width, 1), font=.UI)
	if ok {
		height := run.height
		alicorn.text_run_destroy(&run)
		return height
	}
	return max(24*scale, size*1.25)
}

settings_measured_font_preview_height :: proc(rt: ^alicorn.Runtime, value: string, width, font_size: f32) -> f32 {
	if rt == nil || value == "" { return 0 }
	run, ok := alicorn.runtime_text_run_build(rt, value, font_size, max(width, 1), font=.Monospace)
	if ok {
		height := run.height
		alicorn.text_run_destroy(&run)
		return height
	}
	return max(font_size*3*1.25, font_size*3)
}

settings_measured_checkbox_height :: proc(
	rt: ^alicorn.Runtime,
	label: string,
	form_text_width: f32,
	minimum_height: f32,
	scale: f32,
) -> f32 {
	label_height := settings_measured_text_height(rt, label, max(form_text_width-36, 1), scale)
	return max(minimum_height, max(28, label_height+8))
}

settings_form_section_heights :: proc(
	rt: ^alicorn.Runtime,
	panel_width: f32,
	scale: f32,
	status_summary: string,
	editor_font_size: f32 = EDITOR_FONT_SIZE_DEFAULT,
) -> [4]f32 {
	form_text_width := max(panel_width-28-alicorn.SCROLLBAR_THICKNESS-4, 1)
	sample_text_width := max(form_text_width-16, 1)
	row_gap := max(8, 6*scale)
	option_gap := max(3, 3*scale)
	sample_gap := max(6, 4*scale)
	sample_inner_gap := max(5, 3*scale)
	control_height := max(32, 30*scale)
	heading_height := max(22, 20*scale)

	appearance_items := [3]f32{
		heading_height,
		max(20, 18*scale),
		max(36, 32*scale),
	}
	appearance_height := settings_column_height(appearance_items[:], row_gap)

	workspace_items := [3]f32{
		heading_height,
		settings_measured_checkbox_height(rt, "Show ignored files in the file tree", form_text_width, control_height, scale),
		settings_measured_text_height(rt, "Workspace search continues to honor ignore rules.", form_text_width, scale),
	}
	workspace_height := settings_column_height(workspace_items[:], row_gap)

	option_items := [4]f32{
		settings_measured_checkbox_height(rt, "Increase contrast", form_text_width, control_height, scale),
		settings_measured_checkbox_height(rt, "Reduce motion", form_text_width, control_height, scale),
		settings_measured_checkbox_height(rt, "Reduce transparency", form_text_width, control_height, scale),
		settings_measured_checkbox_height(rt, "Differentiate without color", form_text_width, control_height, scale),
	}
	options_height := settings_column_height(option_items[:], option_gap)

	sample_surface_items := [2]f32{
		settings_measured_text_height(rt, "Selection tint + relief", sample_text_width, scale),
		settings_measured_text_height(rt, "Transparency makes it opaque and removes shadows.", sample_text_width, scale),
	}
	sample_surface_height := settings_column_height(sample_surface_items[:], sample_inner_gap, 8)
	sample_items := [2]f32{sample_surface_height, control_height}
	samples_height := settings_column_height(sample_items[:], sample_gap)

	accessibility_items := [9]f32{
		heading_height,
		settings_measured_checkbox_height(rt, "Use system accessibility preferences", form_text_width, control_height, scale),
		settings_measured_text_height(rt, "Turn this off to apply an app-level override for testing; it does not change OS settings.", form_text_width, scale),
		settings_measured_text_height(rt, "System detected (host values; app overrides below do not change these):", form_text_width, scale),
		settings_measured_text_height(rt, status_summary, form_text_width, scale),
		options_height,
		samples_height,
		settings_measured_text_height(rt, "Tab through controls to inspect focus contrast. The selected sample gains an underline without color differentiation.", form_text_width, scale),
		settings_measured_text_height(rt, "Reduce Motion is forwarded to Alicorn; current controls have no animated style transitions. View → Zoom tests text scaling.", form_text_width, scale),
	}
	accessibility_height := settings_column_height(accessibility_items[:], row_gap)
	editor_preview := "┌─ Editor ───────────┐\n│ Café  λ = 0.1     │\n└────────────────────┘"
	typography_items := [9]f32{
		heading_height,
		max(20, 18*scale),
		control_height,
		max(20, 18*scale),
		control_height,
		settings_measured_text_height(rt, "Editor only; monospaced families first. Preview updates when selected.", form_text_width, scale),
		max(20, 18*scale),
		settings_measured_font_preview_height(rt, editor_preview, form_text_width, editor_font_size*scale),
		control_height,
	}
	typography_height := settings_column_height(typography_items[:], row_gap)
	return [4]f32{appearance_height, workspace_height, accessibility_height, typography_height}
}
settings_accessibility_observed_value :: proc(
	observation: alicorn.Accessibility_Appearance_Observation,
	field: alicorn.Accessibility_Appearance_Field,
	value: bool,
) -> string {
	if field not_in observation.known { return "unsupported / unavailable" }
	return value ? "true" : "false"
}

settings_surface_close :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || !app.settings_surface_open { return }
	app.settings_surface_open = false
	alicorn.invalidate_root(rt, "Scratchpad Settings closed")
}

settings_surface_handle_key :: proc(app: ^App, rt: ^alicorn.Runtime, key: host.Application_Key) -> bool {
	if app == nil || !app.settings_surface_open { return false }
	if key == .Escape {
		settings_surface_close(app, rt)
	}
	return true
}
