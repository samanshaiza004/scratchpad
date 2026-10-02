package main

import "core:fmt"
import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"
import bridge "./bridge"

application_menu_command :: proc(state: rawptr, rt: ^alicorn.Runtime, command: host.Application_Command_ID) {
	app := cast(^App)state
	if command == action_id_for(ACTION_VIEW_COMMAND_PALETTE) { command_palette_open_surface(app, rt); return }
	if command == action_id_for(ACTION_DOCUMENT_GO_TO_LINE) { go_to_line_open_surface(app, rt); return }
	if command == action_id_for(ACTION_DOCUMENT_TOGGLE_WRAP) { editor_toggle_wrap_mode(app, rt); return }
	if command == action_id_for(ACTION_WORKSPACE_NEW_FILE) { dispatch_action(app, rt, ACTION_WORKSPACE_NEW_FILE); return }
	if command == action_id_for(ACTION_WORKSPACE_NEW_FOLDER) { dispatch_action(app, rt, ACTION_WORKSPACE_NEW_FOLDER); return }
	if command == action_id_for(ACTION_WORKSPACE_SETTINGS) { dispatch_action(app, rt, ACTION_WORKSPACE_SETTINGS); return }
	if command == action_id_for(ACTION_EDIT_CUT) { editor_clipboard_command(app, rt, ACTION_EDIT_CUT); return }
	if command == action_id_for(ACTION_EDIT_COPY) { editor_clipboard_command(app, rt, ACTION_EDIT_COPY); return }
	if command == action_id_for(ACTION_EDIT_PASTE) { editor_clipboard_command(app, rt, ACTION_EDIT_PASTE); return }
	if command == action_id_for(ACTION_EDIT_SELECT_ALL) { editor_clipboard_command(app, rt, ACTION_EDIT_SELECT_ALL); return }
	for action in app.backend.state.actions {
		if action_id_for(action.id) == command {
			dispatch_action(app, rt, action.id)
			return
		}
	}
}

editor_toggle_wrap_mode :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil || !app.backend.started { return }
	document, found := find_document(&app.backend.state, app.backend.state.active)
	if !found { return }
	view_index, view_ok := editor_view_ensure(&app.editor_views, document.id)
	if !view_ok { set_error(app, "Could not retain this document's wrap preference."); return }
	view := &app.editor_views[view_index]
	switch view.wrap_mode {
	case .Auto: view.wrap_mode = .On
	case .On: view.wrap_mode = .Off
	case .Off: view.wrap_mode = .Auto
	}
	view.wrap_measurement_width = -1
	alicorn.invalidate_root(rt, "Scratchpad per-document word-wrap preference changed")
}

editor_resolve_conflict :: proc(app: ^App, rt: ^alicorn.Runtime, document_id: string, keep_mine: bool) {
	if app == nil || rt == nil || document_id == "" { return }
	if len(app.editor_edits) > 0 {
		kind := Deferred_Action_Kind.Conflict_Reload
		if keep_mine { kind = .Conflict_Keep_Mine }
		if !deferred_action_enqueue(app, kind, value=document_id) {
			set_error(app, "Could not queue conflict resolution behind pending edits.")
		}
		alicorn.invalidate_root(rt, "Scratchpad conflict resolution queued behind pending edits")
		return
	}
	editor_resolve_conflict_now(app, rt, document_id, keep_mine)
}

editor_resolve_conflict_now :: proc(app: ^App, rt: ^alicorn.Runtime, document_id: string, keep_mine: bool) {
	command := "reload_conflict"
	if keep_mine { command = "keep_mine_conflict" }
	response := bridge.backend_command(&app.backend, command, document_id=document_id)
	handle_command_result(app, rt, &response)
	bridge.backend_command_result_destroy(&response, context.allocator)
	deferred_actions_run(app, rt)
}

dispatch_action :: proc(app: ^App, rt: ^alicorn.Runtime, action_id: string) {
	if app == nil || !app.backend.started { return }
	if action_id == ACTION_FILE_QUICK_OPEN {
		quick_open_open_surface(app, rt)
		return
	}
	if action_id == ACTION_EDIT_PASTE {
		editor_clipboard_command(app, rt, action_id)
		return
	}
	switch action_id {
	case ACTION_WORKSPACE_NEW_FILE:
		workspace_mutation_open_create(app, rt, .Create_File)
		return
	case ACTION_WORKSPACE_NEW_FOLDER:
		workspace_mutation_open_create(app, rt, .Create_Folder)
		return
	case ACTION_WORKSPACE_SETTINGS:
		app.settings_surface_open = true
		alicorn.invalidate_root(rt, "Scratchpad Settings opened")
		return
	}
	if editor_active_preedit(app) && (action_id == ACTION_EDIT_UNDO || action_id == ACTION_EDIT_REDO) {
		set_error(app, "Finish or cancel the active text composition before using Undo or Redo.")
		alicorn.invalidate_root(rt, "Scratchpad history command refused during IME composition")
		return
	}
	if len(app.editor_edits) > 0 && (action_id == ACTION_EDIT_UNDO || action_id == ACTION_EDIT_REDO) {
		// The current published action state can still say disabled while a
		// local edit is waiting for acknowledgement. Queue history navigation
		// behind that edit so the refreshed state decides whether it is enabled.
		if !deferred_action_enqueue(app, .Action, value=action_id) {
			set_error(app, "Could not queue Undo/Redo behind pending editor edits.")
		}
		alicorn.invalidate_root(rt, "Scratchpad history action queued behind pending editor edits")
		return
	}
	entry, found := find_action(&app.backend.state, action_id)
	if !found || !entry.visible { return }
	markdown_selection_command := action_id == ACTION_DOCUMENT_FORMAT ||
	                     action_id == ACTION_ITEM_TOGGLE ||
	                     action_id == ACTION_MARKDOWN_TOGGLE_STRONG ||
	                     action_id == ACTION_MARKDOWN_TOGGLE_EMPHASIS ||
	                     action_id == ACTION_MARKDOWN_TOGGLE_STRIKE ||
	                     action_id == ACTION_MARKDOWN_TOGGLE_INLINE_CODE ||
	                     action_id == ACTION_MARKDOWN_INSERT_LINK ||
	                     action_id == ACTION_MARKDOWN_HEADING_1 ||
	                     action_id == ACTION_MARKDOWN_HEADING_2 ||
	                     action_id == ACTION_MARKDOWN_HEADING_3 ||
	                     action_id == ACTION_MARKDOWN_TOGGLE_BULLETED_LIST ||
	                     action_id == ACTION_MARKDOWN_TOGGLE_NUMBERED_LIST ||
	                     action_id == ACTION_MARKDOWN_TOGGLE_QUOTE ||
	                     action_id == ACTION_MARKDOWN_INSERT_TASK ||
	                     action_id == ACTION_MARKDOWN_INSERT_CODE_BLOCK ||
	                     action_id == ACTION_MARKDOWN_SET_FENCE_LANGUAGE ||
	                     action_id == ACTION_MARKDOWN_INSERT_TABLE ||
	                     action_id == ACTION_MARKDOWN_INSERT_DIVIDER ||
	                     action_id == ACTION_MARKDOWN_TABLE_NEXT ||
	                     action_id == ACTION_MARKDOWN_TABLE_PREVIOUS ||
	                     action_id == ACTION_MARKDOWN_TABLE_ENTER
	if markdown_selection_command {
		document, document_found := find_document(&app.backend.state, app.backend.state.active)
		if !document_found || document.language != "markdown" { return }
	} else if !entry.enabled {
		return
	}
	if len(app.editor_edits) > 0 {
		if !deferred_action_enqueue(app, .Action, value=action_id) {
			set_error(app, "Could not queue the command behind pending editor edits.")
		}
		alicorn.invalidate_root(rt, "Scratchpad command queued behind editor edits")
		return
	}
	if document, found := find_document(&app.backend.state, app.backend.state.active); found {
		if view_index := editor_view_find(app.editor_views[:], document.id); view_index >= 0 {
			editor_undo_group_break(&app.editor_views[view_index])
		}
	}
	command_token := action_id_for(action_id)
	cause := alicorn.cause_begin(rt, .Application, "Scratchpad semantic action", command_token)
	alicorn.trace_action(rt, command_token, entry.title)
	switch action_id {
	case ACTION_FILE_OPEN:
		request_file_dialog(app, rt, .Open_File, "Open File")
	case ACTION_FILE_SAVE_AS:
		if app.backend.state.active != "" {
			request_file_dialog(app, rt, .Save_File, "Save As")
		}
	case ACTION_WORKSPACE_OPEN:
		request_file_dialog(app, rt, .Open_Folder, "Open Folder")
	case ACTION_FILE_SAVE:
		if app.backend.state.active != "" {
			response := bridge.backend_command(&app.backend, "save_document", document_id=app.backend.state.active)
			handle_command_result(app, rt, &response)
			bridge.backend_command_result_destroy(&response, context.allocator)
		}
	case ACTION_EDIT_UNDO, ACTION_EDIT_REDO:
		previous_editor_revision: u64 = 0
		if document, found := find_document(&app.backend.state, app.backend.state.active); found {
			previous_editor_revision = document.editor_revision
		}
		response := bridge.backend_command(&app.backend, action_id, document_id=app.backend.state.active)
		handle_command_result(app, rt, &response)
		if response.ok && response.editor_selection.editor_revision != 0 &&
		   response.editor_selection.editor_revision != previous_editor_revision {
			if view_index := editor_view_find(app.editor_views[:], response.editor_selection.document_id); view_index >= 0 {
				view := &app.editor_views[view_index]
				view.viewport_anchor_skip_next_source_change = true
				view.viewport_anchor_pending = false
				view.viewport_anchor_resolved = false
			}
		}
		if response.ok && response.editor_selection.document_id != "" {
			editor_apply_backend_selection(app, rt, response.editor_selection)
		}
		bridge.backend_command_result_destroy(&response, context.allocator)
	case ACTION_DOCUMENT_FORMAT, ACTION_MARKDOWN_TOGGLE_STRONG, ACTION_MARKDOWN_TOGGLE_EMPHASIS,
		 ACTION_MARKDOWN_TOGGLE_STRIKE, ACTION_MARKDOWN_TOGGLE_INLINE_CODE, ACTION_MARKDOWN_INSERT_LINK,
		 ACTION_MARKDOWN_HEADING_1, ACTION_MARKDOWN_HEADING_2, ACTION_MARKDOWN_HEADING_3,
		 ACTION_MARKDOWN_TOGGLE_BULLETED_LIST, ACTION_MARKDOWN_TOGGLE_NUMBERED_LIST, ACTION_MARKDOWN_TOGGLE_QUOTE,
		 ACTION_MARKDOWN_INSERT_TASK, ACTION_MARKDOWN_INSERT_CODE_BLOCK, ACTION_MARKDOWN_SET_FENCE_LANGUAGE,
		 ACTION_MARKDOWN_INSERT_TABLE, ACTION_MARKDOWN_INSERT_DIVIDER, ACTION_MARKDOWN_SMART_PASTE,
		 ACTION_EDIT_DELETE_LINE,
		 ACTION_EDIT_INDENT_LINES, ACTION_EDIT_OUTDENT_LINES, ACTION_EDIT_INSERT_LINE_ABOVE,
		 ACTION_EDIT_INSERT_LINE_BELOW, ACTION_EDIT_MOVE_LINE_UP, ACTION_EDIT_MOVE_LINE_DOWN,
		 ACTION_EDIT_DUPLICATE_LINE, ACTION_EDIT_JOIN_LINES, ACTION_COMMENT_TOGGLE,
		 ACTION_MARKDOWN_TABLE_NEXT, ACTION_MARKDOWN_TABLE_PREVIOUS, ACTION_MARKDOWN_TABLE_ENTER:
		document, found := find_document(&app.backend.state, app.backend.state.active)
		if !found { break }
		view_index, view_ok := editor_view_ensure(&app.editor_views, document.id)
		if !view_ok {
			set_error(app, "Could not retain the active editor selection for the command.")
			break
		}
		view := &app.editor_views[view_index]
		clipboard_text := ""
		if action_id == ACTION_MARKDOWN_SMART_PASTE {
			text, clipboard_ok := host.ClipboardGetText(app.services.clipboard, allocator=context.allocator)
			if !clipboard_ok {
				set_error(app, "Could not read text from the system clipboard.")
				alicorn.invalidate_root(rt, "Scratchpad smart paste clipboard read failed")
				break
			}
			defer delete(text, context.allocator)
			if len(text) > int(bridge.MAX_EDIT_BYTES) {
				set_error(app, "Clipboard text exceeds the 128 KiB per-edit limit.")
				alicorn.invalidate_root(rt, "Scratchpad rejected oversized Markdown smart paste")
				break
			}
			clipboard_text = string(text)
		}
		response := bridge.backend_command(
			&app.backend,
			"execute_command",
			action_id=action_id,
			argument=clipboard_text,
			document_id=document.id,
			editor_revision=document.editor_revision,
			editor_anchor_byte=view.selection_anchor,
			editor_cursor_byte=view.caret_byte,
		)
		handle_command_result(app, rt, &response)
		if action_id == ACTION_DOCUMENT_FORMAT && response.ok &&
		   response.editor_selection.editor_revision != 0 && response.editor_selection.editor_revision != document.editor_revision {
			view.viewport_anchor_skip_next_source_change = true
			view.viewport_anchor_pending = false
			view.viewport_anchor_resolved = false
		}
		if action_id == ACTION_DOCUMENT_FORMAT && response.ok && response.command_outcome == "no_op" {
			set_error(app, "Table is already aligned.")
			alicorn.invalidate_root(rt, "Scratchpad reported an unchanged table format")
		}
		if response.ok && response.editor_selection.document_id != "" {
			selection_only := response.command_outcome == "selection_only"
			editor_apply_backend_selection(app, rt, response.editor_selection, selection_only)
		}
		bridge.backend_command_result_destroy(&response, context.allocator)
	case ACTION_DOCUMENT_CLOSE:
		request_close_document(app, rt, app.backend.state.active)
	case ACTION_TAB_NEXT:
		navigate_tab(app, rt, 1)
	case ACTION_TAB_PREVIOUS:
		navigate_tab(app, rt, -1)
	case ACTION_WORKSPACE_REFRESH:
		response := bridge.backend_command(&app.backend, "refresh_workspace", include_ignored=app.show_ignored_files)
		if response.ok {
			quick_open_invalidate_index(app)
			tree_clear_directories(app)
			if response.directory_listing_owned {
				if !tree_store_listing(app, response.directory_listing, true) { set_error(app, "Could not retain the refreshed workspace listing.") }
			} else {
				set_error(app, "Scratchpad did not return the refreshed workspace listing.")
			}
			sync_runtime_actions(app, rt)
			sync_menu_states(app)
			alicorn.invalidate_root(rt, "Scratchpad workspace refreshed")
		} else {
			handle_command_result(app, rt, &response)
		}
		bridge.backend_command_result_destroy(&response, context.allocator)
	case:
		set_error(app, fmt.tprintf("Action %s is not available in the Alicorn shell yet", action_id))
		alicorn.invalidate_root(rt, "unavailable Scratchpad action")
	}
	alicorn.cause_end(rt, cause)
}

sync_runtime_actions :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil { return }
	composition_active := editor_active_preedit(app)
	for action in app.backend.state.actions {
		if action.id == "" || action.title == "" { continue }
		enabled := action.enabled
		if action.id == ACTION_DOCUMENT_FORMAT {
			enabled = false
			if document, found := find_document(&app.backend.state, app.backend.state.active); found {
				enabled = document.language == "markdown"
			}
		}
		if action.id == ACTION_EDIT_UNDO && editor_has_pending_active_document_edit(app) { enabled = true }
		if composition_active && (action.id == ACTION_EDIT_UNDO || action.id == ACTION_EDIT_REDO) { enabled = false }
		accepted := alicorn.action_update(rt,
			alicorn.Action_Descriptor{id=action_id_for(action.id), name=action.id, label=action.title},
			alicorn.Action_State{enabled=enabled, checked=action.checked},
		)
		if !accepted { set_error(app, fmt.tprintf("Alicorn rejected action metadata for %s", action.id)) }
	}
}

sync_menu_states :: proc(app: ^App) {
	if app == nil { return }
	composition_active := editor_active_preedit(app)
	for &item in app.file_items {
		if item.kind != .Command { continue }
		item.state = menu_action_state(&app.backend.state, item.command)
	}
	for &item in app.workspace_items {
		if item.kind != .Command { continue }
		switch {
		case item.command == action_id_for(ACTION_WORKSPACE_NEW_FILE), item.command == action_id_for(ACTION_WORKSPACE_NEW_FOLDER):
			item.state = alicorn.Action_State{enabled=app.backend.started && app.backend.state.has_workspace}
		case item.command == action_id_for(ACTION_WORKSPACE_SETTINGS):
			item.state = alicorn.Action_State{enabled=true}
		case:
			item.state = menu_action_state(&app.backend.state, item.command)
		}
	}
	for &item in app.document_items {
		if item.kind != .Command { continue }
		item.state = menu_action_state(&app.backend.state, item.command)
	}
	active_document, has_document := find_document(&app.backend.state, app.backend.state.active)
	for &item in app.document_items {
		if item.kind == .Command && item.command == action_id_for(ACTION_DOCUMENT_FORMAT) {
			item.state.enabled = has_document && active_document.language == "markdown"
		} else if item.kind == .Command && item.command == action_id_for(ACTION_DOCUMENT_GO_TO_LINE) {
			item.state.enabled = has_document
		} else if item.kind == .Command && item.command == action_id_for(ACTION_DOCUMENT_TOGGLE_WRAP) {
			item.state.enabled = has_document
		}
	}
	active_view: ^Editor_View_State
	active_window: ^Editor_Window
	window_matches := false
	if has_document {
		if view_index := editor_view_find(app.editor_views[:], active_document.id); view_index >= 0 {
			active_view = &app.editor_views[view_index]
			active_window, window_matches = editor_view_window(
				active_view,
				&app.editor_window,
				app.editor_window_ready,
				active_document.id,
				active_document.editor_revision,
			)
		}
	}
	selection_nonempty := active_view != nil && active_view.selection_anchor != active_view.caret_byte
	selection_available := false
	if selection_nonempty && window_matches {
		_, selection_available = editor_selected_source_bytes(active_window, active_view.selection_anchor, active_view.caret_byte)
		if selection_available {
			selected_bytes, _ := editor_selected_source_bytes(active_window, active_view.selection_anchor, active_view.caret_byte)
			selection_available = editor_source_bytes_valid_utf8(selected_bytes)
		}
	}
	for &item in app.edit_items {
		if item.kind != .Command { continue }
		switch string_for_action_id(item.command) {
		case ACTION_EDIT_UNDO:
			item.state = menu_action_state(&app.backend.state, item.command)
			if editor_has_pending_active_document_edit(app) { item.state.enabled = true }
		case ACTION_EDIT_REDO:
			item.state = menu_action_state(&app.backend.state, item.command)
		case ACTION_EDIT_COPY:
			item.state = alicorn.Action_State{enabled=selection_nonempty && selection_available}
		case ACTION_EDIT_CUT:
			item.state = alicorn.Action_State{enabled=selection_nonempty && selection_available}
		case ACTION_EDIT_PASTE:
			paste_range_available := false
			if active_view != nil && window_matches {
				start_byte := min(active_view.selection_anchor, active_view.caret_byte)
				end_byte := max(active_view.selection_anchor, active_view.caret_byte)
				window_end := active_window.start_byte+u64(len(active_window.source))
				paste_range_available = start_byte >= active_window.start_byte && end_byte <= window_end
			}
			item.state = alicorn.Action_State{enabled=has_document && paste_range_available && app.services.clipboard.get_text != nil}
		case ACTION_EDIT_SELECT_ALL:
			item.state = alicorn.Action_State{enabled=has_document && editor_current_byte_length(app, active_document) > 0}
		case ACTION_EDIT_DELETE_LINE:
			item.state = alicorn.Action_State{enabled=has_document}
		}
		if composition_active {
			switch string_for_action_id(item.command) {
			case ACTION_EDIT_UNDO, ACTION_EDIT_REDO, ACTION_EDIT_CUT, ACTION_EDIT_PASTE, ACTION_EDIT_SELECT_ALL:
				item.state.enabled = false
			case ACTION_EDIT_COPY:
				item.state = alicorn.Action_State{enabled=active_view != nil && len(active_view.preedit_text) > 0 && app.services.clipboard.set_text != nil}
			}
		}
	}
}

string_for_action_id :: proc(id: host.Application_Command_ID) -> string {
	if id == action_id_for(ACTION_EDIT_UNDO) { return ACTION_EDIT_UNDO }
	if id == action_id_for(ACTION_EDIT_REDO) { return ACTION_EDIT_REDO }
	if id == action_id_for(ACTION_EDIT_CUT) { return ACTION_EDIT_CUT }
	if id == action_id_for(ACTION_EDIT_COPY) { return ACTION_EDIT_COPY }
	if id == action_id_for(ACTION_EDIT_PASTE) { return ACTION_EDIT_PASTE }
	if id == action_id_for(ACTION_EDIT_SELECT_ALL) { return ACTION_EDIT_SELECT_ALL }
	if id == action_id_for(ACTION_EDIT_DELETE_LINE) { return ACTION_EDIT_DELETE_LINE }
	return ""
}

menu_action_state :: proc(state: ^bridge.State_Envelope, id: host.Application_Command_ID) -> alicorn.Action_State {
	for action in state.actions {
		if action_id_for(action.id) == id { return alicorn.Action_State{enabled=action.visible && action.enabled, checked=action.checked} }
	}
	return alicorn.Action_State{}
}

action_enabled :: proc(state: ^bridge.State_Envelope, id: string) -> bool {
	for action in state.actions {
		if action.id == id { return action.visible && action.enabled }
	}
	return false
}

find_action :: proc(state: ^bridge.State_Envelope, id: string) -> (action: bridge.Action_State, found: bool) {
	for action in state.actions { if action.id == id { return action, true } }
	return
}

action_id_for :: proc(name: string) -> host.Application_Command_ID {
	hash: u32 = 2_166_136_261
	for character in name {
		hash = (hash ~ u32(character)) * 16_777_619
	}
	if hash == 0 { hash = 1 }
	return host.Application_Command_ID(hash)
}

init_menus :: proc(app: ^App) {
	app.file_items = [7]host.Application_Menu_Item{
		{kind=.Command, command=action_id_for(ACTION_FILE_OPEN), label="Open File…", state=alicorn.Action_State{enabled=true}, shortcut=host.Application_Menu_Shortcut{'O', {.Primary}}},
		{kind=.Command, command=action_id_for(ACTION_FILE_QUICK_OPEN), label="Quick Open…", state=alicorn.Action_State{enabled=true}, shortcut=host.Application_Menu_Shortcut{'P', {.Primary}}},
		{kind=.Command, command=action_id_for(ACTION_WORKSPACE_OPEN), label="Open Folder…", state=alicorn.Action_State{enabled=true}},
		{kind=.Separator},
		{kind=.Command, command=action_id_for(ACTION_FILE_SAVE), label="Save", shortcut=host.Application_Menu_Shortcut{'S', {.Primary}}},
		{kind=.Command, command=action_id_for(ACTION_FILE_SAVE_AS), label="Save As…", shortcut=host.Application_Menu_Shortcut{'S', {.Primary, .Shift}}},
		{kind=.Command, command=action_id_for(ACTION_DOCUMENT_CLOSE), label="Close Document", shortcut=host.Application_Menu_Shortcut{'W', {.Primary}}},
	}
	app.edit_items = [10]host.Application_Menu_Item{
		{kind=.Command, command=action_id_for(ACTION_EDIT_UNDO), label="Undo", shortcut=host.Application_Menu_Shortcut{'Z', {.Primary}}},
		{kind=.Command, command=action_id_for(ACTION_EDIT_REDO), label="Redo", shortcut=host.Application_Menu_Shortcut{'Z', {.Primary, .Shift}}},
		{kind=.Separator},
		{kind=.Command, command=action_id_for(ACTION_EDIT_CUT), label="Cut", shortcut=host.Application_Menu_Shortcut{'X', {.Primary}}},
		{kind=.Command, command=action_id_for(ACTION_EDIT_COPY), label="Copy", shortcut=host.Application_Menu_Shortcut{'C', {.Primary}}},
		{kind=.Command, command=action_id_for(ACTION_EDIT_PASTE), label="Paste", shortcut=host.Application_Menu_Shortcut{'V', {.Primary}}},
		{kind=.Separator},
		{kind=.Command, command=action_id_for(ACTION_EDIT_SELECT_ALL), label="Select All", shortcut=host.Application_Menu_Shortcut{'A', {.Primary}}},
		{kind=.Separator},
		{kind=.Command, command=action_id_for(ACTION_EDIT_DELETE_LINE), label="Delete Line", shortcut=host.Application_Menu_Shortcut{'K', {.Primary, .Shift}}},
	}
	app.workspace_items = [6]host.Application_Menu_Item{
		{kind=.Command, command=action_id_for(ACTION_WORKSPACE_NEW_FILE), label="New File"},
		{kind=.Command, command=action_id_for(ACTION_WORKSPACE_NEW_FOLDER), label="New Folder"},
		{kind=.Separator},
		{kind=.Command, command=action_id_for(ACTION_WORKSPACE_REFRESH), label="Refresh Workspace", shortcut=host.Application_Menu_Shortcut{'R', {.Primary, .Shift}}},
		{kind=.Separator},
		{kind=.Command, command=action_id_for(ACTION_WORKSPACE_SETTINGS), label="Settings…"},
	}
	app.document_items = [11]host.Application_Menu_Item{
		{kind=.Command, command=action_id_for(ACTION_TAB_NEXT), label="Next Document"},
		{kind=.Command, command=action_id_for(ACTION_TAB_PREVIOUS), label="Previous Document"},
		{kind=.Separator},
		{kind=.Command, command=action_id_for(ACTION_DOCUMENT_FORMAT), label="Format Table"},
		{kind=.Command, command=action_id_for(ACTION_DOCUMENT_GO_TO_LINE), label="Go to Line…", shortcut=host.Application_Menu_Shortcut{'G', {.Primary}}},
		{kind=.Command, command=action_id_for(ACTION_DOCUMENT_TOGGLE_WRAP), label="Cycle Word Wrap"},
		{kind=.Separator},
		{kind=.Command, command=action_id_for(ACTION_MARKDOWN_TOGGLE_STRONG), label="Strong", shortcut=host.Application_Menu_Shortcut{'B', {.Primary}}},
		{kind=.Command, command=action_id_for(ACTION_MARKDOWN_TOGGLE_EMPHASIS), label="Emphasis", shortcut=host.Application_Menu_Shortcut{'I', {.Primary}}},
		{kind=.Command, command=action_id_for(ACTION_MARKDOWN_TOGGLE_INLINE_CODE), label="Inline Code"},
		{kind=.Command, command=action_id_for(ACTION_MARKDOWN_INSERT_TASK), label="Task Checkbox"},
	}
	app.view_items = [1]host.Application_Menu_Item{
		{kind=.Command, command=action_id_for(ACTION_VIEW_COMMAND_PALETTE), label="Command Palette…", state=alicorn.Action_State{enabled=true}, shortcut=host.Application_Menu_Shortcut{'P', {.Primary, .Shift}}},
	}
	app.menus = [5]host.Application_Menu{
		{label="File", items=app.file_items[:]},
		{label="Edit", items=app.edit_items[:]},
		{label="Workspace", items=app.workspace_items[:]},
		{label="Document", items=app.document_items[:]},
		{label="View", items=app.view_items[:]},
	}
}
