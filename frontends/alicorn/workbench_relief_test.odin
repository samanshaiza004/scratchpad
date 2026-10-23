package main

import "core:testing"
import alicorn "alicorn:runtime"

@(test)
test_workbench_relief_retains_settings_semantics_geometry_and_measurements :: proc(t: ^testing.T) {
	for scale in ([4]f32{1, 1.25, 1.5, 2}) {
		rt := alicorn.new_runtime({0, 0, 1200, 760})
		app := App{theme_choice=.Flat, settings_surface_open=true, settings_category=.Appearance}
		fonts := alicorn.text_engine_load_font(&rt.text_engine, ALICORN_TEST_UI_FONT_DATA)
		testing.expect(t, fonts, "relief fixture requires the bundled UI font")
		if !fonts { alicorn.destroy_runtime(&rt); continue }
		_ = settings_test_build(&app, &rt, scale)
		field := settings_test_find_node(&rt, "settings-workbench-appearance", "")
		done := settings_test_find_node(&rt, "settings-done", "")
		testing.expect(t, field != 0 && done != 0, "the real Settings scene should expose its selector and Done action")
		if field == 0 || done == 0 { alicorn.destroy_runtime(&rt); continue }
		_ = alicorn.focus(&rt, field)
		alicorn.invalidate_root(&rt, "settle focus before optical comparison")
		_ = settings_test_build(&app, &rt, scale)
		flat := alicorn.semantic_snapshot(&rt)
		flat_done := rt.nodes[done]^
		_ = scratchpad_theme_select(&app, &rt, .Workbench_Relief)
		_ = settings_test_build(&app, &rt, scale)
		relief := alicorn.semantic_snapshot(&rt)
		testing.expect(t, settings_test_find_node(&rt, "settings-done", "") == done && rt.nodes[done].bounds == flat_done.bounds && rt.nodes[done].hit_bounds == flat_done.hit_bounds && alicorn.focused_node(&rt) == field, "Flat and Relief retain identity, bounds, hits and focus")
		testing.expect(t, len(flat.nodes) == len(relief.nodes), "optical decoration must not add semantic entities")
		if len(flat.nodes) == len(relief.nodes) {
			for before, i in flat.nodes {
				after := relief.nodes[i]
				testing.expect(t, before.id == after.id && before.role == after.role && before.label == after.label && before.actions == after.actions && before.bounds == after.bounds, "optical changes preserve semantic identity, purpose, actions and geometry")
			}
		}
		paint, found := rt.nodes[done].paint[0].payload.(alicorn.Surface_Paint)
		testing.expect(t, found && paint.material != alicorn.MATERIAL_FLAT && paint.physical_height > 0, "Workbench Relief gives operable buttons a mounted surface")
		app.accessibility_appearance_override_enabled = true
		app.accessibility_appearance = {increased_contrast=true, reduce_transparency=true}
		alicorn.invalidate_root(&rt, "accessible relief variant")
		_ = settings_test_build(&app, &rt, scale)
		_ = scratchpad_theme_select(&app, &rt, .Flat)
		_ = settings_test_build(&app, &rt, scale)
		paint, found = rt.nodes[done].paint[0].payload.(alicorn.Surface_Paint)
		testing.expect(t, found && paint.material == alicorn.MATERIAL_FLAT, "switching back restores the canonical flat Button")
		_, build := alicorn.begin_frame(&rt)
		_, present := alicorn.begin_presentation_frame(&rt)
		testing.expect(t, !build && !present, "settled materials introduce no idle work")
		alicorn.semantic_snapshot_destroy(&flat)
		alicorn.semantic_snapshot_destroy(&relief)
		alicorn.destroy_runtime(&rt)
	}
}

@(test)
test_workbench_relief_preference_names_and_window_local_handles :: proc(t: ^testing.T) {
	for choice in ([2]Scratchpad_Theme_Choice{.Flat, .Workbench_Relief}) {
		parsed, valid := scratchpad_theme_choice_parse(scratchpad_theme_choice_name(choice))
		testing.expect(t, valid && parsed == choice, "optical appearance has a stable persisted name")
	}
	app := App{theme_choice=.Workbench_Relief}
	primary := alicorn.new_runtime({0, 0, 800, 600})
	secondary := alicorn.new_runtime({0, 0, 640, 480})
	defer alicorn.destroy_runtime(&primary)
	defer alicorn.destroy_runtime(&secondary)
	_ = scratchpad_styles_ensure(&app, &primary)
	primary_theme := app.relief_workbench_theme
	state := Floating_Window_State{owner=&app}
	_, scope := floating_editor_scope_enter(&state, &secondary)
	_ = scratchpad_styles_ensure(&app, &secondary)
	testing.expect(t, app.style_theme_runtime == &secondary && app.relief_workbench_theme != 0, "the floating Runtime registers its own relief theme and materials")
	floating_editor_scope_leave(&state, &app, &scope)
	testing.expect(t, app.style_theme_runtime == &primary && app.relief_workbench_theme == primary_theme, "leaving the child scope restores primary Runtime handles")
	_ = scratchpad_theme_select(&app, &primary, .Flat)
	primary_material := app.paper_surface_material
	_, scope = floating_editor_scope_enter(&state, &secondary)
	_ = scratchpad_styles_ensure(&app, &secondary)
	floating_editor_scope_leave(&state, &app, &scope)
	testing.expect(t, app.paper_surface_material == primary_material && primary_material != alicorn.MATERIAL_FLAT,
		"Flat affects painting only; visiting a child must preserve primary registered material ownership")
}
