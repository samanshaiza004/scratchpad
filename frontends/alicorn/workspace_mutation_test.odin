package main

import "core:encoding/json"
import "core:strings"
import "core:testing"
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
