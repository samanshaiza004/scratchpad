package main

import "core:fmt"
import "core:os"
import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"
import bridge "./bridge"

App :: struct {
	backend:             bridge.Backend,
	waker:               host.Application_Waker,
	workspace_path:      string,
	backend_library:     string,
	error_message:       string,
	smoke:               bool,
	smoke_rendered:      bool,
	smoke_wake_observed: bool,
	smoke_shutdown:      bool,
}

build_app :: proc(
	state: rawptr,
	rt: ^alicorn.Runtime,
	logical_width, logical_height: int,
	dpi_scale: f32,
) -> alicorn.Node_ID {
	app := cast(^App)state
	ui, should_build := alicorn.begin_frame(rt)
	if !should_build { return 0 }
	root := alicorn.container_begin(
		&ui,
		.Root,
		label="scratchpad-alicorn-root",
		style=alicorn.layout_style(.Column, grow=1, padding=28, gap=14, clip=true),
		color=alicorn.Color{0.055, 0.065, 0.09, 1},
	)
	alicorn.text(&ui, "Scratchpad — Alicorn")
	alicorn.text(&ui, "Phase 1 · frontend-neutral Go / Caliber lifecycle")

	card := alicorn.container_begin(
		&ui,
		.Container,
		label="scratchpad-state-card",
		style=alicorn.layout_style(.Column, width=640, padding=18, gap=12, clip=true),
		color=alicorn.Color{0.08, 0.095, 0.13, 1},
	)
	status := "Stopped"
	if app.backend.started { status = "Running" }
	alicorn.text(&ui, fmt.tprintf("Backend: %s", status))
	if app.error_message != "" { alicorn.text(&ui, fmt.tprintf("Status: %s", app.error_message)) }
	if app.backend.started {
		state := app.backend.state
		workspace := "No workspace"
		if state.has_workspace { workspace = state.workspace_root }
		active := "None"
		if state.active != "" { active = state.active }
		alicorn.text(&ui, fmt.tprintf("Workspace: %s", workspace))
		alicorn.text(&ui, fmt.tprintf("Documents: %d", len(state.documents)))
		alicorn.text(&ui, fmt.tprintf("Active: %s", active))
		alicorn.text(&ui, fmt.tprintf("Revision: %d", state.revision))
		if app.smoke && state.revision > 0 { app.smoke_rendered = true }
	} else {
		alicorn.text(&ui, "Workspace: —")
		alicorn.text(&ui, "Documents: —")
		alicorn.text(&ui, "Active: —")
		alicorn.text(&ui, "Revision: —")
	}
	if app.backend.started {
		if alicorn.button(&ui, "Stop backend", key=alicorn.key_string("backend-stop"), style=alicorn.layout_style(.Row, width=180, height=36)) {
			stopped, message := bridge.backend_stop(&app.backend)
			if stopped { app.error_message = "" } else { app.error_message = message }
		}
	} else {
		if alicorn.button(&ui, "Start backend", key=alicorn.key_string("backend-start"), style=alicorn.layout_style(.Row, width=180, height=36)) {
			start_backend(app)
		}
	}
	alicorn.container_end(&ui)
	alicorn.text(&ui, "State is a read-only snapshot. Shirei remains the default frontend.")
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
	return root
}

start_backend :: proc(app: ^App) {
	if app == nil { return }
	loaded, load_error := bridge.backend_load(&app.backend, app.backend_library)
	if !loaded {
		app.error_message = load_error
		return
	}
	started, start_error := bridge.backend_start(
		&app.backend,
		app.workspace_path,
		app.waker.wake,
		app.waker.data,
	)
	if !started { app.error_message = start_error } else { app.error_message = "" }
}

application_start :: proc(state: rawptr, waker: host.Application_Waker) {
	app := cast(^App)state
	app.waker = waker
	start_backend(app)
}

application_wake :: proc(state: rawptr, rt: ^alicorn.Runtime) {
	app := cast(^App)state
	if !app.backend.started { return }
	app.smoke_wake_observed = true
	changed, ok, message := bridge.backend_consume_wake(&app.backend)
	if !ok {
		app.error_message = message
		alicorn.invalidate_root(rt, "Scratchpad backend state read failed")
		return
	}
	if changed { alicorn.invalidate_root(rt, "Scratchpad Caliber state publication") }
}

application_stop :: proc(state: rawptr) {
	app := cast(^App)state
	if app.backend.started {
		stopped, message := bridge.backend_stop(&app.backend)
		app.smoke_shutdown = stopped && !app.backend.started && app.backend.waiter.thread == nil && app.backend.state_leases == 0
		if !stopped { fmt.eprintln("Scratchpad backend shutdown error:", message) }
	} else {
		app.smoke_shutdown = true
	}
}

main :: proc() {
	app: App
	if library, found := os.lookup_env("SCRATCHPAD_BACKEND_LIBRARY", context.allocator); found {
		app.backend_library = library
	}
	if workspace, found := os.lookup_env("SCRATCHPAD_ALICORN_WORKSPACE", context.allocator); found {
		app.workspace_path = workspace
	}
	if smoke, found := os.lookup_env("SCRATCHPAD_ALICORN_SMOKE", context.allocator); found {
		app.smoke = smoke == "1" || smoke == "true"
	}
	host.Run(host.Application{
		state=rawptr(&app),
		title="Scratchpad — Alicorn Phase 1",
		width=900,
		height=540,
		build=build_app,
		on_start=application_start,
		on_wake=application_wake,
		on_stop=application_stop,
	}, app.smoke)
	if app.smoke {
		passed := app.smoke_rendered && app.smoke_wake_observed && app.smoke_shutdown
		fmt.println("alicorn-smoke", "publication_rendered", app.smoke_rendered, "wake_observed", app.smoke_wake_observed, "ordered_shutdown", app.smoke_shutdown)
		if !passed { os.exit(1) }
	}
}
