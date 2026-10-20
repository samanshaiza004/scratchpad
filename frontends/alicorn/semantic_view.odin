package main

import "core:fmt"
import alicorn "alicorn:runtime"
import bridge "./bridge"

SEMANTIC_VIEW_WINDOW_SIZE :: u64(128)
SEMANTIC_VIEW_ROW_HEIGHT :: f32(160)

semantic_view_density :: proc(document: bridge.State_Document) -> string {
	return document.view_density if document.view_density != "" else "full"
}

semantic_view_title :: proc(mode: string) -> string {
	if mode == "skim" { return "Skim" }
	if mode == "outline" { return "Outline" }
	return "Full"
}

semantic_view_controls :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime, document: bridge.State_Document) {
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
	alicorn.container_end(ui)
}

semantic_view_set_density :: proc(app: ^App, rt: ^alicorn.Runtime, document_id, density: string) {
	if app == nil || rt == nil || document_id == "" { return }
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
	alicorn.container_begin(ui, .Container, label="scratchpad-semantic-view-notice", style=alicorn.layout_style(.Row, height=34, padding=6, align=.Center), color=alicorn.style_color(ui, .Subtle_Surface))
	alicorn.text(ui, fmt.tprintf("%s · %d source-mapped excerpts · read-only; ellipses mark omitted source. Full returns to editing.", semantic_view_title(mode), window.total))
	alicorn.container_end(ui)

	text_scale := editor_text_scale_effective(app)
	row_height := SEMANTIC_VIEW_ROW_HEIGHT*text_scale
	list_key := fmt.tprintf("scratchpad-semantic-view-scroll-%s", document.id)
	list := alicorn.virtual_list_begin(
		ui,
		window.total,
		row_height,
		key=alicorn.key_string(list_key),
		style=alicorn.layout_style(grow=1, clip=true),
		label="scratchpad-semantic-view-scroll",
		focusable=true,
	)
	if list.scroll.id == 0 { return true }
	page_first := window.first
	page_end := page_first+len(window.segments)
	if list.first < page_first || list.last > page_end {
		_ = semantic_view_read_window(app, view, document, mode, list.first)
		window = &view.semantic_window
	}
	if window.ready && window.supported && window.mode == mode && window.revision == document.editor_revision {
		for ordinal := list.first; ordinal < list.last; ordinal += 1 {
			page_index := ordinal-window.first
			if page_index < 0 || page_index >= len(window.segments) { continue }
			segment := window.segments[page_index]
			if segment.status != "current" || segment.document_id != document.id || segment.source_revision != document.editor_revision ||
			   segment.end_byte <= segment.start_byte {
				continue
			}
			alicorn.container_begin(
				ui,
				.Container,
				label="scratchpad-semantic-view-row",
				key=alicorn.key_u64(u64(segment.ordinal)),
				style=alicorn.layout_style(.Column, width=-1, height=row_height, padding=8*text_scale, gap=3*text_scale, clip=true),
				color=alicorn.style_color(ui, .Subtle_Surface),
			)
			meta := segment.label
			if segment.section_context != "" { meta = fmt.tprintf("%s · %s", segment.label, segment.section_context) }
			if segment.source_start_line > 0 {
				line_range := fmt.tprintf("line %d", segment.source_start_line)
				if segment.source_end_line > segment.source_start_line {
					line_range = fmt.tprintf("lines %d–%d", segment.source_start_line, segment.source_end_line)
				}
				meta = fmt.tprintf("%s · %s", meta, line_range)
			}
			alicorn.text(ui, meta, style=alicorn.layout_style(.Row, height=20*text_scale), text_style=alicorn.Text_Style{overflow=.Ellipsis})
			marker_count := 0
			if segment.omitted_before {
				alicorn.text(ui, "… omitted source before this excerpt …", style=alicorn.layout_style(.Row, height=14*text_scale), text_style=alicorn.Text_Style{overflow=.Ellipsis})
				marker_count += 1
			}
			if segment.omitted_after {
				alicorn.text(ui, "… omitted source after this excerpt …", style=alicorn.layout_style(.Row, height=14*text_scale), text_style=alicorn.Text_Style{overflow=.Ellipsis})
				marker_count += 1
			}
			snippet := segment.text
			if segment.truncated { snippet = fmt.tprintf("%s…", segment.text) }
			text_height := max(row_height-16*text_scale-6*text_scale-20*text_scale-f32(marker_count)*14*text_scale, 20*text_scale)
			alicorn.text(ui, snippet, style=alicorn.layout_style(.Row, width=-1, height=text_height, clip=true), text_style=alicorn.Text_Style{overflow=.Wrap})
			alicorn.container_end(ui)
		}
	}
	alicorn.virtual_list_end(ui, list)
	return true
}
