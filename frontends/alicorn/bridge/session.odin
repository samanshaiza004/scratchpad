package alicorn_scratchpad_bridge

import "core:dynlib"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:sync"
import "core:thread"

Caliber_Status :: enum i32 {
	OK = 0,
	Invalid_Argument = 1,
	Invalid_Handle = 2,
	Buffer_Too_Small = 3,
	Limit_Exceeded = 4,
	Not_Found = 5,
	Stale = 6,
	Unavailable = 7,
	Queue_Full = 8,
	Unsupported_Version = 9,
	Internal = 10,
	Stopped = 11,
}

// Mirrors .deps/caliber/include/caliber.h. That header remains authoritative;
// these declarations bind only the ABI surface this frontend actually uses.
Caliber_Context_Config :: struct {
	struct_size:           u32,
	max_command_bytes:     uintptr,
	max_publication_bytes: uintptr,
	max_resource_bytes:    uintptr,
	max_resources:         uintptr,
	telemetry_width:       uintptr,
	max_pending_commands:  uintptr,
}

Caliber_State_Publication :: struct {
	revision: u64,
	schema:   u32,
	reserved: u32,
	data:     ^u8,
	len:      uintptr,
	lease:    rawptr,
}

Caliber_Api_V1 :: struct {
	abi_version:                   u32,
	struct_size:                   u32,
	context_create:                rawptr,
	context_destroy:               rawptr,
	context_dispatch:              rawptr,
	context_peek_command:          rawptr,
	context_take_command:          rawptr,
	context_publish_state:         rawptr,
	context_read_latest_state:     rawptr,
	state_publication_release:     rawptr,
	context_map_resource:          rawptr,
	resource_release:              rawptr,
	context_publish_resource:      rawptr,
	context_release_resource:      rawptr,
	context_publish_telemetry:     rawptr,
	context_read_latest_telemetry: rawptr,
	context_wake_sequence:         rawptr,
	context_wait_wake:             rawptr,
	context_stop_wake_waiters:     rawptr,
}

#assert(size_of(uintptr) == 8)
#assert(size_of(Caliber_Context_Config) == 56)
#assert(offset_of(Caliber_Context_Config, max_command_bytes) == 8)
#assert(offset_of(Caliber_Context_Config, max_publication_bytes) == 16)
#assert(offset_of(Caliber_Context_Config, max_resources) == 32)
#assert(offset_of(Caliber_State_Publication, data) == 16)
#assert(offset_of(Caliber_State_Publication, len) == 24)
#assert(offset_of(Caliber_State_Publication, lease) == 32)
#assert(size_of(Caliber_State_Publication) == 40)
#assert(offset_of(Caliber_Api_V1, context_wait_wake) == 128)
#assert(offset_of(Caliber_Api_V1, context_stop_wake_waiters) == 136)
#assert(size_of(Caliber_Api_V1) == 144)

Caliber_Read_State_Proc :: #type proc "c" (rawptr, ^Caliber_State_Publication) -> Caliber_Status
Caliber_Release_State_Proc :: #type proc "c" (^Caliber_State_Publication)
Caliber_Wake_Sequence_Proc :: #type proc "c" (rawptr, ^u64) -> Caliber_Status
Caliber_Wait_Wake_Proc :: #type proc "c" (rawptr, u64, ^u64) -> Caliber_Status
Caliber_Stop_Waiters_Proc :: #type proc "c" (rawptr) -> Caliber_Status

Backend_Start_Proc :: #type proc "c" (^u8, uintptr, ^^u8, ^uintptr) -> i32
Backend_Stop_Proc :: #type proc "c" (^u8, uintptr, ^^u8, ^uintptr) -> i32
Backend_Get_Pointer_Proc :: #type proc "c" () -> rawptr
Backend_Lease_Proc :: #type proc "c" () -> i32
Backend_Free_Proc :: #type proc "c" (rawptr)
Application_Wake_Proc :: #type proc (rawptr)

State_Document :: struct {
	id:              string `json:"id"`,
	path:            string `json:"path"`,
	status:          string `json:"status"`,
	dirty:           bool   `json:"dirty"`,
	editor_revision: u64    `json:"editor_revision"`,
	language:        string `json:"language"`,
}

State_Envelope :: struct {
	schema:          u32              `json:"schema"`,
	revision:        u64              `json:"revision"`,
	application_rev: u64              `json:"application_revision"`,
	has_workspace:   bool             `json:"has_workspace"`,
	workspace_root:  string           `json:"workspace_root"`,
	active:          string           `json:"active"`,
	documents:       []State_Document `json:"documents"`,
}

Backend_Outcome :: struct {
	code:    string `json:"code"`,
	message: string `json:"message"`,
}

Backend_Response :: struct {
	version:   u32             `json:"version"`,
	request_id: u64             `json:"request_id"`,
	lifecycle: string          `json:"lifecycle"`,
	ok:        bool            `json:"ok"`,
	outcome:   Backend_Outcome `json:"outcome"`,
}

Backend_Start_Request :: struct {
	version:        u32    `json:"version"`,
	request_id:     u64    `json:"request_id"`,
	workspace_path: string `json:"workspace_path,omitempty"`,
}

Backend_Stop_Request :: struct {
	version:    u32 `json:"version"`,
	request_id: u64 `json:"request_id"`,
}

decode_state_envelope :: proc(data: []u8, allocator := context.allocator) -> (state: State_Envelope, ok: bool, message: string) {
	if len(data) == 0 {
		return state, false, "state publication is empty"
	}
	if err := json.unmarshal(data, &state, allocator=allocator); err != nil {
		state_destroy(&state, allocator)
		return {}, false, "state publication is not a valid StateEnvelope"
	}
	if state.schema != 1 {
		message := fmt.tprintf("unsupported StateEnvelope schema %d", state.schema)
		state_destroy(&state, allocator)
		return {}, false, message
	}
	if state.revision == 0 {
		state_destroy(&state, allocator)
		return {}, false, "StateEnvelope revision must be nonzero"
	}
	return state, true, ""
}

state_revision_is_newer :: proc(current, candidate: u64) -> bool {
	return candidate > current
}

state_destroy :: proc(state: ^State_Envelope, allocator: mem.Allocator) {
	if state == nil { return }
	delete(state.workspace_root, allocator)
	delete(state.active, allocator)
	for &document in state.documents {
		delete(document.id, allocator)
		delete(document.path, allocator)
		delete(document.status, allocator)
		delete(document.language, allocator)
	}
	delete(state.documents, allocator)
	state^ = {}
}

// Any number of foreign notifications coalesce until the UI consumes latest.
wake_coalescer_request :: proc(pending: ^u32) -> bool {
	_, transitioned := sync.atomic_compare_exchange_strong(pending, 0, 1)
	return transitioned
}

wake_coalescer_consume :: proc(pending: ^u32) {
	sync.atomic_store(pending, 0)
}

Waiter_State :: struct {
	api:               ^Caliber_Api_V1,
	caliber_context:   rawptr,
	expected_sequence: u64,
	wake:              Application_Wake_Proc,
	wake_data:         rawptr,
	pending:           u32,
	exited:            u32,
	notifications:     u64,
	thread:            ^thread.Thread,
}

waiter_thread_entry :: proc(t: ^thread.Thread) {
	waiter := cast(^Waiter_State)t.data
	wait_fn := transmute(Caliber_Wait_Wake_Proc)(waiter.api.context_wait_wake)
	expected := waiter.expected_sequence
	for {
		woken := expected
		status := wait_fn(waiter.caliber_context, expected, &woken)
		if status == .Stopped { break }
		if status != .OK || woken == expected { break }
		expected = woken
		if wake_coalescer_request(&waiter.pending) {
			sync.atomic_add(&waiter.notifications, 1)
			if waiter.wake != nil { waiter.wake(waiter.wake_data) }
		}
	}
	sync.atomic_store(&waiter.exited, 1)
}

waiter_start :: proc(
	waiter: ^Waiter_State,
	api: ^Caliber_Api_V1,
	caliber_context: rawptr,
	expected_sequence: u64,
	wake: Application_Wake_Proc,
	wake_data: rawptr,
) -> bool {
	if waiter == nil || waiter.thread != nil || api == nil || caliber_context == nil {
		return false
	}
	waiter.api = api
	waiter.caliber_context = caliber_context
	waiter.expected_sequence = expected_sequence
	waiter.wake = wake
	waiter.wake_data = wake_data
	waiter.pending = 0
	waiter.exited = 0
	waiter.notifications = 0
	waiter.thread = thread.create(waiter_thread_entry, name="Scratchpad Caliber wake")
	if waiter.thread == nil { return false }
	waiter.thread.data = rawptr(waiter)
	thread.start(waiter.thread)
	return true
}

waiter_join :: proc(waiter: ^Waiter_State) -> bool {
	if waiter == nil || waiter.thread == nil { return true }
	thread.join(waiter.thread)
	thread.destroy(waiter.thread)
	waiter.thread = nil
	return sync.atomic_load(&waiter.exited) == 1
}

Backend :: struct {
	library:           dynlib.Library,
	library_loaded:    bool,
	load_error:        string,
	start_fn:          Backend_Start_Proc,
	stop_fn:           Backend_Stop_Proc,
	api_fn:            Backend_Get_Pointer_Proc,
	context_fn:        Backend_Get_Pointer_Proc,
	lease_acquired_fn: Backend_Lease_Proc,
	lease_released_fn: Backend_Lease_Proc,
	free_fn:           Backend_Free_Proc,
	api:               ^Caliber_Api_V1,
	caliber_context:   rawptr,
	waiter:            Waiter_State,
	state:             State_Envelope,
	state_allocator:   mem.Allocator,
	state_revision:    u64,
	state_leases:      int,
	started:           bool,
	request_id:        u64,
}

backend_load :: proc(backend: ^Backend, library_path: string) -> (ok: bool, message: string) {
	if backend == nil { return false, "backend state is nil" }
	if backend.library_loaded { return backend.load_error == "", backend.load_error }
	if library_path == "" { return false, "SCRATCHPAD_BACKEND_LIBRARY is not set" }
	library, loaded := dynlib.load_library(library_path)
	if !loaded { return false, fmt.tprintf("load backend library %q: %s", library_path, dynlib.last_error()) }
	backend.library = library
	load_proc :: proc(library: dynlib.Library, name: string) -> rawptr {
		address, found := dynlib.symbol_address(library, name)
		if !found { return nil }
		return address
	}
	start := load_proc(library, "scratchpad_backend_start")
	stop := load_proc(library, "scratchpad_backend_stop")
	api := load_proc(library, "scratchpad_backend_caliber_api")
	ctx := load_proc(library, "scratchpad_backend_caliber_context")
	lease_acquired := load_proc(library, "scratchpad_backend_state_lease_acquired")
	lease_released := load_proc(library, "scratchpad_backend_state_lease_released")
	free_output := load_proc(library, "scratchpad_backend_free")
	if start == nil || stop == nil || api == nil || ctx == nil || lease_acquired == nil || lease_released == nil || free_output == nil {
		backend.library_loaded = true
		backend.load_error = "backend library is missing one or more scratchpad_backend_* bridge exports"
		return false, backend.load_error
	}
	backend.start_fn = transmute(Backend_Start_Proc)(start)
	backend.stop_fn = transmute(Backend_Stop_Proc)(stop)
	backend.api_fn = transmute(Backend_Get_Pointer_Proc)(api)
	backend.context_fn = transmute(Backend_Get_Pointer_Proc)(ctx)
	backend.lease_acquired_fn = transmute(Backend_Lease_Proc)(lease_acquired)
	backend.lease_released_fn = transmute(Backend_Lease_Proc)(lease_released)
	backend.free_fn = transmute(Backend_Free_Proc)(free_output)
	backend.library_loaded = true
	return true, ""
}

backend_start :: proc(
	backend: ^Backend,
	workspace_path: string,
	wake: Application_Wake_Proc,
	wake_data: rawptr,
	allocator := context.allocator,
) -> (ok: bool, message: string) {
	if backend == nil { return false, "backend state is nil" }
	if backend.started { return true, "" }
	if !backend.library_loaded { return false, "backend library is not loaded" }
	backend.request_id += 1
	request := Backend_Start_Request{version=1, request_id=backend.request_id, workspace_path=workspace_path}
	request_bytes, marshal_err := json.marshal(request, allocator=allocator)
	if marshal_err != nil { return false, "could not encode backend start request" }
	defer delete(request_bytes, allocator)
	output: ^u8
	output_len: uintptr
	status := backend.start_fn(&request_bytes[0], uintptr(len(request_bytes)), &output, &output_len)
	response, response_ok := backend_decode_response(output, output_len, backend.free_fn, allocator)
	if status != 0 {
		_, _ = backend_stop_uninitialized(backend, allocator)
		return false, "scratchpad_backend_start returned a nonzero status"
	}
	if !response_ok || !backend_response_identity_matches(response, backend.request_id) {
		_, _ = backend_stop_uninitialized(backend, allocator)
		return false, "scratchpad_backend_start returned malformed or mismatched JSON"
	}
	if !response.ok {
		message := response.outcome.message
		if message == "" { message = response.outcome.code }
		return false, message
	}
	if response.lifecycle != "running" {
		_, _ = backend_stop_uninitialized(backend, allocator)
		return false, "scratchpad_backend_start returned an unexpected lifecycle state"
	}
	backend.started = true
	backend.api = cast(^Caliber_Api_V1)backend.api_fn()
	backend.caliber_context = backend.context_fn()
	if !backend_validate_api(backend.api) || backend.caliber_context == nil {
		_, _ = backend_stop_uninitialized(backend, allocator)
		return false, "backend returned a null, truncated, or incompatible Caliber API/context"
	}
	if state, state_ok, state_error := backend_read_latest(backend, allocator); !state_ok {
		_, _ = backend_stop(backend, allocator)
		return false, state_error
	} else if !state {
		_, _ = backend_stop(backend, allocator)
		return false, "backend started without publishing initial Scratchpad state"
	}
	wake_sequence: u64 = 0
	wake_sequence_fn := transmute(Caliber_Wake_Sequence_Proc)(backend.api.context_wake_sequence)
	if wake_sequence_fn(backend.caliber_context, &wake_sequence) != .OK {
		_, _ = backend_stop(backend, allocator)
		return false, "Caliber context_wake_sequence failed"
	}
	// Start publishes its initial state before returning. Waiting from the
	// preceding sequence delivers that real publication through the host wake
	// route without polling or manufacturing an application tick.
	expected := wake_sequence
	if expected > 0 { expected -= 1 }
	if !waiter_start(&backend.waiter, backend.api, backend.caliber_context, expected, wake, wake_data) {
		_, _ = backend_stop(backend, allocator)
		return false, "could not start the Caliber wake waiter"
	}
	return true, ""
}

backend_decode_response :: proc(
	output: ^u8,
	output_len: uintptr,
	free_output: Backend_Free_Proc,
	allocator: mem.Allocator,
) -> (response: Backend_Response, ok: bool) {
	if output == nil { return response, false }
	if output_len == 0 || output_len > 1 << 20 {
		free_output(rawptr(output))
		return response, false
	}
	defer free_output(rawptr(output))
	bytes, alloc_err := make([]u8, int(output_len), allocator)
	if alloc_err != nil { return response, false }
	defer delete(bytes, allocator)
	mem.copy(rawptr(&bytes[0]), rawptr(output), int(output_len))
	return decode_backend_response_bytes(bytes, allocator)
}

decode_backend_response_bytes :: proc(data: []u8, allocator: mem.Allocator) -> (response: Backend_Response, ok: bool) {
	if len(data) == 0 { return response, false }
	if err := json.unmarshal(data, &response, allocator=allocator); err != nil { return {}, false }
	if response.version != 1 { return {}, false }
	return response, true
}

backend_response_matches :: proc(response: Backend_Response, request_id: u64, lifecycle: string) -> bool {
	return backend_response_identity_matches(response, request_id) && response.lifecycle == lifecycle
}

backend_response_identity_matches :: proc(response: Backend_Response, request_id: u64) -> bool {
	return response.version == 1 && response.request_id == request_id
}

backend_validate_api :: proc(api: ^Caliber_Api_V1) -> bool {
	if api == nil || api.abi_version != 1 { return false }
	required_size := offset_of(Caliber_Api_V1, context_stop_wake_waiters) + size_of(rawptr)
	if uintptr(api.struct_size) < required_size { return false }
	return api.context_read_latest_state != nil &&
	       api.state_publication_release != nil &&
	       api.context_wake_sequence != nil &&
	       api.context_wait_wake != nil &&
	       api.context_stop_wake_waiters != nil
}

backend_read_latest :: proc(backend: ^Backend, allocator := context.allocator) -> (new_state: bool, ok: bool, message: string) {
	if backend == nil || !backend.started || backend.api == nil || backend.caliber_context == nil {
		return false, false, "backend is not running"
	}
	publication: Caliber_State_Publication
	read_fn := transmute(Caliber_Read_State_Proc)(backend.api.context_read_latest_state)
	if read_fn(backend.caliber_context, &publication) != .OK {
		return false, false, "Caliber did not provide a latest state publication"
	}
	if backend.lease_acquired_fn() != 0 {
		release_fn := transmute(Caliber_Release_State_Proc)(backend.api.state_publication_release)
		release_fn(&publication)
		return false, false, "backend rejected state lease accounting"
	}
	backend.state_leases += 1
	if publication.len > 1 << 20 {
		backend_release_publication(backend, &publication)
		return false, false, "Caliber state publication exceeds the 1 MiB bridge limit"
	}
	if publication.len > 0 && publication.data == nil {
		backend_release_publication(backend, &publication)
		return false, false, "Caliber state publication has bytes but a null data pointer"
	}
	data, allocation_err := make([]u8, int(publication.len), allocator)
	if allocation_err != nil {
		backend_release_publication(backend, &publication)
		return false, false, "could not copy Caliber state publication"
	}
	if publication.len > 0 {
		mem.copy(rawptr(&data[0]), rawptr(publication.data), int(publication.len))
	}
	publication_revision := publication.revision
	publication_schema := publication.schema
	backend_release_publication(backend, &publication)
	if publication_schema != 1 {
		delete(data, allocator)
		return false, false, fmt.tprintf("unsupported Caliber state schema %d", publication_schema)
	}
	state, decoded, decode_message := decode_state_envelope(data, allocator)
	delete(data, allocator)
	if !decoded { return false, false, decode_message }
	if state.revision != publication_revision {
		state_destroy(&state, allocator)
		return false, false, "StateEnvelope revision does not match its Caliber publication"
	}
	if !state_revision_is_newer(backend.state_revision, state.revision) {
		state_destroy(&state, allocator)
		return false, true, ""
	}
	state_destroy(&backend.state, backend.state_allocator)
	backend.state = state
	backend.state_allocator = allocator
	backend.state_revision = state.revision
	return true, true, ""
}

backend_release_publication :: proc(backend: ^Backend, publication: ^Caliber_State_Publication) {
	if backend == nil || publication == nil { return }
	release_fn := transmute(Caliber_Release_State_Proc)(backend.api.state_publication_release)
	release_fn(publication)
	if backend.lease_released_fn() == 0 { backend.state_leases -= 1 }
}

backend_consume_wake :: proc(backend: ^Backend, allocator := context.allocator) -> (changed: bool, ok: bool, message: string) {
	if backend == nil || !backend.started { return false, false, "backend is not running" }
	// Clear before reading. A concurrent publication then appears in this read
	// or queues another wake, so no latest-value update can be lost.
	wake_coalescer_consume(&backend.waiter.pending)
	return backend_read_latest(backend, allocator)
}

backend_stop_uninitialized :: proc(backend: ^Backend, allocator: mem.Allocator) -> (ok: bool, message: string) {
	if backend == nil || backend.stop_fn == nil { return false, "backend stop export is unavailable" }
	backend.request_id += 1
	request := Backend_Stop_Request{version=1, request_id=backend.request_id}
	request_bytes, marshal_err := json.marshal(request, allocator=allocator)
	if marshal_err != nil { return false, "could not encode backend stop request" }
	defer delete(request_bytes, allocator)
	output: ^u8
	output_len: uintptr
	status := backend.stop_fn(&request_bytes[0], uintptr(len(request_bytes)), &output, &output_len)
	response, response_ok := backend_decode_response(output, output_len, backend.free_fn, allocator)
	if status != 0 || !response_ok || !response.ok || !backend_response_matches(response, backend.request_id, "stopped") {
		return false, "backend rejected shutdown after startup validation failed"
	}
	backend.started = false
	backend.api = nil
	backend.caliber_context = nil
	state_destroy(&backend.state, backend.state_allocator)
	backend.state_revision = 0
	backend.state_allocator = {}
	return true, ""
}

backend_stop :: proc(backend: ^Backend, allocator := context.allocator) -> (ok: bool, message: string) {
	if backend == nil || !backend.started { return true, "" }
	if backend.api == nil {
		return backend_stop_uninitialized(backend, allocator)
	}
	stop_waiters := transmute(Caliber_Stop_Waiters_Proc)(backend.api.context_stop_wake_waiters)
	stop_status := stop_waiters(backend.caliber_context)
	joined := waiter_join(&backend.waiter)
	if !joined { return false, "Caliber wake waiter did not exit after stop_wake_waiters" }
	if backend.state_leases != 0 {
		return false, fmt.tprintf("refusing backend stop with %d outstanding state lease(s)", backend.state_leases)
	}
	stopped, stop_message := backend_stop_uninitialized(backend, allocator)
	if !stopped { return false, stop_message }
	if stop_status != .OK { return false, fmt.tprintf("backend stopped, but Caliber context_stop_wake_waiters returned: %v", stop_status) }
	return true, ""
}
