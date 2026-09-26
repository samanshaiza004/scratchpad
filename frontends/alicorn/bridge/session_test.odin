package alicorn_scratchpad_bridge

import "core:os"
import "core:fmt"
import "core:strings"
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
	if write_err := os.write_entire_file_from_string(first_path, "# First\n"); write_err != nil {
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
	open_first := backend_command(backend, "open_path", path=first_path, allocator=context.temp_allocator)
	testing.expect(t, open_first.ok && open_first.state_changed, "generic open_path should publish the opened document")
	backend_command_result_destroy(&open_first, context.temp_allocator)
	testing.expect(t, len(backend.state.documents) == 1 && backend.state.active != "", "opened file should appear in real backend state")
	first_id, clone_err := strings.clone(backend.state.active, context.temp_allocator)
	testing.expect(t, clone_err == nil, "could not retain the first document's stable ID")
	defer delete(first_id, context.temp_allocator)
	first_editor_revision := u64(0)
	if len(backend.state.documents) == 1 { first_editor_revision = backend.state.documents[0].editor_revision }
	testing.expect(t, len(backend.state.documents) == 1, "opened first document should have a state record")
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
	testing.expect(t, open_second.ok && open_second.state_changed, "opening another path should publish a second document")
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
	testing.expect(t, backend.state_leases == 0, "shell commands must release every Caliber state lease")
	stopped, stop_message := backend_stop(backend, context.temp_allocator)
	testing.expect(t, stopped, stop_message)
}
