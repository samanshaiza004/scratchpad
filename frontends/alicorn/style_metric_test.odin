package main

import "core:testing"
import alicorn "alicorn:runtime"

@(test)
test_editor_padding_uses_theme_metric_and_environment_density :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 360, 220})
	defer alicorn.destroy_runtime(&rt)
	app: App
	if !scratchpad_styles_ensure(&app, &rt) {
		testing.expect(t, false, "Scratchpad style themes should register for the metric dogfood test")
		return
	}

	authored, found := alicorn.style_extension_length(&rt, app.editor_theme, scratchpad_editor_padding_role())
	testing.expect(t, found && authored.logical_units == 10,
		"the paper theme should expose the app-namespaced 10 px editor padding dimension")
	if !found { return }

	ui, should_build := alicorn.begin_frame(&rt)
	testing.expect(t, should_build, "metric dogfood test should build a frame")
	if !should_build { return }
	alicorn.container_begin(&ui, .Root, key="metric-test-root", style=alicorn.layout_style(width=360, height=220))
	scope := alicorn.style_environment_push(&ui, alicorn.Style_Environment{theme=app.editor_theme, density=1.25})
	padding := scratchpad_editor_surface_padding(&ui, &rt, app.editor_theme)
	paper := alicorn.surface_begin(
		&ui,
		alicorn.surface_extension_color_role(scratchpad_editor_paper_surface_role()),
		key="metric-test-paper",
		style=alicorn.layout_style(.Column, width=320, height=180, padding=padding),
		material=app.paper_surface_material,
	)
	content := alicorn.text_ex(&ui, "Metric-backed content", key="metric-test-content", explicit_key=true)
	alicorn.surface_end(&ui)
	alicorn.style_environment_pop(&ui, scope)
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)

	if paper == 0 || content == 0 { return }
	testing.expect(t, padding == 12.5 && rt.nodes[paper].style.padding == padding,
		"the editor surface layout should consume the theme dimension after density scaling")
	testing.expect(t, rt.nodes[content].bounds.x == rt.nodes[paper].bounds.x+padding,
		"the resolved density-scaled padding should move real editor content geometry")
}
