package main

import alicorn "alicorn:runtime"

// Application vocabulary: these optical relationships do not add widget roles,
// layout, interaction nodes, or compositor depth.
Scratchpad_Optical_Relationship :: enum { Recessed, Groove, Flush, Mounted, Floating }

scratchpad_optical_height :: proc(relationship: Scratchpad_Optical_Relationship) -> f32 {
	switch relationship {
	case .Recessed: return -0.75
	case .Groove: return -0.25
	case .Flush: return 0
	case .Mounted: return 0.5
	case .Floating: return 1
	}
	return 0
}

scratchpad_surface_material :: proc(app: ^App, original: alicorn.Material_ID) -> alicorn.Material_ID {
	if app != nil && app.theme_choice == .Flat { return alicorn.MATERIAL_FLAT }
	return original
}

scratchpad_relief_theme :: proc(app: ^App, rt: ^alicorn.Runtime, editor: bool) -> alicorn.Style_Theme_ID {
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
	for variant in ([?]alicorn.Button_Variant{.Default, .Primary, .Toolbar}) {
		recipe := &theme.button_recipes.recipes[int(variant)]
		if !recipe.defined { recipe^ = defaults.recipes[int(variant)] }
		recipe.rest_surface = {defined=true, material=app.raised_surface_material, physical_height=scratchpad_optical_height(.Mounted)}
		recipe.pressed_surface = {defined=true, material=app.raised_surface_material, physical_height=scratchpad_optical_height(.Groove)}
	}
	return alicorn.style_theme_register(rt, theme)
}

// New structural surfaces are flush in existing themes. Only the experimental
// appearance opts into a recess; the editor's text surface stays calm.
scratchpad_structural_material :: proc(app: ^App) -> alicorn.Material_ID {
	if app != nil && app.theme_choice == .Workbench_Relief { return app.paper_surface_material }
	return alicorn.MATERIAL_FLAT
}
