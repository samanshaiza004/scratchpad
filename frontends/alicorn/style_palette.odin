package main

import alicorn "alicorn:runtime"

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
		app.cool_light_theme = 0
		app.paper_surface_material = alicorn.MATERIAL_FLAT
		app.raised_surface_material = alicorn.MATERIAL_FLAT
		app.floating_surface_material = alicorn.MATERIAL_FLAT
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
	scratchpad_theme_apply_registered(app)
	return app.workbench_theme != 0 && app.editor_theme != 0 &&
		app.paper_surface_material != alicorn.MATERIAL_FLAT &&
		app.raised_surface_material != alicorn.MATERIAL_FLAT &&
		app.floating_surface_material != alicorn.MATERIAL_FLAT
}

scratchpad_theme_apply_registered :: proc(app: ^App) {
	if app == nil { return }
	switch app.theme_choice {
	case .Warm:
		app.workbench_theme = app.warm_workbench_theme
		app.editor_theme = app.warm_editor_theme
	case .Cool_Light:
		app.workbench_theme = app.cool_light_theme
		app.editor_theme = app.cool_light_theme
	}
}

scratchpad_theme_select :: proc(app: ^App, rt: ^alicorn.Runtime, choice: Scratchpad_Theme_Choice) -> bool {
	if app == nil || rt == nil || (choice != .Warm && choice != .Cool_Light) { return false }
	if app.theme_choice == choice { return true }
	if !scratchpad_styles_ensure(app, rt) { return false }
	app.theme_choice = choice
	scratchpad_theme_apply_registered(app)
	if app.theme_preferences_directory != "" &&
	   !scratchpad_theme_preferences_save(app.theme_preferences_directory, choice) {
		set_error(app, "Theme changed for this session, but Scratchpad could not save the preference.")
	}
	alicorn.invalidate_root(rt, "Scratchpad theme preference changed")
	return true
}

scratchpad_editor_paper_surface_role :: proc() -> alicorn.Style_Extension_Color_Role_ID {
	return alicorn.style_extension_color_role_id("app.scratchpad.editor", "paper_surface")
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
