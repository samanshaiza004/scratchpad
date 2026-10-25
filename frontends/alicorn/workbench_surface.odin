package main

import alicorn "alicorn:runtime"
import gui "alicorn:ui"
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
	if gui.column(ui, label="scratchpad-start-screen", grow=1, align=.Center, justify=.Center, padding=20, height=-1) {
		alicorn.container_begin(ui, .Container, label="scratchpad-start-content", style=alicorn.layout_style(.Column, width=card_width, height=alicorn.LAYOUT_SIZE_FIT_CONTENT, max_height=card_max_height, padding=28, gap=14, clip=true), color=alicorn.style_color(ui, .Surface))
		gui.text(ui, "Scratchpad")
		gui.text(ui, "Files first. Your workspace, your way.")
		if gui.row(ui, label="scratchpad-start-actions", height=42, gap=8, align=.Center) {
			if gui.button(ui, "Open File…", key="start-open-file", grow=1, height=38) {
				dispatch_action(app, rt, ACTION_FILE_OPEN)
			}
			if gui.button(ui, "Open Folder…", key="start-open-folder", grow=1, height=38, variant=.Primary) {
				dispatch_action(app, rt, ACTION_WORKSPACE_OPEN)
			}
		}
		if gui.button(ui, "Command Palette…", key="start-command-palette", grow=1, height=36, variant=.Quiet) {
			command_palette_open_surface(app, rt)
		}
		if len(app.backend.state.recent_workspaces) > 0 {
			gui.text(ui, "Recent Workspaces")
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
				if gui.button(ui, path, key=path, height=RECENT_WORKSPACE_ROW_HEIGHT, text_style=alicorn.Text_Style{overflow=.Ellipsis}, variant=.Quiet) {
					recent_workspace_open(app, rt, path)
				}
			}
			alicorn.virtual_list_end(ui, list)
		}
		alicorn.container_end(ui)
	}
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
	gui.text(ui, "Recent Workspaces")
	if len(app.backend.state.recent_workspaces) == 0 {
		gui.text(ui, "No workspaces have been opened yet.")
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
			if gui.button(ui, path, key=path, height=RECENT_WORKSPACE_ROW_HEIGHT, text_style=alicorn.Text_Style{overflow=.Ellipsis}, content_style=alicorn.button_content_style(.Start, padding_x=8), variant=.Quiet) {
				recent_workspace_open(app, rt, path)
			}
		}
		alicorn.virtual_list_end(ui, list)
	}
	if gui.row(ui, label="recent-workspaces-actions", height=38, gap=8, align=.End) {
		if gui.button(ui, "Clear Recent", key="recent-workspaces-clear", width=120, height=34, state=alicorn.Button_State{disabled=len(app.backend.state.recent_workspaces) == 0}, variant=.Quiet) {
			recent_workspace_clear(app, rt)
		}
		if gui.button(ui, "Done", key="recent-workspaces-done", width=88, height=34) {
			app.recent_workspaces_open = false
			alicorn.invalidate_root(rt, "Scratchpad closed recent workspaces")
		}
	}
	alicorn.surface_end(ui)
	alicorn.modal_overlay_end(ui)
}
