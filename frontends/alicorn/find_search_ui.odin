package main

import "core:fmt"
import "core:os"
import "core:strings"
import alicorn "alicorn:runtime"
import gui "alicorn:ui"
import host "alicorn:native/sdl_gpu"
import bridge "./bridge"

FIND_QUERY_KEY :: "scratchpad-find-query"
WORKSPACE_SEARCH_QUERY_KEY :: "scratchpad-workspace-search-query"
FIND_TEXT_HISTORY_LIMIT :: 32

Find_Text_Edit_History :: struct {
	undo: [dynamic]string,
	redo: [dynamic]string,
	observed_text: string,
	observed_initialized: bool,
}

find_text_history_clear_stack :: proc(stack: ^[dynamic]string) {
	if stack == nil { return }
	for value in stack^ {
		if len(value) > 0 { delete(value, context.allocator) }
	}
	delete(stack^)
	stack^ = {}
}

find_text_history_trim :: proc(stack: ^[dynamic]string) {
	if stack == nil { return }
	for len(stack^) > FIND_TEXT_HISTORY_LIMIT {
		oldest := stack^[0]
		if len(oldest) > 0 { delete(oldest, context.allocator) }
		ordered_remove(stack, 0)
	}
}

find_text_history_set_observed :: proc(history: ^Find_Text_Edit_History, text: string) {
	if history == nil { return }
	copy, err := strings.clone(text, context.allocator)
	if err != nil { return }
	if len(history.observed_text) > 0 { delete(history.observed_text, context.allocator) }
	history.observed_text = copy
	history.observed_initialized = true
}

find_text_history_initialize :: proc(history: ^Find_Text_Edit_History, text: string) {
	if history == nil || history.observed_initialized { return }
	find_text_history_set_observed(history, text)
}

find_text_history_observe :: proc(history: ^Find_Text_Edit_History, text: string) {
	if history == nil { return }
	if !history.observed_initialized {
		find_text_history_initialize(history, text)
		return
	}
	if history.observed_text == text { return }
	if previous, err := strings.clone(history.observed_text, context.allocator); err == nil {
		append(&history.undo, previous)
		find_text_history_trim(&history.undo)
		find_text_history_clear_stack(&history.redo)
	}
	find_text_history_set_observed(history, text)
}

find_text_history_destroy :: proc(history: ^Find_Text_Edit_History) {
	if history == nil { return }
	find_text_history_clear_stack(&history.undo)
	find_text_history_clear_stack(&history.redo)
	if len(history.observed_text) > 0 { delete(history.observed_text, context.allocator) }
	history^ = {}
}

// The Find query has one application-owned allocator for its lifetime. The
// retained field borrows the buffer only while describing this control.
find_query_build :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime) -> alicorn.Text_Field_Response {
	if !app.find_query.initialized {
		buffer, ok := alicorn.text_field_buffer_init("", context.allocator)
		if !ok {
			find_set_message(&app.find_error, "Could not initialize the Find query.")
			return {}
		}
		app.find_query = buffer
	}
	find_text_history_initialize(&app.find_query_edit_history, app.find_query.text)
	response := gui.text_field(
		ui, "Find", &app.find_query, key=alicorn.key_string(FIND_QUERY_KEY),
		style=alicorn.layout_style(.Row, grow=1, height=36),
		text_style=SCRATCHPAD_PROMINENT_INPUT_TEXT_STYLE,
	)
	app.find_query_node = response.node
	// Refresh after committed input is adopted so result counts, highlights,
	// and selection all use this description's query. Preedit stays in Alicorn.
	find_refresh_if_needed(app, rt)
	if response.changed {
		find_text_history_observe(&app.find_query_edit_history, app.find_query.text)
		find_set_message(&app.find_replace_message, "")
		alicorn.invalidate_root(rt, "Scratchpad Find adopted committed query input")
	}
	if response.submitted { _ = find_move_match(app, rt, 1) }
	return response
}

// Native Edit shortcuts run before text-field key handling. Keep clipboard
// operations and history local to whichever Find or Replace box owns focus.
application_focused_text_field :: proc(rt: ^alicorn.Runtime) -> (node_id: alicorn.Node_ID, state: alicorn.Text_Field_Interaction, value: string, found: bool) {
	if rt == nil { return }
	node_id = alicorn.focused_node(rt)
	interaction, state_ok := alicorn.text_field_interaction(rt, node_id)
	text_value, value_ok := alicorn.text_field_value(rt, node_id)
	state = interaction
	value = text_value
	found = state_ok && value_ok && state.focused && state.can_edit
	return
}

find_focused_text_field :: proc(app: ^App, rt: ^alicorn.Runtime) -> (node_id: alicorn.Node_ID, is_query, found: bool) {
	if app == nil || rt == nil || !app.find_open { return }
	focused_id, interaction, _, focused := application_focused_text_field(rt)
	if !focused || !interaction.can_edit { return }
	if focused_id == app.find_query_node && focused_id != 0 { return focused_id, true, true }
	if focused_id == app.find_replace_node && focused_id != 0 { return focused_id, false, true }
	return
}

find_text_field_history_for :: proc(app: ^App, is_query: bool) -> ^Find_Text_Edit_History {
	if app == nil { return nil }
	if is_query { return &app.find_query_edit_history }
	return &app.find_replace_edit_history
}

find_text_field_clipboard_command :: proc(app: ^App, rt: ^alicorn.Runtime, action_id: string) -> bool {
	node_id, interaction, value, focused := application_focused_text_field(rt)
	if !focused { return false }
	if app == nil { return true }
	is_query := app != nil && app.find_open && node_id == app.find_query_node
	is_replace := app != nil && app.find_open && node_id == app.find_replace_node
	if interaction.composition_active {
		set_error(app, "Finish or cancel the active text composition before using this edit command.")
		alicorn.invalidate_root(rt, "Scratchpad text field edit command refused during IME composition")
		return true
	}
	switch action_id {
	case ACTION_EDIT_SELECT_ALL:
		_ = alicorn.set_text_selection(rt, node_id, 0, len(value))
		alicorn.invalidate_root(rt, "Scratchpad selected all text in the focused text field")
	case ACTION_EDIT_COPY, ACTION_EDIT_CUT:
		start, end := interaction.selection_start, interaction.selection_end
		if !interaction.has_selection { return true }
		selected, err := strings.clone(value[start:end], context.allocator)
		if err != nil { set_error(app, "Could not retain the selected text."); return true }
		defer delete(selected, context.allocator)
		if action_id == ACTION_EDIT_CUT {
			change := alicorn.process_text_command(rt, node_id, .Delete_Forward)
			changed := change.changed
			alicorn.text_change_destroy(rt, &change)
			if !changed {
				set_error(app, "Cut could not remove the selected text.")
				alicorn.invalidate_root(rt, "Scratchpad text field Cut deletion failed")
				return true
			}
		}
		if app.services.clipboard.set_text == nil || !host.ClipboardSetText(app.services.clipboard, selected) {
			set_error(app, "Could not copy selected text to the system clipboard.")
			alicorn.invalidate_root(rt, "Scratchpad text field clipboard write failed")
			if action_id == ACTION_EDIT_CUT {
				_ = alicorn.set_text_selection(rt, node_id, start, start)
				rollback := alicorn.process_text_input(rt, node_id, selected)
				alicorn.text_change_destroy(rt, &rollback)
			}
			return true
		}
		if is_query {
			find_text_history_observe(&app.find_query_edit_history, app.find_query.text)
		} else if is_replace {
			// The app-owned string is synchronized at the next description.
		}
	case ACTION_EDIT_PASTE:
		if app == nil || app.services.clipboard.get_text == nil { return true }
		text, clipboard_ok := host.ClipboardGetText(app.services.clipboard, allocator=context.allocator)
		if !clipboard_ok {
			set_error(app, "Could not read text from the system clipboard.")
			alicorn.invalidate_root(rt, "Scratchpad text field clipboard read failed")
			return true
		}
		defer delete(text, context.allocator)
		if len(text) == 0 { return true }
		limit := int(bridge.MAX_EDIT_BYTES)
		if is_query { limit = int(bridge.MAX_FIND_QUERY_BYTES) }
		if len(value)-(interaction.selection_end-interaction.selection_start)+len(text) > limit {
			message := "Pasted text exceeds the 128 KiB per-edit limit."
			if is_query { message = "Pasted Find query exceeds the 4 KiB search limit." }
			set_error(app, message)
			alicorn.invalidate_root(rt, "Scratchpad rejected oversized text-field clipboard input")
			return true
		}
		change := alicorn.process_text_input(rt, node_id, text)
		alicorn.text_change_destroy(rt, &change)
	}
	return true
}
find_text_field_replace_value :: proc(app: ^App, rt: ^alicorn.Runtime, node_id: alicorn.Node_ID, is_query: bool, value: string) -> bool {
	focused_node, field_state, _, found := application_focused_text_field(rt)
	if !found || focused_node != node_id || node_id == 0 || !field_state.can_edit || field_state.composition_active { return false }
	current, value_ok := alicorn.text_field_value(rt, node_id)
	if !value_ok { return false }
	same_value := current == value
	if is_query {
		if !alicorn.text_field_buffer_set(&app.find_query, value) { return false }
	} else {
		copy, err := strings.clone(value, context.allocator)
		if err != nil { return false }
		if len(app.find_replace_text) > 0 { delete(app.find_replace_text, context.allocator) }
		app.find_replace_text = copy
	}
	_ = alicorn.set_text_selection(rt, node_id, 0, len(current))
	change := alicorn.process_text_input(rt, node_id, value)
	changed := change.changed
	alicorn.text_change_destroy(rt, &change)
	return changed || same_value
}

find_text_field_history_command :: proc(app: ^App, rt: ^alicorn.Runtime, redo: bool) -> bool {
	node_id, interaction, value, focused := application_focused_text_field(rt)
	if !focused { return false }
	is_find_query := app != nil && app.find_open && node_id == app.find_query_node
	is_find_replace := app != nil && app.find_open && node_id == app.find_replace_node
	is_search_result := app != nil && app.workspace_search_edit_active && node_id == app.workspace_search_edit_node
	if is_search_result {
		if interaction.composition_active {
			set_error(app, "Finish or cancel the active text composition before undoing a source edit.")
			alicorn.invalidate_root(rt, "Scratchpad refused source history during search-result IME composition")
			return true
		}
		if workspace_search_edit_has_pending_intents(app) {
			set_error(app, "Wait for the current source edit to finish before undoing or redoing.")
			alicorn.invalidate_root(rt, "Scratchpad serialized source history after a search-result edit")
			return true
		}
		if !workspace_search_edit_finish(app, rt, refresh=false) { return true }
		dispatch_action(app, rt, ACTION_EDIT_REDO if redo else ACTION_EDIT_UNDO)
		if app.workspace_search_mode { workspace_search_start_query(app, rt, true) }
		return true
	}
	if !is_find_query && !is_find_replace { return true }
	is_query := is_find_query
	history := find_text_field_history_for(app, is_query)
	if history == nil { return true }
	find_text_history_initialize(history, value)
	if interaction.composition_active {
		set_error(app, "Finish or cancel the active text composition before changing Find field history.")
		alicorn.invalidate_root(rt, "Scratchpad Find/Replace history command refused during IME composition")
		return true
	}
	source := &history.undo
	destination := &history.redo
	if redo { source, destination = &history.redo, &history.undo }
	if len(source^) == 0 { return true }
	last := len(source^)-1
	target := source^[last]
	current, err := strings.clone(value, context.allocator)
	if err != nil {
		set_error(app, "Could not retain Find field history.")
		alicorn.invalidate_root(rt, "Scratchpad Find/Replace history allocation failed")
		return true
	}
	if !find_text_field_replace_value(app, rt, node_id, is_query, target) {
		delete(current, context.allocator)
		set_error(app, "Could not restore the focused Find field value.")
		alicorn.invalidate_root(rt, "Scratchpad Find/Replace history restore failed")
		return true
	}
	ordered_remove(source, last)
	append(destination, current)
	find_text_history_trim(destination)
	find_text_history_set_observed(history, target)
	if len(target) > 0 { delete(target, context.allocator) }
	if is_query {
		find_set_message(&app.find_replace_message, "")
		find_refresh_if_needed(app, rt)
	}
	alicorn.invalidate_root(rt, "Scratchpad applied focused Find/Replace history command")
	return true
}

find_sync_focused_edit_menu_states :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil { return }
	node_id, interaction, _, focused := application_focused_text_field(rt)
	if !focused { return }
	for &item in app.edit_items {
		if item.kind != .Command { continue }
		switch string_for_action_id(item.command) {
		case ACTION_EDIT_UNDO, ACTION_EDIT_REDO, ACTION_EDIT_COPY, ACTION_EDIT_CUT, ACTION_EDIT_SELECT_ALL:
			// Keep shortcuts routable when paint-only selection/caret changes
			// do not cause an application description. Handlers inspect the
			// current selection/history and safely consume no-op commands.
			item.state = alicorn.Action_State{enabled=!interaction.composition_active}
		case ACTION_EDIT_PASTE:
			item.state = alicorn.Action_State{enabled=!interaction.composition_active && app.services.clipboard.get_text != nil}
		}
		_ = alicorn.action_update(rt,
			alicorn.Action_Descriptor{id=item.command, name=string_for_action_id(item.command), label=item.label},
			item.state,
		)
	}
}
workspace_search_match_clear_all :: proc(app: ^App) {
	if app == nil { return }
	for &view in app.editor_views { workspace_search_match_clear(&view) }
}

find_capture_text_field :: proc(rt: ^alicorn.Runtime, node_id: alicorn.Node_ID, value: ^string) -> bool {
	if rt == nil || value == nil || node_id == 0 { return false }
	node, found := alicorn.node_info(rt, node_id)
	text, value_found := alicorn.text_field_value(rt, node_id)
	if !found || !value_found || !node.active || text == value^ { return false }
	copy, err := strings.clone(text, context.allocator)
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
	view_index, view_ok := app_editor_view_ensure(app, document.id)
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
	workspace_search_match_clear_all(app)
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
		   app.find_presentation.query == app.find_query.text &&
		   app.find_presentation.match_case == app.find_match_case &&
		   app.find_presentation.whole_word == app.find_whole_word {
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
	   app.find_presentation.query != app.find_query.text ||
	   app.find_presentation.match_case != app.find_match_case ||
	   app.find_presentation.whole_word != app.find_whole_word {
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
	replacement, replacement_ok := string_bytes_to_wire(app.find_replace_text)
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
		query=app.find_query.text,
		match_case=app.find_match_case,
		whole_word=app.find_whole_word,
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
	if len(app.find_query.text) == 0 {
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
	   document.editor_revision != app.find_presentation.editor_revision || app.find_presentation.query != app.find_query.text ||
	   app.find_presentation.match_case != app.find_match_case || app.find_presentation.whole_word != app.find_whole_word {
		find_set_message(&app.find_replace_message, "Waiting for current Find results.")
		alicorn.invalidate_root(rt, "Scratchpad Replace All waited for current authoritative Find results")
		return true
	}
	replacement, replacement_ok := string_bytes_to_wire(app.find_replace_text)
	if !replacement_ok {
		find_set_message(&app.find_replace_message, "Could not prepare replacement text.")
		return true
	}
	response := bridge.backend_command(
		&app.backend,
		"find_replace_all",
		document_id=document.id,
		editor_revision=document.editor_revision,
		query=app.find_query.text,
		match_case=app.find_match_case,
		whole_word=app.find_whole_word,
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

string_bytes_to_wire :: proc(text: string) -> (replacement: []int, ok: bool) {
	result, allocation_error := make([]int, len(text), allocator=context.temp_allocator)
	if allocation_error != nil { return nil, false }
	for byte_index in 0..<len(text) { result[byte_index] = int(text[byte_index]) }
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
	view_index, view_ok := app_editor_view_ensure(app, document.id)
	if !view_ok { return false }
	view := &app.editor_views[view_index]
	editor_undo_group_break(view)
	view.selection_anchor = u64(match.start)
	view.caret_byte = u64(match.end)
	view.anchor_affinity = .Leading
	view.caret_affinity = .Trailing
	view.preferred_x_set = false
	if reveal {
		_ = editor_reveal_request_set(
			view,
			document.id,
			presentation.editor_revision,
			u64(match.start),
			u64(match.end),
			u64(match.line),
			.Center_When_Needed,
		)
	}
	if rt != nil { alicorn.invalidate_root(rt, "Scratchpad Find selected a source-byte match") }
	return true
}

find_match_center_offset :: proc(current_offset, viewport, row_top, row_height: f32) -> (offset: f32, should_scroll: bool) {
	return editor_reveal_content_offset(current_offset, viewport, row_top, row_height, .Center_When_Needed)
}

// Resolve a source destination after the editor has emitted and shaped its
// rows. Both Find and workspace search use this path, so scroll restoration,
// wrapped text, and horizontal overflow share one geometry-based policy.
editor_reveal_after_frame :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil || app.editor_scroll_owner == 0 || !app.backend.started { return }
	document, document_found := find_document(&app.backend.state, app.backend.state.active)
	if !document_found { return }
	view_index := editor_view_find(app.editor_views[:], document.id)
	if view_index < 0 { return }
	view := &app.editor_views[view_index]
	request := view.reveal_request
	if !request.pending || request.document_id != document.id { return }
	if request.editor_revision < document.editor_revision {
		editor_reveal_request_clear(&view.reveal_request)
		return
	}
	window, window_matches := editor_view_window(view, &app.editor_window,
		app.editor_window_ready, document.id, request.editor_revision)
	if request.editor_revision != document.editor_revision || !window_matches ||
	   window.editor_revision != request.editor_revision {
		return
	}
	line, line_found := editor_window_line(window, request.logical_line)
	if !line_found { return }
	target, target_found := editor_row_target_for_source(
		app.editor_row_targets[:], line.logical_line, request.source_start,
	)
	if !target_found { return }
	target_node, node_found := alicorn.node_info(rt, target.node)
	owner, owner_found := alicorn.node_info(rt, app.editor_scroll_owner)
	if !node_found || !owner_found || !target_node.active || !owner.active ||
	   target_node.bounds.h <= 0 || owner.kind != .Scroll_Region { return }

	viewport_top := owner.scroll_viewport_bounds.y
	viewport_height := owner.scroll_viewport_height
	if viewport_height <= 0 { viewport_height = owner.bounds.h }
	if viewport_height <= 0 { return }

	display_line, display_found := editor_display_line_for_target(window, line, target)
	if !display_found { return }
	match_start := min(max(request.source_start, line.source_start), line.source_end)
	match_end := min(max(request.source_end, match_start), line.source_end)
	if target.is_cell {
		match_start = max(match_start, target.cell_start)
		match_end = min(max(match_end, match_start), target.cell_end)
	}
	start_display := editor_source_to_display(&display_line, match_start)
	end_display := editor_source_to_display(&display_line, match_end)
	start_geometry := alicorn.text_node_caret_geometry(
		rt, target.node, alicorn.Text_Position{byte=start_display, affinity=.Leading},
	)
	end_geometry := alicorn.text_node_caret_geometry(
		rt, target.node, alicorn.Text_Position{byte=end_display, affinity=.Trailing},
	)
	if !start_geometry.valid || !end_geometry.valid { return }
	match_top := min(start_geometry.rect.y, end_geometry.rect.y)
	match_bottom := max(start_geometry.rect.y+start_geometry.rect.h, end_geometry.rect.y+end_geometry.rect.h)
	if match_bottom <= match_top { match_bottom = match_top+max(start_geometry.rect.h, EDITOR_ROW_HEIGHT*editor_text_scale_effective(app)) }
	content_top := owner.scroll_offset_y+(match_top-viewport_top)
	content_height := match_bottom-match_top
	next_y, should_scroll_y := editor_reveal_content_offset(
		owner.scroll_offset_y,
		viewport_height,
		content_top,
		content_height,
		request.alignment,
	)
	max_y := max(owner.scroll_content_height-viewport_height, 0)
	next_y = min(max(next_y, 0), max_y)
	if should_scroll_y && abs(next_y-owner.scroll_offset_y) > 0.01 {
		if alicorn.scroll_region_set_offset(
			rt, app.editor_scroll_owner, next_y,
			"Scratchpad revealed a source destination after shaped layout",
		) {
			return
		}
	}

	viewport_left := owner.scroll_viewport_bounds.x
	viewport_width := owner.scroll_viewport_width
	if viewport_width <= 0 { viewport_width = owner.bounds.w }
	if viewport_width <= 0 { return }
	viewport_right := viewport_left+viewport_width
	match_left := min(start_geometry.rect.x, end_geometry.rect.x)
	match_right := max(start_geometry.rect.x, end_geometry.rect.x)
	if match_right <= match_left { match_right = match_left+1 }
	margin_x := min(viewport_width*0.08, 48)
	comfort_left := viewport_left+margin_x
	comfort_right := viewport_right-margin_x
	if match_left < comfort_left || match_right > comfort_right {
		match_width := match_right-match_left
		next_x := owner.scroll_offset_x +
		          ((match_left+match_right)*0.5 - (viewport_left+viewport_width*0.5))
		if match_width >= viewport_width-2*margin_x {
			next_x = owner.scroll_offset_x+(match_left-comfort_left)
		}
		max_x := max(owner.scroll_content_width-viewport_width, 0)
		if alicorn.scroll_region_set_offset_x(
			rt, app.editor_scroll_owner, min(max(next_x, 0), max_x),
			"Scratchpad revealed a source destination in the horizontal lane",
		) { return }
	}
	editor_reveal_request_clear(&view.reveal_request)
}

find_move_match :: proc(app: ^App, rt: ^alicorn.Runtime, direction: int) -> bool {
	if app == nil || (app.workspace_search_mode && !app.find_open) || (!app.find_open && len(app.find_query.text) == 0) { return false }
	stale := false
	if app.backend.started {
		if document, found := find_document(&app.backend.state, app.backend.state.active); found {
			stale = app.find_presentation.document_id != document.id ||
			        app.find_presentation.editor_revision != document.editor_revision ||
			        app.find_presentation.query != app.find_query.text ||
			        app.find_presentation.match_case != app.find_match_case ||
			        app.find_presentation.whole_word != app.find_whole_word
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
				workspace_search_display_index(app.workspace_search_view.results[:], selected),
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

workspace_search_open_surface :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil || app.shutdown_intent != .None ||
	   app.close_document_id != "" || app.workspace_mutation_kind != .None ||
	   app.settings_surface_open || app.recent_workspaces_open {
		return
	}
	if app.find_open { find_close_surface(app) }
	app.workspace_search_tab_open = true
	app.workspace_search_mode = true
	app.workspace_projection_mode = false
	app.workspace_search_focus_pending = true
	app.workspace_search_query_node = 0
	app.editor_focus_pending = false
	alicorn.invalidate_root(rt, "Scratchpad Workspace Search tab opened")
}

// Deactivating Search switches the visible editor surface but preserves its
// query, result snapshot, and tab. Source edits are finished before switching
// so the projection never hides an unacknowledged edit or IME composition.
workspace_search_deactivate :: proc(app: ^App, rt: ^alicorn.Runtime) -> bool {
	if app == nil { return true }
	search_source_changed := app.workspace_search_edit_active && app.workspace_search_edit_source_changed
	if app.workspace_search_edit_active {
		finished := workspace_search_edit_finish(app, rt, refresh=false)
		if !finished && !app.workspace_search_edit_finish_pending { return false }
	}
	app.workspace_search_mode = false
	app.workspace_search_query_node = 0
	app.workspace_search_focus_pending = false
	app.editor_focus_pending = true
	if search_source_changed {
		workspace_search_restore_selection_clear(app)
		find_set_message(&app.workspace_search_started_query, "")
		find_set_message(&app.workspace_search_started_root, "")
	}
	return true
}

workspace_search_close_tab :: proc(app: ^App, rt: ^alicorn.Runtime) -> bool {
	if app == nil { return false }
	if app.workspace_search_edit_active && !workspace_search_edit_finish(app, rt, refresh=false) {
		return false
	}
	workspace_search_cancel_active(app)
	workspace_search_match_clear_all(app)
	workspace_search_view_destroy(&app.workspace_search_view, app.workspace_search_view.allocator)
	app.workspace_search_tab_open = false
	app.workspace_search_mode = false
	app.workspace_search_query_node = 0
	app.workspace_search_focus_pending = false
	app.workspace_search_selected = -1
	find_set_message(&app.workspace_search_query, "")
	find_set_message(&app.workspace_search_started_query, "")
	find_set_message(&app.workspace_search_started_root, "")
	find_set_message(&app.workspace_search_error, "")
	app.editor_focus_pending = true
	if rt != nil { alicorn.invalidate_root(rt, "Scratchpad Workspace Search tab closed") }
	return true
}

workspace_search_edit_has_pending_intents :: proc(app: ^App) -> bool {
	if app == nil { return false }
	for edit in app.editor_edits {
		if edit.workspace_search_edit { return true }
	}
	return false
}

workspace_search_edit_session_matches :: proc(app: ^App, result_index: int) -> bool {
	if app == nil || !app.workspace_search_edit_active ||
	   app.workspace_search_edit_generation != app.workspace_search_view.generation ||
	   result_index != app.workspace_search_edit_index ||
	   result_index < 0 || result_index >= len(app.workspace_search_view.results) { return false }
	result := app.workspace_search_view.results[result_index]
	return result.projection_key == app.workspace_search_edit_projection_key
}

workspace_search_edit_clear :: proc(app: ^App) {
	if app == nil { return }
	if app.workspace_search_edit_buffer.initialized {
		alicorn.text_field_buffer_destroy(&app.workspace_search_edit_buffer)
	}
	if len(app.workspace_search_edit_document_id) > 0 { delete(app.workspace_search_edit_document_id, context.allocator) }
	if len(app.workspace_search_edit_source_text) > 0 { delete(app.workspace_search_edit_source_text, context.allocator) }
	app.workspace_search_edit_active = false
	app.workspace_search_edit_ready = false
	app.workspace_search_edit_finish_pending = false
	app.workspace_search_edit_focus_pending = false
	app.workspace_search_edit_select_match_pending = false
	app.workspace_search_edit_place_caret_pending = false
	app.workspace_search_edit_source_changed = false
	app.workspace_search_edit_index = -1
	app.workspace_search_edit_generation = 0
	app.workspace_search_edit_projection_key = 0
	app.workspace_search_edit_document_id = ""
	app.workspace_search_edit_source_text = ""
	app.workspace_search_edit_instance_id = 0
	app.workspace_search_edit_revision = 0
	app.workspace_search_edit_context_start = 0
	app.workspace_search_edit_context_end = 0
	app.workspace_search_edit_caret_byte = 0
	app.workspace_search_edit_match_start = 0
	app.workspace_search_edit_match_end = 0
	app.workspace_search_edit_initial_caret = 0
	app.workspace_search_edit_node = 0
}

workspace_search_edit_finish :: proc(app: ^App, rt: ^alicorn.Runtime, refresh := true, preserve_selection := true) -> bool {
	if app == nil || !app.workspace_search_edit_active { return true }
	projection_key := app.workspace_search_edit_projection_key
	scratchpad_diagnostic_event("search.edit.finish_requested", projection_key)
	if app.workspace_search_edit_node != 0 && rt != nil {
		interaction, found := alicorn.text_field_interaction(rt, app.workspace_search_edit_node)
		if found && interaction.composition_active {
			scratchpad_diagnostic_event("search.edit.waiting_for_composition", projection_key)
			set_error(app, "Finish or cancel the active text composition before leaving this search result.")
			_ = alicorn.focus(rt, app.workspace_search_edit_node)
			alicorn.invalidate_root(rt, "Scratchpad kept a search projection active during IME composition")
			return false
		}
	}
	if workspace_search_edit_has_pending_intents(app) {
		scratchpad_diagnostic_event("search.edit.waiting_for_acknowledgement", projection_key)
		app.workspace_search_edit_finish_pending = true
		set_error(app, "Finishing the search-result edit after the source acknowledgement arrives.")
		return false
	}
	changed := app.workspace_search_edit_source_changed
	if changed && preserve_selection && app.workspace_search_edit_index >= 0 &&
	   app.workspace_search_edit_index < len(app.workspace_search_view.results) {
		result := app.workspace_search_view.results[app.workspace_search_edit_index]
		path_copy, clone_error := strings.clone(result.path, context.allocator)
		if clone_error == nil {
			workspace_search_restore_selection_clear(app)
			app.workspace_search_restore_selection_pending = true
			app.workspace_search_restore_selection_path = path_copy
			app.workspace_search_restore_selection_byte = app.workspace_search_edit_caret_byte
			app.workspace_search_restore_selection_index = app.workspace_search_selected
		}
	}
	workspace_search_edit_clear(app)
	scratchpad_diagnostic_event("search.edit.finished", projection_key)
	if rt != nil { alicorn.invalidate_root(rt, "Scratchpad ended the active search-result edit") }
	if refresh && changed {
		if app.workspace_search_mode {
			workspace_search_start_query(app, rt, true)
		} else {
			find_set_message(&app.workspace_search_started_query, "")
			find_set_message(&app.workspace_search_started_root, "")
		}
	}
	return true
}

workspace_search_edit_focus_transition :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil || !app.workspace_search_edit_active || app.workspace_search_edit_focus_pending { return }
	// The search context menu is a temporary focus surface. Keep the active
	// excerpt alive until the user chooses an action or dismisses the menu.
	if app.workspace_search_context_menu_open && alicorn.context_menu_is_open(rt) { return }
	if !app.workspace_search_mode || alicorn.focused_node(rt) != app.workspace_search_edit_node {
		_ = workspace_search_edit_finish(app, rt, refresh=app.workspace_search_mode)
	}
}

Workspace_Search_Transition_Kind :: enum { None, Edit, Source, Finish }
Workspace_Search_Transition :: struct {
	kind: Workspace_Search_Transition_Kind,
	generation: u64,
	projection_key: u64,
	initial_caret: int,
}

workspace_search_transition_request :: proc(
	app: ^App,
	rt: ^alicorn.Runtime,
	kind: Workspace_Search_Transition_Kind,
	index: int,
	initial_caret: int = -1,
) {
	if app == nil || rt == nil || index < 0 || index >= len(app.workspace_search_view.results) { return }
	app.workspace_search_transition = {
		kind=kind,
	generation=app.workspace_search_view.generation,
		projection_key=app.workspace_search_view.results[index].projection_key,
		initial_caret=initial_caret,
	}
	scratchpad_diagnostic_event("search.transition.requested", app.workspace_search_transition.projection_key)
	alicorn.invalidate_root(rt, "Scratchpad deferred a search-result transition until frame completion")
}

// Result actions may free the entire result array and the app-owned edit
// buffer. Run them only after all pending descriptions have been retained and
// the virtual-list loop has completed. Resolve identity again, never an index.
workspace_search_transition_after_frame :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil || app.workspace_search_transition.kind == .None { return }
	transition := app.workspace_search_transition
	app.workspace_search_transition = {}
	scratchpad_diagnostic_event("search.transition.dispatch", transition.projection_key)
	if !app.workspace_search_mode { return }
	if transition.generation != app.workspace_search_view.generation {
		find_set_message(&app.workspace_search_error, "Search results refreshed after the previous edit; select the updated result to continue.")
		alicorn.invalidate_root(rt, "Scratchpad discarded a search-result switch to a stale projection")
		return
	}
	for result, index in app.workspace_search_view.results {
		if result.projection_key != transition.projection_key { continue }
		switch transition.kind {
		case .Edit: _ = workspace_search_edit_begin(app, rt, index, initial_caret=transition.initial_caret)
		case .Source: _ = workspace_search_go_to_source(app, rt, index)
		case .Finish: _ = workspace_search_edit_finish(app, rt, refresh=true)
		case .None:
		}
		scratchpad_diagnostic_event("search.transition.completed", transition.projection_key)
		return
	}
	find_set_message(&app.workspace_search_error, "The selected search result is no longer available; select it again.")
	alicorn.invalidate_root(rt, "Scratchpad discarded a missing search-result projection")
}

workspace_search_result_index_for_key :: proc(app: ^App, generation, projection_key: u64) -> int {
	if app == nil || generation != app.workspace_search_view.generation { return -1 }
	for result, index in app.workspace_search_view.results {
		if result.projection_key == projection_key { return index }
	}
	return -1
}

workspace_search_context_menu_open :: proc(app: ^App, rt: ^alicorn.Runtime, index: int, x, y: f32) -> bool {
	if app == nil || rt == nil || !app.workspace_search_mode || app.workspace_search_results_owner == 0 ||
	   index < 0 || index >= len(app.workspace_search_view.results) { return false }
	result := app.workspace_search_view.results[index]
	owner := app.workspace_search_results_owner
	if app.workspace_search_edit_active && app.workspace_search_edit_index == index && app.workspace_search_edit_node != 0 {
		owner = app.workspace_search_edit_node
	}
	if !alicorn.context_menu_open(rt, alicorn.Rect{x, y, 0, 0}, owner) { return false }
	app.workspace_search_selected = index
	app.workspace_search_context_menu_open = true
	app.workspace_search_context_generation = app.workspace_search_view.generation
	app.workspace_search_context_projection_key = result.projection_key
	alicorn.invalidate_root(rt, "Scratchpad opened the selected search result context menu")
	return true
}

workspace_search_context_menu_open_selected :: proc(app: ^App, rt: ^alicorn.Runtime) -> bool {
	if app == nil || rt == nil || !app.workspace_search_mode || len(app.workspace_search_view.results) == 0 { return false }
	index := app.workspace_search_selected
	if index < 0 || index >= len(app.workspace_search_view.results) { index = 0 }
	if app.workspace_search_results_owner != 0 {
		_ = alicorn.virtual_list_ensure_visible(rt, app.workspace_search_results_owner,
			workspace_search_display_index(app.workspace_search_view.results[:], index),
			"Scratchpad keyboard context menu selected a search result")
	}
	anchor := alicorn.Rect{}
	for pointer_target in app.workspace_search_pointer_targets {
		if pointer_target.generation != app.workspace_search_view.generation ||
		   pointer_target.projection_key != app.workspace_search_view.results[index].projection_key { continue }
		if info, found := alicorn.node_info(rt, pointer_target.node); found && info.active { anchor = info.bounds; break }
	}
	if anchor.w <= 0 || anchor.h <= 0 {
		if info, found := alicorn.node_info(rt, app.workspace_search_query_node); found { anchor = info.bounds }
	}
	return workspace_search_context_menu_open(app, rt, index, anchor.x+anchor.w, anchor.y+anchor.h)
}

workspace_search_pointer :: proc(
	app: ^App,
	rt: ^alicorn.Runtime,
	event: alicorn.Pointer_Event,
	target_node: alicorn.Node_ID,
) -> bool {
	if app == nil || rt == nil || !app.workspace_search_mode || event.kind != .Down ||
	   (event.button != alicorn.POINTER_BUTTON_PRIMARY && event.button != alicorn.POINTER_BUTTON_SECONDARY) {
		return false
	}
	if app.workspace_search_results_owner == 0 { return false }
	viewport := alicorn.scroll_region_state(rt, app.workspace_search_results_owner).viewport_bounds
	if viewport.w <= 0 || viewport.h <= 0 || event.x < viewport.x || event.x >= viewport.x+viewport.w ||
	   event.y < viewport.y || event.y >= viewport.y+viewport.h { return false }

	// A secondary click on the active Text_Field has no static preview target,
	// so route it by the retained field geometry.
	if event.button == alicorn.POINTER_BUTTON_SECONDARY && app.workspace_search_edit_active &&
	   app.workspace_search_edit_node != 0 {
		if info, found := alicorn.node_info(rt, app.workspace_search_edit_node); found &&
		   event.x >= info.bounds.x && event.x < info.bounds.x+info.bounds.w &&
		   event.y >= info.bounds.y && event.y < info.bounds.y+info.bounds.h {
			return workspace_search_context_menu_open(app, rt, app.workspace_search_edit_index, event.x, event.y)
		}
	}

	for pointer_target in app.workspace_search_pointer_targets {
		if pointer_target.generation != app.workspace_search_view.generation { continue }
		info, found := alicorn.node_info(rt, pointer_target.node)
		if !found || !info.active || event.x < info.bounds.x || event.x >= info.bounds.x+info.bounds.w ||
		   event.y < info.bounds.y || event.y >= info.bounds.y+info.bounds.h { continue }
		index := workspace_search_result_index_for_key(app, pointer_target.generation, pointer_target.projection_key)
		if index < 0 { continue }
		app.workspace_search_selected = index
		if event.button == alicorn.POINTER_BUTTON_SECONDARY {
			return workspace_search_context_menu_open(app, rt, index, event.x, event.y)
		}
		if target_node != 0 && target_node == app.workspace_search_edit_node { return false }
		if pointer_target.kind == .Navigate_Source {
			_ = workspace_search_go_to_source(app, rt, index)
			return true
		}
		result := app.workspace_search_view.results[index]
		if !result.editable {
			find_set_message(&app.workspace_search_error, "This result is read-only; use its file and line heading to inspect the source.")
			alicorn.invalidate_root(rt, "Scratchpad selected a read-only workspace search result")
			return true
		}
		position, hit := alicorn.text_node_hit_test(rt, pointer_target.node, event.x, event.y)
		initial_caret := result.start_byte-result.context_start_byte
		if hit {
			preview := workspace_search_result_preview(result)
			initial_caret = workspace_search_preview_source_position(preview, position.byte)
		}
		_ = workspace_search_edit_begin(app, rt, index, initial_caret=initial_caret)
		return true
	}
	return false
}

workspace_search_source_document_index :: proc(app: ^App, result: bridge.Workspace_Search_Result) -> int {
	if app == nil || !app.backend.state.has_workspace { return -1 }
	for document, index in app.backend.state.documents {
		if tree_path_is_workspace_entry(app.backend.state.workspace_root, result.path, document.path) { return index }
	}
	return -1
}

workspace_search_edit_begin :: proc(app: ^App, rt: ^alicorn.Runtime, result_index: int, initial_caret: int = -1) -> bool {
	if app == nil || rt == nil || !app.backend.started || !app.workspace_search_mode ||
	   result_index < 0 || result_index >= len(app.workspace_search_view.results) { return false }
	if app.ui_description_runtime != nil {
		workspace_search_transition_request(app, rt, .Edit, result_index, initial_caret)
		return true
	}
	scratchpad_diagnostic_event("search.edit.begin", app.workspace_search_view.results[result_index].projection_key)
	if app.pinned.editing {
		pinned_edit_finish(app, rt, false)
		if app.pinned.editing { return true }
	}
	if workspace_search_edit_session_matches(app, result_index) {
		if initial_caret >= 0 {
			app.workspace_search_edit_initial_caret = min(max(initial_caret, 0), len(app.workspace_search_edit_buffer.text))
			app.workspace_search_edit_place_caret_pending = true
			app.workspace_search_edit_select_match_pending = false
		}
		app.workspace_search_edit_focus_pending = true
		return true
	}
	if app.workspace_search_edit_active {
		changed := app.workspace_search_edit_source_changed
		if !workspace_search_edit_finish(app, rt, refresh=false) { return true }
		if changed {
			workspace_search_start_query(app, rt, true)
			find_set_message(&app.workspace_search_error, "Search results refreshed after the previous edit; select the updated result to continue.")
			return true
		}
	}
	workspace_search_restore_selection_clear(app)
	result := app.workspace_search_view.results[result_index]
	if !result.editable || result.line < 0 || result.context_start_byte < 0 || result.context_end_byte <= result.context_start_byte ||
	   result.context_end_byte-result.context_start_byte != len(result.text) ||
	   result.start_byte < result.context_start_byte || result.end_byte > result.context_end_byte || result.end_byte <= result.start_byte {
		find_set_message(&app.workspace_search_error, "This result cannot be safely edited as UTF-8 source text.")
		alicorn.invalidate_root(rt, "Scratchpad refused an uneditable workspace search result")
		return true
	}
	path, path_error := os.join_path({app.backend.state.workspace_root, result.path}, context.temp_allocator)
	if path_error != nil {
		find_set_message(&app.workspace_search_error, "Could not resolve the selected workspace result path.")
		alicorn.invalidate_root(rt, "Scratchpad could not resolve a search projection source")
		return true
	}
	document_index := workspace_search_source_document_index(app, result)
	if document_index < 0 {
		scratchpad_diagnostic_event("search.edit.open_source_background", result.projection_key)
		opened := bridge.backend_command(
			&app.backend,
			"open_path",
			path=path,
			disposition="background",
		)
		if !opened.ok {
			find_set_message(&app.workspace_search_error, opened.message)
			bridge.backend_command_result_destroy(&opened, context.allocator)
			alicorn.invalidate_root(rt, "Scratchpad could not open a background workspace-search source")
			return true
		}
		handle_command_result(app, rt, &opened)
		bridge.backend_command_result_destroy(&opened, context.allocator)
		document_index = workspace_search_source_document_index(app, result)
	}
	if document_index < 0 {
		find_set_message(&app.workspace_search_error, "The search source could not be retained without changing the active document.")
		alicorn.invalidate_root(rt, "Scratchpad could not resolve a background search source")
		return true
	}
	document := app.backend.state.documents[document_index]
	if document.instance_id == 0 || document.view_kind == "image" || document.view_kind == "unsupported" {
		find_set_message(&app.workspace_search_error, "The search source is no longer an editable text document.")
		alicorn.invalidate_root(rt, "Scratchpad rejected a non-text search projection source")
		return true
	}
	if result.source_document_id != "" &&
	   (document.id != result.source_document_id || document.instance_id != result.source_instance_id || document.editor_revision != result.source_revision) {
		workspace_search_start_query(app, rt, true)
		find_set_message(&app.workspace_search_error, "This result was stale because its open source changed; search results were refreshed.")
		alicorn.invalidate_root(rt, "Scratchpad rejected a stale open-document search result")
		return true
	}
	if editor_accessibility_document_has_pending_edit(app, document.id) {
		find_set_message(&app.workspace_search_error, "Wait for pending edits in this source to finish before editing its search result.")
		alicorn.invalidate_root(rt, "Scratchpad deferred a search projection while source edits were pending")
		return true
	}
	source_window := bridge.backend_command(
		&app.backend,
		"read_visible_lines",
		document_id=document.id,
		editor_revision=document.editor_revision,
		start_line=u64(result.line),
		anchor_byte=u64(result.context_start_byte),
		max_lines=1,
		max_bytes=bridge.MAX_VISIBLE_BYTES,
		source_instance=document.instance_id,
		allow_unversioned_read=true,
		read_latest_after=false,
	)
	if !source_window.ok {
		find_set_message(&app.workspace_search_error, source_window.message)
		bridge.backend_command_result_destroy(&source_window, context.allocator)
		alicorn.invalidate_root(rt, "Scratchpad could not validate bounded search source text")
		return true
	}
	defer bridge.backend_command_result_destroy(&source_window, context.allocator)
	window := source_window.visible_window
	context_start := result.context_start_byte-int(window.start_byte)
	context_end := context_start+len(result.text)
	if window.document_id != document.id || window.editor_revision != document.editor_revision ||
	   context_start < 0 || context_end > len(window.source) ||
	   string(window.source[context_start:context_end]) != result.text {
		workspace_search_start_query(app, rt, true)
		find_set_message(&app.workspace_search_error, "The source no longer matches this result; search results were refreshed.")
		alicorn.invalidate_root(rt, "Scratchpad rejected a stale bounded search projection context")
		return true
	}
	view_index, view_ok := app_editor_view_ensure(app, document.id)
	if !view_ok {
		find_set_message(&app.workspace_search_error, "Could not retain the source document's editor state.")
		return true
	}
	if app.editor_views[view_index].optimistic_pending_edits == 0 {
		app.editor_views[view_index].authoritative_revision = document.editor_revision
	}
	buffer, buffer_ok := alicorn.text_field_buffer_init(result.text, context.allocator)
	if !buffer_ok {
		find_set_message(&app.workspace_search_error, "Could not retain the bounded search-result text.")
		return true
	}
	source_text, text_error := strings.clone(result.text, context.allocator)
	if text_error != nil {
		alicorn.text_field_buffer_destroy(&buffer)
		find_set_message(&app.workspace_search_error, "Could not retain the source comparison for this result.")
		return true
	}
	owned_document_id, id_error := strings.clone(document.id, context.allocator)
	if id_error != nil {
		alicorn.text_field_buffer_destroy(&buffer)
		delete(source_text, context.allocator)
		find_set_message(&app.workspace_search_error, "Could not retain the source identity for this result.")
		return true
	}
	workspace_search_edit_clear(app)
	app.workspace_search_edit_active = true
	app.workspace_search_edit_buffer = buffer
	app.workspace_search_edit_source_text = source_text
	app.workspace_search_edit_document_id = owned_document_id
	app.workspace_search_edit_instance_id = document.instance_id
	app.workspace_search_edit_revision = document.editor_revision
	app.workspace_search_edit_context_start = u64(result.context_start_byte)
	app.workspace_search_edit_context_end = u64(result.context_end_byte)
	app.workspace_search_edit_match_start = result.start_byte-result.context_start_byte
	app.workspace_search_edit_match_end = result.end_byte-result.context_start_byte
	app.workspace_search_edit_initial_caret = initial_caret
	app.workspace_search_edit_place_caret_pending = initial_caret >= 0
	caret_byte := result.start_byte
	if initial_caret >= 0 {
		caret_byte = result.context_start_byte + min(max(initial_caret, 0), len(result.text))
	}
	app.workspace_search_edit_caret_byte = u64(max(caret_byte, 0))
	app.workspace_search_edit_generation = app.workspace_search_view.generation
	app.workspace_search_edit_projection_key = result.projection_key
	app.workspace_search_edit_index = result_index
	app.workspace_search_selected = result_index
	app.workspace_search_edit_focus_pending = true
	app.workspace_search_edit_select_match_pending = initial_caret < 0
	app.editor_focus_pending = false
	app.find_focus_pending = false
	app.workspace_search_focus_pending = false
	app.workspace_search_edit_ready = true
	find_set_message(&app.workspace_search_error, "")
	scratchpad_diagnostic_event("search.edit.activated", result.projection_key)
	alicorn.invalidate_root(rt, "Scratchpad opened a bounded editable search projection")
	return true
}

workspace_search_edit_validate_window :: proc(app: ^App, rt: ^alicorn.Runtime) -> bool {
	if app == nil || !app.workspace_search_edit_active { return false }
	if !workspace_search_edit_session_matches(app, app.workspace_search_edit_index) { return false }
	document, found := find_document(&app.backend.state, app.workspace_search_edit_document_id)
	if !found || document.instance_id != app.workspace_search_edit_instance_id || document.editor_revision != app.workspace_search_edit_revision {
		message := "The source changed before this result could be edited; search results were refreshed."
		workspace_search_edit_clear(app)
		if app.workspace_search_mode { workspace_search_start_query(app, rt, true) }
		find_set_message(&app.workspace_search_error, message)
		return false
	}
	if app.workspace_search_edit_ready { return true }
	if view_index := editor_view_find(app.editor_views[:], document.id); view_index >= 0 {
		view := &app.editor_views[view_index]
		window, exact := editor_view_window(view, &app.editor_window, app.editor_window_ready, document.id, document.editor_revision)
		if !exact { return false }
		window_end := window.start_byte+u64(len(window.source))
		if app.workspace_search_edit_context_start < window.start_byte || app.workspace_search_edit_context_end > window_end {
			find_set_message(&app.workspace_search_error, "The bounded source window does not contain the complete result context yet.")
			return false
		}
		start := int(app.workspace_search_edit_context_start-window.start_byte)
		end := int(app.workspace_search_edit_context_end-window.start_byte)
		if end < start || string(window.source[start:end]) != app.workspace_search_edit_source_text {
			message := "The source no longer matches this result; search results were refreshed."
			workspace_search_edit_clear(app)
			if app.workspace_search_mode { workspace_search_start_query(app, rt, true) }
			find_set_message(&app.workspace_search_error, message)
			return false
		}
		app.workspace_search_edit_ready = true
		find_set_message(&app.workspace_search_error, "")
		return true
	}
	return false
}

workspace_search_utf8_boundary :: proc(value: string, index: int) -> bool {
	return index <= 0 || index >= len(value) || (u8(value[index]) & 0xC0) != 0x80
}

workspace_search_edit_apply_change :: proc(app: ^App, rt: ^alicorn.Runtime) -> bool {
	if app == nil || rt == nil || !app.workspace_search_edit_active || !app.workspace_search_edit_ready ||
	   app.workspace_search_edit_node == 0 || !workspace_search_edit_session_matches(app, app.workspace_search_edit_index) { return false }
	interaction, interaction_found := alicorn.text_field_interaction(rt, app.workspace_search_edit_node)
	if !interaction_found || interaction.composition_active { return false }
	old_text := app.workspace_search_edit_source_text
	new_text := app.workspace_search_edit_buffer.text
	new_bytes := transmute([]u8)new_text
	if !editor_source_bytes_valid_utf8(new_bytes) || strings.contains(new_text, "\n") || strings.contains(new_text, "\r") {
		_ = alicorn.text_field_buffer_set(&app.workspace_search_edit_buffer, old_text)
		set_error(app, "A search-result edit must stay within its single UTF-8 source line.")
		alicorn.invalidate_root(rt, "Scratchpad rejected a cross-line or invalid search projection edit")
		return false
	}
	prefix := 0
	for prefix < len(old_text) && prefix < len(new_text) && old_text[prefix] == new_text[prefix] { prefix += 1 }
	for prefix > 0 && (!workspace_search_utf8_boundary(old_text, prefix) || !workspace_search_utf8_boundary(new_text, prefix)) { prefix -= 1 }
	suffix := 0
	for suffix < len(old_text)-prefix && suffix < len(new_text)-prefix &&
	    old_text[len(old_text)-suffix-1] == new_text[len(new_text)-suffix-1] { suffix += 1 }
	for suffix > 0 && (!workspace_search_utf8_boundary(old_text, len(old_text)-suffix) ||
	                    !workspace_search_utf8_boundary(new_text, len(new_text)-suffix)) { suffix -= 1 }
	if prefix == len(old_text) && prefix == len(new_text) { return true }
	if app.workspace_search_edit_context_end-app.workspace_search_edit_context_start != u64(len(old_text)) {
		set_error(app, "The search projection source range lost synchronization; no edit was sent.")
		return false
	}
	start_byte := app.workspace_search_edit_context_start+u64(prefix)
	end_byte := app.workspace_search_edit_context_start+u64(len(old_text)-suffix)
	caret := min(max(interaction.caret, 0), len(new_text))
	caret_byte := app.workspace_search_edit_context_start+u64(caret)
	new_source_text, clone_error := strings.clone(new_text, context.allocator)
	baseline_copy, baseline_error := strings.clone(new_text, context.allocator)
	if clone_error != nil || baseline_error != nil {
		if clone_error == nil { delete(new_source_text, context.allocator) }
		if baseline_error == nil { delete(baseline_copy, context.allocator) }
		_ = alicorn.text_field_buffer_set(&app.workspace_search_edit_buffer, old_text)
		set_error(app, "Could not retain the updated search-result source text.")
		return false
	}
	replacement := transmute([]u8)new_text[prefix:len(new_text)-suffix]
	if !editor_apply_local_replace_with_wire(
		app, rt, start_byte, end_byte, replacement, {}, caret_byte, caret_byte,
		allow_offscreen_authoritative=true,
	) {
		delete(new_source_text, context.allocator)
		_ = alicorn.text_field_buffer_set(&app.workspace_search_edit_buffer, old_text)
		return false
	}
	old_segment := transmute([]u8)old_text[prefix:len(old_text)-suffix]
	new_segment := transmute([]u8)new_text[prefix:len(new_text)-suffix]
	old_match_start := app.workspace_search_edit_context_start+u64(app.workspace_search_edit_match_start)
	old_match_end := app.workspace_search_edit_context_start+u64(app.workspace_search_edit_match_end)
	new_match_start := editor_rebase_replacement_position(old_match_start, app.workspace_search_edit_context_start+u64(prefix), old_segment, new_segment)
	new_match_end := editor_rebase_replacement_position(old_match_end, app.workspace_search_edit_context_start+u64(prefix), old_segment, new_segment)
	new_match_start = max(new_match_start, app.workspace_search_edit_context_start)
	new_match_end = max(new_match_end, new_match_start)
	result := &app.workspace_search_view.results[app.workspace_search_edit_index]
	if len(result.text) > 0 { delete(result.text, context.allocator) }
	result.text = new_source_text
	delta := i64(len(new_text))-i64(len(old_text))
	result.context_end_byte = int(i64(result.context_end_byte)+delta)
	result.start_byte = int(new_match_start)
	result.end_byte = int(new_match_end)
	app.workspace_search_edit_match_start = int(new_match_start-app.workspace_search_edit_context_start)
	app.workspace_search_edit_match_end = int(new_match_end-app.workspace_search_edit_context_start)
	app.workspace_search_edit_caret_byte = caret_byte
	if len(old_text) > 0 { delete(app.workspace_search_edit_source_text, context.allocator) }
	app.workspace_search_edit_source_text = baseline_copy
	app.workspace_search_edit_context_end = u64(i64(app.workspace_search_edit_context_end)+delta)
	app.workspace_search_edit_source_changed = true
	if rt != nil { alicorn.invalidate_root(rt, "Scratchpad queued an edit from a workspace search projection") }
	return true
}

workspace_search_edit_acknowledged :: proc(app: ^App, rt: ^alicorn.Runtime, intent: Editor_Edit_Intent, revision: u64) {
	if app == nil || !intent.workspace_search_edit || !app.workspace_search_edit_active ||
	   app.workspace_search_edit_document_id != intent.document_id { return }
	app.workspace_search_edit_revision = revision
	_ = rt
}

workspace_search_edit_finish_if_ready :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || !app.workspace_search_edit_active || !app.workspace_search_edit_finish_pending ||
	   workspace_search_edit_has_pending_intents(app) { return }
	_ = workspace_search_edit_finish(app, rt, refresh=true)
}

workspace_search_edit_failed :: proc(app: ^App, rt: ^alicorn.Runtime, intent: Editor_Edit_Intent) {
	if app == nil || !intent.workspace_search_edit { return }
	message := "The source rejected this edit because the search projection was stale. Results were refreshed."
	workspace_search_edit_clear(app)
	if app.workspace_search_mode && rt != nil { workspace_search_start_query(app, rt, true) }
	find_set_message(&app.workspace_search_error, message)
}

workspace_search_restore_selection_clear :: proc(app: ^App) {
	if app == nil { return }
	if len(app.workspace_search_restore_selection_path) > 0 {
		delete(app.workspace_search_restore_selection_path, context.allocator)
	}
	app.workspace_search_restore_selection_path = ""
	app.workspace_search_restore_selection_pending = false
	app.workspace_search_restore_selection_byte = 0
	app.workspace_search_restore_selection_index = -1
}

workspace_search_restore_selection_apply :: proc(app: ^App) -> bool {
	if app == nil || !app.workspace_search_restore_selection_pending { return false }
	best_index := -1
	best_distance: u64 = 0xFFFF_FFFF_FFFF_FFFF
	for result, index in app.workspace_search_view.results {
		if result.path != app.workspace_search_restore_selection_path { continue }
		result_byte := u64(max(result.start_byte, 0))
		distance := result_byte-app.workspace_search_restore_selection_byte if result_byte >= app.workspace_search_restore_selection_byte else app.workspace_search_restore_selection_byte-result_byte
		if best_index < 0 || distance < best_distance {
			best_index = index
			best_distance = distance
		}
	}
	if best_index >= 0 {
		selection_changed := app.workspace_search_selected != best_index
		app.workspace_search_selected = best_index
		if app.workspace_search_view.done { workspace_search_restore_selection_clear(app) }
		return selection_changed
	}
	if !app.workspace_search_view.done { return false }
	if len(app.workspace_search_view.results) > 0 {
		fallback := app.workspace_search_restore_selection_index
		if fallback < 0 { fallback = 0 }
		app.workspace_search_selected = min(fallback, len(app.workspace_search_view.results)-1)
	}
	workspace_search_restore_selection_clear(app)
	return true
}

find_refresh_if_needed :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || !app.backend.started { return }
	document, found := find_document(&app.backend.state, app.backend.state.active)
	if !found { return }
	view_index, view_ok := app_editor_view_ensure(app, document.id)
	if !view_ok { return }
	if app.find_presentation.document_id == document.id &&
	   app.find_presentation.editor_revision == document.editor_revision &&
	   app.find_presentation.query == app.find_query.text &&
	   app.find_presentation.match_case == app.find_match_case &&
	   app.find_presentation.whole_word == app.find_whole_word { return }

	view := &app.editor_views[view_index]
	source_cursor := view.caret_byte
	if app.find_presentation.document_id == document.id &&
	   app.find_presentation.query == app.find_query.text &&
	   app.find_presentation.active_match >= 0 &&
	   app.find_presentation.active_match < len(app.find_presentation.matches) {
		// When an option changes, keep the user's current result if it still
		// qualifies; otherwise select the next result at or after it.
		active := app.find_presentation.matches[app.find_presentation.active_match]
		if active.start >= 0 { source_cursor = u64(active.start) }
	}

	if len(app.find_query.text) > 0 {
		if len(app.find_query.text) > bridge.MAX_FIND_QUERY_BYTES {
			if find_presentation_install(&app.find_presentation, document.id, app.find_query.text,
			   app.find_match_case, app.find_whole_word, document.editor_revision, nil, false,
			   source_cursor) {
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
			query=app.find_query.text,
			max_matches=FIND_MAX_MATCHES,
			match_case=app.find_match_case,
			whole_word=app.find_whole_word,
			read_latest_after=false,
		)
		if response.ok {
			find_set_message(&app.find_error, "")
			if !find_presentation_install_result(
				&app.find_presentation,
				&response,
				document.id,
				app.find_query.text,
				app.find_match_case,
				app.find_whole_word,
				document.editor_revision,
				source_cursor,
			) {
				find_set_message(&app.find_error, "Could not retain the bounded Find matches.")
				return
			}
			if len(app.find_presentation.matches) > 0 { _ = find_apply_active_match(app, rt) }
			return
		} else {
			find_set_message(&app.find_error, response.message)
		}
		bridge.backend_command_result_destroy(&response, context.allocator)
	} else {
		find_set_message(&app.find_error, "")
	}
	if !find_presentation_install(
		&app.find_presentation,
		document.id,
		app.find_query.text,
		app.find_match_case,
		app.find_whole_word,
		document.editor_revision,
		nil,
		false,
		source_cursor,
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
			if text, found := alicorn.text_field_value(rt, app.find_query_node); found {
				_ = alicorn.set_text_selection(rt, app.find_query_node, 0, len(text))
			}
		}
		app.find_focus_pending = false
		app.find_select_query_pending = false
		app.workspace_search_focus_pending = false
		app.editor_focus_pending = false
	} else if app.workspace_search_edit_focus_pending && app.workspace_search_edit_node != 0 {
		if alicorn.focus(rt, app.workspace_search_edit_node) {
			position_applied := true
			if app.workspace_search_edit_place_caret_pending {
				position_applied = alicorn.set_text_caret(rt, app.workspace_search_edit_node, app.workspace_search_edit_initial_caret)
				if position_applied { app.workspace_search_edit_place_caret_pending = false }
			} else if app.workspace_search_edit_select_match_pending {
				_ = alicorn.set_text_selection(rt, app.workspace_search_edit_node,
					app.workspace_search_edit_match_start, app.workspace_search_edit_match_end)
				app.workspace_search_edit_select_match_pending = false
			}
			if position_applied {
				app.workspace_search_edit_focus_pending = false
				app.workspace_search_focus_pending = false
				app.find_focus_pending = false
				app.editor_focus_pending = false
			}
		}
	} else if app.workspace_search_focus_pending && app.workspace_search_query_node != 0 {
		_ = alicorn.focus(rt, app.workspace_search_query_node)
		app.workspace_search_focus_pending = false
		app.find_focus_pending = false
		app.editor_focus_pending = false
	} else if app.editor_focus_pending {
		// Some deferred actions switch presentation modes after the current
		// frame has described its tree. Keep the request pending until the next
		// frame emits the editor's focus target instead of consuming it while
		// that target is temporarily absent.
		if app.editor_scroll_owner != 0 && alicorn.focus(rt, app.editor_scroll_owner) {
			app.editor_focus_pending = false
		}
	}
}

workspace_search_start_query :: proc(app: ^App, rt: ^alicorn.Runtime, force := false) {
	if app == nil || !app.backend.started { return }
	root := app.backend.state.workspace_root
	if !app.backend.state.has_workspace { return }
	query_changed := app.workspace_search_started_query != app.workspace_search_query || app.workspace_search_started_root != root
	if app.workspace_search_edit_active && (force || query_changed) {
		if !workspace_search_edit_finish(app, rt, refresh=false, preserve_selection=!query_changed) { return }
	}
	if query_changed { workspace_search_restore_selection_clear(app) }
	if !force && app.workspace_search_started_query == app.workspace_search_query &&
	   app.workspace_search_started_root == root { return }
	workspace_search_match_clear_all(app)
	old_generation := app.workspace_search_view.generation
	next_generation := max(app.workspace_search_generation, app.backend.state.workspace_search_generation)+1
	if next_generation == 0 { next_generation = 1 }
	app.workspace_search_generation = next_generation
	scratchpad_diagnostic_event("search.query.refresh", next_generation)
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
	if !state.workspace_search_page_available || state.workspace_search_sequence <= view.last_sequence {
		if workspace_search_restore_selection_apply(app) { alicorn.invalidate_root(rt, "Scratchpad restored the active search result after a query refresh") }
		return false
	}
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
	if workspace_search_restore_selection_apply(app) { alicorn.invalidate_root(rt, "Scratchpad restored the active search result after a query refresh") }
	return accepted
}

workspace_search_go_to_source :: proc(app: ^App, rt: ^alicorn.Runtime, result_index: int) -> bool {
	if app == nil || rt == nil || result_index < 0 || result_index >= len(app.workspace_search_view.results) { return false }
	if app.ui_description_runtime != nil {
		workspace_search_transition_request(app, rt, .Source, result_index)
		return true
	}
	refresh_after_navigation := app.workspace_search_edit_active && app.workspace_search_edit_source_changed
	target_byte: i64 = -1
	if app.workspace_search_edit_active && app.workspace_search_edit_source_changed &&
	   result_index == app.workspace_search_edit_index {
		target_byte = i64(app.workspace_search_edit_caret_byte)
	}
	if app.workspace_search_edit_active && !workspace_search_edit_finish(app, rt, refresh=false) { return true }
	activated := workspace_search_activate_result(app, rt, result_index, target_byte)
	// Source navigation leaves the Search tab open. Refresh changed excerpts
	// even after activating the source editor, so returning cannot show old ranges.
	if refresh_after_navigation { workspace_search_start_query(app, rt, true) }
	return activated
}

workspace_search_activate_result :: proc(app: ^App, rt: ^alicorn.Runtime, result_index: int, target_byte: i64 = -1) -> bool {
	if app == nil || rt == nil || !app.backend.started || result_index < 0 ||
	   result_index >= len(app.workspace_search_view.results) || !app.backend.state.has_workspace { return false }
	result := app.workspace_search_view.results[result_index]
	open_byte := u64(max(result.start_byte, 0))
	if target_byte >= 0 { open_byte = u64(target_byte) }
	path, path_error := os.join_path({app.backend.state.workspace_root, result.path}, context.temp_allocator)
	if path_error != nil {
		find_set_message(&app.workspace_search_error, "Could not resolve the selected workspace result path.")
		alicorn.invalidate_root(rt, "Scratchpad could not resolve a workspace search result path")
		return true
	}
	workspace_search_match_clear_all(app)
	response := bridge.backend_command(
		&app.backend,
		"open_path",
		path=path,
		has_target_byte=true,
		target_byte=open_byte,
	)
	if response.ok {
		app.find_open = false
		app.find_query_node = 0
		find_discard_saved_selection(app)
		if app.workspace_search_mode { _ = workspace_search_deactivate(app, rt) }
		app.editor_focus_pending = true
		handle_command_result(app, rt, &response)
		if response.editor_selection.document_id != "" {
			editor_apply_backend_selection(app, rt, response.editor_selection)
			if target_byte < 0 && result.start_byte >= 0 && result.end_byte > result.start_byte && result.line >= 0 {
				view_index, view_ok := app_editor_view_ensure(app, response.editor_selection.document_id)
				if view_ok {
					view := &app.editor_views[view_index]
					document, document_found := find_document(&app.backend.state, response.editor_selection.document_id)
					if document_found {
						view.workspace_search_match_active = true
						view.workspace_search_match_start = u64(result.start_byte)
						view.workspace_search_match_end = u64(result.end_byte)
						view.workspace_search_match_revision = document.editor_revision
						_ = editor_reveal_request_set(
							view,
							document.id,
							document.editor_revision,
							u64(result.start_byte),
							u64(result.end_byte),
							u64(result.line),
							.Center_When_Needed,
						)
					}
				}
			}
		}
	} else {
		find_set_message(&app.workspace_search_error, response.message)
		alicorn.invalidate_root(rt, "Scratchpad could not open the selected search result")
	}
	bridge.backend_command_result_destroy(&response, context.allocator)
	return true
}
