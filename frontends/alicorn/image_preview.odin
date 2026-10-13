package main

import "core:fmt"
import "core:strings"
import alicorn "alicorn:runtime"
import "./bridge"
import host "alicorn:native/sdl_gpu"

IMAGE_PREVIEW_MIN_ZOOM :: f32(0.125)
IMAGE_PREVIEW_MAX_ZOOM :: f32(8)
IMAGE_PREVIEW_ZOOM_STEP :: f32(1.25)
IMAGE_PREVIEW_TOOLBAR_HEIGHT :: f32(34)
IMAGE_PREVIEW_PADDING :: f32(16)

// View state is per document; decoded pixels remain bounded to the active tab.
Image_Preview_View :: struct {
	document_id: string,
	scroll_owner: alicorn.Node_ID,
	fit: bool,
	zoom: f32,
	effective_zoom: f32,
	reset_scroll: bool,
	restore_scroll: bool,
	scroll_x, scroll_y: f32,
}

image_preview_views_destroy :: proc(app: ^App) {
	if app == nil { return }
	for view in app.image_preview_views { delete(view.document_id, context.allocator) }
	delete(app.image_preview_views)
	app.image_preview_views = {}
}

image_preview_view_ensure :: proc(app: ^App, document_id: string) -> ^Image_Preview_View {
	for &view in app.image_preview_views { if view.document_id == document_id { return &view } }
	id, err := strings.clone(document_id, context.allocator)
	if err != nil { return nil }
	append(&app.image_preview_views, Image_Preview_View{document_id=id, fit=true, zoom=1, effective_zoom=1})
	return &app.image_preview_views[len(app.image_preview_views)-1]
}

image_preview_zoom_step :: proc(view: ^Image_Preview_View, rt: ^alicorn.Runtime, direction: int) -> bool {
	if view == nil || rt == nil { return false }
	current := view.effective_zoom if view.fit else view.zoom
	if current <= 0 { current = 1 }
	view.fit = false
	view.zoom = clamp(current*IMAGE_PREVIEW_ZOOM_STEP if direction > 0 else current/IMAGE_PREVIEW_ZOOM_STEP, IMAGE_PREVIEW_MIN_ZOOM, IMAGE_PREVIEW_MAX_ZOOM)
	alicorn.invalidate_root(rt, "image preview zoom changed")
	return true
}

image_preview_set_mode :: proc(view: ^Image_Preview_View, rt: ^alicorn.Runtime, fit: bool) -> bool {
	if view == nil || rt == nil { return false }
	view.fit = fit
	view.zoom = 1
	view.reset_scroll = true
	alicorn.invalidate_root(rt, "image preview sizing mode changed")
	return true
}

// Capture pan after input/layout and restore it after a tab's retained nodes
// are recreated. The runtime may retire inactive nodes between tab switches.
image_preview_after_frame :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil || app.image_scroll_owner == 0 { return }
	for &view in app.image_preview_views {
		if view.scroll_owner != app.image_scroll_owner { continue }
		if view.restore_scroll {
			_ = alicorn.scroll_region_set_offset_x(rt, view.scroll_owner, view.scroll_x, "restore image tab horizontal pan")
			_ = alicorn.scroll_region_set_offset(rt, view.scroll_owner, view.scroll_y, "restore image tab vertical pan")
			view.restore_scroll = false
		}
		scroll := alicorn.scroll_region_state(rt, view.scroll_owner)
		view.scroll_x, view.scroll_y = scroll.offset_x, scroll.offset_y
		return
	}
}

image_preview_handle_zoom_key :: proc(app: ^App, rt: ^alicorn.Runtime, key: host.Application_Key) -> bool {
	document, found := find_document(&app.backend.state, app.backend.state.active)
	if !found || document.view_kind != "image" { return false }
	view := image_preview_view_ensure(app, document.id)
	if key == .Zoom_Reset { return image_preview_set_mode(view, rt, false) }
	return image_preview_zoom_step(view, rt, 1 if key == .Zoom_In else -1)
}

scratchpad_image_preview_set_error :: proc(app: ^App, message: string) {
	if app == nil { return }
	if len(app.image_preview_error) > 0 { delete(app.image_preview_error, context.allocator) }
	app.image_preview_error = ""
	if len(message) > 0 { app.image_preview_error, _ = strings.clone(message, context.allocator) }
}

scratchpad_image_preview_retire_current :: proc(app: ^App) {
	if app == nil || app.image_preview_handle == 0 { return }
	append(&app.retired_brand_marks, Scratchpad_Image_Retirement{handle=app.image_preview_handle, after_build=app.asset_build_generation+1})
	app.image_preview_handle = 0
}

scratchpad_image_preview_sync :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil || !app.backend.started { return }
	for index := len(app.image_preview_views)-1; index >= 0; index -= 1 {
		view := app.image_preview_views[index]
		document, exists := find_document(&app.backend.state, view.document_id)
		if exists && document.view_kind == "image" { continue }
		delete(view.document_id, context.allocator)
		ordered_remove(&app.image_preview_views, index)
	}
	document, found := find_document(&app.backend.state, app.backend.state.active)
	if !found || document.view_kind != "image" {
		if app.image_preview_handle != 0 { scratchpad_image_preview_retire_current(app) }
		if len(app.image_preview_document_id) > 0 { delete(app.image_preview_document_id, context.allocator) }
		app.image_preview_document_id = ""
		app.image_preview_revision = 0
		app.image_preview_width = 0
		app.image_preview_height = 0
		scratchpad_image_preview_set_error(app, "")
		return
	}
	if app.image_preview_document_id == document.id && app.image_preview_revision == document.image_revision &&
	   (app.image_preview_handle != 0 || app.image_preview_error != "") { return }
	scratchpad_image_preview_retire_current(app)
	if len(app.image_preview_document_id) > 0 { delete(app.image_preview_document_id, context.allocator) }
	app.image_preview_document_id, _ = strings.clone(document.id, context.allocator)
	app.image_preview_revision = document.image_revision
	app.image_preview_width = int(document.image_width)
	app.image_preview_height = int(document.image_height)
	scratchpad_image_preview_set_error(app, document.view_error)
	if document.view_error != "" { return }
	if document.image_revision == 0 {
		scratchpad_image_preview_set_error(app, "The image preview revision is unavailable. Reopen the tab to retry.")
		return
	}
	response := bridge.backend_command(&app.backend, "read_image", document_id=document.id, image_revision=document.image_revision, read_latest_after=false)
	if !response.ok {
		message := response.message
		if message == "" { message = "Scratchpad could not read this image. Reopen the tab to retry." }
		scratchpad_image_preview_set_error(app, message)
		bridge.backend_command_result_destroy(&response, context.allocator)
		return
	}
	handle, decode_error := alicorn.image_load_bytes(rt, response.image_bytes)
	bridge.backend_command_result_destroy(&response, context.allocator)
	if decode_error != .None {
		message := "Scratchpad could not decode this image."
		switch decode_error {
		case .None: message = "Scratchpad could not decode this image."
		case .Empty_Input: message = "The image file is empty."
		case .Unsupported_Format: message = "Only PNG and QOI images can be previewed."
		case .Invalid_Header: message = "The image header is incomplete or invalid."
		case .Input_Too_Large: message = "Image exceeds the 128 MiB preview limit."
		case .Dimensions_Too_Large: message = "Image dimensions exceed the 64 MiB decoded preview limit."
		case .Decode_Failed: message = "The image data is invalid or incomplete."
		case .Unsupported_Pixel_Format: message = "This image uses an unsupported pixel format."
		case .Resource_Limit: message = "Scratchpad could not allocate image preview resources."
		case: message = "Scratchpad could not decode this image."
		}
		scratchpad_image_preview_set_error(app, message)
		return
	}
	app.image_preview_handle = handle
	if pixels, ok := alicorn.image_resolve(rt, handle); ok {
		app.image_preview_width = pixels.width
		app.image_preview_height = pixels.height
	} else {
		scratchpad_image_preview_set_error(app, "Scratchpad could not retain the decoded image.")
		return
	}
	scratchpad_image_preview_set_error(app, "")
}

build_image_preview :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime, document: bridge.State_Document, dpi_scale: f32) {
	if app == nil || ui == nil || rt == nil { return }
	view := image_preview_view_ensure(app, document.id)
	if view == nil { alicorn.text(ui, "Could not retain the image view."); return }
	// Use the retained viewport assigned by layout, including the actual split,
	// status bar, toolbar, padding and any recovery notice. A grow-based region
	// requests a follow-up description when its first layout/resize resolves.
	outer := alicorn.viewport_bounds(rt)
	if node, found := alicorn.node_info(rt, view.scroll_owner); found && node.active && node.bounds.w > 0 && node.bounds.h > 0 {
		outer = node.bounds
	} else {
		view.restore_scroll = true
	}
	dpi := dpi_scale if dpi_scale > 0 else 1
	base_width := max(f32(app.image_preview_width)/dpi, 1)
	base_height := max(f32(app.image_preview_height)/dpi, 1)
	zoom := view.zoom
	if view.fit { zoom = min(max(outer.w-2*IMAGE_PREVIEW_PADDING, 1)/base_width, max(outer.h-2*IMAGE_PREVIEW_PADDING, 1)/base_height, 1) }
	view.effective_zoom = zoom
	alicorn.container_begin(ui, .Container, label="image-preview-toolbar", style=alicorn.layout_style(.Row, height=IMAGE_PREVIEW_TOOLBAR_HEIGHT, gap=8, align=.Center))
	alicorn.text(ui, fmt.tprintf("%s · %d × %d · %s · Read-only", document_title(document.path), app.image_preview_width, app.image_preview_height, document.image_format), style=alicorn.layout_style(.Row, grow=1), text_style=alicorn.Text_Style{overflow=.Ellipsis})
	alicorn.text(ui, fmt.tprintf("%d%%", int(zoom*100+0.5)), style=alicorn.layout_style(.Row, width=48), text_style=alicorn.Text_Style{overflow=.Clip})
	if alicorn.button(ui, "−", key=alicorn.key_string("image-preview-zoom-out"), style=alicorn.layout_style(.Row, width=34, height=28), variant=.Toolbar) { _ = image_preview_zoom_step(view, rt, -1) }
	_ = alicorn.tooltip(ui, "Zoom out")
	if alicorn.button(ui, "Fit", key=alicorn.key_string("image-preview-fit"), style=alicorn.layout_style(.Row, width=52, height=28), state=alicorn.Button_State{selected=view.fit}, variant=.Toolbar) { _ = image_preview_set_mode(view, rt, true) }
	if alicorn.button(ui, "100%", key=alicorn.key_string("image-preview-zoom-100"), style=alicorn.layout_style(.Row, width=58, height=28), state=alicorn.Button_State{selected=!view.fit && view.zoom == 1}, variant=.Toolbar) { _ = image_preview_set_mode(view, rt, false) }
	if alicorn.button(ui, "+", key=alicorn.key_string("image-preview-zoom-in"), style=alicorn.layout_style(.Row, width=34, height=28), variant=.Toolbar) { _ = image_preview_zoom_step(view, rt, 1) }
	_ = alicorn.tooltip(ui, "Zoom in")
	alicorn.container_end(ui)
	if app.image_preview_error != "" || app.image_preview_handle == 0 {
		alicorn.container_begin(ui, .Container, label="image-preview-error-card", style=alicorn.layout_style(.Column, grow=1, align=.Center, justify=.Center, gap=8, padding=18))
		alicorn.text(ui, "Preview unavailable")
		alicorn.text(ui, app.image_preview_error if app.image_preview_error != "" else "Loading image preview…", text_style=alicorn.Text_Style{overflow=.Wrap})
		if alicorn.button(ui, "Retry", key=alicorn.key_string("image-preview-retry"), style=alicorn.layout_style(.Row, width=82, height=28)) {
			app.image_preview_revision = 0
			alicorn.invalidate_root(rt, "retry image preview")
		}
		alicorn.container_end(ui)
		return
	}
	image_width, image_height := base_width*zoom, base_height*zoom
	geometry := alicorn.scroll_bar_geometry(alicorn.Rect{0,0,outer.w,outer.h}, image_width+2*IMAGE_PREVIEW_PADDING, image_height+2*IMAGE_PREVIEW_PADDING, 0, .Both, .Auto)
	content_width := max(geometry.viewport.w, image_width+2*IMAGE_PREVIEW_PADDING)
	content_height := max(geometry.viewport.h, image_height+2*IMAGE_PREVIEW_PADDING)
	if view.reset_scroll {
		_ = alicorn.scroll_region_set_offset(rt, view.scroll_owner, 0)
		_ = alicorn.scroll_region_set_offset_x(rt, view.scroll_owner, 0)
		view.reset_scroll = false
		view.restore_scroll = false
		view.scroll_x, view.scroll_y = 0, 0
	}
	scroll := alicorn.scroll_region_begin(ui, key=alicorn.key_string(fmt.tprintf("image-preview-scroll-%s", document.id)), content_width=content_width, content_height=content_height, line_width=48, line_height=48, style=alicorn.layout_style(.Column, grow=1, clip=true), label="image-preview-scroll-region", axes=.Both, scrollbars=.Auto, focusable=true)
	view.scroll_owner = scroll.id
	app.image_scroll_owner = scroll.id
	// The scroll region owns input and scrollbar geometry. Its content wrapper
	// applies both retained offsets to the image; changing a thumb alone never
	// moves ordinary flow children. Virtual_List supplies that layout contract.
	alicorn.container_begin(ui, .Virtual_List, label="image-preview-canvas", style=alicorn.layout_style(.Row, width=content_width, height=content_height, align=.Center, justify=.Center), color=alicorn.style_color(ui, .Subtle_Surface), scroll_offset_x=scroll.offset_x, scroll_offset_y=scroll.offset_y)
	alt := fmt.tprintf("%s, %d by %d pixels", document_title(document.path), app.image_preview_width, app.image_preview_height)
	_ = alicorn.image(ui, app.image_preview_handle, alt_text=alt, key=alicorn.key_string("image-preview-image"), style=alicorn.layout_style(.Row, width=image_width, height=image_height))
	alicorn.container_end(ui)
	alicorn.scroll_region_end(ui)
}

build_unsupported_file_view :: proc(app: ^App, ui: ^alicorn.UI, document: bridge.State_Document) {
	if app == nil || ui == nil { return }
	reason := document.view_error if document.view_error != "" else "This file format isn't supported for preview."
	alicorn.container_begin(ui, .Container, label="unsupported-file-view", style=alicorn.layout_style(.Column, grow=1, align=.Center, justify=.Center))
	alicorn.container_begin(ui, .Container, label="unsupported-file-message", style=alicorn.layout_style(.Column, max_width=560, padding=18, gap=8), color=alicorn.style_color(ui, .Subtle_Surface))
	alicorn.text(ui, "Preview unavailable")
	alicorn.text(ui, reason, text_style=alicorn.Text_Style{overflow=.Wrap})
	alicorn.container_end(ui)
	alicorn.container_end(ui)
}

scratchpad_error_notice_fingerprint :: proc(message: string) -> u64 {
	if len(message) == 0 { return 0 }
	hash := u64(0xCBF29CE484222325)
	for index in 0..<len(message) {
		hash = (hash ~ u64(message[index])) * u64(0x100000001B3)
	}
	return hash
}

scratchpad_error_notice_sync :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil { return }
	fingerprint := scratchpad_error_notice_fingerprint(app.error_message)
	if app.error_notice_initialized && app.error_notice_fingerprint == fingerprint { return }
	app.error_notice_initialized = true
	app.error_notice_fingerprint = fingerprint
	if app.error_message == "" {
		if app.error_notice_active { _ = alicorn.notice_dismiss(rt, "scratchpad-operation-error") }
		app.error_notice_active = false
		return
	}
	details := app.error_message
	if len(details) > alicorn.NOTICE_DETAILS_MAX_BYTES {
		end := alicorn.NOTICE_DETAILS_MAX_BYTES
		for end > 0 && end < len(details) && u8(details[end])&0xC0 == 0x80 { end = end-1 }
		details = details[:end]
	}
	app.error_notice_active = alicorn.notice_post(rt, alicorn.Notice{
		id="scratchpad-operation-error",
		title="Operation needs attention",
		message="Scratchpad could not complete the requested operation.",
		details=details,
		severity=.Error,
		lifetime=.Persistent,
		placement=.Toast,
	}, 1)
}
