package main

import "core:fmt"
import alicorn "alicorn:runtime"
import bridge "./bridge"

SEMANTIC_VIEW_WINDOW_SIZE :: u64(128)

Semantic_View_Row_Layout :: struct {
	height, meta_height, marker_height, text_height: f32,
	indent: f32,
	font: alicorn.Font_Role,
}

// Only the bounded excerpt page is shaped. The sparse index keeps measured
// heights for scrolling; a resize, font change or projection change resets it.
Semantic_View_Layout :: struct {
	index: alicorn.Virtual_List_Height_Index,
	ready: bool,
	width, scale: f32,
	generation, font_generation: u64,
	first, count: int,
	rows: [SEMANTIC_VIEW_WINDOW_SIZE]Semantic_View_Row_Layout,
}

semantic_view_layout_destroy :: proc(layout: ^Semantic_View_Layout) {
	if layout == nil { return }
	if layout.ready { alicorn.virtual_list_height_index_destroy(&layout.index) }
	layout^ = {}
}

semantic_view_snippet :: proc(segment: bridge.Semantic_View_Segment) -> string {
	return fmt.tprintf("%s…", segment.text) if segment.truncated else segment.text
}

semantic_view_omission_marker :: proc(line_count: int) -> string {
	return fmt.tprintf("··· %d lines omitted ···", line_count) if line_count > 0 else "···"
}

semantic_view_text_height :: proc(rt: ^alicorn.Runtime, value: string, width, size: f32, font: alicorn.Font_Role, weight := alicorn.FONT_WEIGHT_REGULAR) -> f32 {
	run, ok := alicorn.runtime_text_run_build(rt, value, size=size, max_width=max(width, 1), font=font, font_weight=weight)
	if !ok { return size*1.5 }
	height := run.height
	alicorn.text_run_destroy(&run)
	return height
}

semantic_view_measure_window :: proc(rt: ^alicorn.Runtime, view: ^Editor_View_State, document: bridge.State_Document, mode: string, width, scale: f32) -> bool {
	window := &view.semantic_window
	layout := &view.semantic_layout
	if !layout.ready || layout.width != width || layout.scale != scale || layout.generation != window.generation ||
	   layout.font_generation != rt.text_engine.font_generation {
		semantic_view_layout_destroy(layout)
		layout.ready = alicorn.virtual_list_height_index_init(&layout.index, window.total, 80*scale)
		layout.width, layout.scale = width, scale
		layout.generation, layout.font_generation = window.generation, rt.text_engine.font_generation
		layout.first = -1
	}
	if !layout.ready { return false }
	_ = alicorn.virtual_list_height_index_set_count(&layout.index, window.total)
	if layout.first == window.first && layout.count == len(window.segments) { return false }
	layout.first, layout.count = window.first, len(window.segments)
	meta_height := semantic_view_text_height(rt, "Source · line 1", 10000, 12*scale, .UI)
	marker_height := semantic_view_text_height(rt, "… omitted source …", 10000, 11*scale, .UI)
	changed := false
	for segment, index in window.segments {
		if index >= len(layout.rows) { break }
		row: Semantic_View_Row_Layout
		row.font = .UI if document.language == "markdown" else .Monospace
		if mode == "outline" && segment.label == "heading" { row.indent = f32(max(segment.depth, 0))*18*scale }
		content_width := max(width-16*scale-row.indent, 1)
		row.meta_height, row.marker_height = meta_height, marker_height
		weight := alicorn.FONT_WEIGHT_SEMIBOLD if segment.label == "heading" else alicorn.FONT_WEIGHT_REGULAR
		row.text_height = semantic_view_text_height(rt, semantic_view_snippet(segment), content_width, alicorn.DEFAULT_TEXT_SIZE*scale, row.font, weight)
		markers := int(segment.omitted_before)+int(segment.omitted_after)
		if segment.omitted_before {
			row.marker_height = alicorn.maxf(row.marker_height, semantic_view_text_height(rt, semantic_view_omission_marker(segment.omitted_before_lines), content_width, 11*scale, .UI))
		}
		if segment.omitted_after {
			row.marker_height = alicorn.maxf(row.marker_height, semantic_view_text_height(rt, semantic_view_omission_marker(segment.omitted_after_lines), content_width, 11*scale, .UI))
		}
		row.height = 16*scale+row.meta_height+row.text_height+f32(markers)*row.marker_height+f32(1+markers)*3*scale
		layout.rows[index] = row
		changed = alicorn.virtual_list_height_index_set_height(&layout.index, segment.ordinal, row.height) || changed
	}
	return changed
}

semantic_view_muted_text :: proc(ui: ^alicorn.UI, key, value: string, height, size: f32) {
	id := alicorn.text(ui, value, key=alicorn.key_string(key), style=alicorn.layout_style(.Row, width=-1, height=height), text_style=alicorn.Text_Style{font_size=size, overflow=.Ellipsis})
	spans := [?]alicorn.Text_Paint_Span{{start=0, end=len(value), color=alicorn.style_color(ui, .Muted_Text), color_set=true}}
	_ = alicorn.text_paint_spans(ui, id, spans[:])
}

semantic_view_density :: proc(document: bridge.State_Document) -> string {
	return document.view_density if document.view_density != "" else "full"
}

semantic_view_title :: proc(mode: string) -> string {
	if mode == "skim" { return "Skim" }
	if mode == "outline" { return "Outline" }
	return "Full"
}

semantic_view_controls :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime, document: bridge.State_Document, view: ^Editor_View_State) {
	selected := semantic_view_density(document)
	alicorn.container_begin(ui, .Container, label="scratchpad-semantic-view-controls", style=alicorn.layout_style(.Row, height=34, gap=6, align=.Center))
	alicorn.text(ui, "View")
	modes := [?]string{"full", "skim", "outline"}
	for mode, index in modes {
		label := "Full" if index == 0 else ("Skim" if index == 1 else "Outline")
		width := f32(58) if index == 0 else (f32(62) if index == 1 else f32(78))
		if alicorn.button(
			ui, label,
			key=alicorn.key_string(fmt.tprintf("document-density-%s", mode)),
			style=alicorn.layout_style(.Row, width=width, height=28),
			state=alicorn.Button_State{selected=selected == mode},
			variant=.Toolbar,
		) {
			semantic_view_set_density(app, rt, document.id, mode)
		}
	}
	if selected != "full" {
		count := 0
		if view != nil && view.semantic_window_owned && view.semantic_window.document_id == document.id &&
		   view.semantic_window.revision == document.editor_revision && view.semantic_window.mode == selected {
			count = view.semantic_window.total
		}
		hint := "Read only · Full to edit"
		if count > 0 { hint = fmt.tprintf("%d excerpts · Read only · Full to edit", count) }
		semantic_view_muted_text(ui, "view-hint", hint, 20, 12)
	}
	alicorn.container_end(ui)
}

semantic_view_set_density :: proc(app: ^App, rt: ^alicorn.Runtime, document_id, density: string) {
	if app == nil || rt == nil || document_id == "" { return }
	// State strings belong to the current backend snapshot. Preserve that
	// snapshot throughout description, and own the command's ID across it.
	if rt.frame_open {
		if !frame_deferred_action_schedule(app, .Set_View_Density, density, document_id=document_id) {
			set_error(app, "Could not queue the document view change.")
		}
		return
	}
	if len(app.editor_edits) > 0 || editor_active_preedit(app) {
		set_error(app, "Finish the current text input before changing document view.")
		alicorn.invalidate_root(rt, "Scratchpad delayed semantic view change until text input is committed")
		return
	}
	result := bridge.backend_command(&app.backend, "set_view_density", document_id=document_id, view_density=density)
	handle_command_result(app, rt, &result)
	if result.ok && density == "full" {
		for &view in app.editor_views {
			if view.document_id == document_id && view.semantic_window_owned {
				bridge.Semantic_View_Window_Destroy(&view.semantic_window, context.allocator)
				view.semantic_window_owned = false
			}
		}
	}
	bridge.backend_command_result_destroy(&result, context.allocator)
}

semantic_view_go_to_source :: proc(
	app: ^App,
	rt: ^alicorn.Runtime,
	document_id: string,
	expected_revision, source_start, source_end, source_line: u64,
) {
	if app == nil || rt == nil || !app.backend.started || document_id == "" { return }
	if len(app.editor_edits) > 0 || editor_active_preedit(app) {
		set_error(app, "Finish pending text input before navigating from this excerpt.")
		alicorn.invalidate_root(rt, "Scratchpad deferred source navigation until text input is committed")
		return
	}
	document, found := find_document(&app.backend.state, document_id)
	if !found || document.editor_revision != expected_revision {
		set_error(app, "This excerpt is out of date. Reopen the current view before navigating.")
		alicorn.invalidate_root(rt, "Scratchpad rejected a stale semantic source destination")
		return
	}
	if app.backend.state.active != document_id {
		select_document(app, rt, document_id)
		document, found = find_document(&app.backend.state, document_id)
		if !found || app.backend.state.active != document_id || document.editor_revision != expected_revision {
			set_error(app, "This excerpt is no longer available in the active document.")
			alicorn.invalidate_root(rt, "Scratchpad could not activate a semantic source destination")
			return
		}
	}
	if semantic_view_density(document) != "full" {
		semantic_view_set_density(app, rt, document_id, "full")
		document, found = find_document(&app.backend.state, document_id)
		if !found || document.editor_revision != expected_revision || semantic_view_density(document) != "full" {
			set_error(app, "Could not return to the current source before navigating.")
			alicorn.invalidate_root(rt, "Scratchpad could not switch to the source editor")
			return
		}
	}
	view_index, view_ok := editor_view_ensure(&app.editor_views, document_id)
	if !view_ok {
		set_error(app, "Could not retain the source location for this excerpt.")
		alicorn.invalidate_root(rt, "Scratchpad could not retain a semantic source destination")
		return
	}
	view := &app.editor_views[view_index]
	start := min(source_start, document.byte_length)
	end := min(max(source_end, start), document.byte_length)
	line := u64(0)
	if document.line_count > 0 { line = min(max(source_line, u64(1)), document.line_count)-1 }
	view.selection_anchor, view.caret_byte = start, start
	view.anchor_affinity, view.caret_affinity = .Leading, .Leading
	view.preferred_x_set = false
	view.pending_goto_line = false
	view.restore_y_pending, view.restore_x_pending = false, false
	if !editor_reveal_request_set(view, document_id, expected_revision, start, end, line, .Center_When_Needed) {
		set_error(app, "Could not queue the source location for this excerpt.")
		alicorn.invalidate_root(rt, "Scratchpad failed to queue a semantic source reveal")
		return
	}
	app.editor_focus_pending = true
	alicorn.invalidate_root(rt, "Scratchpad navigated from a current semantic excerpt to its source")
}

semantic_view_cache_matches :: proc(view: ^Editor_View_State, document: bridge.State_Document, mode: string) -> bool {
	if view == nil || !view.semantic_window_owned { return false }
	window := &view.semantic_window
	return window.document_id == document.id && window.mode == mode &&
	       window.revision == document.editor_revision && (window.ready || !document.presentation_ready)
}

semantic_view_read_window :: proc(
	app: ^App,
	view: ^Editor_View_State,
	document: bridge.State_Document,
	mode: string,
	first: int,
) -> bool {
	if app == nil || view == nil || first < 0 { return false }
	result := bridge.backend_command(
		&app.backend,
		"read_view_window",
		document_id=document.id,
		projection_first=u64(first),
		projection_limit=SEMANTIC_VIEW_WINDOW_SIZE,
		read_latest_after=false,
	)
	if !result.ok || !result.semantic_view_window_owned {
		set_error(app, result.message if result.message != "" else "Could not load the reduced document view.")
		bridge.backend_command_result_destroy(&result, context.allocator)
		return false
	}
	if view.semantic_window_owned {
		bridge.Semantic_View_Window_Destroy(&view.semantic_window, context.allocator)
	}
	view.semantic_window = result.semantic_view_window
	view.semantic_window_owned = true
	result.semantic_view_window = {}
	result.semantic_view_window_owned = false
	bridge.backend_command_result_destroy(&result, context.allocator)
	return view.semantic_window.mode == mode && view.semantic_window.document_id == document.id &&
	       view.semantic_window.revision == document.editor_revision
}

semantic_view_render :: proc(app: ^App, ui: ^alicorn.UI, document: bridge.State_Document, view: ^Editor_View_State, mode: string) -> bool {
	if app == nil || ui == nil || view == nil || mode == "full" { return false }
	if !semantic_view_cache_matches(view, document, mode) {
		_ = semantic_view_read_window(app, view, document, mode, 0)
	}
	if !view.semantic_window_owned || view.semantic_window.mode != mode || view.semantic_window.revision != document.editor_revision {
		alicorn.text(ui, "Preparing the current reduced view…")
		return true
	}
	window := &view.semantic_window
	if !window.supported {
		alicorn.text(ui, "This file type has no semantic view yet. Showing the editable source below.")
		return false
	}
	if !window.ready {
		alicorn.text(ui, "Preparing the current reduced view…")
		return true
	}
	if window.total == 0 {
		alicorn.text(ui, "No structural excerpts are available. The source is unchanged; switch to Full to edit it.")
		return true
	}
	text_scale := editor_text_scale_effective(app)
	style_scope := alicorn.style_environment_push(ui, alicorn.Style_Environment{text_scale=text_scale})
	defer alicorn.style_environment_pop(ui, style_scope)
	width := ui.runtime.viewport.w
	if view.semantic_layout.width > 0 { width = view.semantic_layout.width }
	_ = semantic_view_measure_window(ui.runtime, view, document, mode, width, text_scale)
	list_key := fmt.tprintf("scratchpad-semantic-view-scroll-%s", document.id)
	list := alicorn.virtual_list_begin_variable(
		ui,
		&view.semantic_layout.index,
		key=alicorn.key_string(list_key),
		style=alicorn.layout_style(grow=1, clip=true),
		label="scratchpad-semantic-view-scroll",
		focusable=true,
	)
	if list.scroll.id == 0 { return true }
	if semantic_view_measure_window(ui.runtime, view, document, mode, list.scroll.viewport_width, text_scale) {
		alicorn.invalidate_root(ui.runtime, "Scratchpad measured the resolved excerpt viewport")
	}
	page_first := window.first
	page_end := page_first+len(window.segments)
	if list.first < page_first || list.last > page_end {
		_ = semantic_view_read_window(app, view, document, mode, list.first)
		window = &view.semantic_window
		if semantic_view_measure_window(ui.runtime, view, document, mode, list.scroll.viewport_width, text_scale) {
			alicorn.invalidate_root(ui.runtime, "Scratchpad measured the next excerpt page")
		}
	}
	if window.ready && window.supported && window.mode == mode && window.revision == document.editor_revision {
		for ordinal := list.first; ordinal < list.last; ordinal += 1 {
			page_index := ordinal-window.first
			if page_index < 0 || page_index >= len(window.segments) || page_index >= len(view.semantic_layout.rows) { continue }
			segment := window.segments[page_index]
			if segment.status != "current" || segment.document_id != document.id || segment.source_revision != document.editor_revision ||
			   segment.end_byte <= segment.start_byte {
				continue
			}
			row := view.semantic_layout.rows[page_index]
			alicorn.container_begin(
				ui,
				.Container,
				label="scratchpad-semantic-view-row",
				key=alicorn.key_u64(u64(segment.ordinal)),
				style=alicorn.layout_style(.Column, width=-1, height=row.height, padding=8*text_scale, gap=3*text_scale, clip=true),
			)
			meta := fmt.tprintf("Line %d", segment.source_start_line)
			if segment.source_start_line > 0 {
				line_range := fmt.tprintf("Line %d", segment.source_start_line)
				if segment.source_end_line > segment.source_start_line {
					line_range = fmt.tprintf("Lines %d–%d", segment.source_start_line, segment.source_end_line)
				}
				meta = line_range
			}
			if mode == "skim" && document.language != "markdown" && segment.section_context != "" {
				meta = fmt.tprintf("%s · %s", meta, segment.section_context)
			}
			alicorn.container_begin(ui, .Container, label="scratchpad-semantic-view-row-heading", style=alicorn.layout_style(.Row, width=-1, height=row.meta_height, gap=8, align=.Center))
			semantic_view_muted_text(ui, "meta", meta, row.meta_height, 12)
			if alicorn.button(
				ui, "Go to source",
				key=alicorn.key_pair(segment.generation, u64(segment.ordinal)),
				style=alicorn.layout_style(.Row, width=104, height=row.meta_height),
				text_style=alicorn.Text_Style{font_size=12, overflow=.Ellipsis},
				content_style=alicorn.button_content_style(.Center, .Center, padding_x=2, padding_y=0),
				variant=.Quiet,
			) {
				if !frame_deferred_action_schedule(
					app, .Go_To_Projection_Source,
					document_id=segment.document_id,
					editor_revision=segment.source_revision,
					source_start=u64(segment.start_byte),
					source_end=u64(segment.end_byte),
					source_line=u64(segment.source_start_line),
				) {
					set_error(app, "Could not queue navigation to this source excerpt.")
				}
			}
			alicorn.container_end(ui)
			if segment.omitted_before {
				semantic_view_muted_text(ui, "before", semantic_view_omission_marker(segment.omitted_before_lines), row.marker_height, 11)
			}
			weight := alicorn.FONT_WEIGHT_SEMIBOLD if segment.label == "heading" else alicorn.FONT_WEIGHT_REGULAR
			alicorn.container_begin(ui, .Container, label="scratchpad-semantic-view-source-line", style=alicorn.layout_style(.Row, width=-1, height=row.text_height, gap=0, clip=true))
			if row.indent > 0 {
				alicorn.container_begin(ui, .Container, label="scratchpad-semantic-view-outline-indent", style=alicorn.layout_style(.Row, width=row.indent, height=row.text_height))
				alicorn.container_end(ui)
			}
			alicorn.text(ui, semantic_view_snippet(segment), style=alicorn.layout_style(.Row, grow=1, height=row.text_height, clip=true), font=row.font,
				text_style=alicorn.Text_Style{font_weight=weight, overflow=.Wrap})
			alicorn.container_end(ui)
			if segment.omitted_after {
				semantic_view_muted_text(ui, "after", semantic_view_omission_marker(segment.omitted_after_lines), row.marker_height, 11)
			}
			alicorn.container_end(ui)
		}
	}
	alicorn.virtual_list_end(ui, list)
	return true
}
