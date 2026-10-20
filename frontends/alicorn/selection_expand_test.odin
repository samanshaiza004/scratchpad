package main

import "core:fmt"
import "core:os"
import "core:sync"
import "core:testing"
import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"
import bridge "./bridge"

@(test)
test_selection_expand_native_menu_reaches_authoritative_ranges :: proc(t: ^testing.T) {
	sync.mutex_lock(&backend_integration_test_mutex)
	defer sync.mutex_unlock(&backend_integration_test_mutex)
	workspace, err := os.make_directory_temp("", "scratchpad-selection-*", context.temp_allocator)
	if err != nil { testing.expect(t, false, "selection fixture directory should exist"); return }
	defer _ = os.remove_all(workspace)
	path := fmt.tprintf("%s/note.txt", workspace)
	if os.write_entire_file_from_string(path, "alpha beta.\n\nnext") != nil { testing.expect(t, false, "selection fixture should be writable"); return }
	library, found := os.lookup_env("SCRATCHPAD_BACKEND_LIBRARY", context.temp_allocator)
	if !found { testing.expect(t, false, "selection integration needs the real backend"); return }
	defer delete(library, context.temp_allocator)
	app: App
	loaded, message := bridge.backend_load(&app.backend, library)
	testing.expect(t, loaded, message)
	if !loaded { return }
	started, start_message := bridge.backend_start(&app.backend, workspace, tree_test_wake, nil, context.allocator)
	testing.expect(t, started, start_message)
	if !started { return }
	defer {
		_, _ = bridge.backend_stop(&app.backend, context.allocator)
		editor_views_destroy(&app.editor_views, context.allocator)
	}
	opened := bridge.backend_command(&app.backend, "open_path", path=path, allocator=context.allocator)
	testing.expect(t, opened.ok, "selection fixture should open")
	bridge.backend_command_result_destroy(&opened, context.allocator)
	document, document_found := find_document(&app.backend.state, app.backend.state.active)
	if !document_found { testing.expect(t, false, "selection document should be published"); return }
	view_index, view_ok := editor_view_ensure(&app.editor_views, document.id)
	if !view_ok { testing.expect(t, false, "selection view should be retained"); return }
	app.editor_views[view_index].selection_anchor = 10
	app.editor_views[view_index].caret_byte = 6
	init_menus(&app)
	menu_found := false
	for item in app.edit_items {
		if item.command == action_id_for(ACTION_SELECTION_EXPAND) {
			menu_found = item.shortcut.key == 'E' && host.Application_Menu_Modifier.Primary in item.shortcut.modifiers && host.Application_Menu_Modifier.Alt in item.shortcut.modifiers
		}
	}
	testing.expect(t, menu_found, "Expand Selection should be reachable from Edit with a portable shortcut")
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 900, 600})
	defer alicorn.destroy_runtime(&rt)
	application_menu_command(rawptr(&app), &rt, action_id_for(ACTION_SELECTION_EXPAND))
	view := &app.editor_views[view_index]
	testing.expect(t, view.selection_anchor == 11 && view.caret_byte == 0,
		"the native command should expand a reverse selection through the backend and preserve direction")
	updated, updated_found := find_document(&app.backend.state, document.id)
	testing.expect(t, updated_found && !updated.dirty && updated.editor_revision == document.editor_revision && updated.byte_length == document.byte_length,
		"semantic selection must leave source revision, byte length, and save state unchanged")
}
