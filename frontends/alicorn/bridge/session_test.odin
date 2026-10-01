package alicorn_scratchpad_bridge

import "core:os"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

@(test)
test_state_envelope_decodes_the_existing_schema :: proc(t: ^testing.T) {
 json_text := `{"schema":1,"revision":7,"application_revision":6,"has_workspace":true,"workspace_root":"C:/work","active":"doc-1","workspace_search_generation":5,"workspace_search_sequence":2,"workspace_search_count":33,"workspace_search_page_available":true,"workspace_search_done":false,"workspace_search_truncated":false,"documents":[{"id":"doc-1","path":"C:/work/readme.md","status":"synced","dirty":false,"preview":true,"editor_revision":3,"line_count":42,"language":"markdown","presentation_revision":3,"presentation_ready":true}]}`
	data := transmute([]u8)json_text
	state, ok, message := decode_state_envelope(data, context.temp_allocator)
	testing.expect(t, ok, message)
	testing.expect(t, state.revision == 7 && state.application_rev == 6, "transport and application revisions should decode separately")
	testing.expect(t, state.has_workspace && state.workspace_root == "C:/work", "workspace fields should decode")
	testing.expect(t, state.active == "doc-1" && len(state.documents) == 1, "active document and document count should decode")
	testing.expect(t, state.workspace_search_generation == 5 && state.workspace_search_sequence == 2 &&
	               state.workspace_search_count == 33 && state.workspace_search_page_available,
	               "workspace search status should decode independently of document state")
	if len(state.documents) == 1 {
		doc := state.documents[0]
		testing.expect(t, doc.path == "C:/work/readme.md" && doc.language == "markdown", "document identity fields should decode")
		testing.expect(t, doc.line_count == 42, "logical line count should decode from shared document state")
		testing.expect(t, doc.preview, "preview tab state should decode from the shared StateEnvelope")
		testing.expect(t, doc.presentation_revision == 3 && doc.presentation_ready,
			"Markdown readiness publication should decode alongside source revision state")
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
test_visible_window_requests_deduplicate_and_reject_stale_results :: proc(t: ^testing.T) {
	base := Visible_Window_Request{
		document_id="doc-1", application_rev=8, editor_revision=4,
		start_line=120, max_lines=64, max_bytes=16*1024,
	}
	duplicate := base
	duplicate.generation = 99
	other_line := base
	other_line.start_line += 1
	other_chunk := base
	other_chunk.anchor_byte = 4096
	metadata_request := base
	metadata_request.include_presentation = true
	testing.expect(t, visible_window_request_equal(base, duplicate), "request identity ignores its assigned generation")
	testing.expect(t, !visible_window_request_equal(base, other_line), "a different logical window must not deduplicate")
	testing.expect(t, !visible_window_request_equal(base, other_chunk), "a different long-line byte anchor must not deduplicate")
	testing.expect(t, !visible_window_request_equal(base, metadata_request), "plain and metadata requests must not deduplicate each other")
	testing.expect(t, visible_window_result_is_current(0, 7, 7), "latest completed request should be installable")
	testing.expect(t, !visible_window_result_is_current(0, 6, 7), "stale completion must be rejected")
	testing.expect(t, !visible_window_result_is_current(1, 7, 7), "completion after lane stop must be rejected")
}

visible_slice_write_u32 :: proc(data: []u8, offset: int, value: u32) {
	data[offset+0] = u8(value)
	data[offset+1] = u8(value >> 8)
	data[offset+2] = u8(value >> 16)
	data[offset+3] = u8(value >> 24)
}

visible_slice_write_u64 :: proc(data: []u8, offset: int, value: u64) {
	visible_slice_write_u32(data, offset, u32(value))
	visible_slice_write_u32(data, offset+4, u32(value >> 32))
}

@(test)
test_visible_window_decode_validates_bounded_raw_spvs :: proc(t: ^testing.T) {
	payload := [?]u8{'a', 0xFF, '\n'}
	encoded, alloc_err := make([]u8, VISIBLE_SLICE_HEADER_BYTES+len(payload), context.temp_allocator)
	testing.expect(t, alloc_err == nil, "SPVS fixture allocation should succeed")
	if alloc_err != nil { return }
	defer delete(encoded, context.temp_allocator)
	encoded[0] = 'S'; encoded[1] = 'P'; encoded[2] = 'V'; encoded[3] = 'S'
	visible_slice_write_u32(encoded, 4, VISIBLE_SLICE_SCHEMA_V1)
	visible_slice_write_u64(encoded, 8, 17)
	visible_slice_write_u64(encoded, 16, 9)
	visible_slice_write_u64(encoded, 24, 12)
	visible_slice_write_u64(encoded, 32, 13)
	visible_slice_write_u32(encoded, 40, 1)
	visible_slice_write_u32(encoded, 44, u32(len(payload)))
	for i in 0..<len(payload) { encoded[VISIBLE_SLICE_HEADER_BYTES+i] = payload[i] }
	descriptor := Resource_Descriptor{
		resource_id=4, generation=2, document_id="doc-1",
		application_rev=17, editor_revision=9, start_line=12, end_line=13,
		byte_len=u64(len(payload)), truncated=true, start_byte=88, line_byte_length=4096,
	}
	window, ok, message := visible_window_decode(encoded, descriptor, "doc-1", allocator=context.temp_allocator)
	testing.expect(t, ok, message)
	if ok {
		defer visible_window_destroy(&window, context.temp_allocator)
		testing.expect(t, window.application_rev == 17 && window.editor_revision == 9, "SPVS revisions should be retained")
		testing.expect(t, window.start_line == 12 && window.end_line == 13 && window.start_byte == 88 && window.truncated,
			"SPVS range metadata should match the Caliber resource descriptor")
		testing.expect(t, window.line_byte_length == 4096, "visible byte chunks should retain the full logical line length")
		source_matches := len(window.source) == len(payload)
		if source_matches {
			for i in 0..<len(payload) {
				if window.source[i] != payload[i] { source_matches = false; break }
			}
		}
		testing.expect(t, source_matches, "SPVS payload must preserve raw source bytes, including invalid UTF-8")
	}

	bad_schema := encoded[:]
	visible_slice_write_u32(bad_schema, 4, 99)
	_, ok, _ = visible_window_decode(bad_schema, descriptor, "doc-1", allocator=context.temp_allocator)
	testing.expect(t, !ok, "unknown SPVS schema must be rejected")
	visible_slice_write_u32(encoded, 4, VISIBLE_SLICE_SCHEMA_V1)
	wrong_revision := descriptor
	wrong_revision.editor_revision += 1
	_, ok, _ = visible_window_decode(encoded, wrong_revision, "doc-1", allocator=context.temp_allocator)
	testing.expect(t, !ok, "SPVS revision mismatch must be rejected")
	wrong_length := descriptor
	wrong_length.byte_len += 1
	_, ok, _ = visible_window_decode(encoded, wrong_length, "doc-1", allocator=context.temp_allocator)
	testing.expect(t, !ok, "descriptor/payload length mismatch must be rejected")
	_, ok, _ = visible_window_decode(encoded, descriptor, "other-doc", allocator=context.temp_allocator)
	testing.expect(t, !ok, "resource for another document must be rejected")
	_, ok, _ = visible_window_decode(encoded[:VISIBLE_SLICE_HEADER_BYTES-1], descriptor, "doc-1", allocator=context.temp_allocator)
	testing.expect(t, !ok, "truncated SPVS header must be rejected")
}

@(test)
test_spvs_v2_decodes_bounded_revision_matched_presentation :: proc(t: ^testing.T) {
	payload := [?]u8{'#', ' ', 0xFF, '\n'}
	metadata_len := PRESENTATION_TRAILER_BYTES+2*PRESENTATION_RECORD_BYTES
	encoded, alloc_err := make([]u8, VISIBLE_SLICE_HEADER_BYTES+len(payload)+metadata_len, context.temp_allocator)
	testing.expect(t, alloc_err == nil, "SPVS v2 fixture allocation should succeed")
	if alloc_err != nil { return }
	defer delete(encoded, context.temp_allocator)
	encoded[0] = 'S'; encoded[1] = 'P'; encoded[2] = 'V'; encoded[3] = 'S'
	visible_slice_write_u32(encoded, 4, VISIBLE_SLICE_SCHEMA_V2)
	visible_slice_write_u64(encoded, 8, 17)
	visible_slice_write_u64(encoded, 16, 9)
	visible_slice_write_u64(encoded, 24, 12)
	visible_slice_write_u64(encoded, 32, 13)
	visible_slice_write_u32(encoded, 40, 0)
	visible_slice_write_u32(encoded, 44, u32(len(payload)))
	for i in 0..<len(payload) { encoded[VISIBLE_SLICE_HEADER_BYTES+i] = payload[i] }
	metadata_start := VISIBLE_SLICE_HEADER_BYTES+len(payload)
	visible_slice_write_u64(encoded, metadata_start, 9)
	visible_slice_write_u32(encoded, metadata_start+8, PRESENTATION_READY_FLAG)
	visible_slice_write_u32(encoded, metadata_start+12, 1)
	visible_slice_write_u32(encoded, metadata_start+16, 1)
	visible_slice_write_u32(encoded, metadata_start+20, 0)
	record := metadata_start+PRESENTATION_TRAILER_BYTES
	visible_slice_write_u32(encoded, record, 2) // heading
	visible_slice_write_u32(encoded, record+4, 0)
	visible_slice_write_u32(encoded, record+8, 3)
	visible_slice_write_u32(encoded, record+12, 1)
	record += PRESENTATION_RECORD_BYTES
	visible_slice_write_u32(encoded, record, 0x10002) // quote block
	visible_slice_write_u32(encoded, record+4, 0)
	visible_slice_write_u32(encoded, record+8, 4)
	visible_slice_write_u32(encoded, record+12, 0)
	descriptor := Resource_Descriptor{
		resource_id=4, generation=2, document_id="doc-1",
		application_rev=17, editor_revision=9, start_line=12, end_line=13,
		byte_len=u64(len(payload)), metadata_byte_len=u64(metadata_len), start_byte=88,
	}
	window, ok, message := visible_window_decode(encoded, descriptor, "doc-1", include_presentation=true, allocator=context.temp_allocator)
	testing.expect(t, ok, message)
	if ok {
		defer visible_window_destroy(&window, context.temp_allocator)
		testing.expect(t, string(window.source) == string(payload[:]), "SPVS v2 must retain raw source bytes including malformed UTF-8 unchanged")
		testing.expect(t, window.presentation_ready && window.presentation_revision == 9 && !window.presentation_truncated,
			"presentation readiness must be tied to the authoritative editor revision")
		testing.expect(t, len(window.presentation_spans) == 1 && window.presentation_spans[0].kind == 2 &&
			window.presentation_spans[0].start_byte == 0 && window.presentation_spans[0].end_byte == 3 &&
			window.presentation_spans[0].level_flags == 1, "span record should retain kind, relative byte range, and heading level")
		testing.expect(t, len(window.presentation_blocks) == 1 && window.presentation_blocks[0].kind == 0x10002,
			"block records should be retained separately from spans")
	}
	_, ok, _ = visible_window_decode(encoded, descriptor, "doc-1", allocator=context.temp_allocator)
	testing.expect(t, !ok, "SPVS v2 must be rejected when the caller did not opt into presentation metadata")

	wrong_metadata_length := descriptor
	wrong_metadata_length.metadata_byte_len -= 1
	_, ok, _ = visible_window_decode(encoded, wrong_metadata_length, "doc-1", include_presentation=true, allocator=context.temp_allocator)
	testing.expect(t, !ok, "descriptor metadata byte length must match the encoded trailer and records")
	wrong_source_range := encoded[:]
	visible_slice_write_u32(wrong_source_range, record+8, u32(len(payload))+1)
	_, ok, _ = visible_window_decode(wrong_source_range, descriptor, "doc-1", include_presentation=true, allocator=context.temp_allocator)
	testing.expect(t, !ok, "records extending past the bounded visible source must be rejected")
	wrong_ready_revision := encoded[:]
	visible_slice_write_u64(wrong_ready_revision, metadata_start, 8)
	_, ok, _ = visible_window_decode(wrong_ready_revision, descriptor, "doc-1", include_presentation=true, allocator=context.temp_allocator)
	testing.expect(t, !ok, "ready metadata for a different source revision must be rejected")
	unknown_flags := encoded[:]
	visible_slice_write_u32(unknown_flags, metadata_start+8, 0x4)
	_, ok, _ = visible_window_decode(unknown_flags, descriptor, "doc-1", include_presentation=true, allocator=context.temp_allocator)
	testing.expect(t, !ok, "unknown presentation trailer flags must be rejected")
	unknown_kind := encoded[:]
	visible_slice_write_u32(unknown_kind, metadata_start+PRESENTATION_TRAILER_BYTES, 0x40)
	_, ok, _ = visible_window_decode(unknown_kind, descriptor, "doc-1", include_presentation=true, allocator=context.temp_allocator)
	testing.expect(t, !ok, "unknown presentation record kinds must be rejected")
	too_many_records := encoded[:]
	visible_slice_write_u32(too_many_records, metadata_start+12, 0xFFFFFFFF)
	_, ok, _ = visible_window_decode(too_many_records, descriptor, "doc-1", include_presentation=true, allocator=context.temp_allocator)
	testing.expect(t, !ok, "record counts beyond the bounded cap must be rejected without overflow")
	trailing_metadata := descriptor
	trailing_metadata.metadata_byte_len += 1
	_, ok, _ = visible_window_decode(encoded, trailing_metadata, "doc-1", include_presentation=true, allocator=context.temp_allocator)
	testing.expect(t, !ok, "unaccounted trailing metadata bytes must be rejected")
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
// stages the shared backend beside the test executable before invoking `odin test`.
test_backend_publication_lease_wake_stop_and_restart :: proc(t: ^testing.T) {
	backend: Backend
	loaded, message := backend_load(&backend, "")
	testing.expect(t, loaded, fmt.tprintf("backend should be discovered beside this executable: %s", message))
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
	exercise_shared_backend_shell_commands(t, &backend, &signal)
}

exercise_shared_backend_shell_commands :: proc(t: ^testing.T, backend: ^Backend, signal: ^Test_Wake_Signal) {
	workspace, workspace_err := os.make_directory_temp("", "scratchpad-alicorn-shell-*", context.temp_allocator)
	if workspace_err != nil { testing.expect(t, false, "could not create temporary workspace"); return }
	defer _ = os.remove_all(workspace)
	first_path := fmt.tprintf("%s/first.md", workspace)
	second_path := fmt.tprintf("%s/second.txt", workspace)
	nested_path := fmt.tprintf("%s/nested", workspace)
	nested_file_path := fmt.tprintf("%s/nested/child.md", workspace)
	if mkdir_err := os.make_directory(nested_path); mkdir_err != nil {
		testing.expect(t, false, "could not create a nested test directory")
		return
	}
	if write_err := os.write_entire_file_from_string(first_path, "# First\nSecond\nThird"); write_err != nil {
		testing.expect(t, false, "could not create first test document")
		return
	}
	if write_err := os.write_entire_file_from_string(second_path, "Second\n"); write_err != nil {
		testing.expect(t, false, "could not create second test document")
		return
	}
	if write_err := os.write_entire_file_from_string(nested_file_path, "Nested\n"); write_err != nil {
		testing.expect(t, false, "could not create a nested test document")
		return
	}
	started, start_message := backend_start(backend, workspace, test_wake_callback, rawptr(signal), context.temp_allocator)
	testing.expect(t, started, start_message)
	if !started { return }
	root_listing := backend_command(backend, "list_directory", allocator=context.temp_allocator)
	testing.expect(t, root_listing.ok && root_listing.directory_listing_owned, "generic list_directory should return an owned root listing")
	if root_listing.directory_listing_owned {
		testing.expect(t, root_listing.directory_listing.relative_path == "" && len(root_listing.directory_listing.entries) == 3,
			"root listing should retain the existing bounded directory schema, including subfolders")
	}
	backend_command_result_destroy(&root_listing, context.temp_allocator)
	nested_listing := backend_command(backend, "list_directory", relative_path="nested", allocator=context.temp_allocator)
	testing.expect(t, nested_listing.ok && nested_listing.directory_listing_owned, "generic list_directory should return a nested listing")
	if nested_listing.directory_listing_owned {
		testing.expect(t, nested_listing.directory_listing.relative_path == "nested" && len(nested_listing.directory_listing.entries) == 1 && nested_listing.directory_listing.entries[0].name == "child.md",
			"nested listing should preserve its relative path and entry identity")
	}
	backend_command_result_destroy(&nested_listing, context.temp_allocator)
	open_first := backend_command(backend, "open_path", path=first_path, disposition="preview", allocator=context.temp_allocator)
	testing.expect(t, open_first.ok && open_first.state_changed, "preview open_path should publish the opened document")
	backend_command_result_destroy(&open_first, context.temp_allocator)
	testing.expect(t, len(backend.state.documents) == 1 && backend.state.active != "", "opened file should appear in real backend state")
	if len(backend.state.documents) == 1 {
		testing.expect(t, backend.state.documents[0].preview, "tree-style opening should be marked as a preview")
	}
	first_id, clone_err := strings.clone(backend.state.active, context.temp_allocator)
	testing.expect(t, clone_err == nil, "could not retain the first document's stable ID")
	defer delete(first_id, context.temp_allocator)
	open_second_preview := backend_command(backend, "open_path", path=second_path, disposition="preview", allocator=context.temp_allocator)
	testing.expect(t, open_second_preview.ok && len(backend.state.documents) == 1, "opening another preview should replace the prior clean preview")
	backend_command_result_destroy(&open_second_preview, context.temp_allocator)
	open_first_pinned := backend_command(backend, "open_path", path=first_path, allocator=context.temp_allocator)
	testing.expect(t, open_first_pinned.ok && len(backend.state.documents) == 2, "ordinary open_path should stay pinned and preserve the preview tab")
	backend_command_result_destroy(&open_first_pinned, context.temp_allocator)
	first_editor_revision := u64(0)
	first_document_found := false
	for document in backend.state.documents {
		if document.id == first_id {
			first_document_found = true
			first_editor_revision = document.editor_revision
			break
		}
	}
	testing.expect(t, first_document_found, "opened first document should have a state record")
	visible := backend_command(
		backend,
		"read_visible_lines",
		document_id=first_id,
		start_line=0,
		max_lines=MAX_VISIBLE_LINES,
		max_bytes=MAX_VISIBLE_BYTES,
		allocator=context.temp_allocator,
	)
	testing.expect(t, visible.ok && visible.visible_window_owned, "generic read_visible_lines should return an owned bounded SPVS window")
	if visible.visible_window_owned {
		testing.expect(t, visible.visible_window.start_line == 0 && visible.visible_window.end_line == 3,
			"visible window should report the requested logical line range")
		testing.expect(t, string(visible.visible_window.source) == "# First\nSecond\nThird", "visible window should preserve the document's exact source bytes")
	}
	backend_command_result_destroy(&visible, context.temp_allocator)
	testing.expect(t, backend.resource_leases == 0 && backend.state_leases == 0,
		"visible resource and state leases must be released before the command returns")
	lane_signal: Test_Wake_Signal
	lane: Visible_Window_Lane
	lane_started := visible_window_lane_start(&lane, backend, test_wake_callback, rawptr(&lane_signal), context.temp_allocator)
	testing.expect(t, lane_started, "visible-window lane should start one frontend-owned worker")
	if lane_started {
		idle_wake := sync.sema_wait_with_timeout(&lane_signal.sema, time.Duration(10_000_000))
		testing.expect(t, !idle_wake && lane.submitted == 0 && !lane.active,
			"an idle window lane must sleep without manufacturing requests or wakes")
		first_generation, first_accepted, first_request_error := visible_window_lane_request(
			&lane, first_id, backend.state.application_rev, first_editor_revision,
			0, 256, MAX_VISIBLE_BYTES,
		)
		testing.expect(t, first_accepted, first_request_error)
		latest_generation, latest_accepted, latest_request_error := visible_window_lane_request(
			&lane, first_id, backend.state.application_rev, first_editor_revision,
			1, 256, MAX_VISIBLE_BYTES,
		)
		testing.expect(t, latest_accepted && latest_generation > first_generation, "new viewport request should supersede the earlier window")
		latest_seen := false
		for attempt in 0..<20 {
			completed, found := visible_window_lane_take(&lane)
			if found {
				if completed.generation == latest_generation {
					latest_seen = true
					testing.expect(t, completed.window_owned && completed.window.start_line == 1,
						"only the newest requested logical window should be published")
					if completed.window_owned {
						testing.expect(t, string(completed.window.source) == "Second\nThird",
							"latest window result should carry the exact requested raw bytes")
					}
				} else {
					testing.expect(t, completed.generation < latest_generation,
						"a lane completion must not claim a future generation")
				}
				visible_window_lane_result_destroy(&completed, context.temp_allocator)
				if latest_seen { break }
			}
			if !latest_seen { _ = sync.sema_wait_with_timeout(&lane_signal.sema, time.Duration(100_000_000)) }
		}
		testing.expect(t, latest_seen, "worker should wake the UI after installing the latest window")
		// Repeatedly complete real resource reads. Each completion owns one
		// request ID string and must release it exactly once; this stresses the
		// ownership path that is exercised when a document is opened natively.
		for iteration in 0..<32 {
			start_line := u64(iteration % 3)
			generation, accepted, request_error := visible_window_lane_request(
				&lane, first_id, backend.state.application_rev, first_editor_revision,
				start_line, 256, MAX_VISIBLE_BYTES,
			)
			testing.expect(t, accepted, request_error)
			if !accepted { break }
			completed_for_request := false
			for attempt in 0..<20 {
				completed, found := visible_window_lane_take(&lane)
				if found {
					completed_for_request = completed.generation == generation && completed.window_owned
					visible_window_lane_result_destroy(&completed, context.temp_allocator)
					if completed_for_request { break }
				}
				if !completed_for_request { _ = sync.sema_wait_with_timeout(&lane_signal.sema, time.Duration(100_000_000)) }
			}
			testing.expect(t, completed_for_request, "repeated bounded reads should complete without losing ownership or corrupting the heap")
			if !completed_for_request { break }
		}
		lane_stopped := visible_window_lane_stop(&lane)
		testing.expect(t, lane_stopped && lane.thread == nil, "visible-window lane stop must join its worker")
		testing.expect(t, backend.resource_leases == 0, "worker must release its Caliber resource lease before shutdown")
		lane_restarted := visible_window_lane_start(&lane, backend, test_wake_callback, rawptr(&lane_signal), context.temp_allocator)
		testing.expect(t, lane_restarted, "joined visible-window lane should support a clean restart")
		if lane_restarted {
			lane_stopped_again := visible_window_lane_stop(&lane)
			testing.expect(t, lane_stopped_again && lane.thread == nil, "restarted lane should also stop and join cleanly")
		}
	}
	replacement := [?]int{'x'}
	edit_first := backend_command(
		backend,
		"replace_document",
		document_id=first_id,
		editor_revision=first_editor_revision,
		start_byte=0,
		end_byte=0,
		replacement=replacement[:],
		allocator=context.temp_allocator,
	)
	testing.expect(t, edit_first.ok && edit_first.state_changed, "generic replace_document should publish dirty state for the close-decision test")
	backend_command_result_destroy(&edit_first, context.temp_allocator)
	open_second := backend_command(backend, "open_path", path=second_path, allocator=context.temp_allocator)
	testing.expect(t, open_second.ok && open_second.state_changed, "opening another path should pin and select the existing preview document")
	backend_command_result_destroy(&open_second, context.temp_allocator)
	testing.expect(t, len(backend.state.documents) == 2, "two real documents should produce two tabs")
	select_first := backend_command(backend, "select_document", document_id=first_id, allocator=context.temp_allocator)
	testing.expect(t, select_first.ok && backend.state.active == first_id, "generic select_document should select the existing stable ID")
	backend_command_result_destroy(&select_first, context.temp_allocator)
	refresh := backend_command(backend, "refresh_workspace", allocator=context.temp_allocator)
	testing.expect(t, refresh.ok && refresh.directory_listing_owned && refresh.directory_listing.relative_path == "" && len(refresh.directory_listing.entries) == 3,
		"generic refresh_workspace should return a fresh root listing through the same backend")
	backend_command_result_destroy(&refresh, context.temp_allocator)
	dirty_close := backend_command(backend, "close_document", document_id=first_id, allocator=context.temp_allocator)
	testing.expect(t, !dirty_close.ok && dirty_close.code == "close_requires_decision", "dirty close should return the existing application decision")
	testing.expect(t, dirty_close.close_decision.dirty && dirty_close.close_decision.can_save && dirty_close.close_decision.can_discard, "dirty-close response should carry explicit save/discard options")
	backend_command_result_destroy(&dirty_close, context.temp_allocator)
	save_first := backend_command(backend, "save_document", document_id=first_id, allocator=context.temp_allocator)
	testing.expect(t, save_first.ok && save_first.state_changed, "generic save_document should clear the dirty state before closing")
	backend_command_result_destroy(&save_first, context.temp_allocator)
	close_first := backend_command(backend, "close_document", document_id=first_id, allocator=context.temp_allocator)
	testing.expect(t, close_first.ok && len(backend.state.documents) == 1, "generic close_document should remove the requested clean document")
	backend_command_result_destroy(&close_first, context.temp_allocator)
	long_line_path := fmt.tprintf("%s/long-line.txt", workspace)
	long_line_bytes, long_line_allocation_error := make([]u8, 2*1024*1024, context.temp_allocator)
	testing.expect(t, long_line_allocation_error == nil, "long-line fixture should allocate")
	if long_line_allocation_error == nil {
		defer delete(long_line_bytes, context.temp_allocator)
		for i in 0..<len(long_line_bytes) { long_line_bytes[i] = 'L' }
		if write_error := os.write_entire_file_from_string(long_line_path, string(long_line_bytes)); write_error != nil {
			testing.expect(t, false, "long-line fixture should be written")
		} else {
			open_long_line := backend_command(backend, "open_path", path=long_line_path, allocator=context.temp_allocator)
			testing.expect(t, open_long_line.ok, "shared backend should open the 2 MiB logical line")
			long_document_id, long_id_error := strings.clone(backend.state.active, context.temp_allocator)
			testing.expect(t, long_id_error == nil && len(long_document_id) > 0, "long-line document should publish a stable ID")
			backend_command_result_destroy(&open_long_line, context.temp_allocator)
			if len(long_document_id) > 0 {
				defer delete(long_document_id, context.temp_allocator)
				first_chunk := backend_command(
					backend, "read_visible_lines", document_id=long_document_id,
					start_line=0, max_lines=1, max_bytes=MAX_VISIBLE_BYTES,
					allocator=context.temp_allocator,
				)
				testing.expect(t, first_chunk.ok && first_chunk.visible_window_owned, "shared bridge should return the first bounded long-line chunk")
				if first_chunk.visible_window_owned {
					first_window := first_chunk.visible_window
					testing.expect(t, first_window.line_byte_length == u64(len(long_line_bytes)) && len(first_window.source) == 16*1024 && first_window.truncated,
						"first chunk should be capped at 16 KiB and report the complete logical-line extent")
					anchor := first_window.start_byte+u64(len(first_window.source))-64
				first_prefix_matches := len(first_window.source) >= 3 && first_window.source[0] == 'L' && first_window.source[len(first_window.source)-1] == 'L'
				testing.expect(t, first_prefix_matches, "first long-line resource should preserve raw source bytes")
					backend_command_result_destroy(&first_chunk, context.temp_allocator)
					second_chunk := backend_command(
						backend, "read_visible_lines", document_id=long_document_id,
						start_line=0, anchor_byte=anchor, max_lines=1, max_bytes=MAX_VISIBLE_BYTES,
						allocator=context.temp_allocator,
					)
					testing.expect(t, second_chunk.ok && second_chunk.visible_window_owned, "shared bridge should continue from an absolute byte anchor")
					if second_chunk.visible_window_owned {
						testing.expect(t, second_chunk.visible_window.start_byte == anchor && len(second_chunk.visible_window.source) == 16*1024 && second_chunk.visible_window.truncated,
							"anchored response should advance the bounded chunk without materializing the document")
					if len(second_chunk.visible_window.source) > 0 {
						testing.expect(t, second_chunk.visible_window.source[0] == 'L' && second_chunk.visible_window.source[len(second_chunk.visible_window.source)-1] == 'L',
							"anchored response should retain exact original bytes")
					}
					}
					backend_command_result_destroy(&second_chunk, context.temp_allocator)
				} else {
					backend_command_result_destroy(&first_chunk, context.temp_allocator)
				}
			}
		}
	}
	testing.expect(t, backend.state_leases == 0, "shell commands must release every Caliber state lease")
	testing.expect(t, backend.resource_leases == 0, "long-line Caliber windows must release every resource lease")
	stopped, stop_message := backend_stop(backend, context.temp_allocator)
	testing.expect(t, stopped, stop_message)
}


@(test)
test_find_and_workspace_search_responses_decode_bounded_results :: proc(t: ^testing.T) {
	json_text := `{"version":1,"request_id":9,"lifecycle":"running","ok":true,"outcome":{"code":"ok"},"matches":[{"start":12,"end":17,"line":1,"column":2}],"matches_truncated":true,"workspace_search_page":{"generation":4,"sequence":1,"count":1,"done":false,"truncated":false,"results":[{"path":"docs/guide.md","line":3,"column":7,"start_byte":40,"end_byte":45,"text":"a needle here","text_truncated":false}]}}`
	data := transmute([]u8)json_text
	response, ok := decode_backend_response_bytes(data, context.temp_allocator)
	testing.expect(t, ok, "bounded search response should decode")
	if !ok { return }
	testing.expect(t, len(response.matches) == 1 && response.matches[0].start == 12 && response.matches_truncated,
	               "current-file match byte ranges and truncation should decode")
	page := response.workspace_search_page
	testing.expect(t, page.generation == 4 && page.sequence == 1 && len(page.results) == 1,
	               "workspace page identity and bounded result count should decode")
	if len(page.results) == 1 {
		hit := page.results[0]
		testing.expect(t, hit.path == "docs/guide.md" && hit.line == 3 && hit.start_byte == 40 && hit.end_byte == 45,
		               "workspace hit path and exact source offsets should decode")
	}
	copy, copied := workspace_search_page_clone(page, context.temp_allocator)
	testing.expect(t, copied && len(copy.results) == 1 && copy.results[0].text == "a needle here",
	               "workspace result pages should be independently owned after cloning")
	workspace_search_page_destroy(&copy, context.temp_allocator)
	backend_response_destroy(&response, context.temp_allocator)
}
