package main

import alicorn "alicorn:runtime"

// Application vocabulary: these optical relationships do not add widget roles,
// layout, interaction nodes, or compositor depth.
Scratchpad_Optical_Relationship :: enum { Recessed, Groove, Flush, Mounted, Floating }

Scratchpad_Relief_Materials :: struct {
	recessed, mounted, floating: alicorn.Material_ID,
}

scratchpad_relief_materials_ensure :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app.relief_materials.recessed == alicorn.MATERIAL_FLAT {
		app.relief_materials.recessed = alicorn.style_material_register(rt, alicorn.Style_Material{
			kind=.Analytic_Relief, bevel_width=3, bevel_strength=0.95,
			inner_shadow_strength=0.85,
		})
		app.relief_materials.mounted = alicorn.style_material_register(rt, alicorn.Style_Material{
			kind=.Analytic_Relief, bevel_width=2, bevel_strength=0.95,
			inner_shadow_strength=0.5, outer_shadow_strength=0.65, outer_shadow_radius=4,
		})
		app.relief_materials.floating = alicorn.style_material_register(rt, alicorn.Style_Material{
			kind=.Analytic_Relief, bevel_width=3, bevel_strength=0.95,
			inner_shadow_strength=0.5, outer_shadow_strength=0.8, outer_shadow_radius=8,
		})
	}
}

scratchpad_optical_height :: proc(relationship: Scratchpad_Optical_Relationship) -> f32 {
	switch relationship {
	case .Recessed: return -1.75
	case .Groove: return -1
	case .Flush: return 0
	case .Mounted: return 1.5
	case .Floating: return 2
	}
	return 0
}

scratchpad_surface_material :: proc(app: ^App, original: alicorn.Material_ID) -> alicorn.Material_ID {
	if app != nil && app.theme_choice == .Flat { return alicorn.MATERIAL_FLAT }
	if app != nil && app.theme_choice == .Workbench_Relief {
		if original == app.paper_surface_material { return app.relief_materials.recessed }
		if original == app.raised_surface_material { return app.relief_materials.mounted }
		if original == app.floating_surface_material { return app.relief_materials.floating }
	}
	return original
}

scratchpad_surface_height :: proc(app: ^App, original: f32) -> f32 {
	if app == nil || app.theme_choice != .Workbench_Relief { return original }
	if original < 0 { return scratchpad_optical_height(.Recessed) }
	if original >= 1 { return scratchpad_optical_height(.Floating) }
	if original > 0 { return scratchpad_optical_height(.Mounted) }
	return 0
}

scratchpad_relief_theme :: proc(app: ^App, rt: ^alicorn.Runtime, editor: bool) -> alicorn.Style_Theme_ID {
	scratchpad_relief_materials_ensure(app, rt)
	theme := scratchpad_workbench_theme()
	if editor {
		scratchpad_workbench_theme_destroy(&theme)
		theme = scratchpad_editor_theme()
	}
	defer {
		if editor { scratchpad_editor_theme_destroy(&theme) }
		else { scratchpad_workbench_theme_destroy(&theme) }
	}
	defaults := alicorn.DEFAULT_BUTTON_RECIPES
	for variant in ([?]alicorn.Button_Variant{.Default, .Primary, .Toolbar, .Tab, .Quiet}) {
		recipe := &theme.button_recipes.recipes[int(variant)]
		if !recipe.defined { recipe^ = defaults.recipes[int(variant)] }
		// Tabs need a mounted surface even when not selected. Quiet rows retain
		// their transparent rest state and gain relief only when filled.
		if variant == .Tab { recipe.surface_visible = true }
		recipe.rest_surface = {defined=true, material=app.relief_materials.mounted, physical_height=scratchpad_optical_height(.Mounted)}
		recipe.pressed_surface = {defined=true, material=app.relief_materials.recessed, physical_height=scratchpad_optical_height(.Groove)}
	}
	return alicorn.style_theme_register(rt, theme)
}

// New structural surfaces are flush in existing themes. Only the experimental
// appearance opts into a recess; the editor's text surface stays calm.
scratchpad_structural_material :: proc(app: ^App) -> alicorn.Material_ID {
	if app != nil && app.theme_choice == .Workbench_Relief { return app.relief_materials.recessed }
	return alicorn.MATERIAL_FLAT
}
