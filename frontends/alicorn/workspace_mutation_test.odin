package main

import "core:encoding/json"
import "core:strings"
import "core:testing"
import alicorn "alicorn:runtime"
import bridge "./bridge"

@(test)
test_workspace_path_rewrite_is_component_aware :: proc(t: ^testing.T) {
	rewritten: string
	exact, descendant, sibling, no_descendants, separator: bool
	rewritten, exact = tree_path_rewrite("notes/foo", "notes/foo", "archive/bar", true)
	testing.expect(t, exact && rewritten == "archive/bar", "rename/move should rewrite the exact source path")

	rewritten, descendant = tree_path_rewrite("notes/foo/child.md", "notes/foo", "archive/bar", true)
	testing.expect(t, descendant && rewritten == "archive/bar/child.md", "directory moves should rewrite descendant paths")

	rewritten, sibling = tree_path_rewrite("notes/foobar/child.md", "notes/foo", "archive/bar", true)
	testing.expect(t, !sibling && rewritten == "notes/foobar/child.md", "a textual prefix without a path-component boundary must not be rewritten")

	rewritten, no_descendants = tree_path_rewrite("notes/foo/child.md", "notes/foo", "archive/bar", false)
	testing.expect(t, !no_descendants && rewritten == "notes/foo/child.md", "file moves must not rewrite unrelated descendants")

	rewritten, separator = tree_path_rewrite(`C:\vault\foo\child.md`, `C:\vault\foo`, `C:\vault\archive`, true)
	testing.expect(t, separator && rewritten == `C:\vault\archive\child.md`, "path rewriting should preserve the source separator")
}

@(test)
test_workspace_relative_path_helpers :: proc(t: ^testing.T) {
	testing.expect(t, tree_parent_relative_path("notes/today.md") == "notes", "nested path parent should be its containing directory")
	testing.expect(t, tree_parent_relative_path("README.md") == "", "root path parent should be the workspace root")
	testing.expect(t, tree_basename("notes/today.md") == "today.md", "path basename should preserve the full file name")
	testing.expect(t, tree_join_relative_path("notes", "today.md") == "notes/today.md", "relative path join should use the workspace path form")
}

@(test)
test_workspace_rename_selects_filename_stem :: proc(t: ^testing.T) {
	testing.expect(t, workspace_mutation_stem_end("README.md") == 6, "rename should preselect the stem but preserve the extension")
	testing.expect(t, workspace_mutation_stem_end("archive.tar.gz") == 11, "rename should retain intermediate suffixes as part of the filename stem")
	testing.expect(t, workspace_mutation_stem_end(".gitignore") == len(".gitignore"), "a leading-dot filename without an extension should be selected in full")
	testing.expect(t, workspace_mutation_stem_end("README") == len("README"), "an extensionless name should be selected in full")
}

@(test)
test_workspace_mutation_autofocus_stem_selection_and_modal_traversal :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 640, 360})
	defer alicorn.destroy_runtime(&rt)
	ui, should_build := alicorn.begin_frame(&rt)
	if !should_build { testing.expect(t, false, "mutation dialog focus test should describe its first frame"); return }
	alicorn.container_begin(&ui, .Root, key=alicorn.key_string("workspace-mutation-focus-test-root"), style=alicorn.layout_style(.Column, grow=1))
	_ = alicorn.text_field(&ui, "background", key=alicorn.key_string("workspace-mutation-background-field"))
	alicorn.container_end(&ui)
	alicorn.modal_overlay_begin(&ui, alicorn.key_string("workspace-mutation-focus-test-overlay"), style=alicorn.layout_style(.Column, grow=1))
	alicorn.container_begin(&ui, .Container, key=alicorn.key_string("workspace-mutation-focus-test-dialog"), style=alicorn.layout_style(.Column, width=420, height=180, padding=12, gap=8))
	field := alicorn.text_field(&ui, "archive.tar.gz", key=alicorn.key_string("workspace-mutation-name"))
	_ = alicorn.button(&ui, "Cancel", key=alicorn.key_string("workspace-mutation-cancel"))
	_ = alicorn.button(&ui, "Rename", key=alicorn.key_string("workspace-mutation-confirm"))
	alicorn.container_end(&ui)
	alicorn.modal_overlay_end(&ui)
	alicorn.end_frame(&ui)
	app := App{
		workspace_mutation_kind=.Rename,
		workspace_mutation_name="archive.tar.gz",
		workspace_mutation_name_node=field,
		workspace_mutation_focus_pending=true,
	}
	workspace_mutation_focus_after_frame(&app, &rt)
	testing.expect(t, rt.focused == field, "opening a mutation dialog should focus its text field after description")
	if node, found := rt.nodes[field]; found {
		testing.expect(t, node.selection_anchor.byte == 0 && node.selection_focus.byte == 11,
			"rename autofocus should select archive.tar while leaving the final extension unselected")
	} else {
		testing.expect(t, false, "the mutation field should remain a live retained node")
	}
	traversed := alicorn.focus_traverse(&rt, .Next)
	if node, found := rt.nodes[traversed]; found {
		testing.expect(t, node.key == "workspace-mutation-cancel" || node.key == "workspace-mutation-confirm",
			"Tab from a mutation field must stay within the modal instead of reaching background controls")
	} else {
		testing.expect(t, false, "Tab should focus a live control in the mutation modal")
	}
}

@(test)
test_rename_name_is_carried_by_the_existing_command_request :: proc(t: ^testing.T) {
	request := bridge.Backend_Command_Request{
		version=1,
		request_id=7,
		based_on_revision=3,
		command="rename_path",
		path="notes/draft.md",
		name="final.md",
	}
	encoded, err := json.marshal(request, allocator=context.temp_allocator)
	if err != nil {
		testing.expect(t, false, "rename command should marshal through the existing Caliber request shape")
		return
	}
	defer delete(encoded, context.temp_allocator)
	wire := string(encoded)
	testing.expect(t, strings.contains(wire, `"name":"final.md"`), "rename must transmit the destination basename without a new command protocol")
}
