package main

import "core:strings"
import "core:testing"

@(test)
test_git_diff_deferred_action_owns_snapshot_and_rejects_repository_switch :: proc(t: ^testing.T) {
	app: App
	app.backend.state.git.root, _ = strings.clone("/workspace/first", context.allocator)
	defer delete(app.backend.state.git.root, context.allocator)

	path, path_err := strings.clone("internal/changes.go", context.allocator)
	revision, revision_err := strings.clone("0123456789abcdef", context.allocator)
	if path_err != nil || revision_err != nil {
		delete(path, context.allocator)
		delete(revision, context.allocator)
		testing.expect(t, false, "the test should allocate borrowed Git snapshot strings")
		return
	}
	defer delete(path, context.allocator)
	defer delete(revision, context.allocator)

	queued := git_defer_open_diff(&app, nil, "commit", path, revision, beside=true)
	defer deferred_action_destroy(&app.frame_deferred_action)
	testing.expect(t, queued && app.frame_deferred_action_pending,
		"opening a History diff should queue an owned post-frame request")
	if !queued { return }

	action := app.frame_deferred_action
	delete(path, context.allocator)
	delete(revision, context.allocator)
	path, revision = "", ""
	testing.expect(t,
		action.path == "internal/changes.go" && action.value == "0123456789abcdef" &&
		action.git_kind == "commit" && action.git_beside &&
		action.document_id == "/workspace/first",
		"the deferred request must own the commit, path, and repository identity after the published snapshot is released")
	testing.expect(t, git_deferred_diff_matches_repository(&app, action.document_id),
		"the request should remain valid for the repository that produced its History snapshot")

	duplicate_queued := frame_deferred_action_schedule(&app, .Git_Open_Diff, value="later-revision")
	testing.expect(t, !duplicate_queued && app.frame_deferred_action.value == "0123456789abcdef",
		"rapid repeated clicks in one frame must not replace or duplicate the first owned request")

	delete(app.backend.state.git.root, context.allocator)
	app.backend.state.git.root, _ = strings.clone("/workspace/second", context.allocator)
	testing.expect(t, !git_deferred_diff_matches_repository(&app, action.document_id),
		"a queued History diff must be rejected after switching repositories")
}

@(test)
test_workbench_open_beside_is_deferred_until_after_description :: proc(t: ^testing.T) {
	app: App
	if !app_workbench_initialize(&app, context.allocator) {
		testing.expect(t, false, "the pane model should initialize")
		return
	}
	defer workbench_model_destroy(&app.workbench_model)
	defer deferred_action_destroy(&app.frame_deferred_action)

	window := app_workbench_window(&app)
	if window == nil { testing.expect(t, false, "the initialized pane model should have a window"); return }
	initial_nodes, initial_groups, initial_views := len(window.nodes), len(window.groups), len(window.views)
	git_defer_workbench_open_beside(&app, nil, .Git_History)

	window = app_workbench_window(&app)
	testing.expect(t, app.frame_deferred_action_pending &&
		app.frame_deferred_action.kind == .Workbench_Open_Beside &&
		app.frame_deferred_action.workbench_content_kind == .Git_History,
		"a UI split action should be represented as a post-frame workbench mutation")
	testing.expect(t, window != nil && len(window.nodes) == initial_nodes &&
		len(window.groups) == initial_groups && len(window.views) == initial_views &&
		workbench_model_state_valid(&app.workbench_model),
		"the pane tree must remain unchanged while its current description is being built")
}
