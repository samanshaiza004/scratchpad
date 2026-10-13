package main

import "core:mem"
import "core:strings"
import "core:sync"
import "core:thread"
import alicorn "alicorn:runtime"
import bridge "./bridge"

Image_Preview_Request :: struct { document_id: string, revision, generation: u64 }
Image_Preview_Result :: struct { request: Image_Preview_Request, pixels: alicorn.Image_Decoded, error: string }
Image_Preview_Read_Proc :: #type proc(^bridge.Backend,string,u64,u64,mem.Allocator) -> bridge.Backend_Command_Result
Image_Preview_Lane :: struct {
	backend: ^bridge.Backend,
	wake: bridge.Application_Wake_Proc,
	wake_data: rawptr,
	allocator: mem.Allocator,
	read: Image_Preview_Read_Proc,
	mutex: sync.Mutex,
	sema: sync.Sema,
	thread: ^thread.Thread,
	stopping: bool,
	pending, active: bool,
	wake_posted: bool,
	pending_request, active_request: Image_Preview_Request,
	latest_generation: u64,
	completed: Image_Preview_Result,
	completed_ready: bool,
	submitted, discarded: u64,
}

image_preview_result_destroy :: proc(result: ^Image_Preview_Result, allocator: mem.Allocator) {
	if result == nil { return }
	if result.request.document_id != "" { delete(result.request.document_id,allocator) }
	alicorn.image_decoded_destroy(&result.pixels)
	if result.error != "" { delete(result.error,allocator) }
	result^ = {}
}

image_preview_lane_current :: proc(lane: ^Image_Preview_Lane, generation: u64) -> bool {
	sync.mutex_lock(&lane.mutex)
	defer sync.mutex_unlock(&lane.mutex)
	return !lane.stopping && generation != 0 && generation == lane.latest_generation
}

image_preview_worker_decode :: proc(data: []u8, allocator: mem.Allocator) -> (alicorn.Image_Decoded,alicorn.Image_Load_Error) {
	// Scratch storage is private to this job, never Runtime-owned or shared
	// with the UI. The final pixels use a transferable heap allocator.
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena,block_allocator=allocator,array_allocator=allocator)
	defer mem.dynamic_arena_destroy(&arena)
	return alicorn.image_decode_bytes(data,allocator,mem.dynamic_arena_allocator(&arena))
}

image_preview_lane_worker :: proc(t: ^thread.Thread) {
	lane := cast(^Image_Preview_Lane)t.data
	for {
		sync.sema_wait(&lane.sema)
		sync.mutex_lock(&lane.mutex)
		if lane.stopping { sync.mutex_unlock(&lane.mutex); break }
		if !lane.pending { lane.wake_posted=false; sync.mutex_unlock(&lane.mutex); continue }
		request := lane.pending_request
		lane.pending_request = {}; lane.pending = false; lane.wake_posted = false
		lane.active_request = request; lane.active = true
		sync.mutex_unlock(&lane.mutex)
		response := lane.read(lane.backend,request.document_id,request.revision,request.generation,lane.allocator)
		pixels: alicorn.Image_Decoded
		message := response.message
		if response.ok && image_preview_lane_current(lane,request.generation) {
			err: alicorn.Image_Load_Error
			pixels,err = image_preview_worker_decode(response.image_bytes,lane.allocator)
			if err != .None { message = image_preview_decode_error_message(err) }
		}
		result := Image_Preview_Result{request=request,pixels=pixels}
		if message != "" { result.error,_ = strings.clone(message,lane.allocator) }
		bridge.backend_command_result_destroy(&response,lane.allocator)
		sync.mutex_lock(&lane.mutex)
		lane.active = false; lane.active_request = {}
		current := !lane.stopping && request.generation == lane.latest_generation
		if current {
			image_preview_result_destroy(&lane.completed,lane.allocator)
			lane.completed = result; result = {}
			lane.completed_ready = true
		} else { lane.discarded += 1 }
		wake, wake_data := lane.wake,lane.wake_data
		sync.mutex_unlock(&lane.mutex)
		image_preview_result_destroy(&result,lane.allocator)
		if current && wake != nil { wake(wake_data) }
	}
}

image_preview_lane_start :: proc(lane: ^Image_Preview_Lane, backend: ^bridge.Backend, wake: bridge.Application_Wake_Proc, wake_data: rawptr, allocator := context.allocator) -> bool {
	if lane == nil || backend == nil || !backend.started || lane.thread != nil { return false }
	lane.backend = backend; lane.wake = wake; lane.wake_data = wake_data; lane.allocator = allocator
	lane.stopping = false; lane.sema = {}; lane.wake_posted = false
	if lane.read == nil { lane.read = bridge.backend_image_read }
	lane.thread = thread.create(image_preview_lane_worker,name="Scratchpad image preview")
	if lane.thread == nil { return false }
	lane.thread.data = rawptr(lane)
	thread.start(lane.thread)
	return true
}

image_preview_lane_request :: proc(lane: ^Image_Preview_Lane, document_id: string, revision: u64) -> (u64,bool) {
	if lane == nil || lane.thread == nil || document_id == "" || revision == 0 { return 0,false }
	sync.mutex_lock(&lane.mutex)
	defer sync.mutex_unlock(&lane.mutex)
	if lane.stopping { return 0,false }
	if lane.pending && lane.pending_request.document_id == document_id && lane.pending_request.revision == revision { return lane.pending_request.generation,true }
	if lane.active && !lane.pending && lane.active_request.document_id == document_id && lane.active_request.revision == revision { return lane.active_request.generation,true }
	id,err := strings.clone(document_id,lane.allocator)
	if err != nil { return 0,false }
	lane.latest_generation += 1
	if lane.latest_generation == 0 { lane.latest_generation = 1 }
	if lane.pending { delete(lane.pending_request.document_id,lane.allocator) }
	image_preview_result_destroy(&lane.completed,lane.allocator); lane.completed_ready = false
	lane.pending_request = Image_Preview_Request{id,revision,lane.latest_generation}
	lane.pending = true; lane.submitted += 1
	if !lane.wake_posted { lane.wake_posted=true; sync.sema_post(&lane.sema) }
	return lane.latest_generation,true
}

image_preview_lane_cancel :: proc(lane: ^Image_Preview_Lane) {
	if lane == nil || lane.thread == nil { return }
	sync.mutex_lock(&lane.mutex)
	defer sync.mutex_unlock(&lane.mutex)
	lane.latest_generation += 1
	if lane.pending { delete(lane.pending_request.document_id,lane.allocator) }
	lane.pending_request = {}; lane.pending = false
	image_preview_result_destroy(&lane.completed,lane.allocator); lane.completed_ready = false
}

image_preview_lane_take :: proc(lane: ^Image_Preview_Lane) -> (Image_Preview_Result,bool) {
	if lane == nil || lane.thread == nil { return {},false }
	sync.mutex_lock(&lane.mutex)
	defer sync.mutex_unlock(&lane.mutex)
	if !lane.completed_ready { return {},false }
	result := lane.completed; lane.completed = {}; lane.completed_ready = false
	return result,true
}

image_preview_lane_stop :: proc(lane: ^Image_Preview_Lane) -> bool {
	if lane == nil || lane.thread == nil { return true }
	sync.mutex_lock(&lane.mutex)
	lane.stopping = true
	if lane.pending { delete(lane.pending_request.document_id,lane.allocator) }
	lane.pending = false; lane.pending_request = {}
	sync.mutex_unlock(&lane.mutex)
	sync.sema_post(&lane.sema)
	thread.join(lane.thread); thread.destroy(lane.thread); lane.thread = nil
	image_preview_result_destroy(&lane.completed,lane.allocator); lane.completed_ready = false
	return !lane.active && !lane.pending
}
