package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"
import bridge "./bridge"

floating_test_accept_open :: proc(data: rawptr, description: host.Application_Window_Description) -> bool { return true }

@(test)
test_floating_preview_and_save_preserve_primary_document :: proc(t: ^testing.T) {
	sync.mutex_lock(&backend_integration_test_mutex)
	defer sync.mutex_unlock(&backend_integration_test_mutex)
	workspace, err := os.make_directory_temp("", "scratchpad-floating-save-*", context.temp_allocator)
	if err != nil { testing.expect(t, false, "temporary workspace should be created"); return }
	defer _ = os.remove_all(workspace)
	first_path := fmt.tprintf("%s/first.txt", workspace)
	second_path := fmt.tprintf("%s/second.txt", workspace)
	_ = os.write_entire_file_from_string(first_path, "first\n")
	_ = os.write_entire_file_from_string(second_path, "second\n")
	library, found := os.lookup_env("SCRATCHPAD_BACKEND_LIBRARY", context.temp_allocator)
	if !found { testing.expect(t, false, "staged backend is required"); return }
	defer delete(library, context.temp_allocator)
	app := App{}
	loaded, message := bridge.backend_load(&app.backend, library)
	if !loaded { testing.expect(t, false, message); return }
	started, start_message := bridge.backend_start(&app.backend, workspace, tree_test_wake, nil, context.allocator)
	if !started { testing.expect(t, false, start_message); return }
	rt := alicorn.new_runtime(alicorn.Rect{0,0,800,600})
	defer tree_test_cleanup(t, &app, &rt)
	app.primary_runtime = &rt
	app.services.windows.open = floating_test_accept_open
	opened := bridge.backend_command(&app.backend, "open_path", path=first_path, disposition="preview")
	testing.expect(t, opened.ok, "the sole preview should open")
	bridge.backend_command_result_destroy(&opened, context.allocator)
	first_id, _ := strings.clone(app.backend.state.active, context.allocator)
	defer delete(first_id, context.allocator)
	testing.expect(t, floating_window_open(&app, &rt, first_id), "a sole preview should be detachable")
	if app.floating_window == nil { return }
	defer { if app.floating_window != nil { floating_window_stop(rawptr(app.floating_window)) } }
	document, document_found := find_document(&app.backend.state, first_id)
	testing.expect(t, document_found && !document.preview, "detaching should promote the preview to a regular document")
	second := bridge.backend_command(&app.backend, "open_path", path=second_path, disposition="preview")
	testing.expect(t, second.ok && len(app.backend.state.documents) == 2, "opening another preview must preserve the floating document")
	bridge.backend_command_result_destroy(&second, context.allocator)
	primary_id, _ := strings.clone(app.backend.state.active, context.allocator)
	defer delete(primary_id, context.allocator)
	document, _ = find_document(&app.backend.state, first_id)
	bytes := [?]int{'x'}
	edit := bridge.backend_command(&app.backend, "replace_document", document_id=first_id, editor_revision=document.editor_revision, start_byte=0, end_byte=0, replacement=bytes[:])
	testing.expect(t, edit.ok, "the background floating document should accept an explicit edit")
	bridge.backend_command_result_destroy(&edit, context.allocator)
	child_rt := alicorn.new_runtime(alicorn.Rect{0,0,700,500})
	defer alicorn.destroy_runtime(&child_rt)
	window := app.floating_window
	scoped_app, scope := floating_editor_scope_enter(window, &child_rt)
	if scoped_app == nil { testing.expect(t, false, "floating scope should initialize"); return }
	floating_window_save(scoped_app, &child_rt, window.document_id)
	floating_editor_scope_leave(window, scoped_app, &scope)
	testing.expect(t, app.backend.state.active == primary_id && window.document_id == first_id, "saving must preserve both window document identities across backend publication")
	first, first_err := os.read_entire_file(first_path, context.allocator)
	defer delete(first, context.allocator)
	second_bytes, second_err := os.read_entire_file(second_path, context.allocator)
	defer delete(second_bytes, context.allocator)
	testing.expect(t, first_err == nil && string(first) == "xfirst\n", "Save must write the floating document")
	testing.expect(t, second_err == nil && string(second_bytes) == "second\n", "Save must preserve the primary document file")
	floating_window_stop(rawptr(app.floating_window))
	select_document(&app, &rt, primary_id)
	testing.expect(t, floating_window_open(&app, &rt, primary_id), "the remaining preview should also detach")
	testing.expect(t, app.backend.state.active == first_id, "detaching the active last tab must activate the preceding document")
	navigate_tab(&app, &rt, 1)
	testing.expect(t, app.backend.state.active == first_id, "keyboard tab navigation must skip the detached document")
}
