package main

import "core:fmt"
import "core:strings"
import "core:time"
import alicorn "alicorn:runtime"
import bridge "./bridge"

ACTION_SEMANTIC_MORE :: "view.semantic-more-detail"
ACTION_SEMANTIC_LESS :: "view.semantic-less-detail"
ACTION_SEMANTIC_FULL :: "view.semantic-full-source"

Semantic_Zoom_Wheel :: enum { Primary_Alt, Primary_Shift, Disabled }

Editor_Semantic_Zoom :: struct {
	depth: int,
	plan: bridge.Semantic_Zoom_Plan,
	owned: bool,
	rows: Semantic_Zoom_Rows,
	index: alicorn.Virtual_List_Height_Index,
	index_ready: bool,
	windows: [dynamic]Editor_Window,
	anchor_byte, anchor_line: u64,
	anchor_offset, anchor_in_line: f32,
	anchor_pending: bool,
	wheel_delta: f32,
	wheel_at: time.Tick,
	wheel_latched, wheel_intent: bool,
	wheel_mode: Semantic_Zoom_Wheel,
	waiting: bool,
	waiting_presentation: u64,
	waiting_ready: bool,
}

semantic_zoom_plan_matches :: proc(view: ^Editor_View_State, document: bridge.State_Document) -> bool {
	return view.zoom.owned && view.zoom.plan.document_id == document.id &&
	       view.zoom.plan.revision == document.editor_revision && view.zoom.plan.instance_id == document.instance_id
}

// Pending descriptions borrow text until end_frame. A cache eviction may happen
// while emitting a later row, so copied source text lives in the frame arena.
semantic_zoom_frame_text :: proc(rt: ^alicorn.Runtime, value: string) -> string {
	copy, err := strings.clone(value, alicorn.runtime_scratch_allocator(rt))
	return copy if err == nil else ""
}

semantic_zoom_destroy :: proc(zoom: ^Editor_Semantic_Zoom, allocator := context.allocator) {
	if zoom == nil { return }
	if zoom.index_ready { alicorn.virtual_list_height_index_destroy(&zoom.index) }
	semantic_zoom_rows_destroy(&zoom.rows)
	for &window in zoom.windows { editor_window_destroy(&window) }
	delete(zoom.windows)
	if zoom.owned { bridge.Semantic_Zoom_Plan_Destroy(&zoom.plan, allocator) }
	zoom^ = {}
}

semantic_zoom_find_window :: proc(view: ^Editor_View_State, line: u64) -> ^Editor_Window {
	for &window in view.zoom.windows {
		if line >= window.start_line && line < window.end_line { return &window }
	}
	return nil
}

semantic_zoom_source_window :: proc(app: ^App, view: ^Editor_View_State, document: bridge.State_Document, line: u64) -> ^Editor_Window {
	if !semantic_zoom_plan_matches(view, document) { return nil }
	if cached := semantic_zoom_find_window(view, line); cached != nil { return cached }
	result := bridge.backend_command(&app.backend, "read_visible_lines", document_id=document.id,
		start_line=line, max_lines=8, max_bytes=16*1024, include_presentation=true, read_latest_after=false)
	defer bridge.backend_command_result_destroy(&result, context.allocator)
	if !result.ok || !result.visible_window_owned || result.visible_window.editor_revision != document.editor_revision { return nil }
	window, ok, _ := editor_window_from_visible(&result.visible_window)
	if !ok { return nil }
	if editor_window_is_long_line_chunk(&window) {
		// The ordinary source lane already implements chunked horizontal travel.
		// Return to it rather than displaying an unreachable truncated line.
		editor_window_destroy(&window)
		_ = frame_deferred_action_schedule(app, .Action, ACTION_SEMANTIC_FULL)
		return nil
	}
	if view.zoom.windows.allocator.procedure == nil { view.zoom.windows = make([dynamic]Editor_Window, 0) }
	if len(view.zoom.windows) >= 64 {
		editor_window_destroy(&view.zoom.windows[0])
		ordered_remove(&view.zoom.windows, 0)
	}
	append(&view.zoom.windows, window)
	return &view.zoom.windows[len(view.zoom.windows)-1]
}

semantic_zoom_active :: proc(view: ^Editor_View_State) -> bool {
	return view != nil && view.zoom.depth > 0 && view.zoom.owned && view.zoom.plan.ready &&
	       view.zoom.plan.supported && view.zoom.plan.depth == view.zoom.depth && view.zoom.index_ready && len(view.zoom.rows.folds) > 0
}

semantic_zoom_frontier_width :: proc(app: ^App, rt: ^alicorn.Runtime, view: ^Editor_View_State, document: bridge.State_Document,
	scroll_y, viewport_height, gutter, wrap_width, scale: f32) -> f32 {
	metrics := alicorn.virtual_list_variable_metrics(&view.zoom.index, scroll_y, viewport_height)
	width: f32
	for row := metrics.first; row < metrics.last; row += 1 {
		line_number, fold, ok := semantic_zoom_rows_source_at(&view.zoom.rows, row)
		if !ok || fold >= 0 { continue }
		window := semantic_zoom_source_window(app, view, document, u64(line_number))
		if window == nil { continue }
		if editor_measure_window_wrapping(rt, view, window, document.language, wrap_width, window.presentation_ready, scale) {
			semantic_zoom_sync_geometry(view, window, scale)
			alicorn.invalidate_root(rt, "Scratchpad measured the semantic source frontier")
		}
		if line, found := editor_window_line(window, u64(line_number)); found &&
		   !editor_line_should_wrap_for_view(document.language, window, line, window.presentation_ready, wrap_width, view.wrap_mode, scale) {
			width = max(width, f32(len(line.display))*10*scale+gutter+16*scale)
		}
	}
	return width
}

editor_geometry_index :: proc(view: ^Editor_View_State) -> ^alicorn.Virtual_List_Height_Index {
	if semantic_zoom_active(view) { return &view.zoom.index }
	return &view.wrap_height_index
}

editor_geometry_source_line :: proc(view: ^Editor_View_State, row: int) -> int {
	if semantic_zoom_active(view) {
		line, _, ok := semantic_zoom_rows_source_at(&view.zoom.rows, row)
		return line if ok else 0
	}
	return row
}

editor_geometry_row :: proc(view: ^Editor_View_State, line: int) -> int {
	if semantic_zoom_active(view) { return semantic_zoom_rows_row_for_source(&view.zoom.rows, line) }
	return line
}

editor_geometry_line_top :: proc(view: ^Editor_View_State, line: int) -> f32 {
	return alicorn.virtual_list_height_index_item_top(editor_geometry_index(view), editor_geometry_row(view, line))
}

semantic_zoom_sync_geometry :: proc(view: ^Editor_View_State, window: ^Editor_Window, scale: f32) {
	z := &view.zoom
	if z.depth == 0 || !z.owned || !z.plan.ready || !z.plan.supported { return }
	if !z.index_ready || z.index.item_count != z.rows.row_count || z.index.estimated_height != EDITOR_ROW_HEIGHT*scale {
		if z.index_ready { alicorn.virtual_list_height_index_destroy(&z.index) }
		z.index_ready = alicorn.virtual_list_height_index_init(&z.index, z.rows.row_count, EDITOR_ROW_HEIGHT*scale)
		if !z.index_ready { return }
		for entry in view.wrap_height_index.entries {
			if semantic_zoom_rows_hidden(&z.rows, entry.index) { continue }
			row := semantic_zoom_rows_row_for_source(&z.rows, entry.index)
			_ = alicorn.virtual_list_height_index_set_height(&z.index, row, entry.height)
		}
		for fold in z.rows.folds {
			if !fold.fold.silent { _ = alicorn.virtual_list_height_index_set_height(&z.index, fold.row, 28*scale) }
		}
	}
	if window != nil {
		for line in window.lines {
			if semantic_zoom_rows_hidden(&z.rows, int(line.logical_line)) { continue }
			row := semantic_zoom_rows_row_for_source(&z.rows, int(line.logical_line))
			height := alicorn.virtual_list_height_index_item_height(&view.wrap_height_index, int(line.logical_line))
			_ = alicorn.virtual_list_height_index_set_height(&z.index, row, height)
		}
	}
	alicorn.virtual_list_height_index_rebuild_prefix(&z.index)
}

semantic_zoom_anchor_capture :: proc(app: ^App, rt: ^alicorn.Runtime, view: ^Editor_View_State, source: u64) {
	z := &view.zoom
	if z.depth == 0 || source != z.anchor_byte {
		z.anchor_byte = source
		if window, exact := editor_view_window(view, &app.editor_window, app.editor_window_ready, view.document_id, view.authoritative_revision); exact {
			if line, found := editor_line_for_source(window, source); found { z.anchor_line = line.logical_line }
		}
		for &window in z.windows {
			if line, found := editor_line_for_source(&window, source); found { z.anchor_line = line.logical_line; break }
		}
	}
	scroll := alicorn.scroll_region_state(rt, app.editor_scroll_owner)
	z.anchor_offset = editor_geometry_line_top(view, int(z.anchor_line))-scroll.offset_y
	for target in app.editor_row_targets {
		if target.logical_line != z.anchor_line { continue }
		window, _ := editor_presentation_window(view, &app.editor_window, app.editor_window_ready, view.document_id, view.authoritative_revision)
		if cached := semantic_zoom_find_window(view, target.logical_line); cached != nil { window = cached }
		line, found := editor_window_line(window, z.anchor_line)
		if !found { break }
		geometry := alicorn.text_node_caret_geometry(rt, target.node, alicorn.Text_Position{byte=editor_source_to_display(line, source), affinity=view.caret_affinity})
		if node, ok := alicorn.node_info(rt, target.node); ok && geometry.valid {
			z.anchor_in_line = geometry.rect.y-node.bounds.y
			z.anchor_offset += z.anchor_in_line
		}
		break
	}
	if z.anchor_offset < 0 || z.anchor_offset >= scroll.viewport_height {
		z.anchor_offset = max(scroll.viewport_height*0.4, 0)
	}
	z.anchor_pending = true
}

semantic_zoom_load :: proc(app: ^App, rt: ^alicorn.Runtime, document: bridge.State_Document, view: ^Editor_View_State) -> bool {
	z := &view.zoom
	result := bridge.backend_command(&app.backend, "read_semantic_zoom", document_id=document.id,
		editor_revision=document.editor_revision, anchor_byte=z.anchor_byte, zoom_depth=z.depth, read_latest_after=false)
	defer bridge.backend_command_result_destroy(&result, context.allocator)
	if !result.ok || !result.semantic_zoom_owned {
		set_error(app, result.message if result.message != "" else "Could not prepare semantic zoom.")
		return false
	}
	plan := result.semantic_zoom
	if plan.document_id != document.id || plan.revision != document.editor_revision || plan.depth != z.depth { return false }
	if z.index_ready { alicorn.virtual_list_height_index_destroy(&z.index); z.index_ready = false }
	for &window in z.windows { editor_window_destroy(&window) }
	clear(&z.windows)
	semantic_zoom_rows_destroy(&z.rows)
	if z.owned { bridge.Semantic_Zoom_Plan_Destroy(&z.plan) }
	z.plan, z.owned = plan, true
	result.semantic_zoom, result.semantic_zoom_owned = {}, false
	z.waiting, z.waiting_presentation = !plan.ready, document.presentation_revision
	z.waiting_ready = document.presentation_ready
	if plan.ready && !plan.supported {
		message := "This file type has no semantic structure yet. Full source is available."
		if plan.reason == "fold_limit_exceeded" { message = "This document has too many separate folds for this experiment. Showing Full source." }
		set_error(app, message)
		z.depth = 0
		return false
	}
	if plan.ready && !semantic_zoom_rows_init(&z.rows, plan.folds, int(plan.line_count)) {
		set_error(app, "Invalid source folding plan; showing full source.")
		z.depth = 0
		return false
	}
	return true
}

semantic_zoom_set_depth :: proc(app: ^App, rt: ^alicorn.Runtime, depth: int, source: u64) -> bool {
	if app == nil || rt == nil || !app.backend.started { return false }
	document, found := find_document(&app.backend.state, app.backend.state.active)
	if !found || document.view_kind == "image" || document.view_kind == "unsupported" { return false }
	index, ok := editor_view_ensure(&app.editor_views, document.id)
	if !ok { return false }
	view := &app.editor_views[index]
	if view.zoom.depth > 0 && !semantic_zoom_plan_matches(view, document) {
		semantic_zoom_reveal_input(app, rt, view)
		return false
	}
	if len(app.editor_edits) > 0 || view.preedit_active || view.preedit_recoverable || view.dragging_selection {
		set_error(app, "Finish the current input before changing semantic detail.")
		alicorn.invalidate_root(rt, "semantic zoom waits for committed source")
		return false
	}
	next_depth := clamp(depth, 0, 3)
	if next_depth == view.zoom.depth { return true }
	semantic_zoom_anchor_capture(app, rt, view, source)
	view.zoom.depth = next_depth
	view.zoom.waiting = false
	if next_depth > 0 && !semantic_zoom_load(app, rt, document, view) {
		view.zoom.depth, view.zoom.waiting = 0, false
		view.restore_y_pending = true
		view.restore_token = alicorn.RESTORE_TOKEN_NONE
		alicorn.invalidate_root(rt, "Scratchpad restored full source after a rejected zoom transition")
		return false
	}
	view.restore_y_pending = true
	view.restore_token = alicorn.RESTORE_TOKEN_NONE
	alicorn.invalidate_root(rt, "semantic zoom changed source visibility")
	return true
}

semantic_zoom_prepare :: proc(app: ^App, rt: ^alicorn.Runtime, document: bridge.State_Document, view: ^Editor_View_State) {
	z := &view.zoom
	if z.depth > 0 && z.owned && !semantic_zoom_plan_matches(view, document) {
		// An edit or reload invalidates source coordinates. Require another explicit
		// zoom after returning to source; parser completion never folds while typing.
		semantic_zoom_reveal_input(app, rt, view)
	}
	if z.waiting && document.presentation_ready && (!z.waiting_ready || document.presentation_revision != z.waiting_presentation) {
		_ = semantic_zoom_load(app, rt, document, view)
	}
}

semantic_zoom_session_scroll :: proc(view: ^Editor_View_State) -> f32 {
	if view.zoom.depth == 0 || !view.wrap_height_index_ready { return view.scroll_y }
	return max(alicorn.virtual_list_height_index_item_top(&view.wrap_height_index, int(view.zoom.anchor_line))+view.zoom.anchor_in_line-view.zoom.anchor_offset, 0)
}

semantic_zoom_reveal_input :: proc(app: ^App, rt: ^alicorn.Runtime, view: ^Editor_View_State) {
	if view == nil || view.zoom.depth == 0 { return }
	if document, found := find_document(&app.backend.state, view.document_id); found && view.zoom.owned && !semantic_zoom_plan_matches(view, document) {
		// A different source instance/revision cannot inherit hidden coordinates.
		view.selection_anchor = min(document.anchor_byte, document.byte_length)
		view.caret_byte = min(document.cursor_byte, document.byte_length)
		view.anchor_affinity, view.caret_affinity = .Leading, alicorn.Text_Affinity(document.affinity)
		semantic_zoom_destroy(&view.zoom)
		view.zoom.anchor_byte, view.zoom.anchor_line = view.caret_byte, 0
		view.authoritative_revision = document.editor_revision
		view.viewport_anchor_pending, view.viewport_anchor_resolved = false, false
		view.auto_pair_valid, view.pending_goto_line = false, false
		if view.optimistic_window_ready && view.optimistic_pending_edits == 0 {
			editor_window_destroy(&view.optimistic_window)
			view.optimistic_window_ready = false
		}
		editor_window_destroy(&app.editor_window)
		app.editor_window_ready = false
		editor_wrap_heights_reset(view, int(document.line_count), editor_text_scale_effective(app))
	}
	semantic_zoom_anchor_capture(app, rt, view, view.caret_byte)
	view.zoom.depth, view.zoom.waiting = 0, false
	if document, found := find_document(&app.backend.state, view.document_id); found {
		window, exact := editor_view_window(view, &app.editor_window, app.editor_window_ready, document.id, document.editor_revision)
		_, caret_loaded := editor_line_for_source(window, view.caret_byte)
		if !exact || !caret_loaded {
			result := bridge.backend_command(&app.backend, "read_visible_lines", document_id=document.id,
				start_line=view.zoom.anchor_line, anchor_byte=view.caret_byte, max_lines=bridge.MAX_VISIBLE_LINES,
				max_bytes=bridge.MAX_VISIBLE_BYTES, include_presentation=true, read_latest_after=false)
			if result.ok && result.visible_window_owned && result.visible_window.editor_revision == document.editor_revision {
				fresh, ok, _ := editor_window_from_visible(&result.visible_window)
				if ok {
					if view.optimistic_window_ready && view.optimistic_pending_edits == 0 {
						editor_window_destroy(&view.optimistic_window)
						view.optimistic_window_ready = false
					}
					editor_window_destroy(&app.editor_window)
					app.editor_window, app.editor_window_ready = fresh, true
				}
			}
			bridge.backend_command_result_destroy(&result, context.allocator)
		}
	}
	view.restore_y_pending = true
	view.restore_token = alicorn.RESTORE_TOKEN_NONE
	alicorn.invalidate_root(rt, "Scratchpad revealed source before editing or caret navigation")
}

semantic_zoom_resolve_anchor :: proc(app: ^App, rt: ^alicorn.Runtime, view: ^Editor_View_State, window: ^Editor_Window, viewport_height: f32, language: string) -> (offset: f32, apply: bool) {
	z := &view.zoom
	if !z.anchor_pending || !view.wrap_height_index_ready { return }
	index := editor_geometry_index(view)
	row := editor_geometry_row(view, int(z.anchor_line))
	local_y := z.anchor_in_line
	hidden := semantic_zoom_active(view) && semantic_zoom_rows_hidden(&z.rows, int(z.anchor_line))
	if hidden { local_y = 0 }
	resolved := hidden
	anchor_window := window
	if !hidden && semantic_zoom_active(view) {
		_, found := editor_line_for_source(anchor_window, z.anchor_byte)
		if !found {
			if document, exists := find_document(&app.backend.state, view.document_id); exists {
				anchor_window = semantic_zoom_source_window(app, view, document, z.anchor_line)
			}
		}
	}
	if !hidden && anchor_window != nil {
		if line, found := editor_line_for_source(anchor_window, z.anchor_byte); found {
			run, ok := editor_navigation_text_run(rt, anchor_window, line, language, view.wrap_measurement_width, anchor_window.presentation_ready, view.wrap_mode, editor_text_scale_effective(app))
			if ok {
				geometry := alicorn.text_run_caret_geometry(&run, alicorn.Text_Position{byte=editor_source_to_display(line, z.anchor_byte), affinity=view.caret_affinity}, context.temp_allocator)
				if geometry.valid { local_y = geometry.rect.y; resolved = true }
				alicorn.text_run_destroy(&run)
			}
		}
	}
	offset = max(alicorn.virtual_list_height_index_item_top(index, row)+local_y-z.anchor_offset, 0)
	offset = min(offset, max(index.total_height-viewport_height, 0))
	if resolved { z.anchor_pending = false }
	return offset, true
}

semantic_zoom_expand :: proc(app: ^App, rt: ^alicorn.Runtime, document_id: string, revision, start_line: u64) {
	if document_id != app.backend.state.active { return }
	i := editor_view_find(app.editor_views[:], document_id)
	if i < 0 { return }
	view := &app.editor_views[i]
	if !semantic_zoom_active(view) || view.zoom.plan.revision != revision { return }
	for fold, index in view.zoom.rows.folds {
		if fold.fold.start_line != start_line { continue }
		scroll := alicorn.scroll_region_state(rt, app.editor_scroll_owner)
		view.zoom.anchor_line, view.zoom.anchor_byte = fold.fold.start_line, fold.fold.start_byte
		view.zoom.anchor_offset = alicorn.virtual_list_height_index_item_top(&view.zoom.index, fold.row)-scroll.offset_y
		view.zoom.anchor_in_line, view.zoom.anchor_pending = 0, true
		_ = semantic_zoom_rows_expand(&view.zoom.rows, index)
		if view.zoom.index_ready { alicorn.virtual_list_height_index_destroy(&view.zoom.index); view.zoom.index_ready = false }
		view.restore_y_pending = true
		view.restore_token = alicorn.RESTORE_TOKEN_NONE
		alicorn.invalidate_root(rt, "Scratchpad expanded a source fold in place")
		return
	}
}

semantic_zoom_render_fold :: proc(app: ^App, ui: ^alicorn.UI, document: bridge.State_Document, fold: bridge.Semantic_Zoom_Fold, height: f32) {
	label := fmt.tprintf("… %d lines hidden (%d–%d) · expand", fold.end_line-fold.start_line, fold.start_line+1, fold.end_line)
	if alicorn.button(ui, label, key=alicorn.key_string(fmt.tprintf("semantic-fold-%d-%d-%d-%d", document.instance_id, document.editor_revision, fold.start_byte, fold.end_byte)), style=alicorn.layout_style(.Row, width=-1, height=height), variant=.Quiet,
		content_style=alicorn.button_content_style(.Start, .Center, padding_x=12, padding_y=0)) {
		_ = frame_deferred_action_schedule(app, .Expand_Semantic_Fold, document_id=document.id, editor_revision=document.editor_revision, source_start=fold.start_line)
	}
}

semantic_zoom_action :: proc(app: ^App, rt: ^alicorn.Runtime, action: string) -> bool {
	if action != ACTION_SEMANTIC_MORE && action != ACTION_SEMANTIC_LESS && action != ACTION_SEMANTIC_FULL { return false }
	if rt.frame_open { _ = frame_deferred_action_schedule(app, .Action, action); return true }
	if app.command_palette_open || app.settings_surface_open || app.quick_open_open || app.go_to_line_open || app.close_document_id != "" { return true }
	i := editor_view_find(app.editor_views[:], app.backend.state.active)
	if i < 0 { return true }
	view := &app.editor_views[i]
	depth := view.zoom.depth
	if action == ACTION_SEMANTIC_MORE { depth -= 1 }
	if action == ACTION_SEMANTIC_LESS { depth += 1 }
	if action == ACTION_SEMANTIC_FULL { depth = 0 }
	_ = semantic_zoom_set_depth(app, rt, depth, view.caret_byte)
	return true
}

semantic_zoom_wheel_matches :: proc(mode: Semantic_Zoom_Wheel, modifiers: alicorn.Input_Modifiers) -> bool {
	primary := modifiers.control
	when ODIN_OS == .Darwin { primary = modifiers.super }
	if mode == .Disabled { return false }
	if mode == .Primary_Shift { return primary && modifiers.shift && !modifiers.alt }
	return primary && modifiers.alt && !modifiers.shift
}

semantic_zoom_scroll_capture :: proc(state: rawptr, rt: ^alicorn.Runtime, event: alicorn.Scroll_Event, target: alicorn.Node_ID) -> bool {
	app := cast(^App)state
	if app == nil || target == 0 || target != app.editor_scroll_owner { return false }
	if app.command_palette_open || app.quick_open_open || app.settings_surface_open || app.go_to_line_open || app.workspace_mutation_kind != .None || app.close_document_id != "" || app.shutdown_intent != .None { return false }
	i := editor_view_find(app.editor_views[:], app.backend.state.active)
	if i < 0 || event.delta_y == 0 { return false }
	view := &app.editor_views[i]
	if !view.zoom.wheel_latched || time.tick_since(view.zoom.wheel_at) > 250*time.Millisecond || view.zoom.wheel_mode != app.semantic_zoom_wheel {
		view.zoom.wheel_delta = 0
		view.zoom.wheel_latched = true
		view.zoom.wheel_intent = semantic_zoom_wheel_matches(app.semantic_zoom_wheel, event.modifiers)
		view.zoom.wheel_mode = app.semantic_zoom_wheel
	}
	view.zoom.wheel_at = time.tick_now()
	if !view.zoom.wheel_intent { return false }
	if !semantic_zoom_wheel_matches(app.semantic_zoom_wheel, event.modifiers) { view.zoom.wheel_delta = 0; return true }
	view.zoom.wheel_delta += event.delta_y
	if abs(view.zoom.wheel_delta) < 1 { return true }
	step := -1 if view.zoom.wheel_delta > 0 else 1
	view.zoom.wheel_delta = 0
	source := view.caret_byte
	if view.zoom.depth > 0 { source = view.zoom.anchor_byte }
	for row in app.editor_row_targets {
		if node, found := alicorn.node_info(rt, row.node); found && event.x >= node.bounds.x && event.x < node.bounds.x+node.bounds.w && event.y >= node.bounds.y && event.y < node.bounds.y+node.bounds.h {
			if position, _, ok := semantic_zoom_pointer_source(app, rt, view, event.x, event.y); ok { source = position }
			break
		}
	}
	_ = semantic_zoom_set_depth(app, rt, view.zoom.depth+step, source)
	return true
}

semantic_zoom_pointer_source :: proc(app: ^App, rt: ^alicorn.Runtime, view: ^Editor_View_State, x, y: f32) -> (source: u64, affinity: alicorn.Text_Affinity, ok: bool) {
	if !semantic_zoom_active(view) { return editor_source_at_pointer(app, rt, x, y) }
	document, current := find_document(&app.backend.state, view.document_id)
	if !current || !semantic_zoom_plan_matches(view, document) { return }
	for row in app.editor_row_targets {
		node, found := alicorn.node_info(rt, row.node)
		if !found || x < node.bounds.x || x >= node.bounds.x+node.bounds.w || y < node.bounds.y || y >= node.bounds.y+node.bounds.h { continue }
		window := semantic_zoom_find_window(view, row.logical_line)
		if window == nil { window = semantic_zoom_source_window(app, view, document, row.logical_line) }
		if window == nil || window.editor_revision != document.editor_revision { return }
		line, line_found := editor_window_line(window, row.logical_line)
		if !line_found { return }
		position, hit := alicorn.text_node_hit_test(rt, row.node, x, y)
		if !hit { return }
		display_line, display_found := editor_display_line_for_target(window, line, row)
		if !display_found { return }
		return editor_normalize_source_position(&display_line, editor_display_to_source(&display_line, position.byte)), position.affinity, true
	}
	return
}

semantic_zoom_title :: proc(depth: int) -> string {
	titles := [4]string{"Full", "Focus", "Skim", "Overview"}
	return titles[clamp(depth, 0, 3)]
}
