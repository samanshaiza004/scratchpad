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
		if tree_test_paths_equal(row.path, "ordinary/keep.txt") {
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
	focused_path_preserved := tree_test_paths_equal(app.tree_focused_path, "ordinary/keep.txt")
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
	runa_name_node := tree_test_row_text_node(&rt, runa_id)
	stable_name_node := tree_test_row_text_node(&rt, stable_id)
	runa_name_x: f32
	stable_name_x: f32
	if runa_name_node != 0 { runa_name_x = rt.nodes[runa_name_node].bounds.x }
	if stable_name_node != 0 { stable_name_x = rt.nodes[stable_name_node].bounds.x }
	initial_tree_scroll_owner := app.tree_scroll_owner
	testing.expect(t, runa_found, "root listing should contain the initially collapsed Runa folder")
	testing.expect(t, stable_found && initial_tree_scroll_owner != 0, "the root should contain an unaffected sibling and a retained scroll owner")
	testing.expect(t, tree_test_row_has_icon(&rt, runa_id, .Folder_Closed) &&
		!tree_test_row_has_icon(&rt, runa_id, .Chevron_Right) && !tree_test_row_has_icon(&rt, runa_id, .Chevron_Down),
		"collapsed workspace directories should use one closed-folder icon without a disclosure slot")
	testing.expect(t, tree_test_row_has_icon(&rt, stable_id, .File),
		"workspace files should use the same single icon gutter as directories")
	testing.expect(t, runa_name_node != 0 && stable_name_node != 0 && abs(runa_name_x-stable_name_x) < 0.1,
		"top-level files and folders should align names after one shared icon gutter")
	testing.expect(t, rt.nodes[runa_id].bounds.h == f32(TREE_ROW_HEIGHT),
		"workspace rows should use the compact virtual-list item height")
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
	testing.expect(t, tree_test_row_has_icon(&rt, runa_id, .Folder_Open) &&
		!tree_test_row_has_icon(&rt, runa_id, .Chevron_Right) && !tree_test_row_has_icon(&rt, runa_id, .Chevron_Down),
		"expanded workspace directories should communicate state with folder artwork alone")
	runa_name_after := tree_test_row_text_node(&rt, runa_id)
	testing.expect(t, runa_name_after == runa_name_node && runa_name_after != 0 && rt.nodes[runa_name_after].bounds.x == runa_name_x,
		"opening a folder should retain the filename node and stable horizontal icon gutter")
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

	// Tree focus and editor selection can diverge when a user changes documents
	// through tabs. Keep the focused row highlight, and independently accent the
	// row for the active document.
	_ = alicorn.style_root_accessibility_set(&rt, alicorn.Accessibility_Appearance_Preferences{differentiate_without_color=true})
	avar_id, _ = test_workspace_tree_row(&rt, "Runa/parse/avar.odin")
	_ = alicorn.semantic_focus_set(&rt, rt.nodes[avar_id].semantic_id, app.tree_scroll_owner)
	alicorn.invalidate_root(&rt, "test tree focus moved away from active document")
	testing.expect(t, test_render_workspace_tree(t, &app, &rt), "tree focus should update while the active document remains unchanged")
	cff2_id, _ = test_workspace_tree_row(&rt, "Runa/parse/cff2.odin")
	avar_id, _ = test_workspace_tree_row(&rt, "Runa/parse/avar.odin")
	cff2_name_id := tree_test_row_text_node(&rt, cff2_id)
	avar_name_id := tree_test_row_text_node(&rt, avar_id)
	testing.expect(t, tree_path_is_workspace_entry(app.tree_root_path, rt.nodes[cff2_id].key, cff2_document.path) &&
		!tree_path_is_workspace_entry(app.tree_root_path, rt.nodes[avar_id].key, cff2_document.path),
		"the active document path should identify only its matching workspace-tree entry")
	testing.expect(t, !rt.nodes[cff2_id].selected && rt.nodes[avar_id].selected,
		"the tree keyboard highlight should follow the focused row, not the active document")
	test_ui := alicorn.UI{runtime=&rt}
	active_filename_ink := alicorn.style_contrast_fallback(
		alicorn.style_color(&test_ui, .Accent),
		alicorn.style_color(&test_ui, .Subtle_Surface),
		4.5,
	)
	testing.expect(t, cff2_name_id != 0 && avar_name_id != 0 && rt.nodes[cff2_name_id].color == active_filename_ink,
		"the active document filename should use the theme accent or its readable contrast fallback")
	testing.expect(t, cff2_name_id != 0 && len(rt.nodes[cff2_name_id].text_paint_spans) == 1 &&
		rt.nodes[cff2_name_id].text_paint_spans[0].underline,
		fmt.tprintf("differentiate-without-color should underline the active document filename (cff2=%v spans=%d)",
			cff2_name_id, len(rt.nodes[cff2_name_id].text_paint_spans)))
	_ = alicorn.semantic_focus_set(&rt, rt.nodes[cff2_id].semantic_id, app.tree_scroll_owner)
	alicorn.invalidate_root(&rt, "restore test tree focus before active document change")
	testing.expect(t, test_render_workspace_tree(t, &app, &rt), "tree focus should restore before selecting another document")

	testing.expect(t, test_click_workspace_tree_row(t, &app, &rt, "Runa/parse/avar.odin"), "avar file should accept a click")
	testing.expect(t, rt.invalidated, "changing the active file during description should retain its follow-up invalidation")
	avar_id, _ = test_workspace_tree_row(&rt, "Runa/parse/avar.odin")
	cff2_id, _ = test_workspace_tree_row(&rt, "Runa/parse/cff2.odin")
	avar_path := app.tree_focused_path
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
test_render_workspace_tree :: proc(t: ^testing.T, app: ^App, rt: ^alicorn.Runtime, width: f32 = 800, height: f32 = 600) -> bool {
	ui, should_build := alicorn.begin_frame(rt)
	if !should_build { return false }
	alicorn.container_begin(&ui, .Root, label="scratchpad-tree-integration-test", style=alicorn.layout_style(.Column, width=width, height=height, clip=true))
	build_workspace_tree(app, &ui, rt)
	alicorn.container_end(&ui)
	workspace_context_menu_build(app, &ui, rt)
	alicorn.end_frame(&ui)
	return true
}

@(test)
test_workspace_tree_compact_gutter_fits_sidebar_widths :: proc(t: ^testing.T) {
	app: App
	app.backend.state.has_workspace = true
	app.backend.state.workspace_root = "C:/compact-tree-fixture"
	app.tree_directories = make([dynamic]Tree_Directory, 0, allocator=context.allocator)
	root_entries := [?]bridge.Directory_Entry{
		{name="examples", path="examples", dir=true},
		{name="a-really-long-readme-filename-that-needs-ellipsis.txt", path="a-really-long-readme-filename-that-needs-ellipsis.txt", dir=false},
	}
	nested_entries := [?]bridge.Directory_Entry{{name="sample.odin", path="examples/sample.odin", dir=false}}
	append(&app.tree_directories, Tree_Directory{path="", entries=root_entries[:], expanded=true})
	append(&app.tree_directories, Tree_Directory{path="examples", entries=nested_entries[:], expanded=true})
	defer delete(app.tree_directories)

	widths := [3]f32{220, 320, 560}
	for width in widths {
		rt := alicorn.new_runtime(alicorn.Rect{0, 0, width, 420})
		fonts_loaded := alicorn.text_engine_load_font(&rt.text_engine, ALICORN_TEST_UI_FONT_DATA)
		testing.expect(t, fonts_loaded, fmt.tprintf("compact tree width %.0f should load the bundled UI font", width))
		if !fonts_loaded { alicorn.destroy_runtime(&rt); continue }
		if !test_render_workspace_tree(t, &app, &rt, width, 420) {
			testing.expect(t, false, fmt.tprintf("workspace tree should build at width %.0f", width))
			alicorn.destroy_runtime(&rt)
			continue
		}

		folder_id, folder_found := test_workspace_tree_row(&rt, "examples")
		file_id, file_found := test_workspace_tree_row(&rt, "a-really-long-readme-filename-that-needs-ellipsis.txt")
		nested_id, nested_found := test_workspace_tree_row(&rt, "examples/sample.odin")
		folder_name := tree_test_row_text_node(&rt, folder_id)
		file_name := tree_test_row_text_node(&rt, file_id)
		nested_name := tree_test_row_text_node(&rt, nested_id)
		testing.expect(t, folder_found && file_found && nested_found,
			fmt.tprintf("compact tree rows should be present at width %.0f", width))
		if !folder_found || !file_found || !nested_found { alicorn.destroy_runtime(&rt); continue }
		if folder_name == 0 || file_name == 0 || nested_name == 0 {
			testing.expect(t, false, fmt.tprintf("compact tree names should be present at width %.0f", width))
			alicorn.destroy_runtime(&rt)
			continue
		}

		folder_x := rt.nodes[folder_name].bounds.x
		file_x := rt.nodes[file_name].bounds.x
		nested_x := rt.nodes[nested_name].bounds.x
		testing.expect(t, abs(folder_x-file_x) < 0.1 && abs(nested_x-folder_x-TREE_INDENT_WIDTH) < 0.1,
			fmt.tprintf("single icon gutters should align names at width %.0f (folder=%v file=%v nested=%v indent=%v)", width, folder_x, file_x, nested_x, TREE_INDENT_WIDTH))
		row_ids := [3]alicorn.Node_ID{folder_id, file_id, nested_id}
		for row_id in row_ids {
			row := rt.nodes[row_id]
			name_id := tree_test_row_text_node(&rt, row_id)
			name := rt.nodes[name_id]
			testing.expect(t, row.bounds.h == f32(TREE_ROW_HEIGHT) && row.bounds.x >= 0 && row.bounds.x+row.bounds.w <= width+0.1,
				fmt.tprintf("compact tree row should fit its viewport at width %.0f", width))
			testing.expect(t, name.text_style.overflow == .Ellipsis && name.bounds.x+name.bounds.w <= row.bounds.x+row.bounds.w+0.1,
				fmt.tprintf("long names should ellipsize within their row at width %.0f", width))
			testing.expect(t, !tree_test_row_has_key(&rt, row_id, "tree-row-disclosure-slot"),
				"tree rows should not retain an empty disclosure-icon slot")
		}
		alicorn.destroy_runtime(&rt)
	}
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
		if node, exists := rt.nodes[node_id]; exists && tree_test_paths_equal(node.key, path) {
			return node_id, true
		}
	}
	return 0, false
}
tree_test_row_text_node :: proc(rt: ^alicorn.Runtime, row_id: alicorn.Node_ID) -> alicorn.Node_ID {
	if rt == nil || row_id == 0 { return 0 }
	for node_id in rt.order {
		node, found := rt.nodes[node_id]
		if found && node.active && node.parent == row_id && node.kind == .Text && node.key == "tree-row-name" { return node_id }
	}
	return 0
}

tree_test_row_has_icon :: proc(rt: ^alicorn.Runtime, row_id: alicorn.Node_ID, icon_id: alicorn.Icon_ID) -> bool {
	if rt == nil || row_id == 0 { return false }
	for node_id in rt.order {
		node, found := rt.nodes[node_id]
		if found && node.active && node.parent == row_id && node.icon_id == icon_id { return true }
	}
	return false
}

tree_test_row_has_key :: proc(rt: ^alicorn.Runtime, row_id: alicorn.Node_ID, key: string) -> bool {
	if rt == nil || row_id == 0 { return false }
	for node_id in rt.order {
		node, found := rt.nodes[node_id]
		if found && node.active && node.parent == row_id && node.key == key { return true }
	}
	return false
}

tree_test_paths_equal :: proc(actual, expected: string) -> bool {
	if len(actual) != len(expected) { return false }
	for i in 0..<len(expected) {
		actual_byte := actual[i]
		expected_byte := expected[i]
		if actual_byte == '\\' { actual_byte = '/' }
		if expected_byte == '\\' { expected_byte = '/' }
		if actual_byte != expected_byte { return false }
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
