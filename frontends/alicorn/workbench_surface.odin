package main

import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"

build_start_screen :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime) {
	if app == nil || ui == nil || rt == nil { return }
	alicorn.container_begin(ui, .Container, label="scratchpad-start-screen", style=alicorn.layout_style(.Column, grow=1, align=.Center, gap=12))
	alicorn.container_begin(ui, .Container, label="scratchpad-start-content", style=alicorn.layout_style(.Column, width=360, padding=28, gap=12), color=COLOR_PANEL)
	alicorn.text(ui, "Scratchpad")
	alicorn.text(ui, "Open a file or choose a workspace to get started.")
	alicorn.container_begin(ui, .Container, label="scratchpad-start-actions", style=alicorn.layout_style(.Row, height=38, gap=8))
	if alicorn.button(ui, "Open File…", key=alicorn.key_string("start-open-file"), style=alicorn.layout_style(.Row, grow=1, height=36)) {
		dispatch_action(app, rt, ACTION_FILE_OPEN)
	}
	if alicorn.button(ui, "Open Folder…", key=alicorn.key_string("start-open-folder"), style=alicorn.layout_style(.Row, grow=1, height=36)) {
		dispatch_action(app, rt, ACTION_WORKSPACE_OPEN)
	}
	alicorn.container_end(ui)
	alicorn.container_end(ui)
	alicorn.container_end(ui)
}

settings_surface_build :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime) {
	if app == nil || ui == nil || rt == nil { return }
	alicorn.modal_overlay_begin(ui, alicorn.key_string("scratchpad-settings-overlay"), style=alicorn.layout_style(.Column, grow=1, align=.Center), backdrop_color=alicorn.Color{0.015, 0.02, 0.03, 0.72})
	alicorn.container_begin(ui, .Container, label="scratchpad-settings", style=alicorn.layout_style(.Column, width=480, height=250, padding=22, gap=12, align=.Start, clip=true), color=COLOR_PANEL)
	alicorn.text(ui, "Settings")
	alicorn.text(ui, "Workspace")
	ignored_change := alicorn.checkbox(
		ui,
		"Show ignored files in the file tree",
		app.show_ignored_files,
		key=alicorn.key_string("settings-show-ignored-files"),
		style=alicorn.layout_style(.Row, height=30),
		disabled=!app.backend.started || !app.backend.state.has_workspace,
	)
	if ignored_change.changed {
		tree_set_show_ignored_files(app, rt, ignored_change.value)
	}
	alicorn.text(ui, "Workspace search continues to honor ignore rules.")
	alicorn.container_begin(ui, .Container, label="scratchpad-settings-actions", style=alicorn.layout_style(.Row, grow=1, align=.End))
	if alicorn.button(ui, "Done", key=alicorn.key_string("settings-done"), style=alicorn.layout_style(.Row, width=88, height=34)) {
		settings_surface_close(app, rt)
	}
	alicorn.container_end(ui)
	alicorn.container_end(ui)
	alicorn.modal_overlay_end(ui)
}

settings_surface_close :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || !app.settings_surface_open { return }
	app.settings_surface_open = false
	alicorn.invalidate_root(rt, "Scratchpad Settings closed")
}

settings_surface_handle_key :: proc(app: ^App, rt: ^alicorn.Runtime, key: host.Application_Key) -> bool {
	if app == nil || !app.settings_surface_open { return false }
	if key == .Escape {
		settings_surface_close(app, rt)
	}
	return true
}
