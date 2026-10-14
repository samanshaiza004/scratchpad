package main

import "core:fmt"
import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"

EDITOR_FONT_PICKER_MAX_VISIBLE_ROWS :: 10
EDITOR_FONT_PICKER_ROW_HEIGHT :: f32(48)

editor_font_ascii_lower :: proc(value: u8) -> u8 {
	if value >= 'A' && value <= 'Z' { return value+('a'-'A') }
	return value
}

editor_font_contains_folded :: proc(haystack, needle: string) -> bool {
	if len(needle) == 0 { return true }
	if len(needle) > len(haystack) { return false }
	for start in 0..=len(haystack)-len(needle) {
		matches := true
		for offset in 0..<len(needle) {
			if editor_font_ascii_lower(haystack[start+offset]) != editor_font_ascii_lower(needle[offset]) {
				matches = false
				break
			}
		}
		if matches { return true }
	}
	return false
}

editor_font_family_matches :: proc(family: System_Font_Family, query: string) -> bool {
	position := 0
	for position < len(query) {
		for position < len(query) && (query[position] == ' ' || query[position] == '\t' || query[position] == '\n') { position += 1 }
		if position >= len(query) { break }
		start := position
		for position < len(query) && query[position] != ' ' && query[position] != '\t' && query[position] != '\n' { position += 1 }
		term := query[start:position]
		if !editor_font_contains_folded(family.family, term) { return false }
	}
	return true
}

editor_font_picker_filter :: proc(catalog: []System_Font_Family, query: string, allocator := context.temp_allocator) -> [dynamic]int {
	results := make([dynamic]int, 0, min(len(catalog), 512), allocator=allocator)
	for family, index in catalog {
		if editor_font_family_matches(family, query) { append(&results, index) }
	}
	return results
}

editor_font_picker_selectable :: proc(catalog: []System_Font_Family, result_index: int) -> bool {
	return result_index >= 0 && result_index < len(catalog) && catalog[result_index].unsupported_reason == ""
}

scratchpad_editor_font_picker_open :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil || app.editor_font_picker_open { return }
	scratchpad_editor_font_catalog_ensure(app)
	app.editor_font_picker_previous_focus = alicorn.focused_node(rt)
	app.editor_font_picker_open = true
	app.editor_font_picker_focus_pending = true
	app.editor_font_picker_restore_pending = false
	app.editor_font_picker_overlay_node = 0
	app.editor_font_picker_panel_node = 0
	app.editor_font_picker_query_node = 0
	app.editor_font_picker_results_owner = 0
	app.editor_font_picker_selected = 0
	find_set_message(&app.editor_font_picker_query, "")
	alicorn.invalidate_root(rt, "Scratchpad editor font picker opened")
}

scratchpad_editor_font_picker_close :: proc(app: ^App, rt: ^alicorn.Runtime, restore_focus: bool) {
	if app == nil { return }
	app.editor_font_picker_open = false
	app.editor_font_picker_focus_pending = false
	app.editor_font_picker_restore_pending = restore_focus
	app.editor_font_picker_query_node = 0
	app.editor_font_picker_results_owner = 0
	find_set_message(&app.editor_font_picker_query, "")
	if rt != nil { alicorn.invalidate_root(rt, "Scratchpad editor font picker closed") }
}

scratchpad_editor_font_picker_restore_focus_after_frame :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil { return }
	if app.editor_font_picker_open && app.editor_font_picker_focus_pending && app.editor_font_picker_query_node != 0 {
		if alicorn.focus(rt, app.editor_font_picker_query_node) {
			app.editor_font_picker_focus_pending = false
			if text, found := alicorn.text_field_value(rt, app.editor_font_picker_query_node); found {
				_ = alicorn.set_text_selection(rt, app.editor_font_picker_query_node, 0, len(text))
			}
		}
	}
	if !app.editor_font_picker_restore_pending { return }
	app.editor_font_picker_restore_pending = false
	focus := app.editor_font_picker_previous_focus
	app.editor_font_picker_previous_focus = 0
	if focus != 0 {
		if _, found := alicorn.node_info(rt, focus); found { _ = alicorn.focus(rt, focus) }
	}
}

scratchpad_editor_font_picker_text_change :: proc(state: rawptr, rt: ^alicorn.Runtime, change: alicorn.Text_Change) {
	app := cast(^App)state
	if app == nil || rt == nil || !app.editor_font_picker_open || change.node != app.editor_font_picker_query_node || !change.changed { return }
	find_set_message(&app.editor_font_picker_query, change.text)
	app.editor_font_picker_selected = 0
	alicorn.invalidate_root(rt, "Scratchpad editor font picker query changed")
}

scratchpad_editor_font_picker_choose :: proc(app: ^App, rt: ^alicorn.Runtime, catalog_index: int) -> bool {
	if app == nil || rt == nil || catalog_index < 0 || catalog_index >= len(app.editor_font_catalog) { return false }
	family := app.editor_font_catalog[catalog_index]
	if family.unsupported_reason != "" { return false }
	scratchpad_editor_font_picker_close(app, rt, true)
	return scratchpad_editor_font_request(app, rt, family.family, scratchpad_editor_font_size(app))
}

scratchpad_editor_font_picker_choose_default :: proc(app: ^App, rt: ^alicorn.Runtime) -> bool {
	if app == nil || rt == nil { return false }
	scratchpad_editor_font_picker_close(app, rt, true)
	return scratchpad_editor_font_request(app, rt, "", scratchpad_editor_font_size(app))
}

scratchpad_editor_font_picker_move :: proc(app: ^App, rt: ^alicorn.Runtime, delta: int) -> bool {
	if app == nil || rt == nil || !app.editor_font_picker_open { return false }
	results := editor_font_picker_filter(app.editor_font_catalog[:], app.editor_font_picker_query, context.temp_allocator)
	defer delete(results)
	if len(results) > 0 {
		next := app.editor_font_picker_selected+delta
		for next >= 0 && next < len(results) {
			family := app.editor_font_catalog[results[next]]
			if family.unsupported_reason == "" {
				app.editor_font_picker_selected = next
				break
			}
			next += delta
		}
		if app.editor_font_picker_results_owner != 0 {
			_ = alicorn.virtual_list_ensure_visible(rt, app.editor_font_picker_results_owner, app.editor_font_picker_selected, "Scratchpad editor font picker selection visibility")
		}
	}
	alicorn.invalidate_root(rt, "Scratchpad editor font picker selection moved")
	return true
}

scratchpad_editor_font_picker_execute_selected :: proc(app: ^App, rt: ^alicorn.Runtime) -> bool {
	if app == nil || rt == nil || !app.editor_font_picker_open { return false }
	results := editor_font_picker_filter(app.editor_font_catalog[:], app.editor_font_picker_query, context.temp_allocator)
	defer delete(results)
	focused := alicorn.focused_node(rt)
	default_button, default_found := alicorn.node_by_key(rt, alicorn.key_string("scratchpad-editor-font-picker-default"), .Button)
	if default_found && focused == default_button { return scratchpad_editor_font_picker_choose_default(app, rt) }
	for index, catalog_index in results {
		family := app.editor_font_catalog[catalog_index]
		row, found := alicorn.node_by_key(rt, alicorn.key_string(family.family), .Button)
		if found && focused == row {
			app.editor_font_picker_selected = index
			return scratchpad_editor_font_picker_choose(app, rt, catalog_index)
		}
	}
	if app.editor_font_picker_selected < 0 || app.editor_font_picker_selected >= len(results) { return true }
	return scratchpad_editor_font_picker_choose(app, rt, results[app.editor_font_picker_selected])
}

scratchpad_editor_font_picker_build :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime) {
	if app == nil || ui == nil || rt == nil || !app.editor_font_picker_open { return }
	results := editor_font_picker_filter(app.editor_font_catalog[:], app.editor_font_picker_query, alicorn.runtime_scratch_allocator(rt))
	defer delete(results)
	if len(results) == 0 { app.editor_font_picker_selected = 0
	} else {
		app.editor_font_picker_selected = clamp(app.editor_font_picker_selected, 0, len(results)-1)
		if !editor_font_picker_selectable(app.editor_font_catalog[:], results[app.editor_font_picker_selected]) {
			for result_index, index in results {
				if editor_font_picker_selectable(app.editor_font_catalog[:], index) { app.editor_font_picker_selected = result_index; break }
			}
		}
	}
	app.editor_font_picker_overlay_node = alicorn.modal_overlay_begin(ui, alicorn.key_string("scratchpad-editor-font-picker-overlay"), style=alicorn.layout_style(.Column, grow=1, padding=24, align=.Center, justify=.Center, clip=true), backdrop_color=alicorn.Color{0.015, 0.02, 0.03, 0.72})
	viewport := alicorn.viewport_bounds(rt)
	app.editor_font_picker_panel_node = alicorn.surface_begin(ui, alicorn.surface_core_color_role(.Surface), label="scratchpad-editor-font-picker-panel", key=alicorn.key_string("scratchpad-editor-font-picker-panel"), style=alicorn.layout_style(.Column, max_width=min(900, max(viewport.w-48, 1)), height=alicorn.LAYOUT_SIZE_FIT_CONTENT, max_height=min(700, max(viewport.h-48, 1)), padding=16, gap=8, clip=true), material=app.floating_surface_material, physical_height=1)
	alicorn.text(ui, "Choose editor font", style=alicorn.layout_style(.Row, height=28), text_style=alicorn.Text_Style{font_size=20, font_weight=alicorn.FONT_WEIGHT_SEMIBOLD})
	app.editor_font_picker_query_node = alicorn.text_field(ui, app.editor_font_picker_query, key=alicorn.key_string("scratchpad-editor-font-picker-query"), style=alicorn.layout_style(.Row, height=44), text_style=SCRATCHPAD_PROMINENT_INPUT_TEXT_STYLE)
	monospaced_count := 0
	for catalog_index in results {
		if app.editor_font_catalog[catalog_index].monospaced { monospaced_count += 1 }
	}
	proportional_count := len(results)-monospaced_count
	default_label := "Atkinson Hyperlegible Mono · Monospaced · bundled default"
	if app.editor_font_family == "" { default_label = fmt.tprintf("✓  %s", default_label) }
	if alicorn.button(ui, default_label, key=alicorn.key_string("scratchpad-editor-font-picker-default"), style=alicorn.layout_style(.Row, height=EDITOR_FONT_PICKER_ROW_HEIGHT), state=alicorn.Button_State{selected=app.editor_font_family == ""}, variant=.Quiet, text_style=alicorn.Text_Style{overflow=.Ellipsis}, content_style=alicorn.button_content_style(.Start, padding_x=9, padding_y=4)) {
		_ = scratchpad_editor_font_picker_choose_default(app, rt)
	}
	if !app.editor_font_catalog_ready {
		if app.editor_font_catalog_error != "" { alicorn.text(ui, app.editor_font_catalog_error, style=alicorn.layout_style(.Row, height=42), text_style=alicorn.Text_Style{overflow=.Wrap})
		} else { alicorn.text(ui, "Loading system fonts…", style=alicorn.layout_style(.Row, height=24)) }
	} else if len(results) == 0 {
		alicorn.text(ui, "No matching fonts", style=alicorn.layout_style(.Row, height=24))
	} else {
	list := alicorn.virtual_list_begin(ui, len(results), EDITOR_FONT_PICKER_ROW_HEIGHT, key=alicorn.key_string("scratchpad-editor-font-picker-results"), style=alicorn.layout_style(height=alicorn.LAYOUT_SIZE_FIT_CONTENT, max_height=f32(EDITOR_FONT_PICKER_MAX_VISIBLE_ROWS-1)*EDITOR_FONT_PICKER_ROW_HEIGHT, grow=1, clip=true), label="scratchpad-editor-font-picker-results")
		app.editor_font_picker_results_owner = list.scroll.id
		for index in list.first..<list.last {
			catalog_index := results[index]
			family := app.editor_font_catalog[catalog_index]
			category := "Proportional"
			if family.monospaced { category = "Monospaced" }
			label := fmt.tprintf("%s  ·  %s", family.family, category)
			if family.unsupported_reason != "" { label = fmt.tprintf("%s\nUnavailable: %s", label, family.unsupported_reason) }
			is_current := family.family == app.editor_font_family && app.editor_font_family != ""
			if is_current { label = fmt.tprintf("✓  %s", label) }
			if alicorn.button(ui, label, key=alicorn.key_string(family.family), style=alicorn.layout_style(.Row, height=EDITOR_FONT_PICKER_ROW_HEIGHT), state=alicorn.Button_State{selected=index == app.editor_font_picker_selected, disabled=family.unsupported_reason != ""}, variant=.Quiet, text_style=alicorn.Text_Style{overflow=.Wrap}, content_style=alicorn.button_content_style(.Start, padding_x=9, padding_y=4)) {
				app.editor_font_picker_selected = index
				_ = scratchpad_editor_font_picker_choose(app, rt, catalog_index)
			}
		}
		alicorn.virtual_list_end(ui, list)
	}
	alicorn.text(ui, fmt.tprintf("%d monospaced · %d proportional  ·  ↑/↓ navigate  ·  Enter select  ·  Esc close", monospaced_count, proportional_count), style=alicorn.layout_style(.Row, height=20), text_style=alicorn.Text_Style{overflow=.Ellipsis})
	alicorn.surface_end(ui)
	alicorn.modal_overlay_end(ui)
}

scratchpad_editor_font_picker_pointer :: proc(app: ^App, rt: ^alicorn.Runtime, event: alicorn.Pointer_Event, target: alicorn.Node_ID) -> bool {
	if app == nil || rt == nil || !app.editor_font_picker_open { return false }
	if event.kind == .Down && event.button == alicorn.POINTER_BUTTON_PRIMARY && target == app.editor_font_picker_overlay_node {
		panel, found := alicorn.node_info(rt, app.editor_font_picker_panel_node)
		inside := found && event.x >= panel.bounds.x && event.x < panel.bounds.x+panel.bounds.w && event.y >= panel.bounds.y && event.y < panel.bounds.y+panel.bounds.h
		if !inside { scratchpad_editor_font_picker_close(app, rt, true) }
		return true
	}
	return true
}

scratchpad_editor_font_picker_handle_key :: proc(app: ^App, rt: ^alicorn.Runtime, key: host.Application_Key) -> bool {
	if app == nil || rt == nil || !app.editor_font_picker_open { return false }
	#partial switch key {
	case .Escape:
		scratchpad_editor_font_picker_close(app, rt, true)
		return true
	case .Return:
		return scratchpad_editor_font_picker_execute_selected(app, rt)
	case .Up:
		return scratchpad_editor_font_picker_move(app, rt, -1)
	case .Down:
		return scratchpad_editor_font_picker_move(app, rt, 1)
	case .Tab_Next, .Tab_Previous:
		return false
	case:
		// Left/right, deletion, and selection commands belong to native text
		// input while the query owns focus. Unknown app keys must also decline
		// here because application_key returns this modal handler directly.
		return false
	}
}
