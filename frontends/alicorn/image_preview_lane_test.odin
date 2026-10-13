package main

import "core:mem"
import "core:os"
import "core:fmt"
import "core:sync"
import "core:testing"
import "core:time"
import alicorn "alicorn:runtime"
import bridge "./bridge"

Image_Preview_Test_Gate :: struct { entered,release,completed: sync.Sema, wake_count: int }
image_preview_test_gate: ^Image_Preview_Test_Gate

image_preview_test_read :: proc(backend: ^bridge.Backend, id: string, revision,generation: u64, allocator: mem.Allocator) -> bridge.Backend_Command_Result {
	gate := image_preview_test_gate
	sync.sema_post(&gate.entered)
	sync.sema_wait(&gate.release)
	data,_ := make([]u8,len(SCRATCHPAD_WARM_MARK_DATA),allocator)
	copy(data,SCRATCHPAD_WARM_MARK_DATA)
	return bridge.Backend_Command_Result{ok=true,image_bytes=data,image_bytes_owned=true}
}
image_preview_test_wake :: proc(data: rawptr) {
	gate := cast(^Image_Preview_Test_Gate)data
	sync.atomic_add(&gate.wake_count,1)
	sync.sema_post(&gate.completed)
}

@(test)
test_image_worker_is_bounded_and_suppresses_superseded_results :: proc(t: ^testing.T) {
	gate: Image_Preview_Test_Gate
	image_preview_test_gate = &gate
	backend := bridge.Backend{started=true}
	lane := Image_Preview_Lane{read=image_preview_test_read}
	testing.expect(t,image_preview_lane_start(&lane,&backend,image_preview_test_wake,rawptr(&gate)),"worker should start")
	defer {
		sync.sema_post(&gate.release); sync.sema_post(&gate.release)
		_ = image_preview_lane_stop(&lane)
		image_preview_test_gate = nil
	}
	first,accepted := image_preview_lane_request(&lane,"old",1)
	testing.expect(t,accepted && sync.sema_wait_with_timeout(&gate.entered,2*time.Second),"slow read should run on the worker")
	same,accepted_same := image_preview_lane_request(&lane,"old",1)
	testing.expect(t,accepted_same && same == first && lane.submitted == 1,"rebuilds should not enqueue duplicate active reads")
	_,_ = image_preview_lane_request(&lane,"replaced",1)
	last,_ := image_preview_lane_request(&lane,"new",2)
	sync.mutex_lock(&lane.mutex)
	bounded := lane.active && lane.pending && lane.pending_request.document_id == "new"
	sync.mutex_unlock(&lane.mutex)
	testing.expect(t,bounded,"rapid tab switching should retain only one active and one latest pending request")
	sync.sema_post(&gate.release)
	testing.expect(t,sync.sema_wait_with_timeout(&gate.entered,2*time.Second),"latest pending job should follow the cancelled read")
	sync.sema_post(&gate.release)
	testing.expect(t,sync.sema_wait_with_timeout(&gate.completed,2*time.Second),"only the latest completion should wake the UI")
	result,found := image_preview_lane_take(&lane)
	defer image_preview_result_destroy(&result,lane.allocator)
	testing.expect(t,found && result.request.document_id == "new" && result.request.revision == 2 && result.request.generation == last && len(result.pixels.rgba8)>0,"completion must be tagged with the latest identity/revision and own decoded pixels")
	testing.expect(t,sync.atomic_load(&gate.wake_count) == 1 && lane.discarded == 1,"stale reads must be discarded without waking or decoding into the Runtime")
}

@(test)
test_image_worker_cancel_and_shutdown_release_work_without_polling :: proc(t: ^testing.T) {
	gate: Image_Preview_Test_Gate
	image_preview_test_gate = &gate
	backend := bridge.Backend{started=true}
	lane := Image_Preview_Lane{read=image_preview_test_read}
	testing.expect(t,image_preview_lane_start(&lane,&backend,image_preview_test_wake,rawptr(&gate)),"worker should start")
	defer { sync.sema_post(&gate.release); _ = image_preview_lane_stop(&lane); image_preview_test_gate=nil }
	_,_ = image_preview_lane_request(&lane,"closing",1)
	testing.expect(t,sync.sema_wait_with_timeout(&gate.entered,2*time.Second),"fixture read should enter its gate")
	image_preview_lane_cancel(&lane)
	sync.sema_post(&gate.release)
	testing.expect(t,image_preview_lane_stop(&lane) && lane.thread == nil && !lane.completed_ready && sync.atomic_load(&gate.wake_count) == 0,"closing during a slow read must discard its result, join the worker, and post no periodic wake")
}

@(test)
test_image_worker_decode_reports_corrupt_png_and_qoi :: proc(t: ^testing.T) {
	corrupt := [2][]u8{[]u8{0x89,'P','N','G',13,10,26,10},[]u8{'q','o','i','f',0,0,0,1,0,0,0,1,4,0}}
	for bytes in corrupt {
		pixels,err := image_preview_worker_decode(bytes,context.allocator)
		defer alicorn.image_decoded_destroy(&pixels)
		testing.expect(t,err != .None && len(pixels.rgba8) == 0,"corrupt input should return a bounded error without leaking a partial decoded image")
	}
}

image_preview_test_large_qoi :: proc() -> [dynamic]u8 {
	bytes := make([dynamic]u8,0,300_000,allocator=context.allocator)
	append(&bytes,'q','o','i','f',0,0,0x10,0,0,0,0x10,0,4,0,0xff,128,96,180,255)
	remaining := 4096*4096-1
	for remaining > 0 {
		count := min(remaining,62)
		append(&bytes,u8(0xc0+count-1))
		remaining -= count
	}
	append(&bytes,0,0,0,0,0,0,0,1)
	return bytes
}

@(test)
test_image_preview_real_bridge_large_image_close_reopen_and_theme_switch :: proc(t: ^testing.T) {
	sync.mutex_lock(&backend_integration_test_mutex)
	defer sync.mutex_unlock(&backend_integration_test_mutex)
	workspace,err := os.make_directory_temp("","scratchpad-image-worker-*",context.temp_allocator)
	if err != nil { testing.expect(t,false,"fixture workspace should be created"); return }
	defer _ = os.remove_all(workspace)
	png_path := fmt.tprintf("%s/preview.png",workspace)
	large_path := fmt.tprintf("%s/large.qoi",workspace)
	if write_err := os.write_entire_file(png_path,SCRATCHPAD_WARM_MARK_DATA); write_err != nil { testing.expect(t,false,"PNG fixture should be written"); return }
	encoded := image_preview_test_large_qoi()
	defer delete(encoded)
	if write_err := os.write_entire_file(large_path,encoded[:]); write_err != nil { testing.expect(t,false,"large QOI fixture should be written"); return }
	library,found := os.lookup_env("SCRATCHPAD_BACKEND_LIBRARY",context.temp_allocator)
	if !found { testing.expect(t,false,"integration test needs its staged backend"); return }
	defer delete(library,context.temp_allocator)
	app: App
	rt := alicorn.new_runtime(alicorn.Rect{0,0,700,460})
	defer {
		_ = image_preview_lane_stop(&app.image_preview_lane)
		if app.backend.started { _,_ = bridge.backend_stop(&app.backend,context.allocator) }
		image_preview_views_destroy(&app)
		if app.image_preview_document_id != "" { delete(app.image_preview_document_id,context.allocator) }
		if app.image_preview_error != "" { delete(app.image_preview_error,context.allocator) }
		delete(app.retired_brand_marks)
		alicorn.destroy_runtime(&rt)
	}
	loaded,load_message := bridge.backend_load(&app.backend,library)
	testing.expect(t,loaded,load_message)
	if !loaded { return }
	started,start_message := bridge.backend_start(&app.backend,workspace,tree_test_wake,nil,context.allocator)
	testing.expect(t,started,start_message)
	if !started { return }
	signal: Image_Preview_Test_Gate
	testing.expect(t,image_preview_lane_start(&app.image_preview_lane,&app.backend,image_preview_test_wake,rawptr(&signal)),"real image lane should start")
	opened := bridge.backend_command(&app.backend,"open_path",path=png_path)
	testing.expect(t,opened.ok,opened.message)
	bridge.backend_command_result_destroy(&opened,context.allocator)
	scratchpad_image_preview_sync(&app,&rt)
	testing.expect(t,app.image_preview_loading,"UI sync should queue work and return a loading state")
	testing.expect(t,sync.sema_wait_with_timeout(&signal.completed,5*time.Second),"real PNG read/decode should wake exactly on completion")
	image_preview_take_completion(&app,&rt)
	handle := app.image_preview_handle
	testing.expect(t,handle != 0 && app.image_preview_error == "" && app.backend.resource_leases == 0,"Caliber bytes should be released before adopting PNG pixels")
	submitted := app.image_preview_lane.submitted
	app.theme_choice = .Warm
	_ = scratchpad_styles_ensure(&app,&rt)
	app.theme_choice = .Cool_Light
	_ = scratchpad_styles_ensure(&app,&rt)
	scratchpad_image_preview_sync(&app,&rt)
	testing.expect(t,app.image_preview_handle == handle && app.image_preview_lane.submitted == submitted,"theme changes should retain pixels and schedule no image reload")
	closed := bridge.backend_command(&app.backend,"close_document",document_id=app.backend.state.active)
	testing.expect(t,closed.ok,closed.message)
	bridge.backend_command_result_destroy(&closed,context.allocator)
	scratchpad_image_preview_sync(&app,&rt)
	testing.expect(t,app.image_preview_handle == 0 && !app.image_preview_loading,"close should retire the preview and cancel its work")
	reopened := bridge.backend_command(&app.backend,"open_path",path=png_path)
	testing.expect(t,reopened.ok,reopened.message)
	bridge.backend_command_result_destroy(&reopened,context.allocator)
	scratchpad_image_preview_sync(&app,&rt)
	testing.expect(t,sync.sema_wait_with_timeout(&signal.completed,5*time.Second),"reopened image should decode asynchronously")
	image_preview_take_completion(&app,&rt)
	testing.expect(t,app.image_preview_handle != 0 && app.image_preview_handle != handle,"reopen should install a fresh owned resource")
	opened = bridge.backend_command(&app.backend,"open_path",path=large_path)
	testing.expect(t,opened.ok,opened.message)
	bridge.backend_command_result_destroy(&opened,context.allocator)
	scratchpad_image_preview_sync(&app,&rt)
	testing.expect(t,sync.sema_wait_with_timeout(&signal.completed,10*time.Second),"a 64 MiB decoded image should finish on the worker")
	image_preview_take_completion(&app,&rt)
	pixels,present := alicorn.image_resolve(&rt,app.image_preview_handle)
	testing.expect(t,present && pixels.width == 4096 && pixels.height == 4096 && len(pixels.rgba8) == 64*1024*1024 && app.backend.resource_leases == 0,"large decode/adoption should preserve dimensions and release all Caliber leases")
}

@(test)
test_image_worker_restart_clears_obsolete_wake_ticket :: proc(t: ^testing.T) {
	gate: Image_Preview_Test_Gate
	image_preview_test_gate = &gate
	backend := bridge.Backend{started=true}
	lane := Image_Preview_Lane{read=image_preview_test_read}
	testing.expect(t,image_preview_lane_start(&lane,&backend,image_preview_test_wake,rawptr(&gate)),"worker should start")
	_ = image_preview_lane_stop(&lane)
	// Stopping before a pending wake is consumed may leave its coalescing
	// flag set. A fresh semaphore must not inherit that obsolete ticket.
	lane.wake_posted = true
	testing.expect(t,image_preview_lane_start(&lane,&backend,image_preview_test_wake,rawptr(&gate)),"worker should restart")
	defer { sync.sema_post(&gate.release); _ = image_preview_lane_stop(&lane); image_preview_test_gate=nil }
	_,accepted := image_preview_lane_request(&lane,"restarted",1)
	testing.expect(t,accepted && sync.sema_wait_with_timeout(&gate.entered,2*time.Second),"restarted worker should receive its first request")
	sync.sema_post(&gate.release)
	testing.expect(t,sync.sema_wait_with_timeout(&gate.completed,2*time.Second),"restarted worker should publish its completion")
	result,found := image_preview_lane_take(&lane)
	defer image_preview_result_destroy(&result,lane.allocator)
	testing.expect(t,found && result.request.document_id == "restarted","completion should belong to the new worker session")
}
