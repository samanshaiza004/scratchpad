package main

import "core:testing"
import alicorn "alicorn:runtime"

@(test)
test_editor_zoom_is_bounded_and_discoverable :: proc(t: ^testing.T) {
	app: App
	init_menus(&app)
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 800, 600})
	defer alicorn.destroy_runtime(&rt)

	zoom_in_found := false
	zoom_out_found := false
	zoom_reset_found := false
	for item in app.view_items {
		if item.label == "Zoom In" { zoom_in_found = true }
		if item.label == "Zoom Out" { zoom_out_found = true }
		if item.label == "Reset Editor Zoom" { zoom_reset_found = true }
	}
	testing.expect(t, zoom_in_found && zoom_out_found && zoom_reset_found,
		"the View menu should expose editor zoom in, out, and reset")

	testing.expect(t, application_key(rawptr(&app), &rt, .Zoom_In) && abs(app.editor_text_scale-1.1) < 0.001,
		"the host zoom-in shortcut should change only editor text scale")
	for _ in 0..<29 { _ = editor_text_zoom_step(&app, &rt, 1) }
	testing.expect(t, abs(app.editor_text_scale-EDITOR_TEXT_SCALE_MAX) < 0.001,
		"editor zoom in should stop at its maximum scale")
	testing.expect(t, !editor_text_zoom_step(&app, &rt, 1),
		"zooming past the maximum should not invalidate the editor")

	for _ in 0..<40 { _ = editor_text_zoom_step(&app, &rt, -1) }
	testing.expect(t, abs(app.editor_text_scale-EDITOR_TEXT_SCALE_MIN) < 0.001,
		"editor zoom out should stop at its minimum scale")
	testing.expect(t, !editor_text_zoom_step(&app, &rt, -1),
		"zooming past the minimum should not invalidate the editor")

	testing.expect(t, application_key(rawptr(&app), &rt, .Zoom_Reset),
		"the host zoom-reset shortcut should be handled")
	testing.expect(t, abs(app.editor_text_scale-1) < 0.001,
		"reset editor zoom should restore the default scale")
}
