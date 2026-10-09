package main

import "core:fmt"
import "core:os"
import "core:sync"
import "core:testing"
import alicorn "alicorn:runtime"
import bridge "./bridge"

@(test)
test_workspace_background_context_menu_targets_root_without_changing_selection :: proc(t: ^testing.T) {
	sync.mutex_lock(&backend_integration_test_mutex)
	defer sync.mutex_unlock(&backend_integration_test_mutex)
	workspace, workspace_error := os.make_directory_temp("", "scratchpad-alicorn-tree-background-*", context.temp_allocator)
	if workspace_error != nil {
		testing.expect(t, false, "could not create a temporary workspace for the background context-menu test")
		return
	}
	defer _ = os.remove_all(workspace)
	seed_path := fmt.tprintf("%s/seed.txt", workspace)
	if err := os.write_entire_file_from_string(seed_path, "keep this selection\n"); err != nil {
		testing.expect(t, false, "could not create the context-menu fixture file")
		return
	}
	backend_library, found_library := os.lookup_env("SCRATCHPAD_BACKEND_LIBRARY", context.temp_allocator)
	if !found_library {
		testing.expect(t, false, "workspace context-menu test requires the staged shared Scratchpad backend")
		return
	}
	defer delete(backend_library, context.temp_allocator)
	app: App
	app.tree_directories = make([dynamic]Tree_Directory, 0, allocator=context.allocator)
	app.editor_views = make([dynamic]Editor_View_State, 0, allocator=context.allocator)
	app.editor_edits = make([dynamic]Editor_Edit_Intent, 0, allocator=context.allocator)
	loaded, load_message := bridge.backend_load(&app.backend, backend_library)
	testing.expect(t, loaded, fmt.tprintf("shared backend should load for background context-menu test: %s", load_message))
	if !loaded { return }
	started, start_message := bridge.backend_start(&app.backend, workspace, tree_test_wake, nil, context.allocator)
	testing.expect(t, started, fmt.tprintf("shared backend should start for background context-menu test: %s", start_message))
	if !started { return }
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 800, 600})
	defer tree_test_cleanup(t, &app, &rt)
	defer editor_views_destroy(&app.editor_views)
	defer delete(app.editor_edits)
	tree_sync_workspace(&app, &rt)
	if !test_render_workspace_tree(t, &app, &rt) { return }

	rows := make([dynamic]Tree_Row, 0, allocator=context.temp_allocator)
	tree_flatten_directory(&app, "", 0, &rows)
	seed_index := -1
	for row, index in rows {
		if row.path == "seed.txt" {
			seed_index = index
			tree_set_focused_row(&app, &rt, row, index)
			break
		}
	}
	delete(rows)
	testing.expect(t, seed_index >= 0, "the test file should be a selectable workspace row")
	if seed_index < 0 { return }
	focus_before := alicorn.focused_node(&rt)
	semantic_before := alicorn.semantic_focus_state(&rt)
	selection_index, selection_ok := editor_view_ensure(&app.editor_views, "background-menu-selection", context.allocator)
	testing.expect(t, selection_ok, "the fixture should retain an existing editor selection")
	if !selection_ok { return }
	app.editor_views[selection_index].selection_anchor = 2
	app.editor_views[selection_index].caret_byte = 8

	viewport := alicorn.scroll_region_state(&rt, app.tree_scroll_owner).viewport_bounds
	background_event := alicorn.Pointer_Event{
		kind=.Down,
		x=viewport.x+min(viewport.w*0.5, 12),
		y=viewport.y+viewport.h-6,
		button=alicorn.POINTER_BUTTON_SECONDARY,
	}
	background_target := alicorn.process_pointer(&rt, background_event)
	if key, key_ok := alicorn.node_identity_key(&rt, background_target); key_ok {
		background_event.target_key = key
	}
	application_pointer(rawptr(&app), &rt, background_event, background_target)
	testing.expect(t, alicorn.context_menu_is_open(&rt) && app.workspace_context_target == .Workspace_Root,
		"a secondary click on empty tree space should open the explicit workspace-root context target")
	testing.expect(t, app.tree_focused_path == "seed.txt" && alicorn.semantic_focus_state(&rt).id == semantic_before.id,
		"opening the background menu must not select or activate an unrelated tree row")
	testing.expect(t, app.editor_views[selection_index].selection_anchor == 2 && app.editor_views[selection_index].caret_byte == 8,
		"opening the background menu must preserve the existing editor selection")
	if !test_render_workspace_tree(t, &app, &rt) { return }
	new_file_item := test_workspace_context_menu_item(&rt, "New File…")
	new_folder_item := test_workspace_context_menu_item(&rt, "New Folder…")
	no_item_actions := test_workspace_context_menu_item(&rt, "Rename") == 0 && test_workspace_context_menu_item(&rt, "Move to Trash") == 0
	testing.expect(t, new_file_item != 0 && new_folder_item != 0 && no_item_actions,
		"the workspace-root menu should offer only its creation actions")
	alicorn.context_menu_close(&rt)
	if !test_render_workspace_tree(t, &app, &rt) { return }
	testing.expect(t, alicorn.focused_node(&rt) == focus_before && alicorn.semantic_focus_state(&rt).id == semantic_before.id,
		"dismissing a background menu should restore the prior keyboard and semantic focus")
	testing.expect(t, app.editor_views[selection_index].selection_anchor == 2 && app.editor_views[selection_index].caret_byte == 8,
		"dismissing the background menu should leave the editor selection unchanged")

	workspace_context_menu_test_open_background(t, &app, &rt)
	if !test_render_workspace_tree(t, &app, &rt) { return }
	new_file_item = test_workspace_context_menu_item(&rt, "New File…")
	if new_file_item == 0 { testing.expect(t, false, "root context menu should expose New File"); return }
	_ = alicorn.focus(&rt, new_file_item)
	_ = alicorn.context_menu_handle_key(&rt, .Activate)
	if !test_render_workspace_tree(t, &app, &rt) { return }
	testing.expect(t, app.workspace_mutation_kind == .Create_File && app.workspace_mutation_source == "" && app.workspace_mutation_source_is_dir,
		"New File should enter the existing mutation flow with an explicit workspace-root destination")
	workspace_mutation_set_name(&app, "created-from-background.txt")
	workspace_mutation_submit(&app, &rt, false)
	if !test_render_workspace_tree(t, &app, &rt) { return }
	_, created_file_visible := test_workspace_tree_row(&rt, "created-from-background.txt")
	testing.expect(t, created_file_visible,
		"the normal refresh path should show a file created from the workspace-root context menu")

	workspace_context_menu_test_open_background(t, &app, &rt)
	if !test_render_workspace_tree(t, &app, &rt) { return }
	new_folder_item = test_workspace_context_menu_item(&rt, "New Folder…")
	if new_folder_item == 0 { testing.expect(t, false, "root context menu should expose New Folder"); return }
	_ = alicorn.focus(&rt, new_folder_item)
	_ = alicorn.context_menu_handle_key(&rt, .Activate)
	if !test_render_workspace_tree(t, &app, &rt) { return }
	testing.expect(t, app.workspace_mutation_kind == .Create_Folder && app.workspace_mutation_source == "" && app.workspace_mutation_source_is_dir,
		"New Folder should enter the existing mutation flow with an explicit workspace-root destination")
	workspace_mutation_set_name(&app, "folder-from-background")
	workspace_mutation_submit(&app, &rt, false)
	if !test_render_workspace_tree(t, &app, &rt) { return }
	_, created_folder_visible := test_workspace_tree_row(&rt, "folder-from-background")
	testing.expect(t, created_folder_visible,
		"the normal refresh path should show a folder created from the workspace-root context menu")
}

workspace_context_menu_test_open_background :: proc(t: ^testing.T, app: ^App, rt: ^alicorn.Runtime) {
	viewport := alicorn.scroll_region_state(rt, app.tree_scroll_owner).viewport_bounds
	event := alicorn.Pointer_Event{
		kind=.Down,
		x=viewport.x+min(viewport.w*0.5, 12),
		y=viewport.y+viewport.h-6,
		button=alicorn.POINTER_BUTTON_SECONDARY,
	}
	target := alicorn.process_pointer(rt, event)
	if key, key_ok := alicorn.node_identity_key(rt, target); key_ok { event.target_key = key }
	application_pointer(rawptr(app), rt, event, target)
	testing.expect(t, alicorn.context_menu_is_open(rt) && app.workspace_context_target == .Workspace_Root,
		"empty tree space should reopen the workspace-root context menu")
}
