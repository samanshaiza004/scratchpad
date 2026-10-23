package main

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"
import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"
import bridge "./bridge"

Floating_Window_State :: struct {
	owner: ^App,
	runtime: ^alicorn.Runtime,
	document_id: string,
	services: host.Application_Services,
	visible_window_lane: bridge.Visible_Window_Lane,
	editor_window: Editor_Window,
	editor_window_ready: bool,
	editor_row_targets: [dynamic]Editor_Row_Target,
	editor_scroll_owner: alicorn.Node_ID,
	editor_restore_scroll: bool,
	editor_restore_vertical: bool,
	editor_restore_horizontal: bool,
	editor_restore_x, editor_restore_y: f32,
	editor_presented_document_id: string,
	editor_input_anchor_node: alicorn.Node_ID,
	editor_input_anchor_byte: int,
	editor_input_anchor_affinity: alicorn.Text_Affinity,
	editor_window_error: string,
	editor_window_rejected_request: bridge.Visible_Window_Request,
	editor_window_request_rejected: bool,
	editor_request_generation: u64,
	editor_focus_pending: bool,
	style_theme_runtime: ^alicorn.Runtime,
	workbench_theme, editor_theme: alicorn.Style_Theme_ID,
	warm_workbench_theme, warm_editor_theme: alicorn.Style_Theme_ID,
	relief_workbench_theme, relief_editor_theme: alicorn.Style_Theme_ID,
	cool_light_theme: alicorn.Style_Theme_ID,
	paper_surface_material, raised_surface_material, floating_surface_material: alicorn.Material_ID,
	relief_materials: Scratchpad_Relief_Materials,
	always_on_top: bool,
	return_to_tabs: bool,
	was_primary_active: bool,
	caption_title: string,
	caption_actions: [3]host.Application_Menu,
	accessibility_source_lane: Accessibility_Source_Lane,
	accessibility_projection: Editor_Accessibility_Projection,
	accessibility_source_error: string,
	accessibility_source_error_document_id: string,
	accessibility_source_error_revision: u64,
	accessibility_semantic_area_id: alicorn.Semantic_ID,
	accessibility_semantic_revision: u64,
	accessibility_semantic_has_runs: bool,
	accessibility_semantic_run_count: int,
}

Floating_Window_Scope :: struct {
	active_document: string,
	active_allocator: mem.Allocator,
	accessibility_source_lane_override: ^Accessibility_Source_Lane,
	accessibility_projection: Editor_Accessibility_Projection,
	accessibility_source_error: string,
	accessibility_source_error_document_id: string,
	accessibility_source_error_revision: u64,
	accessibility_semantic_area_id: alicorn.Semantic_ID,
	accessibility_semantic_revision: u64,
	accessibility_semantic_has_runs: bool,
	accessibility_semantic_run_count: int,
	services: host.Application_Services,
	visible_window_lane_override: ^bridge.Visible_Window_Lane,
	editor_window: Editor_Window,
	editor_window_ready: bool,
	editor_row_targets: [dynamic]Editor_Row_Target,
	editor_scroll_owner: alicorn.Node_ID,
	editor_restore_scroll, editor_restore_vertical, editor_restore_horizontal: bool,
	editor_restore_x, editor_restore_y: f32,
	editor_presented_document_id: string,
	editor_input_anchor_node: alicorn.Node_ID,
	editor_input_anchor_byte: int,
	editor_input_anchor_affinity: alicorn.Text_Affinity,
	editor_window_error: string,
	editor_window_rejected_request: bridge.Visible_Window_Request,
	editor_window_request_rejected: bool,
	editor_request_generation: u64,
	editor_focus_pending: bool,
	style_theme_runtime: ^alicorn.Runtime,
	workbench_theme, editor_theme: alicorn.Style_Theme_ID,
	warm_workbench_theme, warm_editor_theme: alicorn.Style_Theme_ID,
	relief_workbench_theme, relief_editor_theme: alicorn.Style_Theme_ID,
	cool_light_theme: alicorn.Style_Theme_ID,
	paper_surface_material, raised_surface_material, floating_surface_material: alicorn.Material_ID,
	relief_materials: Scratchpad_Relief_Materials,
}

editor_visible_window_lane :: proc(app: ^App) -> ^bridge.Visible_Window_Lane {
	if app == nil { return nil }
	if app.editor_visible_window_lane_override != nil { return app.editor_visible_window_lane_override }
	return &app.visible_window_lane
}

floating_window_contains :: proc(app: ^App, document_id: string) -> bool {
	return app != nil && app.floating_window != nil && app.floating_window.document_id == document_id
}

floating_window_tab_document_indices :: proc(
	documents: []bridge.State_Document,
	detached_document_id: string,
	allocator := context.temp_allocator,
) -> [dynamic]int {
	indices := make([dynamic]int, 0, len(documents), allocator=allocator)
	for document, index in documents {
		if detached_document_id != "" && document.id == detached_document_id { continue }
		append(&indices, index)
	}
	return indices
}

floating_window_pin_preview :: proc(app: ^App, rt: ^alicorn.Runtime, document_id: string) -> bool {
	if app == nil || !app.backend.started { return false }
	document, found := find_document(&app.backend.state, document_id)
	if !found { return false }
	if !document.preview { return true }
	order := make([dynamic]string, 0, len(app.backend.state.documents), allocator=context.temp_allocator)
	defer delete(order)
	for open_document in app.backend.state.documents { append(&order, open_document.id) }
	// Reordering to the existing order is the Caliber contract for promoting a
	// preview tab. Detached documents must survive later preview opens.
	result := bridge.backend_command(&app.backend, "reorder_documents", document_order=order[:])
	handle_command_result(app, rt, &result)
	ok := result.ok
	bridge.backend_command_result_destroy(&result, context.allocator)
	return ok
}

// Select the nearest tab only when the detached document owned the primary view.
floating_window_neighbor :: proc(documents: []bridge.State_Document, detached_id, active_id: string) -> string {
	if active_id != detached_id { return active_id }
	for document, index in documents {
		if document.id != detached_id { continue }
		if index+1 < len(documents) { return documents[index+1].id }
		if index > 0 { return documents[index-1].id }
		break
	}
	return ""
}

floating_editor_scope_enter :: proc(state: ^Floating_Window_State, rt: ^alicorn.Runtime) -> (app: ^App, scope: Floating_Window_Scope) {
	if state == nil || state.owner == nil { return }
	app = state.owner
	active_copy, active_error := strings.clone(state.document_id, app.backend.state_allocator)
	if active_error != nil { app = nil; return }
	if rt != nil { state.runtime = rt }
	scope = Floating_Window_Scope{
		active_document=app.backend.state.active,
		active_allocator=app.backend.state_allocator,
		accessibility_source_lane_override=app.accessibility_source_lane_override,
		accessibility_projection=app.accessibility_projection,
		accessibility_source_error=app.accessibility_source_error,
		accessibility_source_error_document_id=app.accessibility_source_error_document_id,
		accessibility_source_error_revision=app.accessibility_source_error_revision,
		accessibility_semantic_area_id=app.accessibility_semantic_area_id,
		accessibility_semantic_revision=app.accessibility_semantic_revision,
		accessibility_semantic_has_runs=app.accessibility_semantic_has_runs,
		accessibility_semantic_run_count=app.accessibility_semantic_run_count,
		services=app.services,
		visible_window_lane_override=app.editor_visible_window_lane_override,
		editor_window=app.editor_window,
		editor_window_ready=app.editor_window_ready,
		editor_row_targets=app.editor_row_targets,
		editor_scroll_owner=app.editor_scroll_owner,
		editor_restore_scroll=app.editor_restore_scroll,
		editor_restore_vertical=app.editor_restore_vertical,
		editor_restore_horizontal=app.editor_restore_horizontal,
		editor_restore_x=app.editor_restore_x,
		editor_restore_y=app.editor_restore_y,
		editor_presented_document_id=app.editor_presented_document_id,
		editor_input_anchor_node=app.editor_input_anchor_node,
		editor_input_anchor_byte=app.editor_input_anchor_byte,
		editor_input_anchor_affinity=app.editor_input_anchor_affinity,
		editor_window_error=app.editor_window_error,
		editor_window_rejected_request=app.editor_window_rejected_request,
		editor_window_request_rejected=app.editor_window_request_rejected,
		editor_request_generation=app.editor_request_generation,
		editor_focus_pending=app.editor_focus_pending,
		style_theme_runtime=app.style_theme_runtime,
		workbench_theme=app.workbench_theme,
		editor_theme=app.editor_theme,
		warm_workbench_theme=app.warm_workbench_theme,
		warm_editor_theme=app.warm_editor_theme,
		relief_workbench_theme=app.relief_workbench_theme,
		relief_editor_theme=app.relief_editor_theme,
		cool_light_theme=app.cool_light_theme,
		paper_surface_material=app.paper_surface_material,
		raised_surface_material=app.raised_surface_material,
		floating_surface_material=app.floating_surface_material,
		relief_materials=app.relief_materials,
	}
	// Transfer the primary active-ID allocation into scope. The temporary child
	// ID belongs to the envelope, so a backend refresh can dispose it safely.
	app.backend.state.active = active_copy
	app.accessibility_source_lane_override = &state.accessibility_source_lane
	app.accessibility_projection = state.accessibility_projection
	state.accessibility_projection = {}
	app.accessibility_source_error = state.accessibility_source_error
	app.accessibility_source_error_document_id = state.accessibility_source_error_document_id
	app.accessibility_source_error_revision = state.accessibility_source_error_revision
	app.accessibility_semantic_area_id = state.accessibility_semantic_area_id
	app.accessibility_semantic_revision = state.accessibility_semantic_revision
	app.accessibility_semantic_has_runs = state.accessibility_semantic_has_runs
	app.accessibility_semantic_run_count = state.accessibility_semantic_run_count
	app.services = state.services
	app.editor_visible_window_lane_override = &state.visible_window_lane
	app.editor_window = state.editor_window
	state.editor_window = {}
	app.editor_window_ready = state.editor_window_ready
	app.editor_row_targets = state.editor_row_targets
	state.editor_row_targets = {}
	app.editor_scroll_owner = state.editor_scroll_owner
	app.editor_restore_scroll = state.editor_restore_scroll
	app.editor_restore_vertical = state.editor_restore_vertical
	app.editor_restore_horizontal = state.editor_restore_horizontal
	app.editor_restore_x = state.editor_restore_x
	app.editor_restore_y = state.editor_restore_y
	app.editor_presented_document_id = state.editor_presented_document_id
	app.editor_input_anchor_node = state.editor_input_anchor_node
	app.editor_input_anchor_byte = state.editor_input_anchor_byte
	app.editor_input_anchor_affinity = state.editor_input_anchor_affinity
	app.editor_window_error = state.editor_window_error
	app.editor_window_rejected_request = state.editor_window_rejected_request
	app.editor_window_request_rejected = state.editor_window_request_rejected
	app.editor_request_generation = state.editor_request_generation
	app.editor_focus_pending = state.editor_focus_pending
	app.style_theme_runtime = state.style_theme_runtime
	app.workbench_theme = state.workbench_theme
	app.editor_theme = state.editor_theme
	app.warm_workbench_theme = state.warm_workbench_theme
	app.warm_editor_theme = state.warm_editor_theme
	app.relief_workbench_theme = state.relief_workbench_theme
	app.relief_editor_theme = state.relief_editor_theme
	app.cool_light_theme = state.cool_light_theme
	app.paper_surface_material = state.paper_surface_material
	app.raised_surface_material = state.raised_surface_material
	app.floating_surface_material = state.floating_surface_material
	app.relief_materials = state.relief_materials
	return
}

floating_editor_scope_leave :: proc(state: ^Floating_Window_State, app: ^App, scope: ^Floating_Window_Scope) {
	if state == nil || app == nil || scope == nil { return }
	state.editor_window = app.editor_window
	state.editor_window_ready = app.editor_window_ready
	state.editor_row_targets = app.editor_row_targets
	state.editor_scroll_owner = app.editor_scroll_owner
	state.editor_restore_scroll = app.editor_restore_scroll
	state.editor_restore_vertical = app.editor_restore_vertical
	state.editor_restore_horizontal = app.editor_restore_horizontal
	state.editor_restore_x = app.editor_restore_x
	state.editor_restore_y = app.editor_restore_y
	state.editor_presented_document_id = app.editor_presented_document_id
	state.editor_input_anchor_node = app.editor_input_anchor_node
	state.editor_input_anchor_byte = app.editor_input_anchor_byte
	state.editor_input_anchor_affinity = app.editor_input_anchor_affinity
	state.editor_window_error = app.editor_window_error
	state.editor_window_rejected_request = app.editor_window_rejected_request
	state.editor_window_request_rejected = app.editor_window_request_rejected
	state.editor_request_generation = app.editor_request_generation
	state.editor_focus_pending = app.editor_focus_pending
	state.style_theme_runtime = app.style_theme_runtime
	state.workbench_theme = app.workbench_theme
	state.editor_theme = app.editor_theme
	state.warm_workbench_theme = app.warm_workbench_theme
	state.warm_editor_theme = app.warm_editor_theme
	state.relief_workbench_theme = app.relief_workbench_theme
	state.relief_editor_theme = app.relief_editor_theme
	state.cool_light_theme = app.cool_light_theme
	state.paper_surface_material = app.paper_surface_material
	state.raised_surface_material = app.raised_surface_material
	state.floating_surface_material = app.floating_surface_material
	state.relief_materials = app.relief_materials
	state.accessibility_projection = app.accessibility_projection
	state.accessibility_source_error = app.accessibility_source_error
	state.accessibility_source_error_document_id = app.accessibility_source_error_document_id
	state.accessibility_source_error_revision = app.accessibility_source_error_revision
	state.accessibility_semantic_area_id = app.accessibility_semantic_area_id
	state.accessibility_semantic_revision = app.accessibility_semantic_revision
	state.accessibility_semantic_has_runs = app.accessibility_semantic_has_runs
	state.accessibility_semantic_run_count = app.accessibility_semantic_run_count
	if scope.active_document == "" || document_is_open(&app.backend.state, scope.active_document) {
		if app.backend.state_allocator.procedure == scope.active_allocator.procedure && app.backend.state_allocator.data == scope.active_allocator.data {
			delete(app.backend.state.active, app.backend.state_allocator)
			app.backend.state.active = scope.active_document
		} else {
			restored, err := strings.clone(scope.active_document, app.backend.state_allocator)
			if err == nil {
				delete(app.backend.state.active, app.backend.state_allocator)
				app.backend.state.active = restored
			}
			delete(scope.active_document, scope.active_allocator)
		}
	} else { delete(scope.active_document, scope.active_allocator) }
	scope.active_document = ""
	app.accessibility_source_lane_override = scope.accessibility_source_lane_override
	app.accessibility_projection = scope.accessibility_projection
	app.accessibility_source_error = scope.accessibility_source_error
	app.accessibility_source_error_document_id = scope.accessibility_source_error_document_id
	app.accessibility_source_error_revision = scope.accessibility_source_error_revision
	app.accessibility_semantic_area_id = scope.accessibility_semantic_area_id
	app.accessibility_semantic_revision = scope.accessibility_semantic_revision
	app.accessibility_semantic_has_runs = scope.accessibility_semantic_has_runs
	app.accessibility_semantic_run_count = scope.accessibility_semantic_run_count
	app.services = scope.services
	app.editor_visible_window_lane_override = scope.visible_window_lane_override
	app.editor_window = scope.editor_window
	app.editor_window_ready = scope.editor_window_ready
	app.editor_row_targets = scope.editor_row_targets
	app.editor_scroll_owner = scope.editor_scroll_owner
	app.editor_restore_scroll = scope.editor_restore_scroll
	app.editor_restore_vertical = scope.editor_restore_vertical
	app.editor_restore_horizontal = scope.editor_restore_horizontal
	app.editor_restore_x = scope.editor_restore_x
	app.editor_restore_y = scope.editor_restore_y
	app.editor_presented_document_id = scope.editor_presented_document_id
	app.editor_input_anchor_node = scope.editor_input_anchor_node
	app.editor_input_anchor_byte = scope.editor_input_anchor_byte
	app.editor_input_anchor_affinity = scope.editor_input_anchor_affinity
	app.editor_window_error = scope.editor_window_error
	app.editor_window_rejected_request = scope.editor_window_rejected_request
	app.editor_window_request_rejected = scope.editor_window_request_rejected
	app.editor_request_generation = scope.editor_request_generation
	app.editor_focus_pending = scope.editor_focus_pending
	app.style_theme_runtime = scope.style_theme_runtime
	app.workbench_theme = scope.workbench_theme
	app.editor_theme = scope.editor_theme
	app.warm_workbench_theme = scope.warm_workbench_theme
	app.warm_editor_theme = scope.warm_editor_theme
	app.relief_workbench_theme = scope.relief_workbench_theme
	app.relief_editor_theme = scope.relief_editor_theme
	app.cool_light_theme = scope.cool_light_theme
	app.paper_surface_material = scope.paper_surface_material
	app.raised_surface_material = scope.raised_surface_material
	app.floating_surface_material = scope.floating_surface_material
	app.relief_materials = scope.relief_materials
}

floating_window_drag_outside :: proc(rt: ^alicorn.Runtime, event: alicorn.Drag_Event) -> bool {
	if rt == nil || event.kind != .Cancelled || !event.has_pointer_position { return false }
	viewport := alicorn.viewport_bounds(rt)
	return event.pointer_x < viewport.x || event.pointer_y < viewport.y ||
		event.pointer_x >= viewport.x+viewport.w || event.pointer_y >= viewport.y+viewport.h
}

floating_window_open :: proc(app: ^App, rt: ^alicorn.Runtime, document_id: string) -> bool {
	if app == nil || rt == nil || !app.backend.started { return false }
	if app.floating_window != nil {
		set_error(app, "A document is already floating. Return it to tabs before detaching another.")
		alicorn.invalidate_root(rt, "floating window slot is already occupied")
		return false
	}
	document, found := find_document(&app.backend.state, document_id)
	if !found { return false }
	if document.view_kind == "image" || document.view_kind == "unsupported" {
		set_error(app, "Only text documents can be detached into a floating window.")
		alicorn.invalidate_root(rt, "unsupported floating document kind")
		return false
	}
	if document.preview {
		if !floating_window_pin_preview(app, rt, document_id) { return false }
		document, found = find_document(&app.backend.state, document_id)
		if !found { return false }
	}
	state := new(Floating_Window_State, allocator=context.allocator)
	if state == nil { return false }
	state.owner = app
	state.runtime = nil
	owned_document_id, clone_error := strings.clone(document.id, context.allocator)
	if clone_error != nil { free(state, allocator=context.allocator); return false }
	state.document_id = owned_document_id
	state.return_to_tabs = true
	state.was_primary_active = app.backend.state.active == state.document_id
	state.caption_actions = {
		{label="Save", command=action_id_for(ACTION_FILE_SAVE), state=alicorn.Action_State{enabled=true}, shortcut=host.Application_Menu_Shortcut{key='s',modifiers={.Primary}}},
		{label="On top", command=action_id_for("floating.on-top"), state=alicorn.Action_State{enabled=true}},
		{label="Return to tabs", command=action_id_for("floating.return"), state=alicorn.Action_State{enabled=true}},
	}
	title := fmt.tprintf("%s — Scratchpad", document_title(document.path))
	description := host.Application_Window_Description{
		application=host.Application{
			state=rawptr(state),
			menus=state.caption_actions[:],
			window_chrome_appearance=floating_window_chrome_appearance,
			window_decorations=.Integrated_Title_Bar when ODIN_OS == .Windows else .System,
			title=title,
				width=760,
				height=560,
				on_initialize=floating_window_initialize,
				build=floating_window_build,
				on_key=floating_window_key,
				on_pointer=floating_window_pointer,
				on_text_key=floating_window_text_key,
				on_text_input=floating_window_text_input,
				on_services=floating_window_services,
				on_start=floating_window_start,
				on_close_requested=floating_window_close_requested,
				on_stop=floating_window_stop,
				on_menu_command=floating_window_menu_command,
				on_scheduled_wake=floating_window_scheduled_wake,
			},
		width=760,
		height=560,
		on_open_failed=floating_window_open_failed,
	}
	if !host.application_open_window(app.services.windows, description) {
		delete(state.document_id, context.allocator)
		free(state, allocator=context.allocator)
		return false
	}
	app.floating_window = state
	neighbor := floating_window_neighbor(app.backend.state.documents, state.document_id, app.backend.state.active)
	if neighbor != "" && neighbor != app.backend.state.active {
		owned_neighbor, err := strings.clone(neighbor, context.temp_allocator)
		if err == nil { select_document(app, rt, owned_neighbor); delete(owned_neighbor, context.temp_allocator) }
	}
	alicorn.invalidate_root(rt, "Scratchpad opened a floating document window")
	return true
}

floating_window_initialize :: proc(state: rawptr, rt: ^alicorn.Runtime) {
	if state == nil || rt == nil { return }
	window := cast(^Floating_Window_State)state
	window.runtime = rt
	_ = alicorn.font_load_bytes(rt, .UI, SCRATCHPAD_UI_FONT_DATA)
	_ = alicorn.font_load_italic_bytes(rt, .UI, SCRATCHPAD_UI_ITALIC_FONT_DATA)
	_ = scratchpad_editor_font_install(rt, scratchpad_editor_font_regular_bytes(window.owner), scratchpad_editor_font_italic_bytes(window.owner))
}

floating_window_services :: proc(state: rawptr, services: host.Application_Services) {
	window := cast(^Floating_Window_State)state
	if window != nil { window.services = services }
}

floating_window_start :: proc(state: rawptr, waker: host.Application_Waker) {
	window := cast(^Floating_Window_State)state
	if window == nil || window.owner == nil || !window.owner.backend.started { return }
	app := window.owner
	_ = accessibility_source_lane_start(&window.accessibility_source_lane, &app.backend, app.waker.wake, app.waker.data)
	if !bridge.visible_window_lane_start(&window.visible_window_lane, &app.backend, app.waker.wake, app.waker.data) {
		window.editor_window_error, _ = strings.clone("Could not start the floating document reader.", context.allocator)
	}
}

floating_window_close_requested :: proc(state: rawptr, rt: ^alicorn.Runtime) -> host.Application_Close_Result {
	return .Allow
}

floating_window_open_failed :: proc(state: rawptr) {
	window := cast(^Floating_Window_State)state
	if window == nil { return }
	app := window.owner
	if app != nil && app.floating_window == window {
		app.floating_window = nil
		set_error(app, "Could not open the floating document window. The document remains in Scratchpad.")
		if window.was_primary_active && app.primary_runtime != nil && document_is_open(&app.backend.state, window.document_id) { select_document(app, app.primary_runtime, window.document_id) }
		if app.primary_runtime != nil { alicorn.invalidate_root(app.primary_runtime, "floating document window could not open") }
	}
	floating_window_state_destroy(window)
}

floating_window_stop :: proc(state: rawptr) {
	window := cast(^Floating_Window_State)state
	if window == nil { return }
	app := window.owner
	if window.accessibility_source_lane.thread != nil { _ = accessibility_source_lane_stop(&window.accessibility_source_lane) }
	if window.visible_window_lane.thread != nil { _ = bridge.visible_window_lane_stop(&window.visible_window_lane) }
	if app != nil && window.return_to_tabs && app.backend.started && document_is_open(&app.backend.state, window.document_id) {
		if app.primary_runtime != nil { select_document(app, app.primary_runtime, window.document_id) }
	}
	if app != nil && app.floating_window == window {
		app.floating_window = nil
		if app.primary_runtime != nil { alicorn.invalidate_root(app.primary_runtime, "floating document returned to the main tab bar") }
	}
	floating_window_state_destroy(window)
}

floating_window_state_destroy :: proc(window: ^Floating_Window_State) {
	if window == nil { return }
	editor_accessibility_projection_destroy(&window.accessibility_projection)
	delete(window.accessibility_source_error, context.allocator)
	delete(window.accessibility_source_error_document_id, context.allocator)
	delete(window.caption_title, context.allocator)
	editor_window_destroy(&window.editor_window)
	delete(window.editor_row_targets)
	if len(window.editor_presented_document_id) > 0 { delete(window.editor_presented_document_id, context.allocator) }
	if len(window.editor_window_error) > 0 { delete(window.editor_window_error, context.allocator) }
	if len(window.editor_window_rejected_request.document_id) > 0 { delete(window.editor_window_rejected_request.document_id, context.allocator) }
	if len(window.document_id) > 0 { delete(window.document_id, context.allocator) }
	free(window, allocator=context.allocator)
}

floating_window_return_to_tabs :: proc(app: ^App) {
	if app == nil || app.floating_window == nil { return }
	app.floating_window.return_to_tabs = true
	host.application_close_window(app.services.windows)
}

floating_window_build :: proc(
	state: rawptr,
	rt: ^alicorn.Runtime,
	logical_width, logical_height: int,
	dpi_scale: f32,
) -> alicorn.Node_ID {
	window := cast(^Floating_Window_State)state
	app, scope := floating_editor_scope_enter(window, rt)
	if app == nil { return 0 }
	defer floating_editor_scope_leave(window, app, &scope)
	if !scratchpad_styles_ensure(app, rt) { return 0 }
	editor_accessibility_requests_drain(app, rt)
	ui, should_build := alicorn.begin_frame(rt)
	if !should_build { return 0 }
	root := alicorn.container_begin(
		&ui, .Root, label="scratchpad-floating-document",
		style=alicorn.layout_style(.Column, grow=1, gap=0, clip=true),
		color=alicorn.style_theme_color(rt, app.editor_theme, .Window_Background),
	)
	workbench_scope := alicorn.style_environment_push(&ui, scratchpad_workbench_style_environment(app))
	if document, found := find_document(&app.backend.state, window.document_id); found {
		title := floating_window_document_heading(app, document)
		if title != window.caption_title {
			if host.application_window_set_title(window.services.windows, title) {
				delete(window.caption_title, context.allocator)
				window.caption_title, _ = strings.clone(title, context.allocator)
			}
		}
		window.caption_actions[0].state.enabled = floating_window_document_dirty(app, document) && document.status != "conflict"
		window.caption_actions[1].state.checked = window.always_on_top
		when ODIN_OS != .Windows {
			alicorn.container_begin(&ui, .Container, label="floating-document-toolbar", style=alicorn.layout_style(.Row, height=alicorn.LAYOUT_SIZE_FIT_CONTENT, min_height=38, max_height=72, padding=6, gap=6, align=.Center, clip=true), color=alicorn.style_color(&ui, .Surface))
			alicorn.text(&ui, title, style=alicorn.layout_style(.Row, grow=1), text_style=alicorn.Text_Style{overflow=.Wrap})
			if alicorn.button(&ui, "Save", key=alicorn.key_string("floating-save"), style=alicorn.layout_style(.Row, width=54, height=26), variant=.Toolbar) { floating_window_save(app, rt, window.document_id) }
			if alicorn.button(&ui, "On top", key=alicorn.key_string("floating-topmost"), style=alicorn.layout_style(.Row, width=68, height=26), state=alicorn.Button_State{selected=window.always_on_top}, variant=.Toolbar) { floating_window_toggle_topmost(window) }
			if alicorn.button(&ui, "Return to tabs", key=alicorn.key_string("floating-return"), style=alicorn.layout_style(.Row, width=108, height=26), variant=.Toolbar) { floating_window_return_to_tabs(app) }
			alicorn.container_end(&ui)
		}
	}
	style_scope := alicorn.style_environment_push(&ui, alicorn.Style_Environment{theme=app.editor_theme})
	padding := scratchpad_editor_surface_padding(&ui, rt, app.editor_theme)
	alicorn.surface_begin(&ui, alicorn.surface_extension_color_role(scratchpad_editor_paper_surface_role()), key=alicorn.key_string("floating-document-surface"), label="floating-document-surface", style=alicorn.layout_style(.Column, grow=1, padding=padding, gap=6, align=.Start, clip=true), material=scratchpad_surface_material(app, app.paper_surface_material), physical_height=scratchpad_surface_height(app, -0.75))
	if document, found := find_document(&app.backend.state, window.document_id); found {
		if alicorn.component_begin(&ui, alicorn.key_string(document.id)) {
			build_document_editor(app, &ui, rt, document, show_heading=false)
			alicorn.component_end(&ui)
		}
	} else {
		alicorn.text(&ui, "This document was closed in Scratchpad.")
	}
	alicorn.style_environment_pop(&ui, style_scope)
	alicorn.surface_end(&ui)
	alicorn.style_environment_pop(&ui, workbench_scope)
	alicorn.end_frame(&ui)
	editor_view_restore_after_frame(app, rt, app.editor_scroll_owner)
	if app.editor_focus_pending && app.editor_scroll_owner != 0 {
		if alicorn.focus(rt, app.editor_scroll_owner) { app.editor_focus_pending = false }
	}
	if app.editor_restore_scroll && app.editor_scroll_owner != 0 {
		if app.editor_restore_vertical { _ = alicorn.scroll_region_set_offset(rt, app.editor_scroll_owner, app.editor_restore_y, "restore floating document vertical view") }
		if app.editor_restore_horizontal { _ = alicorn.scroll_region_set_offset_x(rt, app.editor_scroll_owner, app.editor_restore_x, "restore floating document horizontal view") }
		app.editor_restore_scroll = false
		app.editor_restore_vertical = false
		app.editor_restore_horizontal = false
	}
	if app.editor_input_anchor_node != 0 && app.editor_scroll_owner != 0 {
		geometry := alicorn.text_node_caret_geometry(rt, app.editor_input_anchor_node, alicorn.Text_Position{byte=app.editor_input_anchor_byte, affinity=app.editor_input_anchor_affinity})
		if geometry.valid {
			area := alicorn.Text_Input_Area{rect=alicorn.Rect{geometry.rect.x, geometry.rect.y, 1, max(geometry.rect.h, EDITOR_ROW_HEIGHT*editor_text_scale_effective(app))}, cursor_x=0}
			_ = alicorn.text_input_target_area_set(rt, app.editor_scroll_owner, area)
		}
	}
	editor_reveal_after_frame(app, rt)
	return root
}

floating_window_document_dirty :: proc(app: ^App, document: bridge.State_Document) -> bool {
	if document.dirty { return true }
	if i := editor_view_find(app.editor_views[:], document.id); i >= 0 { return app.editor_views[i].optimistic_pending_edits > 0 }
	return false
}

floating_window_document_heading :: proc(app: ^App, document: bridge.State_Document) -> string {
	lines := document.line_count
	if i := editor_view_find(app.editor_views[:], document.id); i >= 0 {
		view := &app.editor_views[i]
		if view.optimistic_pending_edits > 0 {
			if view.optimistic_line_delta < 0 { lines = u64(max(i64(lines)+view.optimistic_line_delta, 1)) }
			else { lines += u64(view.optimistic_line_delta) }
		}
	}
	modified := " *" if floating_window_document_dirty(app, document) else ""
	return fmt.tprintf("%s%s · %s · %d lines", document_title(document.path), modified, document.language, lines)
}

floating_window_save :: proc(app: ^App, rt: ^alicorn.Runtime, document_id: string) {
	if app == nil || !app.backend.started || !document_is_open(&app.backend.state, document_id) { return }
	if len(app.editor_edits) > 0 {
		if !deferred_action_enqueue(app, .Save_Document, value=document_id) { set_error(app, "Could not queue the floating document save.") }
		return
	}
	result := bridge.backend_command(&app.backend, "save_document", document_id=document_id)
	handle_command_result(app, rt, &result)
	bridge.backend_command_result_destroy(&result, context.allocator)
}

floating_window_toggle_topmost :: proc(window: ^Floating_Window_State) {
	if window == nil { return }
	requested := !window.always_on_top
	if host.application_window_set_always_on_top(window.services.windows, requested) { window.always_on_top = requested; window.caption_actions[1].state.checked = requested }
}

floating_window_chrome_appearance :: proc(state: rawptr, rt: ^alicorn.Runtime) -> host.Window_Chrome_Appearance {
	window := cast(^Floating_Window_State)state
	app, scope := floating_editor_scope_enter(window, rt)
	if app == nil { return {} }
	defer floating_editor_scope_leave(window, app, &scope)
	if !scratchpad_styles_ensure(app, rt) { return {} }
	return scratchpad_window_chrome_appearance(rawptr(app), rt)
}

floating_window_menu_command :: proc(state: rawptr, rt: ^alicorn.Runtime, command: host.Application_Command_ID) {
	window := cast(^Floating_Window_State)state
	app, scope := floating_editor_scope_enter(window, rt)
	if app == nil { return }
	defer floating_editor_scope_leave(window, app, &scope)
	if command == action_id_for(ACTION_FILE_SAVE) { floating_window_save(app, rt, window.document_id) }
	else if command == action_id_for("floating.on-top") { floating_window_toggle_topmost(window) }
	else if command == action_id_for("floating.return") { floating_window_return_to_tabs(app) }
	alicorn.invalidate_root(rt, "floating caption command")
}

floating_window_scheduled_wake :: proc(state: rawptr, rt: ^alicorn.Runtime, class: host.Scheduled_Wake_Class) {
	window := cast(^Floating_Window_State)state
	app, scope := floating_editor_scope_enter(window, rt)
	if app == nil { return }
	defer floating_editor_scope_leave(window, app, &scope)
	application_scheduled_wake(rawptr(app), rt, class)
}

floating_window_key :: proc(state: rawptr, rt: ^alicorn.Runtime, key: host.Application_Key) -> bool {
	window := cast(^Floating_Window_State)state
	if window == nil || window.owner == nil { return false }
	if key == .Zoom_In || key == .Zoom_Out || key == .Zoom_Reset {
		app, scope := floating_editor_scope_enter(window, rt)
		if app == nil { return false }
		defer floating_editor_scope_leave(window, app, &scope)
		return application_key(rawptr(app), rt, key)
	}
	if key == .Return {
		app, scope := floating_editor_scope_enter(window, rt)
		if app == nil { return false }
		defer floating_editor_scope_leave(window, app, &scope)
		return application_key(rawptr(app), rt, key)
	}
	return false
}

floating_window_pointer :: proc(state: rawptr, rt: ^alicorn.Runtime, event: alicorn.Pointer_Event, target: alicorn.Node_ID) {
	window := cast(^Floating_Window_State)state
	app, scope := floating_editor_scope_enter(window, rt)
	if app == nil { return }
	defer floating_editor_scope_leave(window, app, &scope)
	editor_pointer(rawptr(app), rt, event, target)
}

floating_window_text_key :: proc(state: rawptr, rt: ^alicorn.Runtime, owner: alicorn.Node_ID, event: host.Application_Text_Key_Event) -> bool {
	window := cast(^Floating_Window_State)state
	app, scope := floating_editor_scope_enter(window, rt)
	if app == nil { return false }
	defer floating_editor_scope_leave(window, app, &scope)
	return editor_text_key(rawptr(app), rt, owner, event)
}

floating_window_text_input :: proc(state: rawptr, rt: ^alicorn.Runtime, owner: alicorn.Node_ID, event: host.Application_Text_Input_Event) {
	window := cast(^Floating_Window_State)state
	app, scope := floating_editor_scope_enter(window, rt)
	if app == nil { return }
	defer floating_editor_scope_leave(window, app, &scope)
	editor_text_input(rawptr(app), rt, owner, event)
}

@(test)
test_floating_window_drag_out_requires_outside_release :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 640, 480})
	defer alicorn.destroy_runtime(&rt)
	outside := alicorn.Drag_Event{kind=.Cancelled, pointer_x=641, pointer_y=20, has_pointer_position=true}
	inside := alicorn.Drag_Event{kind=.Cancelled, pointer_x=639, pointer_y=20, has_pointer_position=true}
	escape := alicorn.Drag_Event{kind=.Cancelled, pointer_x=641, pointer_y=20, has_pointer_position=false}
	started := alicorn.Drag_Event{kind=.Started, pointer_x=641, pointer_y=20, has_pointer_position=true}
	testing.expect(t, floating_window_drag_outside(&rt, outside), "releasing a tab beyond the window should detach it")
	testing.expect(t, !floating_window_drag_outside(&rt, inside), "an in-window cancelled drag should not detach a tab")
	testing.expect(t, !floating_window_drag_outside(&rt, escape), "a keyboard cancellation without a pointer position should not detach a tab")
	testing.expect(t, !floating_window_drag_outside(&rt, started), "only a released drag may detach a tab")
}

@(test)
test_floating_window_tab_projection_hides_only_the_detached_document :: proc(t: ^testing.T) {
	documents := [?]bridge.State_Document{{id="a"}, {id="b"}, {id="c"}}
	visible := floating_window_tab_document_indices(documents[:], "b", context.temp_allocator)
	defer delete(visible)
	testing.expect(t, len(visible) == 2 && visible[0] == 0 && visible[1] == 2,
		"tab-result indices should map around the hidden floating document without changing document identities")
	all := floating_window_tab_document_indices(documents[:], "missing", context.temp_allocator)
	defer delete(all)
	testing.expect(t, len(all) == 3 && all[2] == 2,
		"a stale detached identity should leave all ordinary tabs visible")
}

@(test)
test_floating_window_neighbor_selection :: proc(t: ^testing.T) {
	documents := [?]bridge.State_Document{{id="a"}, {id="b"}, {id="c"}}
	testing.expect(t, floating_window_neighbor(documents[:], "b", "b") == "c", "detaching the active middle tab should select its next neighbor")
	testing.expect(t, floating_window_neighbor(documents[:], "c", "c") == "b", "detaching the last tab should select its previous neighbor")
	testing.expect(t, floating_window_neighbor(documents[:], "b", "a") == "a", "detaching a background tab should preserve the primary active document")
	testing.expect(t, floating_window_neighbor(documents[:1], "a", "a") == "", "detaching the only tab leaves no document in the primary window")
}

@(test)
test_floating_scope_owns_active_id_across_backend_refresh :: proc(t: ^testing.T) {
	documents := [?]bridge.State_Document{{id="primary"}, {id="floating"}}
	app := App{}
	app.backend.state_allocator = context.allocator
	app.backend.state.documents = documents[:]
	app.backend.state.active, _ = strings.clone("primary", context.allocator)
	defer delete(app.backend.state.active, context.allocator)
	app.accessibility_semantic_area_id = alicorn.Semantic_ID{namespace=1, value=1}
	window := Floating_Window_State{owner=&app, accessibility_semantic_area_id=alicorn.Semantic_ID{namespace=2, value=2}}
	window.document_id, _ = strings.clone("floating", context.allocator)
	defer delete(window.document_id, context.allocator)
	scoped_app, scope := floating_editor_scope_enter(&window, nil)
	testing.expect(t, scoped_app == &app && app.backend.state.active == "floating", "the callback should target its floating document")
	testing.expect(t, rawptr(raw_data(app.backend.state.active)) != rawptr(raw_data(window.document_id)), "the envelope must own a separate active-ID allocation")
	testing.expect(t, editor_accessibility_lane(&app) == &window.accessibility_source_lane && app.accessibility_semantic_area_id.namespace == 2, "source reader and semantic bookkeeping must be window-local")
	// Model the envelope's active field being freed/replaced by backend_read_latest.
	delete(app.backend.state.active, context.allocator)
	app.backend.state.active, _ = strings.clone("primary", context.allocator)
	floating_editor_scope_leave(&window, &app, &scope)
	testing.expect(t, app.backend.state.active == "primary" && window.document_id == "floating", "refreshing the envelope must preserve both owned document identities")
	testing.expect(t, app.accessibility_source_lane_override == nil && app.accessibility_semantic_area_id.namespace == 1, "leaving the callback must restore the primary accessibility context")
}
