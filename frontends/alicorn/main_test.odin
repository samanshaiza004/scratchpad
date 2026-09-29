package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"
import bridge "./bridge"

Editor_Test_Clipboard :: struct {
	text:      string,
	last_write: string,
	reads:     int,
	writes:    int,
	read_ok:   bool,
	write_ok:  bool,
}

editor_test_clipboard_get_text :: proc(data: rawptr, allocator: mem.Allocator) -> (text: string, ok: bool) {
	clipboard := cast(^Editor_Test_Clipboard)data
	if clipboard == nil { return "", false }
	clipboard.reads += 1
	if !clipboard.read_ok { return "", false }
	cloned, clone_error := strings.clone(clipboard.text, allocator)
	return cloned, clone_error == nil
}

editor_test_clipboard_set_text :: proc(data: rawptr, text: string) -> bool {
	clipboard := cast(^Editor_Test_Clipboard)data
	if clipboard == nil || !clipboard.write_ok { return false }
	if len(clipboard.last_write) > 0 { delete(clipboard.last_write, context.temp_allocator) }
	cloned, clone_error := strings.clone(text, context.temp_allocator)
	if clone_error != nil { return false }
	clipboard.last_write = cloned
	clipboard.writes += 1
	return true
}

editor_test_render_scroll_list :: proc(rt: ^alicorn.Runtime, count: int) -> alicorn.Node_ID {
	if rt == nil { return 0 }
	alicorn.invalidate_root(rt, "Scratchpad editor scroll restoration test")
	ui, should_build := alicorn.begin_frame(rt)
	if !should_build { return 0 }
	alicorn.container_begin(&ui, .Root, key=alicorn.key_string("undo-scroll-test-root"), style=alicorn.layout_style())
	list := alicorn.virtual_list_begin(
		&ui,
		count,
		EDITOR_ROW_HEIGHT,
		key=alicorn.key_string("undo-scroll-test-list"),
		style=alicorn.layout_style(grow=1, clip=true),
		label="undo-scroll-test-list",
		focusable=true,
	)
	for position := list.first; position < list.last; position += 1 {
		alicorn.text(&ui, fmt.tprintf("row %d", position), style=alicorn.layout_style(.Row, height=EDITOR_ROW_HEIGHT))
	}
	alicorn.virtual_list_end(&ui, list)
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
	return list.scroll.id
}

editor_test_build_recovery_text_target :: proc(ui: ^alicorn.UI, view: ^Editor_View_State) -> (owner: alicorn.Node_ID, added: bool) {
	alicorn.container_begin(ui, .Root, key=alicorn.key_string("recovery-target-test-root"), style=alicorn.layout_style(grow=1))
	owner = alicorn.container_begin(ui, .Container, key=alicorn.key_string("recovery-target-test-node"), style=alicorn.layout_style(grow=1))
	added = editor_register_text_input_target(ui, owner, view)
	alicorn.container_end(ui)
	alicorn.container_end(ui)
	return
}

@(test)
test_editor_edit_selection_snapshot_captures_only_transaction_state :: proc(t: ^testing.T) {
	view := Editor_View_State{selection_anchor=11, caret_byte=11}
	collapsed := editor_edit_selection_snapshot(&view, 6, 6)
	testing.expect(t,
		collapsed.before_anchor_byte == 11 && collapsed.before_cursor_byte == 11 &&
		collapsed.after_anchor_byte == 6 && collapsed.after_cursor_byte == 6,
		"a collapsed word-delete transaction must carry its collapsed pre-edit caret and post-edit caret")

	view.selection_anchor, view.caret_byte = 11, 6
	selected := editor_edit_selection_snapshot(&view, 6, 6)
	testing.expect(t,
		selected.before_anchor_byte == 11 && selected.before_cursor_byte == 6 &&
		selected.after_anchor_byte == 6 && selected.after_cursor_byte == 6,
		"a selection-delete transaction must preserve the directional prior selection and record its collapsed result")
}

@(test)
test_editor_clipboard_commands_preserve_bounds_and_utf8 :: proc(t: ^testing.T) {
	source, source_error := make([]u8, int(bridge.MAX_VISIBLE_BYTES), allocator=context.allocator)
	testing.expect(t, source_error == nil, "clipboard test should allocate a full visible source window")
	if source_error != nil { return }
	for &byte in source { byte = 'a' }
	visible := bridge.Visible_Window{
		document_id="clipboard-doc",
		editor_revision=1,
		start_line=0,
		end_line=1,
		start_byte=0,
		line_byte_length=u64(len(source)),
		source=source,
	}
	window, window_ok, window_error := editor_window_from_visible(&visible, context.allocator)
	testing.expect(t, window_ok, window_error)
	if !window_ok {
		if len(visible.source) > 0 { delete(visible.source, context.allocator) }
		return
	}

	paste_bytes, paste_error := make([]u8, 100*1024, allocator=context.allocator)
	testing.expect(t, paste_error == nil, "clipboard test should allocate the 100 KiB paste fixture")
	if paste_error != nil { editor_window_destroy(&window); return }
	defer delete(paste_bytes, context.allocator)
	for &byte in paste_bytes { byte = 'p' }
	clipboard := Editor_Test_Clipboard{text=string(paste_bytes), read_ok=true, write_ok=true}
	app: App
	app.backend.started = true
	app.backend.state.active = "clipboard-doc"
	documents := make([dynamic]bridge.State_Document, 0, allocator=context.allocator)
	append(&documents, bridge.State_Document{id="clipboard-doc", byte_length=u64(len(source)), editor_revision=1})
	app.backend.state.documents = documents[:]
	app.editor_views = make([dynamic]Editor_View_State, 0, allocator=context.allocator)
	app.editor_edits = make([dynamic]Editor_Edit_Intent, 0, allocator=context.allocator)
	app.editor_window = window
	app.editor_window_ready = true
	app.services.clipboard = host.Clipboard_Service{
		data=rawptr(&clipboard),
		get_text=editor_test_clipboard_get_text,
		set_text=editor_test_clipboard_set_text,
	}
	init_menus(&app)
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 640, 480})
	defer {
		for index := len(app.editor_edits)-1; index >= 0; index -= 1 { editor_remove_edit(&app, index) }
		delete(app.editor_edits)
		editor_views_destroy(&app.editor_views)
		delete(documents)
		editor_window_destroy(&app.editor_window)
		if len(app.error_message) > 0 { delete(app.error_message, context.allocator) }
		if len(clipboard.last_write) > 0 { delete(clipboard.last_write, context.temp_allocator) }
		alicorn.destroy_runtime(&rt)
	}
	view_index, view_ok := editor_view_ensure(&app.editor_views, "clipboard-doc", context.allocator)
	if !view_ok { testing.expect(t, false, "clipboard test should retain local editor state"); return }
	view := &app.editor_views[view_index]
	view.selection_anchor = u64(len(source))
	view.caret_byte = u64(len(source))

	editor_clipboard_command(&app, &rt, ACTION_EDIT_PASTE)
	testing.expect(t, clipboard.reads == 1 && len(app.editor_edits) == 1 &&
		len(view.optimistic_window.source) == len(source)+len(paste_bytes) &&
		editor_bytes_equal(view.optimistic_window.source[:len(source)], source) &&
		editor_bytes_equal(view.optimistic_window.source[len(source):], paste_bytes),
		"Paste through Clipboard_Service should queue one complete 100 KiB edit against a full 64 KiB window")

	document, document_found := find_document(&app.backend.state, "clipboard-doc")
	editor_clipboard_command(&app, &rt, ACTION_EDIT_SELECT_ALL)
	testing.expect(t, document_found && view.selection_anchor == 0 &&
		view.caret_byte == editor_current_byte_length(&app, document),
		"Select All should include pending optimistic paste bytes")

	view.selection_anchor, view.caret_byte = 0, 1
	editor_clipboard_command(&app, &rt, ACTION_EDIT_COPY)
	testing.expect(t, clipboard.writes == 1 && clipboard.last_write == "a",
		"Copy should write the exact selected UTF-8 source bytes")
	editor_clipboard_command(&app, &rt, ACTION_EDIT_CUT)
	testing.expect(t, clipboard.writes == 2 && clipboard.last_write == "a" && len(app.editor_edits) == 2 &&
		len(view.optimistic_window.source) == len(source)+len(paste_bytes)-1 &&
		view.optimistic_window.source[0] == 'a',
		"Cut should copy the full UTF-8 selection then queue its complete source deletion")

	cut_failure_length := len(view.optimistic_window.source)
	cut_failure_byte := view.optimistic_window.source[1]
	cut_failure_edits := len(app.editor_edits)
	cut_failure_writes := clipboard.writes
	clipboard.write_ok = false
	view.selection_anchor, view.caret_byte = 1, 2
	editor_clipboard_command(&app, &rt, ACTION_EDIT_CUT)
	testing.expect(t, len(app.editor_edits) == cut_failure_edits && clipboard.writes == cut_failure_writes &&
		len(view.optimistic_window.source) == cut_failure_length && view.optimistic_window.source[1] == cut_failure_byte,
		"Cut must leave the source and edit queue unchanged when the OS clipboard rejects Copy")
	clipboard.write_ok = true

	edit_count := len(app.editor_edits)
	view.selection_anchor, view.caret_byte = u64(len(view.optimistic_window.source)+10), u64(len(view.optimistic_window.source)+11)
	clipboard.text = ""
	editor_clipboard_command(&app, &rt, ACTION_EDIT_PASTE)
	testing.expect(t, len(app.editor_edits) == edit_count && clipboard.reads == 2,
		"an empty clipboard should be a no-op even when the selected range is outside the loaded window")

	view.selection_anchor, view.caret_byte = 0, 1
	view.optimistic_window.source[0] = 0xFF
	editor_clipboard_command(&app, &rt, ACTION_EDIT_COPY)
	editor_clipboard_command(&app, &rt, ACTION_EDIT_CUT)
	testing.expect(t, clipboard.writes == 2 && len(app.editor_edits) == edit_count &&
		view.optimistic_window.source[0] == 0xFF && strings.contains(app.error_message, "invalid UTF-8"),
		"Copy and Cut must refuse invalid UTF-8 source bytes without writing or deleting them")
}

@(test)
test_editor_ime_preedit_is_transient_and_uses_utf8_byte_offsets :: proc(t: ^testing.T) {
	source_bytes := [?]u8{'h', 'e', 'l', 'l', 'o', ' ', 'w', 'o', 'r', 'l', 'd'}
	visible := bridge.Visible_Window{
		document_id="ime-doc",
		start_line=0,
		end_line=1,
		start_byte=0,
		line_byte_length=u64(len(source_bytes)),
		source=source_bytes[:],
	}
	window, ok, message := editor_window_from_visible(&visible, context.temp_allocator)
	testing.expect(t, ok, message)
	if !ok { return }
	defer editor_window_destroy(&window, context.temp_allocator)

	view := Editor_View_State{selection_anchor=6, caret_byte=11}
	if !editor_preedit_update(&view, "かな", 3, 6, context.temp_allocator) {
		testing.expect(t, false, "IME preedit should be retained as frontend-owned transient bytes")
		return
	}
	defer editor_preedit_clear(&view, context.temp_allocator)
	first_start, first_end := view.preedit_replace_start, view.preedit_replace_end
	if !editor_preedit_update(&view, "日本", 3, 6, context.temp_allocator) {
		testing.expect(t, false, "subsequent IME updates should replace the preedit projection")
		return
	}
	testing.expect(t, first_start == 6 && first_end == 11 && view.preedit_replace_start == 6 && view.preedit_replace_end == 11,
		"repeated preedit updates must preserve the original UTF-8 source-byte selection")
	line, found := editor_window_line(&window, 0)
	if !found { testing.expect(t, false, "IME test source row should be projected"); return }
	display, selection_start, selection_end, applies := editor_preedit_display_for_line(&view, &window, line, context.temp_allocator)
	defer delete(display, context.temp_allocator)
	testing.expect(t, applies && display == "hello 日本" && selection_start == 9 && selection_end == 12,
		"the transient display should replace the selected source with UTF-8 preedit bytes and keep SDL offsets byte-based")
	if !editor_preedit_update(&view, "日本", 0, 3, context.temp_allocator) {
		testing.expect(t, false, "partial IME composition selection should remain in the frontend projection")
		return
	}
	partial_display, partial_start, partial_end, partial_applies := editor_preedit_display_for_line(&view, &window, line, context.temp_allocator)
	defer delete(partial_display, context.temp_allocator)
	testing.expect(t, partial_applies && partial_display == "hello 日本",
		"a partial SDL byte selection should keep the complete composition visible")
	testing.expect(t, partial_start == 6 && partial_end == 9,
		"a partial SDL byte selection should map the first UTF-8 grapheme range")
	testing.expect(t, string(window.source) == "hello world", "preedit updates must not mutate the committed source window")

	start, end := editor_preedit_take_replace_range(&view, view.selection_anchor, view.caret_byte, context.temp_allocator)
	testing.expect(t, start == 6 && end == 11 && !view.preedit_active,
		"commit should consume exactly the original selected source range and clear the preedit state")
	testing.expect(t, string(window.source) == "hello world", "taking the commit range must not mutate source bytes itself")
}

@(test)
test_editor_ime_cancel_and_commit_are_local_until_one_replacement_is_queued :: proc(t: ^testing.T) {
	source := [?]u8{'h', 'e', 'l', 'l', 'o', ' ', 'w', 'o', 'r', 'l', 'd'}
	visible := bridge.Visible_Window{
		document_id="ime-commit-doc",
		editor_revision=1,
		start_line=0,
		end_line=1,
		start_byte=0,
		line_byte_length=u64(len(source)),
		source=source[:],
	}
	base, window_ok, window_error := editor_window_from_visible(&visible, context.temp_allocator)
	testing.expect(t, window_ok, window_error)
	if !window_ok { return }

	app: App
	app.backend.started = true
	app.backend.state.active = "ime-commit-doc"
	clipboard := Editor_Test_Clipboard{write_ok=true}
	app.services.clipboard = host.Clipboard_Service{
		data=rawptr(&clipboard),
		set_text=editor_test_clipboard_set_text,
	}
	documents := make([dynamic]bridge.State_Document, 0, allocator=context.temp_allocator)
	append(&documents, bridge.State_Document{id="ime-commit-doc", byte_length=u64(len(source)), editor_revision=1})
	app.backend.state.documents = documents[:]
	app.editor_views = make([dynamic]Editor_View_State, 0, allocator=context.allocator)
	app.editor_edits = make([dynamic]Editor_Edit_Intent, 0, allocator=context.allocator)
	app.editor_window = base
	app.editor_window_ready = true
	app.editor_scroll_owner = 41
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 640, 480})
	defer {
		for index := len(app.editor_edits)-1; index >= 0; index -= 1 { editor_remove_edit(&app, index) }
		delete(app.editor_edits)
		editor_views_destroy(&app.editor_views)
		delete(documents)
		editor_window_destroy(&app.editor_window, context.temp_allocator)
		if len(clipboard.last_write) > 0 { delete(clipboard.last_write, context.temp_allocator) }
		if len(app.error_message) > 0 { delete(app.error_message, context.allocator) }
		alicorn.destroy_runtime(&rt)
	}
	view_index, view_ok := editor_view_ensure(&app.editor_views, "ime-commit-doc", context.allocator)
	if !view_ok { testing.expect(t, false, "IME test should retain local view state"); return }
	view := &app.editor_views[view_index]
	view.selection_anchor = 6
	view.caret_byte = 11
	preedit := host.Application_Text_Input_Event{kind=.Preedit, text="かな", selection_start_byte=0, selection_end_byte=0}
	editor_text_input(rawptr(&app), &rt, app.editor_scroll_owner, preedit)
	testing.expect(t, view.preedit_active && len(app.editor_edits) == 0 && string(app.editor_window.source) == "hello world",
		"IME preedit must be frontend-only and must not call Caliber or mutate committed bytes")
	tab_handled := editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Tab, shift=true})
	testing.expect(t, tab_handled && view.preedit_active && string(app.editor_window.source) == "hello world",
		"Tab and Shift+Tab should be consumed during composition without leaving the text target or changing source")
	editor_text_input(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Input_Event{kind=.Cancel})
	testing.expect(t, !view.preedit_active && len(app.editor_edits) == 0 && string(app.editor_window.source) == "hello world",
		"IME cancellation must clear composition without changing source or queueing a replacement")
	oversized, oversized_error := make([]u8, int(bridge.MAX_EDIT_BYTES)+1, allocator=context.temp_allocator)
	testing.expect(t, oversized_error == nil, "rejected IME commit fixture should allocate")
	if oversized_error == nil {
		defer delete(oversized, context.temp_allocator)
		for &byte in oversized { byte = 'x' }
		editor_text_input(rawptr(&app), &rt, app.editor_scroll_owner, preedit)
		editor_text_input(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Input_Event{kind=.Commit, text=string(oversized)})
		testing.expect(t, view.preedit_active && string(view.preedit_text) == string(oversized) &&
			view.preedit_replace_start == 6 && view.preedit_replace_end == 11 && len(app.editor_edits) == 0 &&
			string(app.editor_window.source) == "hello world" && strings.contains(app.error_message, "retryable composition"),
			"a rejected committed composition must remain visibly retryable over its original selection without mutating source")
		editor_text_input(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Input_Event{kind=.Cancel})
		testing.expect(t, view.preedit_active && view.preedit_recoverable && string(view.preedit_text) == string(oversized) &&
			string(app.editor_window.source) == "hello world" && len(app.editor_edits) == 0,
			"the host's empty terminal TEXT_EDITING cancel must preserve a rejected but committed TEXT_INPUT for recovery")
		set_error(&app, "")
		editor_text_input(rawptr(&app), &rt, app.editor_scroll_owner, preedit)
		testing.expect(t, view.preedit_active && view.preedit_recoverable && string(view.preedit_text) == string(oversized) &&
			strings.contains(app.error_message, "Edit > Copy"),
			"a new IME preedit must not overwrite committed text that is still awaiting explicit recovery")
		editor_text_input(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Input_Event{kind=.Commit, text="日本"})
		testing.expect(t, view.preedit_active && view.preedit_recoverable &&
			editor_preedit_recovery_is_full(view) && len(view.preedit_text) == len(oversized) &&
			editor_bytes_equal(view.preedit_text, oversized) &&
			view.preedit_replace_start == 6 && view.preedit_replace_end == 11 && len(app.editor_edits) == 0 &&
			string(app.editor_window.source) == "hello world" && strings.contains(app.error_message, "buffer is full"),
			"a commit received after an oversized initial recovery must be refused without changing its retained bytes")
		for _ in 0..<32 {
			editor_text_input(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Input_Event{kind=.Commit, text="z"})
		}
		testing.expect(t, len(view.preedit_text) == len(oversized) && editor_bytes_equal(view.preedit_text, oversized) &&
			editor_preedit_recovery_is_full(view),
			"repeated commits at the recovery limit must not grow or rewrite the original committed payload")
		clipboard.write_ok = false
		editor_clipboard_command(&app, &rt, ACTION_EDIT_COPY)
		testing.expect(t, clipboard.writes == 0 && view.preedit_active && view.preedit_recoverable &&
			len(view.preedit_text) == len(oversized) &&
			strings.contains(app.error_message, "Could not copy"),
			"a failed clipboard write must leave all committed IME recovery text visible and retryable")
		clipboard.write_ok = true
		editor_clipboard_command(&app, &rt, ACTION_EDIT_COPY)
		testing.expect(t, clipboard.writes == 1 && len(clipboard.last_write) == len(oversized) &&
			editor_bytes_equal(transmute([]u8)clipboard.last_write, oversized) && !view.preedit_active &&
			strings.contains(app.error_message, "copied to the clipboard") &&
			string(app.editor_window.source) == "hello world" && len(app.editor_edits) == 0,
			"Edit Copy should recover the complete committed text, clear its overlay only after success, and leave source unchanged")
	}

	editor_text_input(rawptr(&app), &rt, app.editor_scroll_owner, preedit)
	editor_text_input(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Input_Event{kind=.Commit, text="日本"})
	testing.expect(t, len(app.editor_edits) == 1 && app.editor_edits[0].start_byte == 6 && app.editor_edits[0].end_byte == 11 &&
		string(app.editor_edits[0].replacement) == "日本" && view.optimistic_window_ready &&
		string(view.optimistic_window.source) == "hello 日本",
		"IME commit should replace the original selected bytes with exactly one ordinary optimistic edit")
}

@(test)
test_recoverable_ime_text_survives_document_switch_and_blocks_close :: proc(t: ^testing.T) {
	app: App
	app.editor_views = make([dynamic]Editor_View_State, 0, allocator=context.allocator)
	app.editor_edits = make([dynamic]Editor_Edit_Intent, 0, allocator=context.allocator)
	defer {
		delete(app.editor_edits)
		editor_views_destroy(&app.editor_views)
		if len(app.error_message) > 0 { delete(app.error_message, context.allocator) }
		if len(app.close_document_id) > 0 { delete(app.close_document_id, context.allocator) }
	}
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 320, 200})
	defer alicorn.destroy_runtime(&rt)
	index, ok := editor_view_ensure(&app.editor_views, "recoverable-doc", context.allocator)
	if !ok { testing.expect(t, false, "recovery view should be retained"); return }
	view := &app.editor_views[index]
	view.selection_anchor, view.caret_byte = 2, 4
	if !editor_preedit_update(view, "committed", 0, len("committed"), context.allocator) {
		testing.expect(t, false, "recovery fixture text should be retained")
		return
	}
	view.preedit_replace_start, view.preedit_replace_end = 2, 4
	view.preedit_recoverable = true
	editor_preedit_clear_for_document_switch(view, context.allocator)
	testing.expect(t, view.preedit_active && view.preedit_recoverable && string(view.preedit_text) == "committed",
		"switching away from a document must preserve its committed IME recovery text")
	request_close_document(&app, &rt, "recoverable-doc")
	testing.expect(t, view.preedit_active && view.preedit_recoverable && string(view.preedit_text) == "committed" &&
		app.close_document_id == "recoverable-doc" && strings.contains(app.error_message, "Copy or explicitly discard"),
		"closing a document with committed IME text must open an explicit copy-or-discard recovery prompt")
	close_after_save(&app, &rt)
	close_with_discard(&app, &rt)
	testing.expect(t, view.preedit_active && view.preedit_recoverable && string(view.preedit_text) == "committed",
		"save-and-close and discard-and-close backstops must preserve recovery until an explicit recovery choice")
	testing.expect(t, editor_discard_recoverable_preedit(&app, &rt, "recoverable-doc") && !view.preedit_active &&
		!view.preedit_recoverable && len(view.preedit_text) == 0 &&
		strings.contains(app.error_message, "explicitly discarded"),
		"the recovery prompt's explicit discard choice should clear only the held composition, not edit source bytes")
}

@(test)
test_editor_recovery_commits_are_bounded_and_suspend_text_input :: proc(t: ^testing.T) {
	source, source_error := make([]u8, len("hello world"), allocator=context.allocator)
	if source_error != nil { testing.expect(t, false, "bounded recovery source should allocate"); return }
	copy(source, "hello world")
	visible := bridge.Visible_Window{
		document_id="bounded-recovery-doc",
		editor_revision=1,
		start_line=0,
		end_line=1,
		start_byte=0,
		line_byte_length=u64(len(source)),
		source=source,
	}
	window, window_ok, window_error := editor_window_from_visible(&visible, context.allocator)
	testing.expect(t, window_ok, window_error)
	if !window_ok { if len(visible.source) > 0 { delete(visible.source, context.allocator) }; return }

	app: App
	app.backend.started = true
	app.backend.state.active = "bounded-recovery-doc"
	documents := make([dynamic]bridge.State_Document, 0, allocator=context.allocator)
	append(&documents, bridge.State_Document{id="bounded-recovery-doc", byte_length=u64(len(source)), editor_revision=1, line_count=1})
	app.backend.state.documents = documents[:]
	app.editor_views = make([dynamic]Editor_View_State, 0, allocator=context.allocator)
	app.editor_edits = make([dynamic]Editor_Edit_Intent, 0, allocator=context.allocator)
	app.editor_row_targets = make([dynamic]Editor_Row_Target, 0, allocator=context.allocator)
	app.editor_window = window
	app.editor_window_ready = true
	clipboard := Editor_Test_Clipboard{write_ok=true}
	app.services.clipboard = host.Clipboard_Service{data=rawptr(&clipboard), set_text=editor_test_clipboard_set_text}
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 640, 480})
	defer {
		for index := len(app.editor_edits)-1; index >= 0; index -= 1 { editor_remove_edit(&app, index) }
		delete(app.editor_edits)
		editor_views_destroy(&app.editor_views, context.allocator)
		editor_window_destroy(&app.editor_window, context.allocator)
		delete(app.editor_row_targets)
		delete(documents)
		if len(app.error_message) > 0 { delete(app.error_message, context.allocator) }
		if len(app.editor_window_error) > 0 { delete(app.editor_window_error, context.allocator) }
		if len(clipboard.last_write) > 0 { delete(clipboard.last_write, context.temp_allocator) }
		alicorn.destroy_runtime(&rt)
	}
	alicorn.invalidate_root(&rt, "bounded recovery suspension test target")
	ui, should_build := alicorn.begin_frame(&rt)
	if !should_build { testing.expect(t, false, "bounded recovery target should build its initial frame"); return }
	owner, initial_target_added := editor_test_build_recovery_text_target(&ui, nil)
	alicorn.end_frame(&ui)
	app.editor_scroll_owner = owner
	testing.expect(t, initial_target_added && alicorn.text_input_target_is_active(&rt, owner),
		"the recovery fixture should begin with an active retained target")
	_ = alicorn.focus(&rt, owner)

	view_index, view_ok := editor_view_ensure(&app.editor_views, "bounded-recovery-doc", context.allocator)
	if !view_ok { testing.expect(t, false, "bounded recovery view should allocate"); return }
	view := &app.editor_views[view_index]
	view.selection_anchor, view.caret_byte = 6, 11
	if !editor_preedit_make_recoverable(view, "seed", 6, 11, context.allocator) {
		testing.expect(t, false, "initial recovery text should allocate its bounded backing store")
		return
	}
	// A full pending queue forces each retry to remain recoverable while the
	// test feeds enough independent commits to reach and cross the soft limit.
	pending_id, id_error := strings.clone("bounded-recovery-doc", context.allocator)
	pending_bytes, bytes_error := make([]u8, int(bridge.MAX_EDIT_BYTES), allocator=context.allocator)
	if id_error != nil || bytes_error != nil {
		testing.expect(t, false, "bounded pending edit fixture should allocate")
		if id_error == nil { delete(pending_id, context.allocator) }
		if bytes_error == nil { delete(pending_bytes, context.allocator) }
		return
	}
	append(&app.editor_edits, Editor_Edit_Intent{document_id=pending_id, replacement=pending_bytes})
	chunk, chunk_error := make([]u8, 64, allocator=context.temp_allocator)
	if chunk_error != nil { testing.expect(t, false, "bounded input chunk should allocate"); return }
	defer delete(chunk, context.temp_allocator)
	for &byte in chunk { byte = 'c' }
	remaining := EDITOR_IME_RECOVERY_MAX_BYTES-1-len(view.preedit_text)
	for remaining >= len(chunk) {
		editor_text_input(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Input_Event{kind=.Commit, text=string(chunk)})
		remaining -= len(chunk)
	}
	if remaining > 0 {
		editor_text_input(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Input_Event{kind=.Commit, text=string(chunk[:remaining])})
	}
	editor_text_input(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Input_Event{kind=.Commit, text="xy"})
	testing.expect(t, view.preedit_recoverable && len(view.preedit_text) == EDITOR_IME_RECOVERY_MAX_BYTES+1 &&
		len(view.preedit_recovery_storage) == EDITOR_IME_RECOVERY_MAX_BYTES+1 &&
		string(view.preedit_text[:len("seed")]) == "seed" &&
		string(view.preedit_text[len(view.preedit_text)-2:]) == "xy" &&
		strings.contains(app.error_message, "combined edit was rejected"),
		"the commit that crosses the recovery limit should be preserved in one final growth before suspension")
	owner_node, owner_found := rt.nodes[owner]
	testing.expect(t, owner_found && owner_node.text_input_target && owner_node.text_input_target_suspended &&
		!alicorn.text_input_target_is_active(&rt, owner),
		"the app callback should suspend the already-retained native target immediately when recovery reaches its cap")
	storage_address := rawptr(&view.preedit_recovery_storage[0])
	for _ in 0..<32 {
		editor_text_input(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Input_Event{kind=.Commit, text="overflow"})
	}
	testing.expect(t, len(view.preedit_text) == EDITOR_IME_RECOVERY_MAX_BYTES+1 &&
		len(view.preedit_recovery_storage) == EDITOR_IME_RECOVERY_MAX_BYTES+1 &&
		rawptr(&view.preedit_recovery_storage[0]) == storage_address &&
		string(view.preedit_text[:len("seed")]) == "seed" && string(view.preedit_text[len(view.preedit_text)-2:]) == "xy" &&
		strings.contains(app.error_message, "recovery buffer is full"),
		"commits after the crossing event must be refused without reallocating, copying, or changing recovery text")

	alicorn.invalidate_root(&rt, "full recovery omits target on next description")
	ui, should_build = alicorn.begin_frame(&rt)
	if should_build {
		target_id, target_added := editor_test_build_recovery_text_target(&ui, view)
		alicorn.end_frame(&ui)
		target_node, target_found := rt.nodes[target_id]
		testing.expect(t, !target_added && target_id == owner && target_found && !target_node.text_input_target && target_node.text_input_target_suspended,
			"a full recovery buffer should omit the retained text-input target so the host stops SDL text input")
	} else {
		testing.expect(t, false, "text-input target test should build one retained frame")
	}
	testing.expect(t, editor_copy_recoverable_preedit(&app, &rt, "bounded-recovery-doc") &&
		!view.preedit_active && !view.preedit_recoverable && clipboard.writes == 1,
		"successful recovery Copy should clear the retained recovery text")
	owner_node, owner_found = rt.nodes[owner]
	testing.expect(t, owner_found && !owner_node.text_input_target_suspended,
		"successful Copy should resume the retained target immediately, even though the current description omitted it")
	alicorn.invalidate_root(&rt, "recovery cleared restores target description")
	ui, should_build = alicorn.begin_frame(&rt)
	if should_build {
		target_id, target_added := editor_test_build_recovery_text_target(&ui, view)
		alicorn.end_frame(&ui)
		testing.expect(t, target_id == owner && target_added && alicorn.text_input_target_is_active(&rt, owner),
			"the resumed target should become natively eligible after the recovery-free description")
	} else {
		testing.expect(t, false, "recovery-free target test should build one retained frame")
	}
}

@(test)
test_editor_clipboard_commands_do_not_clobber_active_ime_composition :: proc(t: ^testing.T) {
	source, source_error := make([]u8, 3, allocator=context.allocator)
	if source_error != nil { testing.expect(t, false, "IME clipboard source should allocate"); return }
	copy(source, "abc")
	visible := bridge.Visible_Window{
		document_id="ime-clipboard-doc",
		editor_revision=1,
		start_line=0,
		end_line=1,
		start_byte=0,
		line_byte_length=u64(len(source)),
		source=source[:],
	}
	window, window_ok, window_error := editor_window_from_visible(&visible, context.allocator)
	testing.expect(t, window_ok, window_error)
	if !window_ok { if len(visible.source) > 0 { delete(visible.source, context.allocator) }; return }
	clipboard := Editor_Test_Clipboard{text="ignored paste", read_ok=true, write_ok=true}
	app: App
	app.backend.started = true
	app.backend.state.active = "ime-clipboard-doc"
	documents := make([dynamic]bridge.State_Document, 0, allocator=context.allocator)
	append(&documents, bridge.State_Document{id="ime-clipboard-doc", byte_length=3, editor_revision=1})
	app.backend.state.documents = documents[:]
	app.editor_views = make([dynamic]Editor_View_State, 0, allocator=context.allocator)
	app.editor_edits = make([dynamic]Editor_Edit_Intent, 0, allocator=context.allocator)
	app.editor_window = window
	app.editor_window_ready = true
	app.editor_scroll_owner = 51
	app.services.clipboard = host.Clipboard_Service{
		data=rawptr(&clipboard),
		get_text=editor_test_clipboard_get_text,
		set_text=editor_test_clipboard_set_text,
	}
	init_menus(&app)
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 640, 480})
	defer {
		for index := len(app.editor_edits)-1; index >= 0; index -= 1 { editor_remove_edit(&app, index) }
		delete(app.editor_edits)
		editor_views_destroy(&app.editor_views)
		delete(documents)
		editor_window_destroy(&app.editor_window)
		if len(clipboard.last_write) > 0 { delete(clipboard.last_write, context.temp_allocator) }
		if len(app.error_message) > 0 { delete(app.error_message, context.allocator) }
		alicorn.destroy_runtime(&rt)
	}
	view_index, view_ok := editor_view_ensure(&app.editor_views, "ime-clipboard-doc", context.allocator)
	if !view_ok { testing.expect(t, false, "IME clipboard test should retain view state"); return }
	view := &app.editor_views[view_index]
	view.selection_anchor, view.caret_byte = 1, 2
	preedit := host.Application_Text_Input_Event{kind=.Preedit, text="xy", selection_start_byte=1, selection_end_byte=2}
	editor_text_input(rawptr(&app), &rt, app.editor_scroll_owner, preedit)
	testing.expect(t, view.preedit_active && view.preedit_replace_start == 1 && view.preedit_replace_end == 2 &&
		string(app.editor_window.source) == "abc" && len(app.editor_edits) == 0,
		"IME preedit should own a transient replacement span without mutating source")
	copy_state_found, copy_state_enabled := false, false
	cut_state_enabled, paste_state_enabled, select_all_state_enabled := true, true, true
	for item in app.edit_items {
		switch string_for_action_id(item.command) {
		case ACTION_EDIT_COPY:
			copy_state_found, copy_state_enabled = true, item.state.enabled
		case ACTION_EDIT_CUT:
			cut_state_enabled = item.state.enabled
		case ACTION_EDIT_PASTE:
			paste_state_enabled = item.state.enabled
		case ACTION_EDIT_SELECT_ALL:
			select_all_state_enabled = item.state.enabled
		}
	}
	testing.expect(t, copy_state_found && copy_state_enabled && !cut_state_enabled && !paste_state_enabled && !select_all_state_enabled,
		"while composing, Copy should target composition text and source-changing or selection commands should be disabled")
	editor_clipboard_command(&app, &rt, ACTION_EDIT_COPY)
	testing.expect(t, clipboard.writes == 1 && clipboard.last_write == "xy" && len(app.editor_edits) == 0,
		"Copy during composition should copy the visible preedit bytes without committing or changing source")
	editor_clipboard_command(&app, &rt, ACTION_EDIT_CUT)
	editor_clipboard_command(&app, &rt, ACTION_EDIT_PASTE)
	editor_clipboard_command(&app, &rt, ACTION_EDIT_SELECT_ALL)
	dispatch_action(&app, &rt, ACTION_EDIT_UNDO)
	testing.expect(t, clipboard.reads == 0 && clipboard.writes == 1 && len(app.editor_edits) == 0 &&
		view.preedit_active && view.preedit_replace_start == 1 && view.preedit_replace_end == 2 &&
		string(app.editor_window.source) == "abc",
		"Cut, Paste, Select All, and Undo during composition must not mutate clipboard/source or discard its original span")
	editor_text_input(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Input_Event{kind=.Commit, text="Z"})
	testing.expect(t, len(app.editor_edits) == 1 && app.editor_edits[0].start_byte == 1 && app.editor_edits[0].end_byte == 2 &&
		string(app.editor_edits[0].replacement) == "Z" && string(view.optimistic_window.source) == "aZc" && !view.preedit_active,
		"a late IME commit after rejected menu commands should still replace the original source selection exactly once")
}

@(test)
test_editor_select_all_tracks_queued_optimistic_byte_deltas :: proc(t: ^testing.T) {
	app: App
	app.editor_edits = make([dynamic]Editor_Edit_Intent, 0, allocator=context.temp_allocator)
	defer delete(app.editor_edits)
	replacement, allocation_error := make([]u8, 100, allocator=context.temp_allocator)
	testing.expect(t, allocation_error == nil, "optimistic delta fixture should allocate")
	if allocation_error != nil { return }
	defer delete(replacement, context.temp_allocator)
	append(&app.editor_edits, Editor_Edit_Intent{document_id="doc", start_byte=3, end_byte=5, replacement=replacement})
	append(&app.editor_edits, Editor_Edit_Intent{document_id="other", start_byte=0, end_byte=0, replacement=replacement})
	document := bridge.State_Document{id="doc", byte_length=10}
	length := editor_current_byte_length(&app, document)
	view := Editor_View_State{}
	editor_select_all(&view, length)
	testing.expect(t, length == 108 && view.selection_anchor == 0 && view.caret_byte == 108,
		"Select All should include net pending edits for this document and ignore other documents")
}

@(test)
test_editor_100k_paste_fits_full_visible_window_and_bounded_optimistic_source :: proc(t: ^testing.T) {
	source, source_error := make([]u8, int(bridge.MAX_VISIBLE_BYTES), allocator=context.temp_allocator)
	testing.expect(t, source_error == nil, "full visible source fixture should allocate")
	if source_error != nil { return }
	for &byte in source { byte = 'x' }
	visible := bridge.Visible_Window{
		document_id="large-paste-doc",
		start_line=0,
		end_line=1,
		start_byte=0,
		line_byte_length=u64(len(source)),
		source=source,
	}
	window, ok, message := editor_window_from_visible(&visible, context.temp_allocator)
	testing.expect(t, ok, message)
	if !ok { delete(source, context.temp_allocator); return }
	defer editor_window_destroy(&window, context.temp_allocator)
	paste, paste_error := make([]u8, 100*1024, allocator=context.temp_allocator)
	testing.expect(t, paste_error == nil, "100 KiB paste fixture should allocate")
	if paste_error != nil { return }
	defer delete(paste, context.temp_allocator)
	for &byte in paste { byte = 'p' }
	updated, replaced, replace_message := editor_window_replace_bytes(&window, u64(len(source)), u64(len(source)), paste, context.temp_allocator)
	testing.expect(t, replaced, fmt.tprintf("100 KiB paste after a full 64 KiB visible window should fit: %s", replace_message))
	if !replaced { return }
	defer editor_window_destroy(&updated, context.temp_allocator)
	testing.expect(t, len(updated.source) == int(bridge.MAX_VISIBLE_BYTES)+100*1024 &&
		editor_bytes_equal(updated.source[:len(source)], source),
		"the optimistic projection should retain the full 64 KiB base and append all 100 KiB without truncation")
}

ALICORN_TEST_UI_FONT_DATA :: #load("../../.deps/alicorn/assets/fonts/AtkinsonHyperlegibleNext-Variable.ttf")
ALICORN_TEST_MONO_FONT_DATA :: #load("../../.deps/alicorn/assets/fonts/AtkinsonHyperlegibleMono-Variable.ttf")

tree_test_wake :: proc(data: rawptr) {}

backend_integration_test_mutex: sync.Mutex

@(test)
test_editor_view_scroll_restores_only_after_document_activation :: proc(t: ^testing.T) {
	view := Editor_View_State{scroll_y=0, scroll_x=0}

	// Ordinary input/rebuild flow must treat the retained runtime offset as the
	// current value, never as a reason to restore an older snapshot.
	live := editor_view_sync_scroll(&view, 100, 40, 900, 500, true)
	testing.expect(t, !live.vertical && !live.horizontal, "ordinary scroll movement must not schedule a restore")
	testing.expect(t, view.scroll_y == 100 && view.scroll_x == 40, "ordinary rebuilds should save both live scroll offsets")

	// A document transition is the only event that pushes the saved view back
	// into Alicorn. Horizontal restore waits for the bounded window/content width.
	view.scroll_y = 480
	view.scroll_x = 210
	editor_view_mark_active(&view)
	vertical := editor_view_sync_scroll(&view, 0, 0, 900, 100, false)
	testing.expect(t, vertical.vertical && vertical.scroll_y == 480, "activating a document should restore its saved vertical view once")
	testing.expect(t, !vertical.horizontal && view.restore_x_pending && view.scroll_x == 210,
		"horizontal restore should remain pending until content geometry is available")

	horizontal := editor_view_sync_scroll(&view, 480, 0, 900, 120, true)
	testing.expect(t, !horizontal.vertical && horizontal.horizontal && horizontal.scroll_x == 120,
		"horizontal restore should happen once and clamp to current content geometry")
	next := editor_view_sync_scroll(&view, 520, 90, 900, 120, true)
	testing.expect(t, !next.vertical && !next.horizontal && view.scroll_y == 520 && view.scroll_x == 90,
		"after restoration, normal scrolling should again update saved view state")
}

@(test)
test_editor_line_number_text_has_no_fixed_zero_padding :: proc(t: ^testing.T) {
	testing.expect(t, editor_line_number_text(1) == "1", "the first line number should not be padded")
	testing.expect(t, editor_line_number_text(10) == "10", "two-digit line numbers should use their natural width")
	testing.expect(t, editor_line_number_text(100_000) == "100000", "large line numbers should remain accurate without extra padding")
	testing.expect(t, editor_line_number_gutter_width(167) == 42, "ordinary documents should use a compact three-digit gutter")
	testing.expect(t, editor_line_number_gutter_width(100_000) == 72, "the gutter should widen only when the logical line count needs another digit")
}

@(test)
test_editor_horizontal_extent_is_high_water_per_revision :: proc(t: ^testing.T) {
	view := Editor_View_State{}
	width := editor_view_observe_horizontal_extent(&view, 3, 1_800)
	testing.expect(t, width == 1_800, "the first bounded window establishes a minimum horizontal extent")
	width = editor_view_observe_horizontal_extent(&view, 3, 600)
	testing.expect(t, width == 1_800, "a shorter bounded window must not shrink horizontal scroll geometry")
	width = editor_view_observe_horizontal_extent(&view, 3, 2_400)
	testing.expect(t, width == 2_400, "a newly observed wider window should grow horizontal extent")
	width = editor_view_observe_horizontal_extent(&view, 3, 900)
	testing.expect(t, width == 2_400, "later short windows should preserve the widest observed extent")
	width = editor_view_observe_horizontal_extent(&view, 4, 720)
	testing.expect(t, width == 720, "a new editor revision should reset the old revision's extent")
}

@(test)
test_editor_projection_preserves_source_bytes_and_maps_expansions :: proc(t: ^testing.T) {
	raw := [?]u8{0xEF, 0xBB, 0xBF, 'A', '\t', 0xFF, '\r', '\n', 'e', 0xCC, 0x81}
	source_bytes, allocation_error := make([]u8, len(raw), context.temp_allocator)
	testing.expect(t, allocation_error == nil, "projection fixture should allocate")
	if allocation_error != nil { return }
	defer delete(source_bytes, context.temp_allocator)
	for index in 0..<len(raw) { source_bytes[index] = raw[index] }
	source := bridge.Visible_Window{
		document_id="projection-doc",
		application_rev=4,
		editor_revision=9,
		start_line=0,
		end_line=2,
		start_byte=0,
		source=source_bytes,
	}
	window, ok, message := editor_window_from_visible(&source, context.temp_allocator)
	testing.expect(t, ok, message)
	if !ok { return }
	source_bytes = {}
	defer editor_window_destroy(&window, context.temp_allocator)
	testing.expect(t, len(window.lines) == 2, "SPVS source should project only its declared logical rows")
	if len(window.lines) == 2 {
		line := window.lines[0]
		testing.expect(t, line.display == "A   \\xFF", "BOM should be hidden, tabs expanded, and invalid bytes escaped deterministically")
		expected_offsets := [?]u64{3, 4, 4, 4, 5, 5, 5, 5, 6}
		offsets_match := len(line.display_bytes) == len(expected_offsets)
		if offsets_match {
			for index in 0..<len(expected_offsets) {
				if line.display_bytes[index] != expected_offsets[index] { offsets_match = false; break }
			}
		}
		testing.expect(t, offsets_match, "display boundaries should map back to exact source byte boundaries")
		testing.expect(t, window.lines[1].display == "e\xCC\x81", "valid combining Unicode bytes should be preserved")
	}
}

@(test)
test_editor_projection_hit_testing_keeps_synthetic_spans_atomic :: proc(t: ^testing.T) {
	source := [?]u8{'A', '\t', 0xFF, 'B'}
	line, ok := editor_project_line(source[:], 100, 0, context.temp_allocator)
	testing.expect(t, ok && line.display == "A   \\xFFB", "tab and invalid byte projection should remain visible and deterministic")
	if !ok { return }
	defer {
		delete(line.display, context.temp_allocator)
		delete(line.display_bytes, context.temp_allocator)
	}
	// The tab occupies display byte boundaries 1..4 but source bytes 101..102.
	testing.expect(t, editor_display_to_source(&line, 1) == 101, "the leading edge of a tab should map before its source byte")
	testing.expect(t, editor_display_to_source(&line, 2) == 101, "the left half of an expanded tab should snap before the source byte")
	testing.expect(t, editor_display_to_source(&line, 3) == 102, "the right half of an expanded tab should snap after the source byte")
	testing.expect(t, editor_source_to_display(&line, 101) == 1 && editor_source_to_display(&line, 102) == 4,
		"source boundaries around an expanded tab should map to its visual edges")
	// The escaped invalid byte occupies four display bytes but one source byte.
	testing.expect(t, editor_display_to_source(&line, 6) == 103, "the right half of an escaped byte should snap after its one source byte")
	testing.expect(t, editor_source_to_display(&line, 103) == 8, "the source boundary after an escaped byte should map after the full escape")
	from_tab, tab_affinity, tab_moved := editor_move_horizontal(&line, 101, alicorn.Text_Affinity.Leading, 1)
	testing.expect(t, tab_moved && from_tab == 102, "one horizontal movement should cross an expanded tab atomically")
	from_escape, escape_affinity, escape_moved := editor_move_horizontal(&line, 102, alicorn.Text_Affinity.Leading, 1)
	testing.expect(t, escape_moved && from_escape == 103, "one horizontal movement should cross an escaped byte atomically")
	_ = tab_affinity
	_ = escape_affinity
}

@(test)
test_editor_projection_caret_movement_respects_grapheme_boundaries :: proc(t: ^testing.T) {
	combining := [?]u8{'e', 0xCC, 0x81, 'x'}
	line, ok := editor_project_line(combining[:], 40, 0, context.temp_allocator)
	testing.expect(t, ok, "valid combining-mark source should project")
	if !ok { return }
	defer {
		delete(line.display, context.temp_allocator)
		delete(line.display_bytes, context.temp_allocator)
	}
	next, combining_affinity, combining_moved := editor_move_horizontal(&line, 40, alicorn.Text_Affinity.Leading, 1)
	testing.expect(t, combining_moved && next == 43, "right movement should treat a base plus combining mark as one grapheme")
	previous, previous_affinity, previous_moved := editor_move_horizontal(&line, 43, alicorn.Text_Affinity.Leading, -1)
	testing.expect(t, previous_moved && previous == 40, "left movement should not split a combining grapheme")
	_ = combining_affinity
	_ = previous_affinity

	family := [?]u8{0xF0, 0x9F, 0x91, 0xA8, 0xE2, 0x80, 0x8D, 0xF0, 0x9F, 0x91, 0xA9, 0xE2, 0x80, 0x8D, 0xF0, 0x9F, 0x91, 0xA7}
	emoji, emoji_ok := editor_project_line(family[:], 0, 0, context.temp_allocator)
	testing.expect(t, emoji_ok, "emoji ZWJ sequence should project")
	if !emoji_ok { return }
	defer {
		delete(emoji.display, context.temp_allocator)
		delete(emoji.display_bytes, context.temp_allocator)
	}
	emoji_next, emoji_affinity, emoji_moved := editor_move_horizontal(&emoji, 0, alicorn.Text_Affinity.Leading, 1)
	testing.expect(t, emoji_moved && emoji_next == u64(len(family)), "one horizontal movement should keep an emoji ZWJ sequence atomic")
	_ = emoji_affinity
}

@(test)
test_editor_short_document_rows_keep_fixed_height :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 800, 520})
	ui, build := alicorn.begin_frame(&rt)
	if !build { alicorn.destroy_runtime(&rt); return }
	alicorn.container_begin(&ui, .Root, label="short-editor-root", style=alicorn.layout_style(.Column, width=800, height=520, clip=true))
	list := alicorn.virtual_list_begin(
		&ui,
		2,
		EDITOR_ROW_HEIGHT,
		key=alicorn.key_string("short-editor-list"),
		style=alicorn.layout_style(grow=1, clip=true),
	)
	row_ids: [2]alicorn.Node_ID
	for position := list.first; position < list.last; position += 1 {
		id := alicorn.container_begin(
			&ui,
			.Container,
			label="short-editor-logical-row",
			key=alicorn.key_string(fmt.tprintf("short-editor-row:%d", position)),
			style=editor_logical_row_style(),
		)
		if position >= 0 && position < len(row_ids) { row_ids[position] = id }
		alicorn.container_end(&ui)
	}
	alicorn.virtual_list_end(&ui, list)
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)

	row0, row0_ok := rt.nodes[row_ids[0]]
	row1, row1_ok := rt.nodes[row_ids[1]]
	testing.expect(t, row0_ok && row1_ok, "both short-document rows should be realized")
	if row0_ok && row1_ok {
		testing.expect(t, row0.bounds.h == EDITOR_ROW_HEIGHT && row1.bounds.h == EDITOR_ROW_HEIGHT,
			"a short document must keep each source row at the fixed editor row height")
		testing.expect(t, row1.bounds.y-row0.bounds.y == EDITOR_ROW_HEIGHT,
			"unused viewport space must remain below short documents instead of spreading their rows")
	}
	alicorn.destroy_runtime(&rt)
}

@(test)
test_editor_projection_accepts_multilingual_utf8_and_rejects_invalid_sequences :: proc(t: ^testing.T) {
	multilingual := [?]u8{0xC3, 0xA9, 0xE0, 0xA4, 0x95, 0xD8, 0xA7, 0xD7, 0x90, 0xF0, 0x9F, 0x91, 0xA9, 0xE2, 0x80, 0x8D, 0xF0, 0x9F, 0x92, 0xBB}
	line, ok := editor_project_line(multilingual[:], 0, 0, context.temp_allocator)
	testing.expect(t, ok && line.display == string(multilingual[:]), "multilingual UTF-8 and emoji ZWJ bytes should pass through without normalization")
	if ok { delete(line.display, context.temp_allocator); delete(line.display_bytes, context.temp_allocator) }
	invalid := [?]u8{0xE0, 0x80, 0x80}
	line, ok = editor_project_line(invalid[:], 0, 0, context.temp_allocator)
	testing.expect(t, ok && line.display == "\\xE0\\x80\\x80", "overlong UTF-8 sequences should escape each invalid source byte")
	if ok { delete(line.display, context.temp_allocator); delete(line.display_bytes, context.temp_allocator) }
}

@(test)
test_editor_long_line_chunks_preserve_source_anchor_and_request_only_at_frontier :: proc(t: ^testing.T) {
	source_bytes, allocation_error := make([]u8, 16*1024, context.temp_allocator)
	testing.expect(t, allocation_error == nil, "long-line projection fixture should allocate")
	if allocation_error != nil { return }
	defer delete(source_bytes, context.temp_allocator)
	for i in 0..<len(source_bytes) { source_bytes[i] = 'x' }
	visible := bridge.Visible_Window{
		document_id="long-line",
		application_rev=2,
		editor_revision=3,
		start_line=7,
		end_line=8,
		start_byte=16*1024-32,
		line_byte_length=2*1024*1024,
		truncated=true,
		source=source_bytes,
	}
	window, ok, message := editor_window_from_visible(&visible, context.temp_allocator)
	testing.expect(t, ok, message)
	if !ok { return }
	visible.source = {}
	defer editor_window_destroy(&window, context.temp_allocator)
	testing.expect(t, editor_window_is_long_line_chunk(&window), "truncated one-line resources should be recognized as byte chunks")
	if len(window.lines) == 1 && len(window.lines[0].display_bytes) > 0 {
		testing.expect(t, window.lines[0].display_bytes[0] == window.start_byte, "display mapping should retain the absolute byte anchor")
	}
	anchor, needed := editor_long_line_next_anchor(&window, 7, 100, 200)
	testing.expect(t, !needed && anchor == 0, "a chunk request should not run before the horizontal frontier")
	anchor, needed = editor_long_line_next_anchor(&window, 7, 160, 200)
	want_anchor := window.start_byte+u64(len(window.source))-64
	testing.expect(t, needed && anchor == want_anchor && anchor > window.start_byte, "reaching the horizontal frontier should request a forward byte window with a small overlap")
	anchor, needed = editor_long_line_next_anchor(&window, 8, 200, 200)
	testing.expect(t, !needed && anchor == 0, "a neighboring logical row must not advance this line's byte window")
}

@(test)
test_read_only_editor_emits_only_realized_monospace_rows :: proc(t: ^testing.T) {
	sync.mutex_lock(&backend_integration_test_mutex)
	defer sync.mutex_unlock(&backend_integration_test_mutex)
	workspace, workspace_error := os.make_directory_temp("", "scratchpad-alicorn-editor-*", context.temp_allocator)
	if workspace_error != nil { testing.expect(t, false, "could not create editor-surface workspace"); return }
	defer _ = os.remove_all(workspace)
	path := fmt.tprintf("%s/large-source.txt", workspace)
	content := make([dynamic]u8, 0, allocator=context.temp_allocator)
	defer delete(content)
	for index in 0..<26_150 {
		if index == 1 {
			append(&content, 'x')
			append(&content, '\n')
			continue
		}
		line := fmt.tprintf("line-%05d:", index)
		for byte in transmute([]u8)line { append(&content, byte) }
		target_bytes := 800 if index == 2 else 400
		for _ in 0..<(target_bytes-len(line)) { append(&content, 'x') }
		append(&content, '\n')
	}
	if err := os.write_entire_file_from_string(path, string(content[:])) ; err != nil {
		testing.expect(t, false, "could not write virtualized editor fixture")
		return
	}
	backend_library, found_library := os.lookup_env("SCRATCHPAD_BACKEND_LIBRARY", context.temp_allocator)
	if !found_library { testing.expect(t, false, "editor-surface test requires the staged shared backend"); return }
	defer delete(backend_library, context.temp_allocator)

	app: App
	app.tree_directories = make([dynamic]Tree_Directory, 0, allocator=context.allocator)
	app.editor_views = make([dynamic]Editor_View_State, 0, allocator=context.allocator)
	app.editor_row_targets = make([dynamic]Editor_Row_Target, 0, allocator=context.allocator)
	loaded, load_message := bridge.backend_load(&app.backend, backend_library)
	testing.expect(t, loaded, fmt.tprintf("shared backend should load for editor-surface test: %s", load_message))
	if !loaded { return }
	started, start_message := bridge.backend_start(&app.backend, workspace, tree_test_wake, nil, context.allocator)
	testing.expect(t, started, fmt.tprintf("shared backend should start for editor-surface test: %s", start_message))
	if !started { return }
	rt: alicorn.Runtime
	defer {
		if app.backend.started { _, _ = bridge.backend_stop(&app.backend, context.allocator) }
		editor_window_destroy(&app.editor_window, context.allocator)
		editor_views_destroy(&app.editor_views, context.allocator)
		delete(app.editor_row_targets)
		if len(app.editor_presented_document_id) > 0 { delete(app.editor_presented_document_id, context.allocator) }
		alicorn.destroy_runtime(&rt)
	}
	opened := bridge.backend_command(&app.backend, "open_path", path=path, allocator=context.temp_allocator)
	testing.expect(t, opened.ok && len(app.backend.state.documents) == 1, "Go should publish the real source document")
	bridge.backend_command_result_destroy(&opened, context.temp_allocator)
	active, active_found := find_document(&app.backend.state, app.backend.state.active)
	testing.expect(t, active_found && active.line_count > 26_000 && len(content) > 10*1024*1024,
		"10 MiB fixture should expose real logical-line metadata without a whole-document frontend copy")
	if !active_found { return }
	visible := bridge.backend_command(
		&app.backend,
		"read_visible_lines",
		document_id=active.id,
		start_line=0,
		max_lines=bridge.MAX_VISIBLE_LINES,
		max_bytes=bridge.MAX_VISIBLE_BYTES,
		allocator=context.allocator,
	)
	testing.expect(t, visible.ok && visible.visible_window_owned, "generic Caliber resource should supply a bounded source window")
	if !visible.visible_window_owned { bridge.backend_command_result_destroy(&visible, context.allocator); return }
	window, window_ok, window_message := editor_window_from_visible(&visible.visible_window, context.allocator)
	testing.expect(t, window_ok, window_message)
	if window_ok {
		app.editor_window = window
		app.editor_window_ready = true
		testing.expect(t, len(app.editor_window.source) <= int(bridge.MAX_VISIBLE_BYTES),
			"the frontend must retain only the bounded Caliber source window, never the full document")
	}
	bridge.backend_command_result_destroy(&visible, context.allocator)
	if !window_ok { return }

	rt = alicorn.new_runtime(alicorn.Rect{0, 0, 1100, 720})
	testing.expect(t,
		alicorn.text_engine_load_font(&rt.text_engine, ALICORN_TEST_UI_FONT_DATA) &&
		alicorn.text_engine_load_font_role(&rt.text_engine, .Monospace, ALICORN_TEST_MONO_FONT_DATA),
		"read-only editor interaction test should load the same bundled UI and monospace roles as the native host",
	)
	_ = build_app(rawptr(&app), &rt, 1100, 720, 1)
	realized_rows := 0
	first_row_found := false
	last_fixture_row_found := false
	for node_id in rt.order {
		node, node_found := rt.nodes[node_id]
		if !node_found || !strings.has_prefix(node.key, "scratchpad-line:") { continue }
		realized_rows += 1
		if node.font != .Monospace { testing.expect(t, false, "source lines should use Alicorn's monospace/Runa role") }
	if strings.contains(node.text, "line-00000") { first_row_found = true }
	if strings.contains(node.text, "line-26149") { last_fixture_row_found = true }
	}
	testing.expect(t, realized_rows > 0 && realized_rows < len(app.editor_window.lines),
		"the editor should emit only the virtualized viewport rows, not all document lines")
	testing.expect(t, first_row_found && !last_fixture_row_found,
		"the first viewport should contain real source and omit offscreen logical rows")

	// The interactive read-only editor owns focus at the durable list owner,
	// maps pointer geometry back into source bytes, and keeps navigation local.
	if len(app.editor_row_targets) > 0 {
		target := app.editor_row_targets[0]
		row_node, row_found := rt.nodes[target.node]
		line, line_found := editor_window_line(&app.editor_window, target.logical_line)
		testing.expect(t, row_found && line_found, "a realized editor text node should have a corresponding bounded source row")
		if row_found && line_found {
			owner_node, owner_found := rt.nodes[app.editor_scroll_owner]
			testing.expect(t, owner_found && owner_node.text_input_target && owner_node.focusable,
				"the editor scroll owner should be retained as a generic text-input target")
			click_x, click_y := row_node.bounds.x+70, row_node.bounds.y+row_node.bounds.h/2
			hit, hit_ok := alicorn.text_node_hit_test(&rt, target.node, click_x, click_y)
			testing.expect(t, hit_ok && hit.byte >= 0 && hit.byte <= len(row_node.text),
				"the realized source row should expose a shaped-run hit-test in local display bytes")
			document_revision := active.editor_revision
			application_revision := app.backend.state.revision
			pointer_event := alicorn.Pointer_Event{kind=.Down, x=click_x, y=click_y, button=1}
			pointer_target := alicorn.process_pointer(&rt, pointer_event)
			testing.expect(t, pointer_target == app.editor_scroll_owner,
				"the real retained hit-test should route source clicks to the durable generic text-input owner")
			editor_pointer(rawptr(&app), &rt, pointer_event, pointer_target)
			view_index := editor_view_find(app.editor_views[:], active.id)
			testing.expect(t, rt.focused == app.editor_scroll_owner && view_index >= 0,
				"a real pointer click should focus the durable editor viewport and assign per-document caret state")
			if view_index >= 0 {
				view := &app.editor_views[view_index]
				testing.expect(t, view.caret_byte >= line.source_start && view.caret_byte <= line.source_end,
					"pointer hit testing should map to a legal source byte within the clicked line")
				_ = alicorn.process_pointer(&rt, alicorn.Pointer_Event{kind=.Up, x=click_x, y=click_y, button=1})
				editor_pointer(rawptr(&app), &rt, alicorn.Pointer_Event{kind=.Up, x=click_x, y=click_y, button=1}, 0)

				// The line's clickable horizontal area is the editor viewport, not
				// only the glyph bounds. Clicking before text and after a short line
				// should map to legal source line boundaries.
				owner_node, _ = rt.nodes[app.editor_scroll_owner]
				before_text_x := owner_node.bounds.x+2
				before_text_y := row_node.bounds.y+row_node.bounds.h/2
				before_event := alicorn.Pointer_Event{kind=.Down, x=before_text_x, y=before_text_y, button=1}
				before_target := alicorn.process_pointer(&rt, before_event)
				editor_pointer(rawptr(&app), &rt, before_event, before_target)
				testing.expect(t, before_target == app.editor_scroll_owner && view.caret_byte == line.source_start,
					"clicking before the first glyph should place the caret at the source line start")
				_ = alicorn.process_pointer(&rt, alicorn.Pointer_Event{kind=.Up, x=before_text_x, y=before_text_y, button=1})
				editor_pointer(rawptr(&app), &rt, alicorn.Pointer_Event{kind=.Up, x=before_text_x, y=before_text_y, button=1}, 0)
				short_node := alicorn.Node_ID(0)
				for row in app.editor_row_targets {
					if row.logical_line == 1 { short_node = row.node; break }
				}
				short_row, short_found := rt.nodes[short_node]
				short_line, short_line_found := editor_window_line(&app.editor_window, 1)
				if short_found && short_line_found {
					far_right_x := owner_node.bounds.x+owner_node.scroll_viewport_width-4
					far_right_y := short_row.bounds.y+short_row.bounds.h/2
					right_event := alicorn.Pointer_Event{kind=.Down, x=far_right_x, y=far_right_y, button=1}
					right_target := alicorn.process_pointer(&rt, right_event)
					editor_pointer(rawptr(&app), &rt, right_event, right_target)
					testing.expect(t, view.caret_byte == short_line.source_end,
						"clicking beyond a short source line should place the caret at its end")
					_ = alicorn.process_pointer(&rt, alicorn.Pointer_Event{kind=.Up, x=far_right_x, y=far_right_y, button=1})
					editor_pointer(rawptr(&app), &rt, alicorn.Pointer_Event{kind=.Up, x=far_right_x, y=far_right_y, button=1}, 0)
				} else {
					testing.expect(t, false, "the fixture's short logical row should be realized for line-edge hit testing")
				}

				// Dragging is captured by the stable scroll owner while selection
				// endpoints move across independently retained text rows.
				drag_start_x := row_node.bounds.x+90
				drag_start_y := row_node.bounds.y+row_node.bounds.h/2
				drag_down := alicorn.Pointer_Event{kind=.Down, x=drag_start_x, y=drag_start_y, button=1}
				drag_target := alicorn.process_pointer(&rt, drag_down)
				editor_pointer(rawptr(&app), &rt, drag_down, drag_target)
				drag_anchor := view.selection_anchor
				third_target := Editor_Row_Target{}
				for row in app.editor_row_targets {
					if row.logical_line == 2 { third_target = row; break }
				}
				drag_row, drag_row_found := rt.nodes[third_target.node]
				drag_move := alicorn.Pointer_Event{kind=.Move, x=drag_row.bounds.x+150, y=drag_row.bounds.y+drag_row.bounds.h/2}
				drag_move_target := alicorn.process_pointer(&rt, drag_move)
				editor_pointer(rawptr(&app), &rt, drag_move, drag_move_target)
				third_line, third_line_found := editor_window_line(&app.editor_window, 2)
				testing.expect(t, drag_row_found && third_line_found && view.dragging_selection &&
					view.selection_anchor == drag_anchor && view.caret_byte >= third_line.source_start && view.caret_byte <= third_line.source_end,
					"captured pointer dragging should preserve the anchor and extend selection into the row under the pointer")
				_ = alicorn.process_pointer(&rt, alicorn.Pointer_Event{kind=.Up, x=drag_move.x, y=drag_move.y, button=1})
				editor_pointer(rawptr(&app), &rt, alicorn.Pointer_Event{kind=.Up, x=drag_move.x, y=drag_move.y, button=1}, 0)
				testing.expect(t, !view.dragging_selection, "pointer-up should release the frontend's drag-selection state")
				cancel_down := alicorn.Pointer_Event{kind=.Down, x=drag_start_x, y=drag_start_y, button=1}
				cancel_target := alicorn.process_pointer(&rt, cancel_down)
				editor_pointer(rawptr(&app), &rt, cancel_down, cancel_target)
				captured_before_cancel := rt.captured_node
				cancel_event := alicorn.Pointer_Event{kind=.Cancel}
				_ = alicorn.process_pointer(&rt, cancel_event)
				editor_pointer(rawptr(&app), &rt, cancel_event, captured_before_cancel)
				testing.expect(t, captured_before_cancel == app.editor_scroll_owner && rt.captured_node == 0 && !view.dragging_selection,
					"native pointer-capture cancellation should release both Alicorn capture and local drag state")
				// A plain click collapses the drag selection before testing the
				// ordinary Left/Right contract.
				reset_down := alicorn.Pointer_Event{kind=.Down, x=click_x, y=click_y, button=1}
				reset_target := alicorn.process_pointer(&rt, reset_down)
				editor_pointer(rawptr(&app), &rt, reset_down, reset_target)
				_ = alicorn.process_pointer(&rt, alicorn.Pointer_Event{kind=.Up, x=click_x, y=click_y, button=1})
				editor_pointer(rawptr(&app), &rt, alicorn.Pointer_Event{kind=.Up, x=click_x, y=click_y, button=1}, 0)

				semantic_focus_before_vertical_key := alicorn.semantic_focus_state(&rt).id
				vertical_tree_handled := application_key(rawptr(&app), &rt, .Down)
				testing.expect(t, !vertical_tree_handled && rt.focused == app.editor_scroll_owner &&
					alicorn.semantic_focus_state(&rt).id == semantic_focus_before_vertical_key,
					"vertical keys outside this editor slice must not fall through to workspace-tree navigation")
				clicked_caret := view.caret_byte
				right_handled := editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Right})
				testing.expect(t, right_handled && view.caret_byte > clicked_caret,
					"Right should move the read-only caret locally without an authoritative edit")
				anchor_before_extend := view.selection_anchor
				shift_handled := editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Right, shift=true})
				testing.expect(t, shift_handled && view.selection_anchor == anchor_before_extend && view.caret_byte > view.selection_anchor,
					"Shift+Right should extend a directional frontend-local selection")
				view.caret_byte = line.source_start
				view.selection_anchor = line.source_start
				view.caret_affinity = .Leading
				view.anchor_affinity = .Leading
				word_right_handled := editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Word_Right})
				word_right_caret := view.caret_byte
				testing.expect(t, word_right_handled, "the editor should consume a platform-normalized word-right key")
				testing.expect(t, word_right_caret > line.source_start, "word-right should move to a later Runa word boundary")
				view.caret_byte = line.source_start
				view.selection_anchor = line.source_start
				word_extend_handled := editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Word_Right, shift=true})
				testing.expect(t, word_extend_handled && view.selection_anchor == line.source_start && view.caret_byte > line.source_start,
					"Shift+word-right should extend a frontend-local directional selection through Runa boundaries")
				// Start at a nonzero column on a long row, then move through a one-character row and
				// back. preferred_x must survive the short row and restore the same
				// visual column on the following long row.
				preferred_click_x := row_node.bounds.x+170
				preferred_click_y := row_node.bounds.y+row_node.bounds.h/2
				preferred_down := alicorn.Pointer_Event{kind=.Down, x=preferred_click_x, y=preferred_click_y, button=1}
				preferred_target := alicorn.process_pointer(&rt, preferred_down)
				editor_pointer(rawptr(&app), &rt, preferred_down, preferred_target)
				_ = alicorn.process_pointer(&rt, alicorn.Pointer_Event{kind=.Up, x=preferred_click_x, y=preferred_click_y, button=1})
				editor_pointer(rawptr(&app), &rt, alicorn.Pointer_Event{kind=.Up, x=preferred_click_x, y=preferred_click_y, button=1}, 0)
				first_caret := view.caret_byte
				down_short := editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Down})
				short_caret := view.caret_byte
				down_long := editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Down, shift=true})
				long_caret := view.caret_byte
				selection_anchor_after_shift_down := view.selection_anchor
				up_short := editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Up, shift=true})
				up_caret := view.caret_byte
			down_restore := editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Down, shift=true})
				testing.expect(t, preferred_target == app.editor_scroll_owner && down_short && down_long && up_short && down_restore &&
					view.preferred_x_set && short_line_found && short_caret == short_line.source_end &&
					up_caret == short_caret && view.caret_byte == long_caret && long_caret > first_caret &&
					view.selection_anchor == selection_anchor_after_shift_down && view.selection_anchor == short_caret,
					"vertical motion should keep its preferred visual X across a short row and return to the original column")

				// Page keys use the same local geometry and reveal the resulting
				// logical row through the retained virtual-list viewport.
				_ = editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Home})
				page_down_handled := editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Page_Down})
				page_down_line, page_down_line_found := editor_line_for_source(&app.editor_window, view.caret_byte)
				owner_after_page, owner_after_page_found := rt.nodes[app.editor_scroll_owner]
				page_scroll_moved := owner_after_page_found && owner_after_page.scroll_offset_y > 0
				page_up_handled := editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Page_Up})
				page_up_line, page_up_line_found := editor_line_for_source(&app.editor_window, view.caret_byte)
				testing.expect(t, page_down_handled && page_down_line_found && page_down_line.logical_line > 0 && page_scroll_moved &&
					page_up_handled && page_up_line_found && page_up_line.logical_line < page_down_line.logical_line,
					"Page Down/Up should navigate by viewport-sized logical ranges and keep the caret visible")
				page_anchor := view.selection_anchor
				shift_page_down := editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Page_Down, shift=true})
				shift_page_line, shift_page_line_found := editor_line_for_source(&app.editor_window, view.caret_byte)
				shift_page_up := editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Page_Up, shift=true})
				shift_page_back_line, shift_page_back_found := editor_line_for_source(&app.editor_window, view.caret_byte)
				testing.expect(t, shift_page_down && shift_page_line_found && shift_page_up && shift_page_back_found &&
					shift_page_line.logical_line > page_up_line.logical_line &&
					shift_page_back_line.logical_line == page_up_line.logical_line && view.selection_anchor == page_anchor,
					"Shift+Page Up/Down should extend and contract selection without moving its anchor")

				_ = editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Right, shift=true})
				paint_line, paint_line_found := editor_line_for_source(&app.editor_window, view.caret_byte)
				paint_node_id := alicorn.Node_ID(0)
				if paint_line_found { paint_node_id = editor_row_node_for_line(app.editor_row_targets[:], paint_line.logical_line) }
				_ = build_app(rawptr(&app), &rt, 1100, 720, 1)
				row_node, row_found = rt.nodes[paint_node_id]
				selection_commands, caret_commands := 0, 0
				if row_found {
					for command in row_node.paint {
						if command.kind == .Text_Selection { selection_commands += 1 }
						if command.kind == .Text_Caret { caret_commands += 1 }
					}
				}
				testing.expect(t, selection_commands > 0 && caret_commands == 1,
					"the retained Runa text node should paint the local selection and caret after navigation")
			}
			active_after, active_still_found := find_document(&app.backend.state, active.id)
			testing.expect(t, active_still_found && active_after.editor_revision == document_revision && app.backend.state.revision == application_revision,
				"read-only pointer and keyboard navigation must emit no Caliber mutation or revision change")
			_ = alicorn.process_pointer(&rt, alicorn.Pointer_Event{kind=.Up, x=click_x, y=click_y, button=1})
		}
	}

	// Simulate wheel movement, then rebuild. The newly observed retained offset
	// must be saved rather than mistaken for a stale view that needs restoring.
	vertical_changed := alicorn.scroll_region_set_offset(&rt, app.editor_scroll_owner, 1_000, "test editor wheel scroll")
	horizontal_changed := alicorn.scroll_region_set_offset_x(&rt, app.editor_scroll_owner, 300, "test editor horizontal scroll")
	testing.expect(t, vertical_changed && horizontal_changed, "the large editor fixture should have scroll range on both axes")
	_ = build_app(rawptr(&app), &rt, 1100, 720, 1)
	view_index := editor_view_find(app.editor_views[:], active.id)
	view_saved := view_index >= 0 && app.editor_views[view_index].scroll_y == 1_000 && app.editor_views[view_index].scroll_x == 300
	testing.expect(t, view_saved, "ordinary description rebuilds must preserve live vertical and horizontal offsets")

	workspace_split_id := alicorn.Node_ID(0)
	for node_id in rt.order {
		node, node_found := rt.nodes[node_id]
		if node_found && node.kind == .Split && node.label == "scratchpad-workspace-editor-split" {
			workspace_split_id = node_id
			break
		}
	}
	testing.expect(t, workspace_split_id != 0, "the Scratchpad tree and editor should use Alicorn's retained split primitive")
	if workspace_split_id == 0 { return }
	workspace_split, split_found := rt.nodes[workspace_split_id]
	testing.expect(t, split_found && workspace_split.split_min_first == 180 && workspace_split.split_min_second == 480,
		"the workspace split should preserve useful minimum widths for both panes")
	if !split_found || len(workspace_split.children) != 3 { return }
	first_before, first_found := rt.nodes[workspace_split.children[0]]
	divider, divider_found := rt.nodes[workspace_split.children[1]]
	second_before, second_found := rt.nodes[workspace_split.children[2]]
	if !first_found || !divider_found || !second_found { return }
	position_before := workspace_split.split_position
	first_before_width := first_before.bounds.w
	second_before_width := second_before.bounds.w
	start_x := divider.bounds.x + divider.bounds.w/2
	start_y := divider.bounds.y + divider.bounds.h/2
	_ = alicorn.process_pointer(&rt, alicorn.Pointer_Event{.Down, start_x, start_y, 1})
	_ = alicorn.process_pointer(&rt, alicorn.Pointer_Event{.Move, start_x+40, start_y, 0})
	presentation_ui, presentation_ready := alicorn.begin_presentation_frame(&rt)
	if presentation_ready { alicorn.end_presentation_frame(&presentation_ui) }
	workspace_split_after, split_after_found := rt.nodes[workspace_split_id]
	first_after, first_after_found := rt.nodes[workspace_split.children[0]]
	second_after, second_after_found := rt.nodes[workspace_split.children[2]]
	testing.expect(t, presentation_ready, "the workspace divider drag should resolve a retained presentation frame")
	testing.expect(t, split_after_found && workspace_split_after.split_position == position_before+40,
		"dragging the Alicorn divider should update the retained split position")
	testing.expect(t, first_after_found && first_after.bounds.w > first_before_width &&
		second_after_found && second_after.bounds.w < second_before_width,
		fmt.tprintf("dragging the Alicorn divider should resize the real tree and editor panes (first %v -> %v; second %v -> %v)",
			first_before_width, first_after.bounds.w, second_before_width, second_after.bounds.w))
	_ = alicorn.process_pointer(&rt, alicorn.Pointer_Event{.Up, start_x+40, start_y, 1})
	alicorn.invalidate_root(&rt, "Scratchpad workspace split retention test rebuild")
	_ = build_app(rawptr(&app), &rt, 1100, 720, 1)
	workspace_split_id = 0
	for node_id in rt.order {
		node, node_found := rt.nodes[node_id]
		if node_found && node.kind == .Split && node.label == "scratchpad-workspace-editor-split" {
			workspace_split_id = node_id
			break
		}
	}
	retained_split, retained_split_found := rt.nodes[workspace_split_id]
	testing.expect(t, retained_split_found && retained_split.split_position == position_before+40,
		"the keyed split should retain the user's width across an application description rebuild")
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
	alicorn.end_frame(&ui)
	return true
}

test_click_workspace_tree_row :: proc(t: ^testing.T, app: ^App, rt: ^alicorn.Runtime, path: string) -> bool {
	id, found := test_workspace_tree_row(rt, path)
	if !found { return false }
	bounds := rt.nodes[id].bounds
	x, y := bounds.x + bounds.w/2, bounds.y + bounds.h/2
	_ = alicorn.process_pointer(rt, alicorn.Pointer_Event{.Down, x, y, 1})
	alicorn.invalidate_root(rt, "test pointer down")
	if !test_render_workspace_tree(t, app, rt) { return false }
	_ = alicorn.process_pointer(rt, alicorn.Pointer_Event{.Up, x, y, 1})
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
	if len(app.tree_root_path) > 0 { delete(app.tree_root_path, context.allocator) }
	alicorn.destroy_runtime(rt)
}

Editor_Edit_Test_Signal :: struct {
	sema: sync.Sema,
}

editor_edit_test_wake :: proc(data: rawptr) {
	if data == nil { return }
	signal := cast(^Editor_Edit_Test_Signal)data
	sync.sema_post(&signal.sema)
}

@(test)
test_backend_replace_document_transports_100k_paste_payload :: proc(t: ^testing.T) {
	sync.mutex_lock(&backend_integration_test_mutex)
	defer sync.mutex_unlock(&backend_integration_test_mutex)
	workspace, workspace_error := os.make_directory_temp("", "scratchpad-alicorn-large-edit-*", context.temp_allocator)
	if workspace_error != nil { testing.expect(t, false, "could not create a workspace for the bounded backend edit"); return }
	defer _ = os.remove_all(workspace)
	path := fmt.tprintf("%s/large-edit.txt", workspace)
	source, source_error := make([]u8, int(bridge.MAX_VISIBLE_BYTES), allocator=context.temp_allocator)
	if source_error != nil { testing.expect(t, false, "could not allocate the full visible-window source fixture"); return }
	defer delete(source, context.temp_allocator)
	for &byte in source { byte = 'a' }
	if write_error := os.write_entire_file_from_string(path, string(source)); write_error != nil {
		testing.expect(t, false, "could not write the full visible-window source fixture")
		return
	}
	backend_library, found_library := os.lookup_env("SCRATCHPAD_BACKEND_LIBRARY", context.temp_allocator)
	if !found_library { testing.expect(t, false, "large backend edit test requires the staged shared backend"); return }
	defer delete(backend_library, context.temp_allocator)
	app: App
	loaded, load_message := bridge.backend_load(&app.backend, backend_library)
	testing.expect(t, loaded, fmt.tprintf("shared backend should load for large edit: %s", load_message))
	if !loaded { return }
	started, start_message := bridge.backend_start(&app.backend, workspace, tree_test_wake, nil, context.allocator)
	testing.expect(t, started, fmt.tprintf("shared backend should start for large edit: %s", start_message))
	if !started { return }
	defer {
		if app.backend.started { _, _ = bridge.backend_stop(&app.backend, context.allocator) }
	}
	opened := bridge.backend_command(&app.backend, "open_path", path=path, allocator=context.allocator)
	testing.expect(t, opened.ok && len(app.backend.state.documents) == 1, "backend should open the bounded large-edit fixture")
	bridge.backend_command_result_destroy(&opened, context.allocator)
	document, document_found := find_document(&app.backend.state, app.backend.state.active)
	if !document_found { testing.expect(t, false, "backend should publish the opened large-edit document"); return }
	paste, paste_error := make([]int, 100*1024, allocator=context.temp_allocator)
	if paste_error != nil { testing.expect(t, false, "could not allocate the 100 KiB backend payload"); return }
	defer delete(paste, context.temp_allocator)
	for &value in paste { value = int('p') }
	edit := bridge.backend_command(
		&app.backend,
		"replace_document",
		document_id=document.id,
		editor_revision=document.editor_revision,
		start_byte=u64(len(source)),
		end_byte=u64(len(source)),
		replacement=paste,
		allocator=context.temp_allocator,
	)
	updated, updated_found := find_document(&app.backend.state, document.id)
	testing.expect(t, edit.ok && edit.edit.document_id == document.id &&
		edit.edit.editor_revision == document.editor_revision+1 &&
		edit.edit.new_end_byte == u64(len(source)+len(paste)) && updated_found && updated.dirty &&
		updated.editor_revision == edit.edit.editor_revision && updated.byte_length == u64(len(source)+len(paste)),
		"the real replace_document transport should accept one complete 100 KiB paste and publish its resulting revision/length")
	bridge.backend_command_result_destroy(&edit, context.temp_allocator)
	visible := bridge.backend_command(
		&app.backend,
		"read_visible_lines",
		document_id=document.id,
		start_line=0,
		max_lines=1,
		max_bytes=bridge.MAX_VISIBLE_BYTES,
		allocator=context.temp_allocator,
	)
	testing.expect(t, visible.ok && visible.visible_window_owned &&
		len(visible.visible_window.source) > 0 && len(visible.visible_window.source) <= int(bridge.MAX_VISIBLE_BYTES) &&
		visible.visible_window.line_byte_length == u64(len(source)+len(paste)) &&
		strings.has_prefix(string(visible.visible_window.source), "aaaa"),
		"the backend should continue to return a bounded visible chunk of the enlarged document")
	bridge.backend_command_result_destroy(&visible, context.temp_allocator)
}

@(test)
test_undo_waits_for_pending_optimistic_edit_and_restores_selection :: proc(t: ^testing.T) {
	sync.mutex_lock(&backend_integration_test_mutex)
	defer sync.mutex_unlock(&backend_integration_test_mutex)
	workspace, workspace_error := os.make_directory_temp("", "scratchpad-alicorn-undo-*", context.temp_allocator)
	if workspace_error != nil { testing.expect(t, false, "could not create a temporary workspace for queued Undo"); return }
	defer _ = os.remove_all(workspace)
	path := fmt.tprintf("%s/undo.txt", workspace)
	tail, tail_error := strings.repeat("line\n", 999, context.temp_allocator)
	if tail_error != nil { testing.expect(t, false, "could not create multi-line Undo fixture"); return }
	defer delete(tail, context.temp_allocator)
	source := fmt.aprintf("abc\n%s", tail, allocator=context.temp_allocator)
	defer delete(source, context.temp_allocator)
	if write_error := os.write_entire_file_from_string(path, source); write_error != nil {
		testing.expect(t, false, "could not create the Undo regression source fixture")
		return
	}
	backend_library, found_library := os.lookup_env("SCRATCHPAD_BACKEND_LIBRARY", context.temp_allocator)
	if !found_library { testing.expect(t, false, "queued Undo test requires the staged shared backend"); return }
	defer delete(backend_library, context.temp_allocator)

	app: App
	app.tree_directories = make([dynamic]Tree_Directory, 0, allocator=context.allocator)
	app.editor_views = make([dynamic]Editor_View_State, 0, allocator=context.allocator)
	app.editor_row_targets = make([dynamic]Editor_Row_Target, 0, allocator=context.allocator)
	app.editor_edits = make([dynamic]Editor_Edit_Intent, 0, allocator=context.allocator)
	app.deferred_actions = make([dynamic]Deferred_Action, 0, allocator=context.allocator)
	init_menus(&app)
	loaded, load_message := bridge.backend_load(&app.backend, backend_library)
	testing.expect(t, loaded, fmt.tprintf("shared backend should load for queued Undo: %s", load_message))
	if !loaded { return }
	signal: Editor_Edit_Test_Signal
	started, start_message := bridge.backend_start(&app.backend, workspace, editor_edit_test_wake, rawptr(&signal), context.allocator)
	testing.expect(t, started, fmt.tprintf("shared backend should start for queued Undo: %s", start_message))
	if !started { return }
	gate: sync.Sema
	if !bridge.editor_edit_lane_start(&app.editor_edit_lane, &app.backend, editor_edit_test_wake, rawptr(&signal), context.allocator, &gate) {
		testing.expect(t, false, "serial edit lane should start for queued Undo")
		_, _ = bridge.backend_stop(&app.backend, context.allocator)
		return
	}
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 640, 480})
	defer {
		for _ in 0..<8 { sync.sema_post(&gate) }
		if app.backend.started {
			_ = editor_flush_pending_edits(&app)
			_ = bridge.editor_edit_lane_stop(&app.editor_edit_lane)
			_, _ = bridge.backend_stop(&app.backend, context.allocator)
		}
		editor_window_destroy(&app.editor_window, context.allocator)
		editor_views_destroy(&app.editor_views, context.allocator)
		for index := len(app.editor_edits)-1; index >= 0; index -= 1 { editor_remove_edit(&app, index) }
		delete(app.editor_edits)
		deferred_actions_clear(&app)
		delete(app.deferred_actions)
		delete(app.editor_row_targets)
		tree_clear_directories(&app)
		delete(app.tree_directories)
		if len(app.tree_root_path) > 0 { delete(app.tree_root_path, context.allocator) }
		tree_clear_focused_path(&app)
		alicorn.destroy_runtime(&rt)
	}

	opened := bridge.backend_command(&app.backend, "open_path", path=path, allocator=context.allocator)
	testing.expect(t, opened.ok && len(app.backend.state.documents) == 1, "backend should open the multi-line Undo fixture")
	bridge.backend_command_result_destroy(&opened, context.allocator)
	document, doc_found := find_document(&app.backend.state, app.backend.state.active)
	if !doc_found { testing.expect(t, false, "opened document state should exist"); return }
	initial_editor_revision := document.editor_revision
	initial_line_count := document.line_count
	testing.expect(t, !document.dirty,
		fmt.tprintf("Undo/Redo fixture should start clean (dirty=%v lines=%d bytes=%d)", document.dirty, initial_line_count, document.byte_length))
	if document.dirty { return }
	testing.expect(t, initial_line_count >= 1000,
		fmt.tprintf("Undo/Redo fixture should publish at least 1000 stable lines (lines=%d bytes=%d)", initial_line_count, document.byte_length))
	if initial_line_count < 1000 { return }
	visible := bridge.backend_command(&app.backend, "read_visible_lines", document_id=document.id, start_line=0, max_lines=1, max_bytes=bridge.MAX_VISIBLE_BYTES, allocator=context.allocator)
	testing.expect(t, visible.ok && visible.visible_window_owned,
		fmt.tprintf("backend should provide the bounded source window (ok=%v owned=%v code=%s message=%s)",
			visible.ok, visible.visible_window_owned, visible.code, visible.message))
	if !visible.visible_window_owned { bridge.backend_command_result_destroy(&visible, context.allocator); return }
	window, window_ok, window_error := editor_window_from_visible(&visible.visible_window, context.allocator)
	app.editor_window = window
	app.editor_window_ready = window_ok
	bridge.backend_command_result_destroy(&visible, context.allocator)
	testing.expect(t, window_ok, window_error)
	if !window_ok { return }
	view_index, view_ok := editor_view_ensure(&app.editor_views, document.id)
	if !view_ok { testing.expect(t, false, "editor view should exist for queued Undo"); return }
	view := &app.editor_views[view_index]
	view.selection_anchor = 1
	view.caret_byte = 1
	app.editor_scroll_owner = editor_test_render_scroll_list(&rt, int(document.line_count))
	testing.expect(t, app.editor_scroll_owner != 0 && document.line_count == initial_line_count && initial_line_count >= 1000,
		fmt.tprintf("Undo regression should create a multi-page retained editor list (owner=%d lines=%d)", app.editor_scroll_owner, document.line_count))
	if app.editor_scroll_owner == 0 { return }
	_ = alicorn.scroll_region_set_offset(&rt, app.editor_scroll_owner, f32(900)*EDITOR_ROW_HEIGHT, "move viewport away before Undo")
	owner_before, owner_before_found := rt.nodes[app.editor_scroll_owner]
	testing.expect(t, owner_before_found && owner_before.scroll_offset_y > EDITOR_ROW_HEIGHT*800,
		"Undo regression should move the visible list far away from its original caret line")
	sync_runtime_actions(&app, &rt)
	sync_menu_states(&app)
	_, undo_state_before, undo_action_found := alicorn.action_lookup(&rt, action_id_for(ACTION_EDIT_UNDO))
	testing.expect(t, undo_action_found && !undo_state_before.enabled && !app.edit_items[0].state.enabled,
		"Undo should initially follow the backend's empty history state")
	editor_text_input(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Input_Event{kind=.Commit, text="X"})
	testing.expect(t, len(app.editor_edits) == 1 && string(view.optimistic_window.source) == "aXbc\n",
		"typing should immediately create one optimistic edit while the worker waits at its gate")
	_, undo_state_pending, undo_action_pending_found := alicorn.action_lookup(&rt, action_id_for(ACTION_EDIT_UNDO))
	testing.expect(t, undo_action_pending_found && undo_state_pending.enabled && app.edit_items[0].state.enabled,
		"a queued local edit should immediately enable runtime and native-menu Undo before its backend acknowledgement")
	dispatch_action(&app, &rt, ACTION_EDIT_UNDO)
	testing.expect(t, len(app.deferred_actions) == 1 && app.deferred_actions[0].value == ACTION_EDIT_UNDO,
		"Undo must queue behind an unacknowledged local edit even when published history metadata is stale")

	sync.sema_post(&gate)
	for _ in 0..<120 {
		_ = sync.sema_wait_with_timeout(&signal.sema, time.Duration(100_000_000))
		application_wake(rawptr(&app), &rt)
		if len(app.editor_edits) == 0 && len(app.deferred_actions) == 0 { break }
	}
	testing.expect(t, len(app.editor_edits) == 0 && len(app.deferred_actions) == 0,
		"the edit should acknowledge before the deferred Undo command runs")
	current, current_found := find_document(&app.backend.state, document.id)
	canonical := bridge.backend_command(&app.backend, "read_visible_lines", document_id=document.id, start_line=0, max_lines=1, max_bytes=bridge.MAX_VISIBLE_BYTES, allocator=context.temp_allocator)
	testing.expect(t, current_found && current.editor_revision == initial_editor_revision && !current.dirty &&
		current.byte_length == u64(len(source)) && current.line_count == initial_line_count &&
		canonical.ok && canonical.visible_window_owned && strings.has_prefix(string(canonical.visible_window.source), "abc\n"),
		"Go should apply the queued replacement then Undo, restoring source, editor revision, line count, and clean state")
	bridge.backend_command_result_destroy(&canonical, context.temp_allocator)
	testing.expect(t, view.selection_anchor == 1 && view.caret_byte == 1,
		"the Undo response should restore the original source selection through the semantic command result")
	owner_after, owner_after_found := rt.nodes[app.editor_scroll_owner]
	testing.expect(t, owner_after_found && owner_after.scroll_offset_y < EDITOR_ROW_HEIGHT,
		"Undo should reveal the restored cursor line after the viewport moved away")

	sync_runtime_actions(&app, &rt)
	sync_menu_states(&app)
	testing.expect(t, action_enabled(&app.backend.state, ACTION_EDIT_REDO),
		"Undo should publish enabled Redo metadata before the frontend dispatches the next history step")
	dispatch_action(&app, &rt, ACTION_EDIT_REDO)
	current, current_found = find_document(&app.backend.state, document.id)
	canonical = bridge.backend_command(&app.backend, "read_visible_lines", document_id=document.id, start_line=0, max_lines=1, max_bytes=bridge.MAX_VISIBLE_BYTES, allocator=context.temp_allocator)
	testing.expect(t, current_found && current.editor_revision == initial_editor_revision+1 && current.dirty &&
		current.byte_length == u64(len(source)+1) && current.line_count == initial_line_count &&
		canonical.ok && canonical.visible_window_owned && strings.has_prefix(string(canonical.visible_window.source), "aXbc\n"),
		"Redo should restore the edited source and revision, keep line count, and mark the document dirty")
	bridge.backend_command_result_destroy(&canonical, context.temp_allocator)
	testing.expect(t, view.selection_anchor == 2 && view.caret_byte == 2,
		"the Redo response should restore the post-edit caret selection")
}

@(test)
test_canonical_enter_ack_rebases_queued_source_positions :: proc(t: ^testing.T) {
	source, source_error := make([]u8, len("a\nXb"), allocator=context.allocator)
	if source_error != nil { testing.expect(t, false, "could not allocate the optimistic Enter fixture"); return }
	copy(source, "a\nXb")
	visible := bridge.Visible_Window{
		document_id="enter-rebase-test",
		start_line=0,
		end_line=2,
		start_byte=0,
		source=source,
	}
	window, window_ok, window_error := editor_window_from_visible(&visible, context.allocator)
	testing.expect(t, window_ok, window_error)
	if !window_ok { if len(visible.source) > 0 { delete(visible.source, context.allocator) }; return }
	app: App
	app.editor_edits = make([dynamic]Editor_Edit_Intent, 0, allocator=context.allocator)
	view := Editor_View_State{
		optimistic_window=window,
		optimistic_window_ready=true,
		selection_anchor=3,
		caret_byte=3,
	}
	first_id, first_id_error := strings.clone("enter-rebase-test", context.allocator)
	first_bytes, first_bytes_error := make([]u8, 1, allocator=context.allocator)
	second_id, second_id_error := strings.clone("enter-rebase-test", context.allocator)
	second_bytes, second_bytes_error := make([]u8, 1, allocator=context.allocator)
	if first_id_error != nil || first_bytes_error != nil || second_id_error != nil || second_bytes_error != nil {
		testing.expect(t, false, "could not allocate queued Enter-rebase intents")
		delete(first_id, context.allocator)
		delete(first_bytes, context.allocator)
		delete(second_id, context.allocator)
		delete(second_bytes, context.allocator)
		editor_window_destroy(&view.optimistic_window, context.allocator)
		delete(app.editor_edits)
		return
	}
	first_bytes[0] = '\n'
	second_bytes[0] = 'X'
	append(&app.editor_edits,
		Editor_Edit_Intent{document_id=first_id, start_byte=1, end_byte=1, replacement=first_bytes},
		Editor_Edit_Intent{document_id=second_id, start_byte=2, end_byte=2, replacement=second_bytes},
	)
	applied := []u8{'\r', '\n', ' ', ' '}
	reconciled := editor_reconcile_applied_replacement(&app, &view, &app.editor_edits[0], applied)
	testing.expect(t, reconciled && string(view.optimistic_window.source) == "a\r\n  Xb",
		"canonical CRLF plus Scratchpad indentation should replace the optimistic LF without losing later local text")
	testing.expect(t, app.editor_edits[1].start_byte == 5 && app.editor_edits[1].end_byte == 5 &&
		view.caret_byte == 6 && view.selection_anchor == 6,
		"acknowledging Scratchpad's longer Enter replacement should rebase queued edits and the local caret")
	for index := len(app.editor_edits)-1; index >= 0; index -= 1 { editor_remove_edit(&app, index) }
	delete(app.editor_edits)
	editor_window_destroy(&view.optimistic_window, context.allocator)
}

@(test)
test_optimistic_replacements_converge_and_stale_chain_recovers :: proc(t: ^testing.T) {
	sync.mutex_lock(&backend_integration_test_mutex)
	defer sync.mutex_unlock(&backend_integration_test_mutex)
	workspace, workspace_error := os.make_directory_temp("", "scratchpad-alicorn-edit-*", context.temp_allocator)
	if workspace_error != nil {
		testing.expect(t, false, "could not create a temporary workspace for the optimistic edit test")
		return
	}
	defer _ = os.remove_all(workspace)
	path := fmt.tprintf("%s/typing.txt", workspace)
	other_path := fmt.tprintf("%s/other.txt", workspace)
	if write_error := os.write_entire_file_from_string(path, "hello world\r\nsecond\r\nthird\r\n  fourth"); write_error != nil {
		testing.expect(t, false, "could not create the committed-text source fixture")
		return
	}
	if write_error := os.write_entire_file_from_string(other_path, "another document"); write_error != nil {
		testing.expect(t, false, "could not create the deferred-tab fixture")
		return
	}
	backend_library, found_library := os.lookup_env("SCRATCHPAD_BACKEND_LIBRARY", context.temp_allocator)
	if !found_library { testing.expect(t, false, "optimistic editor test requires the staged shared backend"); return }
	defer delete(backend_library, context.temp_allocator)

	app: App
	app.tree_directories = make([dynamic]Tree_Directory, 0, allocator=context.allocator)
	app.editor_views = make([dynamic]Editor_View_State, 0, allocator=context.allocator)
	app.editor_row_targets = make([dynamic]Editor_Row_Target, 0, allocator=context.allocator)
	app.editor_edits = make([dynamic]Editor_Edit_Intent, 0, allocator=context.allocator)
	app.deferred_actions = make([dynamic]Deferred_Action, 0, allocator=context.allocator)
	init_menus(&app)
	loaded, load_message := bridge.backend_load(&app.backend, backend_library)
	testing.expect(t, loaded, fmt.tprintf("shared backend should load for optimistic editor test: %s", load_message))
	if !loaded { return }
	signal: Editor_Edit_Test_Signal
	started, start_message := bridge.backend_start(&app.backend, workspace, editor_edit_test_wake, rawptr(&signal), context.allocator)
	testing.expect(t, started, fmt.tprintf("shared backend should start for optimistic editor test: %s", start_message))
	if !started { return }
	window_lane_started := bridge.visible_window_lane_start(
		&app.visible_window_lane,
		&app.backend,
		editor_edit_test_wake,
		rawptr(&signal),
		context.allocator,
	)
	testing.expect(t, window_lane_started, "the authoritative recovery test should start the bounded visible-window lane")
	if !window_lane_started { _, _ = bridge.backend_stop(&app.backend, context.allocator); return }
	gate: sync.Sema
	lane_started := bridge.editor_edit_lane_start(
		&app.editor_edit_lane,
		&app.backend,
		editor_edit_test_wake,
		rawptr(&signal),
		context.allocator,
		&gate,
	)
	testing.expect(t, lane_started, "one serial editor edit worker should start")
	if !lane_started {
		_ = bridge.visible_window_lane_stop(&app.visible_window_lane)
		_, _ = bridge.backend_stop(&app.backend, context.allocator)
		return
	}
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 1000, 700})
	defer {
		if app.backend.started {
			_ = bridge.visible_window_lane_stop(&app.visible_window_lane)
			for _ in 0..<128 { sync.sema_post(&gate) }
			_ = editor_flush_pending_edits(&app)
			_ = bridge.editor_edit_lane_stop(&app.editor_edit_lane)
			_, _ = bridge.backend_stop(&app.backend, context.allocator)
		}
		editor_window_destroy(&app.editor_window, context.allocator)
		editor_views_destroy(&app.editor_views, context.allocator)
		tree_clear_directories(&app)
		tree_clear_focused_path(&app)
		if len(app.tree_root_path) > 0 { delete(app.tree_root_path, context.allocator) }
		for index := len(app.editor_edits)-1; index >= 0; index -= 1 { editor_remove_edit(&app, index) }
		delete(app.editor_edits)
		deferred_actions_clear(&app)
		delete(app.deferred_actions)
		delete(app.editor_row_targets)
		if len(app.editor_presented_document_id) > 0 { delete(app.editor_presented_document_id, context.allocator) }
		if len(app.editor_window_error) > 0 { delete(app.editor_window_error, context.allocator) }
		if len(app.error_message) > 0 { delete(app.error_message, context.allocator) }
		alicorn.destroy_runtime(&rt)
	}
	opened := bridge.backend_command(&app.backend, "open_path", path=path, allocator=context.temp_allocator)
	testing.expect(t, opened.ok && len(app.backend.state.documents) == 1, "Go should open the real source document before editing")
	bridge.backend_command_result_destroy(&opened, context.temp_allocator)
	typing_document_id, id_error := strings.clone(app.backend.state.active, context.allocator)
	testing.expect(t, id_error == nil && typing_document_id != "", "the typing document identity should be retained for deferred command assertions")
	defer delete(typing_document_id, context.allocator)
	opened_other := bridge.backend_command(&app.backend, "open_path", path=other_path, allocator=context.temp_allocator)
	testing.expect(t, opened_other.ok && len(app.backend.state.documents) == 2, "the second document should open for tab-switch ordering coverage")
	bridge.backend_command_result_destroy(&opened_other, context.temp_allocator)
	selected_typing := bridge.backend_command(&app.backend, "select_document", document_id=typing_document_id, allocator=context.temp_allocator)
	testing.expect(t, selected_typing.ok, "the typing document should be active before committed input begins")
	bridge.backend_command_result_destroy(&selected_typing, context.temp_allocator)
	document, document_found := find_document(&app.backend.state, app.backend.state.active)
	if !document_found { testing.expect(t, false, "opened source document should have authoritative state"); return }
	base_editor_revision := document.editor_revision
	base_application_revision := app.backend.state.application_rev
	visible := bridge.backend_command(
		&app.backend,
		"read_visible_lines",
		document_id=document.id,
		start_line=0,
		max_lines=bridge.MAX_VISIBLE_LINES,
		max_bytes=bridge.MAX_VISIBLE_BYTES,
		allocator=context.allocator,
	)
	testing.expect(t, visible.ok && visible.visible_window_owned, "the initial source should arrive through the existing bounded window resource")
	if !visible.visible_window_owned { bridge.backend_command_result_destroy(&visible, context.allocator); return }
	window, window_ok, window_error := editor_window_from_visible(&visible.visible_window, context.allocator)
	app.editor_window = window
	app.editor_window_ready = window_ok
	bridge.backend_command_result_destroy(&visible, context.allocator)
	testing.expect(t, window_ok, window_error)
	if !window_ok { return }
	if !alicorn.text_engine_load_font(&rt.text_engine, ALICORN_TEST_UI_FONT_DATA) ||
	   !alicorn.text_engine_load_font_role(&rt.text_engine, .Monospace, ALICORN_TEST_MONO_FONT_DATA) {
		testing.expect(t, false, "optimistic editor test should load the bundled UI and monospace fonts")
		return
	}
	_ = build_app(rawptr(&app), &rt, 1000, 700, 1)
	view_index, view_ok := editor_view_ensure(&app.editor_views, document.id)
	testing.expect(t, view_ok && app.editor_scroll_owner != 0, "the real document build should create a durable editor owner")
	if !view_ok { return }
	view := &app.editor_views[view_index]
	view.caret_byte = 9 // hello wor|ld
	view.selection_anchor = view.caret_byte
	_ = alicorn.focus(&rt, app.editor_scroll_owner)
	_ = build_app(rawptr(&app), &rt, 1000, 700, 1)
	if caret_node := editor_row_node_for_line(app.editor_row_targets[:], 0); caret_node != 0 {
		geometry := alicorn.text_node_caret_geometry(&rt, caret_node, alicorn.Text_Position{byte=9, affinity=.Leading})
		area, area_ok := alicorn.text_input_area(&rt, app.editor_scroll_owner)
		testing.expect(t, geometry.valid && area_ok && area.rect.y == geometry.rect.y && area.rect.h >= geometry.rect.h,
			"the generic text-input candidate area should follow the shaped caret row after layout")
	} else {
		testing.expect(t, false, "focused source row should be retained for candidate-area geometry")
	}
	commits := [7]string{"x", "a", "b", "c", "d", "e", "f"}
	for text in commits {
		editor_text_input(
			rawptr(&app),
			&rt,
			app.editor_scroll_owner,
			host.Application_Text_Input_Event{kind=.Commit, text=text},
		)
	}
	// Replace a directional selection, then join lines with Backspace and
	// Delete. All three operations must share the same optimistic replacement
	// path while the first Caliber request remains deliberately blocked.
	view.selection_anchor = 9
	view.caret_byte = 16
	editor_text_input(
		rawptr(&app),
		&rt,
		app.editor_scroll_owner,
		host.Application_Text_Input_Event{kind=.Commit, text="X"},
	)
	second_line, second_found := editor_window_line(&view.optimistic_window, 1)
	testing.expect(t, second_found, "optimistic multi-line source should retain the second logical line")
	if second_found {
		view.selection_anchor = second_line.source_start
		view.caret_byte = second_line.source_start
		_ = editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Backspace})
	}
	joined_line, joined_found := editor_window_line(&view.optimistic_window, 0)
	testing.expect(t, joined_found, "Backspace at line start should leave the joined line available")
	if joined_found {
		view.selection_anchor = joined_line.source_end
		view.caret_byte = joined_line.source_end
		_ = editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Delete})
	}
	fourth_line, fourth_found := editor_window_line(&view.optimistic_window, 1)
	testing.expect(t, fourth_found, "the trailing indented line should remain addressable after cross-line joins")
	if fourth_found {
		view.selection_anchor = fourth_line.source_start+2
		view.caret_byte = fourth_line.source_start+2
		first_enter_handled := application_key(rawptr(&app), &rt, .Return)
		second_enter_handled := application_key(rawptr(&app), &rt, .Return)
		testing.expect(t, first_enter_handled && second_enter_handled,
			"the focused editor viewport should consume both Enter keys")
		tab_handled := editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Tab})
		testing.expect(t, tab_handled && strings.has_suffix(string(view.optimistic_window.source), "      fourth"),
			"Tab should insert one four-space indentation unit immediately without yielding editor focus")
		shift_tab_handled := editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Tab, shift=true})
		testing.expect(t, shift_tab_handled && strings.has_suffix(string(view.optimistic_window.source), "  fourth"),
			"Shift+Tab should remove one indentation unit from the current line through the same replacement lane")
		editor_text_input(
			rawptr(&app),
			&rt,
			app.editor_scroll_owner,
			host.Application_Text_Input_Event{kind=.Commit, text="X"},
		)
	}
	expected_optimistic := "hello worXldsecondthird\r\n  \r\n  \r\n  Xfourth"
	testing.expect(t, bridge.editor_edit_lane_is_active(&app.editor_edit_lane) && len(app.editor_edits) == 15,
		"the first request should be held in flight while replacements, Enter, and Tab indentation accumulate locally")
	testing.expect(t, view.optimistic_window_ready && string(view.optimistic_window.source) == expected_optimistic,
		"typing, selection replacement, cross-line deletion, and Scratchpad-indented Enter should update the bounded projection before backend acknowledgement")
	testing.expect(t, view.caret_byte == u64(len("hello worXldsecondthird\r\n  \r\n  \r\n  X")) &&
		view.optimistic_pending_edits == 15 && view.optimistic_window.end_line == 4 &&
		view.optimistic_line_delta == 0,
		"the replacement queue should preserve the caret and reflect both deleted and inserted logical lines immediately")
	other_document_id := ""
	for candidate in app.backend.state.documents {
		if candidate.id != typing_document_id { other_document_id = candidate.id; break }
	}
	other_document_id_copy, other_id_error := strings.clone(other_document_id, context.allocator)
	testing.expect(t, other_id_error == nil && other_document_id_copy != "", "the second document identity should be available for a queued tab switch")
	defer delete(other_document_id_copy, context.allocator)
	select_document(&app, &rt, other_document_id_copy)
	testing.expect(t, len(app.deferred_actions) == 1 && app.backend.state.active == typing_document_id && app.error_message == "",
		"tab selection should queue invisibly behind the edits without changing the active document or showing a wait error")
	_ = build_app(rawptr(&app), &rt, 1000, 700, 1)
	optimistic_text_rendered := false
	chrome_became_disabled := false
	for node_id in rt.order {
		if node, found := rt.nodes[node_id]; found {
			if node.key == fmt.tprintf("scratchpad-line:%s:0", document.id) {
				optimistic_text_rendered = node.text == "hello worXldsecondthird"
			}
			if node.key == "action-file-open" || node.key == "action-workspace-open" ||
			   node.key == "action-document-close" || node.key == fmt.tprintf("tab:%s", typing_document_id) ||
			   node.key == fmt.tprintf("tab-close:%s", typing_document_id) {
				chrome_became_disabled = chrome_became_disabled || node.disabled
			}
		}
	}
	testing.expect(t, optimistic_text_rendered,
		"the rebuilt Alicorn description should visibly contain all committed characters before the backend lane is released")
	testing.expect(t, !chrome_became_disabled,
		"pending editor acknowledgements must not flash the toolbar or tab controls into disabled styling")
	testing.expect(t, app.file_items[0].state.enabled && app.file_items[1].state.enabled,
		"native menu availability should remain stable while source edits are pending")
	state_while_held, state_held_ok, state_held_error := bridge.backend_read_latest(&app.backend, context.temp_allocator)
	testing.expect(t, state_held_ok && !state_while_held && app.backend.state.application_rev == base_application_revision,
		fmt.tprintf("the held worker must not mutate or publish backend state before its dispatch gate opens: %s", state_held_error))
	canonical_before_ack := bridge.backend_command(
		&app.backend,
		"read_visible_lines",
		document_id=document.id,
		start_line=0,
		max_lines=bridge.MAX_VISIBLE_LINES,
		max_bytes=bridge.MAX_VISIBLE_BYTES,
		allocator=context.temp_allocator,
	)
	testing.expect(t, canonical_before_ack.ok && string(canonical_before_ack.visible_window.source) == "hello world\r\nsecond\r\nthird\r\n  fourth",
		"the authoritative document should remain unchanged while only the first local edit is queued")
	bridge.backend_command_result_destroy(&canonical_before_ack, context.temp_allocator)
	for _ in 0..<15 { sync.sema_post(&gate) }
	for _ in 0..<120 {
		if len(app.editor_edits) == 0 { break }
		_ = sync.sema_wait_with_timeout(&signal.sema, time.Duration(100_000_000))
		application_wake(rawptr(&app), &rt)
	}
	testing.expect(t, len(app.editor_edits) == 0 && len(app.deferred_actions) == 0 && view.optimistic_pending_edits == 0,
		"all delayed edits should be acknowledged serially and then drain the deferred tab selection")
	testing.expect(t, app.backend.state.active == other_document_id_copy,
		"the queued tab switch should execute after the final authoritative edit acknowledgement")
	document_after, found_after := find_document(&app.backend.state, document.id)
	testing.expect(t, found_after && document_after.editor_revision == base_editor_revision+15 && document_after.line_count == 4,
		"every replacement and Enter should converge through its own ordered revision and update authoritative line topology")
	canonical_after := bridge.backend_command(
		&app.backend,
		"read_visible_lines",
		document_id=typing_document_id,
		start_line=0,
		max_lines=bridge.MAX_VISIBLE_LINES,
		max_bytes=bridge.MAX_VISIBLE_BYTES,
		allocator=context.temp_allocator,
	)
	testing.expect(t, canonical_after.ok && canonical_after.visible_window_owned && string(canonical_after.visible_window.source) == expected_optimistic,
		"the final Caliber visible window should match the complete local replacement projection")
	bridge.backend_command_result_destroy(&canonical_after, context.temp_allocator)

	// Start a second chain, accept its first replacement, then mutate the
	// authoritative document before the next serialized request is dispatched.
	// The stale edit and all dependent local edits must be discarded together.
	select_document(&app, &rt, typing_document_id)
	document_before_stale, found_before_stale := find_document(&app.backend.state, typing_document_id)
	testing.expect(t, found_before_stale, "the source document should be active for stale-chain recovery")
	if !found_before_stale { return }
	stale_base_revision := document_before_stale.editor_revision
	publication_before_external_edit := app.backend.state_revision
	view_index, view_ok = editor_view_ensure(&app.editor_views, typing_document_id)
	testing.expect(t, view_ok, "the source document should retain its local editor view across tab changes")
	if !view_ok { return }
	view = &app.editor_views[view_index]
	view.caret_byte = view.optimistic_window.start_byte+u64(len(view.optimistic_window.source))
	view.selection_anchor = view.caret_byte
	stale_chain_commits := [4]string{"a", "b", "c", "d"}
	for text in stale_chain_commits {
		editor_text_input(
			rawptr(&app),
			&rt,
			app.editor_scroll_owner,
			host.Application_Text_Input_Event{kind=.Commit, text=text},
		)
	}
	testing.expect(t, len(app.editor_edits) == 4 &&
		string(view.optimistic_window.source) == fmt.tprintf("%sabcd", expected_optimistic),
		"four rapid local edits should be visible while only the first request is in flight")
	sync.sema_post(&gate)
	for _ in 0..<120 {
		if len(app.editor_edits) == 3 && view.authoritative_revision == stale_base_revision+1 { break }
		_ = sync.sema_wait_with_timeout(&signal.sema, time.Duration(100_000_000))
		application_wake(rawptr(&app), &rt)
	}
	testing.expect(t, len(app.editor_edits) == 3 && view.authoritative_revision == stale_base_revision+1,
		"the first edit should be accepted and the dependent second edit should be the sole in-flight request")
	canonical_after_first := bridge.backend_command(
		&app.backend,
		"read_visible_lines",
		document_id=typing_document_id,
		start_line=0,
		max_lines=bridge.MAX_VISIBLE_LINES,
		max_bytes=bridge.MAX_VISIBLE_BYTES,
		allocator=context.temp_allocator,
	)
	testing.expect(t, canonical_after_first.ok && canonical_after_first.visible_window_owned &&
		string(canonical_after_first.visible_window.source) == fmt.tprintf("%sa", expected_optimistic),
		"the first replacement should be authoritative before the dependent request is challenged")
	concurrent_change_byte := canonical_after_first.visible_window.start_byte+u64(len(canonical_after_first.visible_window.source))
	bridge.backend_command_result_destroy(&canonical_after_first, context.temp_allocator)
	concurrent_change := bridge.backend_command(
		&app.backend,
		"replace_document",
		document_id=typing_document_id,
		editor_revision=view.authoritative_revision,
		start_byte=concurrent_change_byte,
		end_byte=concurrent_change_byte,
		replacement=[]int{'!'},
		allocator=context.temp_allocator,
	)
	testing.expect(t, concurrent_change.ok,
		"an external authoritative edit should advance the revision while the next serial request remains gated")
	bridge.backend_command_result_destroy(&concurrent_change, context.temp_allocator)
	testing.expect(t, view.optimistic_pending_edits == 3 && len(app.editor_edits) == 3,
		"the optimistic dependent chain should remain local until the stale response is handled")
	// Reproduce a stale local publication: another command advanced the real
	// document, but this frontend has not yet adopted that newer state envelope.
	app.backend.state_revision = publication_before_external_edit
	for &stale_document in app.backend.state.documents {
		if stale_document.id == typing_document_id {
			stale_document.editor_revision = stale_base_revision+1
			break
		}
	}
	sync.sema_post(&gate)
	for _ in 0..<120 {
		if len(app.editor_edits) == 0 { break }
		_ = sync.sema_wait_with_timeout(&signal.sema, time.Duration(100_000_000))
		application_wake(rawptr(&app), &rt)
	}
	testing.expect(t, len(app.editor_edits) == 0 && view.optimistic_pending_edits == 0 &&
		!view.optimistic_window_ready && view.position_reconcile_pending,
		"a stale request must discard itself and every dependent optimistic edit, then invalidate the old bounded window")
	conflicted_document, conflicted_document_found := find_document(&app.backend.state, typing_document_id)
	testing.expect(t, conflicted_document_found && conflicted_document.editor_revision == stale_base_revision+2 &&
		app.backend.state_revision > publication_before_external_edit && !app.editor_window_ready,
		"stale rejection should adopt the newer state publication and evict any cached window before recovery")
	testing.expect(t, strings.contains(app.error_message, "reloading authoritative text"),
		"stale rejection should report the controlled recovery instead of silently diverging")

	// Rebuild asks the existing visible-window lane for the canonical revision.
	_ = build_app(rawptr(&app), &rt, 1000, 700, 1)
	for _ in 0..<120 {
		current_document, current_found := find_document(&app.backend.state, typing_document_id)
		if current_found && app.editor_window_ready &&
		   app.editor_window.document_id == typing_document_id &&
		   app.editor_window.editor_revision == current_document.editor_revision { break }
		_ = sync.sema_wait_with_timeout(&signal.sema, time.Duration(100_000_000))
		application_wake(rawptr(&app), &rt)
	}
	recovered_document, recovered_found := find_document(&app.backend.state, typing_document_id)
	testing.expect(t, recovered_found, "the authoritative source document should survive stale recovery")
	if !recovered_found { return }
	recovered_revision := recovered_document.editor_revision
	recovered_expected := fmt.tprintf("%sa!", expected_optimistic)
	_, caret_is_legal := editor_line_for_source(&app.editor_window, view.caret_byte)
	testing.expect(t, recovered_found && app.editor_window_ready &&
		app.editor_window.editor_revision == recovered_document.editor_revision &&
		string(app.editor_window.source) == recovered_expected,
		"the bounded window should reload the exact authoritative bytes, including the concurrent edit but excluding rejected dependents")
	testing.expect(t, !view.position_reconcile_pending &&
		view.authoritative_revision == recovered_revision &&
		view.caret_byte >= app.editor_window.start_byte &&
		view.caret_byte <= app.editor_window.start_byte+u64(len(app.editor_window.source)) &&
		caret_is_legal,
		"recovery should clamp and normalize the caret to a legal source boundary in the reloaded window")
	testing.expect(t, app.error_message == "",
		"a successful authoritative reload should clear the temporary stale-edit alert")

	// The recovered editor remains usable: a new local edit should be accepted
	// against the new authoritative revision and converge normally.
	editor_text_input(
		rawptr(&app),
		&rt,
		app.editor_scroll_owner,
		host.Application_Text_Input_Event{kind=.Commit, text="z"},
	)
	testing.expect(t, len(app.editor_edits) == 1 &&
		string(view.optimistic_window.source) == fmt.tprintf("%sz", recovered_expected),
		"typing should resume immediately on the recovered authoritative projection")
	sync.sema_post(&gate)
	for _ in 0..<120 {
		if len(app.editor_edits) == 0 { break }
		_ = sync.sema_wait_with_timeout(&signal.sema, time.Duration(100_000_000))
		application_wake(rawptr(&app), &rt)
	}
	final_document, final_found := find_document(&app.backend.state, typing_document_id)
	canonical_final := bridge.backend_command(
		&app.backend,
		"read_visible_lines",
		document_id=typing_document_id,
		start_line=0,
		max_lines=bridge.MAX_VISIBLE_LINES,
		max_bytes=bridge.MAX_VISIBLE_BYTES,
		allocator=context.temp_allocator,
	)
	final_expected := fmt.tprintf("%sz", recovered_expected)
	testing.expect(t, len(app.editor_edits) == 0 && view.optimistic_pending_edits == 0 &&
		final_found && final_document.editor_revision == recovered_revision+1 &&
		view.authoritative_revision == final_document.editor_revision &&
		canonical_final.ok && canonical_final.visible_window_owned &&
		string(canonical_final.visible_window.source) == final_expected &&
		string(view.optimistic_window.source) == string(canonical_final.visible_window.source),
		"post-recovery editing should converge with no pending edits and identical optimistic/canonical bytes")
	bridge.backend_command_result_destroy(&canonical_final, context.temp_allocator)
	testing.expect(t, app.backend.state_leases == 0 && app.backend.resource_leases == 0,
		"the success and stale-recovery paths should leave no Caliber publication or resource leases outstanding")
}
