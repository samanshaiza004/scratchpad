package main

import "core:fmt"
import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"

Settings_Category :: enum { Appearance, Editor, Workspace, Accessibility }

SETTINGS_CATEGORY_NAMES :: [Settings_Category]string{
	.Appearance="Appearance", .Editor="Editor", .Workspace="Workspace", .Accessibility="Accessibility",
}
SETTINGS_EDITOR_PREVIEW :: "Aa Bb Cc    0O 1lI\nThe quick brown fox jumps over the lazy dog.\nfn main() { let total = 123.456; }"

// Scroll_Region requires a declared logical extent. The same small page
// description measures and emits its rows, keeping strings and spacing in one
// place. All rows are retained; a four-page settings form needs no virtualization.
Settings_Form :: struct {
	ui: ^alicorn.UI,
	rt: ^alicorn.Runtime,
	width, scale, gap, height: f32,
	rows: int,
}

settings_form_row :: proc(form: ^Settings_Form, height: f32) -> alicorn.Layout_Style {
	if form.rows > 0 { form.height += form.gap }
	form.rows += 1
	form.height += height
	return alicorn.layout_style(.Row, width=-1, height=height)
}

settings_text_height :: proc(rt: ^alicorn.Runtime, value: string, width, size: f32, font := alicorn.Font_Role.UI, weight := alicorn.FONT_WEIGHT_REGULAR, overflow := alicorn.Text_Overflow.Wrap) -> f32 {
	run, ok := alicorn.runtime_text_run_build(rt, value, size, max(width, 1), font=font, font_weight=weight, overflow=overflow)
	if ok {
		height := run.height
		alicorn.text_run_destroy(&run)
		return height
	}
	return size*1.5
}

settings_form_text :: proc(form: ^Settings_Form, key, value: string, size: f32 = 16, weight := alicorn.FONT_WEIGHT_REGULAR) {
	height := settings_text_height(form.rt, value, form.width, size*form.scale, weight=weight)
	style := settings_form_row(form, height)
	if form.ui != nil {
		alicorn.text(form.ui, value, key=alicorn.key_string(key), style=style, text_style=alicorn.Text_Style{font_size=size, font_weight=weight, overflow=.Wrap})
	}
}

settings_form_checkbox :: proc(form: ^Settings_Form, key, label: string, value: bool, disabled := false) -> alicorn.Control_Change_Bool {
	height := max(44, settings_text_height(form.rt, label, form.width-36, 16*form.scale)+12)
	style := settings_form_row(form, height)
	if form.ui == nil { return alicorn.Control_Change_Bool{value=value} }
	return alicorn.checkbox(form.ui, label, value, key=alicorn.key_string(key), style=style, disabled=disabled)
}

settings_category_select :: proc(app: ^App, rt: ^alicorn.Runtime, category: Settings_Category) {
	if app.settings_category == category { return }
	app.settings_category = category
	if scroll, found := alicorn.node_by_key(rt, alicorn.key_string("scratchpad-settings-scroll"), .Scroll_Region); found {
		_ = alicorn.scroll_region_set_offset(rt, scroll, 0, "Scratchpad Settings category changed")
	}
	alicorn.invalidate_root(rt, "Scratchpad Settings category changed")
}

settings_surface_build :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime, text_scale: f32 = 1) {
	if app == nil || ui == nil || rt == nil { return }
	scale := max(text_scale, 1)
	viewport := alicorn.viewport_bounds(rt)
	panel_width := min(1440, max(viewport.w-48, 1))
	panel_height := min(1040, max(viewport.h-48, 1))
	padding := f32(20)
	gap := f32(12)
	control_height := max(44, 30*scale)
	wide := panel_width >= 760*scale
	navigation_width := f32(200)*scale
	content_width := panel_width-2*padding
	if wide { content_width -= navigation_width+gap }
	// Always reserve the vertical scrollbar lane: switching pages cannot change
	// the width used for measurement or create a scrollbar/wrapping feedback loop.
	form_width := min(920, max(content_width-32-alicorn.SCROLLBAR_THICKNESS, 1))
	names := SETTINGS_CATEGORY_NAMES

	alicorn.modal_overlay_begin(ui, alicorn.key_string("scratchpad-settings-overlay"), style=alicorn.layout_style(.Column, grow=1, align=.Center, justify=.Center), backdrop_color=alicorn.Color{0.015, 0.02, 0.03, 0.72})
	alicorn.surface_begin(ui, alicorn.surface_core_color_role(.Surface), key=alicorn.key_string("scratchpad-settings"), label="scratchpad-settings", style=alicorn.layout_style(.Column, width=panel_width, height=panel_height, padding=padding, gap=gap, clip=true), shape=scratchpad_surface_shape(app, 6), material=scratchpad_surface_material(app, app.floating_surface_material), physical_height=scratchpad_surface_height(app, 1))
	alicorn.container_begin(ui, .Container, label="scratchpad-settings-header", style=alicorn.layout_style(.Row, height=max(48, 30*scale), align=.Center))
	alicorn.text(ui, "Settings", key=alicorn.key_string("settings-heading"), style=alicorn.layout_style(.Row, grow=1), text_style=alicorn.Text_Style{font_size=24, font_weight=alicorn.FONT_WEIGHT_SEMIBOLD, overflow=.Ellipsis})
	alicorn.container_end(ui)
	alicorn.container_begin(ui, .Container, label="scratchpad-settings-body", style=alicorn.layout_style(wide ? .Row : .Column, grow=1, gap=gap, clip=true))
	if wide {
		alicorn.surface_begin(ui, alicorn.surface_core_color_role(.Subtle_Surface), key=alicorn.key_string("settings-navigation"), label="settings-navigation", style=alicorn.layout_style(.Column, width=navigation_width, padding=8, gap=6), shape=scratchpad_surface_shape(app, 4), material=scratchpad_surface_material(app, app.raised_surface_material), physical_height=scratchpad_surface_height(app, 0.25))
		for category in Settings_Category {
			if alicorn.button(ui, names[category], key=alicorn.key_string(fmt.tprintf("settings-category-%d", category)), style=alicorn.layout_style(.Row, width=-1, height=control_height), state=alicorn.Button_State{selected=app.settings_category == category}, content_style=alicorn.button_content_style(.Start, padding_x=12), variant=.Quiet) {
				settings_category_select(app, rt, category)
			}
		}
		alicorn.surface_end(ui)
	} else {
		options: [4]alicorn.Select_Option
		for category in Settings_Category { options[int(category)] = alicorn.Select_Option{key=u64(category)+1, label=names[category]} }
		choice := alicorn.select_control(ui, alicorn.key_string("settings-category-select"), "Settings category", options[:], u64(app.settings_category)+1, style=alicorn.layout_style(.Row, width=-1, height=control_height))
		if choice.changed { settings_category_select(app, rt, Settings_Category(choice.selected_key-1)) }
	}
	form := Settings_Form{rt=rt, width=form_width, scale=scale, gap=max(16, 12*scale)}
	settings_page_build(app, &form)
	content_height := form.height
	region := alicorn.scroll_region_begin(ui, key=alicorn.key_string("scratchpad-settings-scroll"), content_height=content_height, line_height=32, style=alicorn.layout_style(.Column, grow=1, padding=16, clip=true), label="scratchpad-settings-scroll", axes=.Vertical, scrollbars=.Always, focusable=true)
	alicorn.container_begin(ui, .Virtual_List, key=alicorn.key_string("settings-form"), label="settings-form", style=alicorn.layout_style(.Column, width=form_width, height=content_height, gap=form.gap), scroll_offset_y=region.offset_y)
	form.ui = ui
	form.height, form.rows = 0, 0
	settings_page_build(app, &form)
	alicorn.container_end(ui)
	alicorn.scroll_region_end(ui)
	alicorn.container_end(ui)
	alicorn.container_begin(ui, .Container, label="scratchpad-settings-footer", style=alicorn.layout_style(.Row, height=control_height, gap=12, align=.Center))
	alicorn.text(ui, "Changes apply immediately", key=alicorn.key_string("settings-save-note"), style=alicorn.layout_style(.Row, grow=1), text_style=alicorn.Text_Style{overflow=.Ellipsis})
	if alicorn.button(ui, "Done", key=alicorn.key_string("settings-done"), style=alicorn.layout_style(.Row, width=max(96, 80*scale), height=control_height)) { settings_surface_close(app, rt) }
	alicorn.container_end(ui)
	alicorn.surface_end(ui)
	alicorn.modal_overlay_end(ui)
}

settings_page_build :: proc(app: ^App, form: ^Settings_Form) {
	ui, rt := form.ui, form.rt
	control_height := max(44, 30*form.scale)
	switch app.settings_category {
	case .Appearance:
		settings_form_text(form, "settings-page-title", "Appearance", 24, alicorn.FONT_WEIGHT_SEMIBOLD)
		settings_form_text(form, "settings-appearance-note", "Choose the colors and surface treatment used by the workbench and document editor.")
		settings_form_text(form, "settings-theme-heading", "Workbench appearance", 18, alicorn.FONT_WEIGHT_MEDIUM)
		style := settings_form_row(form, control_height)
		if ui != nil {
			options := [?]alicorn.Select_Option{{key=1, label="Warm"}, {key=2, label="Cool Light"}, {key=3, label="Flat Workbench"}, {key=4, label="Workbench Relief (Experimental)"}}
			choice := alicorn.select_control(ui, alicorn.key_string("settings-workbench-appearance"), "Workbench appearance", options[:], u64(app.theme_choice)+1, style=style)
			if choice.changed {
				actions := [?]string{ACTION_VIEW_THEME_WARM, ACTION_VIEW_THEME_COOL_LIGHT, ACTION_VIEW_THEME_FLAT, ACTION_VIEW_THEME_RELIEF}
				if !frame_deferred_action_schedule(app, .Action, actions[choice.selected_key-1]) { set_error(app, "Could not queue the workbench appearance.") }
			}
		}
		settings_form_text(form, "settings-theme-persistence-note", "Your theme is saved for the next time you open Scratchpad.")
	case .Editor:
		settings_form_text(form, "settings-page-title", "Editor", 24, alicorn.FONT_WEIGHT_SEMIBOLD)
		settings_form_text(form, "settings-semantic-zoom-label", "Semantic zoom wheel gesture", 18, alicorn.FONT_WEIGHT_MEDIUM)
		zoom_style := settings_form_row(form, control_height)
		if ui != nil {
			options := [?]alicorn.Select_Option{{key=1, label="Ctrl/Cmd + Alt/Option + wheel"}, {key=2, label="Ctrl/Cmd + Shift + wheel"}, {key=3, label="Disabled"}}
			choice := alicorn.select_control(ui, alicorn.key_string("settings-semantic-zoom-wheel"), "Semantic zoom wheel gesture", options[:], u64(app.semantic_zoom_wheel)+1, style=zoom_style)
			if choice.changed { app.semantic_zoom_wheel = Semantic_Zoom_Wheel(choice.selected_key-1); scratchpad_preferences_save(app); alicorn.invalidate_root(rt, "semantic zoom gesture changed") }
		}
		settings_form_text(form, "settings-semantic-zoom-note", "Changes source visibility through Full, Focus, Skim, and Overview. Font zoom keeps its existing shortcuts.")
		settings_form_text(form, "settings-editor-font-note", "Choose a font for your documents. The workbench font stays the same.")
		settings_form_text(form, "settings-editor-font-family-label", "Font family", 18, alicorn.FONT_WEIGHT_MEDIUM)
		family := app.editor_font_family
		if family == "" { family = "Atkinson Hyperlegible Mono" }
		style := settings_form_row(form, max(control_height, settings_text_height(rt, family, form.width-48, 18*form.scale, overflow=.Ellipsis)+20))
		if ui != nil {
			style.padding, style.gap, style.align = 10, 10, .Center
			button, clicked := alicorn.button_begin(ui, "", key=alicorn.key_string("settings-editor-font-family"), style=style, variant=.Default)
			if button != 0 {
				_ = alicorn.semantic_description(ui, .Button, fmt.tprintf("Choose editor font family: %s", family), actions=alicorn.semantic_actions_add({}, .Press))
				alicorn.text(ui, family, key=alicorn.key_string("settings-editor-font-family-value"), style=alicorn.layout_style(.Row, grow=1), text_style=alicorn.Text_Style{font_size=18, overflow=.Ellipsis})
				_ = alicorn.icon(ui, .Chevron_Down, key=alicorn.key_string("settings-editor-font-family-chevron"), size=18)
				alicorn.button_end(ui)
			}
			if clicked { scratchpad_editor_font_picker_open(app, rt) }
		}
		settings_form_text(form, "settings-editor-font-size-label", "Font size", 18, alicorn.FONT_WEIGHT_MEDIUM)
		size_control_height := max(control_height, settings_text_height(rt, "16.0 px", form.width, 16*form.scale)+20)
		style = settings_form_row(form, size_control_height)
		size := scratchpad_editor_font_size(app)
		if ui != nil {
			style.gap, style.align = 8, .Center
			alicorn.container_begin(ui, .Container, label="settings-editor-font-size-controls", style=style)
			if alicorn.button(ui, "−", key=alicorn.key_string("settings-editor-font-size-down"), style=alicorn.layout_style(.Row, width=control_height, height=control_height), state=alicorn.Button_State{disabled=size <= EDITOR_FONT_SIZE_MIN}) { _ = scratchpad_editor_font_request(app, rt, app.editor_font_family, max(EDITOR_FONT_SIZE_MIN, size-1)) }
			alicorn.container_begin(ui, .Container, label="settings-editor-font-size-display", style=alicorn.layout_style(.Row, grow=1, height=size_control_height, padding=10, align=.Center), color=alicorn.style_color(ui, .Subtle_Surface))
			alicorn.text(ui, fmt.tprintf("%.1f px", size), key=alicorn.key_string("settings-editor-font-size-value"), style=alicorn.layout_style(.Row, grow=1), text_style=alicorn.Text_Style{overflow=.Ellipsis})
			alicorn.container_end(ui)
			if alicorn.button(ui, "+", key=alicorn.key_string("settings-editor-font-size-up"), style=alicorn.layout_style(.Row, width=control_height, height=control_height), state=alicorn.Button_State{disabled=size >= EDITOR_FONT_SIZE_MAX}) { _ = scratchpad_editor_font_request(app, rt, app.editor_font_family, min(EDITOR_FONT_SIZE_MAX, size+1)) }
			alicorn.container_end(ui)
		}
		preview_label_height := settings_text_height(rt, "Preview", form.width-32, 16*form.scale)
		preview_height := settings_text_height(rt, SETTINGS_EDITOR_PREVIEW, form.width-32, size*form.scale, .Monospace)
		style = settings_form_row(form, preview_label_height+preview_height+44)
		if ui != nil {
			style.direction, style.padding, style.gap = .Column, 16, 12
			alicorn.surface_begin(ui, alicorn.surface_core_color_role(.Subtle_Surface), key=alicorn.key_string("settings-editor-font-preview-surface"), label="settings-editor-font-preview-surface", style=style, shape=scratchpad_surface_shape(app, 4), material=scratchpad_surface_material(app, app.raised_surface_material), physical_height=scratchpad_surface_height(app, 0.25))
			alicorn.text(ui, "Preview", key=alicorn.key_string("settings-editor-font-preview-label"), style=alicorn.layout_style(.Row, width=-1, height=preview_label_height))
			alicorn.text(ui, SETTINGS_EDITOR_PREVIEW, key=alicorn.key_string("settings-editor-font-preview"), style=alicorn.layout_style(.Row, width=-1, height=preview_height), font=.Monospace, text_style=alicorn.Text_Style{font_size=size, overflow=.Wrap})
			alicorn.surface_end(ui)
		}
		style = settings_form_row(form, control_height)
		if ui != nil {
			style.width = min(form.width, max(180, 150*form.scale))
			if alicorn.button(ui, "Reset to default", key=alicorn.key_string("settings-editor-font-reset"), style=style) { _ = scratchpad_editor_font_request(app, rt, "", EDITOR_FONT_SIZE_DEFAULT) }
		}
	case .Workspace:
		settings_form_text(form, "settings-page-title", "Workspace", 24, alicorn.FONT_WEIGHT_SEMIBOLD)
		settings_form_text(form, "settings-workspace-note", "Control which files are visible in the file tree.")
		change := settings_form_checkbox(form, "settings-show-ignored-files", "Show ignored files", app.show_ignored_files, !app.backend.started || !app.backend.state.has_workspace)
		if change.changed { tree_set_show_ignored_files(app, rt, change.value) }
		settings_form_text(form, "settings-workspace-search-note", "Workspace search continues to honor ignore rules.")
	case .Accessibility:
		settings_form_text(form, "settings-page-title", "Accessibility", 24, alicorn.FONT_WEIGHT_SEMIBOLD)
		settings_form_text(form, "settings-accessibility-override-note", "Follow your system appearance preferences, or adjust them for Scratchpad.")
		change := settings_form_checkbox(form, "settings-accessibility-use-system", "Use system accessibility preferences", !app.accessibility_appearance_override_enabled)
		if change.changed { app.accessibility_appearance_override_enabled = !change.value; alicorn.invalidate_root(rt, "Scratchpad accessibility appearance source changed") }
		observation := alicorn.style_root_accessibility_observation_get(rt)
		preferences := app.accessibility_appearance
		if !app.accessibility_appearance_override_enabled { preferences = observation.preferences }
		disabled := !app.accessibility_appearance_override_enabled
		contrast := settings_form_checkbox(form, "settings-accessibility-increased-contrast", "Increase contrast", preferences.increased_contrast, disabled)
		motion := settings_form_checkbox(form, "settings-accessibility-reduce-motion", "Reduce motion", preferences.reduce_motion, disabled)
		transparency := settings_form_checkbox(form, "settings-accessibility-reduce-transparency", "Reduce transparency", preferences.reduce_transparency, disabled)
		differentiate := settings_form_checkbox(form, "settings-accessibility-differentiate-without-color", "Differentiate without color", preferences.differentiate_without_color, disabled)
		if contrast.changed || motion.changed || transparency.changed || differentiate.changed {
			app.accessibility_appearance = alicorn.Accessibility_Appearance_Preferences{increased_contrast=contrast.value, reduce_motion=motion.value, reduce_transparency=transparency.value, differentiate_without_color=differentiate.value}
			alicorn.invalidate_root(rt, "Scratchpad accessibility preferences changed")
		}
		settings_form_text(form, "settings-accessibility-scope-note", "These controls affect Scratchpad only. Your operating system settings are unchanged.")
	}
}

settings_surface_close :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || !app.settings_surface_open { return }
	app.settings_surface_open = false
	alicorn.invalidate_root(rt, "Scratchpad Settings closed")
}

settings_surface_handle_key :: proc(app: ^App, rt: ^alicorn.Runtime, key: host.Application_Key) -> bool {
	if app == nil || !app.settings_surface_open { return false }
	if key == .Escape { settings_surface_close(app, rt) }
	return true
}
