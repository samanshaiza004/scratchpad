package main

import "core:fmt"
import "core:testing"
import alicorn "alicorn:runtime"

settings_style_study_build :: proc(
	app: ^App, rt: ^alicorn.Runtime, style: Maybe(Settings_Navigation_Style) = nil,
	resolved_style: ^Settings_Navigation_Style = nil,
) -> bool {
	for _ in 0..<4 {
		if !settings_test_build(app, rt, 1, style, resolved_style) { return false }
		settings_surface_intrinsic_after_frame(app, rt)
		if !rt.invalidated { return true }
	}
	return false
}

settings_style_study_flush :: proc(rt: ^alicorn.Runtime) {
	ui, ready := alicorn.begin_presentation_frame(rt)
	if ready { alicorn.end_presentation_frame(&ui) }
}

Settings_Style_Change :: enum { No_Op, Redeclare, Paint, Typography, Geometry, Material, Preset }

@(test)
test_settings_navigation_style_work :: proc(t: ^testing.T) {
	for scale in SETTINGS_STYLE_STUDY_SCALES {
		for change in Settings_Style_Change {
			settings_style_work_sample(t, scale, change)
		}
	}
}

@(test)
test_settings_navigation_style_theme_and_accessibility :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime({0, 0, 1600, 820})
	defer alicorn.destroy_runtime(&rt)
	if !testing.expect(t, alicorn.text_engine_load_default_fonts(&rt)) { return }
	app := App{settings_surface_open=true}
	defer delete(app.selected_theme_id)
	defer delete(app.selected_theme_name)
	if !testing.expect(t, settings_test_build(&app, &rt, 1)) { return }
	option := settings_test_find_node(&rt, "settings-category-0", "")
	previous_ink := alicorn.style_theme_color(&rt, app.workbench_theme, .Text)
	if !testing.expect(t, option != 0 && alicorn.focus(&rt, option)) { return }
	alicorn.focus_indicator_set(&rt, true)

	testing.expect(t, scratchpad_theme_select(&app, &rt, .Cool_Light, persist=false))
	appearance := alicorn.Accessibility_Appearance_Preferences{
		increased_contrast=true, differentiate_without_color=true, reduce_transparency=true,
	}
	testing.expect(t, alicorn.style_root_accessibility_set(&rt, appearance))
	if !testing.expect(t, settings_test_build(&app, &rt, 1.5)) { return }
	testing.expect(t, alicorn.focused_node(&rt) == option && app.settings_category == .Appearance)
	testing.expect(t, settings_test_find_node(&rt, "settings-category-0", "") == option)
	testing.expect(t, previous_ink != alicorn.style_theme_color(&rt, app.workbench_theme, .Text))
	current_ink := alicorn.style_environment_color(&rt,
		{theme=app.workbench_theme, accessibility=appearance}, .Text)
	display, ok := alicorn.paint_display_list(&rt)
	if !testing.expect(t, ok) { return }
	mark, label: bool
	for command in display.commands {
		if !settings_test_descendant(&rt, command.owner, option) { continue }
		if text, is_text := command.payload.(alicorn.Text_Paint); is_text {
			run, valid := alicorn.paint_text_run_resolve(&rt, text.run)
			label = valid && run.value == "Appearance" && run.size > 15 &&
				run.height <= command.bounds.h+1 && text.color == current_ink
		}
		if surface, is_surface := command.payload.(alicorn.Surface_Paint); is_surface {
			mark = mark || (command.bounds.w == 3 && command.bounds.h == 16 && surface.fill == current_ink)
		}
	}
	testing.expect(t, label && mark, "new theme ink, larger text and a non-color selection mark must all survive")
}

settings_style_work_sample :: proc(t: ^testing.T, scale: f32, change: Settings_Style_Change) {
	allocations: alicorn.Runtime_Allocation_Stats
	rt := alicorn.new_runtime({0, 0, 1000, 720}, {allocation_stats=&allocations})
	defer alicorn.destroy_runtime(&rt)
	_ = alicorn.set_presentation_scale(&rt, scale, scale)
	if !testing.expect(t, alicorn.text_engine_load_default_fonts(&rt)) { return }
	app := App{settings_surface_open=true, accessibility_appearance_override_enabled=true}
	style: Settings_Navigation_Style
	if !testing.expect(t, settings_style_study_build(&app, &rt, resolved_style=&style)) { return }
	if change == .Material {
		// Keep optical height constant across the transition. The flat
		// material ignores it, and the registered relief material uses it.
		style.optical_height = 0.5
	}
	owner := settings_test_find_node(&rt, "settings-category-0", "")
	if !testing.expect(t, owner != 0 && alicorn.focus(&rt, owner)) { return }
	alicorn.focus_indicator_set(&rt, true)
	if !testing.expect(t, settings_style_study_build(&app, &rt, style)) { return }
	settings_style_study_flush(&rt)
	label_found := false
	for child_id in rt.nodes[owner].children {
		label := rt.nodes[child_id]
		if label.kind != .Text { continue }
		label_found = true
		button := rt.nodes[owner].bounds
		testing.expect(t, label.text_run_valid && label.text_run.height <= label.bounds.h+1 &&
			label.bounds.y >= button.y && label.bounds.y+label.bounds.h <= button.y+button.h,
			"the visible label must fit inside the focused category")
	}
	testing.expect(t, label_found, "the category must retain a drawable label")
	before := alicorn.frame_stats_snapshot(&rt)
	before_allocations := allocations
	switch change {
	case .No_Op:
		settings_style_study_flush(&rt)
	case .Redeclare:
		alicorn.invalidate_root(&rt, "style study unchanged description")
		testing.expect(t, settings_style_study_build(&app, &rt, style))
	case .Paint:
		style.selected_fill = {0.25, 0.35, 0.46, 1}
		alicorn.invalidate_root(&rt, "style study fill only")
		testing.expect(t, settings_style_study_build(&app, &rt, style))
	case .Typography:
		style.text.font_size += 2
		alicorn.invalidate_root(&rt, "style study typography only")
		testing.expect(t, settings_style_study_build(&app, &rt, style))
	case .Geometry:
		style.height += 6
		alicorn.invalidate_root(&rt, "style study height only")
		testing.expect(t, settings_style_study_build(&app, &rt, style))
	case .Material:
		style.material = app.raised_surface_material
		alicorn.invalidate_root(&rt, "style study material only")
		testing.expect(t, settings_style_study_build(&app, &rt, style))
	case .Preset:
		testing.expect(t, scratchpad_surface_treatment_select(&app, &rt, .Workbench_Relief, persist=false))
		testing.expect(t, settings_style_study_build(&app, &rt))
	}
	after := alicorn.frame_stats_snapshot(&rt)
	layout := after.layout_nodes_visited-before.layout_nodes_visited
	shapes := after.text_shape_requests-before.text_shape_requests
	paint := after.paint_nodes_visited-before.paint_nodes_visited
	fmt.println("settings-style-work", scale, change, after.frames_built-before.frames_built,
		after.reconcile_nodes_visited-before.reconcile_nodes_visited,
		layout, after.measure_nodes_executed-before.measure_nodes_executed, shapes, paint,
		after.display_commands_finalized-before.display_commands_finalized,
		allocations.persistent_alloc_calls-before_allocations.persistent_alloc_calls,
		allocations.scratch_alloc_calls-before_allocations.scratch_alloc_calls)
	testing.expect(t, settings_test_find_node(&rt, "settings-category-0", "") == owner &&
		alicorn.focused_node(&rt) == owner && app.settings_category == .Appearance,
		"restyling preserves the existing owner, keyboard focus and active page")
	switch change {
	case .No_Op, .Redeclare:
		testing.expect(t, layout == 0 && shapes == 0 && paint == 0)
	case .Paint:
		testing.expect(t, layout == 0 && shapes == 0 && paint > 0)
		display, ok := alicorn.paint_display_list(&rt)
		fill_found := false
		for command in display.commands {
			if surface, found := command.payload.(alicorn.Surface_Paint); found && surface.fill == style.selected_fill {
				fill_found = true
			}
		}
		testing.expect(t, ok && fill_found, "the fill edit must appear in the retained display")
	case .Typography:
		testing.expect(t, shapes > 0 && paint > 0)
	case .Geometry:
		testing.expect(t, layout > 0 && paint > 0)
	case .Material:
		testing.expect(t, layout == 0 && shapes == 0 && paint > 0)
	case .Preset:
		testing.expect(t, paint > 0)
	}
	if change == .Preset {
		settings_style_compare_fresh(t, &rt, scale, app.surface_treatment)
	} else {
		settings_style_compare_fresh(t, &rt, scale, .Standard, style)
	}
}

settings_style_compare_fresh :: proc(
	t: ^testing.T, retained: ^alicorn.Runtime, scale: f32, treatment: Scratchpad_Surface_Treatment,
	style: Maybe(Settings_Navigation_Style) = nil,
) {
	fresh := alicorn.new_runtime({0, 0, 1000, 720})
	defer alicorn.destroy_runtime(&fresh)
	_ = alicorn.set_presentation_scale(&fresh, scale, scale)
	if !testing.expect(t, alicorn.text_engine_load_default_fonts(&fresh)) { return }
	app := App{settings_surface_open=true, accessibility_appearance_override_enabled=true}
	if !testing.expect(t, scratchpad_surface_treatment_select(&app, &fresh, treatment, persist=false)) { return }
	if !testing.expect(t, settings_style_study_build(&app, &fresh, style)) { return }
	owner := settings_test_find_node(&fresh, "settings-category-0", "")
	if !testing.expect(t, owner != 0 && alicorn.focus(&fresh, owner)) { return }
	alicorn.focus_indicator_set(&fresh, true)
	if !testing.expect(t, settings_style_study_build(&app, &fresh, style)) { return }

	a, a_ok := alicorn.paint_display_list(retained)
	b, b_ok := alicorn.paint_display_list(&fresh)
	a_nav := settings_test_find_node(retained, "settings-navigation", "")
	b_nav := settings_test_find_node(&fresh, "settings-navigation", "")
	if !testing.expect(t, a_ok && b_ok && a_nav != 0 && b_nav != 0) { return }
	cursor := 0
	for before in a.commands {
		if !settings_test_descendant(retained, before.owner, a_nav) { continue }
		for cursor < len(b.commands) && !settings_test_descendant(&fresh, b.commands[cursor].owner, b_nav) {
			cursor += 1
		}
		if !testing.expect(t, cursor < len(b.commands), "fresh navigation is missing a retained draw") { return }
		after := b.commands[cursor]
		cursor += 1
		testing.expectf(t, before.bounds == after.bounds && before.clip == after.clip &&
			before.opacity == after.opacity && before.translation == after.translation,
			"retained %s and fresh %s differ: bounds %v / %v, clips %v / %v",
			retained.nodes[before.owner].label, fresh.nodes[after.owner].label,
			before.bounds, after.bounds, before.clip, after.clip)
		#partial switch paint in before.payload {
		case alicorn.Surface_Paint:
			reference, ok := after.payload.(alicorn.Surface_Paint)
			testing.expect(t, ok && reference == paint, "fresh and retained surface paint should match")
		case alicorn.Text_Paint:
			reference, ok := after.payload.(alicorn.Text_Paint)
			if !testing.expect(t, ok && reference.color == paint.color) { continue }
			run, run_ok := alicorn.paint_text_run_resolve(retained, paint.run)
			other, other_ok := alicorn.paint_text_run_resolve(&fresh, reference.run)
			if !testing.expect(t, run_ok && other_ok && run.value == other.value &&
				len(run.glyphs) == len(other.glyphs) && run.height == other.height && run.width == other.width) {
				continue
			}
			for glyph, i in run.glyphs {
				testing.expect(t, glyph == other.glyphs[i], "fresh and retained text glyph placement should match")
			}
		case:
			testing.expect(t, false, "unexpected navigation paint command")
		}
	}
	for command in b.commands[cursor:] {
		testing.expect(t, !settings_test_descendant(&fresh, command.owner, b_nav), "fresh navigation has an extra draw")
	}
}
