package main

import "core:fmt"
import "core:strings"
import alicorn "alicorn:runtime"
import gui "alicorn:ui"
import host "alicorn:native/sdl_gpu"
import bridge "./bridge"

WORKSPACE_ADDRESS_ROW_HEIGHT :: f32(28)
WORKSPACE_ADDRESS_RECENT_LIMIT :: 8

Workspace_Address_Row_Kind :: enum {
	Heading,
	Parent,
	Exact,
	Directory,
	Recent,
}

Workspace_Address_Row :: struct {
	kind: Workspace_Address_Row_Kind,
	label: string,
	path: string,
}

workspace_address_open_surface :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil || !app.backend.started || app.shutdown_intent != .None ||
	   app.close_document_id != "" || app.save_as_confirmation_open || app.workspace_mutation_kind != .None ||
	   app.settings_surface_open || app.go_to_line_open {
		return
	}
	for view in app.editor_views {
		if view.preedit_active {
			set_error(app, "Finish or cancel the active text composition before opening the workspace address.")
			alicorn.invalidate_root(rt, "Scratchpad preserved active IME composition while opening workspace address")
			return
		}
	}
	if !app.backend.state.has_workspace {
		request_file_dialog(app, rt, .Open_Folder, "Open Workspace")
		return
	}
	if app.workspace_address_open {
		workspace_address_close_surface(app, rt, true)
		return
	}
	if app.command_palette_open { command_palette_close_surface(app, rt, false) }
	if app.quick_open_open { quick_open_close_surface(app, rt, false) }
	if app.symbol_picker_open { symbol_picker_close_surface(app, rt, false) }
	app.workspace_address_previous_focus = alicorn.focused_node(rt)
	app.workspace_address_open = true
	app.workspace_address_focus_pending = true
	app.workspace_address_restore_pending = false
	app.workspace_address_node = 0
	app.workspace_address_selected_index = -1
	app.workspace_address_confirm_open = false
	find_set_message(&app.workspace_address_query, app.backend.state.workspace_root)
	find_set_message(&app.workspace_address_error, "")
	workspace_address_browse_clear(app)
	workspace_address_request_browse(app)
	alicorn.invalidate_root(rt, "Scratchpad opened the workspace address picker")
}

workspace_address_close_surface :: proc(app: ^App, rt: ^alicorn.Runtime, restore_focus: bool) {
	if app == nil { return }
	if workspace_address_block_composition(app, rt) { return }
	app.workspace_address_open = false
	app.workspace_address_focus_pending = false
	app.workspace_address_restore_pending = restore_focus
	app.workspace_address_node = 0
	app.workspace_address_selected_index = -1
	workspace_address_confirmation_clear(app)
	bridge.workspace_browse_lane_cancel(&app.workspace_browse_lane)
	workspace_address_browse_clear(app)
	find_set_message(&app.workspace_address_error, "")
	if rt != nil { alicorn.invalidate_root(rt, "Scratchpad closed the workspace address picker") }
}

workspace_address_restore_focus_after_frame :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil { return }
	if app.workspace_address_open && app.workspace_address_focus_pending && app.workspace_address_node != 0 {
		if alicorn.focus(rt, app.workspace_address_node) {
			app.workspace_address_focus_pending = false
			if text, found := alicorn.text_field_value(rt, app.workspace_address_node); found {
				_ = alicorn.set_text_selection(rt, app.workspace_address_node, 0, len(text))
			}
		}
	}
	if !app.workspace_address_restore_pending { return }
	app.workspace_address_restore_pending = false
	focus := app.workspace_address_previous_focus
	app.workspace_address_previous_focus = 0
	if focus != 0 {
		if _, found := alicorn.node_info(rt, focus); found && alicorn.focus(rt, focus) { return }
	}
	if app.tree_scroll_owner != 0 { _ = alicorn.focus(rt, app.tree_scroll_owner) }
}

workspace_address_text_change :: proc(state: rawptr, rt: ^alicorn.Runtime, change: alicorn.Text_Change) {
	app := cast(^App)state
	if app == nil || rt == nil || !app.workspace_address_open || change.node != app.workspace_address_node || !change.changed { return }
	if len(change.text) > 32768 {
		find_set_message(&app.workspace_address_error, "Workspace paths are limited to 32 KiB.")
		alicorn.invalidate_root(rt, "Scratchpad rejected an oversized workspace path")
		return
	}
	find_set_message(&app.workspace_address_query, change.text)
	find_set_message(&app.workspace_address_error, "")
	app.workspace_address_selected_index = -1
	app.workspace_address_confirm_open = false
	workspace_address_browse_clear(app)
	workspace_address_request_browse(app)
	alicorn.invalidate_root(rt, "Scratchpad workspace address query changed")
}

workspace_address_request_browse :: proc(app: ^App) {
	if app == nil || !app.workspace_address_open || !app.backend.state.has_workspace { return }
	base := app.backend.state.workspace_root
	generation, accepted := bridge.workspace_browse_lane_request(&app.workspace_browse_lane, app.workspace_address_query, base)
	if !accepted {
		app.workspace_address_loading = false
		find_set_message(&app.workspace_address_error, "The directory suggestions could not be requested.")
		return
	}
	app.workspace_address_generation = generation
	app.workspace_address_loading = true
}

workspace_address_take_completion :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil { return }
	result, found := bridge.workspace_browse_lane_take(&app.workspace_browse_lane)
	if !found { return }
	defer bridge.workspace_browse_lane_result_destroy(&result, context.allocator)
	if !app.workspace_address_open || result.generation != app.workspace_address_generation ||
	   result.query != app.workspace_address_query || result.base_path != app.backend.state.workspace_root {
		return
	}
	app.workspace_address_loading = false
	if result.error != "" {
		find_set_message(&app.workspace_address_error, result.error)
	} else if result.browse_owned {
		workspace_address_browse_clear(app)
		app.workspace_address_browse = result.browse
		app.workspace_address_browse_owned = true
		result.browse = {}
		result.browse_owned = false
		find_set_message(&app.workspace_address_error, "")
	}
	if rt != nil { alicorn.invalidate_root(rt, "Scratchpad workspace directory suggestions completed") }
}

workspace_address_browse_clear :: proc(app: ^App) {
	if app == nil { return }
	if app.workspace_address_browse_owned {
		bridge.workspace_browse_destroy(&app.workspace_address_browse, context.allocator)
	}
	app.workspace_address_browse = {}
	app.workspace_address_browse_owned = false
}

workspace_address_rows :: proc(app: ^App, allocator := context.temp_allocator) -> [dynamic]Workspace_Address_Row {
	rows := make([dynamic]Workspace_Address_Row, 0, allocator=allocator)
	if app == nil { return rows }
	browse := app.workspace_address_browse
	if browse.parent_path != "" {
		append(&rows, Workspace_Address_Row{.Parent, fmt.tprintf("↑  %s", browse.parent_path), browse.parent_path})
	}
	if browse.exact_path != "" && browse.exact_path != app.backend.state.workspace_root {
		append(&rows, Workspace_Address_Row{.Exact, fmt.tprintf("Open this folder  ·  %s", browse.exact_path), browse.exact_path})
	}
	for entry in browse.entries {
		if !entry.dir { continue }
		append(&rows, Workspace_Address_Row{.Directory, fmt.tprintf("▸  %s", entry.name), entry.path})
	}
	if len(app.backend.state.recent_workspaces) > 0 {
		append(&rows, Workspace_Address_Row{.Heading, "Recent Workspaces", ""})
		added := 0
		for path in app.backend.state.recent_workspaces {
			if path == app.backend.state.workspace_root { continue }
			append(&rows, Workspace_Address_Row{.Recent, path, path})
			added += 1
			if added >= WORKSPACE_ADDRESS_RECENT_LIMIT { break }
		}
	}
	return rows
}

workspace_address_suggestions_build :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime) {
	if app == nil || ui == nil || rt == nil { return }
	alicorn.container_begin(ui, .Container, label="workspace-address-suggestions", style=alicorn.layout_style(.Column, grow=1, gap=6, padding=4, clip=true))
	if app.workspace_address_confirm_open {
		gui.text(ui, fmt.tprintf("Switch to %s? This will remove the current pinned references.", app.workspace_address_confirm_path))
		if gui.row(ui, label="workspace-address-confirm-actions", height=36, gap=8) {
			if gui.button(ui, "Switch workspace", key="workspace-address-confirm", height=32, variant=.Primary) {
				workspace_address_confirm_switch(app, rt)
			}
			if gui.button(ui, "Cancel", key="workspace-address-cancel-confirm", height=32, variant=.Quiet) {
				workspace_address_confirmation_clear(app)
				find_set_message(&app.workspace_address_error, "")
				alicorn.invalidate_root(rt, "Scratchpad cancelled workspace switch confirmation")
			}
		}
	}
	if app.workspace_address_browse.directory_path != "" {
		if gui.row(ui, label="workspace-address-heading", height=26, justify=.Space_Between, align=.Center) {
			gui.text(ui, fmt.tprintf("Folders in %s", app.workspace_address_browse.directory_path),
				style=alicorn.layout_style(.Row, grow=1), text_style=alicorn.Text_Style{overflow=.Ellipsis})
			if gui.button(ui, "×", key="workspace-address-close", width=28, height=26, variant=.Quiet) {
				workspace_address_close_surface(app, rt, true)
			}
		}
	}
	if app.workspace_address_loading {
		gui.text(ui, "Finding folders…", style=alicorn.layout_style(.Row, height=22))
	} else if app.workspace_address_error != "" {
		gui.text(ui, app.workspace_address_error, style=alicorn.layout_style(.Row, height=alicorn.LAYOUT_SIZE_FIT_CONTENT), text_style=alicorn.Text_Style{overflow=.Wrap})
	} else {
		rows := workspace_address_rows(app, alicorn.runtime_scratch_allocator(rt))
		defer delete(rows)
		if len(rows) == 0 {
			gui.text(ui, "No matching folders. You can still enter a full path and press Enter.", style=alicorn.layout_style(.Row, height=alicorn.LAYOUT_SIZE_FIT_CONTENT), text_style=alicorn.Text_Style{overflow=.Wrap})
		} else {
			list := alicorn.virtual_list_begin(
				ui,
				len(rows),
				WORKSPACE_ADDRESS_ROW_HEIGHT,
				key=alicorn.key_string("scratchpad-workspace-address-results"),
				style=alicorn.layout_style(.Column, grow=1, clip=true),
				label="Workspace folders and recent workspaces",
			)
			for index := list.first; index < list.last; index += 1 {
				row := rows[index]
				if row.kind == .Heading {
					gui.text(ui, row.label, key=alicorn.key_string("workspace-address-recent-heading"), style=alicorn.layout_style(.Row, height=WORKSPACE_ADDRESS_ROW_HEIGHT, align=.Center))
					continue
				}
				key := fmt.tprintf("workspace-address-option:%v:%s", row.kind, row.path)
				if gui.button(
					ui,
					row.label,
					key=alicorn.key_string(key),
					height=WORKSPACE_ADDRESS_ROW_HEIGHT,
					state=alicorn.Button_State{selected=index == app.workspace_address_selected_index},
					variant=.Quiet,
					text_style=alicorn.Text_Style{overflow=.Ellipsis},
					content_style=alicorn.button_content_style(.Start, padding_x=7, padding_y=3),
				) {
					app.workspace_address_selected_index = index
					workspace_address_request_switch(app, rt, row.path, false)
				}
			}
			alicorn.virtual_list_end(ui, list)
		}
	}
	if app.workspace_address_browse.truncated {
		gui.text(ui, "Folder list capped; type more of a path to narrow the suggestions.", style=alicorn.layout_style(.Row, height=alicorn.LAYOUT_SIZE_FIT_CONTENT), text_style=alicorn.Text_Style{overflow=.Wrap})
	}
	if app.workspace_address_error == "" && !app.workspace_address_confirm_open {
		gui.text(ui, "↑/↓ choose  ·  Enter open  ·  Esc cancel  ·  Browse… for a folder dialog", style=alicorn.layout_style(.Row, height=alicorn.LAYOUT_SIZE_FIT_CONTENT), text_style=alicorn.Text_Style{overflow=.Wrap})
	}
	if gui.button(ui, "Browse…", key="workspace-address-browse-native", height=32, variant=.Quiet) {
		if !workspace_address_block_composition(app, rt) {
			app.workspace_address_focus_pending = true
			request_file_dialog(app, rt, .Open_Folder, "Choose Workspace")
		}
	}
	if gui.button(ui, "Close", key="workspace-address-done", height=30, variant=.Quiet) {
		workspace_address_close_surface(app, rt, true)
	}
	alicorn.container_end(ui)
}

workspace_address_handle_key :: proc(app: ^App, rt: ^alicorn.Runtime, key: host.Application_Key) -> bool {
	if app == nil || rt == nil || !app.workspace_address_open { return false }
	#partial switch key {
	case .Escape:
		if app.workspace_address_confirm_open {
			workspace_address_confirmation_clear(app)
			find_set_message(&app.workspace_address_error, "")
			alicorn.invalidate_root(rt, "Scratchpad cancelled workspace switch confirmation")
		} else {
			workspace_address_close_surface(app, rt, true)
		}
		return true
	case .Up:
		return workspace_address_move_selection(app, -1, rt)
	case .Down:
		return workspace_address_move_selection(app, 1, rt)
	case .Return:
		if app.workspace_address_confirm_open {
			workspace_address_confirm_switch(app, rt)
			return true
		}
		rows := workspace_address_rows(app, context.temp_allocator)
		defer delete(rows)
		if app.workspace_address_selected_index >= 0 && app.workspace_address_selected_index < len(rows) {
			row := rows[app.workspace_address_selected_index]
			if workspace_address_row_selectable(row) {
				workspace_address_request_switch(app, rt, row.path, false)
				return true
			}
		}
		if workspace_address_has_trailing_separator(app.workspace_address_query) {
			find_set_message(&app.workspace_address_error, "Choose a listed folder, or remove the trailing separator to open this directory.")
			alicorn.invalidate_root(rt, "Scratchpad kept workspace address entry in browse mode")
			return true
		}
		workspace_address_request_switch(app, rt, app.workspace_address_query, false)
		return true
	case:
		return false
	}
}

workspace_address_move_selection :: proc(app: ^App, delta: int, rt: ^alicorn.Runtime) -> bool {
	if app == nil || delta == 0 { return false }
	rows := workspace_address_rows(app, context.temp_allocator)
	defer delete(rows)
	if len(rows) == 0 { return true }
	start := app.workspace_address_selected_index
	if start < 0 { start = -1 if delta > 0 else len(rows) }
	for index := start+delta; index >= 0 && index < len(rows); index += delta {
		if !workspace_address_row_selectable(rows[index]) { continue }
		app.workspace_address_selected_index = index
		if rt != nil { alicorn.invalidate_root(rt, "Scratchpad moved workspace address suggestion selection") }
		return true
	}
	return true
}

workspace_address_row_selectable :: proc(row: Workspace_Address_Row) -> bool {
	return row.kind == .Parent || row.kind == .Exact || row.kind == .Directory || row.kind == .Recent
}

workspace_address_has_trailing_separator :: proc(path: string) -> bool {
	if len(path) == 0 { return false }
	last := path[len(path)-1]
	return last == '/' || last == '\\'
}

workspace_address_request_switch :: proc(app: ^App, rt: ^alicorn.Runtime, path: string, confirmed: bool) {
	if app == nil || rt == nil || !app.backend.started || path == "" { return }
	if workspace_address_block_composition(app, rt) { return }
	if app.workspace_address_open { app.workspace_address_focus_pending = true }
	if len(app.editor_edits) > 0 {
		find_set_message(&app.workspace_address_error, "Wait for the current source edit to finish before switching workspaces.")
		alicorn.invalidate_root(rt, "Scratchpad delayed workspace switch behind a pending source edit")
		return
	}
	for view in app.editor_views {
		if view.preedit_active {
			find_set_message(&app.workspace_address_error, "Finish or cancel the active text composition before switching workspaces.")
			alicorn.invalidate_root(rt, "Scratchpad preserved active IME composition during workspace switch")
			return
		}
	}
	if app.pinned.editing {
		pinned_edit_finish(app, rt, false)
		if app.pinned.editing { return }
	}
	response := bridge.backend_command(
		&app.backend,
		"open_workspace",
		path=path,
		discard=confirmed,
		pin_revision=app.workspace_address_confirm_pin_revision if confirmed else 0,
	)
	if !response.ok && response.code == "workspace_switch_requires_confirmation" {
		if !app.workspace_address_open {
			app.workspace_address_previous_focus = alicorn.focused_node(rt)
			find_set_message(&app.workspace_address_query, path)
			app.workspace_address_open = true
			app.workspace_address_selected_index = -1
			workspace_address_request_browse(app)
		}
		workspace_address_confirmation_set(app, path, app.backend.state.pinned_revision)
		app.workspace_address_open = true
		app.workspace_address_focus_pending = true
		app.recent_workspaces_open = false
		if app.workspace_address_confirm_open { find_set_message(&app.workspace_address_error, "") }
		if rt != nil { alicorn.invalidate_root(rt, "Scratchpad requested confirmation before clearing pinned references") }
	} else if !response.ok && response.code == "stale_pinned_ranges" {
		workspace_address_confirmation_clear(app)
		find_set_message(&app.workspace_address_error, "Pinned references changed. Review the current pins, then try switching again.")
		if rt != nil { alicorn.invalidate_root(rt, "Scratchpad rejected stale workspace pin confirmation") }
	} else {
		ok := response.ok
		if !ok { find_set_message(&app.workspace_address_error, response.message) }
		handle_command_result(app, rt, &response)
		if ok {
			workspace_address_confirmation_clear(app)
			workspace_address_close_surface(app, rt, true)
		}
	}
	bridge.backend_command_result_destroy(&response, context.allocator)
}

workspace_address_block_composition :: proc(app: ^App, rt: ^alicorn.Runtime) -> bool {
	if app == nil || rt == nil || !app.workspace_address_open || app.workspace_address_node == 0 { return false }
	interaction, found := alicorn.text_field_interaction(rt, app.workspace_address_node)
	if !found || !interaction.composition_active { return false }
	find_set_message(&app.workspace_address_error, "Finish or cancel the active path composition before choosing or closing the workspace picker.")
	alicorn.invalidate_root(rt, "Scratchpad preserved workspace address IME composition")
	return true
}

workspace_address_confirm_switch :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || !app.workspace_address_confirm_open || app.workspace_address_confirm_path == "" { return }
	workspace_address_request_switch(app, rt, app.workspace_address_confirm_path, true)
}

workspace_address_confirmation_set :: proc(app: ^App, path: string, pin_revision: u64) {
	if app == nil { return }
	workspace_address_confirmation_clear(app)
	path_copy, clone_error := strings.clone(path, context.allocator)
	if clone_error != nil {
		find_set_message(&app.workspace_address_error, "Could not retain the destination path for confirmation.")
		return
	}
	app.workspace_address_confirm_path = path_copy
	app.workspace_address_confirm_pin_revision = pin_revision
	app.workspace_address_confirm_open = app.workspace_address_confirm_path != ""
}

workspace_address_confirmation_clear :: proc(app: ^App) {
	if app == nil { return }
	if app.workspace_address_confirm_path != "" { delete(app.workspace_address_confirm_path, context.allocator) }
	app.workspace_address_confirm_path = ""
	app.workspace_address_confirm_pin_revision = 0
	app.workspace_address_confirm_open = false
}
