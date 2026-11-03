package main

import alicorn "alicorn:runtime"

// Marker interaction requires the exact parser revision and the original
// source bytes. Optimistically rebased paint never authorizes a source action.
editor_task_marker_is_current :: proc(window: ^Editor_Window, start, end: u64) -> bool {
	if window == nil || !window.presentation_ready || window.presentation_stale ||
	   window.presentation_revision != window.editor_revision || end < start || end-start != 3 ||
	   start < window.start_byte || end > window.start_byte+u64(len(window.source)) { return false }
	local := int(start-window.start_byte)
	return window.source[local] == '[' && window.source[local+2] == ']' &&
	       (window.source[local+1] == ' ' || window.source[local+1] == 'x' || window.source[local+1] == 'X')
}

editor_task_marker_at_pointer :: proc(
	app: ^App, rt: ^alicorn.Runtime, window: ^Editor_Window, x, y: f32,
) -> (start, end: u64, hit: bool) {
	if app == nil || rt == nil || window == nil { return }
	for record in window.presentation_spans {
		if record.kind != EDITOR_PRESENTATION_TASK_MARKER { continue }
		start = window.start_byte+u64(record.start_byte)
		end = window.start_byte+u64(record.end_byte)
		if !editor_task_marker_is_current(window, start, end) { continue }
		for row in app.editor_row_targets {
			line, found := editor_window_line(window, row.logical_line)
			if !found || start < line.source_start || end > line.source_end { continue }
			display_line, display_found := editor_display_line_for_target(window, line, row)
			if !display_found { continue }
			first, last, mapped := editor_source_range_to_display(&display_line, start, end)
			if !mapped { continue }
			left := alicorn.text_node_caret_geometry(rt, row.node, {byte=first, affinity=.Leading})
			right := alicorn.text_node_caret_geometry(rt, row.node, {byte=last, affinity=.Trailing})
			if left.valid && right.valid && left.line_index == right.line_index &&
			   x >= min(left.rect.x, right.rect.x) && x < max(left.rect.x, right.rect.x) &&
			   y >= left.rect.y && y < left.rect.y+left.rect.h { return start, end, true }
		}
	}
	return 0, 0, false
}

// A plain click toggles on release. Dragging, Shift-click, double-click, IME,
// pending edits, or a changed source revision preserve ordinary text editing.
editor_task_marker_pointer_finish :: proc(app: ^App, rt: ^alicorn.Runtime, event: alicorn.Pointer_Event) {
	if app == nil || rt == nil { return }
	for &view in app.editor_views {
		if !view.task_toggle_pending { continue }
		if event.kind == .Move {
			if abs(event.x-view.task_toggle_x) > 4 || abs(event.y-view.task_toggle_y) > 4 {
				view.task_toggle_pending = false
			}
			continue
		}
		if event.kind != .Up && event.kind != .Down && event.kind != .Cancel { continue }
		view.task_toggle_pending = false
		if event.kind != .Up || event.button != alicorn.POINTER_BUTTON_PRIMARY ||
		   event.modifiers.shift || event.modifiers.control || event.modifiers.alt || event.modifiers.super ||
		   view.preedit_active || len(app.editor_edits) > 0 ||
		   view.document_id != app.backend.state.active { continue }
		document, found := find_document(&app.backend.state, view.document_id)
		if !found || document.language != "markdown" || document.editor_revision != view.task_toggle_revision { continue }
		window, current := editor_view_window(&view, &app.editor_window, app.editor_window_ready,
			document.id, document.editor_revision)
		if !current { continue }
		start, end, hit := editor_task_marker_at_pointer(app, rt, window, event.x, event.y)
		if !hit || start != view.task_toggle_start || end != view.task_toggle_end { continue }
		dispatch_action(app, rt, ACTION_ITEM_TOGGLE)
		return
	}
}
