package main

// app_host.odin owns Scratchpad's host-facing boundary. The application
// callback set, the description entry points, and the host-service vocabulary
// are declared here exactly once; the two run paths below are renderer
// adapters only.
//
//   * sdl-gpu: native/sdl_gpu host.Run, the reference renderer. It keeps the
//     exact Application it has always built.
//   * webgpu: alicorn:ui/webgpu.run, the hosted SDL3/WebGPU host. It receives
//     the same callbacks through the hosted run description.
//
// Nothing in this file adds behavior. Every field is a 1:1 mapping; the
// mapping table lives in docs/frontends/alicorn/WEBGPU-RENDERER.md.

import "core:os"
import "core:strings"
import alicorn "alicorn:runtime"
import gui "alicorn:ui"
import webgpu "alicorn:ui/webgpu"
import host "alicorn:native/sdl_gpu"

SCRATCHPAD_RENDERER_ENV :: "SCRATCHPAD_RENDERER"

Scratchpad_Renderer :: enum {
	SDL_GPU,
	WebGPU,
}

// Scratchpad_Services is the renderer-neutral host capability set. The native
// host publishes host.Application_Services; the hosted host publishes
// gui.UI_Host_Services. Both adapters translate into this type so the
// application sees one service vocabulary.
Scratchpad_Services :: struct {
	windows:   alicorn.Hosted_Window_Service,
	dialogs:   alicorn.Hosted_Dialog_Service,
	quit:      alicorn.Hosted_Quit_Service,
	clipboard: alicorn.Clipboard_Service,
	scheduler: alicorn.Application_Scheduler,
	file_drag: alicorn.File_Drag_Service,
}

// Scratchpad_Application is the single application description shared by both
// hosts. prepare/describe/after_frame split the reference build callback into
// the three phases the hosted renderer needs:
//
//   prepare      runs before the description and may decline the frame.
//   describe     records the retained tree; the caller owns the open frame.
//   after_frame  applies post-layout state (focus, scroll restore, deferred
//                actions). Both hosts call it after end_frame of the same
//                description pass, before that frame is presented.
Scratchpad_Application :: struct {
	title:              string,
	width, height:      int,
	menus:              []alicorn.Menu,
	menu_presentation:  alicorn.Menu_Presentation,
	window_decorations: alicorn.Window_Decoration_Mode,
	window_chrome_height:    f32,
	window_chrome_metrics:   alicorn.Window_Chrome_Metrics_Proc,
	window_chrome_layout:    alicorn.Window_Chrome_Layout_Proc,
	window_chrome_appearance: alicorn.Window_Chrome_Appearance_Proc,
	prepare:     proc(app: ^App, rt: ^alicorn.Runtime) -> bool,
	describe:    proc(app: ^App, rt: ^alicorn.Runtime, ui: ^alicorn.UI, logical_width, logical_height: int, dpi_scale: f32) -> alicorn.Node_ID,
	after_frame: proc(app: ^App, rt: ^alicorn.Runtime),

	on_initialize:      proc(state: rawptr, rt: ^alicorn.Runtime),
	on_key:             proc(state: rawptr, rt: ^alicorn.Runtime, key: alicorn.Application_Key) -> bool,
	on_text_change:     proc(state: rawptr, rt: ^alicorn.Runtime, change: alicorn.Text_Change),
	on_text_input:      proc(state: rawptr, rt: ^alicorn.Runtime, owner: alicorn.Node_ID, event: alicorn.Application_Text_Input_Event),
	on_text_key:        proc(state: rawptr, rt: ^alicorn.Runtime, owner: alicorn.Node_ID, event: alicorn.Application_Text_Key_Event) -> bool,
	on_pointer:         proc(state: rawptr, rt: ^alicorn.Runtime, event: alicorn.Pointer_Event, target: alicorn.Node_ID),
	on_drag:            proc(state: rawptr, rt: ^alicorn.Runtime, event: alicorn.Drag_Event),
	on_scroll_capture:  proc(state: rawptr, rt: ^alicorn.Runtime, event: alicorn.Scroll_Event, target: alicorn.Node_ID) -> bool,
	on_scroll:          proc(state: rawptr, rt: ^alicorn.Runtime, event: alicorn.Scroll_Event),
	on_services:        proc(state: rawptr, services: Scratchpad_Services),
	on_start:           proc(state: rawptr, waker: gui.Application_Waker),
	on_wake:            proc(state: rawptr, rt: ^alicorn.Runtime),
	on_scheduled_wake:  proc(state: rawptr, rt: ^alicorn.Runtime, class: alicorn.Scheduled_Wake_Class),
	on_close_requested: proc(state: rawptr, rt: ^alicorn.Runtime) -> alicorn.Hosted_Close_Result,
	on_dialog:          proc(state: rawptr, rt: ^alicorn.Runtime, result: ^alicorn.File_Dialog_Result),
	on_stop:            proc(state: rawptr),
	on_menu_command:    proc(state: rawptr, rt: ^alicorn.Runtime, command: alicorn.Action_ID),
	on_file_drop:       proc(state: rawptr, rt: ^alicorn.Runtime, path: string),
	on_tick:            proc(state: rawptr, rt: ^alicorn.Runtime),
}

scratchpad_renderer :: proc() -> Scratchpad_Renderer {
	raw := os.get_env(SCRATCHPAD_RENDERER_ENV, context.temp_allocator)
	for argument in os.args {
		if strings.has_prefix(argument, "--renderer=") {
			raw = argument[len("--renderer="):]
		}
	}
	switch strings.to_lower(raw, context.temp_allocator) {
	case "webgpu", "web-gpu", "gpu":
		return .WebGPU
	case "", "sdl-gpu", "sdl_gpu", "sdlgpu", "native":
		return .SDL_GPU
	}
	// Unknown values keep the reference renderer so a typo never changes which
	// renderer a developer is validating by accident.
	return .SDL_GPU
}

// scratchpad_application is the one application description. Adding a host
// callback means adding it here and mapping it in both adapters below.
scratchpad_application :: proc(app: ^App) -> Scratchpad_Application {
	window_decorations := alicorn.Window_Decoration_Mode.System
	when ODIN_OS == .Windows {
		window_decorations = .Integrated_Title_Bar
	}
	window_chrome_height: f32
	window_chrome_metrics: alicorn.Window_Chrome_Metrics_Proc
	window_chrome_layout: alicorn.Window_Chrome_Layout_Proc
	when ODIN_OS == .Darwin {
		window_decorations = .Content_Title_Bar
		window_chrome_height = SCRATCHPAD_CONTENT_TITLEBAR_HEIGHT
		window_chrome_metrics = scratchpad_content_titlebar_metrics
		window_chrome_layout = scratchpad_content_titlebar_layout
	}
	when ODIN_OS == .Windows {
		window_chrome_metrics = scratchpad_content_titlebar_metrics
		window_chrome_layout = scratchpad_content_titlebar_layout
	}
	window_chrome_appearance: alicorn.Window_Chrome_Appearance_Proc
	menu_presentation := alicorn.Menu_Presentation.Labels
	when ODIN_OS == .Windows {
		window_chrome_appearance = scratchpad_window_chrome_appearance
		menu_presentation = .Hidden
	}
	return Scratchpad_Application{
		title="Scratchpad",
		width=1200,
		height=760,
		menus=scratchpad_native_menus(app.menus[:]),
		menu_presentation=menu_presentation,
		window_decorations=window_decorations,
		window_chrome_height=window_chrome_height,
		window_chrome_metrics=window_chrome_metrics,
		window_chrome_layout=window_chrome_layout,
		window_chrome_appearance=window_chrome_appearance,
		prepare=scratchpad_build_prepare,
		describe=scratchpad_build_describe,
		after_frame=scratchpad_build_after_frame,
		on_initialize=scratchpad_application_initialize,
		on_key=application_key,
		on_text_change=command_palette_text_change,
		on_text_input=editor_text_input,
		on_text_key=editor_text_key,
		on_pointer=application_pointer,
		on_drag=application_drag,
		on_scroll_capture=semantic_zoom_scroll_capture,
		on_services=application_services,
		on_start=application_start,
		on_wake=application_wake,
		on_scheduled_wake=application_scheduled_wake,
		on_close_requested=application_close_requested,
		on_dialog=application_dialog,
		on_stop=application_stop,
		on_menu_command=application_menu_command,
	}
}

// run_scratchpad_application selects the renderer host. Both paths receive the
// same Scratchpad_Application; smoke mode is forwarded unchanged.
run_scratchpad_application :: proc(app: ^App) {
	scratchpad_application_spec = scratchpad_application(app)
	if scratchpad_renderer() == .WebGPU {
		run_scratchpad_webgpu(app)
	} else {
		run_scratchpad_sdl_gpu(app)
	}
}

@(private)
scratchpad_application_spec: Scratchpad_Application

// ---- Reference SDL_GPU path ------------------------------------------------

run_scratchpad_sdl_gpu :: proc(app: ^App) {
	// The native host passes its borrowed worker waker straight through; the
	// hosted adapter wraps the same shape for its own wake transport.
	start :: proc(data: rawptr, waker: host.Application_Waker) {
		if scratchpad_application_spec.on_start != nil {
			scratchpad_application_spec.on_start(data, gui.Application_Waker{data=waker.data, wake=waker.wake})
		}
	}
	services :: proc(data: rawptr, value: host.Application_Services) {
		if scratchpad_application_spec.on_services != nil {
			scratchpad_application_spec.on_services(data, scratchpad_services_from_native(value))
		}
	}
	host.Run(host.Application{
		state=rawptr(app),
		title=scratchpad_application_spec.title,
		width=scratchpad_application_spec.width,
		height=scratchpad_application_spec.height,
		menus=scratchpad_application_spec.menus,
		menu_presentation=host.Application_Menu_Presentation(scratchpad_application_spec.menu_presentation),
		window_decorations=host.Window_Decoration_Mode(scratchpad_application_spec.window_decorations),
		window_chrome_height=scratchpad_application_spec.window_chrome_height,
		window_chrome_metrics=scratchpad_application_spec.window_chrome_metrics,
		window_chrome_layout=scratchpad_application_spec.window_chrome_layout,
		window_chrome_appearance=scratchpad_application_spec.window_chrome_appearance,
		on_initialize=scratchpad_application_spec.on_initialize,
		build=build_app,
		on_key=scratchpad_application_spec.on_key,
		on_pointer=scratchpad_application_spec.on_pointer,
		on_scroll_capture=scratchpad_application_spec.on_scroll_capture,
		on_drag=scratchpad_application_spec.on_drag,
		on_text_key=scratchpad_application_spec.on_text_key,
		on_text_input=scratchpad_application_spec.on_text_input,
		on_text_change=scratchpad_application_spec.on_text_change,
		on_services=services,
		on_start=start,
		on_close_requested=scratchpad_application_spec.on_close_requested,
		on_dialog=scratchpad_application_spec.on_dialog,
		on_wake=scratchpad_application_spec.on_wake,
		on_scheduled_wake=scratchpad_application_spec.on_scheduled_wake,
		on_stop=scratchpad_application_spec.on_stop,
		on_menu_command=scratchpad_application_spec.on_menu_command,
		on_file_drop=scratchpad_application_spec.on_file_drop,
		on_tick=scratchpad_application_spec.on_tick,
	}, app.smoke)
}

// scratchpad_services_from_native translates the reference host service set.
// The window service is re-shaped once so every window request still reaches
// native/sdl_gpu through the hosted description vocabulary.
scratchpad_services_from_native :: proc(value: host.Application_Services) -> Scratchpad_Services {
	scratchpad_native_windows.service = value.windows
	windows := alicorn.Hosted_Window_Service{
		data=rawptr(&scratchpad_native_windows),
		open=native_window_service_open,
		close=native_window_service_close,
		set_always_on_top=native_window_service_set_always_on_top,
		set_title=native_window_service_set_title,
	}
	if value.windows.open == nil { windows = {} }
	return Scratchpad_Services{
		windows=windows,
		dialogs=value.dialogs,
		quit=value.quit,
		clipboard=value.clipboard,
		scheduler=value.scheduler,
		file_drag=value.file_drag,
	}
}

// ---- Hosted SDL3/WebGPU path ----------------------------------------------

run_scratchpad_webgpu :: proc(app: ^App) {
	spec := scratchpad_application(app)
	initialize :: proc(app: ^App, rt: ^alicorn.Runtime) {
		if scratchpad_application_spec.on_initialize != nil { scratchpad_application_spec.on_initialize(rawptr(app), rt) }
	}
	start :: proc(app: ^App, waker: gui.Application_Waker) {
		if scratchpad_application_spec.on_start != nil { scratchpad_application_spec.on_start(rawptr(app), waker) }
	}
	wake :: proc(app: ^App, ctx: gui.Application_Context) {
		if scratchpad_application_spec.on_wake != nil {
			scratchpad_application_spec.on_wake(rawptr(app), cast(^alicorn.Runtime)ctx)
		}
	}
	services :: proc(app: ^App, value: gui.UI_Host_Services) {
		if scratchpad_application_spec.on_services != nil { scratchpad_application_spec.on_services(rawptr(app), scratchpad_services_from_hosted(value)) }
	}
	stop :: proc(app: ^App) {
		if scratchpad_application_spec.on_stop != nil { scratchpad_application_spec.on_stop(rawptr(app)) }
	}
	after_frame :: proc(app: ^App, rt: ^alicorn.Runtime) {
		if scratchpad_application_spec.after_frame != nil { scratchpad_application_spec.after_frame(app, rt) }
	}
	key :: proc(app: ^App, rt: ^alicorn.Runtime, code: alicorn.Application_Key) -> bool {
		return scratchpad_application_spec.on_key != nil && scratchpad_application_spec.on_key(rawptr(app), rt, code)
	}
	text_change :: proc(app: ^App, rt: ^alicorn.Runtime, change: alicorn.Text_Change) {
		if scratchpad_application_spec.on_text_change != nil { scratchpad_application_spec.on_text_change(rawptr(app), rt, change) }
	}
	text_key :: proc(app: ^App, rt: ^alicorn.Runtime, owner: alicorn.Node_ID, event: alicorn.Application_Text_Key_Event) -> bool {
		return scratchpad_application_spec.on_text_key != nil && scratchpad_application_spec.on_text_key(rawptr(app), rt, owner, event)
	}
	pointer :: proc(app: ^App, rt: ^alicorn.Runtime, event: alicorn.Pointer_Event, target: alicorn.Node_ID) {
		if scratchpad_application_spec.on_pointer != nil { scratchpad_application_spec.on_pointer(rawptr(app), rt, event, target) }
	}
	drag :: proc(app: ^App, rt: ^alicorn.Runtime, event: alicorn.Drag_Event) {
		if scratchpad_application_spec.on_drag != nil { scratchpad_application_spec.on_drag(rawptr(app), rt, event) }
	}
	scroll_capture :: proc(app: ^App, rt: ^alicorn.Runtime, event: alicorn.Scroll_Event, target: alicorn.Node_ID) -> bool {
		return scratchpad_application_spec.on_scroll_capture != nil && scratchpad_application_spec.on_scroll_capture(rawptr(app), rt, event, target)
	}
	scroll :: proc(app: ^App, rt: ^alicorn.Runtime, event: alicorn.Scroll_Event) {
		if scratchpad_application_spec.on_scroll != nil { scratchpad_application_spec.on_scroll(rawptr(app), rt, event) }
	}
	text_input :: proc(app: ^App, rt: ^alicorn.Runtime, owner: alicorn.Node_ID, event: alicorn.Hosted_Text_Input_Event) {
		if scratchpad_application_spec.on_text_input == nil { return }
		scratchpad_application_spec.on_text_input(rawptr(app), rt, owner, alicorn.Application_Text_Input_Event{
			kind=alicorn.Application_Text_Input_Event_Kind(event.kind),
			text=event.text,
			selection_start_byte=event.selection_start_byte,
			selection_end_byte=event.selection_end_byte,
		})
	}
	scheduled_wake :: proc(app: ^App, rt: ^alicorn.Runtime, class: alicorn.Scheduled_Wake_Class) {
		if scratchpad_application_spec.on_scheduled_wake != nil { scratchpad_application_spec.on_scheduled_wake(rawptr(app), rt, class) }
	}
	file_drop :: proc(app: ^App, rt: ^alicorn.Runtime, path: string) {
		if scratchpad_application_spec.on_file_drop != nil { scratchpad_application_spec.on_file_drop(rawptr(app), rt, path) }
	}
	tick :: proc(app: ^App, rt: ^alicorn.Runtime) {
		if scratchpad_application_spec.on_tick != nil { scratchpad_application_spec.on_tick(rawptr(app), rt) }
	}
	menu_command :: proc(app: ^App, rt: ^alicorn.Runtime, command: alicorn.Action_ID) {
		if scratchpad_application_spec.on_menu_command != nil { scratchpad_application_spec.on_menu_command(rawptr(app), rt, command) }
	}
	close_requested :: proc(app: ^App, rt: ^alicorn.Runtime) -> alicorn.Hosted_Close_Result {
		if scratchpad_application_spec.on_close_requested != nil { return scratchpad_application_spec.on_close_requested(rawptr(app), rt) }
		return .Allow
	}
	dialog :: proc(app: ^App, rt: ^alicorn.Runtime, result: ^alicorn.File_Dialog_Result) {
		if scratchpad_application_spec.on_dialog != nil { scratchpad_application_spec.on_dialog(rawptr(app), rt, result) }
	}
	chrome_metrics :: proc(state: rawptr, rt: ^alicorn.Runtime, metrics: alicorn.Window_Chrome_Metrics) {
		if scratchpad_application_spec.window_chrome_metrics != nil {
			scratchpad_application_spec.window_chrome_metrics(state, rt, metrics)
		}
	}
	chrome_layout :: proc(state: rawptr, rt: ^alicorn.Runtime) -> alicorn.Window_Chrome_Layout {
		if scratchpad_application_spec.window_chrome_layout != nil {
			return scratchpad_application_spec.window_chrome_layout(state, rt)
		}
		return {}
	}
	chrome_appearance :: proc(state: rawptr, rt: ^alicorn.Runtime) -> alicorn.Window_Chrome_Appearance {
		if scratchpad_application_spec.window_chrome_appearance != nil {
			return scratchpad_application_spec.window_chrome_appearance(state, rt)
		}
		return {}
	}
	webgpu.run(app,
		hosted_render,
		title=scratchpad_application_spec.title,
		width=scratchpad_application_spec.width,
		height=scratchpad_application_spec.height,
		on_initialize=initialize,
		on_key=key,
		on_text_change=text_change,
		on_text_key=text_key,
		on_pointer=pointer,
		on_drag=drag,
		on_scroll_capture=scroll_capture,
		on_scroll=scroll,
		on_text_input=text_input,
		on_services=services,
		on_start=start,
		on_wake=wake,
		on_scheduled_wake=scheduled_wake,
		on_file_drop=file_drop,
		on_tick=tick,
		on_menu_command=menu_command,
		on_close_requested=close_requested,
		on_dialog=dialog,
		on_stop=stop,
		on_after_frame=after_frame,
		smoke=app.smoke,
		menus=scratchpad_application_spec.menus,
		menu_presentation=scratchpad_application_spec.menu_presentation,
		window_decorations=scratchpad_application_spec.window_decorations,
		window_chrome_height=scratchpad_application_spec.window_chrome_height,
		window_chrome_metrics=chrome_metrics,
		window_chrome_layout=chrome_layout,
		window_chrome_appearance=chrome_appearance,
		interaction_update_policy=.Explicit,
	)
}

// hosted_render adapts the hosted renderer's single callback to the shared
// three-phase application description. The hosted runtime opens the frame but
// adds no root container: the application owns the root, so describe opens it
// exactly like the reference host's build contract. Post-layout work runs
// through the hosted `on_after_frame` hook after end_frame of the same pass.
hosted_render :: proc(app: ^App, ctx: ^gui.UI) {
	if app == nil || ctx == nil || ctx.runtime == nil { return }
	rt := ctx.runtime
	if scratchpad_application_spec.prepare != nil && !scratchpad_application_spec.prepare(app, rt) { return }
	logical_width := int(ctx.runtime.viewport.w)
	logical_height := int(ctx.runtime.viewport.h)
	dpi_scale := ctx.runtime.presentation_scale_x
	if dpi_scale <= 0 { dpi_scale = 1 }
	_ = scratchpad_application_spec.describe(app, rt, ctx, logical_width, logical_height, dpi_scale)
}

scratchpad_services_from_hosted :: proc(value: gui.UI_Host_Services) -> Scratchpad_Services {
	return Scratchpad_Services{
		windows=value.windows,
		dialogs=value.dialogs,
		quit=value.quit,
		clipboard=value.clipboard_text,
		scheduler=value.scheduler,
		file_drag=value.file_drag,
	}
}

// ---- Native secondary-window bridge ---------------------------------------
//
// The application describes secondary windows with the hosted vocabulary so
// the floating editor is written once. native/sdl_gpu still expects a native
// Application, so this bridge mirrors Alicorn's own ui.run adapter: it wraps
// the hosted config in a native Application whose build opens the frame the
// hosted render callback expects.

@(private)
Native_Window_Service :: struct {
	service: host.Application_Window_Service,
}

@(private)
scratchpad_native_windows: Native_Window_Service

@(private)
Native_Window_Bridge :: struct {
	config:         alicorn.Hosted_Runtime_Config,
	on_open_failed: alicorn.Hosted_Window_Open_Failed_Proc,
	// windows is the child's own hosted-shape view of the host-provided
	// secondary-window service. It must not alias the primary window's global
	// wrapper.
	windows: Native_Window_Service,
}

@(private)
native_window_build :: proc(
	data: rawptr,
	rt: ^alicorn.Runtime,
	logical_width, logical_height: int,
	dpi_scale: f32,
) -> alicorn.Node_ID {
	bridge := cast(^Native_Window_Bridge)data
	if bridge == nil || bridge.config.render == nil { return 0 }
	ui, should_build := alicorn.begin_frame(rt)
	if !should_build { return 0 }
	root := alicorn.container_begin(
		&ui,
		.Root,
		label="ui-root",
		key="alicorn.ui.root",
		style=alicorn.layout_style(.Column, grow=1),
	)
	if root != 0 {
		bridge.config.render(bridge.config.state, &ui, logical_width, logical_height, dpi_scale)
		alicorn.container_end(&ui)
	}
	alicorn.end_frame(&ui)
	return root
}

@(private)
native_window_initialize :: proc(data: rawptr, rt: ^alicorn.Runtime) {
	if bridge := cast(^Native_Window_Bridge)data; bridge != nil && bridge.config.on_initialize != nil {
		bridge.config.on_initialize(bridge.config.state, rt)
	}
}

@(private)
native_window_start :: proc(data: rawptr, _waker: host.Application_Waker) {
	// The reference host owns its wake transport. The hosted child callback
	// receives an empty waker, matching Alicorn's own native window bridge.
	if bridge := cast(^Native_Window_Bridge)data; bridge != nil && bridge.config.on_start != nil {
		bridge.config.on_start(bridge.config.state, {})
	}
}

@(private)
native_window_wake :: proc(data: rawptr, rt: ^alicorn.Runtime) {
	if bridge := cast(^Native_Window_Bridge)data; bridge != nil && bridge.config.on_wake != nil {
		bridge.config.on_wake(bridge.config.state, rt)
	}
}

@(private)
native_window_scheduled_wake :: proc(data: rawptr, rt: ^alicorn.Runtime, class: alicorn.Scheduled_Wake_Class) {
	if bridge := cast(^Native_Window_Bridge)data; bridge != nil && bridge.config.on_scheduled_wake != nil {
		bridge.config.on_scheduled_wake(bridge.config.state, rt, class)
	}
}

@(private)
native_window_stop :: proc(data: rawptr) {
	bridge := cast(^Native_Window_Bridge)data
	if bridge == nil { return }
	if bridge.config.on_stop != nil { bridge.config.on_stop(bridge.config.state) }
	free(bridge)
}

@(private)
native_window_key :: proc(data: rawptr, rt: ^alicorn.Runtime, key: alicorn.Application_Key) -> bool {
	bridge := cast(^Native_Window_Bridge)data
	if bridge == nil || bridge.config.on_key == nil { return false }
	return bridge.config.on_key(
		bridge.config.state,
		rt,
		alicorn.focused_node(rt),
		alicorn.Hosted_Key_Event{key_code=u32(key), pressed=true},
	)
}

@(private)
native_window_text_change :: proc(data: rawptr, rt: ^alicorn.Runtime, change: alicorn.Text_Change) {
	if bridge := cast(^Native_Window_Bridge)data; bridge != nil && bridge.config.on_text_change != nil {
		bridge.config.on_text_change(bridge.config.state, rt, change)
	}
}

@(private)
native_window_text_key :: proc(
	data: rawptr,
	rt: ^alicorn.Runtime,
	owner: alicorn.Node_ID,
	event: alicorn.Application_Text_Key_Event,
) -> bool {
	bridge := cast(^Native_Window_Bridge)data
	return bridge != nil && bridge.config.on_text_key != nil &&
		bridge.config.on_text_key(bridge.config.state, rt, owner, event)
}

@(private)
native_window_pointer :: proc(data: rawptr, rt: ^alicorn.Runtime, event: alicorn.Pointer_Event, target: alicorn.Node_ID) {
	if bridge := cast(^Native_Window_Bridge)data; bridge != nil && bridge.config.on_pointer != nil {
		bridge.config.on_pointer(bridge.config.state, rt, event, target)
	}
}

@(private)
native_window_drag :: proc(data: rawptr, rt: ^alicorn.Runtime, event: alicorn.Drag_Event) {
	if bridge := cast(^Native_Window_Bridge)data; bridge != nil && bridge.config.on_drag != nil {
		bridge.config.on_drag(bridge.config.state, rt, event)
	}
}

@(private)
native_window_scroll_capture :: proc(
	data: rawptr,
	rt: ^alicorn.Runtime,
	event: alicorn.Scroll_Event,
	target: alicorn.Node_ID,
) -> bool {
	bridge := cast(^Native_Window_Bridge)data
	return bridge != nil && bridge.config.on_scroll_capture != nil &&
		bridge.config.on_scroll_capture(bridge.config.state, rt, event, target)
}

@(private)
native_window_scroll :: proc(data: rawptr, rt: ^alicorn.Runtime, event: alicorn.Scroll_Event) {
	if bridge := cast(^Native_Window_Bridge)data; bridge != nil && bridge.config.on_scroll != nil {
		bridge.config.on_scroll(bridge.config.state, rt, event)
	}
}

@(private)
native_window_text_input :: proc(
	data: rawptr,
	rt: ^alicorn.Runtime,
	owner: alicorn.Node_ID,
	event: alicorn.Application_Text_Input_Event,
) {
	if bridge := cast(^Native_Window_Bridge)data; bridge != nil && bridge.config.on_text_input != nil {
		bridge.config.on_text_input(bridge.config.state, rt, owner, alicorn.Hosted_Text_Input_Event{
			kind=alicorn.Hosted_Text_Input_Kind(event.kind),
			text=event.text,
			selection_start_byte=event.selection_start_byte,
			selection_end_byte=event.selection_end_byte,
		})
	}
}

@(private)
native_window_services :: proc(data: rawptr, value: host.Application_Services) {
	bridge := cast(^Native_Window_Bridge)data
	if bridge == nil { return }
	bridge.windows.service = value.windows
	windows := alicorn.Hosted_Window_Service{
		data=rawptr(&bridge.windows),
		open=native_window_service_open,
		close=native_window_service_close,
		set_always_on_top=native_window_service_set_always_on_top,
		set_title=native_window_service_set_title,
	}
	if value.windows.open == nil { windows = {} }
	if bridge.config.on_host_services == nil { return }
	bridge.config.on_host_services(bridge.config.state, alicorn.Hosted_Host_Services{
		windows=windows,
		dialogs=value.dialogs,
		quit=value.quit,
		clipboard=value.clipboard,
		scheduler=value.scheduler,
	})
}

@(private)
native_window_menu_command :: proc(data: rawptr, rt: ^alicorn.Runtime, command: alicorn.Action_ID) {
	if bridge := cast(^Native_Window_Bridge)data; bridge != nil && bridge.config.on_menu_command != nil {
		bridge.config.on_menu_command(bridge.config.state, rt, command)
	}
}

@(private)
native_window_close_requested :: proc(data: rawptr, rt: ^alicorn.Runtime) -> alicorn.Hosted_Close_Result {
	bridge := cast(^Native_Window_Bridge)data
	if bridge != nil && bridge.config.on_close_requested != nil {
		return bridge.config.on_close_requested(bridge.config.state, rt)
	}
	return .Allow
}

@(private)
native_window_dialog :: proc(data: rawptr, rt: ^alicorn.Runtime, result: ^alicorn.File_Dialog_Result) {
	if bridge := cast(^Native_Window_Bridge)data; bridge != nil && bridge.config.on_dialog != nil {
		bridge.config.on_dialog(bridge.config.state, rt, result)
	}
}

@(private)
native_window_file_drop :: proc(data: rawptr, rt: ^alicorn.Runtime, path: string) {
	if bridge := cast(^Native_Window_Bridge)data; bridge != nil && bridge.config.on_file_drop != nil {
		bridge.config.on_file_drop(bridge.config.state, rt, path)
	}
}

@(private)
native_window_tick :: proc(data: rawptr, rt: ^alicorn.Runtime) {
	if bridge := cast(^Native_Window_Bridge)data; bridge != nil && bridge.config.on_tick != nil {
		bridge.config.on_tick(bridge.config.state, rt)
	}
}

@(private)
native_window_chrome_metrics :: proc(data: rawptr, rt: ^alicorn.Runtime, metrics: alicorn.Window_Chrome_Metrics) {
	if bridge := cast(^Native_Window_Bridge)data; bridge != nil && bridge.config.window_chrome_metrics != nil {
		bridge.config.window_chrome_metrics(bridge.config.state, rt, metrics)
	}
}

@(private)
native_window_chrome_layout :: proc(data: rawptr, rt: ^alicorn.Runtime) -> alicorn.Window_Chrome_Layout {
	if bridge := cast(^Native_Window_Bridge)data; bridge != nil && bridge.config.window_chrome_layout != nil {
		return bridge.config.window_chrome_layout(bridge.config.state, rt)
	}
	return {}
}

@(private)
native_window_chrome_appearance :: proc(data: rawptr, rt: ^alicorn.Runtime) -> alicorn.Window_Chrome_Appearance {
	if bridge := cast(^Native_Window_Bridge)data; bridge != nil && bridge.config.window_chrome_appearance != nil {
		return bridge.config.window_chrome_appearance(bridge.config.state, rt)
	}
	return {}
}

@(private)
native_window_open_failed :: proc(data: rawptr) {
	bridge := cast(^Native_Window_Bridge)data
	if bridge == nil { return }
	state := bridge.config.state
	failed := bridge.on_open_failed
	free(bridge)
	if failed != nil { failed(state) }
}

@(private)
native_window_service_open :: proc(data: rawptr, description: alicorn.Hosted_Window_Description) -> bool {
	ctx := cast(^Native_Window_Service)data
	if ctx == nil || ctx.service.open == nil || description.config.render == nil { return false }
	bridge := new(Native_Window_Bridge)
	if bridge == nil { return false }
	bridge.config = description.config
	bridge.on_open_failed = description.on_open_failed
	application := host.Application{
		state=rawptr(bridge),
		title=description.title,
		width=description.width,
		height=description.height,
		menus=description.config.menus,
		menu_presentation=host.Application_Menu_Presentation(description.config.menu_presentation),
		window_decorations=host.Window_Decoration_Mode(description.config.window_decorations),
		window_chrome_height=description.config.window_chrome_height,
		window_chrome_metrics=native_window_chrome_metrics,
		window_chrome_layout=native_window_chrome_layout,
		window_chrome_appearance=native_window_chrome_appearance,
		build=native_window_build,
		interaction_update_policy=host.Application_Interaction_Update_Policy(description.config.interaction_update_policy),
	}
	if description.config.on_initialize != nil { application.on_initialize = native_window_initialize }
	if description.config.on_host_services != nil { application.on_services = native_window_services }
	if description.config.on_file_drop != nil { application.on_file_drop = native_window_file_drop }
	if description.config.on_tick != nil { application.on_tick = native_window_tick }
	if description.config.on_start != nil { application.on_start = native_window_start }
	if description.config.on_wake != nil { application.on_wake = native_window_wake }
	if description.config.on_scheduled_wake != nil { application.on_scheduled_wake = native_window_scheduled_wake }
	application.on_stop = native_window_stop
	if description.config.on_key != nil { application.on_key = native_window_key }
	if description.config.on_text_change != nil { application.on_text_change = native_window_text_change }
	if description.config.on_text_key != nil { application.on_text_key = native_window_text_key }
	if description.config.on_pointer != nil { application.on_pointer = native_window_pointer }
	if description.config.on_drag != nil { application.on_drag = native_window_drag }
	if description.config.on_scroll_capture != nil { application.on_scroll_capture = native_window_scroll_capture }
	if description.config.on_scroll != nil { application.on_scroll = native_window_scroll }
	if description.config.on_text_input != nil { application.on_text_input = native_window_text_input }
	if description.config.on_menu_command != nil { application.on_menu_command = native_window_menu_command }
	if description.config.on_close_requested != nil { application.on_close_requested = native_window_close_requested }
	if description.config.on_dialog != nil { application.on_dialog = native_window_dialog }
	native_description := host.Application_Window_Description{
		application=application,
		width=description.width,
		height=description.height,
		always_on_top=description.always_on_top,
		on_open_failed=native_window_open_failed,
	}
	if !host.application_open_window(ctx.service, native_description) {
		free(bridge)
		return false
	}
	return true
}

@(private)
native_window_service_close :: proc(data: rawptr) {
	if ctx := cast(^Native_Window_Service)data; ctx != nil && ctx.service.close != nil {
		ctx.service.close(ctx.service.data)
	}
}

@(private)
native_window_service_set_always_on_top :: proc(data: rawptr, always_on_top: bool) -> bool {
	ctx := cast(^Native_Window_Service)data
	if ctx == nil || ctx.service.set_always_on_top == nil { return false }
	return ctx.service.set_always_on_top(ctx.service.data, always_on_top)
}

@(private)
native_window_service_set_title :: proc(data: rawptr, title: string) -> bool {
	ctx := cast(^Native_Window_Service)data
	if ctx == nil || ctx.service.set_title == nil { return false }
	return ctx.service.set_title(ctx.service.data, title)
}
