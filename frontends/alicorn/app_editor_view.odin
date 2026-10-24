package main

import "core:fmt"
import "core:strings"
import alicorn "alicorn:runtime"
import bridge "./bridge"

editor_render_table_pipe :: proc(ui: ^alicorn.UI, pipe_index: int, row_height, text_scale: f32, color: alicorn.Color) {
	if ui == nil { return }
	pipe := alicorn.text(
		ui,
		"|",
		key=alicorn.key_u64(u64(pipe_index)),
		style=alicorn.layout_style(.Row, width=10*text_scale, height=row_height, align=.Start),
		font=.Monospace,
		text_style=alicorn.Text_Style{overflow=.Clip},
	)
	paint := [?]alicorn.Text_Paint_Span{{
		start=0,
		end=1,
		color=color,
		color_set=true,
	}}
	_ = alicorn.text_paint_spans(ui, pipe, paint[:])
}

editor_render_table_cells :: proc(
	ui: ^alicorn.UI,
	app: ^App,
	rt: ^alicorn.Runtime,
	view: ^Editor_View_State,
	window: ^Editor_Window,
	line: ^Editor_Display_Line,
	table: Editor_Table_Row_Layout,
	markdown_palette: Editor_Markdown_Palette,
	row_height, wrap_width: f32,
	scroll_owner: alicorn.Node_ID,
	window_matches, paint_current: bool,
) {
	if ui == nil || app == nil || rt == nil || view == nil || window == nil || line == nil || !table.ok || !table.wraps { return }
	text_scale := editor_text_scale_effective(app)
	alicorn.container_begin(
		ui,
		.Container,
		label="scratchpad-table-visual-row",
		key=alicorn.key_u64(line.logical_line),
		style=alicorn.layout_style(.Row, width=wrap_width, height=row_height, gap=0, align=.Start, clip=true),
	)
	pipe_index := 0
	if table.leading_pipe && pipe_index < len(table.pipes) {
		editor_render_table_pipe(ui, pipe_index, row_height, text_scale, markdown_palette.muted_text)
		pipe_index += 1
	}
	for &cell, cell_index in table.cells {
		cell_text := cell.display
		if semantic_zoom_active(view) { cell_text = semantic_zoom_frame_text(rt, cell_text) }
		cell_overflow := alicorn.Text_Overflow.Wrap
		if table.delimiter { cell_overflow = .Clip }
		cell_node := alicorn.text(
			ui,
			cell_text,
			key=alicorn.key_u64(u64(cell_index)),
			style=alicorn.layout_style(.Row, width=table.widths[cell_index], height=row_height, align=.Start, clip=true),
			font=.Monospace,
			text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_REGULAR, overflow=cell_overflow},
		)
		anchor_source := min(max(view.selection_anchor, cell.source_start), cell.source_end)
		caret_source := min(max(view.caret_byte, cell.source_start), cell.source_end)
		anchor_display := editor_source_to_display(&cell, anchor_source)
		caret_display := editor_source_to_display(&cell, caret_source)
		show_caret := window_matches && alicorn.focused_node(rt) == scroll_owner && view.caret_byte >= cell.source_start && view.caret_byte <= cell.source_end
		paint_spans: []alicorn.Text_Paint_Span
		text_style_spans: []alicorn.Text_Style_Span
		if paint_current {
			paint_spans = editor_presentation_spans_for_line(window, &cell, markdown_palette, alicorn.runtime_scratch_allocator(rt))
			text_style_spans = editor_presentation_text_styles_for_line(window, &cell, alicorn.runtime_scratch_allocator(rt))
		}
		if show_caret && !view.preedit_active && !view.preedit_recoverable {
			if row_start, row_end, row_ok := editor_visual_row_display_range(
				rt, &cell, caret_display, view.caret_affinity, table.widths[cell_index], true, text_style_spans, text_scale,
			); row_ok {
				caret_row := [?]alicorn.Text_Paint_Span{{
					start=row_start,
					end=row_end,
					background=markdown_palette.active_line,
					background_set=true,
				}}
				paint_spans = editor_merge_text_paint_spans(paint_spans, caret_row[:], alicorn.runtime_scratch_allocator(rt))
			}
		}
		search_spans := workspace_search_match_paint_spans_for_line(window, &cell, view, markdown_palette, alicorn.runtime_scratch_allocator(rt))
		paint_spans = editor_merge_text_paint_spans(paint_spans, search_spans, alicorn.runtime_scratch_allocator(rt))
		if app.find_open { paint_spans = find_merge_paint_spans(window, &cell, &app.find_presentation, paint_spans, markdown_palette, alicorn.runtime_scratch_allocator(rt)) }
		_ = alicorn.text_paint_spans(ui, cell_node, paint_spans)
		_ = alicorn.text_style_spans(ui, cell_node, text_style_spans)
		if !window_matches { anchor_display = caret_display }
		_ = alicorn.text_interaction(
			ui,
			cell_node,
			alicorn.Text_Position{byte=anchor_display, affinity=view.anchor_affinity},
			alicorn.Text_Position{byte=caret_display, affinity=view.caret_affinity},
			show_caret,
		)
		append(&app.editor_row_targets, Editor_Row_Target{
			node=cell_node,
			logical_line=line.logical_line,
			cell_start=cell.source_start,
			cell_end=cell.source_end,
			cell_index=cell_index,
			cell_width=table.widths[cell_index],
			cell_origin_x=table.origins[cell_index],
			is_cell=true,
		})
		if window_matches && alicorn.focused_node(rt) == scroll_owner && show_caret {
			app.editor_input_anchor_node = cell_node
			app.editor_input_anchor_byte = caret_display
			app.editor_input_anchor_affinity = view.caret_affinity
		}
		if cell_index+1 < len(table.cells) && pipe_index < len(table.pipes) {
			editor_render_table_pipe(ui, pipe_index, row_height, text_scale, markdown_palette.muted_text)
			pipe_index += 1
		}
	}
	if table.trailing_pipe && pipe_index < len(table.pipes) {
		editor_render_table_pipe(ui, pipe_index, row_height, text_scale, markdown_palette.muted_text)
	}
	alicorn.container_end(ui)
}

editor_wrap_viewport_size :: proc(
	app: ^App,
	rt: ^alicorn.Runtime,
	view: ^Editor_View_State,
	previous: alicorn.Scroll_Region_Handle,
) -> (width, height: f32) {
	text_scale := editor_text_scale_effective(app)
	if rt == nil || view == nil { return 240, EDITOR_ROW_HEIGHT*text_scale }
	viewport := alicorn.viewport_bounds(rt)
	outer_width, outer_height := viewport.w, viewport.h
	width, height = previous.viewport_width, previous.viewport_height
	if previous.id == 0 || width <= 0 {
		width = max(outer_width-320, 240)
	} else if view.wrap_last_outer_width > 0 {
		width += outer_width-view.wrap_last_outer_width
	}
	if previous.id == 0 || height <= 0 {
		height = max(outer_height-220, EDITOR_ROW_HEIGHT*text_scale)
	} else if view.wrap_last_outer_height > 0 {
		height += outer_height-view.wrap_last_outer_height
	}
	if app != nil && app.workspace_editor_split_node != 0 {
		node, found := alicorn.node_info(rt, app.workspace_editor_split_node)
		if found && node.kind == .Split {
			// If retained layout has already applied the drag, the scroll region
			// width includes the split movement. While layout is pending, its saved
			// viewport is still from the previous split position, so apply the delta
			// exactly once. This avoids both stale row heights and double-counting
			// when the editor narrows during a drag.
			if view.wrap_last_split_position_valid && (!node.split_dragging || alicorn.layout_is_pending(rt)) {
				width -= node.split_position-view.wrap_last_split_position
			}
			view.wrap_last_split_position = node.split_position
			view.wrap_last_split_position_valid = true
		}
	}
	view.wrap_last_outer_width = outer_width
	view.wrap_last_outer_height = outer_height
	return max(width, 240), max(height, EDITOR_ROW_HEIGHT*text_scale)
}

build_document_editor :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime, document: bridge.State_Document, show_heading := true) {
	view_index := editor_view_find(app.editor_views[:], document.id)
	view_created := view_index < 0
	view_ok := true
	if view_created { view_index, view_ok = editor_view_ensure(&app.editor_views, document.id) }
	if !view_ok {
		alicorn.text(ui, "Could not retain this document's view state.")
		return
	}
	view := &app.editor_views[view_index]
	if view_created {
		view.selection_anchor = document.anchor_byte
		view.caret_byte = document.cursor_byte
		view.caret_affinity = alicorn.Text_Affinity(document.affinity)
		view.scroll_x = document.scroll_x
		view.scroll_y = document.scroll_y
		view.restore_x_pending = document.scroll_x_initialized
		view.restore_y_pending = document.scroll_y_initialized
	}
	markdown_palette := editor_markdown_palette(rt, app.editor_theme)
	text_scale := editor_text_scale_effective(app)
	if view.workspace_search_match_active && view.workspace_search_match_revision != document.editor_revision {
		workspace_search_match_clear(view)
	}
	if app.editor_presented_document_id != document.id {
		if old_view_index := editor_view_find(app.editor_views[:], app.editor_presented_document_id); old_view_index >= 0 {
			editor_preedit_clear_for_document_switch(&app.editor_views[old_view_index])
		}
		presented_id, clone_error := strings.clone(document.id, context.allocator)
		if clone_error != nil {
			alicorn.text(ui, "Could not retain the active document identity.")
			return
		}
		if len(app.editor_presented_document_id) > 0 { delete(app.editor_presented_document_id, context.allocator) }
		app.editor_presented_document_id = presented_id
		editor_view_mark_active(view)
	}
	display_line_count := document.line_count
	if view.optimistic_pending_edits > 0 {
		if view.optimistic_line_delta < 0 {
			removed := u64(-view.optimistic_line_delta)
			display_line_count = display_line_count-removed if removed < display_line_count else 1
		} else {
			display_line_count += u64(view.optimistic_line_delta)
		}
	}
	if show_heading {
		alicorn.container_begin(ui, .Container, label="document-view-heading", style=alicorn.layout_style(.Row, height=30, gap=12, align=.Center))
	heading := fmt.tprintf("%s  ·  %s  ·  %d lines", document_title(document.path), document.language, display_line_count)
	alicorn.text(ui, heading)
	if app.editor_window_error != "" { alicorn.text(ui, fmt.tprintf("Window: %s", app.editor_window_error)) }
	alicorn.container_end(ui)
	} else if app.editor_window_error != "" { alicorn.text(ui, fmt.tprintf("Window: %s", app.editor_window_error)) }
	if document.status == "conflict" {
		alicorn.container_begin(ui, .Container, label="document-conflict-actions", key=alicorn.key_string("document-conflict-actions"), style=alicorn.layout_style(.Column, height=68, padding=7, gap=4), color=alicorn.style_color(ui, .Subtle_Surface))
		alicorn.text(ui, "This file changed on disk. Your edits are preserved. Reload discards them; Keep Mine overwrites the disk version.")
		alicorn.container_begin(ui, .Container, label="document-conflict-buttons", style=alicorn.layout_style(.Row, height=30, gap=8, align=.Center))
		if alicorn.button(ui, "Reload from Disk", key=alicorn.key_string("conflict-reload"), style=alicorn.layout_style(.Row, width=140, height=28)) {
			editor_resolve_conflict(app, rt, document.id, false)
		}
		if alicorn.button(ui, "Keep Mine", key=alicorn.key_string("conflict-keep"), style=alicorn.layout_style(.Row, width=104, height=28)) {
			editor_resolve_conflict(app, rt, document.id, true)
		}
		if alicorn.button(ui, "Save As…", key=alicorn.key_string("conflict-save-as"), style=alicorn.layout_style(.Row, width=100, height=28)) {
			request_file_dialog(app, rt, .Save_File, "Save As")
		}
		alicorn.container_end(ui)
		alicorn.container_end(ui)
	}

	semantic_zoom_prepare(app, rt, document, view)
	if view.reveal_request.pending { semantic_zoom_reveal_input(app, rt, view) }

	window, window_matches := editor_presentation_window(
		view,
		&app.editor_window,
		app.editor_window_ready,
		document.id,
		document.editor_revision,
	)
	window_available := window != nil
	// The backend rebuilds the Markdown table projection synchronously when a
	// semantic command arrives. Do not make the menu depend on an asynchronous,
	// bounded presentation window; the command reports when the caret is outside
	// a formattable table.
	format_table_enabled := document.language == "markdown"
	for &item in app.document_items {
		if item.kind == .Command && item.command == action_id_for(ACTION_DOCUMENT_FORMAT) {
			item.state.enabled = format_table_enabled
		}
	}
	if window_matches {
		_ = editor_view_resolve_document_edge(view, window, display_line_count)
		_ = editor_view_resolve_goto_line(view, window, display_line_count)
		if line, found := editor_line_for_source(window, view.caret_byte); found {
			previous_caret := view.caret_byte
			view.caret_byte = editor_normalize_source_position(line, view.caret_byte)
			if view.selection_anchor == previous_caret { view.selection_anchor = view.caret_byte }
		}
		if line, found := editor_line_for_source(window, view.selection_anchor); found {
			view.selection_anchor = editor_normalize_source_position(line, view.selection_anchor)
		}
	}
	gutter_width := editor_line_number_gutter_width(display_line_count, text_scale)
	line_count := int(display_line_count)
	if line_count < 1 { line_count = 1 }
	if !view.wrap_height_index_ready {
		view.wrap_height_index_ready = alicorn.virtual_list_height_index_init(
			&view.wrap_height_index, line_count, EDITOR_ROW_HEIGHT*text_scale, context.allocator,
		)
	}
	if view.wrap_height_index_ready {
		_ = alicorn.virtual_list_height_index_set_count(&view.wrap_height_index, line_count)
	}
	semantic_zoom_sync_geometry(view, window, text_scale)
	previous_scroll := alicorn.scroll_region_state(rt, app.editor_scroll_owner)
	viewport_width, viewport_height := editor_wrap_viewport_size(app, rt, view, previous_scroll)
	wrap_width := max(viewport_width-gutter_width-16*text_scale, 80*text_scale)
	scroll_y := view.scroll_y
	if !view.restore_y_pending && previous_scroll.id != 0 { scroll_y = previous_scroll.offset_y }
	if view.viewport_anchor_pending && view.viewport_anchor_resolved && window_matches {
		if anchor_line, anchor_found := editor_line_for_source(window, view.viewport_anchor_byte); anchor_found {
			anchor_top := alicorn.virtual_list_height_index_item_top(&view.wrap_height_index, int(anchor_line.logical_line))
			scroll_y = max(anchor_top+view.viewport_anchor_offset, 0)
			view.scroll_y = scroll_y
			view.restore_y_pending = true
		}
	}
	request_presentation := document.language == "markdown" ||
	                        document.language == "go" ||
	                        document.language == "typescript" ||
	                        document.language == "tsx"
	presentation_window_matches := document.presentation_ready && window_matches && window.presentation_ready &&
	                              !window.presentation_stale &&
	                              window.presentation_revision == document.presentation_revision &&
	                              window.presentation_revision == document.editor_revision
	// Exact parser metadata is authoritative. A locally rebased presentation is
	// also safe for visual continuity after the edit ACK; it stays presentation-
	// only until the exact projection for the accepted source revision arrives.
	presentation_visual := presentation_window_matches ||
	                       (request_presentation && window_matches && window.presentation_ready &&
	                        window.presentation_stale)
	// A rebased projection can keep the current text styled, but it is not the
	// parser's answer for a newer revision. Fetch exact metadata when the
	// language worker catches up; do not request the same projection repeatedly.
	metadata_refresh_needed := request_presentation && document.presentation_ready && !presentation_window_matches
	if window_matches && window.presentation_ready && window.presentation_revision == document.presentation_revision {
		metadata_refresh_needed = false
	}
	if view.wrap_height_index_ready && window_available {
		needs_measurement := abs(view.wrap_measurement_width-wrap_width) > 0.5 ||
		                     view.wrap_measurement_mode != view.wrap_mode ||
		                     view.wrap_measurement_revision != window.editor_revision ||
		                     view.wrap_measurement_presentation_revision != window.presentation_revision ||
		                     view.wrap_measurement_start_line != window.start_line ||
		                     view.wrap_measurement_end_line != window.end_line ||
		                     view.wrap_measurement_pending_edits != view.optimistic_pending_edits ||
		                     metadata_refresh_needed || view.viewport_anchor_pending
		if needs_measurement {
			before := alicorn.virtual_list_variable_metrics(editor_geometry_index(view), scroll_y, viewport_height)
			anchor_line := editor_geometry_source_line(view, before.first)
			anchor_top := editor_geometry_line_top(view, anchor_line)
			anchor_byte := u64(0)
			anchor_offset := scroll_y-anchor_top
			if anchor_source_line, anchor_line_found := editor_window_line(window, u64(anchor_line)); anchor_line_found {
				anchor_byte = anchor_source_line.source_start
			}
			if view.viewport_anchor_pending && view.viewport_anchor_resolved {
				anchor_byte = view.viewport_anchor_byte
				anchor_offset = view.viewport_anchor_offset
			}
			_ = editor_measure_window_wrapping(
				rt, view, window, document.language, wrap_width,
				presentation_visual, text_scale,
			)
			semantic_zoom_sync_geometry(view, window, text_scale)
			new_anchor_line := anchor_line
			if mapped_line, mapped := editor_line_for_source(window, anchor_byte); mapped {
				new_anchor_line = int(mapped_line.logical_line)
			}
			new_anchor_top := editor_geometry_line_top(view, new_anchor_line)
			if previous_scroll.id != 0 {
				scroll_y = max(new_anchor_top+anchor_offset, 0)
				if view.restore_y_pending {
					view.scroll_y = scroll_y
				} else if abs(scroll_y-previous_scroll.offset_y) > 0.01 {
					_ = alicorn.scroll_region_set_offset(rt, previous_scroll.id, scroll_y, "Scratchpad preserved the source-relative viewport anchor while text reflowed")
				}
			}
			if view.viewport_anchor_pending && view.viewport_anchor_resolved {
				view.viewport_anchor_pending = false
				view.viewport_anchor_resolved = false
			}
			view.wrap_measurement_width = wrap_width
			view.wrap_measurement_mode = view.wrap_mode
			view.wrap_measurement_revision = window.editor_revision
			view.wrap_measurement_presentation_revision = window.presentation_revision
			view.wrap_measurement_start_line = window.start_line
			view.wrap_measurement_end_line = window.end_line
			view.wrap_measurement_pending_edits = view.optimistic_pending_edits
		}
	}
	geometry_index := editor_geometry_index(view)
	if anchored_y, apply_anchor := semantic_zoom_resolve_anchor(app, rt, view, window, viewport_height, document.language); apply_anchor {
		scroll_y, view.scroll_y = anchored_y, anchored_y
		view.restore_y_pending = true
		view.restore_token = alicorn.RESTORE_TOKEN_NONE
	}
	// Source-relative destinations override a tab's saved offset long enough
	// to realize their row; exact shaped geometry resolves after this build.
	request := view.reveal_request
	if request.pending && request.document_id == document.id &&
	   request.editor_revision == document.editor_revision &&
	   view.wrap_height_index_ready &&
	   request.logical_line < u64(max(line_count, 0)) {
		target_line := int(request.logical_line)
		target_top := editor_geometry_line_top(view, target_line)
		target_height := alicorn.virtual_list_height_index_item_height(geometry_index, editor_geometry_row(view, target_line))
		if target_height <= 0 { target_height = EDITOR_ROW_HEIGHT*text_scale }
		// Only move far enough to realize an offscreen logical line here. A
		// wrapped line can exceed the viewport while its requested caret is
		// already visible; after-frame reveal uses the exact source geometry.
		if target_top+target_height <= scroll_y || target_top >= scroll_y+viewport_height {
			desired_y, _ := editor_reveal_content_offset(
				scroll_y, viewport_height, target_top, target_height, request.alignment,
			)
			max_y := max(geometry_index.total_height-viewport_height, 0)
			desired_y = min(max(desired_y, 0), max_y)
			scroll_y = desired_y
			view.scroll_y = desired_y
			view.restore_y_pending = true
		}
	} else if request.pending && request.document_id == document.id &&
	          request.editor_revision < document.editor_revision {
		editor_reveal_request_clear(&view.reveal_request)
	}
	visible_intrinsic_width: f32 = 0
	if semantic_zoom_active(view) {
		visible_intrinsic_width = semantic_zoom_frontier_width(app, rt, view, document, scroll_y, viewport_height, gutter_width, wrap_width, text_scale)
	} else if window_matches {
		visible_intrinsic_width = editor_visible_window_content_width(
			window,
			&view.wrap_height_index,
			scroll_y,
			viewport_height,
			gutter_width,
			document.language,
			presentation_visual,
			wrap_width,
			view.wrap_mode,
			text_scale,
		)
	}
	content_width := max(viewport_width, visible_intrinsic_width)
	// Keep editor rows in a fixed horizontal viewport. The scroll region still
	// owns horizontal extent and its scrollbar, but only individual no-wrap
	// source lanes consume scroll_x. This leaves the gutter and clipped text
	// lane fixed while long source lines move inside that lane.
	alicorn.virtual_list_height_index_rebuild_prefix(geometry_index)
	scroll_restore := alicorn.Scroll_Restore_Request{}
	if view.restore_y_pending {
		if view.restore_runtime != rt || view.restore_token == alicorn.RESTORE_TOKEN_NONE {
			view.restore_runtime = rt
			view.restore_token = alicorn.restore_token_next(rt)
		}
		scroll_restore = alicorn.Scroll_Restore_Request{
			token=view.restore_token,
			offset_x=previous_scroll.offset_x,
			offset_y=scroll_y,
		}
	}
	editor_scroll := alicorn.scroll_region_begin(
		ui,
		key=alicorn.key_string("editor-scroll-region"),
		content_height=geometry_index.total_height,
		line_height=geometry_index.estimated_height,
		content_width=content_width,
		style=alicorn.layout_style(grow=1, clip=true),
		label="scratchpad-visible-document-lines",
		axes=.Both,
		focusable=true,
		restore=scroll_restore,
	)
	editor_accessibility_build_semantics(app, ui, rt, document, editor_scroll.id, view)
	list_metrics := alicorn.virtual_list_variable_metrics(
		geometry_index,
		editor_scroll.offset_y,
		editor_scroll.viewport_height,
	)
	list_content_style := alicorn.layout_style(width=-1, height=editor_scroll.viewport_height, clip=true)
	if content_width > 0 { list_content_style.width = content_width }
	alicorn.container_begin(
		ui,
		.Virtual_List,
		label="scratchpad-visible-document-lines",
		style=list_content_style,
		scroll_offset_y=list_metrics.offset_y,
		layout_scroll_offset_y=list_metrics.leading_offset_y,
		scroll_offset_x=editor_scroll.offset_x,
		layout_scroll_offset_x=0,
	)
	style_scope := alicorn.style_environment_push(ui, alicorn.Style_Environment{text_scale=text_scale})
	list := alicorn.Virtual_List_Handle{
		scroll=editor_scroll,
		first=list_metrics.first,
		last=list_metrics.last,
	}
	horizontal_ready := window_matches && list.scroll.max_scroll_x > 0.5
	editor_has_focus := alicorn.focused_node(rt) == list.scroll.id
	if view.undo_group_editor_focus != editor_has_focus {
		editor_undo_group_break(view)
		view.undo_group_editor_focus = editor_has_focus
	}
	_ = editor_register_text_input_target(ui, list.scroll.id, view)
	if rt != nil {
		// Keep native text input away from stale source bytes. The editor input
		// handlers independently reject edits until an exact-revision window is
		// installed; suspending here also prevents IME preedit from targeting an
		// obsolete caret location.
		suspend_text_input := !window_matches || editor_preedit_recovery_is_full(view)
		_ = alicorn.text_input_target_set_suspended(rt, list.scroll.id, suspend_text_input)
	}
	app.editor_scroll_owner = list.scroll.id
	restore := editor_view_sync_scroll(
		view,
		list.scroll.offset_y,
		list.scroll.offset_x,
		list.scroll.max_scroll_y,
		list.scroll.max_scroll_x,
		horizontal_ready,
	)
	if scroll_restore.token != alicorn.RESTORE_TOKEN_NONE {
		// Keep the app's requested value until Alicorn resolves it against the
		// final viewport and (if needed) corrects the virtualized range.
		view.scroll_y = scroll_restore.offset_y
		view.restore_y_pending = true
		restore.vertical = false
	}
	if restore.vertical || restore.horizontal {
		app.editor_restore_scroll = true
		app.editor_restore_vertical = restore.vertical
		app.editor_restore_horizontal = restore.horizontal
		app.editor_restore_y = restore.scroll_y
		app.editor_restore_x = restore.scroll_x
	}
	visible_start := u64(max(editor_geometry_source_line(view, list.first), 0))
	visible_end := u64(max(editor_geometry_source_line(view, max(list.last-1, 0))+1, 0))
	window_covers_view := window_matches &&
	                      window.start_line <= visible_start &&
	                      window.end_line >= visible_end
	if metadata_refresh_needed { window_covers_view = false }
	bracket_match: Editor_Bracket_Match
	bracket_match_found := false
	if window_matches && !view.preedit_active && !view.preedit_recoverable {
		bracket_match, bracket_match_found = editor_bracket_match_in_window(window, view.caret_byte)
	}
	base_window := window
	base_window_matches, base_window_covers_view := window_matches, window_covers_view
	base_presentation_visual := presentation_visual
	for position := list.first; position < list.last; position += 1 {
		line_number := u64(editor_geometry_source_line(view, position))
		if semantic_zoom_active(view) {
			_, fold_index, mapped := semantic_zoom_rows_source_at(&view.zoom.rows, position)
			if mapped && fold_index >= 0 {
				semantic_zoom_render_fold(app, ui, document, view.zoom.rows.folds[fold_index], alicorn.virtual_list_height_index_item_height(geometry_index, position))
				continue
			}
		}
		window := base_window
		if semantic_zoom_active(view) {
			window = semantic_zoom_source_window(app, view, document, line_number)
			if window != nil {
				if editor_measure_window_wrapping(rt, view, window, document.language, wrap_width, window.presentation_ready, text_scale) {
					semantic_zoom_sync_geometry(view, window, text_scale)
					alicorn.invalidate_root(rt, "Scratchpad measured visible folded source rows")
				}
			}
		}
		row_height := alicorn.virtual_list_height_index_item_height(geometry_index, position)
		if row_height <= 0 { row_height = EDITOR_ROW_HEIGHT*text_scale }
		window_available := window != nil
		window_matches, window_covers_view := base_window_matches, base_window_covers_view
		presentation_visual := base_presentation_visual
		if semantic_zoom_active(view) {
			window_matches = window_available && window.document_id == document.id && window.editor_revision == document.editor_revision
			window_covers_view = window_matches
			presentation_visual = window_matches && window.presentation_ready && !window.presentation_stale
		}
		if line, found := editor_window_line(window, line_number); window_available && found {
			table_row := editor_table_row_layout(window, line, wrap_width, text_scale=text_scale)
			table_wrap_active := table_row.ok && table_row.wraps && !view.preedit_active && !view.preedit_recoverable
			line_wraps := editor_line_should_wrap_for_view(document.language, window, line, presentation_visual, wrap_width, view.wrap_mode, text_scale)
			if editor_table_line_is_projected(window, line) && !table_wrap_active { line_wraps = false }
			row_presentation_current := document.language == "markdown" && presentation_visual &&
			                           !view.preedit_active && !view.preedit_recoverable
			markdown_row := editor_markdown_row_presentation(window, line, row_presentation_current)
			row_background := editor_markdown_row_background(markdown_row)
			editor_row_node := alicorn.container_begin(
				ui,
				.Container,
				label="scratchpad-editor-logical-line",
				key=alicorn.key_u64(line.logical_line),
				style=alicorn.layout_style(.Row, height=row_height, gap=8, align=.Center, clip=true),
				color=row_background,
			)
			// The parent virtual list shifts the whole row for horizontal scroll.
			// Counter-shift fixed chrome and wrapped prose; no-wrap text stays in
			// the parent's scrolling lane.
			editor_gutter_node := alicorn.container_begin(
				ui,
				.Virtual_List,
				label="scratchpad-editor-line-number-gutter",
				key=alicorn.key_string("gutter"),
				style=alicorn.layout_style(.Row, width=gutter_width, height=row_height, align=.Center, clip=true),
				color=alicorn.style_color(ui, .Subtle_Surface),
			)
			alicorn.container_begin(ui, .Container, label="scratchpad-editor-line-number-spacer", style=alicorn.layout_style(.Row, grow=1))
			alicorn.container_end(ui)
			line_number_text := editor_line_number_text(line.logical_line+1)
			line_number_node := alicorn.text(
				ui,
				line_number_text,
				key=alicorn.key_u64(line.logical_line),
				font=.Monospace,
			)
			if editor_table_line_is_projected(window, line) && window_matches && alicorn.focused_node(rt) == list.scroll.id &&
			   view.caret_byte >= line.source_start && view.caret_byte <= line.source_end &&
			   !view.preedit_active && !view.preedit_recoverable {
				gutter_paint := [?]alicorn.Text_Paint_Span{{
					start=0,
					end=len(line_number_text),
					background=markdown_palette.active_line_gutter,
					background_set=true,
				}}
				_ = alicorn.text_paint_spans(ui, line_number_node, gutter_paint[:])
			}
			alicorn.container_end(ui)
			alicorn.container_begin(
				ui,
				.Virtual_List,
				label="scratchpad-editor-source-lane",
				key=alicorn.key_string("source"),
				style=alicorn.layout_style(.Row, width=wrap_width, height=row_height, clip=true),
				scroll_offset_x=list.scroll.offset_x if !line_wraps else 0,
				layout_scroll_offset_x=list.scroll.offset_x if !line_wraps else 0,
			)
			if table_wrap_active {
				paint_table := window_covers_view && presentation_visual &&
				               window.document_id == document.id && !view.preedit_active && !view.preedit_recoverable
				editor_render_table_cells(
					ui, app, rt, view, window, line, table_row, markdown_palette,
					row_height, wrap_width, list.scroll.id, window_matches, paint_table,
				)
			} else {
			anchor_source := min(max(view.selection_anchor, line.source_start), line.source_end)
			caret_source := min(max(view.caret_byte, line.source_start), line.source_end)
			display_text := line.display
			anchor_display := editor_source_to_display(line, anchor_source)
			caret_display := editor_source_to_display(line, caret_source)
			caret_area_byte := caret_display
			caret_area_affinity := view.caret_affinity
			show_caret := window_matches && alicorn.focused_node(rt) == list.scroll.id && view.caret_byte >= line.source_start && view.caret_byte <= line.source_end
			if window_matches {
				if composition_display, composition_start, composition_end, applies := editor_preedit_display_for_line(view, window, line); applies {
				display_text = composition_display
				anchor_display, caret_display = composition_start, composition_end
				if anchor_display == caret_display && len(view.preedit_text) > 0 {
					// A zero-width SDL composition range still needs visible
					// feedback; highlight the composed text as the underline
					// equivalent while keeping the candidate caret at SDL's byte
					// position.
					anchor_display = composition_start
					caret_display = composition_start+len(view.preedit_text)
				}
				caret_area_byte = composition_end
				caret_area_affinity = .Trailing
				composition_start_line, start_found := editor_line_for_source(window, view.preedit_replace_start)
				show_caret = start_found && composition_start_line.logical_line == line.logical_line && alicorn.focused_node(rt) == list.scroll.id
				}
			} else {
				// The last authoritative selection may not describe the last-good
				// bytes after an undo. Render the old text without stale selection
				// or caret decoration while interaction authority is suspended.
				anchor_display = caret_display
			}
			line_text_style := alicorn.layout_style(.Row, height=row_height)
			if semantic_zoom_active(view) { display_text = semantic_zoom_frame_text(rt, display_text) }
			text_overflow := alicorn.Text_Overflow.Clip
			if line_wraps {
				line_text_style.width = wrap_width
				text_overflow = .Wrap
			}
			line_node := alicorn.text(
				ui,
				display_text,
				key=alicorn.key_u64(line.logical_line),
				style=line_text_style,
				font=.Monospace,
				text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_REGULAR, overflow=text_overflow},
			)
			paint_spans: []alicorn.Text_Paint_Span
			paint_current := window_covers_view && presentation_visual &&
			                 window.document_id == document.id && !view.preedit_active && !view.preedit_recoverable
			if paint_current {
				paint_spans = editor_presentation_spans_for_line(window, line, markdown_palette, alicorn.runtime_scratch_allocator(rt))
			}
			text_style_spans: []alicorn.Text_Style_Span
			if paint_current { text_style_spans = editor_presentation_text_styles_for_line(window, line, alicorn.runtime_scratch_allocator(rt)) }
			decoration_current := window_covers_view && window.document_id == document.id &&
			                      !view.preedit_active && !view.preedit_recoverable
			if decoration_current {
				search_spans := workspace_search_match_paint_spans_for_line(window, line, view, markdown_palette, alicorn.runtime_scratch_allocator(rt))
				paint_spans = editor_merge_text_paint_spans(paint_spans, search_spans, alicorn.runtime_scratch_allocator(rt))
				if app.find_open { paint_spans = find_merge_paint_spans(window, line, &app.find_presentation, paint_spans, markdown_palette, alicorn.runtime_scratch_allocator(rt)) }
			}
			if bracket_match_found {
				combined_spans := make([dynamic]alicorn.Text_Paint_Span, 0, len(paint_spans)+2, allocator=alicorn.runtime_scratch_allocator(rt))
				for span in paint_spans { append(&combined_spans, span) }
				bracket_bytes := [2]u64{bracket_match.first, bracket_match.second}
				for source_byte in bracket_bytes {
					if source_byte < line.source_start || source_byte >= line.source_end { continue }
					start, end, mapped := editor_source_range_to_display(line, source_byte, source_byte+1)
					if !mapped { continue }
					append(&combined_spans, alicorn.Text_Paint_Span{
						start=start,
						end=end,
						background=markdown_palette.bracket_match_background,
						background_set=true,
					})
				}
				paint_spans = combined_spans[:]
			}
			_ = alicorn.text_paint_spans(ui, line_node, paint_spans)
			_ = alicorn.text_style_spans(ui, line_node, text_style_spans)
			append(&app.editor_row_targets, Editor_Row_Target{node=line_node, logical_line=line.logical_line})
			composition_row := false
			if window_matches && view.preedit_active {
				if composition_line, composition_found := editor_line_for_source(window, view.preedit_replace_start); composition_found {
					composition_row = composition_line.logical_line == line.logical_line
				}
			}
			if window_matches && alicorn.focused_node(rt) == list.scroll.id && ((view.caret_byte >= line.source_start && view.caret_byte <= line.source_end) || composition_row) {
				app.editor_input_anchor_node = line_node
				app.editor_input_anchor_byte = caret_area_byte
				app.editor_input_anchor_affinity = caret_area_affinity
			}
			_ = alicorn.text_interaction(
				ui,
				line_node,
				alicorn.Text_Position{byte=anchor_display, affinity=view.anchor_affinity},
				alicorn.Text_Position{byte=caret_display, affinity=view.caret_affinity},
				show_caret,
			)
			if show_caret && !view.preedit_active && !view.preedit_recoverable {
				caret_position := alicorn.Text_Position{byte=caret_display, affinity=view.caret_affinity}
				_ = alicorn.visual_row_background(ui, editor_row_node, line_node, caret_position, markdown_palette.active_line)
				_ = alicorn.visual_row_background(ui, editor_gutter_node, line_node, caret_position, markdown_palette.active_line_gutter)
			}
			}
			alicorn.container_end(ui)
			alicorn.container_end(ui)
		} else if window_matches || !window_available {
			label := fmt.tprintf("Loading line %d…", line_number+1)
			alicorn.text(
				ui,
				label,
				key=alicorn.key_u64(line_number),
				style=alicorn.layout_style(.Row, height=row_height),
			)
		} else {
			// A newer document snapshot may have added rows that do not exist in
			// the last-good bounded window. Preserve the current topology without
			// claiming those bytes are loading; the matching refresh will fill it.
			alicorn.text(
				ui,
				"",
				key=alicorn.key_u64(line_number),
				style=alicorn.layout_style(.Row, height=row_height),
			)
		}
	}
	alicorn.virtual_list_end(ui, list)
	alicorn.style_environment_pop(ui, style_scope)
	if semantic_zoom_active(view) { return }

	request_start := visible_start
	if request_start > 64 { request_start -= 64 } else { request_start = 0 }
	remaining := document.line_count-request_start
	request_lines := min(remaining, bridge.MAX_VISIBLE_LINES)
	if request_lines == 0 { request_lines = 1 }
	request_anchor, long_line_chunk_needed := editor_long_line_next_anchor(
		window,
		visible_start,
		list.scroll.offset_x,
		list.scroll.max_scroll_x,
	)
	if !window_matches { request_anchor = 0 }
	if long_line_chunk_needed && window_matches {
		request_start = window.start_line
		request_lines = 1
	}
	request_source_anchor := view.viewport_anchor_pending && !view.viewport_anchor_resolved && view.viewport_anchor_revision != 0
	if document.line_count > 0 && (!window_covers_view || request_anchor > 0 || metadata_refresh_needed) {
		if metadata_refresh_needed && window_matches && !editor_window_is_long_line_chunk(window) {
			// Request the same source window so a returned parser projection can be
			// rebased through the queued local edits without changing its byte origin.
			request_start = window.start_line
			request_lines = window.end_line-window.start_line
			request_anchor = 0
		}
		request := bridge.Visible_Window_Request{
			document_id=document.id,
			application_rev=app.backend.state.application_rev,
			editor_revision=document.editor_revision,
			start_line=request_start,
			anchor_byte=request_anchor,
			max_lines=request_lines,
			max_bytes=bridge.MAX_VISIBLE_BYTES,
			include_presentation=request_presentation,
			presentation_revision=document.presentation_revision,
			presentation_ready=document.presentation_ready,
			has_source_anchor=request_source_anchor,
			source_anchor_revision=view.viewport_anchor_revision,
			source_anchor_byte=view.viewport_anchor_byte,
			source_anchor_line=view.viewport_anchor_line,
		}
		if !editor_window_request_is_rejected(app, request) {
			generation, accepted, request_error := bridge.visible_window_lane_request(
				editor_visible_window_lane(app),
				document.id,
				app.backend.state.application_rev,
				document.editor_revision,
				request_start,
				request_lines,
				bridge.MAX_VISIBLE_BYTES,
				request_anchor,
				request_presentation,
				document.presentation_revision,
				document.presentation_ready,
				request_source_anchor,
				view.viewport_anchor_revision,
				view.viewport_anchor_byte,
				view.viewport_anchor_line,
			)
			if accepted {
				app.editor_request_generation = generation
				editor_window_rejection_clear(app)
				if app.editor_window_error != "" { delete(app.editor_window_error, context.allocator) }
				app.editor_window_error = ""
			} else if request_error != "" {
				if app.editor_window_error != "" { delete(app.editor_window_error, context.allocator) }
				app.editor_window_error, _ = strings.clone(request_error, context.allocator)
			}
		}
	}
	if len(app.editor_edits) > 0 && bridge.editor_edit_lane_can_submit(&app.editor_edit_lane) {
		_, _ = editor_dispatch_next_edit(app)
	}
}

build_document_status :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime, document: bridge.State_Document) {
	if app == nil || ui == nil { return }
	if document.view_kind == "image" || document.view_kind == "unsupported" {
		label := "Preview unavailable"
		if document.view_kind == "image" && document.image_width > 0 && document.image_height > 0 {
			label = fmt.tprintf("%d x %d pixels  |  %s  |  Read-only", document.image_width, document.image_height, document.image_format)
		} else if document.view_kind == "image" { label = "Image preview unavailable | Read-only" }
		alicorn.container_begin(ui, .Container, label="image-document-status-bar", style=alicorn.layout_style(.Row, height=32, padding=8, align=.Center), color=alicorn.style_color(ui, .Subtle_Surface))
		alicorn.text(ui, label, style=alicorn.layout_style(.Row, grow=1), text_style=alicorn.Text_Style{overflow=.Ellipsis})
		alicorn.container_end(ui)
		return
	}
	view_index, view_ok := editor_view_ensure(&app.editor_views, document.id)
	if !view_ok { return }
	view := &app.editor_views[view_index]
	window, _ := editor_presentation_window(view, &app.editor_window, app.editor_window_ready, document.id, document.editor_revision)
	line_count := document.line_count
	if view.optimistic_pending_edits > 0 {
		if view.optimistic_line_delta < 0 {
			removed := u64(-view.optimistic_line_delta)
			line_count = line_count-removed if removed < line_count else 1
		} else { line_count += u64(view.optimistic_line_delta) }
	}
	location := "Ln —  Col —"
	if view.pending_goto_line {
		location = fmt.tprintf("Ln %d  Col %d", view.pending_goto_target_line+1, view.pending_goto_column)
	} else if line, found := editor_line_for_source(window, view.caret_byte); found {
		column := u64(1)
		position := line.source_start
		for position < min(view.caret_byte, line.source_end) {
			next, _, moved := editor_move_horizontal(line, position, .Leading, 1)
			if !moved || next <= position { break }
			position = next
			column += 1
		}
		location = fmt.tprintf("Ln %d  Col %d", line.logical_line+1, column)
		if editor_window_is_long_line_chunk(window) { location = fmt.tprintf("%s  (chunk)", location) }
	}
	modified := ""
	if document.dirty || view.optimistic_pending_edits > 0 { modified = "  • Modified" }
	document_info := fmt.tprintf("%s%s  ·  %d lines", document.language, modified, line_count)
	wrap_label := "Auto"
	switch view.wrap_mode {
	case .On: wrap_label = "On"
	case .Off: wrap_label = "Off"
	case .Auto: wrap_label = "Auto"
	}
	alicorn.surface_begin(ui, alicorn.surface_core_color_role(.Subtle_Surface), label="document-status-bar", key=alicorn.key_string("document-status-bar"), style=alicorn.layout_style(.Row, height=alicorn.LAYOUT_SIZE_FIT_CONTENT, min_height=40, gap=10, padding=8, align=.Center), material=scratchpad_structural_material(app), physical_height=scratchpad_optical_height(.Groove))
	alicorn.adaptive_begin(ui, alicorn.key_string("document-status-responsive"),
		style=alicorn.layout_style(.Row, grow=1, height=alicorn.LAYOUT_SIZE_FIT_CONTENT, min_height=24, gap=10, align=.Center),
		label="document-status-responsive")
	alicorn.adaptive_alternative_begin(ui, alicorn.key_string("document-status-wide"), "Wide", minimum_width=600,
		style=alicorn.layout_style(.Row, grow=1, height=alicorn.LAYOUT_SIZE_FIT_CONTENT, min_height=24, gap=10, align=.Center))
	alicorn.container_begin(ui, .Container, label="document-status-information", style=alicorn.layout_style(.Row, grow=1, compress_weight=1, min_width=188, height=alicorn.LAYOUT_SIZE_FIT_CONTENT, min_height=24, gap=12, align=.Center))
	alicorn.text(ui, location, key=alicorn.key_string("document-status-location"), style=alicorn.layout_style(.Row, width=176, height=24), text_style=alicorn.Text_Style{overflow=.Ellipsis})
	alicorn.text(ui, document_info, key=alicorn.key_string("document-status-document-info"), style=alicorn.layout_style(.Row, grow=1, height=24), text_style=alicorn.Text_Style{overflow=.Ellipsis})
	alicorn.container_end(ui)
	alicorn.text(ui, fmt.tprintf("Detail: %s%s", semantic_zoom_title(view.zoom.depth), " · preparing" if view.zoom.waiting else ""),
		key=alicorn.key_string("document-semantic-detail"), style=alicorn.layout_style(.Row, width=120, height=24), text_style=alicorn.Text_Style{font_size=12, overflow=.Ellipsis})
	if alicorn.button(ui, fmt.tprintf("Wrap: %s", wrap_label), key=alicorn.key_string("document-wrap"), style=alicorn.layout_style(.Row, width=88, height=24), content_style=alicorn.button_content_style(padding_x=0, padding_y=0), variant=.Quiet) {
		editor_toggle_wrap_mode(app, rt)
	}
	if alicorn.button(ui, "Go to Line…", key=alicorn.key_string("document-goto-line"), style=alicorn.layout_style(.Row, width=100, height=24), content_style=alicorn.button_content_style(padding_x=0, padding_y=0), variant=.Quiet) {
		go_to_line_open_surface(app, rt)
	}
	alicorn.adaptive_alternative_end(ui)

	alicorn.adaptive_alternative_begin(ui, alicorn.key_string("document-status-compact"), "Compact",
		style=alicorn.layout_style(.Row, grow=1, height=alicorn.LAYOUT_SIZE_FIT_CONTENT, min_height=24, gap=10, align=.Center))
	alicorn.text(ui, location, key=alicorn.key_string("document-status-compact-location"), style=alicorn.layout_style(.Row, grow=1, compress_weight=1, min_width=96, height=24), text_style=alicorn.Text_Style{overflow=.Ellipsis})
	alicorn.text(ui, semantic_zoom_title(view.zoom.depth), key=alicorn.key_string("document-semantic-detail-compact"), style=alicorn.layout_style(.Row, width=68, height=24), text_style=alicorn.Text_Style{font_size=12, overflow=.Ellipsis})
	if alicorn.button(ui, fmt.tprintf("Wrap: %s", wrap_label), key=alicorn.key_string("document-wrap-compact"), style=alicorn.layout_style(.Row, width=88, height=24), content_style=alicorn.button_content_style(padding_x=0, padding_y=0), variant=.Quiet) {
		editor_toggle_wrap_mode(app, rt)
	}
	alicorn.adaptive_alternative_end(ui)
	alicorn.adaptive_end(ui)
	alicorn.container_end(ui)
}
