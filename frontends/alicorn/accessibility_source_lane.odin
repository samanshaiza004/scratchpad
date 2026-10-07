package main

import "core:mem"
import "core:strings"
import "core:sync"
import "core:thread"
import bridge "./bridge"

ACCESSIBILITY_SOURCE_PAGE_LINES :: u64(bridge.MAX_VISIBLE_LINES)
ACCESSIBILITY_SOURCE_PAGE_BYTES :: u64(bridge.MAX_VISIBLE_BYTES)

Accessibility_Source_Request :: struct {
	document_id: string,
	editor_revision: u64,
	byte_length: u64,
	line_count: u64,
	generation: u64,
}

Accessibility_Source_Result :: struct {
	request: Accessibility_Source_Request,
	projection: Editor_Accessibility_Projection,
	error: string,
	projection_owned: bool,
	error_owned: bool,
}

Accessibility_Source_Lane :: struct {
	backend: ^bridge.Backend,
	wake: bridge.Application_Wake_Proc,
	wake_data: rawptr,
	allocator: mem.Allocator,
	mutex: sync.Mutex,
	sema: sync.Sema,
	thread: ^thread.Thread,
	stopping: u32,
	wake_posted: bool,
	pending: bool,
	active: bool,
	pending_request: Accessibility_Source_Request,
	active_request: Accessibility_Source_Request,
	latest_generation: u64,
	completed: Accessibility_Source_Result,
	completed_ready: bool,
	submitted: u64,
	cancelled: u64,
}

accessibility_source_request_equal :: proc(a, b: Accessibility_Source_Request) -> bool {
	return a.document_id == b.document_id &&
		a.editor_revision == b.editor_revision &&
		a.byte_length == b.byte_length &&
		a.line_count == b.line_count
}

accessibility_source_result_destroy :: proc(result: ^Accessibility_Source_Result, allocator: mem.Allocator) {
	if result == nil { return }
	if len(result.request.document_id) > 0 { delete(result.request.document_id, allocator) }
	if result.projection_owned { editor_accessibility_projection_destroy(&result.projection) }
	if result.error_owned { delete(result.error, allocator) }
	result^ = {}
}

accessibility_source_lane_worker :: proc(t: ^thread.Thread) {
	lane := cast(^Accessibility_Source_Lane)t.data
	for {
		sync.sema_wait(&lane.sema)
		sync.mutex_lock(&lane.mutex)
		if sync.atomic_load(&lane.stopping) != 0 {
			sync.mutex_unlock(&lane.mutex)
			break
		}
		if !lane.pending {
			lane.wake_posted = false
			sync.mutex_unlock(&lane.mutex)
			continue
		}
		lane.active_request = lane.pending_request
		lane.pending_request = {}
		lane.pending = false
		lane.active = true
		lane.wake_posted = false
		request := lane.active_request
		sync.mutex_unlock(&lane.mutex)

		source, read_ok, error_message, error_message_owned := accessibility_source_read(lane, request)
		projection: Editor_Accessibility_Projection
		if read_ok {
			projection = editor_accessibility_projection_build(
				request.document_id,
				string(source),
				request.editor_revision,
				lane.allocator,
			)
			delete(source, lane.allocator)
			source = nil
			if !projection.complete {
				read_ok = false
				error_message = editor_accessibility_unsupported_reason_string(projection.unsupported_reason)
				if error_message == "" { error_message = "could not build a complete accessible text projection" }
				error_message_owned = false
			}
		}

		sync.mutex_lock(&lane.mutex)
		is_current := sync.atomic_load(&lane.stopping) == 0 &&
		              request.generation != 0 && request.generation == lane.latest_generation
		lane.active = false
		lane.active_request = {}
		if is_current {
			accessibility_source_result_destroy(&lane.completed, lane.allocator)
			lane.completed.request = request
			request.document_id = ""
			if read_ok {
				lane.completed.projection = projection
				lane.completed.projection_owned = true
				projection = {}
			} else {
				lane.completed.error, _ = strings.clone(error_message, lane.allocator)
				lane.completed.error_owned = len(lane.completed.error) > 0
			}
			lane.completed_ready = true
		} else {
			lane.cancelled += 1
		}
		wake := lane.wake
		wake_data := lane.wake_data
		should_post := lane.pending && !lane.wake_posted && sync.atomic_load(&lane.stopping) == 0
		if should_post { lane.wake_posted = true }
		sync.mutex_unlock(&lane.mutex)

		if len(source) > 0 { delete(source, lane.allocator) }
		if projection.complete || len(projection.document_id) > 0 { editor_accessibility_projection_destroy(&projection) }
		if error_message_owned { delete(error_message, lane.allocator) }
		if len(request.document_id) > 0 { delete(request.document_id, lane.allocator) }
		if is_current && wake != nil { wake(wake_data) }
		if should_post { sync.sema_post(&lane.sema) }
	}
}

accessibility_source_lane_start :: proc(
	lane: ^Accessibility_Source_Lane,
	backend: ^bridge.Backend,
	wake: bridge.Application_Wake_Proc,
	wake_data: rawptr,
	allocator := context.allocator,
) -> bool {
	if lane == nil || backend == nil || !backend.started || lane.thread != nil { return false }
	lane.backend = backend
	lane.wake = wake
	lane.wake_data = wake_data
	lane.allocator = allocator
	lane.stopping = 0
	lane.wake_posted = false
	lane.pending = false
	lane.active = false
	lane.latest_generation = 0
	lane.completed = {}
	lane.completed_ready = false
	lane.submitted = 0
	lane.cancelled = 0
	lane.sema = {}
	lane.thread = thread.create(accessibility_source_lane_worker, name="Scratchpad accessibility source lane")
	if lane.thread == nil { return false }
	lane.thread.data = rawptr(lane)
	thread.start(lane.thread)
	return true
}

accessibility_source_lane_request :: proc(
	lane: ^Accessibility_Source_Lane,
	document_id: string,
	editor_revision, byte_length, line_count: u64,
) -> (generation: u64, accepted: bool) {
	if lane == nil || lane.thread == nil || len(document_id) == 0 || (line_count == 0 && byte_length != 0) { return 0, false }
	sync.mutex_lock(&lane.mutex)
	defer sync.mutex_unlock(&lane.mutex)
	if sync.atomic_load(&lane.stopping) != 0 { return 0, false }
	request := Accessibility_Source_Request{
		document_id=document_id,
		editor_revision=editor_revision,
		byte_length=byte_length,
		line_count=line_count,
	}
	if lane.pending && accessibility_source_request_equal(lane.pending_request, request) {
		return lane.pending_request.generation, true
	}
	if lane.active && !lane.pending && accessibility_source_request_equal(lane.active_request, request) {
		return lane.active_request.generation, true
	}
	if lane.completed_ready && accessibility_source_request_equal(lane.completed.request, request) {
		return lane.completed.request.generation, true
	}
	owned_document_id, clone_error := strings.clone(document_id, lane.allocator)
	if clone_error != nil { return 0, false }
	lane.latest_generation += 1
	if lane.latest_generation == 0 { lane.latest_generation = 1 }
	generation = lane.latest_generation
	if lane.pending {
		delete(lane.pending_request.document_id, lane.allocator)
	} else if lane.active {
		lane.cancelled += 1
	}
	request.document_id = owned_document_id
	request.generation = generation
	lane.pending_request = request
	lane.pending = true
	lane.submitted += 1
	if !lane.wake_posted {
		lane.wake_posted = true
		sync.sema_post(&lane.sema)
	}
	return generation, true
}

accessibility_source_lane_cancel :: proc(lane: ^Accessibility_Source_Lane) {
	if lane == nil || lane.thread == nil { return }
	sync.mutex_lock(&lane.mutex)
	lane.latest_generation += 1
	if lane.latest_generation == 0 { lane.latest_generation = 1 }
	if lane.pending {
		delete(lane.pending_request.document_id, lane.allocator)
		lane.pending_request = {}
		lane.pending = false
	}
	accessibility_source_result_destroy(&lane.completed, lane.allocator)
	lane.completed_ready = false
	sync.mutex_unlock(&lane.mutex)
}

accessibility_source_lane_take :: proc(lane: ^Accessibility_Source_Lane) -> (result: Accessibility_Source_Result, found: bool) {
	if lane == nil { return {}, false }
	sync.mutex_lock(&lane.mutex)
	if !lane.completed_ready {
		sync.mutex_unlock(&lane.mutex)
		return {}, false
	}
	result = lane.completed
	lane.completed = {}
	lane.completed_ready = false
	sync.mutex_unlock(&lane.mutex)
	return result, true
}

accessibility_source_lane_stop :: proc(lane: ^Accessibility_Source_Lane) -> bool {
	if lane == nil || lane.thread == nil { return true }
	sync.mutex_lock(&lane.mutex)
	sync.atomic_store(&lane.stopping, 1)
	if lane.pending {
		delete(lane.pending_request.document_id, lane.allocator)
		lane.pending_request = {}
		lane.pending = false
	}
	sync.mutex_unlock(&lane.mutex)
	sync.sema_post(&lane.sema)
	thread.join(lane.thread)
	thread.destroy(lane.thread)
	lane.thread = nil
	accessibility_source_result_destroy(&lane.completed, lane.allocator)
	lane.completed_ready = false
	lane.backend = nil
	lane.wake = nil
	lane.wake_data = nil
	return !lane.active && !lane.pending
}

accessibility_source_request_is_current :: proc(lane: ^Accessibility_Source_Lane, request: Accessibility_Source_Request) -> bool {
	if lane == nil { return false }
	sync.mutex_lock(&lane.mutex)
	current := sync.atomic_load(&lane.stopping) == 0 && request.generation != 0 && request.generation == lane.latest_generation
	sync.mutex_unlock(&lane.mutex)
	return current
}

accessibility_source_read :: proc(
	lane: ^Accessibility_Source_Lane,
	request: Accessibility_Source_Request,
) -> ([]u8, bool, string, bool) {
	message: string
	message_owned := false
	if lane == nil || lane.backend == nil { return nil, false, "accessibility source request is invalid", false }
	if request.byte_length == 0 {
		empty, allocation_error := make([]u8, 0, allocator=lane.allocator)
		if allocation_error != nil { return nil, false, "could not allocate the empty accessibility source projection", false }
		return empty, true, "", false
	}
	if request.line_count == 0 { return nil, false, "accessibility source request has bytes but no logical lines", false }
	source_length := int(request.byte_length)
	if source_length < 0 { return nil, false, "document is too large for this platform's address space", false }
	source, allocation_error := make([]u8, source_length, allocator=lane.allocator)
	if allocation_error != nil { return nil, false, "could not allocate the bounded accessibility source projection", false }
	written := 0
	start_line: u64 = 0
	anchor_byte: u64 = 0
	for written < len(source) || start_line < request.line_count {
		if !accessibility_source_request_is_current(lane, request) {
			delete(source, lane.allocator)
			return nil, false, "accessibility source request was superseded", false
		}
		max_lines := ACCESSIBILITY_SOURCE_PAGE_LINES
		if anchor_byte != 0 { max_lines = 1 }
		result := bridge.backend_command(
			lane.backend,
			"read_visible_lines",
			document_id=request.document_id,
			start_line=start_line,
			anchor_byte=anchor_byte,
			max_lines=max_lines,
			max_bytes=ACCESSIBILITY_SOURCE_PAGE_BYTES,
			editor_revision=request.editor_revision,
			allow_unversioned_read=true,
			read_latest_after=false,
			allocator=lane.allocator,
		)
		if !result.ok || !result.visible_window_owned {
			if result.message != "" { message, _ = strings.clone(result.message, lane.allocator) }
			if message == "" && result.code != "" { message, _ = strings.clone(result.code, lane.allocator) }
			message_owned = len(message) > 0
			bridge.backend_command_result_destroy(&result, lane.allocator)
			delete(source, lane.allocator)
			if message == "" { message = "could not read a bounded document source page" }
			return nil, false, message, message_owned
		}
		window := result.visible_window
		if window.document_id != request.document_id || window.editor_revision != request.editor_revision ||
		   window.start_line != start_line || window.end_line <= start_line || window.end_line > request.line_count {
			bridge.backend_command_result_destroy(&result, lane.allocator)
			delete(source, lane.allocator)
			return nil, false, "bounded source page changed document or editor revision while assembling accessibility text", false
		}
		if !accessibility_source_copy_page(source, &written, window) {
			bridge.backend_command_result_destroy(&result, lane.allocator)
			delete(source, lane.allocator)
			return nil, false, "bounded source pages were not contiguous or disagreed on overlapping bytes", false
		}
		page_newlines := u64(0)
		for byte in window.source { if byte == '\n' { page_newlines += 1 } }
		ends_with_lf := len(window.source) > 0 && window.source[len(window.source)-1] == '\n'
		was_line_chunk := anchor_byte != 0 || window.line_byte_length > 0
		was_truncated := window.truncated
		page_end_byte := window.start_byte+u64(len(window.source))
		bridge.backend_command_result_destroy(&result, lane.allocator)
		if written == len(source) { break }
		if ends_with_lf {
			start_line += page_newlines
			anchor_byte = 0
		} else if was_truncated {
			start_line += page_newlines
			anchor_byte = page_end_byte
		} else if was_line_chunk {
			start_line += 1
			anchor_byte = 0
		} else {
			delete(source, lane.allocator)
			return nil, false, "bounded source read ended before the declared document byte length", false
		}
		if start_line >= request.line_count && written < len(source) {
			delete(source, lane.allocator)
			return nil, false, "bounded source read reached the declared final line before all source bytes", false
		}
	}
	if written != len(source) {
		delete(source, lane.allocator)
		return nil, false, "bounded source pages did not assemble the declared document byte length", false
	}
	return source, true, "", false
}

accessibility_source_copy_page :: proc(source: []u8, written: ^int, window: bridge.Visible_Window) -> bool {
	if written == nil || window.start_byte > u64(len(source)) || u64(len(window.source)) > u64(len(source))-window.start_byte { return false }
	page_start := int(window.start_byte)
	if page_start > written^ {
		gap := page_start-written^
		if gap == 1 {
			source[written^] = '\n'
			written^ += 1
		} else if gap == 2 {
			source[written^] = '\r'
			source[written^+1] = '\n'
			written^ += 2
		} else {
			return false
		}
	}
	if page_start < written^ {
		overlap := written^-page_start
		if overlap > len(window.source) { return false }
		for index in 0..<overlap {
			if source[page_start+index] != window.source[index] { return false }
		}
		copy_start := overlap
		copy_count := len(window.source)-copy_start
		if copy_count > 0 {
			copy(source[written^:written^+copy_count], window.source[copy_start:])
			written^ += copy_count
		}
		return true
	}
	if len(window.source) > 0 {
		copy(source[written^:written^+len(window.source)], window.source)
		written^ += len(window.source)
	}
	return true
}
