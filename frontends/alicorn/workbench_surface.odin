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
	card_width := min(520, max(rt.viewport.w-48, 200))
	card_max_height := min(640, max(rt.viewport.h-40, 180))
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

settings_surface_build :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime) {
	if app == nil || ui == nil || rt == nil { return }
	scale := max(rt.style_environment.text_scale, 1)
	panel_width := min(640, max(rt.viewport.w-32, 200))
	panel_height := min(700, max(rt.viewport.h-32, 180))
	header_height := max(32, 28*scale)
	footer_height := max(44, 40*scale)
	control_height := max(34, 30*scale)
	body_height := max(panel_height-36-header_height-footer_height-16, 24)
	content_height := 900*scale

	alicorn.modal_overlay_begin(ui, alicorn.key_string("scratchpad-settings-overlay"), style=alicorn.layout_style(.Column, grow=1, align=.Center, justify=.Center), backdrop_color=alicorn.Color{0.015, 0.02, 0.03, 0.72})
	alicorn.container_begin(ui, .Container, label="scratchpad-settings", style=alicorn.layout_style(.Column, width=panel_width, height=panel_height, padding=18, gap=8, align=.Start, clip=true), color=alicorn.style_color(ui, .Surface))
	alicorn.container_begin(ui, .Container, label="scratchpad-settings-header", style=alicorn.layout_style(.Row, height=header_height, align=.Center))
	alicorn.text(ui, "Settings", style=alicorn.layout_style(.Row, height=header_height, grow=1))
	alicorn.container_end(ui)

	settings_scroll := alicorn.virtual_list_begin(
		ui,
		1,
		content_height,
		key=alicorn.key_string("scratchpad-settings-scroll"),
		style=alicorn.layout_style(.Column, height=body_height, clip=true),
		label="scratchpad-settings-scroll",
		axes=.Vertical,
		focusable=true,
	)
	alicorn.container_begin(ui, .Container, label="scratchpad-settings-scroll-content", style=alicorn.layout_style(.Column, width=-1, height=content_height, padding=2, gap=max(10, 8*scale), align=.Start))
	alicorn.text(ui, "Appearance", style=alicorn.layout_style(.Row, height=max(24, 22*scale)))
	alicorn.text(ui, "Theme", style=alicorn.layout_style(.Row, height=max(22, 20*scale)))
	alicorn.container_begin(ui, .Container, label="settings-theme-choice-row", style=alicorn.layout_style(.Row, height=max(40, 36*scale), gap=8, align=.Center))
	if alicorn.button(ui, "Warm", key=alicorn.key_string("settings-theme-warm"), style=alicorn.layout_style(.Row, grow=1, height=max(38, 34*scale)), state=alicorn.Button_State{selected=app.theme_choice == .Warm}, variant=.Quiet) {
		if !frame_deferred_action_schedule(app, .Action, ACTION_VIEW_THEME_WARM) { set_error(app, "Could not queue the Warm theme change.") }
	}
	if alicorn.button(ui, "Cool Light", key=alicorn.key_string("settings-theme-cool-light"), style=alicorn.layout_style(.Row, grow=1, height=max(38, 34*scale)), state=alicorn.Button_State{selected=app.theme_choice == .Cool_Light}, variant=.Quiet) {
		if !frame_deferred_action_schedule(app, .Action, ACTION_VIEW_THEME_COOL_LIGHT) { set_error(app, "Could not queue the Cool Light theme change.") }
	}
	alicorn.container_end(ui)

	alicorn.text(ui, "Workspace", style=alicorn.layout_style(.Row, height=max(24, 22*scale)))
	ignored_change := alicorn.checkbox(ui, "Show ignored files in the file tree", app.show_ignored_files, key=alicorn.key_string("settings-show-ignored-files"), style=alicorn.layout_style(.Row, height=control_height), disabled=!app.backend.started || !app.backend.state.has_workspace)
	if ignored_change.changed { tree_set_show_ignored_files(app, rt, ignored_change.value) }
	alicorn.text(ui, "Workspace search continues to honor ignore rules.", style=alicorn.layout_style(.Row, height=alicorn.LAYOUT_SIZE_FIT_CONTENT), text_style=alicorn.Text_Style{overflow=.Wrap})

	alicorn.text(ui, "Accessibility appearance", style=alicorn.layout_style(.Row, height=max(24, 22*scale)))
	system_preferences_change := alicorn.checkbox(ui, "Use system accessibility preferences", !app.accessibility_appearance_override_enabled, key=alicorn.key_string("settings-accessibility-use-system"), style=alicorn.layout_style(.Row, height=control_height))
	if system_preferences_change.changed {
		app.accessibility_appearance_override_enabled = !system_preferences_change.value
		alicorn.invalidate_root(rt, "Scratchpad accessibility appearance source changed")
	}
	alicorn.text(ui, "Turn this off to apply an app-level override for testing; it does not change OS settings.", style=alicorn.layout_style(.Row, height=alicorn.LAYOUT_SIZE_FIT_CONTENT), text_style=alicorn.Text_Style{overflow=.Wrap})

	host_appearance := alicorn.style_root_accessibility_observation_get(rt)
	alicorn.text(ui, "System detected (host values; app overrides below do not change these):", style=alicorn.layout_style(.Row, height=alicorn.LAYOUT_SIZE_FIT_CONTENT), text_style=alicorn.Text_Style{overflow=.Wrap})
	alicorn.text(ui, fmt.tprintf(
		"Contrast: %s  ·  Reduce motion: %s  ·  Reduce transparency: %s  ·  Differentiate without color: %s",
		settings_accessibility_observed_value(host_appearance, .Increased_Contrast, host_appearance.preferences.increased_contrast),
		settings_accessibility_observed_value(host_appearance, .Reduce_Motion, host_appearance.preferences.reduce_motion),
		settings_accessibility_observed_value(host_appearance, .Reduce_Transparency, host_appearance.preferences.reduce_transparency),
		settings_accessibility_observed_value(host_appearance, .Differentiate_Without_Color, host_appearance.preferences.differentiate_without_color),
	), style=alicorn.layout_style(.Row, height=alicorn.LAYOUT_SIZE_FIT_CONTENT), text_style=alicorn.Text_Style{overflow=.Wrap})

	alicorn.container_begin(ui, .Container, label="settings-accessibility-options", style=alicorn.layout_style(.Column, gap=4, align=.Start))
	contrast_change := alicorn.checkbox(ui, "Increase contrast", app.accessibility_appearance.increased_contrast, key=alicorn.key_string("settings-accessibility-increased-contrast"), style=alicorn.layout_style(.Row, height=control_height), disabled=!app.accessibility_appearance_override_enabled)
	if contrast_change.changed {
		app.accessibility_appearance.increased_contrast = contrast_change.value
		alicorn.invalidate_root(rt, "Scratchpad increased-contrast preference changed")
	}
	motion_change := alicorn.checkbox(ui, "Reduce motion", app.accessibility_appearance.reduce_motion, key=alicorn.key_string("settings-accessibility-reduce-motion"), style=alicorn.layout_style(.Row, height=control_height), disabled=!app.accessibility_appearance_override_enabled)
	if motion_change.changed {
		app.accessibility_appearance.reduce_motion = motion_change.value
		alicorn.invalidate_root(rt, "Scratchpad reduce-motion preference changed")
	}
	transparency_change := alicorn.checkbox(ui, "Reduce transparency", app.accessibility_appearance.reduce_transparency, key=alicorn.key_string("settings-accessibility-reduce-transparency"), style=alicorn.layout_style(.Row, height=control_height), disabled=!app.accessibility_appearance_override_enabled)
	if transparency_change.changed {
		app.accessibility_appearance.reduce_transparency = transparency_change.value
		alicorn.invalidate_root(rt, "Scratchpad reduce-transparency preference changed")
	}
	differentiate_change := alicorn.checkbox(ui, "Differentiate without color", app.accessibility_appearance.differentiate_without_color, key=alicorn.key_string("settings-accessibility-differentiate-without-color"), style=alicorn.layout_style(.Row, height=control_height), disabled=!app.accessibility_appearance_override_enabled)
	if differentiate_change.changed {
		app.accessibility_appearance.differentiate_without_color = differentiate_change.value
		alicorn.invalidate_root(rt, "Scratchpad differentiate-without-color preference changed")
	}
	alicorn.container_end(ui)

	alicorn.container_begin(ui, .Container, label="settings-appearance-samples", style=alicorn.layout_style(.Column, gap=8, align=.Start))
	alicorn.surface_begin(ui, alicorn.surface_core_color_role(.Selection), key=alicorn.key_string("settings-accessibility-material-sample"), label="settings-accessibility-material-sample", style=alicorn.layout_style(.Column, width=-1, height=alicorn.LAYOUT_SIZE_FIT_CONTENT, padding=9, gap=6, align=.Start), material=app.floating_surface_material, physical_height=0.5)
	alicorn.text(ui, "Selection tint + relief")
	alicorn.text(ui, "Transparency makes it opaque and removes shadows.", style=alicorn.layout_style(.Row, height=alicorn.LAYOUT_SIZE_FIT_CONTENT), text_style=alicorn.Text_Style{overflow=.Wrap})
	alicorn.surface_end(ui)
	if alicorn.button(ui, "Selected state sample", key=alicorn.key_string("settings-accessibility-selected-sample"), style=alicorn.layout_style(.Row, width=min(260*scale, panel_width-72), height=control_height), state=alicorn.Button_State{selected=true}, variant=.Quiet) {
		// This sample has no action; selection is held to expose the recipe's
		// non-color indicator while the preference is toggled.
	}
	alicorn.container_end(ui)

	alicorn.text(ui, "Tab through controls to inspect focus contrast. The selected sample gains an underline without color differentiation.", style=alicorn.layout_style(.Row, height=alicorn.LAYOUT_SIZE_FIT_CONTENT), text_style=alicorn.Text_Style{overflow=.Wrap})
	alicorn.text(ui, "Reduce Motion is forwarded to Alicorn; current controls have no animated style transitions. View → Zoom tests text scaling.", style=alicorn.layout_style(.Row, height=alicorn.LAYOUT_SIZE_FIT_CONTENT), text_style=alicorn.Text_Style{overflow=.Wrap})
	alicorn.container_end(ui)
	alicorn.virtual_list_end(ui, settings_scroll)

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
