package alicorn_scratchpad_bridge

import "core:dynlib"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
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

VISIBLE_SLICE_HEADER_BYTES :: 48
VISIBLE_SLICE_SCHEMA_V1   :: u32(1)
VISIBLE_SLICE_SCHEMA_V2   :: u32(2)
MAX_VISIBLE_LINES         :: u64(256)
MAX_VISIBLE_BYTES         :: u64(64 * 1024)
MAX_EDIT_BYTES            :: u64(128 * 1024)
MAX_FIND_MATCHES           :: 1000
MAX_FIND_QUERY_BYTES       :: 4096
MAX_WORKSPACE_SEARCH_QUERY_BYTES :: 4096
MAX_WORKSPACE_SEARCH_PAGE_SIZE :: 32
MAX_WORKSPACE_SEARCH_RESULTS :: 5000

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

Caliber_Resource_View :: struct {
	resource_id: u64,
	generation:  u64,
	data:        ^u8,
	len:         uintptr,
	lease:       rawptr,
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
#assert(offset_of(Caliber_Resource_View, data) == 16)
#assert(offset_of(Caliber_Resource_View, len) == 24)
#assert(offset_of(Caliber_Resource_View, lease) == 32)
#assert(size_of(Caliber_Resource_View) == 40)
#assert(offset_of(Caliber_Api_V1, context_wait_wake) == 128)
#assert(offset_of(Caliber_Api_V1, context_stop_wake_waiters) == 136)
#assert(size_of(Caliber_Api_V1) == 144)

Caliber_Read_State_Proc :: #type proc "c" (rawptr, ^Caliber_State_Publication) -> Caliber_Status
Caliber_Release_State_Proc :: #type proc "c" (^Caliber_State_Publication)
Caliber_Map_Resource_Proc :: #type proc "c" (rawptr, u64, u64, ^Caliber_Resource_View) -> Caliber_Status
Caliber_Release_Resource_Proc :: #type proc "c" (^Caliber_Resource_View)
Caliber_Release_Context_Resource_Proc :: #type proc "c" (rawptr, u64, u64) -> Caliber_Status
Caliber_Wake_Sequence_Proc :: #type proc "c" (rawptr, ^u64) -> Caliber_Status
Caliber_Wait_Wake_Proc :: #type proc "c" (rawptr, u64, ^u64) -> Caliber_Status
Caliber_Stop_Waiters_Proc :: #type proc "c" (rawptr) -> Caliber_Status
Caliber_Dispatch_Proc :: #type proc "c" (rawptr, ^u8, uintptr) -> Caliber_Status

Backend_Start_Proc :: #type proc "c" (^u8, uintptr, ^^u8, ^uintptr) -> i32
Backend_Stop_Proc :: #type proc "c" (^u8, uintptr, ^^u8, ^uintptr) -> i32
Backend_Get_Pointer_Proc :: #type proc "c" () -> rawptr
Backend_Lease_Proc :: #type proc "c" () -> i32
Backend_Free_Proc :: #type proc "c" (rawptr)
Backend_Pump_Proc :: #type proc "c" (^^u8, ^uintptr) -> i32
Application_Wake_Proc :: #type proc (rawptr)

State_Document :: struct {
	id:              string `json:"id"`,
	path:            string `json:"path"`,
	status:          string `json:"status"`,
	dirty:           bool   `json:"dirty"`,
	preview:         bool   `json:"preview"`,
	editor_revision: u64    `json:"editor_revision"`,
	line_count:      u64    `json:"line_count"`,
	byte_length:     u64    `json:"byte_length"`,
	can_undo:        bool   `json:"can_undo"`,
	can_redo:        bool   `json:"can_redo"`,
	language:        string `json:"language"`,
	presentation_revision: u64 `json:"presentation_revision"`,
	presentation_ready: bool `json:"presentation_ready"`,
}

Resource_Descriptor :: struct {
	resource_id:     u64    `json:"resource_id"`,
	generation:      u64    `json:"generation"`,
	document_id:     string `json:"document_id"`,
	application_rev: u64    `json:"application_revision"`,
	editor_revision: u64    `json:"editor_revision"`,
	start_line:      u64    `json:"start_line"`,
	end_line:        u64    `json:"end_line"`,
	byte_len:        u64    `json:"byte_len"`,
	truncated:       bool   `json:"truncated"`,
	start_byte:      u64    `json:"start_byte"`,
	line_byte_length: u64   `json:"line_byte_length"`,
	metadata_byte_len: u64 `json:"metadata_byte_len"`,
}

PRESENTATION_MAX_RECORDS :: 4096
PRESENTATION_TRAILER_BYTES :: 24
PRESENTATION_RECORD_BYTES :: 16
PRESENTATION_READY_FLAG :: u32(1)
PRESENTATION_TRUNCATED_FLAG :: u32(2)

Presentation_Record :: struct {
	kind: u32,
	start_byte: u32,
	end_byte: u32,
	level_flags: u32,
}

Visible_Window :: struct {
	document_id:     string,
	application_rev: u64,
	editor_revision: u64,
	start_line:      u64,
	end_line:        u64,
	start_byte:      u64,
	line_byte_length: u64,
	truncated:       bool,
	source:          []u8,
	presentation_revision: u64,
	presentation_ready: bool,
	presentation_truncated: bool,
	presentation_spans: []Presentation_Record,
	presentation_blocks: []Presentation_Record,
}

Action_State :: struct {
	id:       string   `json:"id"`,
	title:    string   `json:"title"`,
	category: string   `json:"category"`,
	bindings: []string `json:"bindings"`,
	visible:  bool     `json:"visible"`,
	enabled:  bool     `json:"enabled"`,
	checked:  bool     `json:"checked"`,
}

State_Envelope :: struct {
	schema:          u32              `json:"schema"`,
	revision:        u64              `json:"revision"`,
	application_rev: u64              `json:"application_revision"`,
	has_workspace:   bool             `json:"has_workspace"`,
	workspace_root:  string           `json:"workspace_root"`,
	active:          string           `json:"active"`,
	documents:       []State_Document `json:"documents"`,
	actions:         []Action_State   `json:"actions"`,
	workspace_search_generation: u64 `json:"workspace_search_generation"`,
	workspace_search_sequence:   u64 `json:"workspace_search_sequence"`,
	workspace_search_count:      u64 `json:"workspace_search_count"`,
	workspace_search_page_available: bool `json:"workspace_search_page_available"`,
	workspace_search_done:       bool `json:"workspace_search_done"`,
	workspace_search_truncated:  bool `json:"workspace_search_truncated"`,
}

Backend_Outcome :: struct {
	code:    string `json:"code"`,
	message: string `json:"message"`,
}

Backend_Response :: struct {
	version:          u32               `json:"version"`,
	request_id:       u64               `json:"request_id"`,
	lifecycle:        string            `json:"lifecycle"`,
	ok:               bool              `json:"ok"`,
	outcome:          Backend_Outcome   `json:"outcome"`,
	revision:         u64               `json:"revision"`,
	directory_listing: Directory_Listing `json:"directory_listing"`,
	close_decision:   Close_Decision    `json:"close_decision"`,
	resource:         Resource_Descriptor `json:"resource"`,
	edit:             Edit_Ack           `json:"edit"`,
	editor_selection: Editor_Selection   `json:"editor_selection"`,
	command_outcome:  string             `json:"command_outcome"`,
	matches:          []Current_Match    `json:"matches"`,
	matches_truncated: bool               `json:"matches_truncated"`,
	workspace_search_page: Workspace_Search_Page `json:"workspace_search_page"`,
}

Editor_Selection :: struct {
	document_id:     string `json:"document_id"`,
	editor_revision: u64    `json:"editor_revision"`,
	anchor_byte:     u64    `json:"anchor_byte"`,
	cursor_byte:     u64    `json:"cursor_byte"`,
	cursor_line:      u64    `json:"cursor_line"`,
}

Edit_Ack :: struct {
	document_id:     string `json:"document_id"`,
	editor_revision: u64    `json:"editor_revision"`,
	start_byte:      u64    `json:"start_byte"`,
	old_end_byte:    u64    `json:"old_end_byte"`,
	new_end_byte:    u64    `json:"new_end_byte"`,
	applied_replacement: []u8 `json:"applied_replacement"`,
}

Directory_Listing :: struct {
	relative_path: string           `json:"relative_path"`,
	limit:         int              `json:"limit"`,
	truncated:     bool             `json:"truncated"`,
	entries:       []Directory_Entry `json:"entries"`,
}

Directory_Entry :: struct {
	name: string `json:"name"`,
	path: string `json:"path"`,
	dir:  bool   `json:"dir"`,
}

Close_Decision :: struct {
	document_id: string `json:"document_id"`,
	dirty:       bool   `json:"dirty"`,
	can_save:    bool   `json:"can_save"`,
	can_discard: bool   `json:"can_discard"`,
}

Current_Match :: struct {
	start:  int `json:"start"`,
	end:    int `json:"end"`,
	line:   int `json:"line"`,
	column: int `json:"column"`,
}

Workspace_Search_Result :: struct {
	path:           string `json:"path"`,
	line:           int    `json:"line"`,
	column:         int    `json:"column"`,
	start_byte:     int    `json:"start_byte"`,
	end_byte:       int    `json:"end_byte"`,
	text:           string `json:"text"`,
	text_truncated: bool   `json:"text_truncated"`,
}

Workspace_Search_Page :: struct {
	generation: u64 `json:"generation"`,
	sequence:   u64 `json:"sequence"`,
	count:      u64 `json:"count"`,
	done:       bool `json:"done"`,
	truncated:  bool `json:"truncated"`,
	results:    []Workspace_Search_Result `json:"results"`,
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

Backend_Command_Request :: struct {
	version:          u32    `json:"version"`,
	request_id:       u64    `json:"request_id"`,
	based_on_revision: u64    `json:"based_on_revision"`,
	command:          string `json:"command"`,
	action_id:        string `json:"action_id,omitempty"`,
	path:             string `json:"path,omitempty"`,
	name:             string `json:"name,omitempty"`,
	disposition:      string `json:"disposition,omitempty"`,
	document_id:      string `json:"document_id,omitempty"`,
	discard:          bool   `json:"discard,omitempty"`,
	relative_path:    string `json:"relative_path,omitempty"`,
	limit:            int    `json:"limit,omitempty"`,
	start_line:       u64    `json:"start_line,omitempty"`,
	anchor_byte:      u64    `json:"anchor_byte,omitempty"`,
	max_lines:        u64    `json:"max_lines,omitempty"`,
	max_bytes:        u64    `json:"max_bytes,omitempty"`,
	include_presentation: bool `json:"include_presentation,omitempty"`,
	include_ignored: bool `json:"include_ignored,omitempty"`,
	query:            string `json:"query,omitempty"`,
	max_matches:      int    `json:"max_matches,omitempty"`,
	search_generation: u64   `json:"search_generation,omitempty"`,
	has_target_byte:  bool   `json:"has_target_byte,omitempty"`,
	target_byte:      u64    `json:"target_byte,omitempty"`,
	editor_revision:  u64    `json:"editor_revision"`,
	editor_anchor_byte: u64 `json:"editor_anchor_byte,omitempty"`,
	editor_cursor_byte: u64 `json:"editor_cursor_byte,omitempty"`,
	start_byte:         u64    `json:"start_byte,omitempty"`,
	end_byte:           u64    `json:"end_byte,omitempty"`,
	replacement:        []int  `json:"replacement,omitempty"`,
	has_selection_state: bool   `json:"has_selection_state,omitempty"`,
	before_anchor_byte: u64    `json:"before_anchor_byte,omitempty"`,
	before_cursor_byte: u64    `json:"before_cursor_byte,omitempty"`,
	after_anchor_byte:  u64    `json:"after_anchor_byte,omitempty"`,
	after_cursor_byte:  u64    `json:"after_cursor_byte,omitempty"`,
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
	for &action in state.actions {
		delete(action.id, allocator)
		delete(action.title, allocator)
		delete(action.category, allocator)
		for &binding in action.bindings { delete(binding, allocator) }
		delete(action.bindings, allocator)
	}
	delete(state.actions, allocator)
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
	resource_lease_acquired_fn: Backend_Lease_Proc,
	resource_lease_released_fn: Backend_Lease_Proc,
	free_fn:           Backend_Free_Proc,
	pump_fn:           Backend_Pump_Proc,
	api:               ^Caliber_Api_V1,
	caliber_context:   rawptr,
	waiter:            Waiter_State,
	state:             State_Envelope,
	state_allocator:   mem.Allocator,
	state_revision:    u64,
	state_leases:      int,
	resource_leases:   int,
	started:           bool,
	request_id:        u64,
	command_mutex:     sync.Mutex,
}

backend_load :: proc(backend: ^Backend, library_path: string) -> (ok: bool, message: string) {
	if backend == nil { return false, "backend state is nil" }
	if backend.library_loaded { return backend.load_error == "", backend.load_error }
	resolved_library_path := library_path
	owned_library_path := false
	if library_path == "" {
		directory, directory_error := os.get_executable_directory(context.allocator)
		if directory_error != nil { return false, "could not locate the Scratchpad executable directory" }
		name := "libscratchpad_backend.so"
		when ODIN_OS == .Windows { name = "scratchpad_backend.dll" }
		when ODIN_OS == .Darwin { name = "libscratchpad_backend.dylib" }
		resolved_path, join_error := os.join_path({directory, name}, context.allocator)
		delete(directory, context.allocator)
		if join_error != nil { return false, "could not resolve the sibling Scratchpad backend library" }
		resolved_library_path = resolved_path
		owned_library_path = true
	}
	library, loaded := dynlib.load_library(resolved_library_path)
	if !loaded {
		message := fmt.tprintf("load backend library %q: %s. Place the backend beside this application or set SCRATCHPAD_BACKEND_LIBRARY to override.", resolved_library_path, dynlib.last_error())
		if owned_library_path { delete(resolved_library_path, context.allocator) }
		return false, message
	}
	if owned_library_path { delete(resolved_library_path, context.allocator) }
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
	resource_lease_acquired := load_proc(library, "scratchpad_backend_resource_lease_acquired")
	resource_lease_released := load_proc(library, "scratchpad_backend_resource_lease_released")
	free_output := load_proc(library, "scratchpad_backend_free")
	pump := load_proc(library, "scratchpad_backend_pump")
	if start == nil || stop == nil || api == nil || ctx == nil || lease_acquired == nil || lease_released == nil || resource_lease_acquired == nil || resource_lease_released == nil || free_output == nil || pump == nil {
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
	backend.resource_lease_acquired_fn = transmute(Backend_Lease_Proc)(resource_lease_acquired)
	backend.resource_lease_released_fn = transmute(Backend_Lease_Proc)(resource_lease_released)
	backend.free_fn = transmute(Backend_Free_Proc)(free_output)
	backend.pump_fn = transmute(Backend_Pump_Proc)(pump)
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
	defer backend_response_destroy(&response, allocator)
	if status != 0 {
		_, _ = backend_stop_uninitialized(backend, allocator)
		return false, "scratchpad_backend_start returned a nonzero status"
	}
	if !response_ok || !backend_response_identity_matches(response, backend.request_id) {
		_, _ = backend_stop_uninitialized(backend, allocator)
		return false, "scratchpad_backend_start returned malformed or mismatched JSON"
	}
	if !response.ok {
		message, _ := strings.clone(response.outcome.message, allocator)
		if message == "" { message, _ = strings.clone(response.outcome.code, allocator) }
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
	       api.context_map_resource != nil &&
	       api.resource_release != nil &&
	       api.context_release_resource != nil &&
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

backend_release_resource_view :: proc(
	backend: ^Backend,
	view: ^Caliber_Resource_View,
	resource_id, generation: u64,
) {
	if backend == nil || view == nil { return }
	if view.lease != nil {
		release_view := transmute(Caliber_Release_Resource_Proc)(backend.api.resource_release)
		release_view(view)
	}
	release_resource := transmute(Caliber_Release_Context_Resource_Proc)(backend.api.context_release_resource)
	_ = release_resource(backend.caliber_context, resource_id, generation)
	if backend.resource_lease_released_fn() == 0 { backend.resource_leases -= 1 }
	view^ = {}
}

visible_slice_read_u32 :: proc(data: []u8, offset: int) -> u32 {
	return u32(data[offset]) |
	       u32(data[offset+1]) << 8 |
	       u32(data[offset+2]) << 16 |
	       u32(data[offset+3]) << 24
}

visible_slice_read_u64 :: proc(data: []u8, offset: int) -> u64 {
	low := u64(visible_slice_read_u32(data, offset))
	high := u64(visible_slice_read_u32(data, offset+4))
	return low | high << 32
}

visible_window_decode :: proc(
	data: []u8,
	descriptor: Resource_Descriptor,
	expected_document_id: string,
	include_presentation := false,
	allocator := context.allocator,
) -> (window: Visible_Window, ok: bool, message: string) {
	if descriptor.resource_id == 0 || descriptor.generation == 0 || descriptor.document_id != expected_document_id {
		return {}, false, "visible resource identity does not match the requested document"
	}
	if descriptor.byte_len > MAX_VISIBLE_BYTES || descriptor.end_line < descriptor.start_line || descriptor.end_line-descriptor.start_line > MAX_VISIBLE_LINES {
		return {}, false, "visible resource descriptor exceeds the bounded window limits"
	}
	if descriptor.start_byte > max(u64)-descriptor.byte_len {
		return {}, false, "visible source byte range overflows its absolute coordinate"
	}
	if descriptor.line_byte_length > 0 &&
	   (descriptor.end_line != descriptor.start_line+1 || descriptor.byte_len > descriptor.line_byte_length) {
		return {}, false, "visible line-chunk metadata is inconsistent with the bounded resource"
	}
	if len(data) < VISIBLE_SLICE_HEADER_BYTES || string(data[:4]) != "SPVS" {
		return {}, false, "visible resource has a truncated or invalid SPVS header"
	}
	schema := visible_slice_read_u32(data, 4)
	if schema != VISIBLE_SLICE_SCHEMA_V1 && schema != VISIBLE_SLICE_SCHEMA_V2 {
		return {}, false, "visible resource uses an unsupported SPVS schema"
	}
	application_revision := visible_slice_read_u64(data, 8)
	editor_revision := visible_slice_read_u64(data, 16)
	start_line := visible_slice_read_u64(data, 24)
	end_line := visible_slice_read_u64(data, 32)
	flags := visible_slice_read_u32(data, 40)
	byte_len := visible_slice_read_u32(data, 44)
	if flags > 1 || ((flags & 1) != 0) != descriptor.truncated {
		return {}, false, "visible resource flags do not match its descriptor"
	}
	if u64(byte_len) != descriptor.byte_len || u64(len(data)) != u64(VISIBLE_SLICE_HEADER_BYTES)+descriptor.byte_len+descriptor.metadata_byte_len {
		return {}, false, "visible resource payload length does not match its descriptor"
	}
	if application_revision != descriptor.application_rev || editor_revision != descriptor.editor_revision ||
	   start_line != descriptor.start_line || end_line != descriptor.end_line {
		return {}, false, "SPVS revisions or line bounds do not match the resource descriptor"
	}
	if include_presentation != (schema == VISIBLE_SLICE_SCHEMA_V2) {
		return {}, false, "visible resource schema does not match presentation request mode"
	}
	if schema == VISIBLE_SLICE_SCHEMA_V1 && descriptor.metadata_byte_len != 0 {
		return {}, false, "SPVS v1 descriptor unexpectedly includes metadata bytes"
	}
	if schema == VISIBLE_SLICE_SCHEMA_V2 && !presentation_metadata_valid(data, descriptor.byte_len, descriptor.metadata_byte_len) {
		return {}, false, "SPVS v2 presentation metadata is malformed or exceeds its bounds"
	}
	document_id, clone_error := strings.clone(descriptor.document_id, allocator)
	if clone_error != nil { return {}, false, "could not retain visible resource document identity" }
	source, allocation_error := make([]u8, int(byte_len), allocator)
	if allocation_error != nil {
		delete(document_id, allocator)
		return {}, false, "could not retain bounded visible source bytes"
	}
	if byte_len > 0 { mem.copy(rawptr(&source[0]), rawptr(&data[VISIBLE_SLICE_HEADER_BYTES]), int(byte_len)) }
	window = Visible_Window{
		document_id=document_id,
		application_rev=application_revision,
		editor_revision=editor_revision,
		start_line=start_line,
		end_line=end_line,
		start_byte=descriptor.start_byte,
		line_byte_length=descriptor.line_byte_length,
		truncated=descriptor.truncated,
		source=source,
	}
	if schema == VISIBLE_SLICE_SCHEMA_V2 {
		if !visible_window_copy_presentation(&window, data, descriptor.byte_len, allocator) {
			visible_window_destroy(&window, allocator)
			return {}, false, "could not retain bounded Markdown presentation metadata"
		}
	}
	return window, true, ""
}

presentation_metadata_valid :: proc(data: []u8, source_byte_len, metadata_byte_len: u64) -> bool {
	if metadata_byte_len < PRESENTATION_TRAILER_BYTES || metadata_byte_len > PRESENTATION_TRAILER_BYTES+PRESENTATION_MAX_RECORDS*PRESENTATION_RECORD_BYTES {
		return false
	}
	metadata_start := VISIBLE_SLICE_HEADER_BYTES+int(source_byte_len)
	if metadata_start < VISIBLE_SLICE_HEADER_BYTES || metadata_start+int(metadata_byte_len) != len(data) { return false }
	trailer := data[metadata_start:metadata_start+PRESENTATION_TRAILER_BYTES]
	flags := visible_slice_read_u32(trailer, 8)
	span_count := visible_slice_read_u32(trailer, 12)
	block_count := visible_slice_read_u32(trailer, 16)
	reserved := visible_slice_read_u32(trailer, 20)
	record_count := u64(span_count)+u64(block_count)
	if flags & ~(PRESENTATION_READY_FLAG|PRESENTATION_TRUNCATED_FLAG) != 0 || reserved != 0 ||
	   record_count > PRESENTATION_MAX_RECORDS ||
	   u64(PRESENTATION_TRAILER_BYTES)+record_count*PRESENTATION_RECORD_BYTES != metadata_byte_len {
		return false
	}
	for index in 0..<int(record_count) {
		record_offset := metadata_start+PRESENTATION_TRAILER_BYTES+index*PRESENTATION_RECORD_BYTES
		kind := visible_slice_read_u32(data, record_offset)
		start := visible_slice_read_u32(data, record_offset+4)
		end := visible_slice_read_u32(data, record_offset+8)
		level_flags := visible_slice_read_u32(data, record_offset+12)
		is_span := kind >= 1 && kind <= 33
		is_block := kind >= 0x10001 && kind <= 0x10005
		if !is_span && !is_block || (index < int(span_count)) != is_span || end <= start || u64(end) > source_byte_len { return false }
		if is_span && level_flags > 255 { return false }
		if is_block && level_flags & ~u32(0x3FF) != 0 { return false }
	}
	return true
}

visible_window_copy_presentation :: proc(window: ^Visible_Window, data: []u8, source_byte_len: u64, allocator: mem.Allocator) -> bool {
	if window == nil { return false }
	metadata_start := VISIBLE_SLICE_HEADER_BYTES+int(source_byte_len)
	trailer := data[metadata_start:metadata_start+PRESENTATION_TRAILER_BYTES]
	window.presentation_revision = visible_slice_read_u64(trailer, 0)
	flags := visible_slice_read_u32(trailer, 8)
	span_count := int(visible_slice_read_u32(trailer, 12))
	block_count := int(visible_slice_read_u32(trailer, 16))
	window.presentation_ready = flags & PRESENTATION_READY_FLAG != 0
	window.presentation_truncated = flags & PRESENTATION_TRUNCATED_FLAG != 0
	if window.presentation_ready && window.presentation_revision != window.editor_revision { return false }
	spans, span_err := make([]Presentation_Record, span_count, allocator)
	if span_err != nil { return false }
	blocks, block_err := make([]Presentation_Record, block_count, allocator)
	if block_err != nil { delete(spans, allocator); return false }
	for index in 0..<span_count+block_count {
		record_offset := metadata_start+PRESENTATION_TRAILER_BYTES+index*PRESENTATION_RECORD_BYTES
		record := Presentation_Record{
			kind=visible_slice_read_u32(data, record_offset),
			start_byte=visible_slice_read_u32(data, record_offset+4),
			end_byte=visible_slice_read_u32(data, record_offset+8),
			level_flags=visible_slice_read_u32(data, record_offset+12),
		}
		if index < span_count { spans[index] = record } else { blocks[index-span_count] = record }
	}
	window.presentation_spans = spans
	window.presentation_blocks = blocks
	return true
}

backend_copy_visible_resource :: proc(
	backend: ^Backend,
	descriptor: Resource_Descriptor,
	expected_document_id: string,
	include_presentation := false,
	allocator := context.allocator,
) -> (window: Visible_Window, ok: bool, message: string) {
	if backend == nil || backend.api == nil || backend.caliber_context == nil {
		return {}, false, "Caliber resource context is unavailable"
	}
	map_resource := transmute(Caliber_Map_Resource_Proc)(backend.api.context_map_resource)
	view: Caliber_Resource_View
	status := map_resource(backend.caliber_context, descriptor.resource_id, descriptor.generation, &view)
	if status != .OK { return {}, false, fmt.tprintf("Caliber context_map_resource failed with status %d", status) }
	if backend.resource_lease_acquired_fn() != 0 {
		if view.lease != nil {
			release_view := transmute(Caliber_Release_Resource_Proc)(backend.api.resource_release)
			release_view(&view)
		}
		release_resource := transmute(Caliber_Release_Context_Resource_Proc)(backend.api.context_release_resource)
		_ = release_resource(backend.caliber_context, descriptor.resource_id, descriptor.generation)
		return {}, false, "backend rejected Caliber resource lease accounting"
	}
	backend.resource_leases += 1
	defer backend_release_resource_view(backend, &view, descriptor.resource_id, descriptor.generation)
	if view.resource_id != descriptor.resource_id || view.generation != descriptor.generation {
		return {}, false, "Caliber returned a mismatched resource handle"
	}
	max_metadata := PRESENTATION_TRAILER_BYTES+PRESENTATION_MAX_RECORDS*PRESENTATION_RECORD_BYTES
	if view.len < VISIBLE_SLICE_HEADER_BYTES || view.len > uintptr(VISIBLE_SLICE_HEADER_BYTES)+uintptr(MAX_VISIBLE_BYTES)+uintptr(max_metadata) {
		return {}, false, "Caliber visible resource exceeds the SPVS byte limit"
	}
	if view.data == nil { return {}, false, "Caliber returned a null visible resource payload" }
	data, allocation_error := make([]u8, int(view.len), allocator)
	if allocation_error != nil { return {}, false, "could not copy Caliber visible resource" }
	defer delete(data, allocator)
	mem.copy(rawptr(&data[0]), rawptr(view.data), int(view.len))
	return visible_window_decode(data, descriptor, expected_document_id, include_presentation, allocator)
}

backend_consume_wake :: proc(backend: ^Backend, allocator := context.allocator) -> (changed: bool, ok: bool, message: string) {
	if backend == nil || !backend.started { return false, false, "backend is not running" }
	sync.mutex_lock(&backend.command_mutex)
	defer sync.mutex_unlock(&backend.command_mutex)
	if !backend.started { return false, false, "backend is not running" }
	// Clear before reading. A concurrent publication then appears in this read
	// or queues another wake, so no latest-value update can be lost.
	wake_coalescer_consume(&backend.waiter.pending)
	return backend_read_latest(backend, allocator)
}

Backend_Command_Result :: struct {
	ok:             bool,
	state_changed:  bool,
	revision:       u64,
	edit:           Edit_Ack,
	editor_selection: Editor_Selection,
	matches:        []Current_Match,
	matches_truncated: bool,
	workspace_search_page: Workspace_Search_Page,
	code:           string,
	message:        string,
	command_outcome: string,
	directory_listing: Directory_Listing,
	close_decision: Close_Decision,
	visible_window:  Visible_Window,
	code_owned:     bool,
	message_owned:  bool,
	command_outcome_owned: bool,
	directory_listing_owned: bool,
	close_id_owned: bool,
	edit_document_id_owned: bool,
	edit_applied_replacement_owned: bool,
	editor_selection_document_id_owned: bool,
	visible_window_owned: bool,
	matches_owned: bool,
	search_page_owned: bool,
}

backend_command :: proc(
	backend: ^Backend,
	command: string,
	action_id := "",
	path := "",
	name := "",
	disposition := "",
	document_id := "",
	discard := false,
	relative_path := "",
	start_line: u64 = 0,
	anchor_byte: u64 = 0,
	max_lines: u64 = 0,
	max_bytes: u64 = 0,
	editor_revision: u64 = 0,
	editor_anchor_byte: u64 = 0,
	editor_cursor_byte: u64 = 0,
	start_byte: u64 = 0,
	end_byte: u64 = 0,
	replacement: []int = {},
	has_selection_state := false,
	before_anchor_byte: u64 = 0,
	before_cursor_byte: u64 = 0,
	after_anchor_byte: u64 = 0,
	after_cursor_byte: u64 = 0,
	include_presentation := false,
	include_ignored := false,
	query := "",
	max_matches: int = 0,
	search_generation: u64 = 0,
	has_target_byte := false,
	target_byte: u64 = 0,
	based_on_revision: u64 = 0,
	read_latest_after := true,
	allocator := context.allocator,
) -> (result: Backend_Command_Result) {
	if backend == nil || !backend.started || backend.api == nil || backend.caliber_context == nil {
		return Backend_Command_Result{code="not_running", message="backend is not running"}
	}
	sync.mutex_lock(&backend.command_mutex)
	defer sync.mutex_unlock(&backend.command_mutex)
	if !backend.started || backend.api == nil || backend.caliber_context == nil {
		return Backend_Command_Result{code="not_running", message="backend is not running"}
	}
	if len(command) == 0 { return Backend_Command_Result{code="invalid_command", message="command is empty"} }
	backend.request_id += 1
	request_revision := based_on_revision
	if request_revision == 0 { request_revision = backend.state.application_rev }
	request := Backend_Command_Request{
		version=1,
		request_id=backend.request_id,
		based_on_revision=request_revision,
		command=command,
		action_id=action_id,
		path=path,
		name=name,
		disposition=disposition,
		document_id=document_id,
		discard=discard,
		relative_path=relative_path,
		limit=200,
		start_line=start_line,
		anchor_byte=anchor_byte,
		max_lines=max_lines,
		max_bytes=max_bytes,
		editor_revision=editor_revision,
		editor_anchor_byte=editor_anchor_byte,
		editor_cursor_byte=editor_cursor_byte,
		start_byte=start_byte,
		end_byte=end_byte,
		replacement=replacement,
		has_selection_state=has_selection_state,
		before_anchor_byte=before_anchor_byte,
		before_cursor_byte=before_cursor_byte,
		after_anchor_byte=after_anchor_byte,
		after_cursor_byte=after_cursor_byte,
		include_presentation=include_presentation,
		include_ignored=include_ignored,
		query=query,
		max_matches=max_matches,
		search_generation=search_generation,
		has_target_byte=has_target_byte,
		target_byte=target_byte,
	}
	request_bytes, marshal_err := json.marshal(request, allocator=allocator)
	if marshal_err != nil { return Backend_Command_Result{code="encode_failed", message="could not encode Scratchpad command"} }
	defer delete(request_bytes, allocator)
	dispatch := transmute(Caliber_Dispatch_Proc)(backend.api.context_dispatch)
	if dispatch == nil { return Backend_Command_Result{code="caliber_unavailable", message="Caliber context_dispatch is unavailable"} }
	if dispatch(backend.caliber_context, &request_bytes[0], uintptr(len(request_bytes))) != .OK {
		return Backend_Command_Result{code="dispatch_failed", message="Caliber rejected the Scratchpad command"}
	}
	output: ^u8
	output_len: uintptr
	status := backend.pump_fn(&output, &output_len)
	response, response_ok := backend_decode_response(output, output_len, backend.free_fn, allocator)
	if status != 0 || !response_ok {
		backend_response_destroy(&response, allocator)
		return Backend_Command_Result{code="malformed_response", message="scratchpad_backend_pump returned an invalid response"}
	}
	if !backend_response_identity_matches(response, backend.request_id) {
		backend_response_destroy(&response, allocator)
		return Backend_Command_Result{code="response_mismatch", message="Scratchpad command response had a mismatched request ID"}
	}
	result.ok = response.ok
	result.revision = response.revision
	if response.ok && command == "replace_document" {
		if response.edit.document_id == "" || response.edit.editor_revision == 0 {
			backend_response_destroy(&response, allocator)
			return Backend_Command_Result{code="malformed_edit_ack", message="Scratchpad returned a successful edit without a valid revision acknowledgement"}
		}
		result.edit = response.edit
		result.edit.document_id, _ = strings.clone(response.edit.document_id, allocator)
		result.edit_document_id_owned = len(result.edit.document_id) > 0
		if len(response.edit.applied_replacement) > 0 {
			applied_copy, allocation_error := make([]u8, len(response.edit.applied_replacement), allocator=allocator)
			if allocation_error != nil {
				backend_response_destroy(&response, allocator)
				backend_command_result_destroy(&result, allocator)
				return Backend_Command_Result{code="allocation_failed", message="could not retain applied replacement bytes"}
			}
			mem.copy(rawptr(&applied_copy[0]), rawptr(&response.edit.applied_replacement[0]), len(response.edit.applied_replacement))
			result.edit.applied_replacement = applied_copy
			result.edit_applied_replacement_owned = true
		}
	}
	if response.ok && (command == "edit.undo" || command == "edit.redo" || command == "execute_command" || command == "open_path") && response.editor_selection.document_id != "" {
		result.editor_selection = response.editor_selection
		result.editor_selection.document_id, _ = strings.clone(response.editor_selection.document_id, allocator)
		result.editor_selection_document_id_owned = len(result.editor_selection.document_id) > 0
	}
	code_copy, code_clone_err := strings.clone(response.outcome.code, allocator)
	result.code = code_copy
	result.code_owned = code_clone_err == nil && len(result.code) > 0
	command_outcome_copy, command_outcome_clone_err := strings.clone(response.command_outcome, allocator)
	result.command_outcome = command_outcome_copy
	result.command_outcome_owned = command_outcome_clone_err == nil && len(result.command_outcome) > 0
	message_copy, message_clone_err := strings.clone(response.outcome.message, allocator)
	result.message = message_copy
	result.message_owned = message_clone_err == nil && len(result.message) > 0
	if len(response.close_decision.document_id) > 0 {
		result.close_decision = response.close_decision
		close_id_copy, close_id_clone_err := strings.clone(response.close_decision.document_id, allocator)
		result.close_decision.document_id = close_id_copy
		result.close_id_owned = close_id_clone_err == nil && len(result.close_decision.document_id) > 0
	}
	if response.directory_listing.limit > 0 {
		listing, listing_ok := directory_listing_clone(response.directory_listing, allocator)
		if !listing_ok {
			backend_response_destroy(&response, allocator)
			backend_command_result_destroy(&result, allocator)
			return Backend_Command_Result{code="allocation_failed", message="could not retain the directory listing"}
		}
		result.directory_listing = listing
		result.directory_listing_owned = true
	}
	if response.ok && command == "find_current" && len(response.matches) > 0 {
		result.matches = make([]Current_Match, len(response.matches), allocator=allocator)
		copy(result.matches[:], response.matches[:])
		result.matches_truncated = response.matches_truncated
		result.matches_owned = true
	}
	if response.ok && command == "workspace_search_take_page" && response.workspace_search_page.generation != 0 {
		page, page_ok := workspace_search_page_clone(response.workspace_search_page, allocator)
		if !page_ok {
			backend_response_destroy(&response, allocator)
			backend_command_result_destroy(&result, allocator)
			return Backend_Command_Result{code="allocation_failed", message="could not retain workspace search results"}
		}
		result.workspace_search_page = page
		result.search_page_owned = true
	}
	if response.ok && command == "read_visible_lines" {
		window, window_ok, window_message := backend_copy_visible_resource(backend, response.resource, document_id, include_presentation, allocator)
		if !window_ok {
			backend_response_destroy(&response, allocator)
			backend_command_result_destroy(&result, allocator)
			return Backend_Command_Result{code="visible_resource_invalid", message=window_message}
		}
		result.visible_window = window
		result.visible_window_owned = true
	}
	backend_response_destroy(&response, allocator)
	if !result.ok {
		if result.message == "" { result.message = result.code }
		return result
	}
	if command == "read_visible_lines" { return result }
	if !read_latest_after { return result }
	changed, read_ok, read_message := backend_read_latest(backend, allocator)
	if !read_ok {
		result.ok = false
		if result.code_owned { delete(result.code, allocator) }
		result.code = "state_read_failed"
		result.code_owned = false
		if result.message_owned { delete(result.message, allocator) }
		message_copy, message_clone_err := strings.clone(read_message, allocator)
		result.message = message_copy
		result.message_owned = message_clone_err == nil && len(result.message) > 0
		return result
	}
	result.state_changed = changed
	return result
}

backend_command_result_destroy :: proc(result: ^Backend_Command_Result, allocator: mem.Allocator) {
	if result == nil { return }
	if result.code_owned { delete(result.code, allocator) }
	if result.command_outcome_owned { delete(result.command_outcome, allocator) }
	if result.message_owned { delete(result.message, allocator) }
	if result.directory_listing_owned { directory_listing_destroy(&result.directory_listing, allocator) }
	if result.close_id_owned { delete(result.close_decision.document_id, allocator) }
	if result.edit_document_id_owned { delete(result.edit.document_id, allocator) }
	if result.edit_applied_replacement_owned { delete(result.edit.applied_replacement, allocator) }
	if result.editor_selection_document_id_owned { delete(result.editor_selection.document_id, allocator) }
	if result.visible_window_owned { visible_window_destroy(&result.visible_window, allocator) }
	if result.matches_owned { delete(result.matches, allocator) }
	if result.search_page_owned { workspace_search_page_destroy(&result.workspace_search_page, allocator) }
	result^ = {}
}

visible_window_destroy :: proc(window: ^Visible_Window, allocator: mem.Allocator) {
	if window == nil { return }
	if len(window.document_id) > 0 { delete(window.document_id, allocator) }
	delete(window.source, allocator)
	delete(window.presentation_spans, allocator)
	delete(window.presentation_blocks, allocator)
	window^ = {}
}

Visible_Window_Request :: struct {
	document_id:       string,
	application_rev:   u64,
	editor_revision:   u64,
	start_line:        u64,
	anchor_byte:       u64,
	max_lines:         u64,
	max_bytes:         u64,
	include_presentation: bool,
	presentation_revision: u64,
	presentation_ready: bool,
	generation:        u64,
}

Visible_Window_Lane_Result :: struct {
	generation: u64,
	request:    Visible_Window_Request,
	window:     Visible_Window,
	error:      string,
	window_owned: bool,
	error_owned: bool,
}

Visible_Window_Lane :: struct {
	backend:            ^Backend,
	wake:               Application_Wake_Proc,
	wake_data:          rawptr,
	allocator:          mem.Allocator,
	mutex:              sync.Mutex,
	sema:               sync.Sema,
	thread:             ^thread.Thread,
	stopping:           u32,
	wake_posted:        bool,
	pending:            bool,
	pending_request:    Visible_Window_Request,
	active:             bool,
	active_request:     Visible_Window_Request,
	latest_generation:  u64,
	completed:          Visible_Window_Lane_Result,
	completed_ready:    bool,
	submitted:          u64,
	coalesced:          u64,
	stale_discarded:    u64,
}

visible_window_request_equal :: proc(a, b: Visible_Window_Request) -> bool {
	return a.document_id == b.document_id &&
	       a.application_rev == b.application_rev &&
	       a.editor_revision == b.editor_revision &&
	       a.start_line == b.start_line &&
	       a.anchor_byte == b.anchor_byte &&
	       a.max_lines == b.max_lines &&
	       a.max_bytes == b.max_bytes &&
	       a.include_presentation == b.include_presentation &&
	       a.presentation_revision == b.presentation_revision &&
	       a.presentation_ready == b.presentation_ready
}

visible_window_result_is_current :: proc(stopping: u32, result_generation, latest_generation: u64) -> bool {
	return stopping == 0 && result_generation != 0 && result_generation == latest_generation
}

visible_window_lane_worker :: proc(t: ^thread.Thread) {
	lane := cast(^Visible_Window_Lane)t.data
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

		result := backend_command(
			lane.backend,
			"read_visible_lines",
			document_id=request.document_id,
			start_line=request.start_line,
			anchor_byte=request.anchor_byte,
			max_lines=request.max_lines,
			max_bytes=request.max_bytes,
			include_presentation=request.include_presentation,
			based_on_revision=request.application_rev,
			allocator=lane.allocator,
		)

		sync.mutex_lock(&lane.mutex)
		is_current := visible_window_result_is_current(sync.atomic_load(&lane.stopping), request.generation, lane.latest_generation)
		lane.active = false
		// request is a shallow ownership copy of active_request. Clear the lane's
		// view here, then release the single owned string through request below.
		lane.active_request = {}
		if is_current {
			visible_window_lane_result_destroy(&lane.completed, lane.allocator)
			lane.completed.generation = request.generation
			lane.completed.request = request
			// The completed result now owns the request identity. It is needed by
			// the application to suppress retries of a rejected response.
			request.document_id = ""
			if result.ok && result.visible_window_owned {
				lane.completed.window = result.visible_window
				lane.completed.window_owned = true
				result.visible_window_owned = false
			} else {
				error_text := result.message
				if error_text == "" { error_text = result.code }
				lane.completed.error, _ = strings.clone(error_text, lane.allocator)
				lane.completed.error_owned = len(lane.completed.error) > 0
			}
			lane.completed_ready = true
		} else {
			lane.stale_discarded += 1
		}
		wake := lane.wake
		wake_data := lane.wake_data
		sync.mutex_unlock(&lane.mutex)

		backend_command_result_destroy(&result, lane.allocator)
		delete(request.document_id, lane.allocator)
		if is_current && wake != nil { wake(wake_data) }
	}
}

visible_window_lane_start :: proc(
	lane: ^Visible_Window_Lane,
	backend: ^Backend,
	wake: Application_Wake_Proc,
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
	lane.completed_ready = false
	lane.completed = {}
	lane.submitted = 0
	lane.coalesced = 0
	lane.stale_discarded = 0
	lane.sema = {}
	lane.thread = thread.create(visible_window_lane_worker, name="Scratchpad visible-window lane")
	if lane.thread == nil { return false }
	lane.thread.data = rawptr(lane)
	thread.start(lane.thread)
	return true
}

visible_window_lane_request :: proc(
	lane: ^Visible_Window_Lane,
	document_id: string,
	application_rev, editor_revision, start_line, max_lines, max_bytes: u64,
	anchor_byte: u64 = 0,
	include_presentation := false,
	presentation_revision: u64 = 0,
	presentation_ready := false,
) -> (generation: u64, accepted: bool, message: string) {
	if lane == nil || lane.thread == nil || len(document_id) == 0 {
		return 0, false, "visible-window lane is not running or document identity is empty"
	}
	if max_lines == 0 || max_lines > MAX_VISIBLE_LINES || max_bytes == 0 || max_bytes > MAX_VISIBLE_BYTES {
		return 0, false, "visible-window request exceeds the bounded line or byte limit"
	}
	if sync.atomic_load(&lane.stopping) != 0 { return 0, false, "visible-window lane is stopping" }
	sync.mutex_lock(&lane.mutex)
	if sync.atomic_load(&lane.stopping) != 0 {
		sync.mutex_unlock(&lane.mutex)
		return 0, false, "visible-window lane is stopping"
	}
	if lane.pending && visible_window_request_equal(lane.pending_request, Visible_Window_Request{
		document_id=document_id, application_rev=application_rev, editor_revision=editor_revision,
		start_line=start_line, anchor_byte=anchor_byte, max_lines=max_lines, max_bytes=max_bytes,
		include_presentation=include_presentation, presentation_revision=presentation_revision,
		presentation_ready=presentation_ready,
	}) {
		generation = lane.pending_request.generation
		sync.mutex_unlock(&lane.mutex)
		return generation, true, ""
	}
	if lane.active && !lane.pending && visible_window_request_equal(lane.active_request, Visible_Window_Request{
		document_id=document_id, application_rev=application_rev, editor_revision=editor_revision,
		start_line=start_line, anchor_byte=anchor_byte, max_lines=max_lines, max_bytes=max_bytes,
		include_presentation=include_presentation, presentation_revision=presentation_revision,
		presentation_ready=presentation_ready,
	}) {
		generation = lane.active_request.generation
		sync.mutex_unlock(&lane.mutex)
		return generation, true, ""
	}
	owned_document_id, clone_err := strings.clone(document_id, lane.allocator)
	if clone_err != nil {
		sync.mutex_unlock(&lane.mutex)
		return 0, false, "could not retain visible-window document identity"
	}
	lane.latest_generation += 1
	if lane.latest_generation == 0 { lane.latest_generation = 1 }
	generation = lane.latest_generation
	if lane.pending {
		delete(lane.pending_request.document_id, lane.allocator)
		lane.coalesced += 1
	} else if lane.active {
		lane.coalesced += 1
	}
	lane.pending_request = Visible_Window_Request{
		document_id=owned_document_id,
		application_rev=application_rev,
		editor_revision=editor_revision,
		start_line=start_line,
		anchor_byte=anchor_byte,
		max_lines=max_lines,
		max_bytes=max_bytes,
		include_presentation=include_presentation,
		presentation_revision=presentation_revision,
		presentation_ready=presentation_ready,
		generation=generation,
	}
	lane.pending = true
	lane.submitted += 1
	if !lane.wake_posted {
		lane.wake_posted = true
		sync.sema_post(&lane.sema)
	}
	sync.mutex_unlock(&lane.mutex)
	return generation, true, ""
}

visible_window_lane_take :: proc(lane: ^Visible_Window_Lane) -> (result: Visible_Window_Lane_Result, found: bool) {
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

visible_window_lane_result_destroy :: proc(result: ^Visible_Window_Lane_Result, allocator: mem.Allocator) {
	if result == nil { return }
	if len(result.request.document_id) > 0 { delete(result.request.document_id, allocator) }
	if result.window_owned { visible_window_destroy(&result.window, allocator) }
	if result.error_owned { delete(result.error, allocator) }
	result^ = {}
}

visible_window_lane_stop :: proc(lane: ^Visible_Window_Lane) -> bool {
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
	visible_window_lane_result_destroy(&lane.completed, lane.allocator)
	lane.completed_ready = false
	lane.backend = nil
	lane.wake = nil
	lane.wake_data = nil
	return !lane.active && !lane.pending
}

Editor_Edit_Request :: struct {
	sequence:          u64,
	document_id:       string,
	based_on_revision: u64,
	editor_revision:   u64,
	start_byte:        u64,
	end_byte:          u64,
	has_selection_state: bool,
	before_anchor_byte: u64,
	before_cursor_byte: u64,
	after_anchor_byte:  u64,
	after_cursor_byte:  u64,
	replacement:       []u8,
}

Editor_Edit_Lane_Result :: struct {
	sequence:    u64,
	document_id: string,
	command:     Backend_Command_Result,
}

// One request is submitted at a time. Scratchpad's Alicorn app retains the
// local keystroke queue and submits its head only after this lane's ack arrives.
Editor_Edit_Lane :: struct {
	backend:             ^Backend,
	wake:                Application_Wake_Proc,
	wake_data:           rawptr,
	allocator:           mem.Allocator,
	mutex:               sync.Mutex,
	sema:                sync.Sema,
	completion_sema:     sync.Sema,
	thread:              ^thread.Thread,
	stopping:            u32,
	pending:             bool,
	pending_request:     Editor_Edit_Request,
	active:              bool,
	completed:           Editor_Edit_Lane_Result,
	completed_ready:     bool,
	test_dispatch_gate:  ^sync.Sema,
}

editor_edit_request_destroy :: proc(request: ^Editor_Edit_Request, allocator: mem.Allocator) {
	if request == nil { return }
	if len(request.document_id) > 0 { delete(request.document_id, allocator) }
	delete(request.replacement, allocator)
	request^ = {}
}

editor_edit_lane_result_destroy :: proc(result: ^Editor_Edit_Lane_Result, allocator: mem.Allocator) {
	if result == nil { return }
	if len(result.document_id) > 0 { delete(result.document_id, allocator) }
	backend_command_result_destroy(&result.command, allocator)
	result^ = {}
}

editor_edit_lane_worker :: proc(t: ^thread.Thread) {
	lane := cast(^Editor_Edit_Lane)t.data
	for {
		sync.sema_wait(&lane.sema)
		sync.mutex_lock(&lane.mutex)
		if sync.atomic_load(&lane.stopping) != 0 && !lane.pending {
			sync.mutex_unlock(&lane.mutex)
			break
		}
		if !lane.pending {
			sync.mutex_unlock(&lane.mutex)
			continue
		}
		request := lane.pending_request
		lane.pending_request = {}
		lane.pending = false
		lane.active = true
		sync.mutex_unlock(&lane.mutex)

		if lane.test_dispatch_gate != nil { sync.sema_wait(lane.test_dispatch_gate) }
		replacement, allocation_error := make([]int, len(request.replacement), allocator=lane.allocator)
		result: Backend_Command_Result
		if allocation_error != nil {
			result = Backend_Command_Result{code="allocation_failed", message="could not encode the bounded optimistic edit"}
		} else {
			for value, index in request.replacement { replacement[index] = int(value) }
			result = backend_command(
				lane.backend,
				"replace_document",
				document_id=request.document_id,
				editor_revision=request.editor_revision,
				start_byte=request.start_byte,
				end_byte=request.end_byte,
				replacement=replacement,
				has_selection_state=request.has_selection_state,
				before_anchor_byte=request.before_anchor_byte,
				before_cursor_byte=request.before_cursor_byte,
				after_anchor_byte=request.after_anchor_byte,
				after_cursor_byte=request.after_cursor_byte,
				based_on_revision=request.based_on_revision,
				read_latest_after=false,
				allocator=lane.allocator,
			)
			delete(replacement, lane.allocator)
		}

		sync.mutex_lock(&lane.mutex)
		lane.completed = Editor_Edit_Lane_Result{
			sequence=request.sequence,
			document_id=request.document_id,
			command=result,
		}
		request.document_id = ""
		delete(request.replacement, lane.allocator)
		lane.completed_ready = true
		lane.active = false
		wake := lane.wake
		wake_data := lane.wake_data
		sync.mutex_unlock(&lane.mutex)
		sync.sema_post(&lane.completion_sema)
		if wake != nil { wake(wake_data) }
		sync.mutex_lock(&lane.mutex)
		should_stop := sync.atomic_load(&lane.stopping) != 0 && !lane.pending
		sync.mutex_unlock(&lane.mutex)
		if should_stop { break }
	}
}

editor_edit_lane_start :: proc(
	lane: ^Editor_Edit_Lane,
	backend: ^Backend,
	wake: Application_Wake_Proc,
	wake_data: rawptr,
	allocator := context.allocator,
	test_dispatch_gate: ^sync.Sema = nil,
) -> bool {
	if lane == nil || backend == nil || !backend.started || lane.thread != nil { return false }
	lane.backend = backend
	lane.wake = wake
	lane.wake_data = wake_data
	lane.allocator = allocator
	lane.stopping = 0
	lane.pending = false
	lane.pending_request = {}
	lane.active = false
	lane.completed_ready = false
	lane.completed = {}
	lane.test_dispatch_gate = test_dispatch_gate
	lane.sema = {}
	lane.completion_sema = {}
	lane.thread = thread.create(editor_edit_lane_worker, name="Scratchpad optimistic editor edit lane")
	if lane.thread == nil { return false }
	lane.thread.data = rawptr(lane)
	thread.start(lane.thread)
	return true
}

editor_edit_lane_submit :: proc(
	lane: ^Editor_Edit_Lane,
	sequence: u64,
	document_id: string,
	based_on_revision, editor_revision, start_byte, end_byte: u64,
	replacement: []u8,
	before_anchor_byte, before_cursor_byte, after_anchor_byte, after_cursor_byte: u64,
) -> (accepted: bool, message: string) {
	if lane == nil || lane.thread == nil || len(document_id) == 0 || sequence == 0 {
		return false, "editor edit lane is not running or request identity is invalid"
	}
	if end_byte < start_byte || len(replacement) > int(MAX_EDIT_BYTES) {
		return false, "editor edit request is invalid or exceeds the 128 KiB payload limit"
	}
	if sync.atomic_load(&lane.stopping) != 0 { return false, "editor edit lane is stopping" }
	sync.mutex_lock(&lane.mutex)
	defer sync.mutex_unlock(&lane.mutex)
	if sync.atomic_load(&lane.stopping) != 0 || lane.pending || lane.active || lane.completed_ready {
		return false, "editor edit lane is not ready for another in-flight request"
	}
	owned_id, id_error := strings.clone(document_id, lane.allocator)
	if id_error != nil { return false, "could not retain editor edit document identity" }
	owned_bytes, bytes_error := make([]u8, len(replacement), allocator=lane.allocator)
	if bytes_error != nil {
		delete(owned_id, lane.allocator)
		return false, "could not retain editor edit bytes"
	}
	if len(replacement) > 0 { copy(owned_bytes, replacement) }
	lane.pending_request = Editor_Edit_Request{
		sequence=sequence,
		document_id=owned_id,
		based_on_revision=based_on_revision,
		editor_revision=editor_revision,
		start_byte=start_byte,
		end_byte=end_byte,
		has_selection_state=true,
		before_anchor_byte=before_anchor_byte,
		before_cursor_byte=before_cursor_byte,
		after_anchor_byte=after_anchor_byte,
		after_cursor_byte=after_cursor_byte,
		replacement=owned_bytes,
	}
	lane.pending = true
	sync.sema_post(&lane.sema)
	return true, ""
}

editor_edit_lane_is_active :: proc(lane: ^Editor_Edit_Lane) -> bool {
	if lane == nil || lane.thread == nil { return false }
	sync.mutex_lock(&lane.mutex)
	active := lane.active || lane.pending
	sync.mutex_unlock(&lane.mutex)
	return active
}

editor_edit_lane_can_submit :: proc(lane: ^Editor_Edit_Lane) -> bool {
	if lane == nil || lane.thread == nil || sync.atomic_load(&lane.stopping) != 0 { return false }
	sync.mutex_lock(&lane.mutex)
	ready := !lane.active && !lane.pending && !lane.completed_ready
	sync.mutex_unlock(&lane.mutex)
	return ready
}

editor_edit_lane_take :: proc(lane: ^Editor_Edit_Lane) -> (result: Editor_Edit_Lane_Result, found: bool) {
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

editor_edit_lane_wait_take :: proc(lane: ^Editor_Edit_Lane) -> (result: Editor_Edit_Lane_Result, found: bool) {
	for {
		result, found = editor_edit_lane_take(lane)
		if found || lane == nil || lane.thread == nil { return }
		sync.sema_wait(&lane.completion_sema)
	}
}

editor_edit_lane_stop :: proc(lane: ^Editor_Edit_Lane) -> bool {
	if lane == nil || lane.thread == nil { return true }
	sync.mutex_lock(&lane.mutex)
	sync.atomic_store(&lane.stopping, 1)
	sync.mutex_unlock(&lane.mutex)
	sync.sema_post(&lane.sema)
	thread.join(lane.thread)
	thread.destroy(lane.thread)
	lane.thread = nil
	editor_edit_lane_result_destroy(&lane.completed, lane.allocator)
	lane.completed_ready = false
	if lane.pending { editor_edit_request_destroy(&lane.pending_request, lane.allocator) }
	lane.pending = false
	lane.backend = nil
	lane.wake = nil
	lane.wake_data = nil
	lane.test_dispatch_gate = nil
	return !lane.active && !lane.pending
}

directory_listing_clone :: proc(source: Directory_Listing, allocator: mem.Allocator) -> (copy: Directory_Listing, ok: bool) {
	copy.limit = source.limit
	copy.truncated = source.truncated
	relative_path_copy, err := strings.clone(source.relative_path, allocator)
	if err != nil { directory_listing_destroy(&copy, allocator); return {}, false }
	copy.relative_path = relative_path_copy
	copy.entries = make([]Directory_Entry, len(source.entries), allocator=allocator)
	for entry, i in source.entries {
		copy.entries[i].name, err = strings.clone(entry.name, allocator)
		if err != nil { directory_listing_destroy(&copy, allocator); return {}, false }
		copy.entries[i].path, err = strings.clone(entry.path, allocator)
		if err != nil { directory_listing_destroy(&copy, allocator); return {}, false }
		copy.entries[i].dir = entry.dir
	}
	return copy, true
}

directory_listing_destroy :: proc(listing: ^Directory_Listing, allocator: mem.Allocator) {
	if listing == nil { return }
	delete(listing.relative_path, allocator)
	for &entry in listing.entries {
		delete(entry.name, allocator)
		delete(entry.path, allocator)
	}
	delete(listing.entries, allocator)
	listing^ = {}
}

workspace_search_page_clone :: proc(source: Workspace_Search_Page, allocator: mem.Allocator) -> (copy: Workspace_Search_Page, ok: bool) {
	copy = source
	copy.results = make([]Workspace_Search_Result, len(source.results), allocator=allocator)
	for result, index in source.results {
		copy.results[index] = result
		path_copy, err := strings.clone(result.path, allocator)
		if err != nil { workspace_search_page_destroy(&copy, allocator); return {}, false }
		copy.results[index].path = path_copy
		text_copy, text_err := strings.clone(result.text, allocator)
		if text_err != nil { workspace_search_page_destroy(&copy, allocator); return {}, false }
		copy.results[index].text = text_copy
	}
	return copy, true
}

workspace_search_page_destroy :: proc(page: ^Workspace_Search_Page, allocator: mem.Allocator) {
	if page == nil { return }
	for &result in page.results {
		delete(result.path, allocator)
		delete(result.text, allocator)
	}
	delete(page.results, allocator)
	page^ = {}
}

backend_response_destroy :: proc(response: ^Backend_Response, allocator: mem.Allocator) {
	if response == nil { return }
	delete(response.lifecycle, allocator)
	delete(response.outcome.code, allocator)
	delete(response.outcome.message, allocator)
	delete(response.close_decision.document_id, allocator)
	delete(response.editor_selection.document_id, allocator)
	delete(response.resource.document_id, allocator)
	delete(response.edit.document_id, allocator)
	delete(response.edit.applied_replacement, allocator)
	delete(response.matches, allocator)
	workspace_search_page_destroy(&response.workspace_search_page, allocator)
	directory_listing_destroy(&response.directory_listing, allocator)
	response^ = {}
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
	defer backend_response_destroy(&response, allocator)
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
	if backend.resource_leases != 0 {
		return false, fmt.tprintf("refusing backend stop with %d outstanding Caliber resource lease(s)", backend.resource_leases)
	}
	stopped, stop_message := backend_stop_uninitialized(backend, allocator)
	if !stopped { return false, stop_message }
	if stop_status != .OK { return false, fmt.tprintf("backend stopped, but Caliber context_stop_wake_waiters returned: %v", stop_status) }
	return true, ""
}
