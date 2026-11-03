package main

import "core:fmt"
import "core:strings"
import alicorn "alicorn:runtime"
import gui "alicorn:ui"
import bridge "./bridge"

STRUCTURAL_VIEW_ROW_HEIGHT :: f32(34)
STRUCTURAL_VIEW_HEADER_HEIGHT :: f32(20)

projection_sidebar_window_clear :: proc(app: ^App) {
	if app == nil { return }
	if app.structural_view_owned {
		bridge.Semantic_View_Window_Destroy(&app.structural_view_window, context.allocator)
	}
	app.structural_view_owned = false
	app.structural_view_window = {}
	app.structural_view_revision = 0
	app.structural_view_first = 0
	app.structural_view_waiting_presentation = 0
}

projection_sidebar_destroy :: proc(app: ^App) {
	if app == nil { return }
	projection_sidebar_window_clear(app)
	if len(app.structural_view_document_id) > 0 { delete(app.structural_view_document_id, context.allocator) }
	if len(app.structural_view_kind) > 0 { delete(app.structural_view_kind, context.allocator) }
	if len(app.structural_view_error) > 0 { delete(app.structural_view_error, context.allocator) }
	app.structural_view_document_id = ""
	app.structural_view_kind = ""
	app.structural_view_error = ""
	app.structural_view_scroll_owner = 0
}

projection_sidebar_set_identity :: proc(app: ^App, document_id, kind: string) {
	if app == nil { return }
	if app.structural_view_document_id != document_id {
		if len(app.structural_view_document_id) > 0 { delete(app.structural_view_document_id, context.allocator) }
		app.structural_view_document_id, _ = strings.clone(document_id, context.allocator)
	}
	if app.structural_view_kind != kind {
		if len(app.structural_view_kind) > 0 { delete(app.structural_view_kind, context.allocator) }
		app.structural_view_kind, _ = strings.clone(kind, context.allocator)
	}
}

projection_sidebar_prepare :: proc(app: ^App, rt: ^alicorn.Runtime, requested_first: int = -1) {
	if app == nil || rt == nil || !app.backend.started { return }
	document, found := find_document(&app.backend.state, app.backend.state.active)
	if !found || document.view_kind == "image" || document.view_kind == "unsupported" ||
		floating_window_contains(app, document.id) || document.path == "" {
		projection_sidebar_window_clear(app)
		projection_sidebar_set_identity(app, "", app.structural_projection_kind)
		app.structural_view_scroll_owner = 0
		return
	}
	if app.structural_projection_kind == "" { app.structural_projection_kind = "symbols" }
	kind := app.structural_projection_kind
	identity_changed := app.structural_view_document_id != document.id ||
		app.structural_view_kind != kind || app.structural_view_revision != document.editor_revision
	if identity_changed {
		projection_sidebar_window_clear(app)
		projection_sidebar_set_identity(app, document.id, kind)
		app.structural_view_revision = document.editor_revision
		app.structural_view_scroll_owner = 0
		find_set_message(&app.structural_view_error, "")
	}

	first_visible := max(requested_first, 0) if requested_first >= 0 else 0
	if requested_first < 0 && !identity_changed && app.structural_view_scroll_owner != 0 {
		scroll := alicorn.scroll_region_state(rt, app.structural_view_scroll_owner)
		if scroll.id != 0 {
			first_visible = max(int(scroll.offset_y/STRUCTURAL_VIEW_ROW_HEIGHT), 0)
		}
	}
	page_first := first_visible/bridge.MAX_PROJECTION_WINDOW*bridge.MAX_PROJECTION_WINDOW
	window_matches := app.structural_view_owned &&
		app.structural_view_window.document_id == document.id &&
		app.structural_view_window.mode == kind &&
		app.structural_view_window.revision == document.editor_revision
	if window_matches && !app.structural_view_window.ready &&
		document.presentation_ready &&
		document.presentation_revision != app.structural_view_waiting_presentation {
		window_matches = false
	}
	if window_matches && (first_visible < app.structural_view_window.first ||
		first_visible >= app.structural_view_window.first+max(len(app.structural_view_window.segments), 1)) {
		window_matches = false
	}
	if window_matches { return }

	projection_sidebar_window_clear(app)
	result := bridge.backend_command(
		&app.backend,
		"read_view_window",
		document_id=document.id,
		projection_kind=kind,
		projection_first=u64(page_first),
		projection_limit=bridge.MAX_PROJECTION_WINDOW,
		allow_unversioned_read=true,
		read_latest_after=false,
	)
	defer bridge.backend_command_result_destroy(&result, context.allocator)
	if !result.ok || !result.semantic_view_window_owned {
		find_set_message(&app.structural_view_error,
			result.message if result.message != "" else "Could not load this structural view.")
		return
	}
	window := result.semantic_view_window
	if window.document_id != document.id || window.mode != kind || window.revision != document.editor_revision {
		bridge.Semantic_View_Window_Destroy(&window, context.allocator)
		return
	}
	app.structural_view_window = window
	app.structural_view_owned = true
	app.structural_view_first = page_first
	app.structural_view_waiting_presentation = document.presentation_revision
	result.semantic_view_window = {}
	result.semantic_view_window_owned = false
	find_set_message(&app.structural_view_error, "")
}

projection_sidebar_build :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime) {
	if app == nil || ui == nil || rt == nil { return }
	active, has_active := find_document(&app.backend.state, app.backend.state.active)
	active_text := has_active && (active.view_kind == "" || active.view_kind == "text")
	if !active_text || floating_window_contains(app, active.id) {
		gui.text(ui, "Open a text document to browse its structure.")
		return
	}

	gui.text(ui, projection_sidebar_title(app.structural_projection_kind),
		style=alicorn.layout_style(.Row, height=STRUCTURAL_VIEW_HEADER_HEIGHT),
		color=alicorn.style_color(ui, .Text),
		text_style=alicorn.Text_Style{font_size=13, font_weight=alicorn.FONT_WEIGHT_MEDIUM},
	)
	gui.text(ui, active.path,
		style=alicorn.layout_style(.Row, height=STRUCTURAL_VIEW_HEADER_HEIGHT, clip=true),
		color=alicorn.style_color(ui, .Muted_Text),
		text_style=alicorn.Text_Style{font_size=12, overflow=.Ellipsis},
	)
	if app.structural_view_error != "" {
		gui.text(ui, app.structural_view_error, color=alicorn.style_color(ui, .Muted_Text))
		return
	}
	if !app.structural_view_owned {
		gui.text(ui, "Loading source structure…", color=alicorn.style_color(ui, .Muted_Text))
		return
	}
	window := &app.structural_view_window
	if !window.ready {
		gui.text(ui, "Updating source structure…", color=alicorn.style_color(ui, .Muted_Text))
		return
	}
	if !window.supported {
		gui.text(ui, "This file type has no matching structure. The source remains editable.",
			text_style=alicorn.Text_Style{font_size=12, overflow=.Wrap})
		return
	}
	if window.total == 0 {
		gui.text(ui, projection_sidebar_empty_message(app.structural_projection_kind),
			color=alicorn.style_color(ui, .Muted_Text))
		return
	}
	count := fmt.tprintf("%d results", window.total)
	gui.text(ui, count,
		style=alicorn.layout_style(.Row, height=STRUCTURAL_VIEW_HEADER_HEIGHT),
		color=alicorn.style_color(ui, .Muted_Text),
		text_style=alicorn.Text_Style{font_size=12},
	)
	list_key := alicorn.key_string(fmt.tprintf(
		"scratchpad-structural-view-%s-%s",
		active.id,
		app.structural_projection_kind,
	))
	list := alicorn.virtual_list_begin(
		ui,
		window.total,
		STRUCTURAL_VIEW_ROW_HEIGHT,
		key=list_key,
		style=alicorn.layout_style(grow=1, clip=true),
		label=fmt.tprintf("%s in %s", projection_sidebar_title(app.structural_projection_kind), active.path),
		focusable=true,
	)
	app.structural_view_scroll_owner = list.scroll.id
	for position := list.first; position < list.last; position += 1 {
		segment_index := position-window.first
		if segment_index < 0 || segment_index >= len(window.segments) {
			gui.text(ui, "Loading…",
				key=alicorn.key_pair(window.generation, u64(position)),
				style=alicorn.layout_style(.Row, height=STRUCTURAL_VIEW_ROW_HEIGHT),
				color=alicorn.style_color(ui, .Muted_Text))
			continue
		}
		segment := window.segments[segment_index]
		projection_sidebar_row(app, ui, rt, segment)
	}
	alicorn.virtual_list_end(ui, list)
}

projection_sidebar_row :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime, segment: bridge.Semantic_View_Segment) {
	kind := app.structural_projection_kind
	title := segment.text
	switch kind {
	case "symbols":
		if segment.section_context != "" { title = segment.section_context }
	case "links":
		if segment.section_context != "" { title = segment.section_context }
	}
	if title == "" { title = segment.label }
	if kind == "symbols" && segment.label != "heading" {
		title = fmt.tprintf("%s  ·  %s", segment.label, segment.section_context if segment.section_context != "" else segment.text)
	}
	if gui.row(ui,
		key=alicorn.key_pair(segment.generation, u64(segment.ordinal)),
		label=fmt.tprintf("structural-result-%d", segment.ordinal),
		height=STRUCTURAL_VIEW_ROW_HEIGHT,
		gap=3,
		align=.Center,
	) {
		if kind == "symbols" && segment.label == "heading" && segment.depth > 0 {
			indent_width := f32(min(segment.depth, 8))*12
			_ = gui.box(ui, width=indent_width, height=1, fill=alicorn.NO_BACKGROUND_COLOR)
		}
		if gui.button(ui, title,
			key=alicorn.key_pair(segment.generation, u64(segment.ordinal)),
			grow=1,
			height=29,
			variant=.Quiet,
			text_style=alicorn.Text_Style{font_size=13, overflow=.Ellipsis},
			content_style=alicorn.button_content_style(.Start, padding_x=4, padding_y=2),
		) {
			_ = projection_sidebar_navigate(app, rt, segment, false)
		}
		gui.text(ui, fmt.tprintf("%d", segment.source_start_line),
			style=alicorn.layout_style(.Row, width=30),
			color=alicorn.style_color(ui, .Muted_Text),
			text_style=alicorn.Text_Style{font_size=11},
		)
		if kind == "tasks" {
			toggle_label := "Toggle"
			if segment.section_context == "complete" { toggle_label = "Reopen" }
			if gui.button(ui, toggle_label,
				key=alicorn.key_pair(segment.generation, u64(segment.ordinal)+0x80000000),
				width=58,
				height=26,
				variant=.Toolbar,
				text_style=alicorn.Text_Style{font_size=11, overflow=.Ellipsis},
			) {
				_ = projection_sidebar_navigate(app, rt, segment, true)
			}
		}
	}
}

projection_sidebar_navigate :: proc(app: ^App, rt: ^alicorn.Runtime, segment: bridge.Semantic_View_Segment, toggle_task: bool) -> bool {
	if app == nil || rt == nil || segment.status != "current" { return false }
	document, found := find_document(&app.backend.state, segment.document_id)
	if !found || document.editor_revision != segment.source_revision ||
		segment.start_byte < 0 || u64(segment.start_byte) > document.byte_length {
		projection_sidebar_window_clear(app)
		alicorn.invalidate_root(rt, "Scratchpad rejected a stale structural source range")
		return false
	}
	if len(app.editor_edits) > 0 || editor_active_preedit(app) {
		set_error(app, "Finish the current edit before navigating to a structural result.")
		alicorn.invalidate_root(rt, "Scratchpad structural navigation waited for committed edits")
		return false
	}
	response := bridge.backend_command(
		&app.backend,
		"open_path",
		path=document.path,
		has_target_byte=true,
		target_byte=u64(segment.start_byte),
	)
	if !response.ok {
		set_error(app, response.message if response.message != "" else "Could not open the structural source range.")
		bridge.backend_command_result_destroy(&response, context.allocator)
		alicorn.invalidate_root(rt, "Scratchpad structural source navigation failed")
		return false
	}
	app.editor_focus_pending = true
	handle_command_result(app, rt, &response)
	if response.editor_selection.document_id != "" {
		editor_apply_backend_selection(app, rt, response.editor_selection)
	}
	bridge.backend_command_result_destroy(&response, context.allocator)
	if toggle_task {
		dispatch_action(app, rt, ACTION_ITEM_TOGGLE)
	}
	alicorn.invalidate_root(rt, "Scratchpad navigated from a structural projection")
	return true
}

projection_sidebar_empty_message :: proc(kind: string) -> string {
	switch kind {
	case "tasks": return "No tasks in this document."
	case "symbols": return "No headings or code symbols in this document."
	case "links": return "No links in this document."
	}
	return "No structural results."
}

projection_sidebar_title :: proc(kind: string) -> string {
	switch kind {
	case "tasks": return "Tasks"
	case "symbols": return "Symbols"
	case "links": return "Links"
	}
	return "Structure"
}
