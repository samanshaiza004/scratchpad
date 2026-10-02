package main

import "core:fmt"
import "core:os"
import "core:strings"
import alicorn "alicorn:runtime"
import bridge "./bridge"

FIND_QUERY_KEY :: "scratchpad-find-query"
WORKSPACE_SEARCH_QUERY_KEY :: "scratchpad-workspace-search-query"

find_capture_text_field :: proc(rt: ^alicorn.Runtime, node_id: alicorn.Node_ID, value: ^string) -> bool {
	if rt == nil || value == nil || node_id == 0 { return false }
	node, found := rt.nodes[node_id]
	if !found || !node.active || node.kind != .Text_Field || node.text == value^ { return false }
	copy, err := strings.clone(node.text, context.allocator)
	if err != nil { return false }
	if len(value^) > 0 { delete(value^, context.allocator) }
	value^ = copy
	return true
}

find_initial_previous_match :: proc(matches: []bridge.Current_Match, source_cursor: u64) -> int {
	for index := len(matches)-1; index >= 0; index -= 1 {
		match := matches[index]
		if match.start >= 0 && u64(match.start) < source_cursor { return index }
	}
	return len(matches)-1 if len(matches) > 0 else -1
}

find_set_message :: proc(value: ^string, message: string) {
	if value == nil { return }
	if len(value^) > 0 { delete(value^, context.allocator) }
	value^ = ""
	if len(message) > 0 { value^, _ = strings.clone(message, context.allocator) }
}

find_discard_saved_selection :: proc(app: ^App) {
	if app == nil { return }
	if len(app.find_restore_document_id) > 0 { delete(app.find_restore_document_id, context.allocator) }
	app.find_restore_document_id = ""
	app.find_restore_valid = false
	app.find_restore_pending = false
}

find_capture_editor_selection :: proc(app: ^App) {
	if app == nil || !app.backend.started { return }
	document, found := find_document(&app.backend.state, app.backend.state.active)
	if !found { return }
	view_index, view_ok := editor_view_ensure(&app.editor_views, document.id)
	if !view_ok { return }
	view := &app.editor_views[view_index]
	document_id, clone_error := strings.clone(document.id, context.allocator)
	if clone_error != nil { return }
	if len(app.find_restore_document_id) > 0 { delete(app.find_restore_document_id, context.allocator) }
	app.find_restore_document_id = document_id
	app.find_restore_anchor = view.selection_anchor
	app.find_restore_caret = view.caret_byte
	app.find_restore_anchor_affinity = view.anchor_affinity
	app.find_restore_caret_affinity = view.caret_affinity
	app.find_restore_valid = true
}

find_open_surface :: proc(app: ^App) {
	if app == nil { return }
	if !app.find_open { find_capture_editor_selection(app) }
	app.find_open = true
	app.find_focus_pending = true
	app.find_select_query_pending = true
	app.workspace_search_focus_pending = false
	app.editor_focus_pending = false
	if app.backend.started {
		if document, found := find_document(&app.backend.state, app.backend.state.active); found &&
		   app.find_presentation.document_id == document.id &&
		   app.find_presentation.editor_revision == document.editor_revision &&
		   app.find_presentation.query == app.find_query {
			if index := editor_view_find(app.editor_views[:], document.id); index >= 0 {
				app.find_presentation.active_match = find_initial_match(app.find_presentation.matches, app.editor_views[index].caret_byte)
				_ = find_apply_active_match(app, nil, false)
			}
		}
	}
}

find_close_surface :: proc(app: ^App) {
	if app == nil || !app.find_open { return }
	app.find_open = false
	app.find_query_node = 0
	app.find_replace_node = 0
	app.find_restore_pending = true
	app.editor_focus_pending = true
}

find_replace_current :: proc(app: ^App, rt: ^alicorn.Runtime) -> bool {
	if app == nil || rt == nil || !app.find_open || !app.backend.started { return false }
	if len(app.editor_edits) > 0 {
		find_set_message(&app.find_replace_message, "Wait for pending edits to finish.")
		alicorn.invalidate_root(rt, "Scratchpad deferred Find replacement until pending edits finish")
		return true
	}
	if editor_active_preedit(app) {
		find_set_message(&app.find_replace_message, "Finish or cancel text composition before replacing.")
		alicorn.invalidate_root(rt, "Scratchpad Find replacement refused during IME composition")
		return true
	}
	if len(app.find_replace_text) > int(bridge.MAX_EDIT_BYTES) {
		find_set_message(&app.find_replace_message, "Replacement exceeds the 128 KiB per-edit limit.")
		alicorn.invalidate_root(rt, "Scratchpad Find replacement exceeded the edit limit")
		return true
	}
	find_refresh_if_needed(app, rt)
	if len(app.find_presentation.matches) == 0 || app.find_presentation.active_match < 0 ||
	   app.find_presentation.active_match >= len(app.find_presentation.matches) {
		find_set_message(&app.find_replace_message, "No current match to replace.")
		alicorn.invalidate_root(rt, "Scratchpad Find replacement has no active match")
		return true
	}
	document, view, _, ready := active_editor_context(app)
	if !ready || view == nil || document.id != app.find_presentation.document_id ||
	   document.editor_revision != app.find_presentation.editor_revision ||
	   app.find_presentation.query != app.find_query {
		find_set_message(&app.find_replace_message, "Waiting for the current source window.")
		alicorn.invalidate_root(rt, "Scratchpad Find replacement waited for the exact source window")
		return true
	}
	match := app.find_presentation.matches[app.find_presentation.active_match]
	if match.start < 0 || match.end <= match.start || u64(match.end) > document.byte_length {
		find_set_message(&app.find_replace_message, "The active Find match has invalid source coordinates.")
		alicorn.invalidate_root(rt, "Scratchpad refused invalid Find source coordinates")
		return true
	}
	replacement, replacement_ok := find_replacement_bytes(app.find_replace_text)
	if !replacement_ok {
		find_set_message(&app.find_replace_message, "Could not prepare replacement text.")
		return true
	}
	response := bridge.backend_command(
		&app.backend,
		"find_replace_current",
		document_id=document.id,
		editor_revision=document.editor_revision,
		start_byte=u64(match.start),
		end_byte=u64(match.end),
		query=app.find_query,
		replacement=replacement,
		has_selection_state=true,
		before_anchor_byte=view.selection_anchor,
		before_cursor_byte=view.caret_byte,
	)
	if response.ok && response.edit.document_id == document.id && response.edit.editor_revision > 0 {
		view.authoritative_revision = response.edit.editor_revision
		view.optimistic_pending_edits = 0
		view.optimistic_line_delta = 0
		view.selection_anchor = response.edit.new_end_byte
		view.caret_byte = response.edit.new_end_byte
		view.anchor_affinity = .Trailing
		view.caret_affinity = .Trailing
		view.preferred_x_set = false
		view.position_reconcile_pending = true
		app.find_presentation.editor_revision = 0
		find_set_message(&app.find_replace_message, "Replaced current match.")
		find_refresh_if_needed(app, rt)
	} else if response.ok {
		find_set_message(&app.find_replace_message, "The replacement did not change the document.")
	} else {
		find_set_message(&app.find_replace_message, response.message)
		if response.code == "stale_editor_revision" || response.code == "stale_find_match" {
			app.find_presentation.editor_revision = 0
			find_refresh_if_needed(app, rt)
		}
	}
	bridge.backend_command_result_destroy(&response, context.allocator)
	alicorn.invalidate_root(rt, "Scratchpad replaced the active Find match against authoritative source")
	return true
}

find_replace_all :: proc(app: ^App, rt: ^alicorn.Runtime) -> bool {
	if app == nil || rt == nil || !app.find_open || !app.backend.started { return false }
	if len(app.editor_edits) > 0 {
		find_set_message(&app.find_replace_message, "Wait for pending edits to finish.")
		alicorn.invalidate_root(rt, "Scratchpad deferred Replace All until pending edits finish")
		return true
	}
	if editor_active_preedit(app) {
		find_set_message(&app.find_replace_message, "Finish or cancel text composition before replacing.")
		alicorn.invalidate_root(rt, "Scratchpad Replace All refused during IME composition")
		return true
	}
	if len(app.find_query) == 0 {
		find_set_message(&app.find_replace_message, "Enter a Find query first.")
		return true
	}
	if len(app.find_replace_text) > int(bridge.MAX_EDIT_BYTES) {
		find_set_message(&app.find_replace_message, "Replacement exceeds the 128 KiB per-edit limit.")
		alicorn.invalidate_root(rt, "Scratchpad Replace All replacement exceeded the edit limit")
		return true
	}
	find_refresh_if_needed(app, rt)
	if len(app.find_presentation.matches) == 0 {
		find_set_message(&app.find_replace_message, "No matches to replace.")
		return true
	}
	document, view, _, ready := active_editor_context(app)
	if !ready || view == nil || document.id != app.find_presentation.document_id ||
	   document.editor_revision != app.find_presentation.editor_revision || app.find_presentation.query != app.find_query {
		find_set_message(&app.find_replace_message, "Waiting for current Find results.")
		alicorn.invalidate_root(rt, "Scratchpad Replace All waited for current authoritative Find results")
		return true
	}
	replacement, replacement_ok := find_replacement_bytes(app.find_replace_text)
	if !replacement_ok {
		find_set_message(&app.find_replace_message, "Could not prepare replacement text.")
		return true
	}
	response := bridge.backend_command(
		&app.backend,
		"find_replace_all",
		document_id=document.id,
		editor_revision=document.editor_revision,
		query=app.find_query,
		replacement=replacement,
		has_selection_state=true,
		before_anchor_byte=view.selection_anchor,
		before_cursor_byte=view.caret_byte,
	)
	if response.ok {
		switch {
		case response.matches_replaced == 0:
			find_set_message(&app.find_replace_message, "No matches to replace.")
		case response.source_refresh_needed && response.editor_selection.document_id == document.id:
			view.authoritative_revision = response.editor_selection.editor_revision
			view.optimistic_pending_edits = 0
			view.optimistic_line_delta = 0
			view.selection_anchor = response.editor_selection.anchor_byte
			view.caret_byte = response.editor_selection.cursor_byte
			view.anchor_affinity = .Trailing
			view.caret_affinity = .Trailing
			view.preferred_x_set = false
			view.position_reconcile_pending = true
			app.find_presentation.editor_revision = 0
			find_set_message(&app.find_replace_message, fmt.tprintf("Replaced %d matches.", response.matches_replaced))
			find_refresh_if_needed(app, rt)
		case:
			find_set_message(&app.find_replace_message, fmt.tprintf("%d matches were unchanged.", response.matches_replaced))
		}
	} else {
		find_set_message(&app.find_replace_message, response.message)
		if response.code == "stale_editor_revision" {
			app.find_presentation.editor_revision = 0
			find_refresh_if_needed(app, rt)
		}
	}
	bridge.backend_command_result_destroy(&response, context.allocator)
	alicorn.invalidate_root(rt, "Scratchpad replaced all current Find matches in one authoritative edit")
	return true
}

find_replacement_bytes :: proc(text: string) -> (replacement: []int, ok: bool) {
	result, allocation_error := make([]int, len(text), allocator=context.temp_allocator)
	if allocation_error != nil { return nil, false }
	for index, value in text { result[index] = int(value) }
	return result, true
}

find_apply_active_match :: proc(app: ^App, rt: ^alicorn.Runtime, reveal := true) -> bool {
	if app == nil || !app.backend.started { return false }
	presentation := &app.find_presentation
	if presentation.active_match < 0 || presentation.active_match >= len(presentation.matches) { return false }
	match := presentation.matches[presentation.active_match]
	if match.start < 0 || match.end < match.start || match.line < 0 { return false }
	document, found := find_document(&app.backend.state, app.backend.state.active)
	if !found || document.id != presentation.document_id { return false }
	view_index, view_ok := editor_view_ensure(&app.editor_views, document.id)
	if !view_ok { return false }
	view := &app.editor_views[view_index]
	editor_undo_group_break(view)
	view.selection_anchor = u64(match.start)
	view.caret_byte = u64(match.end)
	view.anchor_affinity = .Leading
	view.caret_affinity = .Trailing
	view.preferred_x_set = false
	if reveal && rt != nil && app.editor_scroll_owner != 0 {
		_ = find_reveal_match_line(rt, view, app.editor_scroll_owner, match.line)
	}
	if rt != nil { alicorn.invalidate_root(rt, "Scratchpad Find selected a source-byte match") }
	return true
}

// Keep an already-comfortably-visible match in place. Otherwise move its
// logical source row toward the viewport center, using the same sparse visual
// row measurements as the editor so wrapped Markdown retains correct geometry.
find_reveal_match_line :: proc(
	rt: ^alicorn.Runtime,
	view: ^Editor_View_State,
	owner: alicorn.Node_ID,
	logical_line: int,
) -> bool {
	if rt == nil || view == nil || owner == 0 || logical_line < 0 { return false }
	node, found := rt.nodes[owner]
	if !found || !node.active || node.kind != .Scroll_Region { return false }
	viewport := node.scroll_viewport_height
	if viewport <= 0 { viewport = node.bounds.h }
	if viewport <= 0 { return false }

	row_top := f32(logical_line)*EDITOR_ROW_HEIGHT
	row_height := EDITOR_ROW_HEIGHT
	if view.wrap_height_index_ready && logical_line < view.wrap_height_index.item_count {
		row_top = alicorn.virtual_list_height_index_item_top(&view.wrap_height_index, logical_line)
		row_height = alicorn.virtual_list_height_index_item_height(&view.wrap_height_index, logical_line)
		if row_height <= 0 { row_height = EDITOR_ROW_HEIGHT }
	}
	row_bottom := row_top+row_height
	centered_offset, should_scroll := find_match_center_offset(
		node.scroll_offset_y, viewport, row_top, row_height,
	)
	if !should_scroll { return false }
	return alicorn.scroll_region_set_offset(
		rt,
		owner,
		centered_offset,
		"Scratchpad centered a Find match while preserving comfortably visible context",
	)
}

find_match_center_offset :: proc(current_offset, viewport, row_top, row_height: f32) -> (offset: f32, should_scroll: bool) {
	if viewport <= 0 || row_height <= 0 { return current_offset, false }
	row_bottom := row_top+row_height
	margin := min(viewport*0.18, 64)
	if row_top >= current_offset+margin && row_bottom <= current_offset+viewport-margin {
		return current_offset, false
	}
	return max(row_top+row_height*0.5-viewport*0.5, 0), true
}

find_move_match :: proc(app: ^App, rt: ^alicorn.Runtime, direction: int) -> bool {
	if app == nil || (app.workspace_search_mode && !app.find_open) || (!app.find_open && len(app.find_query) == 0) { return false }
	stale := false
	if app.backend.started {
		if document, found := find_document(&app.backend.state, app.backend.state.active); found {
			stale = app.find_presentation.document_id != document.id ||
			        app.find_presentation.editor_revision != document.editor_revision ||
			        app.find_presentation.query != app.find_query
		}
	}
	find_refresh_if_needed(app, rt)
	if len(app.find_presentation.matches) == 0 { return false }
	if stale && !app.find_open {
		view_index := editor_view_find(app.editor_views[:], app.find_presentation.document_id)
		if view_index >= 0 {
			cursor := app.editor_views[view_index].caret_byte
			app.find_presentation.active_match = find_initial_match(app.find_presentation.matches, cursor)
			if direction < 0 { app.find_presentation.active_match = find_initial_previous_match(app.find_presentation.matches, cursor) }
			return find_apply_active_match(app, rt)
		}
	}
	app.find_presentation.active_match = find_step_match(
		len(app.find_presentation.matches), app.find_presentation.active_match, direction,
	)
	return find_apply_active_match(app, rt)
}

workspace_search_move_selection :: proc(app: ^App, rt: ^alicorn.Runtime, direction: int) -> bool {
	if app == nil || rt == nil || !app.workspace_search_mode { return false }
	if len(app.workspace_search_view.results) == 0 { return true }
	selected := workspace_search_selection_step(
		len(app.workspace_search_view.results),
		app.workspace_search_selected,
		direction,
	)
	if selected != app.workspace_search_selected {
		app.workspace_search_selected = selected
		if app.workspace_search_results_owner != 0 {
			_ = alicorn.virtual_list_ensure_visible(
				rt,
				app.workspace_search_results_owner,
				selected,
				"Scratchpad workspace search selection moved",
			)
		}
		alicorn.invalidate_root(rt, "Scratchpad workspace search selection moved")
	}
	return true
}

workspace_search_cancel_active :: proc(app: ^App) {
	if app == nil || !app.backend.started || app.workspace_search_view.generation == 0 || app.workspace_search_view.done { return }
	response := bridge.backend_command(
		&app.backend,
		"workspace_search_cancel",
		search_generation=app.workspace_search_view.generation,
	)
	bridge.backend_command_result_destroy(&response, context.allocator)
	app.workspace_search_view.done = true
	find_set_message(&app.workspace_search_started_query, "")
	find_set_message(&app.workspace_search_started_root, "")
}

find_refresh_if_needed :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || !app.backend.started { return }
	document, found := find_document(&app.backend.state, app.backend.state.active)
	if !found { return }
	view_index, view_ok := editor_view_ensure(&app.editor_views, document.id)
	if !view_ok { return }
	if app.find_presentation.document_id == document.id &&
	   app.find_presentation.editor_revision == document.editor_revision &&
	   app.find_presentation.query == app.find_query { return }

	matches: []bridge.Current_Match
	truncated := false
	if len(app.find_query) > 0 {
		if len(app.find_query) > bridge.MAX_FIND_QUERY_BYTES {
			if find_presentation_install(&app.find_presentation, document.id, app.find_query, document.editor_revision, matches, false, app.editor_views[view_index].caret_byte) {
				find_set_message(&app.find_error, "Find query exceeds the 4096 byte limit.")
			} else {
				find_set_message(&app.find_error, "Could not retain the bounded Find query state.")
			}
			return
		}
		response := bridge.backend_command(
			&app.backend,
			"find_current",
			document_id=document.id,
			query=app.find_query,
			max_matches=FIND_MAX_MATCHES,
			read_latest_after=false,
		)
		if response.ok {
			matches = response.matches
			truncated = response.matches_truncated
			find_set_message(&app.find_error, "")
		} else {
			find_set_message(&app.find_error, response.message)
		}
		bridge.backend_command_result_destroy(&response, context.allocator)
	} else {
		find_set_message(&app.find_error, "")
	}
	view := &app.editor_views[view_index]
	if !find_presentation_install(
		&app.find_presentation,
		document.id,
		app.find_query,
		document.editor_revision,
		matches,
		truncated,
		view.caret_byte,
	) {
		find_set_message(&app.find_error, "Could not retain the bounded Find matches.")
		return
	}
	if len(app.find_presentation.matches) > 0 { _ = find_apply_active_match(app, rt) }
}

find_restore_after_frame :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil { return }
	if app.find_restore_pending {
		if app.find_restore_valid && app.find_restore_document_id != "" {
			if index := editor_view_find(app.editor_views[:], app.find_restore_document_id); index >= 0 {
				view := &app.editor_views[index]
				view.selection_anchor = app.find_restore_anchor
				view.caret_byte = app.find_restore_caret
				view.anchor_affinity = app.find_restore_anchor_affinity
				view.caret_affinity = app.find_restore_caret_affinity
				view.preferred_x_set = false
			}
		}
		app.find_restore_pending = false
		app.find_restore_valid = false
		if len(app.find_restore_document_id) > 0 { delete(app.find_restore_document_id, context.allocator) }
		app.find_restore_document_id = ""
	}
	if app.find_focus_pending && app.find_query_node != 0 {
		if alicorn.focus(rt, app.find_query_node) && app.find_select_query_pending {
			if node, found := rt.nodes[app.find_query_node]; found && node.kind == .Text_Field {
				_ = alicorn.set_text_selection(rt, app.find_query_node, 0, len(node.text))
			}
		}
		app.find_focus_pending = false
		app.find_select_query_pending = false
		app.workspace_search_focus_pending = false
		app.editor_focus_pending = false
	} else if app.workspace_search_focus_pending && app.workspace_search_query_node != 0 {
		_ = alicorn.focus(rt, app.workspace_search_query_node)
		app.workspace_search_focus_pending = false
		app.find_focus_pending = false
		app.editor_focus_pending = false
	} else if app.editor_focus_pending {
		if app.editor_scroll_owner != 0 { _ = alicorn.focus(rt, app.editor_scroll_owner) }
		app.editor_focus_pending = false
	}
}

workspace_search_start_query :: proc(app: ^App, rt: ^alicorn.Runtime, force := false) {
	if app == nil || !app.backend.started { return }
	root := app.backend.state.workspace_root
	if !app.backend.state.has_workspace { return }
	if !force && app.workspace_search_started_query == app.workspace_search_query &&
	   app.workspace_search_started_root == root { return }
	old_generation := app.workspace_search_view.generation
	next_generation := max(app.workspace_search_generation, app.backend.state.workspace_search_generation)+1
	if next_generation == 0 { next_generation = 1 }
	app.workspace_search_generation = next_generation
	workspace_search_view_begin(&app.workspace_search_view, next_generation)
	app.workspace_search_selected = -1
	find_set_message(&app.workspace_search_error, "")
	find_set_message(&app.workspace_search_started_query, app.workspace_search_query)
	find_set_message(&app.workspace_search_started_root, root)
	if len(app.workspace_search_query) > bridge.MAX_WORKSPACE_SEARCH_QUERY_BYTES {
		if old_generation > 0 {
			cancel := bridge.backend_command(&app.backend, "workspace_search_cancel", search_generation=old_generation)
			bridge.backend_command_result_destroy(&cancel, context.allocator)
		}
		app.workspace_search_view.done = true
		find_set_message(&app.workspace_search_error, "Search query exceeds the 4096 byte limit.")
		return
	}
	response := bridge.backend_command(
		&app.backend,
		"workspace_search_start",
		query=app.workspace_search_query,
		search_generation=next_generation,
	)
	if !response.ok {
		app.workspace_search_view.done = true
		find_set_message(&app.workspace_search_error, response.message)
	}
	bridge.backend_command_result_destroy(&response, context.allocator)
	if rt != nil { alicorn.invalidate_root(rt, "Scratchpad workspace search generation started") }
}

workspace_search_sync_wake :: proc(app: ^App, rt: ^alicorn.Runtime) -> bool {
	if app == nil || rt == nil || !app.backend.started { return false }
	state := &app.backend.state
	view := &app.workspace_search_view
	if view.generation == 0 || state.workspace_search_generation != view.generation ||
	   state.workspace_root != app.workspace_search_started_root { return false }
	view.count = state.workspace_search_count
	view.done = state.workspace_search_done
	view.truncated = state.workspace_search_truncated || len(view.results) >= WORKSPACE_SEARCH_MAX_RESULTS
	if !state.workspace_search_page_available || state.workspace_search_sequence <= view.last_sequence { return false }
	response := bridge.backend_command(
		&app.backend,
		"workspace_search_take_page",
		search_generation=view.generation,
		read_latest_after=false,
	)
	accepted := false
	if response.ok && response.search_page_owned {
		accepted = workspace_search_view_append(view, response.workspace_search_page)
	} else if response.code != "stale_search_generation" {
		find_set_message(&app.workspace_search_error, response.message)
	}
	bridge.backend_command_result_destroy(&response, context.allocator)
	if accepted { alicorn.invalidate_root(rt, "Scratchpad workspace search page arrived") }
	if accepted && app.workspace_search_selected < 0 && len(view.results) > 0 { app.workspace_search_selected = 0 }
	return accepted
}

workspace_search_activate_result :: proc(app: ^App, rt: ^alicorn.Runtime, result_index: int) -> bool {
	if app == nil || rt == nil || !app.backend.started || result_index < 0 ||
	   result_index >= len(app.workspace_search_view.results) || !app.backend.state.has_workspace { return false }
	result := app.workspace_search_view.results[result_index]
	path, path_error := os.join_path({app.backend.state.workspace_root, result.path}, context.temp_allocator)
	if path_error != nil {
		find_set_message(&app.workspace_search_error, "Could not resolve the selected workspace result path.")
		alicorn.invalidate_root(rt, "Scratchpad could not resolve a workspace search result path")
		return true
	}
	response := bridge.backend_command(
		&app.backend,
		"open_path",
		path=path,
		has_target_byte=true,
		target_byte=u64(max(result.start_byte, 0)),
	)
	if response.ok {
		app.find_open = false
		app.find_query_node = 0
		find_discard_saved_selection(app)
		app.editor_focus_pending = true
		handle_command_result(app, rt, &response)
		if response.editor_selection.document_id != "" {
			editor_apply_backend_selection(app, rt, response.editor_selection)
		}
	} else {
		find_set_message(&app.workspace_search_error, response.message)
		alicorn.invalidate_root(rt, "Scratchpad could not open the selected search result")
	}
	bridge.backend_command_result_destroy(&response, context.allocator)
	return true
}
