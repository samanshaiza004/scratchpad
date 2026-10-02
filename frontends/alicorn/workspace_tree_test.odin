package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import alicorn "alicorn:runtime"
import bridge "./bridge"

@(test)
test_workspace_tree_ignore_toggle_preserves_expansion_and_focus :: proc(t: ^testing.T) {
	sync.mutex_lock(&backend_integration_test_mutex)
	defer sync.mutex_unlock(&backend_integration_test_mutex)
	workspace, workspace_error := os.make_directory_temp("", "scratchpad-alicorn-ignore-*", context.temp_allocator)
	if workspace_error != nil {
		testing.expect(t, false, "could not create a temporary workspace for the ignored-file tree test")
		return
	}
	defer _ = os.remove_all(workspace)
	ordinary := fmt.tprintf("%s/ordinary", workspace)
	ignored := fmt.tprintf("%s/ignored", workspace)
	keep_file := fmt.tprintf("%s/ordinary/keep.txt", workspace)
	ignored_file := fmt.tprintf("%s/ignored/generated.txt", workspace)
	if err := os.write_entire_file_from_string(fmt.tprintf("%s/.gitignore", workspace), "ignored/\n"); err != nil {
		testing.expect(t, false, "could not create the ignored-file tree rule")
		return
	}
	if err := os.make_directory(ordinary); err != nil {
		testing.expect(t, false, "could not create the ordinary test directory")
		return
	}
	if err := os.make_directory(ignored); err != nil {
		testing.expect(t, false, "could not create the ignored test directory")
		return
	}
	if err := os.write_entire_file_from_string(keep_file, "keep\n"); err != nil {
		testing.expect(t, false, "could not create the ordinary test file")
		return
	}
	if err := os.write_entire_file_from_string(ignored_file, "generated\n"); err != nil {
		testing.expect(t, false, "could not create the ignored test file")
		return
	}

	backend_library, found_library := os.lookup_env("SCRATCHPAD_BACKEND_LIBRARY", context.temp_allocator)
	if !found_library {
		testing.expect(t, false, "ignored-file tree test requires the staged shared Scratchpad backend")
		return
	}
	defer delete(backend_library, context.temp_allocator)
	app: App
	app.tree_directories = make([dynamic]Tree_Directory, 0, allocator=context.allocator)
	loaded, load_message := bridge.backend_load(&app.backend, backend_library)
	testing.expect(t, loaded, fmt.tprintf("shared Scratchpad backend should load: %s", load_message))
	if !loaded { return }
	started, start_message := bridge.backend_start(&app.backend, workspace, tree_test_wake, nil, context.allocator)
	testing.expect(t, started, fmt.tprintf("shared Scratchpad backend should start: %s", start_message))
	if !started { return }
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 800, 600})
	defer tree_test_cleanup(t, &app, &rt)
	tree_sync_workspace(&app, &rt)
	alicorn.invalidate_root(&rt, "initial ignored-file tree description")
	if !test_render_workspace_tree(t, &app, &rt) { return }
	_ = tree_load_directory(&app, "ordinary", true)
	rows := make([dynamic]Tree_Row, 0, allocator=context.temp_allocator)
	tree_flatten_directory(&app, "", 0, &rows)
	focused_index := -1
	for row, index in rows {
		if tree_test_key_matches_path(fmt.tprintf("workspace-entry:%s", row.path), "ordinary/keep.txt") {
			focused_index = index
			tree_set_focused_row(&app, &rt, row, index)
			break
		}
	}
	delete(rows)
	testing.expect(t, focused_index >= 0, "the expanded ordinary folder should expose its focus target")
	if focused_index < 0 { return }
	alicorn.invalidate_root(&rt, "show the expanded ordinary folder")
	if !test_render_workspace_tree(t, &app, &rt) { return }
	focus_before := alicorn.semantic_focus_state(&rt)

	tree_set_show_ignored_files(&app, &rt, true)
	ordinary_index := tree_directory_index(&app, "ordinary")
	testing.expect(t, ordinary_index >= 0 && app.tree_directories[ordinary_index].expanded,
		"turning ignored-file visibility on should preserve expanded folders")
	if !test_render_workspace_tree(t, &app, &rt) { return }
	_, ignored_visible := test_workspace_tree_row(&rt, "ignored")
	_, keep_visible := test_workspace_tree_row(&rt, "ordinary/keep.txt")
	focus_after := alicorn.semantic_focus_state(&rt)
	testing.expect(t, ignored_visible, "the ignored folder should appear when visibility is enabled")
	testing.expect(t, keep_visible, "the previously expanded ordinary folder should remain visible")
	focused_path_preserved := tree_test_key_matches_path(fmt.tprintf("workspace-entry:%s", app.tree_focused_path), "ordinary/keep.txt")
	testing.expect(t, focus_after.id == focus_before.id && focused_path_preserved,
		"toggling ignored-file visibility should preserve semantic focus")
	_ = tree_load_directory(&app, "ignored", true)
	alicorn.invalidate_root(&rt, "expand ignored test subtree")
	if !test_render_workspace_tree(t, &app, &rt) { return }
	_, generated_visible := test_workspace_tree_row(&rt, "ignored/generated.txt")
	testing.expect(t, generated_visible, "the expanded ignored folder should show its file")

	tree_set_show_ignored_files(&app, &rt, false)
	if !test_render_workspace_tree(t, &app, &rt) { return }
	_, ignored_hidden := test_workspace_tree_row(&rt, "ignored")
	_, keep_visible = test_workspace_tree_row(&rt, "ordinary/keep.txt")
	testing.expect(t, !ignored_hidden && keep_visible,
		"turning ignored-file visibility off should hide ignored entries and retain ordinary expansions")

	tree_set_show_ignored_files(&app, &rt, true)
	if !test_render_workspace_tree(t, &app, &rt) { return }
	_, ignored_visible = test_workspace_tree_row(&rt, "ignored")
	_, generated_visible = test_workspace_tree_row(&rt, "ignored/generated.txt")
	testing.expect(t, ignored_visible && generated_visible,
		"turning ignored-file visibility back on should restore the hidden expanded subtree")
}
@(test)
test_workspace_tree_expansion_and_semantic_selection_refresh_immediately :: proc(t: ^testing.T) {
	sync.mutex_lock(&backend_integration_test_mutex)
	defer sync.mutex_unlock(&backend_integration_test_mutex)
	workspace, workspace_error := os.make_directory_temp("", "scratchpad-alicorn-tree-*", context.temp_allocator)
	if workspace_error != nil {
		testing.expect(t, false, "could not create a temporary workspace for the Alicorn tree test")
		return
	}
	defer _ = os.remove_all(workspace)

	runa := fmt.tprintf("%s/Runa", workspace)
	parse := fmt.tprintf("%s/Runa/parse", workspace)
	cff2 := fmt.tprintf("%s/Runa/parse/cff2.odin", workspace)
	avar := fmt.tprintf("%s/Runa/parse/avar.odin", workspace)
	stable_file := fmt.tprintf("%s/stable.txt", workspace)
	if err := os.make_directory(runa); err != nil {
		testing.expect(t, false, "could not create Runa test directory")
		return
	}
	if err := os.make_directory(parse); err != nil {
		testing.expect(t, false, "could not create parse test directory")
		return
	}
	if err := os.write_entire_file_from_string(cff2, "package cff2\n"); err != nil {
		testing.expect(t, false, "could not create cff2 test file")
		return
	}
	if err := os.write_entire_file_from_string(avar, "package avar\n"); err != nil {
		testing.expect(t, false, "could not create avar test file")
		return
	}
	if err := os.write_entire_file_from_string(stable_file, "stable sibling\n"); err != nil {
		testing.expect(t, false, "could not create stable sibling test file")
		return
	}

	backend_library, found_library := os.lookup_env("SCRATCHPAD_BACKEND_LIBRARY", context.temp_allocator)
	if !found_library {
		testing.expect(t, false, "Alicorn tree integration test requires the staged shared Scratchpad backend")
		return
	}
	defer delete(backend_library, context.temp_allocator)

	app: App
	app.tree_directories = make([dynamic]Tree_Directory, 0, allocator=context.allocator)
	loaded, load_message := bridge.backend_load(&app.backend, backend_library)
	testing.expect(t, loaded, fmt.tprintf("shared Scratchpad backend should load: %s", load_message))
	if !loaded { return }
	started, start_message := bridge.backend_start(&app.backend, workspace, tree_test_wake, nil, context.allocator)
	testing.expect(t, started, fmt.tprintf("shared Scratchpad backend should start: %s", start_message))
	if !started { return }

	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 800, 600})
	defer tree_test_cleanup(t, &app, &rt)
	tree_sync_workspace(&app, &rt)
	alicorn.invalidate_root(&rt, "initial Scratchpad tree description")
	testing.expect(t, test_render_workspace_tree(t, &app, &rt), "initial workspace tree should build")

	runa_id, runa_found := test_workspace_tree_row(&rt, "Runa")
	stable_id, stable_found := test_workspace_tree_row(&rt, "stable.txt")
	initial_tree_scroll_owner := app.tree_scroll_owner
	testing.expect(t, runa_found, "root listing should contain the initially collapsed Runa folder")
	testing.expect(t, stable_found && initial_tree_scroll_owner != 0, "the root should contain an unaffected sibling and a retained scroll owner")
	if !runa_found || !stable_found { return }

	// Loading and expanding a never-opened folder must publish a new description
	// without requiring another user input event.
	testing.expect(t, test_click_workspace_tree_row(t, &app, &rt, "Runa"), "Runa folder should accept a click")
	testing.expect(t, tree_directory_index(&app, "Runa") >= 0 && app.tree_directories[tree_directory_index(&app, "Runa")].expanded,
		"the first Runa click should load and expand it")
	testing.expect(t, rt.invalidated, "folder expansion during description must retain its follow-up invalidation")
	testing.expect(t, test_render_workspace_tree(t, &app, &rt), "folder expansion should trigger the next description without new input")
	parse_id, parse_found := test_workspace_tree_row(&rt, "Runa/parse")
	testing.expect(t, parse_found, "parse should appear immediately after Runa's follow-up description")
	runa_id, _ = test_workspace_tree_row(&rt, "Runa")
	stable_id_after_expansion, stable_sibling_still_found := test_workspace_tree_row(&rt, "stable.txt")
	testing.expect(t, stable_sibling_still_found && stable_id_after_expansion == stable_id,
		"expanding a directory should retain the Node_ID of an unchanged sibling row")
	testing.expect(t, app.tree_scroll_owner == initial_tree_scroll_owner,
		"directory expansion should retain the tree's durable scroll-owner identity")
	testing.expect(t, rt.nodes[runa_id].selected, "the expanded folder should receive its selected presentation on the follow-up description")
	if !parse_found { return }

	testing.expect(t, test_click_workspace_tree_row(t, &app, &rt, "Runa/parse"), "parse folder should accept a click")
	testing.expect(t, rt.invalidated, "nested expansion should retain its follow-up invalidation")
	testing.expect(t, test_render_workspace_tree(t, &app, &rt), "nested expansion should trigger a description without new input")
	cff2_id, cff2_found := test_workspace_tree_row(&rt, "Runa/parse/cff2.odin")
	avar_id, avar_found := test_workspace_tree_row(&rt, "Runa/parse/avar.odin")
	testing.expect(t, cff2_found && avar_found, "both nested source files should appear immediately after expansion")
	parse_id, _ = test_workspace_tree_row(&rt, "Runa/parse")
	testing.expect(t, rt.nodes[parse_id].selected, "the nested folder should receive its selected presentation immediately")
	if !cff2_found || !avar_found { return }

	testing.expect(t, test_click_workspace_tree_row(t, &app, &rt, "Runa/parse/cff2.odin"), "cff2 file should accept a click")
	testing.expect(t, rt.invalidated, "opening a file during description should retain its follow-up invalidation")
	testing.expect(t, test_render_workspace_tree(t, &app, &rt), "opening a file should refresh its selected row without another input event")
	cff2_id, _ = test_workspace_tree_row(&rt, "Runa/parse/cff2.odin")
	cff2_document, cff2_active := find_document(&app.backend.state, app.backend.state.active)
	testing.expect(t, rt.nodes[cff2_id].selected && cff2_active && strings.contains(cff2_document.path, "cff2.odin"),
		"cff2 should be both the semantic focus and active document after its click")

	testing.expect(t, test_click_workspace_tree_row(t, &app, &rt, "Runa/parse/avar.odin"), "avar file should accept a click")
	testing.expect(t, rt.invalidated, "changing the active file during description should retain its follow-up invalidation")
	avar_id, _ = test_workspace_tree_row(&rt, "Runa/parse/avar.odin")
	cff2_id, _ = test_workspace_tree_row(&rt, "Runa/parse/cff2.odin")
	avar_path := rt.nodes[avar_id].key[len("workspace-entry:"):]
	focus_before_followup := alicorn.semantic_focus_state(&rt)
	testing.expect(t, focus_before_followup.id == tree_semantic_id(avar_path, false),
		"semantic focus should move to avar in the click frame")
	testing.expect(t, rt.nodes[cff2_id].selected && !rt.nodes[avar_id].selected,
		"the click frame should still contain its old description until the pending follow-up is built")
	testing.expect(t, test_render_workspace_tree(t, &app, &rt), "active file change should update selection without another input event")
	avar_id, _ = test_workspace_tree_row(&rt, "Runa/parse/avar.odin")
	cff2_id, _ = test_workspace_tree_row(&rt, "Runa/parse/cff2.odin")
	focus := alicorn.semantic_focus_state(&rt)
	testing.expect(t, focus.id == tree_semantic_id(avar_path, false), "semantic focus should move to avar immediately")
	testing.expect(t, rt.nodes[avar_id].selected && !rt.nodes[cff2_id].selected,
		"the blue selected presentation should move from cff2 to avar on that same follow-up description")
	active, active_found := find_document(&app.backend.state, app.backend.state.active)
	testing.expect(t, active_found && strings.contains(active.path, "avar.odin"), "the shared Go backend should publish avar as the active document")
}
test_render_workspace_tree :: proc(t: ^testing.T, app: ^App, rt: ^alicorn.Runtime) -> bool {
	ui, should_build := alicorn.begin_frame(rt)
	if !should_build { return false }
	alicorn.container_begin(&ui, .Root, label="scratchpad-tree-integration-test", style=alicorn.layout_style(.Column, width=800, height=600, clip=true))
	build_workspace_tree(app, &ui, rt)
	alicorn.container_end(&ui)
	workspace_context_menu_build(app, &ui, rt)
	alicorn.end_frame(&ui)
	return true
}
test_workspace_context_menu_item :: proc(rt: ^alicorn.Runtime, label: string) -> alicorn.Node_ID {
	if rt == nil || rt.context_menu.panel == 0 { return 0 }
	for node_id in rt.order {
		if node, found := rt.nodes[node_id]; found && node.active && node.parent == rt.context_menu.panel && node.kind == .Button && node.label == label {
			return node_id
		}
	}
	return 0
}
test_click_workspace_tree_row :: proc(t: ^testing.T, app: ^App, rt: ^alicorn.Runtime, path: string) -> bool {
	id, found := test_workspace_tree_row(rt, path)
	if !found { return false }
	bounds := rt.nodes[id].bounds
	x, y := bounds.x + bounds.w/2, bounds.y + bounds.h/2
	_ = alicorn.process_pointer(rt, alicorn.Pointer_Event{kind=.Down, x=x, y=y, button=1})
	alicorn.invalidate_root(rt, "test pointer down")
	if !test_render_workspace_tree(t, app, rt) { return false }
	_ = alicorn.process_pointer(rt, alicorn.Pointer_Event{kind=.Up, x=x, y=y, button=1})
	alicorn.invalidate_root(rt, "test pointer release")
	return test_render_workspace_tree(t, app, rt)
}
test_workspace_tree_row :: proc(rt: ^alicorn.Runtime, path: string) -> (id: alicorn.Node_ID, found: bool) {
	for node_id in rt.order {
		if node, exists := rt.nodes[node_id]; exists && tree_test_key_matches_path(node.key, path) {
			return node_id, true
		}
	}
	return 0, false
}
tree_test_key_matches_path :: proc(key, path: string) -> bool {
	prefix := "workspace-entry:"
	if !strings.has_prefix(key, prefix) { return false }
	actual := key[len(prefix):]
	if len(actual) != len(path) { return false }
	for i in 0..<len(path) {
		actual_byte := actual[i]
		if actual_byte == '\\' { actual_byte = '/' }
		if actual_byte != path[i] { return false }
	}
	return true
}
tree_test_cleanup :: proc(t: ^testing.T, app: ^App, rt: ^alicorn.Runtime) {
	if app.backend.started {
		stopped, message := bridge.backend_stop(&app.backend, context.allocator)
		testing.expect(t, stopped, fmt.tprintf("shared Scratchpad backend should stop cleanly: %s", message))
	}
	tree_clear_directories(app)
	tree_clear_focused_path(app)
	workspace_context_menu_clear(app)
	if len(app.tree_root_path) > 0 { delete(app.tree_root_path, context.allocator) }
	alicorn.destroy_runtime(rt)
}
