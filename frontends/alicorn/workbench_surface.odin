package main

import alicorn "alicorn:runtime"
import bridge "./bridge"

RECENT_WORKSPACE_ROW_HEIGHT :: f32(36)
RECENT_WORKSPACE_MODAL_LIST_HEIGHT :: f32(324)
RECENT_WORKSPACE_START_LIST_HEIGHT :: f32(238)

build_start_screen :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime) {
	if app == nil || ui == nil || rt == nil { return }
	viewport := alicorn.viewport_bounds(rt)
	card_width := min(520, max(viewport.w-48, 200))
	card_max_height := min(640, max(viewport.h-40, 180))
	recent_height := max(min(RECENT_WORKSPACE_START_LIST_HEIGHT, card_max_height-220), RECENT_WORKSPACE_ROW_HEIGHT)
	alicorn.container_begin(ui, .Container, label="scratchpad-start-screen", style=alicorn.layout_style(.Column, grow=1, align=.Center, justify=.Center, padding=20))
	alicorn.container_begin(ui, .Container, label="scratchpad-start-content", style=alicorn.layout_style(.Column, width=card_width, height=alicorn.LAYOUT_SIZE_FIT_CONTENT, max_height=card_max_height, padding=28, gap=14, clip=true), color=alicorn.style_color(ui, .Surface))
	alicorn.text(ui, "Scratchpad")
	alicorn.text(ui, "Files first. Your workspace, your way.")
	alicorn.container_begin(ui, .Container, label="scratchpad-start-actions", style=alicorn.layout_style(.Row, height=42, gap=8, align=.Center))
	if alicorn.button(ui, "Open File…", key=alicorn.key_string("start-open-file"), style=alicorn.layout_style(.Row, grow=1, height=38)) {
		dispatch_action(app, rt, ACTION_FILE_OPEN)
	}
	if alicorn.button(ui, "Open Folder…", key=alicorn.key_string("start-open-folder"), style=alicorn.layout_style(.Row, grow=1, height=38), variant=.Primary) {
		dispatch_action(app, rt, ACTION_WORKSPACE_OPEN)
	}
	alicorn.container_end(ui)
	if alicorn.button(ui, "Command Palette…", key=alicorn.key_string("start-command-palette"), style=alicorn.layout_style(.Row, grow=1, height=36), variant=.Quiet) {
		command_palette_open_surface(app, rt)
	}
	if len(app.backend.state.recent_workspaces) > 0 {
		alicorn.text(ui, "Recent Workspaces")
		list := alicorn.virtual_list_begin(
			ui,
			len(app.backend.state.recent_workspaces),
			RECENT_WORKSPACE_ROW_HEIGHT,
			key=alicorn.key_string("scratchpad-start-recent-workspaces"),
			style=alicorn.layout_style(height=alicorn.LAYOUT_SIZE_FIT_CONTENT, max_height=recent_height, grow=1, clip=true),
			label="scratchpad-start-recent-workspaces",
		)
		for index := list.first; index < list.last; index += 1 {
			path := app.backend.state.recent_workspaces[index]
			if alicorn.button(ui, path, key=alicorn.key_string(path), style=alicorn.layout_style(.Row, height=RECENT_WORKSPACE_ROW_HEIGHT), text_style=alicorn.Text_Style{overflow=.Ellipsis}, variant=.Quiet) {
				recent_workspace_open(app, rt, path)
			}
		}
		alicorn.virtual_list_end(ui, list)
	}
	alicorn.container_end(ui)
	alicorn.container_end(ui)
}
recent_workspace_open :: proc(app: ^App, rt: ^alicorn.Runtime, path: string) {
	if app == nil || rt == nil || !app.backend.started || path == "" { return }
	response := bridge.backend_command(&app.backend, "open_path", path=path)
	handle_command_result(app, rt, &response)
	bridge.backend_command_result_destroy(&response, context.allocator)
	app.recent_workspaces_open = false
	alicorn.invalidate_root(rt, "Scratchpad opened a recent workspace")
}

recent_workspace_clear :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil || !app.backend.started { return }
	response := bridge.backend_command(&app.backend, "clear_recent_workspaces")
	handle_command_result(app, rt, &response)
	bridge.backend_command_result_destroy(&response, context.allocator)
	alicorn.invalidate_root(rt, "Scratchpad cleared recent workspaces")
}

recent_workspaces_surface_build :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime) {
	if app == nil || ui == nil || rt == nil || !app.recent_workspaces_open { return }
	alicorn.modal_overlay_begin(ui, alicorn.key_string("recent-workspaces-overlay"), style=alicorn.layout_style(.Column, grow=1, align=.Center, justify=.Center), backdrop_color=alicorn.Color{0.015, 0.02, 0.03, 0.72})
	alicorn.surface_begin(ui, alicorn.surface_core_color_role(.Surface), key=alicorn.key_string("recent-workspaces-panel"), label="recent-workspaces-panel", style=alicorn.layout_style(.Column, max_width=680, height=alicorn.LAYOUT_SIZE_FIT_CONTENT, max_height=560, padding=18, gap=8, clip=true), shape=scratchpad_surface_shape(app, 7), material=scratchpad_surface_material(app, app.floating_surface_material), physical_height=scratchpad_surface_height(app, 1))
	alicorn.text(ui, "Recent Workspaces")
	if len(app.backend.state.recent_workspaces) == 0 {
		alicorn.text(ui, "No workspaces have been opened yet.")
	} else {
		list := alicorn.virtual_list_begin(
			ui,
			len(app.backend.state.recent_workspaces),
			RECENT_WORKSPACE_ROW_HEIGHT,
			key=alicorn.key_string("recent-workspaces-list"),
			style=alicorn.layout_style(height=alicorn.LAYOUT_SIZE_FIT_CONTENT, max_height=RECENT_WORKSPACE_MODAL_LIST_HEIGHT, grow=1, clip=true),
			label="recent-workspaces-list",
		)
		for index := list.first; index < list.last; index += 1 {
			path := app.backend.state.recent_workspaces[index]
			if alicorn.button(ui, path, key=alicorn.key_string(path), style=alicorn.layout_style(.Row, height=RECENT_WORKSPACE_ROW_HEIGHT), text_style=alicorn.Text_Style{overflow=.Ellipsis}, content_style=alicorn.button_content_style(.Start, padding_x=8), variant=.Quiet) {
				recent_workspace_open(app, rt, path)
			}
		}
		alicorn.virtual_list_end(ui, list)
	}
	alicorn.container_begin(ui, .Container, label="recent-workspaces-actions", style=alicorn.layout_style(.Row, height=38, gap=8, align=.End))
	if alicorn.button(ui, "Clear Recent", key=alicorn.key_string("recent-workspaces-clear"), style=alicorn.layout_style(.Row, width=120, height=34), state=alicorn.Button_State{disabled=len(app.backend.state.recent_workspaces) == 0}, variant=.Quiet) {
		recent_workspace_clear(app, rt)
	}
	if alicorn.button(ui, "Done", key=alicorn.key_string("recent-workspaces-done"), style=alicorn.layout_style(.Row, width=88, height=34)) {
		app.recent_workspaces_open = false
		alicorn.invalidate_root(rt, "Scratchpad closed recent workspaces")
	}
	alicorn.container_end(ui)
	alicorn.surface_end(ui)
	alicorn.modal_overlay_end(ui)
}
