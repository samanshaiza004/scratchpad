package main

import alicorn "alicorn:runtime"

EDITOR_TEXT_SCALE_MIN :: f32(0.7)
EDITOR_TEXT_SCALE_MAX :: f32(2.0)
EDITOR_TEXT_SCALE_STEP :: f32(0.1)

editor_text_scale_effective :: proc(app: ^App) -> f32 {
	if app == nil || app.editor_text_scale <= 0 { return 1 }
	return app.editor_text_scale
}

editor_text_zoom_step :: proc(app: ^App, rt: ^alicorn.Runtime, direction: int) -> bool {
	if direction == 0 { return false }
	current := editor_text_scale_effective(app)
	step := int(current*10+0.5)+direction
	return editor_text_zoom_set(app, rt, f32(step)/10)
}

editor_text_zoom_set :: proc(app: ^App, rt: ^alicorn.Runtime, requested_scale: f32) -> bool {
	if app == nil || rt == nil { return false }
	current := editor_text_scale_effective(app)
	step := int(requested_scale*10+0.5)
	next := clamp(f32(step)/10, EDITOR_TEXT_SCALE_MIN, EDITOR_TEXT_SCALE_MAX)
	if abs(next-current) < 0.001 { return false }

	active_view_index := -1
	active_document, active_document_found := find_document(&app.backend.state, app.backend.state.active)
	if active_document_found {
		active_view_index = editor_view_find(app.editor_views[:], active_document.id)
		if active_view_index >= 0 {
			view := &app.editor_views[active_view_index]
			window, window_matches := editor_view_window(
				view, &app.editor_window, app.editor_window_ready,
				active_document.id, active_document.editor_revision,
			)
			scroll := alicorn.scroll_region_state(rt, app.editor_scroll_owner)
			if window_matches && scroll.id != 0 && view.wrap_height_index_ready {
				metrics := alicorn.virtual_list_variable_metrics(
					&view.wrap_height_index, scroll.offset_y, scroll.viewport_height,
				)
				if anchor_line, found := editor_window_line(window, u64(metrics.first)); found {
					anchor_top := alicorn.virtual_list_height_index_item_top(&view.wrap_height_index, metrics.first)
					view.viewport_anchor_byte = anchor_line.source_start
					view.viewport_anchor_line = anchor_line.logical_line
					view.viewport_anchor_revision = active_document.editor_revision
					view.viewport_anchor_offset = scroll.offset_y-anchor_top
					view.viewport_anchor_pending = true
					view.viewport_anchor_resolved = true
					view.scroll_y = scroll.offset_y
					view.restore_y_pending = true
				}
			}
		}
	}

	ratio := next/current
	app.editor_text_scale = next
	for view_index in 0..<len(app.editor_views) {
		view := &app.editor_views[view_index]
		if view_index != active_view_index {
			view.scroll_y *= ratio
			view.restore_y_pending = true
		}
		if view.wrap_height_index_ready {
			item_count := view.wrap_height_index.item_count
			if document, found := find_document(&app.backend.state, view.document_id); found {
				item_count = int(document.line_count)
			}
			editor_wrap_heights_reset(view, item_count, next)
		}
		view.wrap_measurement_width = -1
		view.wrap_measurement_revision = 0
		view.wrap_measurement_presentation_revision = 0
		view.wrap_measurement_start_line = 0
		view.wrap_measurement_end_line = 0
		view.wrap_measurement_pending_edits = 0
	}

	alicorn.invalidate_root(rt, "Scratchpad editor text scale changed")
	return true
}
