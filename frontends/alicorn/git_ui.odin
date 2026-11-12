package main

import "core:fmt"
import "core:strings"
import alicorn "alicorn:runtime"
import gui "alicorn:ui"
import bridge "./bridge"

git_workbench_is_document :: proc(app: ^App) -> bool {
	if app == nil { return true }
	view, found := app_workbench_active_view(app)
	return !found || view.kind == .Editor
}

git_workbench_sync_repository :: proc(app: ^App) {
	if app == nil { return }
	root := app.backend.state.git.root
	if root == app.git_repository_root { return }
	if len(app.git_repository_root) > 0 { delete(app.git_repository_root, context.allocator) }
	app.git_repository_root = ""
	if root != "" { app.git_repository_root, _ = strings.clone(root, context.allocator) }
	if window := app_workbench_window(app); window != nil {
		repository_identity := app_workbench_repository_identity(app)
		for view in window.views {
			if view.kind != .History && view.kind != .Diff { continue }
			if !app_workbench_view_resource_rebind(app, view.id, repository_identity) {
				set_error(app, "Could not update a Git workbench view for the active repository.")
			}
		}
	}
	if len(app.git_selected_commit) > 0 { delete(app.git_selected_commit, context.allocator) }
	app.git_selected_commit = ""
	if len(app.git_commit_message) > 0 { delete(app.git_commit_message, context.allocator) }
	app.git_commit_message = ""
	if len(app.git_commit_submitted_message) > 0 { delete(app.git_commit_submitted_message, context.allocator) }
	app.git_commit_submitted_message = ""
	app.git_commit_clear_pending = false
	git_diff_clear(app)
	app.git_history_graph_payload_node = 0
	app.git_history_graph_generation = 0
	app.git_history_scroll_y = 0
	app.git_history_scroll_restore = false
	app.git_diff_scroll_x = 0
	app.git_diff_scroll_y = 0
	app.git_diff_scroll_restore = false
}

git_diff_clear :: proc(app: ^App) {
	if app == nil { return }
	if len(app.git_diff_text) > 0 { delete(app.git_diff_text, context.allocator) }
	app.git_diff_text = ""
	app.git_diff_loaded_generation = 0
	app.git_diff_untracked = false
	app.git_diff_content_width = 0
	app.git_diff_selected_hunk = 0
	app.git_diff_scroll_owner = 0
	app.git_diff_scroll_x = 0
	app.git_diff_scroll_y = 0
	app.git_diff_scroll_restore = false
	clear(&app.git_diff_lines)
	clear(&app.git_diff_hunks)
}

git_workbench_select :: proc(app: ^App, rt: ^alicorn.Runtime, view: Workbench_Content_Kind) -> bool {
	if app == nil || rt == nil { return false }
	if app.workspace_search_mode && !workspace_search_deactivate(app, rt) { return false }
	kind := Workbench_View_Kind.History if view == .Git_History else Workbench_View_Kind.Diff
	view_id, ok := app_workbench_view_ensure_kind(app, kind)
	if !ok || !app_workbench_activate_view(app, rt, view_id) {
		set_error(app, "Could not activate this workbench view.")
		return false
	}
	if view == .Git_History {
		if !app.backend.state.git.available && !app.backend.state.git.loading {
			git_defer_refresh(app, rt)
		}
	}
	alicorn.invalidate_root(rt, "Scratchpad Git workbench view selected")
	return true
}

git_workbench_open_beside :: proc(app: ^App, rt: ^alicorn.Runtime, view: Workbench_Content_Kind) -> bool {
	if app == nil || rt == nil || view == .Document { return false }
	if app.workspace_search_mode && !workspace_search_deactivate(app, rt) { return false }
	kind := Workbench_View_Kind.History if view == .Git_History else Workbench_View_Kind.Diff
	if !app_workbench_open_kind_beside(app, rt, kind) {
		set_error(app, "Could not open this workbench view beside the current pane.")
		return false
	}
	if view == .Git_History {
		if !app.backend.state.git.available && !app.backend.state.git.loading {
			git_defer_refresh(app, rt)
		}
	}
	alicorn.invalidate_root(rt, "Scratchpad opened a workbench view beside the current view")
	return true
}

git_open_diff :: proc(app: ^App, rt: ^alicorn.Runtime, kind, path, revision: string, untracked := false, beside := false) {
	if app == nil || rt == nil { return }
	if beside {
		if !git_workbench_open_beside(app, rt, .Git_Diff) { return }
	} else {
		if !git_workbench_select(app, rt, .Git_Diff) { return }
	}
	active_view, active_found := app_workbench_active_view(app)
	if !active_found || active_view.kind != .Diff { return }
	if app.git_diff_scroll_owner != 0 {
		_ = alicorn.scroll_region_set_offset(rt, app.git_diff_scroll_owner, 0, "Scratchpad opened a new Git diff")
	}
	git_diff_clear(app)
	app.git_diff_untracked = untracked
	response := bridge.backend_command(&app.backend, "git_diff_request", path=path,
		git_kind=kind, git_revision=revision, git_untracked=untracked)
	if !response.ok { set_error(app, response.message) }
	bridge.backend_command_result_destroy(&response, context.allocator)
	alicorn.invalidate_root(rt, "Scratchpad Git diff requested")
}

git_defer_refresh :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if !frame_deferred_action_schedule(app, .Git_Refresh) {
		set_error(app, "Could not queue the Git refresh until the current view finishes rendering.")
		alicorn.invalidate_root(rt, "Scratchpad could not queue a Git refresh")
	}
}

git_refresh :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil { return }
	response := bridge.backend_command(&app.backend, "git_refresh")
	if !response.ok { set_error(app, response.message) }
	bridge.backend_command_result_destroy(&response, context.allocator)
	alicorn.invalidate_root(rt, "Scratchpad Git state refreshed")
}

git_defer_select_commit :: proc(app: ^App, rt: ^alicorn.Runtime, hash: string) {
	if !frame_deferred_action_schedule(app, .Git_Select_Commit, value=hash) {
		set_error(app, "Could not queue the selected Git commit.")
		alicorn.invalidate_root(rt, "Scratchpad could not queue Git commit selection")
	}
}

git_defer_workbench_open_beside :: proc(
	app: ^App,
	rt: ^alicorn.Runtime,
	view: Workbench_Content_Kind,
) {
	if !frame_deferred_action_schedule(app, .Workbench_Open_Beside,
		workbench_content_kind=view) {
		set_error(app, "Could not queue the pane split until the current view finishes rendering.")
		alicorn.invalidate_root(rt, "Scratchpad could not queue a pane split")
	}
}

git_defer_open_diff :: proc(
	app: ^App,
	rt: ^alicorn.Runtime,
	kind, path, revision: string,
	untracked := false,
	beside := false,
) -> bool {
	if !frame_deferred_action_schedule(app, .Git_Open_Diff, value=revision,
		document_id=app_workbench_repository_identity(app),
		path=path, git_kind=kind, git_untracked=untracked, git_beside=beside) {
		set_error(app, "Could not queue the Git diff until the current view finishes rendering.")
		alicorn.invalidate_root(rt, "Scratchpad could not queue a Git diff")
		return false
	}
	return true
}

git_deferred_diff_matches_repository :: proc(app: ^App, captured_repository: string) -> bool {
	return app != nil && captured_repository != "" && captured_repository == app_workbench_repository_identity(app)
}

git_select_commit :: proc(app: ^App, rt: ^alicorn.Runtime, hash: string) {
	if app == nil || rt == nil || hash == "" { return }
	found := false
	for commit in app.backend.state.git.commits {
		if commit.hash == hash { found = true; break }
	}
	if app.git_selected_commit == hash {
		if !found {
			response := bridge.backend_command(&app.backend, "git_history_request", git_revision=hash)
			if !response.ok { set_error(app, response.message) }
			bridge.backend_command_result_destroy(&response, context.allocator)
		}
		return
	}
	if len(app.git_selected_commit) > 0 { delete(app.git_selected_commit, context.allocator) }
	app.git_selected_commit, _ = strings.clone(hash, context.allocator)
	if !found {
		response := bridge.backend_command(&app.backend, "git_history_request", git_revision=hash)
		if !response.ok { set_error(app, response.message) }
		bridge.backend_command_result_destroy(&response, context.allocator)
	}
	response := bridge.backend_command(&app.backend, "git_detail_request", git_revision=hash)
	if !response.ok { set_error(app, response.message) }
	bridge.backend_command_result_destroy(&response, context.allocator)
	alicorn.invalidate_root(rt, "Scratchpad Git commit selected")
}

git_history_handle_key :: proc(app: ^App, rt: ^alicorn.Runtime, key: alicorn.Application_Key) -> bool {
	if app == nil || rt == nil { return false }
	#partial switch key {
	case .Up, .Down, .Page_Up, .Page_Down:
	case:
		return false
	}
	focused := alicorn.focused_node(rt)
	if focused == 0 || focused == app.git_history_filter_node || app.git_history_list_node == 0 {
		return false
	}
	list := alicorn.scroll_region_state(rt, app.git_history_list_node)
	if list.id == 0 { return false }
	visible := make([dynamic]int, 0, len(app.backend.state.git.commits), allocator=context.temp_allocator)
	query, _ := strings.to_lower(app.git_history_filter, allocator=context.temp_allocator)
	focused_position := -1
	selected_position := -1
	for commit, index in app.backend.state.git.commits {
		if !git_history_commit_matches(commit, query) { continue }
		if commit.hash == app.git_selected_commit { selected_position = len(visible) }
		if focused != app.git_history_list_node {
			row_id, found := alicorn.node_by_key(rt, alicorn.key_string(fmt.tprintf("git-commit-%s", commit.hash)), .Button)
			if found && row_id == focused { focused_position = len(visible) }
		}
		append(&visible, index)
	}
	if focused != app.git_history_list_node && focused_position < 0 { return false }
	if len(visible) == 0 { return false }
	position := selected_position
	if focused_position >= 0 { position = focused_position }
	delta := 0
	#partial switch key {
	case .Up: delta = -1
	case .Down: delta = 1
	case .Page_Up: delta = -max(1, int(list.viewport_height/52)-1)
	case .Page_Down: delta = max(1, int(list.viewport_height/52)-1)
	}
	if position < 0 {
		position = 0
		if delta < 0 { position = len(visible)-1 }
	} else {
		position = clamp(position+delta, 0, len(visible)-1)
	}
	commit := app.backend.state.git.commits[visible[position]]
	git_select_commit(app, rt, commit.hash)
	_ = alicorn.virtual_list_ensure_visible(rt, list.id, position, "keyboard-selected Git commit")
	_ = alicorn.focus(rt, list.id)
	return true
}

git_diff_sync :: proc(app: ^App) {
	if app == nil || !app.backend.state.git.diff_ready ||
	   app.backend.state.git.diff_generation == 0 ||
	   app.backend.state.git.diff_generation == app.git_diff_loaded_generation { return }
	response := bridge.backend_command(&app.backend, "git_read_diff",
		git_diff_generation=app.backend.state.git.diff_generation,
		read_latest_after=false, allocator=context.allocator)
	if response.ok {
		if len(app.git_diff_text) > 0 { delete(app.git_diff_text, context.allocator) }
		app.git_diff_text = ""
		if len(response.git_diff.text) > 0 {
			app.git_diff_text, _ = strings.clone(response.git_diff.text, context.allocator)
		}
		git_diff_reindex(app)
		app.git_diff_loaded_generation = app.backend.state.git.diff_generation
	} else if response.code != "stale_git_diff" {
		set_error(app, response.message)
	}
	bridge.backend_command_result_destroy(&response, context.allocator)
}

git_diff_parse_hunk_start :: proc(line: string, marker: u8) -> (value: int, ok: bool) {
	for index := 0; index < len(line); index += 1 {
		if line[index] != marker { continue }
		index += 1
		if index >= len(line) || line[index] < '0' || line[index] > '9' { return 0, false }
		for index < len(line) && line[index] >= '0' && line[index] <= '9' {
			value = value*10 + int(line[index]-'0')
			index += 1
		}
		return value, true
	}
	return 0, false
}

git_diff_reindex :: proc(app: ^App) {
	if app == nil { return }
	clear(&app.git_diff_lines)
	clear(&app.git_diff_hunks)
	if app.git_diff_lines == nil { app.git_diff_lines = make([dynamic]Git_Diff_Line, 0, 256, allocator=context.allocator) }
	if app.git_diff_hunks == nil { app.git_diff_hunks = make([dynamic]int, 0, 16, allocator=context.allocator) }
	old_line, new_line := 0, 0
	position := 0
	max_line_bytes := 0
	for position < len(app.git_diff_text) {
		start := position
		for position < len(app.git_diff_text) && app.git_diff_text[position] != '\n' { position += 1 }
		end := position
		line := app.git_diff_text[start:end]
		max_line_bytes = max(max_line_bytes, len(line))
		kind := Git_Diff_Line_Kind.Meta
		line_old, line_new := 0, 0
		if strings.has_prefix(line, "@@") {
			kind = .Hunk
			old_line, _ = git_diff_parse_hunk_start(line, '-')
			new_line, _ = git_diff_parse_hunk_start(line, '+')
			append(&app.git_diff_hunks, len(app.git_diff_lines))
		} else if len(line) > 0 {
			switch line[0] {
			case '+':
				if !strings.has_prefix(line, "+++") {
					kind, line_new = .Addition, new_line
					new_line += 1
				}
			case '-':
				if !strings.has_prefix(line, "---") {
					kind, line_old = .Deletion, old_line
					old_line += 1
				}
			case ' ':
				kind, line_old, line_new = .Context, old_line, new_line
				old_line += 1
				new_line += 1
			}
		}
		append(&app.git_diff_lines, Git_Diff_Line{start=start, end=end,
			old_line=line_old, new_line=line_new, kind=kind})
		if position < len(app.git_diff_text) { position += 1 }
	}
	app.git_diff_content_width = min(max(720, f32(max_line_bytes)*8+152), 8192)
	app.git_diff_selected_hunk = min(app.git_diff_selected_hunk, max(len(app.git_diff_hunks)-1, 0))
}

git_diff_navigate_hunk :: proc(app: ^App, rt: ^alicorn.Runtime, delta: int) {
	if app == nil || rt == nil || len(app.git_diff_hunks) == 0 { return }
	app.git_diff_selected_hunk = clamp(app.git_diff_selected_hunk+delta, 0, len(app.git_diff_hunks)-1)
	if app.git_diff_scroll_owner != 0 {
		_ = alicorn.virtual_list_ensure_visible(rt, app.git_diff_scroll_owner,
			app.git_diff_hunks[app.git_diff_selected_hunk], "navigate Git diff hunk")
	}
	alicorn.invalidate_root(rt, "Scratchpad navigated to a Git diff hunk")
}

git_sidebar_build :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime) {
	if app == nil || ui == nil || rt == nil { return }
	state := &app.backend.state.git
	if gui.row(ui, label="git-sidebar-heading", height=34, gap=8, align=.Center) {
		gui.text(ui, "Source Control", style=alicorn.layout_style(.Row, grow=1),
			text_style=alicorn.Text_Style{font_size=17, font_weight=alicorn.FONT_WEIGHT_SEMIBOLD})
		if gui.button(ui, "↻", key="git-refresh", width=32, height=28, variant=.Toolbar) {
			git_defer_refresh(app, rt)
		}
		if gui.button(ui, "History", key="git-open-history", width=66, height=28, variant=.Toolbar) {
			git_workbench_select(app, rt, .Git_History)
		}
		if gui.button(ui, "↗", key="git-open-history-beside", width=30, height=28, variant=.Toolbar) {
			git_defer_workbench_open_beside(app, rt, .Git_History)
		}
	}
	if !app.backend.state.has_workspace {
		gui.text(ui, "Open a workspace to use Git.")
		return
	}
	if !state.available {
		if state.loading { gui.text(ui, "Reading repository status…") }
		if state.error != "" { gui.text(ui, state.error) }
		else if !state.loading { gui.text(ui, "No Git repository detected in this workspace.") }
		return
	}
	if state.loading { gui.text(ui, "Refreshing repository status…", text_style=alicorn.Text_Style{font_size=11}) }
	branch := state.branch
	if branch == "" { branch = "Detached HEAD" }
	if state.ahead != 0 || state.behind != 0 {
		branch = fmt.tprintf("%s · ↑%d ↓%d", branch, state.ahead, state.behind)
	}
	gui.text(ui, branch, text_style=alicorn.Text_Style{font_size=13, font_weight=alicorn.FONT_WEIGHT_MEDIUM, overflow=.Ellipsis})
	if state.upstream != "" { gui.text(ui, state.upstream, text_style=alicorn.Text_Style{font_size=11, overflow=.Ellipsis}) }
	if state.error != "" { gui.text(ui, state.error, text_style=alicorn.Text_Style{font_size=12, overflow=.Wrap}) }
	staged_count, unstaged_count := 0, 0
	for file in state.files {
		if file.staged { staged_count += 1 }
		if file.unstaged { unstaged_count += 1 }
	}
	if app.git_commit_clear_pending && !state.loading {
		if state.error == "" && app.git_commit_message == app.git_commit_submitted_message {
			find_set_message(&app.git_commit_message, "")
			app.git_commit_message_node = 0
		}
		app.git_commit_clear_pending = false
		if len(app.git_commit_submitted_message) > 0 { delete(app.git_commit_submitted_message, context.allocator) }
		app.git_commit_submitted_message = ""
	}
	content_height := f32(180 + (staged_count+unstaged_count)*42)
	scroll := alicorn.scroll_region_begin(ui,
		key=alicorn.key_string("scratchpad-git-sidebar-scroll"),
		content_height=content_height, line_height=42,
		style=alicorn.layout_style(.Column, grow=1, clip=true),
		label="git-sidebar-scroll", axes=.Vertical, scrollbars=.Auto, focusable=true)
	alicorn.container_begin(ui, .Virtual_List,
		key=alicorn.key_string("scratchpad-git-sidebar-content"), label="git-sidebar-content",
		style=alicorn.layout_style(.Column, grow=1, padding=5, gap=4, clip=true),
		scroll_offset_y=scroll.offset_y)
	gui.text(ui, fmt.tprintf("Staged · %d", staged_count), text_style=alicorn.Text_Style{font_size=12, font_weight=alicorn.FONT_WEIGHT_SEMIBOLD})
	for file in state.files {
		if !file.staged { continue }
		git_file_row_build(app, ui, rt, file, staged=true)
	}
	gui.text(ui, fmt.tprintf("Changes · %d", unstaged_count), text_style=alicorn.Text_Style{font_size=12, font_weight=alicorn.FONT_WEIGHT_SEMIBOLD})
	for file in state.files {
		if !file.unstaged { continue }
		git_file_row_build(app, ui, rt, file, staged=false)
	}
	if staged_count == 0 && unstaged_count == 0 { gui.text(ui, "Working tree clean.") }
	gui.text(ui, "Commit message", text_style=alicorn.Text_Style{font_size=11, font_weight=alicorn.FONT_WEIGHT_MEDIUM})
	app.git_commit_message_node = alicorn.text_field(ui, app.git_commit_message,
		key=alicorn.key_string("scratchpad-git-commit-message"),
		style=alicorn.layout_style(.Row, grow=1, height=34))
	if gui.button(ui, "Commit Staged Changes", key="git-commit-staged",
		width=-1, height=34, state=alicorn.Button_State{disabled=staged_count == 0 || state.loading}, variant=.Primary) {
		if !frame_deferred_action_schedule(app, .Git_Commit, value=app.git_commit_message) {
			set_error(app, "Could not queue the Git commit until the current view finishes rendering.")
			alicorn.invalidate_root(rt, "Scratchpad could not queue a Git commit")
		}
	}
	alicorn.container_end(ui)
	alicorn.scroll_region_end(ui)
}

git_file_row_build :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime, file: bridge.Git_File, staged: bool) {
	key := fmt.tprintf("git-file-%s-%s", "staged" if staged else "working", file.path)
	display_path := file.path
	if file.original_path != "" { display_path = fmt.tprintf("%s → %s", file.original_path, file.path) }
	if gui.row(ui, label=key, height=36, gap=3, align=.Center) {
		gui.text(ui, display_path, key=fmt.tprintf("%s-path", key), style=alicorn.layout_style(.Row, grow=1),
			text_style=alicorn.Text_Style{font_size=12, overflow=.Ellipsis})
		if gui.button(ui, "Diff", key=fmt.tprintf("%s-diff", key), width=42, height=28, variant=.Toolbar) {
			kind := "staged" if staged else "working"
			git_defer_open_diff(app, rt, kind, file.path, "", untracked=!staged && file.untracked)
		}
		if staged {
			if gui.button(ui, "−", key=fmt.tprintf("%s-unstage", key), width=28, height=28, state=alicorn.Button_State{disabled=app.backend.state.git.loading}, variant=.Toolbar) {
				git_defer_path_mutation(app, rt, "git_unstage", file.path, file.original_path)
			}
		} else if gui.button(ui, "+", key=fmt.tprintf("%s-stage", key), width=28, height=28, state=alicorn.Button_State{disabled=app.backend.state.git.loading}, variant=.Toolbar) {
				git_defer_path_mutation(app, rt, "git_stage", file.path, file.original_path)
		}
	}
}

git_defer_path_mutation :: proc(app: ^App, rt: ^alicorn.Runtime, command, path, original_path: string) {
	if !frame_deferred_action_schedule(app, .Git_Path_Mutation, path=path,
		git_command=command, git_original_path=original_path) {
		set_error(app, "Could not queue the Git path update until the current view finishes rendering.")
		alicorn.invalidate_root(rt, "Scratchpad could not queue a Git path update")
	}
}

git_path_mutation :: proc(app: ^App, rt: ^alicorn.Runtime, command, path, original_path: string) {
	if app == nil || rt == nil { return }
	response := bridge.backend_command(&app.backend, command, path=path, git_original_path=original_path)
	if !response.ok { set_error(app, response.message) }
	bridge.backend_command_result_destroy(&response, context.allocator)
	alicorn.invalidate_root(rt, "Scratchpad Git path updated")
}

git_commit :: proc(app: ^App, rt: ^alicorn.Runtime, message: string) {
	if app == nil || rt == nil { return }
	response := bridge.backend_command(&app.backend, "git_commit", git_message=message)
	if !response.ok { set_error(app, response.message) }
	else {
		if len(app.git_commit_submitted_message) > 0 { delete(app.git_commit_submitted_message, context.allocator) }
		app.git_commit_submitted_message, _ = strings.clone(message, context.allocator)
		app.git_commit_clear_pending = true
	}
	bridge.backend_command_result_destroy(&response, context.allocator)
	alicorn.invalidate_root(rt, "Scratchpad Git commit submitted")
}

git_history_build :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime, dpi_scale, available_width: f32) {
	state := &app.backend.state.git
	if gui.row(ui, label="git-history-toolbar", height=42, gap=10, align=.Center) {
		label := "Repository History"
		if state.branch != "" { label = fmt.tprintf("%s · History", state.branch) }
		gui.text(ui, label, style=alicorn.layout_style(.Row, grow=1), text_style=alicorn.Text_Style{font_size=20, font_weight=alicorn.FONT_WEIGHT_SEMIBOLD, overflow=.Ellipsis})
		if gui.button(ui, "Refresh", key="git-history-refresh", width=76, height=30, variant=.Toolbar) {
			git_defer_refresh(app, rt)
		}
		if gui.button(ui, "Open Beside", key="git-history-open-beside", width=100, height=30, variant=.Toolbar) {
			git_defer_workbench_open_beside(app, rt, .Git_History)
		}
	}
	gui.text(ui, "Filter commits by subject, author, hash, or ref", text_style=alicorn.Text_Style{font_size=11})
	app.git_history_filter_node = alicorn.text_field(ui, app.git_history_filter,
		key=alicorn.key_string("git-history-filter"), style=alicorn.layout_style(.Row, height=32))
	if state.loading && !state.available { gui.text(ui, "Reading recent history…"); return }
	if !state.available {
		message := state.error
		if message == "" { message = "No Git repository is open." }
		gui.text(ui, message)
		return
	}
	if state.loading { gui.text(ui, "Refreshing history…", text_style=alicorn.Text_Style{font_size=11}) }
	if state.history_loading { gui.text(ui, "Loading history at selected ref…", text_style=alicorn.Text_Style{font_size=11}) }
	if state.history_error != "" { gui.text(ui, state.history_error, text_style=alicorn.Text_Style{font_size=11, overflow=.Wrap}) }
	if len(state.commits) == 0 { gui.text(ui, "This repository has no commits yet."); return }
	visible := make([dynamic]int, 0, len(state.commits), allocator=context.temp_allocator)
	query, _ := strings.to_lower(app.git_history_filter, allocator=context.temp_allocator)
	for commit, index in state.commits {
		if git_history_commit_matches(commit, query) { append(&visible, index) }
	}
	if !gui.row(ui, label="git-history-content", height=-1, grow=1, gap=6, align=.Stretch) { return }
	refs_initial := app.git_history_refs_split_position
	if refs_initial < 112 || refs_initial > available_width-432 { refs_initial = min(176, max(112, available_width*0.22)) }
	refs_split := alicorn.split_begin(ui,
		key=alicorn.key_string("scratchpad-git-history-refs-split"), axis=.Horizontal,
		initial=refs_initial, min_first=104, min_second=420,
		style=alicorn.layout_style(.Row, grow=1, gap=2, clip=true), label="Git history refs and commit workspace")
	app.git_history_refs_split_position = refs_split.position
	alicorn.split_first_begin(ui, refs_split)
	alicorn.container_begin(ui, .Container, label="git-history-refs-panel",
		style=alicorn.layout_style(.Column, grow=1, padding=5, gap=4, clip=true))
	gui.text(ui, fmt.tprintf("Refs · %d", len(state.refs)), style=alicorn.layout_style(.Row, height=26), text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_SEMIBOLD})
	refs := alicorn.virtual_list_begin(ui, len(state.refs), 30,
		key=alicorn.key_string("git-history-refs"),
		style=alicorn.layout_style(grow=1, clip=true), label="Repository branches, remotes, and tags")
	for index := refs.first; index < refs.last; index += 1 {
		ref := state.refs[index]
		prefix := "tag"
		if ref.kind == "branch" { prefix = "branch" }
		if ref.kind == "remote" { prefix = "remote" }
		label := fmt.tprintf("%s  %s", prefix, ref.name)
		if ref.head { label = fmt.tprintf("%s  · HEAD", label) }
		if gui.button(ui, label, key=fmt.tprintf("git-ref-%s", ref.full_name), width=-1, height=28,
			state=alicorn.Button_State{selected=ref.target != "" && app.git_selected_commit == ref.target,
				disabled=ref.target == ""},
			content_style=alicorn.button_content_style(.Start, padding_x=5), variant=.Quiet,
			text_style=alicorn.Text_Style{font_size=11, overflow=.Ellipsis}) {
			if app.git_history_filter != "" { find_set_message(&app.git_history_filter, "") }
			git_defer_select_commit(app, rt, ref.target)
		}
	}
	alicorn.virtual_list_end(ui, refs)
	alicorn.container_end(ui)
	alicorn.split_first_end(ui, refs_split)
	alicorn.split_divider(ui, refs_split)
	alicorn.split_second_begin(ui, refs_split)
	detail_initial := app.git_history_detail_split_position
	if detail_initial < 220 || detail_initial > available_width-refs_split.position-220 {
		detail_initial = max(240, (available_width-refs_split.position)*0.48)
	}
	detail_split := alicorn.split_begin(ui,
		key=alicorn.key_string("scratchpad-git-history-detail-split"), axis=.Horizontal,
		initial=detail_initial, min_first=200, min_second=220,
		style=alicorn.layout_style(.Row, grow=1, gap=2, clip=true), label="Git history commits and selected commit detail")
	app.git_history_detail_split_position = detail_split.position
	alicorn.split_first_begin(ui, detail_split)
	alicorn.container_begin(ui, .Container, label="git-history-commit-panel",
		style=alicorn.layout_style(.Column, grow=1, padding=5, gap=4, clip=true))
	if gui.row(ui, label="git-history-commit-heading", height=26, align=.Center) {
		gui.text(ui, fmt.tprintf("Commits · %d of %d", len(visible), len(state.commits)), style=alicorn.layout_style(.Row, grow=1), text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_SEMIBOLD})
		gui.text(ui, "DAG", style=alicorn.layout_style(.Row, width=72, align=.Center), text_style=alicorn.Text_Style{font_size=10, font_weight=alicorn.FONT_WEIGHT_MEDIUM})
	}
	commits := alicorn.virtual_list_begin(ui, len(visible), 52,
		key=alicorn.key_string("git-history-list"),
		style=alicorn.layout_style(grow=1, padding=4, gap=2, clip=true),
		label="Repository commits", focusable=true)
	app.git_history_list_node = commits.scroll.id
	app.git_history_graph_first = commits.first
	app.git_history_graph_last = commits.last
	if len(visible) > 0 {
		viewport_height := commits.scroll.viewport_height
		alicorn.container_begin(ui, .Container, label="git-history-graph-and-rows",
			style=alicorn.layout_style(.Row, height=viewport_height, clip=true))
		app.git_history_graph_node = alicorn.gpu_geometry_surface(ui,
			"scratchpad-git-history-dag",
			alicorn.layout_style(.Row, width=72, height=viewport_height, clip=true),
			dpi_scale)
		alicorn.container_begin(ui, .Container, label="git-history-commit-rows",
			style=alicorn.layout_style(.Column, grow=1, height=viewport_height, clip=true))
	}
	for position := commits.first; position < commits.last; position += 1 {
		index := visible[position]
		commit := state.commits[index]
		marker := "●"
		if len(commit.parents) == 0 { marker = "○" }
		if len(commit.parents) > 1 { marker = "⑂" }
		label := fmt.tprintf("%s  %s  %s", marker, commit.hash[:min(7, len(commit.hash))], commit.subject)
		if commit.refs != "" { label = fmt.tprintf("%s  ·  %s", label, commit.refs) }
		if gui.button(ui, label, key=fmt.tprintf("git-commit-%s", commit.hash), width=-1, height=48,
			state=alicorn.Button_State{selected=app.git_selected_commit == commit.hash},
			content_style=alicorn.button_content_style(.Start, padding_x=8), variant=.Quiet,
			text_style=alicorn.Text_Style{font_size=12, overflow=.Ellipsis}) {
			git_defer_select_commit(app, rt, commit.hash)
			_ = alicorn.virtual_list_ensure_visible(rt, commits.scroll.id, position, "selected Git commit")
		}
	}
	if len(visible) > 0 {
		alicorn.container_end(ui)
		alicorn.container_end(ui)
	}
	if len(visible) == 0 { gui.text(ui, "No commits match this filter.") }
	alicorn.virtual_list_end(ui, commits)
	alicorn.container_end(ui)
	alicorn.split_first_end(ui, detail_split)
	alicorn.split_divider(ui, detail_split)
	alicorn.split_second_begin(ui, detail_split)
	alicorn.container_begin(ui, .Container, label="git-history-detail-panel",
		style=alicorn.layout_style(.Column, grow=1, min_width=220, padding=10, gap=6, clip=true))
	if app.git_selected_commit == "" {
		gui.text(ui, "Select a commit to inspect its metadata and changed files.")
	} else if state.detail_loading {
		gui.text(ui, "Loading commit details…")
	} else if state.detail_error != "" {
		gui.text(ui, state.detail_error)
	} else if state.detail_ready && state.detail.hash == app.git_selected_commit {
		detail := state.detail
		gui.text(ui, detail.subject, style=alicorn.layout_style(.Row, height=32), text_style=alicorn.Text_Style{font_size=18, font_weight=alicorn.FONT_WEIGHT_SEMIBOLD, overflow=.Ellipsis})
		gui.text(ui, fmt.tprintf("%s\n%s <%s>\n%s\nParents: %d", detail.hash, detail.author, detail.email, detail.date, len(detail.parents)),
			style=alicorn.layout_style(.Column, height=72, clip=true), text_style=alicorn.Text_Style{font_size=12, overflow=.Wrap})
		if detail.body != "" { gui.text(ui, detail.body, style=alicorn.layout_style(.Column, height=64, clip=true), text_style=alicorn.Text_Style{font_size=12, overflow=.Wrap}) }
		if gui.button(ui, "Open Full Diff Beside", key="git-commit-full-diff", height=32, variant=.Toolbar) {
			git_defer_open_diff(app, rt, "commit", "", detail.hash, beside=true)
		}
		gui.text(ui, fmt.tprintf("Changed Files · %d", len(detail.files)), style=alicorn.layout_style(.Row, height=24), text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_SEMIBOLD})
		if len(detail.files) > 0 {
			files := alicorn.virtual_list_begin(ui, len(detail.files), 34,
				key=alicorn.key_string("git-commit-changed-files"),
				style=alicorn.layout_style(grow=1, clip=true), label="Commit changed files")
			for index := files.first; index < files.last; index += 1 {
				file := detail.files[index]
				stats := "binary"
				if file.additions >= 0 && file.deletions >= 0 { stats = fmt.tprintf("+%d −%d", file.additions, file.deletions) }
				if gui.button(ui, fmt.tprintf("%s  %s  %s", file.status, stats, file.path), key=fmt.tprintf("git-commit-file-%d-%s", index, file.path),
					width=-1, height=32, content_style=alicorn.button_content_style(.Start, padding_x=6), variant=.Quiet,
					text_style=alicorn.Text_Style{font_size=12, overflow=.Ellipsis}) {
					git_defer_open_diff(app, rt, "commit", file.path, detail.hash, beside=true)
				}
			}
			alicorn.virtual_list_end(ui, files)
		}
	} else {
		gui.text(ui, "Loading commit details…")
	}
	alicorn.container_end(ui)
	alicorn.split_second_end(ui, detail_split)
	alicorn.split_end(ui, detail_split)
	alicorn.split_second_end(ui, refs_split)
	alicorn.split_end(ui, refs_split)
	alicorn.container_end(ui)
}

git_history_finalize_geometry :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil { return }
	if app.git_history_graph_node == 0 {
		app.git_history_graph_payload_node = 0
		app.git_history_graph_generation = 0
		app.git_history_graph_first = 0
		app.git_history_graph_last = 0
		app.git_history_graph_payload_first = 0
		app.git_history_graph_payload_last = 0
		app.git_history_graph_visible_count = 0
		return
	}
	ctx, ok := alicorn.gpu_surface_context(rt, app.git_history_graph_node)
	if !ok {
		app.git_history_graph_payload_node = 0
		return
	}
	state := &app.backend.state.git
	query, _ := strings.to_lower(app.git_history_filter, allocator=context.temp_allocator)
	visible := make([dynamic]int, 0, len(state.commits), allocator=context.temp_allocator)
	selected_index := -1
	for commit, index in state.commits {
		if commit.hash == app.git_selected_commit { selected_index = index }
		if git_history_commit_matches(commit, query) { append(&visible, index) }
	}
	width_milli := int(ctx.logical_bounds.w*1000)
	height_milli := int(ctx.logical_bounds.h*1000)
	filter_changed := app.git_history_graph_filter != app.git_history_filter
	if app.git_history_graph_payload_node == app.git_history_graph_node &&
	   app.git_history_graph_generation == state.generation &&
	   app.git_history_graph_payload_first == app.git_history_graph_first &&
	   app.git_history_graph_payload_last == app.git_history_graph_last &&
	   app.git_history_graph_visible_count == len(visible) &&
	   app.git_history_graph_width_milli == width_milli &&
	   app.git_history_graph_height_milli == height_milli &&
	   app.git_history_graph_selected_index == selected_index &&
	   !filter_changed {
		return
	}
	layout := git_dag_layout(state.commits[:])
	defer git_dag_destroy(&layout)
	segments := make([dynamic]alicorn.GPU_Surface_Line_Segment, 0, 128, allocator=context.temp_allocator)
	circles := make([dynamic]alicorn.GPU_Surface_Filled_Circle, 0, 64, allocator=context.temp_allocator)
	git_dag_build_geometry(layout, state.commits[:], visible[:], app.git_history_graph_first,
		app.git_history_graph_last, 52, ctx.logical_bounds.w, selected_index, query != "", &segments, &circles)
	if alicorn.gpu_surface_update_geometry(rt, app.git_history_graph_node, segments[:], circles[:]) {
		app.git_history_graph_payload_node = app.git_history_graph_node
		app.git_history_graph_generation = state.generation
		app.git_history_graph_payload_first = app.git_history_graph_first
		app.git_history_graph_payload_last = app.git_history_graph_last
		app.git_history_graph_visible_count = len(visible)
		app.git_history_graph_width_milli = width_milli
		app.git_history_graph_height_milli = height_milli
		app.git_history_graph_selected_index = selected_index
		if filter_changed {
			if len(app.git_history_graph_filter) > 0 { delete(app.git_history_graph_filter, context.allocator) }
			app.git_history_graph_filter, _ = strings.clone(app.git_history_filter, context.allocator)
		}
	}
}

git_history_commit_matches :: proc(commit: bridge.Git_Commit, query: string) -> bool {
	if query == "" { return true }
	values := [4]string{commit.hash, commit.author, commit.subject, commit.refs}
	for value in values {
		lower, _ := strings.to_lower(value, allocator=context.temp_allocator)
		if strings.contains(lower, query) { return true }
	}
	return false
}

git_diff_build :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime) {
	state := &app.backend.state.git
	if gui.row(ui, label="git-diff-toolbar", height=42, gap=10, align=.Center) {
		label := "Working Tree Diff"
		if state.diff_kind == "staged" { label = "Staged Diff" }
		if state.diff_kind == "commit" {
			revision := state.diff_revision
			if len(revision) > 10 { revision = revision[:10] }
			label = fmt.tprintf("Commit · %s", revision)
		}
		if state.diff_path != "" { label = fmt.tprintf("%s · %s", label, state.diff_path) }
		gui.text(ui, label, style=alicorn.layout_style(.Row, grow=1), text_style=alicorn.Text_Style{font_size=20, font_weight=alicorn.FONT_WEIGHT_SEMIBOLD, overflow=.Ellipsis})
		if gui.button(ui, "‹", key="git-diff-previous-hunk", width=30, height=30,
			state=alicorn.Button_State{disabled=len(app.git_diff_hunks) == 0 || app.git_diff_selected_hunk == 0}, variant=.Toolbar) {
			git_diff_navigate_hunk(app, rt, -1)
		}
		hunk_label := "No hunks"
		if len(app.git_diff_hunks) > 0 { hunk_label = fmt.tprintf("%d / %d", app.git_diff_selected_hunk+1, len(app.git_diff_hunks)) }
		gui.text(ui, hunk_label, style=alicorn.layout_style(.Row, width=68, align=.Center), text_style=alicorn.Text_Style{font_size=11})
		if gui.button(ui, "›", key="git-diff-next-hunk", width=30, height=30,
			state=alicorn.Button_State{disabled=len(app.git_diff_hunks) == 0 || app.git_diff_selected_hunk >= len(app.git_diff_hunks)-1}, variant=.Toolbar) {
			git_diff_navigate_hunk(app, rt, 1)
		}
		if gui.button(ui, "Open Beside", key="git-diff-open-beside", width=100, height=30, variant=.Toolbar) {
			git_defer_open_diff(app, rt, state.diff_kind, state.diff_path, state.diff_revision,
				untracked=app.git_diff_untracked, beside=true)
		}
	}
	if !state.available {
		if state.loading { gui.text(ui, "Opening repository…") }
		else if state.error != "" { gui.text(ui, state.error) }
		else { gui.text(ui, "No Git repository is open.") }
		return
	}
	if state.diff_loading { gui.text(ui, "Preparing read-only diff…"); return }
	if state.diff_error != "" { gui.text(ui, state.diff_error); return }
	if app.git_diff_text == "" { gui.text(ui, "No differences for this selection."); return }
	lines := alicorn.virtual_list_begin(ui, len(app.git_diff_lines), 21,
		key=alicorn.key_string("git-diff-content"),
		style=alicorn.layout_style(grow=1, padding=8, clip=true),
		content_width=app.git_diff_content_width, line_width=32,
		label="Read-only Git diff", axes=.Both, axis_behavior=.Auto_Lock)
	app.git_diff_scroll_owner = lines.scroll.id
	for index := lines.first; index < lines.last; index += 1 {
		if index < 0 || index >= len(app.git_diff_lines) { continue }
		line := app.git_diff_lines[index]
		text := app.git_diff_text[line.start:line.end]
		if line.kind == .Meta || line.kind == .Hunk {
			color := alicorn.style_color(ui, .Muted_Text)
			if line.kind == .Hunk { color = alicorn.style_color(ui, .Accent) }
			gui.text(ui, text, key=fmt.tprintf("git-diff-line-%d", index),
				style=alicorn.layout_style(.Row, width=app.git_diff_content_width, height=21, padding=3),
				color=color, font=.Monospace,
				text_style=alicorn.Text_Style{font_size=12, overflow=.Ellipsis})
			continue
		}
		background := alicorn.NO_BACKGROUND_COLOR
		text_color := alicorn.style_color(ui, .Text)
		marker := " "
		if line.kind == .Addition {
			background = alicorn.style_color(ui, .Success)
			background.a = 0.10
			text_color = alicorn.style_color(ui, .Success)
			marker = "+"
		} else if line.kind == .Deletion {
			background = alicorn.style_color(ui, .Danger)
			background.a = 0.10
			text_color = alicorn.style_color(ui, .Danger)
			marker = "−"
		}
		alicorn.container_begin(ui, .Container, label="git-diff-readable-line",
			key=alicorn.key_u64(u64(index+1)),
			style=alicorn.layout_style(.Row, width=app.git_diff_content_width, height=21, align=.Center, clip=true),
			color=background)
		old_text, new_text := "", ""
		if line.old_line > 0 { old_text = fmt.tprintf("%d", line.old_line) }
		if line.new_line > 0 { new_text = fmt.tprintf("%d", line.new_line) }
		gui.text(ui, old_text, style=alicorn.layout_style(.Row, width=58, height=21, padding=3, align=.End),
			font=.Monospace, text_style=alicorn.Text_Style{font_size=11, overflow=.Ellipsis}, color=alicorn.style_color(ui, .Muted_Text))
		gui.text(ui, new_text, style=alicorn.layout_style(.Row, width=58, height=21, padding=3, align=.End),
			font=.Monospace, text_style=alicorn.Text_Style{font_size=11, overflow=.Ellipsis}, color=alicorn.style_color(ui, .Muted_Text))
		gui.text(ui, marker, style=alicorn.layout_style(.Row, width=24, height=21, align=.Center),
			font=.Monospace, text_style=alicorn.Text_Style{font_size=11}, color=text_color)
		gui.text(ui, text[1:], style=alicorn.layout_style(.Row, width=max(app.git_diff_content_width-140, 120), height=21),
			key=fmt.tprintf("git-diff-line-text-%d", index), font=.Monospace,
			text_style=alicorn.Text_Style{font_size=12, overflow=.Ellipsis}, color=text_color)
		alicorn.container_end(ui)
	}
	alicorn.virtual_list_end(ui, lines)
}
