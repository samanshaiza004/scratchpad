package main

import "core:fmt"
import alicorn "alicorn:runtime"
import gui "alicorn:ui"
import host "alicorn:native/sdl_gpu"
import bridge "./bridge"

SYMBOL_PICKER_ROW_HEIGHT :: f32(38)

symbol_picker_open_surface :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil || !app.backend.started || app.shutdown_intent != .None ||
	   app.close_document_id != "" || app.workspace_mutation_kind != .None ||
	   app.settings_surface_open || app.recent_workspaces_open {
		return
	}
	if app.workspace_search_edit_active && !workspace_search_edit_finish(app, rt, refresh=false) {
		return
	}
	if app.command_palette_open { command_palette_close_surface(app, rt, false) }
	if app.quick_open_open { quick_open_close_surface(app, rt, false) }
	app.symbol_picker_previous_focus = alicorn.focused_node(rt)
	app.symbol_picker_previous_search_mode = app.workspace_search_mode
	app.symbol_picker_previous_projection_kind = app.structural_projection_kind
	app.symbol_picker_open = true
	app.symbol_picker_query_node = 0
	app.symbol_picker_overlay_node = 0
	app.symbol_picker_panel_node = 0
	app.symbol_picker_results_owner = 0
	app.symbol_picker_page_first = 0
	app.symbol_picker_selected_index = 0
	app.symbol_picker_focus_pending = true
	find_set_message(&app.symbol_picker_query, "")
	app.structural_projection_kind = "symbols"
	app.structural_view_scroll_owner = 0
	projection_sidebar_window_clear(app)
	alicorn.invalidate_root(rt, "Scratchpad Go to Symbol opened")
}

symbol_picker_close_surface :: proc(app: ^App, rt: ^alicorn.Runtime, restore_focus: bool) {
	if app == nil { return }
	app.symbol_picker_open = false
	app.symbol_picker_focus_pending = false
	app.symbol_picker_query_node = 0
	app.symbol_picker_overlay_node = 0
	app.symbol_picker_panel_node = 0
	app.symbol_picker_results_owner = 0
	find_set_message(&app.symbol_picker_query, "")
	if app.symbol_picker_previous_projection_kind != "" {
		app.structural_projection_kind = app.symbol_picker_previous_projection_kind
	}
	app.structural_view_scroll_owner = 0
	projection_sidebar_window_clear(app)
	if restore_focus && rt != nil && app.symbol_picker_previous_focus != 0 {
		if _, found := alicorn.node_info(rt, app.symbol_picker_previous_focus); found {
			_ = alicorn.focus(rt, app.symbol_picker_previous_focus)
		}
	} else if restore_focus && app.symbol_picker_previous_search_mode {
		app.workspace_search_focus_pending = true
	}
	app.symbol_picker_previous_focus = 0
	app.symbol_picker_previous_search_mode = false
	app.symbol_picker_previous_projection_kind = ""
	if rt != nil { alicorn.invalidate_root(rt, "Scratchpad Go to Symbol closed") }
}

symbol_picker_filter_indices :: proc(app: ^App, allocator := context.temp_allocator) -> [dynamic]int {
	results := make([dynamic]int, 0, len(app.structural_view_window.segments), allocator=allocator)
	if app == nil || !app.structural_view_owned || !app.structural_view_window.ready { return results }
	for segment, index in app.structural_view_window.segments {
		label := segment.text
		if segment.section_context != "" { label = fmt.tprintf("%s  %s", segment.label, segment.section_context) }
		if label == "" { label = segment.label }
		if len(app.symbol_picker_query) > 0 {
			score := max(command_palette_field_score(app.symbol_picker_query, label),
				command_palette_field_score(app.symbol_picker_query, segment.label))
			if score < 0 { continue }
		}
		append(&results, index)
	}
	return results
}

symbol_picker_restore_focus_after_frame :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil || !app.symbol_picker_open || !app.symbol_picker_focus_pending ||
	   app.symbol_picker_query_node == 0 { return }
	if alicorn.focus(rt, app.symbol_picker_query_node) {
		app.symbol_picker_focus_pending = false
	}
}

symbol_picker_move_selection :: proc(app: ^App, rt: ^alicorn.Runtime, direction: int) {
	if app == nil || rt == nil { return }
	filtered := symbol_picker_filter_indices(app, context.temp_allocator)
	defer delete(filtered)
	if len(filtered) == 0 { return }
	app.symbol_picker_selected_index = clamp(app.symbol_picker_selected_index+direction, 0, len(filtered)-1)
	if app.symbol_picker_results_owner != 0 {
		_ = alicorn.virtual_list_ensure_visible(rt, app.symbol_picker_results_owner,
			app.symbol_picker_selected_index, "Scratchpad Go to Symbol selection visibility")
	}
	alicorn.invalidate_root(rt, "Scratchpad Go to Symbol selection moved")
}

symbol_picker_build :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime) {
	if app == nil || ui == nil || rt == nil || !app.symbol_picker_open { return }
	filtered := symbol_picker_filter_indices(app, alicorn.runtime_scratch_allocator(rt))
	defer delete(filtered)
	if len(filtered) == 0 { app.symbol_picker_selected_index = 0
	} else { app.symbol_picker_selected_index = clamp(app.symbol_picker_selected_index, 0, len(filtered)-1) }
	app.symbol_picker_overlay_node = alicorn.modal_overlay_begin(
		ui,
		alicorn.key_string("scratchpad-symbol-picker-overlay"),
		style=alicorn.layout_style(.Column, grow=1, padding=32, align=.Center, justify=.Center, clip=true),
		backdrop_color=scratchpad_modal_backdrop_color(rt, app.workbench_theme),
	)
	app.symbol_picker_panel_node = alicorn.surface_begin(
		ui,
		alicorn.surface_core_color_role(.Surface),
		label="scratchpad-symbol-picker-panel",
		key=alicorn.key_string("scratchpad-symbol-picker-panel"),
		style=alicorn.layout_style(.Column, width=760, max_width=900, max_height=700, height=560, padding=14, gap=8, clip=true),
		shape=scratchpad_surface_shape(app, 7),
		material=scratchpad_surface_material(app, app.floating_surface_material),
		physical_height=scratchpad_surface_height(app, 1),
	)
	gui.text(ui, "Go to Symbol", style=alicorn.layout_style(.Row, height=24),
		text_style=alicorn.Text_Style{font_size=17, font_weight=alicorn.FONT_WEIGHT_MEDIUM})
	app.symbol_picker_query_node = alicorn.text_field(ui, app.symbol_picker_query,
		key=alicorn.key_string("scratchpad-symbol-picker-query"),
		style=alicorn.layout_style(.Row, height=40),
		text_style=SCRATCHPAD_PROMINENT_INPUT_TEXT_STYLE)
	if app.symbol_picker_query_node != 0 {
		_ = alicorn.semantic_text_field_label(ui, "Filter document symbols")
	}

	active, has_active := find_document(&app.backend.state, app.backend.state.active)
	if !has_active || active.path == "" || active.view_kind == "image" || active.view_kind == "unsupported" {
		gui.text(ui, "Open a text document to search its symbols.", style=alicorn.layout_style(.Row, height=24),
			color=alicorn.style_color(ui, .Muted_Text))
	} else if app.structural_view_error != "" {
		gui.text(ui, app.structural_view_error, style=alicorn.layout_style(.Row, height=24),
			color=alicorn.style_color(ui, .Muted_Text))
	} else if !app.structural_view_owned || !app.structural_view_window.ready {
		gui.text(ui, "Loading symbols…", style=alicorn.layout_style(.Row, height=24),
			color=alicorn.style_color(ui, .Muted_Text))
	} else if !app.structural_view_window.supported {
		gui.text(ui, "This document does not provide a symbol projection.", style=alicorn.layout_style(.Row, height=24),
			color=alicorn.style_color(ui, .Muted_Text))
	} else if len(filtered) == 0 {
		gui.text(ui, "No symbols match this query on the current page.", style=alicorn.layout_style(.Row, height=24),
			color=alicorn.style_color(ui, .Muted_Text))
	} else {
		list := alicorn.virtual_list_begin(
			ui,
			len(filtered),
			SYMBOL_PICKER_ROW_HEIGHT,
			key=alicorn.key_string("scratchpad-symbol-picker-results"),
			style=alicorn.layout_style(grow=1, clip=true),
			label="Symbols in current document",
			focusable=true,
		)
		app.symbol_picker_results_owner = list.scroll.id
		for result_index := list.first; result_index < list.last; result_index += 1 {
			segment_index := filtered[result_index]
			if segment_index < 0 || segment_index >= len(app.structural_view_window.segments) { continue }
			segment := app.structural_view_window.segments[segment_index]
			label := segment.text
			if segment.section_context != "" && segment.label != "heading" {
				label = fmt.tprintf("%s  ·  %s", segment.label, segment.section_context)
			}
			if label == "" { label = segment.label }
			if gui.row(ui, key=alicorn.key_pair(segment.generation, u64(segment.ordinal)),
				label="symbol-picker-row", height=SYMBOL_PICKER_ROW_HEIGHT-2, gap=8, align=.Center) {
				if gui.button(ui, label,
					key=alicorn.key_pair(segment.generation, u64(segment.ordinal)+0x10000000),
					grow=1, height=34,
					state=alicorn.Button_State{selected=result_index == app.symbol_picker_selected_index},
					variant=.Quiet,
					text_style=alicorn.Text_Style{overflow=.Ellipsis},
					content_style=alicorn.button_content_style(.Start, padding_x=8, padding_y=4),
				) {
					app.symbol_picker_selected_index = result_index
					if projection_sidebar_navigate(app, rt, segment, false) {
						app.workspace_search_mode = false
						app.workspace_projection_mode = false
						symbol_picker_close_surface(app, rt, false)
					}
				}
				gui.text(ui, fmt.tprintf("%d", segment.source_start_line),
					style=alicorn.layout_style(.Row, width=48),
					color=alicorn.style_color(ui, .Muted_Text),
					text_style=alicorn.Text_Style{font_size=12},
				)
			}
		}
		alicorn.virtual_list_end(ui, list)
	}

	window := &app.structural_view_window
	page_count := bridge.MAX_PROJECTION_WINDOW
	previous_enabled := window.first > 0
	next_enabled := window.first+len(window.segments) < window.total
	if gui.row(ui, label="symbol-picker-footer", height=34, gap=8, align=.Center) {
		first := window.first+1
		last := window.first+len(window.segments)
		if len(window.segments) == 0 { first = 0; last = 0 }
		gui.text(ui, fmt.tprintf("%d–%d of %d  ·  Filter the current %d-symbol page", first, last, window.total, page_count),
			style=alicorn.layout_style(.Row, grow=1),
			color=alicorn.style_color(ui, .Muted_Text),
			text_style=alicorn.Text_Style{font_size=12, overflow=.Ellipsis})
		if gui.button(ui, "Previous", key="symbol-picker-previous-page", width=80, height=28,
			state=alicorn.Button_State{disabled=!previous_enabled}, variant=.Toolbar) {
			app.symbol_picker_page_first = max(window.first-page_count, 0)
			app.symbol_picker_selected_index = 0
			app.structural_view_scroll_owner = 0
			projection_sidebar_window_clear(app)
			alicorn.invalidate_root(rt, "Scratchpad Go to Symbol previous page")
		}
		if gui.button(ui, "Next", key="symbol-picker-next-page", width=64, height=28,
			state=alicorn.Button_State{disabled=!next_enabled}, variant=.Toolbar) {
			app.symbol_picker_page_first = window.first+page_count
			app.symbol_picker_selected_index = 0
			app.structural_view_scroll_owner = 0
			projection_sidebar_window_clear(app)
			alicorn.invalidate_root(rt, "Scratchpad Go to Symbol next page")
		}
		if gui.button(ui, "Close", key="symbol-picker-close", width=70, height=28, variant=.Quiet) {
			symbol_picker_close_surface(app, rt, true)
		}
	}
	alicorn.surface_end(ui)
	alicorn.modal_overlay_end(ui)
}

symbol_picker_handle_key :: proc(app: ^App, rt: ^alicorn.Runtime, key: host.Application_Key) -> bool {
	if app == nil || rt == nil || !app.symbol_picker_open { return false }
	filtered := symbol_picker_filter_indices(app, context.temp_allocator)
	defer delete(filtered)
	#partial switch key {
	case .Escape:
		symbol_picker_close_surface(app, rt, true)
		return true
	case .Up:
		symbol_picker_move_selection(app, rt, -1)
		return true
	case .Down:
		symbol_picker_move_selection(app, rt, 1)
		return true
	case .Page_Up:
		app.symbol_picker_page_first = max(app.symbol_picker_page_first-bridge.MAX_PROJECTION_WINDOW, 0)
		app.structural_view_scroll_owner = 0
		projection_sidebar_window_clear(app)
		alicorn.invalidate_root(rt, "Scratchpad Go to Symbol previous page")
		return true
	case .Page_Down:
		if app.structural_view_owned && app.structural_view_window.first+len(app.structural_view_window.segments) < app.structural_view_window.total {
			app.symbol_picker_page_first = app.structural_view_window.first+bridge.MAX_PROJECTION_WINDOW
			app.structural_view_scroll_owner = 0
			projection_sidebar_window_clear(app)
			alicorn.invalidate_root(rt, "Scratchpad Go to Symbol next page")
		}
		return true
	case .Return:
		if len(filtered) == 0 || !app.structural_view_owned { return true }
		app.symbol_picker_selected_index = clamp(app.symbol_picker_selected_index, 0, len(filtered)-1)
		segment_index := filtered[app.symbol_picker_selected_index]
		if segment_index >= 0 && segment_index < len(app.structural_view_window.segments) {
			segment := app.structural_view_window.segments[segment_index]
			if projection_sidebar_navigate(app, rt, segment, false) {
				app.workspace_search_mode = false
				app.workspace_projection_mode = false
				symbol_picker_close_surface(app, rt, false)
			}
		}
		return true
	case:
		return true
	}
}

symbol_picker_pointer :: proc(app: ^App, rt: ^alicorn.Runtime, event: alicorn.Pointer_Event, target: alicorn.Node_ID) -> bool {
	if app == nil || rt == nil || !app.symbol_picker_open { return false }
	if event.kind == .Down && event.button == alicorn.POINTER_BUTTON_PRIMARY && target == app.symbol_picker_overlay_node {
		panel, found := alicorn.node_info(rt, app.symbol_picker_panel_node)
		inside := found && event.x >= panel.bounds.x && event.x < panel.bounds.x+panel.bounds.w &&
			event.y >= panel.bounds.y && event.y < panel.bounds.y+panel.bounds.h
		if !inside { symbol_picker_close_surface(app, rt, true) }
	}
	return true
}

symbol_picker_text_change :: proc(state: rawptr, rt: ^alicorn.Runtime, change: alicorn.Text_Change) {
	app := cast(^App)state
	if app == nil || rt == nil || !app.symbol_picker_open || change.node != app.symbol_picker_query_node || !change.changed { return }
	find_set_message(&app.symbol_picker_query, change.text)
	app.symbol_picker_selected_index = 0
	if app.symbol_picker_results_owner != 0 {
		_ = alicorn.virtual_list_ensure_visible(rt, app.symbol_picker_results_owner, 0,
			"Scratchpad Go to Symbol query reset visibility")
	}
	alicorn.invalidate_root(rt, "Scratchpad Go to Symbol query changed")
}
