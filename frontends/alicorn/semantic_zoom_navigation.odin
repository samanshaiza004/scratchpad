package main

import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"
import bridge "./bridge"

Semantic_Zoom_Navigation_Line :: struct {
	window: ^Editor_Window,
	line: ^Editor_Display_Line,
	display: Editor_Display_Line,
	target: Editor_Row_Target,
	width: f32,
	origin_x: f32,
	presentation_current: bool,
}

semantic_zoom_navigation_context :: proc(
	app: ^App,
	rt: ^alicorn.Runtime,
	document: bridge.State_Document,
	view: ^Editor_View_State,
	source: u64,
) -> (result: Semantic_Zoom_Navigation_Line, ok: bool) {
	result.window = semantic_zoom_source_window_at_byte(app, view, document, source)
	if result.window == nil { return result, false }
	result.line, ok = editor_line_for_source(result.window, source)
	if !ok { return result, false }
	result.target, _ = editor_row_target_for_source(app.editor_row_targets[:], result.line.logical_line, source)
	result.display, ok = editor_display_line_for_target(result.window, result.line, result.target)
	if !ok { return result, false }
	owner, owner_found := alicorn.node_info(rt, app.editor_scroll_owner)
	text_scale := editor_text_scale_effective(app)
	width := f32(1200)
	if owner_found {
		gutter := editor_line_number_gutter_width(document.line_count, text_scale)
		width = max(owner.scroll_viewport_width-gutter-16*text_scale, 80*text_scale)
	}
	if result.target.is_cell {
		width, result.origin_x = result.target.cell_width, result.target.cell_origin_x
	}
	result.width = width
	result.presentation_current = result.window.presentation_ready && !result.window.presentation_stale &&
		result.window.presentation_revision == result.window.editor_revision && document.presentation_ready &&
		document.presentation_revision == result.window.presentation_revision
	return result, true
}

semantic_zoom_navigation_adjacent_line :: proc(
	app: ^App,
	document: bridge.State_Document,
	view: ^Editor_View_State,
	current_line: int,
	direction: int,
) -> (window: ^Editor_Window, line: ^Editor_Display_Line, ok: bool) {
	if direction == 0 { return }
	row := semantic_zoom_rows_row_for_source(&view.zoom.rows, current_line)
	for row += direction; row >= 0 && row < view.zoom.rows.row_count; row += direction {
		source_line, fold_index, mapped := semantic_zoom_rows_source_at(&view.zoom.rows, row)
		if !mapped || fold_index >= 0 || semantic_zoom_rows_hidden(&view.zoom.rows, source_line) { continue }
		window = semantic_zoom_source_window(app, view, document, u64(source_line))
		if window == nil || window.editor_revision != document.editor_revision { return nil, nil, false }
		line, ok = editor_window_line(window, u64(source_line))
		if ok { return window, line, true }
	}
	return nil, nil, false
}

semantic_zoom_navigation_crosses_hidden :: proc(view: ^Editor_View_State, anchor, caret: u64) -> bool {
	return semantic_zoom_selection_crosses_fold(view, min(anchor, caret), max(anchor, caret))
}

semantic_zoom_navigation_leave_fold :: proc(
	app: ^App,
	rt: ^alicorn.Runtime,
	document: bridge.State_Document,
	view: ^Editor_View_State,
	line: ^Editor_Display_Line,
	event: host.Application_Text_Key_Event,
) -> (source: u64, affinity: alicorn.Text_Affinity) {
	if line == nil { return view.caret_byte, view.caret_affinity }
	index := semantic_zoom_rows_fold_before_source(&view.zoom.rows, int(line.logical_line))
	if index < 0 { return view.caret_byte, view.caret_affinity }
	entry := view.zoom.rows.folds[index]
	if event.key == .Home || event.key == .Line_Start || event.key == .End || event.key == .Line_End {
		return entry.fold.start_byte, .Leading
	}
	direction := -1
	if event.key == .Right || event.key == .Word_Right || event.key == .Down || event.key == .Page_Down { direction = 1 }
	row := entry.row
	if direction < 0 || !entry.fold.silent { row += direction }
	if event.key == .Page_Up || event.key == .Page_Down {
		step := 1
		if owner, found := alicorn.node_info(rt, app.editor_scroll_owner); found {
			step = max(int(owner.scroll_viewport_height/(EDITOR_ROW_HEIGHT*editor_text_scale_effective(app)))-1, 1)
		}
		row = entry.row+direction*step
	}
	for row >= 0 && row < view.zoom.rows.row_count {
		source_line, fold_index, mapped := semantic_zoom_rows_source_at(&view.zoom.rows, row)
		if mapped && fold_index < 0 && !semantic_zoom_rows_hidden(&view.zoom.rows, source_line) {
			window := semantic_zoom_source_window(app, view, document, u64(source_line))
			if window == nil { break }
			target_line, found := editor_window_line(window, u64(source_line))
			if !found { break }
			if event.key == .Word_Left || event.key == .Word_Right {
				boundary := target_line.source_start if direction > 0 else target_line.source_end
				affinity := alicorn.Text_Affinity.Leading if direction > 0 else .Trailing
				if target_context, context_ok := semantic_zoom_navigation_context(app, rt, document, view, boundary); context_ok {
					word_direction := -1 if direction < 0 else 1
					next, next_affinity, moved := semantic_zoom_navigation_move_word(rt, &target_context.display,
						boundary, affinity, word_direction, event.control && event.alt)
					if moved { return next, next_affinity }
				}
			}
			if direction > 0 { return target_line.source_start, .Leading }
			return target_line.source_end, .Trailing
		}
		row += direction
	}
	return entry.fold.start_byte, .Leading
}

semantic_zoom_navigation_move_word :: proc(
	rt: ^alicorn.Runtime,
	line: ^Editor_Display_Line,
	source: u64,
	affinity: alicorn.Text_Affinity,
	direction: int,
	subword := false,
) -> (next: u64, next_affinity: alicorn.Text_Affinity, moved: bool) {
	if line == nil || direction == 0 { return source, affinity, false }
	display_byte := int(editor_source_to_display(line, source))
	if subword {
		if target, handled := editor_subword_move_ascii(line.display, display_byte, direction); handled {
			next = editor_normalize_source_position(line, editor_display_to_source(line, target))
			return next, affinity, next != source
		}
	}
	position := alicorn.Text_Position{byte=display_byte, affinity=affinity}
	target := alicorn.text_move_word(line.display, position, direction, context.temp_allocator)
	next = editor_normalize_source_position(line, editor_display_to_source(line, target.byte))
	return next, target.affinity, next != source
}

// Navigation in reduced detail operates on retained presentation rows. It is
// deliberately separate from editing: unsupported mutation keys still reveal
// Full source through editor_text_key before they reach the bounded edit lane.
semantic_zoom_navigation_key :: proc(
	app: ^App,
	rt: ^alicorn.Runtime,
	owner: alicorn.Node_ID,
	document: bridge.State_Document,
	view: ^Editor_View_State,
	event: host.Application_Text_Key_Event,
) -> bool {
	#partial switch event.key {
	case .Left, .Right, .Word_Left, .Word_Right, .Home, .End, .Line_Start, .Line_End,
		.Document_Start, .Document_End, .Up, .Down, .Page_Up, .Page_Down:
	case:
		return false
	}
	if !semantic_zoom_active(view) || !semantic_zoom_plan_matches(view, document) || view.preedit_active { return false }
	if event.super && event.key != .Document_Start && event.key != .Document_End { return false }
	if event.control && event.key != .Word_Left && event.key != .Word_Right && event.key != .Line_Start &&
		event.key != .Line_End && event.key != .Document_Start && event.key != .Document_End { return false }
	if event.alt && event.key != .Word_Left && event.key != .Word_Right && event.key != .Line_Start &&
		event.key != .Line_End { return false }

	old_caret, old_affinity := view.caret_byte, view.caret_affinity
	next_caret, next_affinity := old_caret, old_affinity
	selection_exists := view.selection_anchor != old_caret
	view.pending_document_edge, view.pending_document_edge_shift = .None, false
	direction := 0
	if event.key == .Left || event.key == .Word_Left || event.key == .Up || event.key == .Page_Up { direction = -1 }
	if event.key == .Right || event.key == .Word_Right || event.key == .Down || event.key == .Page_Down { direction = 1 }

	current, current_ok := semantic_zoom_navigation_context(app, rt, document, view, old_caret)
	if !current_ok { return true }
	line := current.line
	current_hidden := semantic_zoom_rows_hidden(&view.zoom.rows, int(line.logical_line))
	if current_hidden && event.key != .Document_Start && event.key != .Document_End {
		next_caret, next_affinity = semantic_zoom_navigation_leave_fold(app, rt, document, view, line, event)
	} else if direction < 0 && (event.key == .Left || event.key == .Word_Left) && selection_exists && !event.shift {
		next_caret, next_affinity = min(view.selection_anchor, old_caret), view.anchor_affinity
		if view.selection_anchor < old_caret { next_caret, next_affinity = view.selection_anchor, view.anchor_affinity }
		if view.caret_byte < view.selection_anchor { next_caret, next_affinity = view.caret_byte, view.caret_affinity }
	} else if direction > 0 && (event.key == .Right || event.key == .Word_Right) && selection_exists && !event.shift {
		next_caret, next_affinity = max(view.selection_anchor, old_caret), view.anchor_affinity
		if view.selection_anchor > old_caret { next_caret, next_affinity = view.selection_anchor, view.anchor_affinity }
		if view.caret_byte > view.selection_anchor { next_caret, next_affinity = view.caret_byte, view.caret_affinity }
	} else {
		#partial switch event.key {
		case .Left, .Right, .Word_Left, .Word_Right:
			word := event.key == .Word_Left || event.key == .Word_Right
			subword := event.control && event.alt
			if word {
				next_caret, next_affinity, _ = semantic_zoom_navigation_move_word(rt, &current.display, old_caret, old_affinity, direction, subword)
			} else {
				next_caret, next_affinity, _ = editor_move_horizontal(&current.display, old_caret, old_affinity, direction)
			}
			at_edge := direction < 0 && old_caret == current.display.source_start || direction > 0 && old_caret == current.display.source_end
			if next_caret == old_caret && at_edge {
				if next_window, next_line, found := semantic_zoom_navigation_adjacent_line(app, document, view, int(line.logical_line), direction); found {
					if word {
						if next_context, context_ok := semantic_zoom_navigation_context(app, rt, document, view, next_line.source_start if direction > 0 else next_line.source_end); context_ok {
							boundary := next_line.source_start if direction > 0 else next_line.source_end
							affinity := alicorn.Text_Affinity.Leading if direction > 0 else .Trailing
							next_caret, next_affinity, _ = semantic_zoom_navigation_move_word(rt, &next_context.display, boundary, affinity, direction, subword)
						}
					} else if direction > 0 {
						next_caret, next_affinity = next_line.source_start, .Leading
					} else {
						next_caret, next_affinity = next_line.source_end, .Trailing
					}
					_ = next_window
				}
			}
		case .Home, .Line_Start:
			next_caret = editor_normalize_source_position(&current.display, current.display.source_start)
			next_affinity = .Leading
		case .End, .Line_End:
			next_caret = editor_normalize_source_position(&current.display, current.display.source_end)
			next_affinity = .Trailing
		case .Document_Start, .Document_End:
			row := 0
			step := 1
			if event.key == .Document_End { row, step = view.zoom.rows.row_count-1, -1 }
			for row >= 0 && row < view.zoom.rows.row_count {
				source_line, fold_index, mapped := semantic_zoom_rows_source_at(&view.zoom.rows, row)
				if mapped && fold_index < 0 {
					window := semantic_zoom_source_window(app, view, document, u64(source_line))
					if window != nil {
						if target_line, found := editor_window_line(window, u64(source_line)); found {
							if event.key == .Document_Start { next_caret, next_affinity = target_line.source_start, .Leading }
							else { next_caret, next_affinity = target_line.source_end, .Trailing }
						}
					}
					break
				}
				row += step
			}
		case .Up, .Down, .Page_Up, .Page_Down:
			next_caret, next_affinity = semantic_zoom_navigation_vertical(app, rt, owner, document, view, current, event)
		case:
			return true
		}
	}
	if next_caret == old_caret && next_affinity == old_affinity { return true }
	if event.shift && semantic_zoom_navigation_crosses_hidden(view, view.selection_anchor, next_caret) { return true }
	selection_scope: alicorn.Application_Mutation_Scope
	when alicorn.APP_MUTATION_DIAGNOSTICS_ENABLED {
		selection_scope = alicorn.application_mutation_begin(
			rt, "active editor selection", .Description, app.selection_diagnostic_revision,
			"semantic zoom caret navigation",
		)
	}
	editor_undo_group_break(view)
	if !event.shift { view.selection_anchor, view.anchor_affinity = next_caret, next_affinity }
	view.caret_byte, view.caret_affinity = next_caret, next_affinity
	view.preferred_x_set = view.preferred_x_set && (event.key == .Up || event.key == .Down)
	view.zoom.anchor_byte = next_caret
	if target_window := semantic_zoom_source_window_at_byte(app, view, document, next_caret); target_window != nil {
		if target_line, found := editor_line_for_source(target_window, next_caret); found {
			view.zoom.anchor_line = target_line.logical_line
			_ = editor_ensure_line_visible(rt, view, owner, int(target_line.logical_line), "Scratchpad moved the caret through semantic source rows")
		}
	}
	when alicorn.APP_MUTATION_DIAGNOSTICS_ENABLED {
		application_selection_diagnostic_revision_advance(app)
		alicorn.application_mutation_end(rt, &selection_scope, app.selection_diagnostic_revision)
	}
	alicorn.invalidate_root(rt, "Scratchpad moved the caret through semantic zoom")
	return true
}

semantic_zoom_navigation_vertical :: proc(
	app: ^App,
	rt: ^alicorn.Runtime,
	owner: alicorn.Node_ID,
	document: bridge.State_Document,
	view: ^Editor_View_State,
	current: Semantic_Zoom_Navigation_Line,
	event: host.Application_Text_Key_Event,
) -> (source: u64, affinity: alicorn.Text_Affinity) {
	direction := -1 if event.key == .Up || event.key == .Page_Up else 1
	text_scale := editor_text_scale_effective(app)
	current_display := current.display
	caret_position := alicorn.Text_Position{byte=editor_source_to_display(&current_display, view.caret_byte), affinity=view.caret_affinity}
	run, built := editor_navigation_text_run(rt, current.window, &current_display, document.language,
		current.width, current.presentation_current, view.wrap_mode, text_scale)
	if !built { return view.caret_byte, view.caret_affinity }
	defer alicorn.text_run_destroy(&run)
	geometry := alicorn.text_run_caret_geometry(&run, caret_position, alicorn.runtime_scratch_allocator(rt))
	if !geometry.valid { return view.caret_byte, view.caret_affinity }
	if !view.preferred_x_set {
		view.preferred_x = geometry.rect.x+current.origin_x
		view.preferred_x_set = true
	}
	current_row := semantic_zoom_rows_row_for_source(&view.zoom.rows, int(current.line.logical_line))
	target_row := current_row
	target_visual_row := geometry.line_index+direction
	within_line := event.key == .Up || event.key == .Down
	if within_line && target_visual_row >= 0 && target_visual_row < len(run.lines) {
		row := run.lines[target_visual_row]
		position := alicorn.text_run_hit_test(&run, view.preferred_x-current.origin_x,
			row.y+row.height*0.5, alicorn.runtime_scratch_allocator(rt))
		return editor_normalize_source_position(&current_display, editor_display_to_source(&current_display, position.byte)), position.affinity
	}
	if !within_line {
		owner_node, owner_found := alicorn.node_info(rt, owner)
		step := 1
		if owner_found { step = max(int(owner_node.scroll_viewport_height/(EDITOR_ROW_HEIGHT*text_scale))-1, 1) }
		target_row = clamp(current_row+direction*step, 0, max(view.zoom.rows.row_count-1, 0))
	} else {
		target_row += direction
	}
	for target_row >= 0 && target_row < view.zoom.rows.row_count {
		line_number, fold_index, mapped := semantic_zoom_rows_source_at(&view.zoom.rows, target_row)
		if mapped && fold_index < 0 && !semantic_zoom_rows_hidden(&view.zoom.rows, line_number) {
			window := semantic_zoom_source_window(app, view, document, u64(line_number))
			if window == nil { break }
			line, found := editor_window_line(window, u64(line_number))
			if found {
				target, _ := editor_row_target_for_source(app.editor_row_targets[:], line.logical_line, line.source_start)
				display, display_ok := editor_display_line_for_target(window, line, target)
				if display_ok {
					width := current.width
					origin_x := f32(0)
					if target.is_cell { width, origin_x = target.cell_width, target.cell_origin_x }
					presentation_current := window.presentation_ready && !window.presentation_stale &&
						window.presentation_revision == window.editor_revision && document.presentation_ready &&
						document.presentation_revision == window.presentation_revision
					target_run, target_built := editor_navigation_text_run(rt, window, &display, document.language,
						width, presentation_current, view.wrap_mode, text_scale)
					if target_built {
						visual_row := 0
						if direction < 0 { visual_row = len(target_run.lines)-1 }
						if len(target_run.lines) > 0 {
							row := target_run.lines[visual_row]
							position := alicorn.text_run_hit_test(&target_run, view.preferred_x-origin_x,
								row.y+row.height*0.5, alicorn.runtime_scratch_allocator(rt))
							source = editor_normalize_source_position(&display, editor_display_to_source(&display, position.byte))
							affinity = position.affinity
							alicorn.text_run_destroy(&target_run)
							return
						}
						alicorn.text_run_destroy(&target_run)
					}
				}
			}
		}
		target_row += direction
		if within_line { direction = -1 if event.key == .Up else 1 }
	}
	return view.caret_byte, view.caret_affinity
}
