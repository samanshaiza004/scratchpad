package alicorn_scratchpad_bridge

import "core:os"
import "core:sync"
import "core:testing"
import "core:time"

@(test)
test_state_envelope_decodes_the_existing_schema :: proc(t: ^testing.T) {
	json_text := `{"schema":1,"revision":7,"application_revision":6,"has_workspace":true,"workspace_root":"C:/work","active":"doc-1","documents":[{"id":"doc-1","path":"C:/work/readme.md","status":"synced","dirty":false,"editor_revision":3,"language":"markdown"}]}`
	data := transmute([]u8)json_text
	state, ok, message := decode_state_envelope(data, context.temp_allocator)
	testing.expect(t, ok, message)
	testing.expect(t, state.revision == 7 && state.application_rev == 6, "transport and application revisions should decode separately")
	testing.expect(t, state.has_workspace && state.workspace_root == "C:/work", "workspace fields should decode")
	testing.expect(t, state.active == "doc-1" && len(state.documents) == 1, "active document and document count should decode")
	if len(state.documents) == 1 {
		doc := state.documents[0]
		testing.expect(t, doc.path == "C:/work/readme.md" && doc.language == "markdown", "document identity fields should decode")
	}
}

@(test)
test_state_envelope_rejects_malformed_and_unknown_schema :: proc(t: ^testing.T) {
	malformed_text := `{"schema":1,"revision":`
	malformed := transmute([]u8)malformed_text
	_, ok, _ := decode_state_envelope(malformed, context.temp_allocator)
	testing.expect(t, !ok, "truncated JSON must be rejected")
	unknown_text := `{"schema":99,"revision":2,"application_revision":1,"has_workspace":false,"documents":[]}`
	unknown := transmute([]u8)unknown_text
	_, ok, _ = decode_state_envelope(unknown, context.temp_allocator)
	testing.expect(t, !ok, "unknown StateEnvelope schemas must be rejected")
}

@(test)
test_state_publications_accept_only_newer_revisions :: proc(t: ^testing.T) {
	testing.expect(t, state_revision_is_newer(0, 1), "first publication should be accepted")
	testing.expect(t, state_revision_is_newer(4, 5), "new publication should replace old state")
	testing.expect(t, !state_revision_is_newer(5, 5), "duplicate publication should be ignored")
	testing.expect(t, !state_revision_is_newer(5, 3), "stale publication should be ignored")
}

@(test)
test_backend_response_rejects_malformed_and_mismatched_lifecycle :: proc(t: ^testing.T) {
	valid := Backend_Response{version=1, request_id=7, lifecycle="running", ok=true}
	bad_json_text := `{"version":1,"request_id":`
	bad_json := transmute([]u8)bad_json_text
	_, ok := decode_backend_response_bytes(bad_json, context.temp_allocator)
	testing.expect(t, !ok, "truncated backend response must fail the frontend decoder")
	unknown_version_text := `{"version":3,"request_id":7,"lifecycle":"running","ok":true}`
	unknown_version := transmute([]u8)unknown_version_text
	_, ok = decode_backend_response_bytes(unknown_version, context.temp_allocator)
	testing.expect(t, !ok, "unknown backend response version must be rejected by the frontend decoder")
	testing.expect(t, backend_response_matches(valid, 7, "running"), "matching response should pass")
	testing.expect(t, !backend_response_matches(valid, 8, "running"), "wrong request identity must fail")
	testing.expect(t, !backend_response_matches(valid, 7, "stopped"), "wrong lifecycle must fail")
	testing.expect(t, !backend_response_matches(Backend_Response{version=2, request_id=7, lifecycle="running"}, 7, "running"), "unknown response version must fail")
}

@(test)
test_wake_notifications_coalesce_until_ui_consumes :: proc(t: ^testing.T) {
	pending: u32 = 0
	testing.expect(t, wake_coalescer_request(&pending), "first notification should schedule a host wake")
	testing.expect(t, !wake_coalescer_request(&pending), "second notification should coalesce")
	testing.expect(t, !wake_coalescer_request(&pending), "more notifications remain coalesced")
	wake_coalescer_consume(&pending)
	testing.expect(t, wake_coalescer_request(&pending), "a later publication should wake after consumption")
}

Test_Wake_Signal :: struct {
	sema: sync.Sema,
}

test_wake_callback :: proc(data: rawptr) {
	signal := cast(^Test_Wake_Signal)data
	sync.sema_post(&signal.sema)
}

@(test)
// This is an integration test against the real existing Go c-shared bridge
// and Caliber ABI. The project wrapper builds and stages both libraries and
// supplies SCRATCHPAD_BACKEND_LIBRARY before invoking `odin test`.
test_backend_publication_lease_wake_stop_and_restart :: proc(t: ^testing.T) {
	library_path, found := os.lookup_env("SCRATCHPAD_BACKEND_LIBRARY", context.temp_allocator)
	if !found || library_path == "" {
		testing.expect(t, false, "run this integration test through tools/alicorn.ps1 or tools/alicorn.sh test")
		return
	}
	backend: Backend
	loaded, message := backend_load(&backend, library_path)
	testing.expect(t, loaded, message)
	if !loaded { return }
	signal: Test_Wake_Signal
	started, start_message := backend_start(&backend, "", test_wake_callback, rawptr(&signal), context.temp_allocator)
	testing.expect(t, started, start_message)
	if !started { return }
	testing.expect(t, backend.state_revision > 0, "backend start should publish real initial state")
	wake_arrived := sync.sema_wait_with_timeout(&signal.sema, time.Duration(2_000_000_000))
	testing.expect(t, wake_arrived, "initial state publication should pass through the blocking wake waiter")
	changed, consumed, consume_error := backend_consume_wake(&backend, context.temp_allocator)
	testing.expect(t, consumed, consume_error)
	testing.expect(t, !changed, "consuming the already-read initial revision should ignore the duplicate")
	testing.expect(t, backend.state_leases == 0, "state read must release and account its lease before returning")
	stopped, stop_error := backend_stop(&backend, context.temp_allocator)
	testing.expect(t, stopped, stop_error)
	testing.expect(t, backend.waiter.thread == nil && backend.waiter.exited == 1, "shutdown must stop and join the waiter")
	testing.expect(t, backend.state_leases == 0 && !backend.started, "backend stop requires released leases and leaves stopped state")

	second_start, second_error := backend_start(&backend, "", test_wake_callback, rawptr(&signal), context.temp_allocator)
	testing.expect(t, second_start, second_error)
	if second_start {
		second_stop, second_stop_error := backend_stop(&backend, context.temp_allocator)
		testing.expect(t, second_stop, second_stop_error)
	}
}
