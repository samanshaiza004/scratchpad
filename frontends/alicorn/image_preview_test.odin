package main

import "core:testing"
import "core:fmt"
import alicorn "alicorn:runtime"
import bridge "./bridge"

image_preview_test_document :: proc(id := "fixture-image") -> bridge.State_Document {
	return bridge.State_Document{id=id, path="fixture.png", view_kind="image", image_format="PNG", image_width=1600, image_height=900}
}

image_preview_test_build :: proc(app: ^App, rt: ^alicorn.Runtime, document: bridge.State_Document, dpi := f32(1)) {
	_ = alicorn.set_presentation_scale(rt, dpi, dpi)
	for pass in 0..<3 {
		alicorn.invalidate_root(rt, "settle image viewer fixture")
		ui, build := alicorn.begin_frame(rt)
		if !build { return }
		alicorn.container_begin(&ui, .Root, key=alicorn.key_string("image-viewer-test-root"), style=alicorn.layout_style(.Column, padding=12, gap=6, clip=true))
		if alicorn.component_begin(&ui, alicorn.key_string(document.id)) {
			build_image_preview(app, &ui, rt, document, dpi)
			alicorn.component_end(&ui)
		}
		alicorn.container_end(&ui)
		alicorn.end_frame(&ui)
		image_preview_after_frame(app, rt)
	}
}

image_preview_test_bounds :: proc(rt: ^alicorn.Runtime) -> alicorn.Rect {
	for draw in rt.display {
		if _, image := draw.payload.(alicorn.Image_Paint); image { return draw.bounds }
	}
	return {}
}

@(test)
test_image_preview_fit_uses_assigned_viewport_and_actual_pixel_zoom :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0,0,1000,680})
	defer alicorn.destroy_runtime(&rt)
	handle, err := alicorn.image_load_bytes(&rt, SCRATCHPAD_WARM_MARK_DATA)
	testing.expect(t, err == .None, "fixture image should load")
	if err != .None { return }
	app := App{image_preview_handle=handle, image_preview_width=1600, image_preview_height=900}
	defer image_preview_views_destroy(&app)
	document := image_preview_test_document()
	image_preview_test_build(&app, &rt, document)
	view := image_preview_view_ensure(&app, document.id)
	scroll := alicorn.scroll_region_state(&rt, view.scroll_owner)
	bounds := image_preview_test_bounds(&rt)
	testing.expect(t, bounds.w <= scroll.viewport_width-31 && bounds.h <= scroll.viewport_height-31 && !scroll.vertical_bar_visible && !scroll.horizontal_bar_visible,
		"Fit should use the assigned viewport and need no scrollbars")
	fit_zoom := view.effective_zoom
	_ = image_preview_zoom_step(view, &rt, 1)
	testing.expect(t, !view.fit && abs(view.zoom-fit_zoom*IMAGE_PREVIEW_ZOOM_STEP) < 0.001,
		"zooming from Fit should start at the displayed scale")
	_ = image_preview_set_mode(view, &rt, false)
	image_preview_test_build(&app, &rt, document, 1.5)
	bounds = image_preview_test_bounds(&rt)
	testing.expect(t, abs(bounds.w*1.5-1600) < 0.1 && abs(bounds.h*1.5-900) < 0.1,
		fmt.tprintf("100 percent physical pixels: bounds=%v dpi=1.5 zoom=%v", bounds, view.zoom))
	rt.viewport = alicorn.Rect{0,0,560,420}
	_ = image_preview_set_mode(view, &rt, true)
	image_preview_test_build(&app, &rt, document, 1.5)
	scroll = alicorn.scroll_region_state(&rt, view.scroll_owner)
	bounds = image_preview_test_bounds(&rt)
	testing.expect(t, bounds.w <= scroll.viewport_width && bounds.h <= scroll.viewport_height && !scroll.vertical_bar_visible && !scroll.horizontal_bar_visible,
		"Fit should converge after a narrower/shorter layout without guessing sidebar dimensions")
}

@(test)
test_image_preview_wheel_and_scrollbar_drag_move_image_and_reset_fit :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0,0,700,460})
	defer alicorn.destroy_runtime(&rt)
	handle, err := alicorn.image_load_bytes(&rt, SCRATCHPAD_WARM_MARK_DATA)
	if err != .None { testing.expect(t, false, "fixture should load"); return }
	app := App{image_preview_handle=handle, image_preview_width=1600, image_preview_height=900}
	defer image_preview_views_destroy(&app)
	document := image_preview_test_document()
	view := image_preview_view_ensure(&app, document.id)
	_ = image_preview_set_mode(view, &rt, false)
	image_preview_test_build(&app, &rt, document)
	original := image_preview_test_bounds(&rt)
	scroll := alicorn.scroll_region_state(&rt, view.scroll_owner)
	initial_offset_x := scroll.offset_x
	testing.expect(t, scroll.max_scroll_x > 0 && scroll.max_scroll_y > 0, "100 percent should expose both overflow axes")
	_ = alicorn.process_scroll(&rt, alicorn.Scroll_Event{x=scroll.viewport_bounds.x+40,y=scroll.viewport_bounds.y+40,delta_y=-2})
	image_preview_test_build(&app, &rt, document)
	after_wheel := image_preview_test_bounds(&rt)
	testing.expect(t, abs(after_wheel.y-(original.y-96)) < 0.1, "wheel input must move the image by the retained offset, not only the thumb")
	node, found := rt.nodes[view.scroll_owner]
	if found {
		thumb := node.scrollbar_horizontal_thumb
		_ = alicorn.process_pointer(&rt, alicorn.Pointer_Event{kind=.Down,button=1,x=thumb.x+thumb.w/2,y=thumb.y+thumb.h/2})
		_ = alicorn.process_pointer(&rt, alicorn.Pointer_Event{kind=.Move,button=1,x=thumb.x+thumb.w/2+80,y=thumb.y+thumb.h/2})
		_ = alicorn.process_pointer(&rt, alicorn.Pointer_Event{kind=.Up,button=1,x=thumb.x+thumb.w/2+80,y=thumb.y+thumb.h/2})
	}
	image_preview_test_build(&app, &rt, document)
	scroll = alicorn.scroll_region_state(&rt, view.scroll_owner)
	after_drag := image_preview_test_bounds(&rt)
	testing.expect(t, scroll.offset_x > 0 && abs(after_drag.x-(original.x-(scroll.offset_x-initial_offset_x))) <= 0.51,
		fmt.tprintf("horizontal thumb pan: original=%v after=%v scroll=%v", original, after_drag, scroll))
	_ = image_preview_set_mode(view, &rt, true)
	image_preview_test_build(&app, &rt, document)
	scroll = alicorn.scroll_region_state(&rt, view.scroll_owner)
	testing.expect(t, scroll.offset_x == 0 && scroll.offset_y == 0 && !scroll.vertical_bar_visible && !scroll.horizontal_bar_visible,
		"Fit must reset stale pan offsets and remove both thumbs")
}

@(test)
test_image_preview_retains_zoom_and_pan_when_switching_tabs :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0,0,700,460})
	defer alicorn.destroy_runtime(&rt)
	handle, err := alicorn.image_load_bytes(&rt, SCRATCHPAD_WARM_MARK_DATA)
	if err != .None { testing.expect(t, false, "fixture should load"); return }
	app := App{image_preview_handle=handle, image_preview_width=1600, image_preview_height=900}
	defer image_preview_views_destroy(&app)
	first, second := image_preview_test_document("first"), image_preview_test_document("second")
	view := image_preview_view_ensure(&app, first.id)
	view.fit = false; view.zoom = 2
	image_preview_test_build(&app, &rt, first)
	_ = alicorn.scroll_region_set_offset(&rt, view.scroll_owner, 123)
	_ = alicorn.scroll_region_set_offset_x(&rt, view.scroll_owner, 234)
	image_preview_test_build(&app, &rt, first)
	before := image_preview_test_bounds(&rt)
	image_preview_test_build(&app, &rt, second)
	image_preview_test_build(&app, &rt, first)
	view = image_preview_view_ensure(&app, first.id)
	testing.expect(t, !view.fit && view.zoom == 2 && image_preview_test_bounds(&rt) == before,
		fmt.tprintf("tab restore: before=%v after=%v fit=%v zoom=%v scroll=%v", before, image_preview_test_bounds(&rt), view.fit, view.zoom, alicorn.scroll_region_state(&rt, view.scroll_owner)))
}

@(test)
test_image_preview_disables_text_only_native_menu_actions :: proc(t: ^testing.T) {
	document := image_preview_test_document()
	documents := [1]bridge.State_Document{document}
	app := App{}
	app.backend.state.active = document.id
	app.backend.state.documents = documents[:]
	init_menus(&app)
	sync_menu_states(&app)
	for item in app.document_items {
		if item.kind != .Command { continue }
		if item.command == action_id_for(ACTION_DOCUMENT_GO_TO_LINE) || item.command == action_id_for(ACTION_DOCUMENT_TOGGLE_WRAP) {
			testing.expect(t, !item.state.enabled, "image tabs should disable Go to Line and Word Wrap")
		}
	}
	for item in app.edit_items {
		if item.kind == .Command && item.command == action_id_for(ACTION_EDIT_DELETE_LINE) {
			testing.expect(t, !item.state.enabled, "image tabs should disable native Delete Line")
		}
	}
}

@(test)
test_image_preview_native_zoom_command_targets_image_not_text :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0,0,700,460})
	defer alicorn.destroy_runtime(&rt)
	document := image_preview_test_document()
	documents := [1]bridge.State_Document{document}
	app := App{editor_text_scale=1}
	app.backend.state.active = document.id
	app.backend.state.documents = documents[:]
	defer image_preview_views_destroy(&app)
	view := image_preview_view_ensure(&app, document.id)
	view.effective_zoom = 0.5
	application_menu_command(rawptr(&app), &rt, action_id_for(ACTION_VIEW_EDITOR_ZOOM_IN))
	testing.expect(t, !view.fit && view.zoom == 0.625 && app.editor_text_scale == 1,
		"native View zoom commands should zoom the active image without changing editor typography")
	application_menu_command(rawptr(&app), &rt, action_id_for(ACTION_VIEW_EDITOR_ZOOM_RESET))
	testing.expect(t, view.zoom == 1 && view.zoom_anchor_pending, "native Reset Zoom should restore image pixel size and reset pan")
}

@(test)
test_image_preview_zoom_preserves_source_at_viewport_center :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0,0,700,460})
	defer alicorn.destroy_runtime(&rt)
	handle,err := alicorn.image_load_bytes(&rt,SCRATCHPAD_WARM_MARK_DATA)
	if err != .None { testing.expect(t,false,"fixture should decode"); return }
	app := App{image_preview_handle=handle,image_preview_width=1600,image_preview_height=900}
	defer image_preview_views_destroy(&app)
	doc := image_preview_test_document()
	view := image_preview_view_ensure(&app,doc.id)
	_ = image_preview_set_mode(view,&rt,false)
	image_preview_test_build(&app,&rt,doc)
	_ = alicorn.scroll_region_set_offset_x(&rt,view.scroll_owner,300)
	_ = alicorn.scroll_region_set_offset(&rt,view.scroll_owner,200)
	image_preview_test_build(&app,&rt,doc)
	before := alicorn.scroll_region_state(&rt,view.scroll_owner)
	x := (before.offset_x+before.viewport_width/2-(before.content_width-view.image_width)/2)/view.image_width
	y := (before.offset_y+before.viewport_height/2-(before.content_height-view.image_height)/2)/view.image_height
	for id,node in rt.nodes {
		if node.kind == .Button && node.label == "+" {
			_ = alicorn.focus(&rt,id)
			_ = alicorn.activate_focused(&rt,.Enter)
			break
		}
	}
	image_preview_test_build(&app,&rt,doc)
	after := alicorn.scroll_region_state(&rt,view.scroll_owner)
	x_after := (after.offset_x+after.viewport_width/2-(after.content_width-view.image_width)/2)/view.image_width
	y_after := (after.offset_y+after.viewport_height/2-(after.content_height-view.image_height)/2)/view.image_height
	testing.expect(t,abs(x_after-x)<0.001 && abs(y_after-y)<0.001,"zoom should preserve the source point at the viewport center")
}
