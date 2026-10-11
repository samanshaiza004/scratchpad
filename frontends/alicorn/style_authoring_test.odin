package main

import "core:testing"
import alicorn "alicorn:runtime"

@(test)
test_paper_material_and_tab_recipe_are_dogfooded_from_theme_source :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 320, 200})
	defer alicorn.destroy_runtime(&rt)
	app: App
	if !scratchpad_styles_ensure(&app, &rt) {
		testing.expect(t, false, "Scratchpad theme material and recipes should register")
		return
	}

	paper, paper_ok := alicorn.style_material_resolve(&rt, app.paper_surface_material)
	testing.expect(t, paper_ok && paper.kind == .Analytic_Relief && paper.bevel_width == 1 &&
		paper.bevel_strength == 0.36 && paper.inner_shadow_strength == 0.18,
		"the editor paper material should be registered from generated theme source values")

	resolved := alicorn.style_button_resolve(
		&rt,
		alicorn.Style_Environment{theme=app.workbench_theme},
		.Tab,
		alicorn.Button_Visual_State{selected=true},
	)
	accent := alicorn.style_theme_color(&rt, app.workbench_theme, .Accent)
	testing.expect(t, resolved.selected_indicator == .Underline && resolved.selected_indicator_color == accent,
		"the selected tab indicator should use the accent role authored in Scratchpad's workbench theme")

	cool_active_line, cool_active_line_found := alicorn.style_extension_color(&rt, app.cool_light_theme, scratchpad_editor_active_line_role())
	warm_active_line, warm_active_line_found := alicorn.style_extension_color(&rt, app.warm_editor_theme, scratchpad_editor_active_line_role())
	testing.expect(t, cool_active_line_found && warm_active_line_found &&
		cool_active_line != warm_active_line && cool_active_line.b > cool_active_line.r && warm_active_line.r > warm_active_line.b,
		"the editor caret row should resolve distinct cool and warm colors from theme extension roles")
}
