package main

import "core:fmt"
import alicorn "alicorn:runtime"
import gui "alicorn:ui"
import bridge "./bridge"

ACTION_EDITOR_TOGGLE_FOLD :: "document.toggle-fold"
ACTION_EDITOR_FOLD_ALL :: "document.fold-all"
ACTION_EDITOR_UNFOLD_ALL :: "document.unfold-all"

Editor_Manual_Folding :: struct {
	plan: bridge.Editor_Fold_Plan,
	owned: bool,
	collapsed: [dynamic]bool,
	rows: Semantic_Zoom_Rows,
	index: alicorn.Virtual_List_Height_Index,
	index_ready: bool,
	windows: [dynamic]Editor_Window,
	waiting: bool,
	waiting_presentation_revision: u64,
	waiting_ready: bool,
	anchor_line: u64,
	anchor_offset: f32,
	anchor_pending: bool,
}

manual_folding_destroy :: proc(folding: ^Editor_Manual_Folding, allocator := context.allocator) {
	if folding == nil { return }
	manual_folding_clear_projection(folding)
	for &window in folding.windows { editor_window_destroy(&window, allocator) }
	delete(folding.windows)
	if folding.owned { bridge.Editor_Fold_Plan_Destroy(&folding.plan, allocator) }
	delete(folding.collapsed)
	folding^ = {}
}

manual_folding_cached_window :: proc(view: ^Editor_View_State, line: u64) -> ^Editor_Window {
	if view == nil { return nil }
	for &window in view.manual_folding.windows {
		if line >= window.start_line && line < window.end_line &&
		   window.document_id == view.document_id && window.editor_revision == view.authoritative_revision {
			return &window
		}
	}
	return nil
}

manual_folding_window_for_byte :: proc(view: ^Editor_View_State, document_id: string, revision, source_byte: u64) -> ^Editor_Window {
	if view == nil || !manual_folding_has_candidates(view) ||
	   view.manual_folding.plan.document_id != document_id || view.manual_folding.plan.revision != revision {
		return nil
	}
	for &window in view.manual_folding.windows {
		if window.document_id != document_id || window.editor_revision != revision { continue }
		if _, found := editor_line_for_source(&window, source_byte); found { return &window }
	}
	return nil
}

manual_folding_any_window :: proc(view: ^Editor_View_State, document_id: string, revision: u64) -> ^Editor_Window {
	if view == nil || !manual_folding_has_candidates(view) ||
	   view.manual_folding.plan.document_id != document_id || view.manual_folding.plan.revision != revision {
		return nil
	}
	for &window in view.manual_folding.windows {
		if window.document_id == document_id && window.editor_revision == revision { return &window }
	}
	return nil
}

manual_folding_visible_windows_ready :: proc(
	view: ^Editor_View_State,
	document: bridge.State_Document,
	first_row, last_row: int,
	base: ^Editor_Window,
) -> (all_rows_ready, all_presentation_current: bool) {
	all_rows_ready, all_presentation_current = true, true
	if !manual_folding_projection_active(view) { return false, false }
	for row := first_row; row < last_row; row += 1 {
		source_line, _, ok := semantic_zoom_rows_source_at(&view.manual_folding.rows, row)
		if !ok { continue }
		line := u64(source_line)
		window := base
		if window == nil || window.document_id != document.id || window.editor_revision != document.editor_revision ||
		   line < window.start_line || line >= window.end_line {
			window = manual_folding_cached_window(view, line)
		}
		if window == nil || window.document_id != document.id || window.editor_revision != document.editor_revision ||
		   line < window.start_line || line >= window.end_line {
			all_rows_ready = false
			all_presentation_current = false
			continue
		}
		if !window.presentation_ready || window.presentation_stale ||
		   window.presentation_revision != document.presentation_revision ||
		   window.presentation_revision != document.editor_revision {
			all_presentation_current = false
		}
	}
	return
}

manual_folding_measure_window :: proc(
	rt: ^alicorn.Runtime,
	view: ^Editor_View_State,
	document: bridge.State_Document,
	window: ^Editor_Window,
	width, text_scale: f32,
) -> bool {
	if rt == nil || view == nil || window == nil || !view.wrap_height_index_ready || width <= 0 { return false }
	presentation_current := window.presentation_ready && !window.presentation_stale &&
		window.presentation_revision == document.presentation_revision &&
		window.presentation_revision == document.editor_revision
	language_hash: u64 = 1469598103934665603
	for character in document.language {
		language_hash = (language_hash ~ u64(character)) * 1099511628211
	}
	if language_hash == 0 { language_hash = 1 }
	if window.layout_measurement_ready &&
	   abs(window.layout_measurement_width-width) <= 0.5 &&
	   window.layout_measurement_text_scale == text_scale &&
	   window.layout_measurement_revision == document.editor_revision &&
	   window.layout_measurement_presentation_revision == window.presentation_revision &&
	   window.layout_measurement_language_hash == language_hash &&
	   window.layout_measurement_mode == view.wrap_mode &&
	   window.layout_measurement_presentation_current == presentation_current {
		return false
	}
	changed := editor_measure_window_wrapping(
		rt, view, window, document.language, width, presentation_current, text_scale,
	)
	window.layout_measurement_ready = true
	window.layout_measurement_width = width
	window.layout_measurement_text_scale = text_scale
	window.layout_measurement_revision = document.editor_revision
	window.layout_measurement_presentation_revision = window.presentation_revision
	window.layout_measurement_language_hash = language_hash
	window.layout_measurement_mode = view.wrap_mode
	window.layout_measurement_presentation_current = presentation_current
	return changed
}

manual_folding_adjacent_visible_line :: proc(view: ^Editor_View_State, current_line: u64, direction: int) -> (line: u64, found: bool) {
	if !manual_folding_projection_active(view) || (direction != -1 && direction != 1) { return current_line, false }
	row := manual_folding_row_for_source(&view.manual_folding.rows, int(current_line))
	if row < 0 { return current_line, false }
	source_line, _, ok := semantic_zoom_rows_source_at(&view.manual_folding.rows, row+direction)
	return u64(source_line) if ok else current_line, ok
}

// An anchor hidden by a new fold lands on the preceding visible row. This
// also gives folds at EOF a real row instead of the insertion point past EOF.
manual_folding_row_for_source :: proc(rows: ^Semantic_Zoom_Rows, line: int) -> int {
	row := semantic_zoom_rows_row_for_source(rows, line)
	if semantic_zoom_rows_hidden(rows, line) { return max(row-1, 0) }
	return row
}

manual_folding_source_window :: proc(
	app: ^App,
	view: ^Editor_View_State,
	document: bridge.State_Document,
	line: u64,
	base: ^Editor_Window,
) -> ^Editor_Window {
	if app == nil || view == nil { return nil }
	if base != nil && base.document_id == document.id && base.editor_revision == document.editor_revision &&
	   line >= base.start_line && line < base.end_line {
		return base
	}
	if !manual_folding_plan_matches(&view.manual_folding, document) { return nil }
	if cached := manual_folding_cached_window(view, line); cached != nil { return cached }
	result := bridge.backend_command(&app.backend, "read_visible_lines", document_id=document.id,
		start_line=line, max_lines=8, max_bytes=16*1024, include_presentation=true, read_latest_after=false)
	defer bridge.backend_command_result_destroy(&result, context.allocator)
	if !result.ok || !result.visible_window_owned || result.visible_window.document_id != document.id ||
	   result.visible_window.editor_revision != document.editor_revision {
		return nil
	}
	window, ok, _ := editor_window_from_visible(&result.visible_window, context.allocator)
	if !ok { return nil }
	if editor_window_is_long_line_chunk(&window) {
		// The ordinary source lane owns horizontal chunk traversal. A partial
		// cached line cannot provide complete caret or wrapping geometry.
		editor_window_destroy(&window)
		return nil
	}
	if view.manual_folding.windows.allocator.procedure == nil {
		view.manual_folding.windows = make([dynamic]Editor_Window, 0, allocator=context.allocator)
	}
	if len(view.manual_folding.windows) >= 64 {
		editor_window_destroy(&view.manual_folding.windows[0])
		ordered_remove(&view.manual_folding.windows, 0)
	}
	append(&view.manual_folding.windows, window)
	return &view.manual_folding.windows[len(view.manual_folding.windows)-1]
}

manual_folding_clear_projection :: proc(folding: ^Editor_Manual_Folding) {
	if folding == nil { return }
	if folding.index_ready { alicorn.virtual_list_height_index_destroy(&folding.index); folding.index_ready = false }
	semantic_zoom_rows_destroy(&folding.rows)
}

manual_folding_plan_matches :: proc(folding: ^Editor_Manual_Folding, document: bridge.State_Document) -> bool {
	return folding != nil && folding.owned && folding.plan.document_id == document.id &&
	       folding.plan.revision == document.editor_revision && folding.plan.instance_id == document.instance_id
}

manual_folding_projection_active :: proc(view: ^Editor_View_State) -> bool {
	return view != nil && view.zoom.depth == 0 && view.optimistic_pending_edits == 0 &&
	       view.manual_folding.owned && view.manual_folding.plan.ready && view.manual_folding.plan.supported &&
	       view.manual_folding.plan.document_id == view.document_id &&
	       view.manual_folding.plan.instance_id == view.document_instance_id &&
	       view.manual_folding.plan.revision == view.authoritative_revision &&
	       len(view.manual_folding.rows.folds) > 0 && view.manual_folding.index_ready
}

manual_folding_has_candidates :: proc(view: ^Editor_View_State) -> bool {
	return view != nil && view.zoom.depth == 0 && view.manual_folding.owned &&
	       view.manual_folding.plan.ready && view.manual_folding.plan.supported &&
	       view.manual_folding.plan.document_id == view.document_id &&
	       view.manual_folding.plan.instance_id == view.document_instance_id &&
	       view.manual_folding.plan.revision == view.authoritative_revision &&
	       len(view.manual_folding.plan.folds) > 0 && view.optimistic_pending_edits == 0
}

manual_folding_prepare :: proc(app: ^App, rt: ^alicorn.Runtime, document: bridge.State_Document, view: ^Editor_View_State) {
	if app == nil || rt == nil || view == nil || view.zoom.depth != 0 || document.view_kind == "image" || document.view_kind == "unsupported" {
		return
	}
	if view.document_instance_id != document.instance_id {
		manual_folding_destroy(&view.manual_folding)
		view.document_instance_id = document.instance_id
	}
	if view.authoritative_revision == 0 && view.optimistic_pending_edits == 0 {
		view.authoritative_revision = document.editor_revision
	}
	folding := &view.manual_folding
	if manual_folding_plan_matches(folding, document) {
		if !folding.waiting { return }
		if !document.presentation_ready ||
		   (folding.waiting_ready && folding.waiting_presentation_revision == document.presentation_revision) {
			return
		}
	} else if folding.owned || folding.waiting {
		manual_folding_destroy(folding)
	}
	result := bridge.backend_command(&app.backend, "read_editor_folds", document_id=document.id,
		editor_revision=document.editor_revision, read_latest_after=false)
	defer bridge.backend_command_result_destroy(&result, context.allocator)
	if !result.ok || !result.editor_folds_owned {
		return
	}
	plan := result.editor_folds
	if plan.document_id != document.id || plan.revision != document.editor_revision || plan.instance_id != document.instance_id {
		return
	}
	manual_folding_destroy(folding)
	folding.plan, folding.owned = plan, true
	result.editor_folds, result.editor_folds_owned = {}, false
	folding.waiting = !plan.ready
	folding.waiting_presentation_revision = document.presentation_revision
	folding.waiting_ready = document.presentation_ready
	if !plan.ready || !plan.supported { return }
	folding.collapsed, _ = make([dynamic]bool, len(plan.folds), allocator=context.allocator)
	if len(plan.folds) > 0 && len(folding.collapsed) != len(plan.folds) {
		manual_folding_destroy(folding)
		return
	}
	if plan.line_count <= 0 { return }
	if !semantic_zoom_rows_init(&folding.rows, nil, int(plan.line_count)) {
		manual_folding_destroy(folding)
		return
	}
	if len(plan.folds) > 0 { alicorn.invalidate_root(rt, "Scratchpad loaded source folding metadata") }
}

manual_folding_rebuild_rows :: proc(folding: ^Editor_Manual_Folding) -> bool {
	if folding == nil || !folding.owned || !folding.plan.ready || !folding.plan.supported { return false }
	active := make([dynamic]bridge.Semantic_Zoom_Fold, 0, len(folding.plan.folds), allocator=context.temp_allocator)
	defer delete(active)
	for source, index in folding.plan.folds {
		if index >= len(folding.collapsed) || !folding.collapsed[index] { continue }
		suppressed := false
		for included in active {
			if source.body_start_line >= included.start_line && source.end_line <= included.end_line {
				suppressed = true
				break
			}
		}
		if suppressed { continue }
		append(&active, bridge.Semantic_Zoom_Fold{
			start_line=source.body_start_line,
			end_line=source.end_line,
			start_byte=source.body_start_byte,
			end_byte=source.end_byte,
			label=source.label,
			silent=true,
		})
	}
	return semantic_zoom_rows_init(&folding.rows, active[:], int(folding.plan.line_count))
}

manual_folding_sync_geometry :: proc(view: ^Editor_View_State, window: ^Editor_Window, scale: f32) {
	if view == nil { return }
	folding := &view.manual_folding
	if !manual_folding_has_candidates(view) || len(folding.rows.folds) == 0 || !view.wrap_height_index_ready {
		if folding.index_ready { alicorn.virtual_list_height_index_destroy(&folding.index); folding.index_ready = false }
		// Expanding the last collapsed fold returns geometry to the ordinary
		// wrapped-line index. Apply the captured source-line anchor there too;
		// otherwise the viewport stays at the old folded offset and jumps
		// to different source after the hidden rows reappear.
		if len(folding.rows.folds) == 0 && view.wrap_height_index_ready && folding.anchor_pending {
			line := clamp(int(folding.anchor_line), 0, max(view.wrap_height_index.item_count-1, 0))
			_ = manual_folding_restore_anchor_at_row(view, folding, &view.wrap_height_index, line)
		}
		return
	}
	row_count := folding.rows.row_count
	if !folding.index_ready || folding.index.item_count != row_count || folding.index.estimated_height != EDITOR_ROW_HEIGHT*scale {
		if folding.index_ready { alicorn.virtual_list_height_index_destroy(&folding.index) }
		folding.index_ready = alicorn.virtual_list_height_index_init(&folding.index, row_count, EDITOR_ROW_HEIGHT*scale)
		if !folding.index_ready { return }
		for entry in view.wrap_height_index.entries {
			if semantic_zoom_rows_hidden(&folding.rows, entry.index) { continue }
			row := semantic_zoom_rows_row_for_source(&folding.rows, entry.index)
			if row >= 0 { _ = alicorn.virtual_list_height_index_set_height(&folding.index, row, entry.height) }
		}
	}
	if window != nil {
		for line in window.lines {
			line_number := int(line.logical_line)
			if semantic_zoom_rows_hidden(&folding.rows, line_number) { continue }
			row := semantic_zoom_rows_row_for_source(&folding.rows, line_number)
			if row >= 0 {
				height := alicorn.virtual_list_height_index_item_height(&view.wrap_height_index, line_number)
				_ = alicorn.virtual_list_height_index_set_height(&folding.index, row, height)
			}
		}
	}
	alicorn.virtual_list_height_index_rebuild_prefix(&folding.index)
	if folding.anchor_pending {
		line := int(folding.anchor_line)
		row := manual_folding_row_for_source(&folding.rows, line)
		if semantic_zoom_rows_hidden(&folding.rows, line) { folding.anchor_offset = 0 }
		_ = manual_folding_restore_anchor_at_row(view, folding, &folding.index, row)
	}
}

manual_folding_restore_anchor_at_row :: proc(
	view: ^Editor_View_State,
	folding: ^Editor_Manual_Folding,
	index: ^alicorn.Virtual_List_Height_Index,
	row: int,
) -> bool {
	if view == nil || folding == nil || index == nil || !folding.anchor_pending ||
	   row < 0 || row >= index.item_count {
		return false
	}
	view.scroll_y = max(alicorn.virtual_list_height_index_item_top(index, row)+folding.anchor_offset, 0)
	view.restore_y_pending = true
	view.restore_token = alicorn.RESTORE_TOKEN_NONE
	folding.anchor_pending = false
	return true
}

manual_folding_capture_anchor :: proc(app: ^App, rt: ^alicorn.Runtime, view: ^Editor_View_State, fallback_line: u64) {
	if view == nil { return }
	folding := &view.manual_folding
	folding.anchor_line, folding.anchor_offset = fallback_line, 0
	if rt != nil {
		scroll := alicorn.scroll_region_state(rt, app.editor_scroll_owner)
		index := editor_geometry_index(view)
		if scroll.id != 0 && index != nil && index.item_count > 0 {
			metrics := alicorn.virtual_list_variable_metrics(index, scroll.offset_y, scroll.viewport_height)
			folding.anchor_line = u64(max(editor_geometry_source_line(view, metrics.first), 0))
			folding.anchor_offset = scroll.offset_y-editor_geometry_line_top(view, int(folding.anchor_line))
		}
	}
	folding.anchor_pending = true
}

manual_folding_find_by_start :: proc(view: ^Editor_View_State, start_byte: u64) -> int {
	if !manual_folding_has_candidates(view) { return -1 }
	for fold, index in view.manual_folding.plan.folds {
		if fold.start_byte == start_byte { return index }
	}
	return -1
}

manual_folding_header_for_line :: proc(view: ^Editor_View_State, line: u64) -> (index: int, collapsed: bool, found: bool) {
	if !manual_folding_has_candidates(view) { return -1, false, false }
	first := -1
	for fold, candidate in view.manual_folding.plan.folds {
		if fold.start_line != line { continue }
		// Keep the remaining collapsed range reachable when several parser
		// candidates share one header and its single gutter control.
		if view.manual_folding.collapsed[candidate] { return candidate, true, true }
		if first < 0 { first = candidate }
	}
	return first, false, first >= 0
}

manual_folding_toggle :: proc(app: ^App, rt: ^alicorn.Runtime, document_id: string, instance_id, revision, start_byte: u64) {
	if app == nil || rt == nil || app.backend.state.active != document_id { return }
	view_index := editor_view_find(app.editor_views[:], document_id)
	if view_index < 0 { return }
	view := &app.editor_views[view_index]
	document, found := find_document(&app.backend.state, document_id)
	if !found || document.instance_id != instance_id || document.editor_revision != revision ||
	   !manual_folding_plan_matches(&view.manual_folding, document) || view.zoom.depth != 0 ||
	   view.optimistic_pending_edits != 0 {
		return
	}
	fold_index := manual_folding_find_by_start(view, start_byte)
	if fold_index < 0 { return }
	fold := view.manual_folding.plan.folds[fold_index]
	was_collapsed := view.manual_folding.collapsed[fold_index]
	if !was_collapsed && manual_folding_selection_overlaps_fold(view, fold) { return }
	manual_folding_capture_anchor(app, rt, view, view.manual_folding.plan.folds[fold_index].start_line)
	view.manual_folding.collapsed[fold_index] = !was_collapsed
	if !manual_folding_rebuild_rows(&view.manual_folding) {
		view.manual_folding.collapsed[fold_index] = was_collapsed
		return
	}
	if !was_collapsed { manual_folding_move_caret_out_of_fold(view, fold) }
	manual_folding_clear_geometry_index(&view.manual_folding)
	manual_folding_sync_geometry(view, nil, editor_text_scale_effective(app))
	view.restore_y_pending = true
	alicorn.invalidate_root(rt, "Scratchpad toggled a source fold")
}

manual_folding_clear_geometry_index :: proc(folding: ^Editor_Manual_Folding) {
	if folding != nil && folding.index_ready {
		alicorn.virtual_list_height_index_destroy(&folding.index)
		folding.index_ready = false
	}
}

manual_folding_set_all :: proc(app: ^App, rt: ^alicorn.Runtime, collapse: bool) {
	if app == nil || rt == nil { return }
	document, found := find_document(&app.backend.state, app.backend.state.active)
	if !found { return }
	view_index := editor_view_find(app.editor_views[:], document.id)
	if view_index < 0 { return }
	view := &app.editor_views[view_index]
	if !manual_folding_plan_matches(&view.manual_folding, document) || view.zoom.depth != 0 || view.optimistic_pending_edits != 0 { return }
	changed := false
	previous: [4096]bool
	for fold, index in view.manual_folding.plan.folds {
		previous[index] = view.manual_folding.collapsed[index]
		target := collapse
		if collapse && manual_folding_selection_overlaps_fold(view, fold) {
			// A fold must not discard or shorten the editor's authoritative
			// source selection. Leave any intersecting range expanded.
			target = previous[index]
		}
		if target != previous[index] { changed = true }
	}
	if !changed { return }
	manual_folding_capture_anchor(app, rt, view, 0)
	for fold, index in view.manual_folding.plan.folds {
		target := collapse
		if collapse && manual_folding_selection_overlaps_fold(view, fold) { target = previous[index] }
		view.manual_folding.collapsed[index] = target
	}
	if !manual_folding_rebuild_rows(&view.manual_folding) {
		for index in 0..<len(view.manual_folding.collapsed) { view.manual_folding.collapsed[index] = previous[index] }
		return
	}
	if collapse {
		for fold, index in view.manual_folding.plan.folds {
			if !previous[index] && view.manual_folding.collapsed[index] { manual_folding_move_caret_out_of_fold(view, fold) }
		}
	}
	manual_folding_clear_geometry_index(&view.manual_folding)
	manual_folding_sync_geometry(view, nil, editor_text_scale_effective(app))
	view.restore_y_pending = true
	alicorn.invalidate_root(rt, "Scratchpad changed all source folds")
}

manual_folding_toggle_index :: proc(view: ^Editor_View_State) -> int {
	if !manual_folding_has_candidates(view) { return -1 }
	best := -1
	span := u64(0xFFFF_FFFF_FFFF_FFFF)
	for fold, index in view.manual_folding.plan.folds {
		if view.caret_byte >= fold.start_byte && view.caret_byte < fold.end_byte {
			width := fold.end_byte-fold.start_byte
			if width < span { best, span = index, width }
		}
	}
	return best
}

manual_folding_move_caret_out_of_fold :: proc(view: ^Editor_View_State, fold: bridge.Editor_Fold) {
	if view == nil { return }
	hides_caret := view.caret_byte >= fold.body_start_byte && view.caret_byte < fold.end_byte
	if hides_caret && view.selection_anchor == view.caret_byte {
		view.selection_anchor = fold.start_byte
		view.caret_byte = fold.start_byte
		view.anchor_affinity, view.caret_affinity = .Leading, .Leading
		view.preferred_x_set = false
	}
}

manual_folding_selection_overlaps_fold :: proc(view: ^Editor_View_State, fold: bridge.Editor_Fold) -> bool {
	if view == nil || view.selection_anchor == view.caret_byte { return false }
	selection_start := min(view.selection_anchor, view.caret_byte)
	selection_end := max(view.selection_anchor, view.caret_byte)
	return selection_start < fold.end_byte && selection_end > fold.body_start_byte
}

manual_folding_toggle_at_caret :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil { return }
	document, found := find_document(&app.backend.state, app.backend.state.active)
	if !found { return }
	view_index := editor_view_find(app.editor_views[:], document.id)
	if view_index < 0 { return }
	view := &app.editor_views[view_index]
	if !manual_folding_plan_matches(&view.manual_folding, document) || view.zoom.depth != 0 { return }
	best := manual_folding_toggle_index(view)
	if best >= 0 {
		manual_folding_toggle(app, rt, document.id, document.instance_id, document.editor_revision,
			view.manual_folding.plan.folds[best].start_byte)
	}
}

manual_folding_reveal_pending :: proc(app: ^App, rt: ^alicorn.Runtime, document: bridge.State_Document, view: ^Editor_View_State) {
	if !manual_folding_plan_matches(&view.manual_folding, document) || view.zoom.depth != 0 || view.optimistic_pending_edits != 0 { return }
	if view.reveal_request.pending && view.reveal_request.document_id == document.id &&
	   view.reveal_request.editor_revision == document.editor_revision {
		manual_folding_reveal_range(app, rt, view, view.reveal_request.source_start, view.reveal_request.source_end)
		return
	}
	if view.pending_goto_line && view.pending_goto_target_line > 0 {
		line := view.pending_goto_target_line-1
		manual_folding_reveal_lines(app, rt, view, line, line+1)
	}
}

manual_folding_reveal_range :: proc(app: ^App, rt: ^alicorn.Runtime, view: ^Editor_View_State, start_byte, end_byte: u64) {
	if view == nil { return }
	folding := &view.manual_folding
	changed := false
	previous: [4096]bool
	for index in 0..<len(folding.collapsed) { previous[index] = folding.collapsed[index] }
	for fold, index in view.manual_folding.plan.folds {
		contains_target := start_byte == end_byte && start_byte >= fold.body_start_byte && start_byte < fold.end_byte
		overlaps_target := start_byte < end_byte && fold.body_start_byte < end_byte && fold.end_byte > start_byte
		if !contains_target && !overlaps_target { continue }
		if folding.collapsed[index] { folding.collapsed[index] = false; changed = true }
	}
	if !changed { return }
	if !manual_folding_rebuild_rows(folding) {
		for index in 0..<len(folding.collapsed) { folding.collapsed[index] = previous[index] }
		return
	}
	manual_folding_clear_geometry_index(folding)
	manual_folding_sync_geometry(view, nil, editor_text_scale_effective(app))
	view.restore_y_pending = true
	alicorn.invalidate_root(rt, "Scratchpad revealed a source target through collapsed folds")
}

manual_folding_reveal_lines :: proc(app: ^App, rt: ^alicorn.Runtime, view: ^Editor_View_State, start_line, end_line: u64) {
	folding := &view.manual_folding
	changed := false
	previous: [4096]bool
	for index in 0..<len(folding.collapsed) { previous[index] = folding.collapsed[index] }
	for fold, index in folding.plan.folds {
		if !folding.collapsed[index] || fold.body_start_line >= end_line || fold.end_line <= start_line { continue }
		folding.collapsed[index] = false
		changed = true
	}
	if !changed { return }
	if !manual_folding_rebuild_rows(folding) {
		for index in 0..<len(folding.collapsed) { folding.collapsed[index] = previous[index] }
		return
	}
	manual_folding_clear_geometry_index(folding)
	manual_folding_sync_geometry(view, nil, editor_text_scale_effective(app))
	view.restore_y_pending = true
	alicorn.invalidate_root(rt, "Scratchpad revealed a source target through collapsed folds")
}

// Overlay the marker at the end of the last visual line. Keep the source in
// its own Row so the marker grid cannot change the text's layout constraints.
manual_folding_ellipsis_begin :: proc(
	ui: ^alicorn.UI, rt: ^alicorn.Runtime, line: ^Editor_Display_Line,
	width, row_height, scale: f32, wraps: bool, spans: []alicorn.Text_Style_Span,
) -> alicorn.Node_ID {
	overflow := alicorn.Text_Overflow.Wrap if wraps else .Clip
	run, ok := editor_temporary_text_run(rt, line, width if wraps else 0, overflow, spans, scale)
	if !ok { return 0 }
	defer alicorn.text_run_destroy(&run)
	if len(run.lines) == 0 { return 0 }
	last := run.lines[len(run.lines)-1]
	left := last.x+last.width+4*scale
	marker_width := 12*scale
	if last.y >= row_height || (wraps && left+marker_width > width) { return 0 }
	columns := [?]alicorn.Grid_Track{alicorn.grid_fixed(left), alicorn.grid_fixed(max(width-left, marker_width))}
	rows := [?]alicorn.Grid_Track{alicorn.grid_fixed(last.y), alicorn.grid_fixed(row_height-last.y)}
	style := alicorn.layout_style(.Row, width=width, height=row_height)
	if alicorn.grid_begin(ui, "fold-inline", columns[:], rows[:], style=style) == 0 { return 0 }
	source := alicorn.container_begin(ui, .Container, key="fold-inline-source", style=style)
	if source == 0 { alicorn.grid_end(ui) }
	return source
}

manual_folding_ellipsis_end :: proc(ui: ^alicorn.UI, source: alicorn.Node_ID) {
	alicorn.container_end(ui)
	_ = alicorn.grid_cell(ui, source, 0, 0, row_span=2, column_span=2, align_x=.Start, align_y=.Start)
	marker := gui.text(ui, "…", key="fold-inline-ellipsis", font=.Monospace,
		color=alicorn.style_color(ui, .Muted_Text), decorative=true)
	_ = alicorn.grid_cell(ui, marker, 1, 1, align_x=.Start, align_y=.Start)
	alicorn.grid_end(ui)
}

manual_folding_header_button :: proc(app: ^App, ui: ^alicorn.UI, document: bridge.State_Document, view: ^Editor_View_State, line: u64) -> bool {
	index, collapsed, found := manual_folding_header_for_line(view, line)
	if !found { return false }
	fold := view.manual_folding.plan.folds[index]
	label := fmt.tprintf("Collapse %s", fold.label)
	if collapsed { label = fmt.tprintf("Expand %s, %d lines hidden", fold.label, fold.end_line-fold.body_start_line) }
	icon: alicorn.Icon_ID = .Chevron_Right if collapsed else .Chevron_Down
	if gui.icon_button(ui, label, icon,
		key=fmt.tprintf("manual-fold-gutter-%d-%d-%d", document.instance_id, document.editor_revision, fold.start_byte),
		style=alicorn.layout_style(width=12, height=22)) {
		_ = frame_deferred_action_schedule(app, .Toggle_Manual_Fold,
			document_id=document.id, editor_revision=document.editor_revision,
			source_instance_id=document.instance_id, source_start=fold.start_byte)
	}
	if collapsed { _ = alicorn.tooltip(ui, label) }
	return collapsed
}

manual_folding_action :: proc(app: ^App, rt: ^alicorn.Runtime, action: string) -> bool {
	if action != ACTION_EDITOR_TOGGLE_FOLD && action != ACTION_EDITOR_FOLD_ALL && action != ACTION_EDITOR_UNFOLD_ALL { return false }
	if app == nil || rt == nil { return true }
	if app.ui_description_runtime == rt {
		document, found := find_document(&app.backend.state, app.backend.state.active)
		if found {
			_ = frame_deferred_action_schedule(app, .Action, action,
				document_id=document.id, editor_revision=document.editor_revision,
				source_instance_id=document.instance_id)
		}
		return true
	}
	document, found := find_document(&app.backend.state, app.backend.state.active)
	if found {
		_ = manual_folding_run_action(app, rt, action, document.id, document.instance_id, document.editor_revision)
	}
	return true
}

manual_folding_run_action :: proc(
	app: ^App,
	rt: ^alicorn.Runtime,
	action, document_id: string,
	instance_id, revision: u64,
) -> bool {
	if action != ACTION_EDITOR_TOGGLE_FOLD && action != ACTION_EDITOR_FOLD_ALL && action != ACTION_EDITOR_UNFOLD_ALL { return false }
	if app == nil || rt == nil || app.backend.state.active != document_id { return true }
	document, found := find_document(&app.backend.state, document_id)
	if !found || document.instance_id != instance_id || document.editor_revision != revision { return true }
	if action == ACTION_EDITOR_TOGGLE_FOLD { manual_folding_toggle_at_caret(app, rt)
	} else { manual_folding_set_all(app, rt, action == ACTION_EDITOR_FOLD_ALL) }
	return true
}

manual_folding_menu_enabled :: proc(view: ^Editor_View_State, document: bridge.State_Document, action: string) -> bool {
	if view == nil || !manual_folding_plan_matches(&view.manual_folding, document) || !manual_folding_has_candidates(view) { return false }
	if document.view_kind != "" && document.view_kind != "text" { return false }
	if action == ACTION_EDITOR_UNFOLD_ALL {
		for collapsed in view.manual_folding.collapsed { if collapsed { return true } }
		return false
	}
	if action == ACTION_EDITOR_FOLD_ALL {
		for collapsed in view.manual_folding.collapsed { if !collapsed { return true } }
		return false
	}
	return action == ACTION_EDITOR_TOGGLE_FOLD && manual_folding_toggle_index(view) >= 0
}
