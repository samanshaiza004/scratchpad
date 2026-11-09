package main

import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"

SCRATCHPAD_PROMINENT_INPUT_TEXT_STYLE :: alicorn.Text_Style{
	font_weight=alicorn.FONT_WEIGHT_REGULAR,
	font_size=18,
	overflow=.Ellipsis,
}

scratchpad_styles_ensure :: proc(app: ^App, rt: ^alicorn.Runtime) -> bool {
	if app == nil || rt == nil { return false }
	if app.style_theme_runtime != rt {
		app.workbench_theme = 0
		app.editor_theme = 0
		app.warm_workbench_theme = 0
		app.warm_editor_theme = 0
		app.relief_workbench_theme, app.relief_editor_theme = 0, 0
		app.cool_light_theme = 0
		app.paper_surface_material = alicorn.MATERIAL_FLAT
		app.raised_surface_material = alicorn.MATERIAL_FLAT
		app.floating_surface_material = alicorn.MATERIAL_FLAT
		app.relief_materials = {}
		app.style_theme_runtime = rt
	}
	if app.warm_workbench_theme == 0 {
		theme := scratchpad_workbench_theme()
		app.warm_workbench_theme = alicorn.style_theme_register(rt, theme)
		scratchpad_workbench_theme_destroy(&theme)
	}
	if app.warm_editor_theme == 0 {
		theme := scratchpad_editor_theme()
		app.warm_editor_theme = alicorn.style_theme_register(rt, theme)
		scratchpad_editor_theme_destroy(&theme)
	}
	if app.cool_light_theme == 0 {
		theme := scratchpad_cool_light_theme()
		app.cool_light_theme = alicorn.style_theme_register(rt, theme)
		scratchpad_cool_light_theme_destroy(&theme)
	}
	if app.paper_surface_material == alicorn.MATERIAL_FLAT {
		for definition in scratchpad_editor_theme_materials {
			if definition.name == "app.scratchpad.editor.paper" {
				app.paper_surface_material = alicorn.style_material_register(rt, definition.material)
				break
			}
		}
	}
	if app.raised_surface_material == alicorn.MATERIAL_FLAT {
		app.raised_surface_material = alicorn.style_material_register(rt, alicorn.Style_Material{
			kind=.Analytic_Relief, bevel_width=1, bevel_strength=0.42,
			inner_shadow_strength=0.14, outer_shadow_strength=0.18,
			outer_shadow_radius=3,
		})
	}
	if app.floating_surface_material == alicorn.MATERIAL_FLAT {
		app.floating_surface_material = alicorn.style_material_register(rt, alicorn.Style_Material{
			kind=.Analytic_Relief, bevel_width=1.5, bevel_strength=0.48,
			inner_shadow_strength=0.2, outer_shadow_strength=0.36,
			outer_shadow_radius=7,
		})
	}
	if app.theme_choice == .Workbench_Relief && app.relief_workbench_theme == 0 { app.relief_workbench_theme = scratchpad_relief_theme(app, rt, false) }
	if app.theme_choice == .Workbench_Relief && app.relief_editor_theme == 0 { app.relief_editor_theme = scratchpad_relief_theme(app, rt, true) }
	scratchpad_theme_apply_registered(app)
	return app.workbench_theme != 0 && app.editor_theme != 0 &&
		app.paper_surface_material != alicorn.MATERIAL_FLAT &&
		app.raised_surface_material != alicorn.MATERIAL_FLAT &&
		app.floating_surface_material != alicorn.MATERIAL_FLAT
}

scratchpad_theme_apply_registered :: proc(app: ^App) {
	if app == nil { return }
	switch app.theme_choice {
	case .Warm, .Flat:
		app.workbench_theme = app.warm_workbench_theme
		app.editor_theme = app.warm_editor_theme
	case .Workbench_Relief:
		app.workbench_theme = app.relief_workbench_theme
		app.editor_theme = app.relief_editor_theme
	case .Cool_Light:
		app.workbench_theme = app.cool_light_theme
		app.editor_theme = app.cool_light_theme
	}
}

scratchpad_theme_select :: proc(app: ^App, rt: ^alicorn.Runtime, choice: Scratchpad_Theme_Choice) -> bool {
	if app == nil || rt == nil || (choice < .Warm || choice > .Workbench_Relief) { return false }
	if app.theme_choice == choice { return true }
	if !scratchpad_styles_ensure(app, rt) { return false }
	if choice == .Workbench_Relief {
		if app.relief_workbench_theme == 0 { app.relief_workbench_theme = scratchpad_relief_theme(app, rt, false) }
		if app.relief_editor_theme == 0 { app.relief_editor_theme = scratchpad_relief_theme(app, rt, true) }
		if app.relief_workbench_theme == 0 || app.relief_editor_theme == 0 { return false }
	}
	app.theme_choice = choice
	if app.brand_mark != 0 { _ = scratchpad_brand_mark_replace(app, rt, choice) }
	scratchpad_theme_apply_registered(app)
	scratchpad_preferences_save(app)
	alicorn.invalidate_root(rt, "Scratchpad theme preference changed")
	return true
}

scratchpad_editor_paper_surface_role :: proc() -> alicorn.Style_Extension_Color_Role_ID {
	return alicorn.style_extension_color_role_id("app.scratchpad.editor", "paper_surface")
}

scratchpad_editor_active_line_role :: proc() -> alicorn.Style_Extension_Color_Role_ID {
	return alicorn.style_extension_color_role_id("app.scratchpad.editor", "active_line")
}

scratchpad_editor_active_line_gutter_role :: proc() -> alicorn.Style_Extension_Color_Role_ID {
	return alicorn.style_extension_color_role_id("app.scratchpad.editor", "active_line_gutter")
}

scratchpad_modal_backdrop_color :: proc(rt: ^alicorn.Runtime, theme: alicorn.Style_Theme_ID) -> alicorn.Color {
	role := alicorn.style_extension_color_role_id("app.scratchpad.workbench", "modal_backdrop")
	color, found := alicorn.style_extension_color(rt, theme, role)
	if found { return color }
	return alicorn.Color{0.015, 0.02, 0.03, 0.72}
}

SCRATCHPAD_MODAL_BLUR_SIGMA :: 6.0
SCRATCHPAD_MODAL_PANEL_OPACITY :: 0.70
SCRATCHPAD_MODAL_SCRIM_OPACITY :: 0.50

scratchpad_modal_accessibility_preferences :: proc(
	app: ^App,
	rt: ^alicorn.Runtime,
) -> alicorn.Accessibility_Appearance_Preferences {
	if app != nil && app.accessibility_appearance_override_enabled {
		return app.accessibility_appearance
	}
	if rt != nil {
		return alicorn.style_root_accessibility_observation_get(rt).preferences
	}
	if app != nil { return app.accessibility_appearance }
	return {}
}

scratchpad_modal_requires_opaque_surfaces :: proc(app: ^App, rt: ^alicorn.Runtime) -> bool {
	accessibility := scratchpad_modal_accessibility_preferences(app, rt)
	return accessibility.increased_contrast || accessibility.reduce_transparency
}

scratchpad_modal_backdrop_effect :: proc(
	app: ^App,
	rt: ^alicorn.Runtime,
	enabled := true,
) -> alicorn.Backdrop_Effect {
	if !enabled || app == nil || rt == nil || scratchpad_modal_requires_opaque_surfaces(app, rt) {
		return alicorn.BACKDROP_NONE
	}
	return alicorn.backdrop_blur(SCRATCHPAD_MODAL_BLUR_SIGMA, .Direct)
}

scratchpad_modal_overlay_color :: proc(app: ^App, rt: ^alicorn.Runtime) -> alicorn.Color {
	if app == nil || rt == nil { return alicorn.Color{0.015, 0.02, 0.03, 0.72} }
	color := scratchpad_modal_backdrop_color(rt, app.workbench_theme)
	if scratchpad_modal_requires_opaque_surfaces(app, rt) {
		color.a = 1
	} else {
		color.a = SCRATCHPAD_MODAL_SCRIM_OPACITY
	}
	return color
}

scratchpad_modal_panel_fill :: proc(app: ^App, rt: ^alicorn.Runtime, translucent := true) -> alicorn.Color {
	if app == nil || rt == nil { return alicorn.NO_BACKGROUND_COLOR }
	environment := scratchpad_workbench_style_environment(app)
	fill := alicorn.style_environment_color(rt, environment, .Surface)
	if translucent && !scratchpad_modal_requires_opaque_surfaces(app, rt) {
		fill.a = SCRATCHPAD_MODAL_PANEL_OPACITY
	} else {
		fill.a = 1
	}
	return fill
}

scratchpad_modal_surface_begin :: proc(
	ui: ^alicorn.UI,
	app: ^App,
	rt: ^alicorn.Runtime,
	key: alicorn.UI_Key,
	label: string,
	style: alicorn.Layout_Style,
) -> alicorn.Node_ID {
	return alicorn.surface_begin(
		ui,
		alicorn.surface_core_color_role(.Surface),
		key=key,
		label=label,
	style=style,
		shape=scratchpad_surface_shape(app, 6),
		material=scratchpad_surface_material(app, app.floating_surface_material),
		physical_height=scratchpad_surface_height(app, 1),
		fill=scratchpad_modal_panel_fill(app, rt),
		backdrop_effect=scratchpad_modal_backdrop_effect(app, rt),
	)
}

scratchpad_workbench_style_environment :: proc(app: ^App) -> alicorn.Style_Environment {
	if app == nil { return alicorn.Style_Environment{} }
	environment := alicorn.Style_Environment{theme=app.workbench_theme}
	if app.accessibility_appearance_override_enabled {
		environment.accessibility = app.accessibility_appearance
		environment.accessibility_set = true
	}
	return environment
}

// The host continues to own integrated title-bar rendering and behavior; this
// callback only supplies colors from the currently selected workbench theme.
scratchpad_window_chrome_appearance :: proc(state: rawptr, rt: ^alicorn.Runtime) -> host.Window_Chrome_Appearance {
	app := cast(^App)state
	if app == nil || rt == nil || app.workbench_theme == 0 { return {} }
	return host.Window_Chrome_Appearance{
		defined=true,
		background=alicorn.style_theme_color(rt, app.workbench_theme, .Surface),
		foreground=alicorn.style_theme_color(rt, app.workbench_theme, .Text),
	}
}
