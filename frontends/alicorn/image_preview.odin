package main

import "core:fmt"
import "core:strings"
import alicorn "alicorn:runtime"
import gui "alicorn:ui"
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
	image_width, image_height: f32,
	zoom_anchor_x, zoom_anchor_y: f32,
	zoom_anchor_pending: bool,
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

image_preview_capture_zoom_anchor :: proc(view: ^Image_Preview_View, rt: ^alicorn.Runtime) {
	scroll := alicorn.scroll_region_state(rt,view.scroll_owner)
	view.zoom_anchor_x,view.zoom_anchor_y = 0.5,0.5
	if scroll.id != 0 && view.image_width > 0 && view.image_height > 0 {
		origin_x := (scroll.content_width-view.image_width)/2
		origin_y := (scroll.content_height-view.image_height)/2
		view.zoom_anchor_x = clamp((scroll.offset_x+scroll.viewport_width/2-origin_x)/view.image_width,0,1)
		view.zoom_anchor_y = clamp((scroll.offset_y+scroll.viewport_height/2-origin_y)/view.image_height,0,1)
	}
	view.zoom_anchor_pending = true
}

image_preview_zoom_step :: proc(view: ^Image_Preview_View, rt: ^alicorn.Runtime, direction: int) -> bool {
	if view == nil || rt == nil { return false }
	current := view.effective_zoom if view.fit else view.zoom
	if current <= 0 { current = 1 }
	image_preview_capture_zoom_anchor(view,rt)
	view.fit = false
	view.zoom = clamp(current*IMAGE_PREVIEW_ZOOM_STEP if direction > 0 else current/IMAGE_PREVIEW_ZOOM_STEP, IMAGE_PREVIEW_MIN_ZOOM, IMAGE_PREVIEW_MAX_ZOOM)
	alicorn.invalidate_root(rt, "image preview zoom changed")
	return true
}

image_preview_set_mode :: proc(view: ^Image_Preview_View, rt: ^alicorn.Runtime, fit: bool) -> bool {
	if view == nil || rt == nil { return false }
	if !fit { image_preview_capture_zoom_anchor(view,rt) }
	else { view.zoom_anchor_pending = false }
	view.fit = fit
	view.zoom = 1
	view.reset_scroll = fit
	alicorn.invalidate_root(rt, "image preview sizing mode changed")
	return true
}

// Capture pan after input/layout and restore it after a tab's retained nodes
// are recreated. The runtime may retire inactive nodes between tab switches.
image_preview_after_frame :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil || app.image_scroll_owner == 0 { return }
	for &view in app.image_preview_views {
		if view.scroll_owner != app.image_scroll_owner { continue }
		if view.zoom_anchor_pending {
			scroll := alicorn.scroll_region_state(rt,view.scroll_owner)
			x := (scroll.content_width-view.image_width)/2+view.zoom_anchor_x*view.image_width-scroll.viewport_width/2
			y := (scroll.content_height-view.image_height)/2+view.zoom_anchor_y*view.image_height-scroll.viewport_height/2
			_ = alicorn.scroll_region_set_offset_x(rt,view.scroll_owner,x,"preserve image center while zooming")
			_ = alicorn.scroll_region_set_offset(rt,view.scroll_owner,y,"preserve image center while zooming")
			view.zoom_anchor_pending = false; view.restore_scroll = false
		}
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
		if app.image_preview_loading { image_preview_lane_cancel(&app.image_preview_lane) }
		app.image_preview_loading = false; app.image_preview_generation = 0
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
	   (app.image_preview_handle != 0 || app.image_preview_error != "" || app.image_preview_loading) { return }
	image_preview_lane_cancel(&app.image_preview_lane)
	app.image_preview_loading = false
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
	if app.image_preview_lane.thread == nil {
		if !image_preview_lane_start(&app.image_preview_lane,&app.backend,app.waker.wake,app.waker.data) {
			scratchpad_image_preview_set_error(app,"Could not start the image preview worker.")
			return
		}
	}
	generation,accepted := image_preview_lane_request(&app.image_preview_lane,document.id,document.image_revision)
	if !accepted { scratchpad_image_preview_set_error(app,"Could not queue the image preview."); return }
	app.image_preview_generation = generation
	app.image_preview_loading = true
}

image_preview_decode_error_message :: proc(err: alicorn.Image_Load_Error) -> string {
	switch err {
	case .None: return ""
	case .Empty_Input: return "The image file is empty."
	case .Unsupported_Format: return "Only PNG and QOI images can be previewed."
	case .Invalid_Header: return "The image header is incomplete or invalid."
	case .Input_Too_Large: return "Image exceeds the 128 MiB preview limit."
	case .Dimensions_Too_Large: return "Image dimensions exceed the 64 MiB decoded preview limit."
	case .Decode_Failed: return "The image data is invalid or incomplete."
	case .Unsupported_Pixel_Format: return "This image uses an unsupported pixel format."
	case .Resource_Limit: return "Scratchpad could not allocate image preview resources."
	}
	return "Scratchpad could not decode this image."
}

image_preview_take_completion :: proc(app: ^App, rt: ^alicorn.Runtime) {
	result,found := image_preview_lane_take(&app.image_preview_lane)
	if !found { return }
	defer image_preview_result_destroy(&result,app.image_preview_lane.allocator)
	document,exists := find_document(&app.backend.state,app.backend.state.active)
	if !exists || document.view_kind != "image" || document.id != result.request.document_id || document.image_revision != result.request.revision || result.request.generation != app.image_preview_generation { return }
	app.image_preview_loading = false
	if result.error != "" { scratchpad_image_preview_set_error(app,result.error) }
	else {
		handle,err := alicorn.image_adopt_decoded(rt,&result.pixels)
		if err != .None { scratchpad_image_preview_set_error(app,image_preview_decode_error_message(err)) }
		else {
			scratchpad_image_preview_retire_current(app)
			app.image_preview_handle = handle
			pixels,_ := alicorn.image_resolve(rt,handle)
			app.image_preview_width,app.image_preview_height = pixels.width,pixels.height
			scratchpad_image_preview_set_error(app,"")
		}
	}
	alicorn.invalidate_root(rt,"image preview worker completed")
}

build_image_preview :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime, document: bridge.State_Document, dpi_scale: f32) {
	if app == nil || ui == nil || rt == nil { return }
	view := image_preview_view_ensure(app, document.id)
	if view == nil {
		gui.text(ui, "Could not retain the image view.")
		return
	}
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
	if gui.row(ui, label="image-preview-toolbar", height=IMAGE_PREVIEW_TOOLBAR_HEIGHT, gap=8, align=.Center) {
		gui.text(ui, fmt.tprintf("%s · %d × %d · %s · Read-only", document_title(document.path), app.image_preview_width, app.image_preview_height, document.image_format), style=alicorn.layout_style(.Row, grow=1), text_style=alicorn.Text_Style{overflow=.Ellipsis})
		if gui.row(ui, label="image-preview-zoom-controls", width=244, height=28, gap=4, align=.Center) {
			if gui.button(ui, "−", key="image-preview-zoom-out", width=32, height=28, variant=.Toolbar) {
				_ = image_preview_zoom_step(view, rt, -1)
			}
			_ = alicorn.tooltip(ui, "Zoom out")
			gui.text(ui, fmt.tprintf("%d%%", int(zoom*100+0.5)), style=alicorn.layout_style(.Row, width=48), text_style=alicorn.Text_Style{overflow=.Clip})
			if gui.button(ui, "+", key="image-preview-zoom-in", width=32, height=28, variant=.Toolbar) {
				_ = image_preview_zoom_step(view, rt, 1)
			}
			_ = alicorn.tooltip(ui, "Zoom in")
			if gui.button(ui, "Fit", key="image-preview-fit", width=48, height=28, state=alicorn.Button_State{selected=view.fit}, variant=.Toolbar) {
				_ = image_preview_set_mode(view, rt, true)
			}
			if gui.button(ui, "100%", key="image-preview-zoom-100", width=58, height=28, state=alicorn.Button_State{selected=!view.fit && view.zoom == 1}, variant=.Toolbar) {
				_ = image_preview_set_mode(view, rt, false)
			}
		}
	}
	if app.image_preview_error != "" || app.image_preview_handle == 0 {
		if gui.column(ui, label="image-preview-error-card", height=-1, grow=1, align=.Center, justify=.Center, gap=8, padding=18) {
			gui.text(ui, "Loading image preview…" if app.image_preview_loading else "Preview unavailable")
			if app.image_preview_error != "" { gui.text(ui, app.image_preview_error, text_style=alicorn.Text_Style{overflow=.Wrap}) }
			if !app.image_preview_loading && gui.button(ui, "Retry", key="image-preview-retry", width=82, height=28) {
				app.image_preview_revision = 0
				alicorn.invalidate_root(rt, "retry image preview")
			}
		}
		return
	}
	// Toolbar activations change the view during description. Apply the new
	// scale to this frame before resolving the center anchor after layout.
	zoom = view.zoom
	if view.fit { zoom = min(max(outer.w-2*IMAGE_PREVIEW_PADDING,1)/base_width,max(outer.h-2*IMAGE_PREVIEW_PADDING,1)/base_height,1) }
	view.effective_zoom = zoom
	image_width, image_height := base_width*zoom, base_height*zoom
	view.image_width,view.image_height = image_width,image_height
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
	alicorn.container_begin(ui, .Virtual_List, label="image-preview-canvas", style=alicorn.layout_style(.Row, width=content_width, height=content_height, align=.Center, justify=.Center), color=image_preview_canvas_color(ui), scroll_offset_x=scroll.offset_x, scroll_offset_y=scroll.offset_y)
	alt := fmt.tprintf("%s, %d by %d pixels", document_title(document.path), app.image_preview_width, app.image_preview_height)
	_ = alicorn.image(ui, app.image_preview_handle, alt_text=alt, key=alicorn.key_string("image-preview-image"), style=alicorn.layout_style(.Row, width=image_width, height=image_height))
	alicorn.container_end(ui)
	alicorn.scroll_region_end(ui)
}

image_preview_canvas_color :: proc(ui: ^alicorn.UI) -> alicorn.Color {
	surface := alicorn.style_color(ui,.Subtle_Surface)
	neutral := (surface.r+surface.g+surface.b)/3*0.88
	return alicorn.Color{neutral,neutral,neutral,1}
}

build_unsupported_file_view :: proc(app: ^App, ui: ^alicorn.UI, document: bridge.State_Document) {
	if app == nil || ui == nil { return }
	reason := document.view_error if document.view_error != "" else "This file format isn't supported for preview."
	if gui.column(ui, label="unsupported-file-view", height=-1, grow=1, align=.Center, justify=.Center) {
		alicorn.container_begin(ui, .Container, label="unsupported-file-message", style=alicorn.layout_style(.Column, max_width=560, padding=18, gap=8), color=alicorn.style_color(ui, .Subtle_Surface))
		gui.text(ui, "Preview unavailable")
		gui.text(ui, reason, text_style=alicorn.Text_Style{overflow=.Wrap})
		alicorn.container_end(ui)
	}
}

scratchpad_error_notice_fingerprint :: proc(message: string, style_environment: alicorn.Style_Environment) -> u64 {
	if len(message) == 0 { return 0 }
	hash := u64(0xCBF29CE484222325)
	for index in 0..<len(message) {
		hash = (hash ~ u64(message[index])) * u64(0x100000001B3)
	}
	hash = (hash ~ u64(u32(style_environment.theme))) * u64(0x100000001B3)
	hash = (hash ~ u64(transmute(u32)style_environment.density)) * u64(0x100000001B3)
	hash = (hash ~ u64(transmute(u32)style_environment.text_scale)) * u64(0x100000001B3)
	hash = (hash ~ u64(u32(style_environment.accent))) * u64(0x100000001B3)
	if style_environment.accessibility_set { hash = (hash ~ 1) * u64(0x100000001B3) }
	if style_environment.accessibility.increased_contrast { hash = (hash ~ 2) * u64(0x100000001B3) }
	if style_environment.accessibility.reduce_motion { hash = (hash ~ 3) * u64(0x100000001B3) }
	if style_environment.accessibility.reduce_transparency { hash = (hash ~ 4) * u64(0x100000001B3) }
	if style_environment.accessibility.differentiate_without_color { hash = (hash ~ 5) * u64(0x100000001B3) }
	return hash
}

scratchpad_error_notice_sync :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil { return }
	style_environment := scratchpad_workbench_style_environment(app)
	fingerprint := scratchpad_error_notice_fingerprint(app.error_message, style_environment)
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
	message := app.error_message
	if len(message) > alicorn.NOTICE_MESSAGE_MAX_BYTES {
		end := alicorn.NOTICE_MESSAGE_MAX_BYTES
		for end > 0 && end < len(message) && u8(message[end])&0xC0 == 0x80 { end -= 1 }
		message = message[:end]
	}
	app.error_notice_active = alicorn.notice_post(rt, alicorn.Notice{
		id="scratchpad-operation-error",
		title="Operation needs attention",
		message=message,
		details=details,
		severity=.Error,
		lifetime=.Persistent,
		placement=.Toast,
		style_environment=style_environment,
	}, 1)
}
