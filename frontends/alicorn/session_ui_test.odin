package main

import "core:encoding/json"
import "core:fmt"
import "core:testing"
import alicorn "alicorn:runtime"
import bridge "./bridge"

session_ui_test_build :: proc(app: ^App, rt: ^alicorn.Runtime, show_tree: bool) {
	session_ui_prepare(app, rt)
	alicorn.invalidate_root(rt, "session restart fixture")
	ui, build := alicorn.begin_frame(rt)
	if !build { return }
	alicorn.container_begin(&ui, .Root, key=alicorn.key_string("session-test-root"), style=alicorn.layout_style(.Column, grow=1, clip=true))
	if show_tree { build_workspace_tree(app, &ui, rt) }
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
	session_ui_after_frame(app, rt)
}

session_ui_test_cleanup :: proc(app: ^App) {
	delete(app.tree_directories)
 delete(app.session_ui.tree_path, context.allocator)
	tree_clear_focused_path(app)
}

@(test)
test_session_ui_restores_virtual_tree_focus_after_serialization_and_runtime_restart :: proc(t: ^testing.T) {
	entries: [500]bridge.Directory_Entry
	for &entry, index in entries {
		name := fmt.tprintf("record-%03d.txt", index)
		entry = bridge.Directory_Entry{name=name, path=name}
	}
	directories := [1]Tree_Directory{{path="", entries=entries[:], expanded=true}}
	first := App{}
	first.backend.started = true
	first.backend.state = bridge.State_Envelope{revision=1, has_workspace=true, workspace_root="fixture"}
	append(&first.tree_directories, directories[0])
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 400, 260})
	session_ui_test_build(&first, &rt, true)
	_ = alicorn.scroll_region_set_offset(&rt, first.tree_scroll_owner, 350*TREE_ROW_HEIGHT)
	tree_set_focused_row(&first, &rt, Tree_Row{path=entries[350].path}, 350)
	session_ui_test_build(&first, &rt, true)
	session_ui_capture(&first, &rt)
	encoded, err := json.marshal(first.session_ui, allocator=context.temp_allocator)
	testing.expect(t, err == nil, "the application semantic schema must serialize")
	alicorn.destroy_runtime(&rt)
	session_ui_test_cleanup(&first)
	defer delete(encoded, context.temp_allocator)

	saved: bridge.Session_UI
	testing.expect(t, json.unmarshal(encoded, &saved, allocator=context.temp_allocator) == nil, "the saved schema must decode independently of runtime state")
	defer { delete(saved.focus, context.temp_allocator); delete(saved.tree_path, context.temp_allocator) }
	second := App{}
	second.backend.started = true
	second.backend.state = bridge.State_Envelope{revision=1, has_workspace=true, workspace_root="fixture", session_ui=saved}
	append(&second.tree_directories, directories[0])
	defer session_ui_test_cleanup(&second)
	fresh := alicorn.new_runtime(alicorn.Rect{0, 0, 300, 180})
	defer alicorn.destroy_runtime(&fresh)
	session_ui_test_build(&second, &fresh, false)
	testing.expect(t, second.session_ui_restore_pending, "startup can defer focus until the tree is described")
	session_ui_test_build(&second, &fresh, true)
	session_ui_test_build(&second, &fresh, true)
	focus := alicorn.semantic_focus_state(&fresh)
	testing.expect(t, focus.id == tree_semantic_id(entries[350].path, false) && focus.realized_node != 0,
		"semantic focus must rebind to the application path within the restored virtual range")
	testing.expect(t, alicorn.focused_node(&fresh) == second.tree_scroll_owner && !second.session_ui_restore_pending,
		"keyboard focus belongs to the freshly acquired tree owner")
	testing.expect(t, alicorn.scroll_region_state(&fresh, second.tree_scroll_owner).offset_y == 350*TREE_ROW_HEIGHT,
		"the fresh tree restores its logical offset despite a changed viewport")
	_, rebuild := alicorn.begin_frame(&fresh)
	testing.expect(t, !rebuild, "completed restoration must return to idle")
}

@(test)
test_session_ui_deleted_focus_and_shrunken_content_use_safe_fallback :: proc(t: ^testing.T) {
	entries := [1]bridge.Directory_Entry{{name="remaining.txt", path="remaining.txt"}}
	directories := [1]Tree_Directory{{path="", entries=entries[:], expanded=true}}
	app := App{}
	app.backend.started = true
	app.backend.state = bridge.State_Envelope{revision=1, has_workspace=true, session_ui=bridge.Session_UI{focus="tree", tree_path="deleted.txt", tree_scroll_y=9000}}
	append(&app.tree_directories, directories[0])
	defer session_ui_test_cleanup(&app)
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 300, 180})
	defer alicorn.destroy_runtime(&rt)
	session_ui_test_build(&app, &rt, true)
	session_ui_test_build(&app, &rt, true)
	testing.expect(t, alicorn.semantic_focus_state(&rt).realized_node == 0 && !app.session_ui_restore_pending,
		"a deleted path must not transfer logical focus to an unrelated row or keep retrying")
	testing.expect(t, alicorn.scroll_region_state(&rt, app.tree_scroll_owner).offset_y == 0,
		"shrinking the tree clamps its old offset at zero")
}

@(test)
test_session_ui_delayed_focus_yields_to_user_input :: proc(t: ^testing.T) {
	app := App{}
	app.backend.started = true
	app.backend.state = bridge.State_Envelope{revision=1, has_workspace=true, session_ui=bridge.Session_UI{focus="tree", tree_path="later.txt"}}
	defer session_ui_test_cleanup(&app)
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 300, 180})
	defer alicorn.destroy_runtime(&rt)
	session_ui_test_build(&app, &rt, false)
	alicorn.invalidate_root(&rt, "user opened another control while tree was unavailable")
	ui, _ := alicorn.begin_frame(&rt)
	alicorn.container_begin(&ui, .Root, style=alicorn.layout_style(.Column, grow=1))
	field := alicorn.text_field(&ui, "search", style=alicorn.layout_style(height=40))
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
	_ = alicorn.focus(&rt, field)
	session_ui_prepare(&app, &rt)
	session_ui_after_frame(&app, &rt)
	testing.expect(t, !app.session_ui_restore_pending && alicorn.focused_node(&rt) == field,
		"an unavailable saved focus target must yield to the user's new control")
}
