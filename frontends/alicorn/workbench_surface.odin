package main

import "core:fmt"
import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"

build_start_screen :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime) {
	if app == nil || ui == nil || rt == nil { return }
	alicorn.container_begin(ui, .Container, label="scratchpad-start-screen", style=alicorn.layout_style(.Column, grow=1, align=.Center, gap=12))
	alicorn.container_begin(ui, .Container, label="scratchpad-start-content", style=alicorn.layout_style(.Column, width=360, padding=28, gap=12), color=alicorn.style_color(ui, .Surface))
	alicorn.text(ui, "Scratchpad")
	alicorn.text(ui, "Open a file or choose a workspace to get started.")
	alicorn.container_begin(ui, .Container, label="scratchpad-start-actions", style=alicorn.layout_style(.Row, height=38, gap=8))
	if alicorn.button(ui, "Open File…", key=alicorn.key_string("start-open-file"), style=alicorn.layout_style(.Row, grow=1, height=36)) {
		dispatch_action(app, rt, ACTION_FILE_OPEN)
	}
	if alicorn.button(ui, "Open Folder…", key=alicorn.key_string("start-open-folder"), style=alicorn.layout_style(.Row, grow=1, height=36)) {
		dispatch_action(app, rt, ACTION_WORKSPACE_OPEN)
	}
	alicorn.container_end(ui)
	if alicorn.button(ui, "Command Palette…", key=alicorn.key_string("start-command-palette"), style=alicorn.layout_style(.Row, width=304, height=36)) {
		command_palette_open_surface(app, rt)
	}
	alicorn.container_end(ui)
	alicorn.container_end(ui)
}

settings_surface_build :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime) {
	if app == nil || ui == nil || rt == nil { return }
	alicorn.modal_overlay_begin(ui, alicorn.key_string("scratchpad-settings-overlay"), style=alicorn.layout_style(.Column, grow=1, align=.Center), backdrop_color=alicorn.Color{0.015, 0.02, 0.03, 0.72})
	alicorn.container_begin(ui, .Container, label="scratchpad-settings", style=alicorn.layout_style(.Column, width=560, height=580, padding=22, gap=8, align=.Start, clip=true), color=alicorn.style_color(ui, .Surface))
	alicorn.text(ui, "Settings")
	alicorn.text(ui, "Workspace")
	ignored_change := alicorn.checkbox(
		ui,
		"Show ignored files in the file tree",
		app.show_ignored_files,
		key=alicorn.key_string("settings-show-ignored-files"),
		style=alicorn.layout_style(.Row, height=30),
		disabled=!app.backend.started || !app.backend.state.has_workspace,
	)
	if ignored_change.changed {
		tree_set_show_ignored_files(app, rt, ignored_change.value)
	}
	alicorn.text(ui, "Workspace search continues to honor ignore rules.")
	alicorn.text(ui, "Accessibility appearance")
	system_preferences_change := alicorn.checkbox(
		ui,
		"Use system accessibility preferences",
		!app.accessibility_appearance_override_enabled,
		key=alicorn.key_string("settings-accessibility-use-system"),
		style=alicorn.layout_style(.Row, height=30),
	)
	if system_preferences_change.changed {
		app.accessibility_appearance_override_enabled = !system_preferences_change.value
		alicorn.invalidate_root(rt, "Scratchpad accessibility appearance source changed")
	}
	alicorn.text(ui, "Turn this off to apply an app-level override for testing; it does not change OS settings.", style=alicorn.layout_style(.Row, height=36), text_style=alicorn.Text_Style{overflow=.Wrap})

	host_appearance := alicorn.style_root_accessibility_observation_get(rt)
	alicorn.text(ui, "System detected (host values; app overrides below do not change these):")
	alicorn.text(ui, fmt.tprintf(
		"Contrast: %s  ·  Reduce motion: %s  ·  Reduce transparency: %s  ·  Differentiate without color: %s",
		settings_accessibility_observed_value(host_appearance, .Increased_Contrast, host_appearance.preferences.increased_contrast),
		settings_accessibility_observed_value(host_appearance, .Reduce_Motion, host_appearance.preferences.reduce_motion),
		settings_accessibility_observed_value(host_appearance, .Reduce_Transparency, host_appearance.preferences.reduce_transparency),
		settings_accessibility_observed_value(host_appearance, .Differentiate_Without_Color, host_appearance.preferences.differentiate_without_color),
	), style=alicorn.layout_style(.Row, height=36), text_style=alicorn.Text_Style{overflow=.Wrap})

	alicorn.container_begin(ui, .Container, label="settings-accessibility-row-one", style=alicorn.layout_style(.Row, height=28, gap=6, align=.Center))
	contrast_change := alicorn.checkbox(
		ui,
		"Increase contrast",
		app.accessibility_appearance.increased_contrast,
		key=alicorn.key_string("settings-accessibility-increased-contrast"),
		style=alicorn.layout_style(.Row, width=252, height=28),
		disabled=!app.accessibility_appearance_override_enabled,
	)
	if contrast_change.changed {
		app.accessibility_appearance.increased_contrast = contrast_change.value
		alicorn.invalidate_root(rt, "Scratchpad increased-contrast preference changed")
	}
	motion_change := alicorn.checkbox(
		ui,
		"Reduce motion",
		app.accessibility_appearance.reduce_motion,
		key=alicorn.key_string("settings-accessibility-reduce-motion"),
		style=alicorn.layout_style(.Row, width=252, height=28),
		disabled=!app.accessibility_appearance_override_enabled,
	)
	if motion_change.changed {
		app.accessibility_appearance.reduce_motion = motion_change.value
		alicorn.invalidate_root(rt, "Scratchpad reduce-motion preference changed")
	}
	alicorn.container_end(ui)
	alicorn.container_begin(ui, .Container, label="settings-accessibility-row-two", style=alicorn.layout_style(.Row, height=28, gap=6, align=.Center))
	transparency_change := alicorn.checkbox(
		ui,
		"Reduce transparency",
		app.accessibility_appearance.reduce_transparency,
		key=alicorn.key_string("settings-accessibility-reduce-transparency"),
		style=alicorn.layout_style(.Row, width=252, height=28),
		disabled=!app.accessibility_appearance_override_enabled,
	)
	if transparency_change.changed {
		app.accessibility_appearance.reduce_transparency = transparency_change.value
		alicorn.invalidate_root(rt, "Scratchpad reduce-transparency preference changed")
	}
	differentiate_change := alicorn.checkbox(
		ui,
		"Differentiate without color",
		app.accessibility_appearance.differentiate_without_color,
		key=alicorn.key_string("settings-accessibility-differentiate-without-color"),
		style=alicorn.layout_style(.Row, width=252, height=28),
		disabled=!app.accessibility_appearance_override_enabled,
	)
	if differentiate_change.changed {
		app.accessibility_appearance.differentiate_without_color = differentiate_change.value
		alicorn.invalidate_root(rt, "Scratchpad differentiate-without-color preference changed")
	}
	alicorn.container_end(ui)

	alicorn.container_begin(ui, .Container, label="settings-appearance-samples", style=alicorn.layout_style(.Row, height=78, gap=12, align=.Center))
	alicorn.surface_begin(
		ui,
		alicorn.surface_core_color_role(.Selection),
		key=alicorn.key_string("settings-accessibility-material-sample"),
		label="settings-accessibility-material-sample",
		style=alicorn.layout_style(.Column, width=220, height=62, padding=9, gap=2, align=.Start),
		material=app.floating_surface_material,
		physical_height=0.5,
	)
	alicorn.text(ui, "Selection tint + relief")
	alicorn.text(ui, "Transparency makes it opaque and removes shadows.", text_style=alicorn.Text_Style{overflow=.Wrap})
	alicorn.surface_end(ui)
	if alicorn.button(
		ui,
		"Selected state sample",
		key=alicorn.key_string("settings-accessibility-selected-sample"),
		style=alicorn.layout_style(.Row, width=204, height=36),
		state=alicorn.Button_State{selected=true},
		variant=.Quiet,
	) {
		// This sample has no action; selection is held to expose the recipe's
		// non-color indicator while the preference is toggled.
	}
	alicorn.container_end(ui)
	alicorn.text(ui, "Tab through controls to inspect focus contrast. The selected sample gains an underline without color differentiation.", style=alicorn.layout_style(.Row, height=36), text_style=alicorn.Text_Style{overflow=.Wrap})
	alicorn.text(ui, "Reduce Motion is forwarded to Alicorn; current controls have no animated style transitions. View → Zoom tests text scaling.", style=alicorn.layout_style(.Row, height=36), text_style=alicorn.Text_Style{overflow=.Wrap})
	alicorn.container_begin(ui, .Container, label="scratchpad-settings-actions", style=alicorn.layout_style(.Row, grow=1, align=.End))
	if alicorn.button(ui, "Done", key=alicorn.key_string("settings-done"), style=alicorn.layout_style(.Row, width=88, height=34)) {
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
