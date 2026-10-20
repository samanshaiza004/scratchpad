package main

import "core:testing"
import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"
import bridge "./bridge"

tab_detach_test_open :: proc(data: rawptr, description: host.Application_Window_Description) -> bool {
	requests := cast(^int)data
	requests^ += 1
	// Reject the request after observing it so this test needs no native window.
	return false
}

// Exercise the retained drag and application callback together: a preview box
// alone does not prove that an outside release reaches the window service.
@(test)
test_tab_drag_release_outside_requests_window :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 640, 480})
	defer alicorn.destroy_runtime(&rt)
	documents := [?]bridge.State_Document{{id="detached-document", path="document.txt", view_kind="text"}}
	app := App{}
	app.backend.started = true
	app.backend.state.documents = documents[:]
	app.backend.state.active = documents[0].id
	defer workspace_drag_clear(&app)
	requests := 0
	app.services.windows = host.Application_Window_Service{data=rawptr(&requests), open=tab_detach_test_open}
	ui, should_build := alicorn.begin_frame(&rt)
	if !should_build { testing.expect(t, false, "the tab should be described"); return }
	alicorn.container_begin_simple(&ui, .Root, style=alicorn.layout_style(.Row, width=640, height=480))
	tab, _ := alicorn.button_ex(&ui, "document.txt", key="detach-test-tab", style=alicorn.layout_style(width=160, height=40))
	_ = alicorn.drag_source(&ui, SCRATCHPAD_DRAG_TABS, document_tab_semantic_id(documents[0].id))
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
	node, found := alicorn.node_info(&rt, tab)
	if !found { testing.expect(t, false, "the draggable tab should be retained"); return }
	x := node.bounds.x+10
	y := node.bounds.y+10
	_ = alicorn.process_pointer(&rt, alicorn.Pointer_Event{kind=.Down, x=x, y=y, button=alicorn.POINTER_BUTTON_PRIMARY})
	_ = alicorn.process_pointer(&rt, alicorn.Pointer_Event{kind=.Move, x=650, y=y})
	started, pending := alicorn.drag_event_take(&rt)
	testing.expect(t, pending && started.kind == .Started, "the drag must cross the threshold")
	application_drag(rawptr(&app), &rt, started)
	testing.expect(t, app.workspace_drag_source_document_id == documents[0].id, "drag start should retain the logical document identity")
	_ = alicorn.process_pointer(&rt, alicorn.Pointer_Event{kind=.Up, x=650, y=y, button=alicorn.POINTER_BUTTON_PRIMARY})
	released, released_pending := alicorn.drag_event_take(&rt)
	testing.expect(t, released_pending && released.kind == .Cancelled && released.has_pointer_position && released.pointer_x == 650,
		"an outside release must preserve logical pointer coordinates for tear-off")
	application_drag(rawptr(&app), &rt, released)
	testing.expect(t, requests == 1, "releasing a tab outside the window must request a floating document window")
	testing.expect(t, app.workspace_drag_kind == .None && app.workspace_drag_source_document_id == "", "release must clear the drag source even if the host rejects the request")
	// Escape/focus cancellation has no release position and must not detach.
	application_drag(rawptr(&app), &rt, started)
	application_drag(rawptr(&app), &rt, alicorn.Drag_Event{kind=.Cancelled})
	testing.expect(t, requests == 1, "cancelling a drag without an outside release must not open a window")
}
