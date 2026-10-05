package main

import alicorn "alicorn:runtime"

scratchpad_styles_ensure :: proc(app: ^App, rt: ^alicorn.Runtime) -> bool {
	if app == nil || rt == nil { return false }
	if app.style_theme_runtime != rt {
		app.workbench_theme = 0
		app.editor_theme = 0
		app.paper_surface_material = alicorn.MATERIAL_FLAT
		app.raised_surface_material = alicorn.MATERIAL_FLAT
		app.floating_surface_material = alicorn.MATERIAL_FLAT
		app.style_theme_runtime = rt
	}
	if app.workbench_theme == 0 {
		theme := scratchpad_workbench_theme()
		app.workbench_theme = alicorn.style_theme_register(rt, theme)
		scratchpad_workbench_theme_destroy(&theme)
	}
	if app.editor_theme == 0 {
		theme := scratchpad_editor_theme()
		app.editor_theme = alicorn.style_theme_register(rt, theme)
		scratchpad_editor_theme_destroy(&theme)
	}
	if app.paper_surface_material == alicorn.MATERIAL_FLAT {
		app.paper_surface_material = alicorn.style_material_register(rt, alicorn.Style_Material{
			kind=.Analytic_Relief, bevel_width=1, bevel_strength=0.16,
			inner_shadow_strength=0.12,
		})
	}
	if app.raised_surface_material == alicorn.MATERIAL_FLAT {
		app.raised_surface_material = alicorn.style_material_register(rt, alicorn.Style_Material{
			kind=.Analytic_Relief, bevel_width=1, bevel_strength=0.12,
			inner_shadow_strength=0.04, outer_shadow_strength=0.08,
			outer_shadow_radius=2,
		})
	}
	if app.floating_surface_material == alicorn.MATERIAL_FLAT {
		app.floating_surface_material = alicorn.style_material_register(rt, alicorn.Style_Material{
			kind=.Analytic_Relief, bevel_width=1.5, bevel_strength=0.16,
			inner_shadow_strength=0.06, outer_shadow_strength=0.28,
			outer_shadow_radius=7,
		})
	}
	return app.workbench_theme != 0 && app.editor_theme != 0 &&
		app.paper_surface_material != alicorn.MATERIAL_FLAT &&
		app.raised_surface_material != alicorn.MATERIAL_FLAT &&
		app.floating_surface_material != alicorn.MATERIAL_FLAT
}

scratchpad_editor_paper_surface_role :: proc() -> alicorn.Style_Extension_Color_Role_ID {
	return alicorn.style_extension_color_role_id("app.scratchpad.editor", "paper_surface")
}
