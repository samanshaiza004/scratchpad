package main

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"
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

editor_test_build_recovery_text_target :: proc(ui: ^alicorn.UI, view: ^Editor_View_State) -> (owner: alicorn.Node_ID, added: bool) {
	alicorn.container_begin(ui, .Root, key=alicorn.key_string("recovery-target-test-root"), style=alicorn.layout_style(grow=1))
	owner = alicorn.container_begin(ui, .Container, key=alicorn.key_string("recovery-target-test-node"), style=alicorn.layout_style(grow=1))
	added = editor_register_text_input_target(ui, owner, view)
	alicorn.container_end(ui)
	alicorn.container_end(ui)
	return
}

@(test)
test_editor_subword_boundaries_and_pair_mapping :: proc(t: ^testing.T) {
	next, handled := editor_subword_move_ascii("helloWorld", 0, 1)
	testing.expect(t, handled && next == 5, "subword-right should stop between lower- and upper-case identifier runs")
	next, handled = editor_subword_move_ascii("helloWorld", 10, -1)
	testing.expect(t, handled && next == 5, "subword-left should stop at the matching camel-case boundary")
	next, handled = editor_subword_move_ascii("HTTPServer", 0, 1)
	testing.expect(t, handled && next == 4, "an acronym should form one subword before the following capitalized word")
	next, handled = editor_subword_move_ascii("item42Name", 0, 1)
	testing.expect(t, handled && next == 4, "subword movement should stop at an identifier digit transition")
	_, handled = editor_subword_move_ascii("日本語", 0, 1)
	testing.expect(t, !handled, "non-ASCII word movement should remain on Runa's Unicode path")
	testing.expect(t,
		editor_pair_closer_for_opener('(') == ')' && editor_pair_closer_for_opener('[') == ']' &&
		editor_pair_closer_for_opener('{') == '}' && editor_pair_closer_for_opener('x') == 0,
		"auto-pair mapping should be limited to the supported balanced delimiters")
}

@(test)
test_editor_markdown_enter_projection_matches_list_continuation_and_breakout :: proc(t: ^testing.T) {
	window := Editor_Window{start_byte=40, source=[]u8{'-', ' ', 'i', 't', 'e', 'm'}}
	line := Editor_Display_Line{logical_line=3, source_start=40, source_end=46}
	continued, continued_ok := editor_markdown_enter_projection(&window, &line, 46)
	defer delete(continued.replacement, context.temp_allocator)
	testing.expect(t, continued_ok && continued.start_byte == 46 && continued.end_byte == 46 &&
		string(continued.replacement) == "\n- ",
		"Markdown Enter should optimistically continue a non-empty unordered list item")

	empty_window := Editor_Window{start_byte=0, source=[]u8{' ', ' ', '-', ' '}}
	empty_line := Editor_Display_Line{logical_line=0, source_start=0, source_end=4}
	breakout, breakout_ok := editor_markdown_enter_projection(&empty_window, &empty_line, 4)
	defer delete(breakout.replacement, context.temp_allocator)
	testing.expect(t, breakout_ok && breakout.breakout && breakout.start_byte == 2 && breakout.end_byte == 4 &&
		string(breakout.replacement) == "\n  ",
		"Enter on an empty list item should remove its marker and leave the list at the same indentation")

	crlf_window := Editor_Window{start_byte=0, source=[]u8{'-', ' ', 'x', '\r', '\n'}}
	crlf_line := Editor_Display_Line{logical_line=0, source_start=0, source_end=3}
	crlf, crlf_ok := editor_markdown_enter_projection(&crlf_window, &crlf_line, 3)
	defer delete(crlf.replacement, context.temp_allocator)
	testing.expect(t, crlf_ok && string(crlf.replacement) == "\r\n- ",
		"optimistic Markdown continuation should preserve a CRLF document's local line ending")
}

@(test)
test_go_to_line_parses_one_based_line_and_grapheme_column :: proc(t: ^testing.T) {
	line, column, ok := go_to_line_parse(" 12:5 ", 20)
	testing.expect(t, ok && line == 11 && column == 5, "Go to Line should translate one-based line:column input")
	line, column, ok = go_to_line_parse("999", 20)
	testing.expect(t, ok && line == 19 && column == 1, "Go to Line should clamp an oversized line to the document end")
	_, _, ok = go_to_line_parse("0:1", 20)
	testing.expect(t, !ok, "Go to Line should reject a zero line number")
	_, _, ok = go_to_line_parse("1:0", 20)
	testing.expect(t, !ok, "Go to Line should reject a zero column")
	_, _, ok = go_to_line_parse("18446744073709551616", 20)
	testing.expect(t, !ok, "Go to Line should reject decimal overflow")
}

@(test)
test_editor_bracket_match_is_bounded_and_nested :: proc(t: ^testing.T) {
	window := Editor_Window{start_byte=100, source=[]u8{'(', 'a', '[', 'b', ']', ')'}}
	outer, outer_ok := editor_bracket_match_in_window(&window, 101)
	testing.expect(t, outer_ok && outer.first == 100 && outer.second == 105,
		"caret after an opening parenthesis should find its nested matching close")
	inner, inner_ok := editor_bracket_match_in_window(&window, 104)
	testing.expect(t, inner_ok && inner.first == 102 && inner.second == 104,
		"caret before a closing bracket should find its matching open")
	partial := Editor_Window{start_byte=100, source=[]u8{'(', 'x'}}
	_, partial_ok := editor_bracket_match_in_window(&partial, 101)
	testing.expect(t, !partial_ok, "bracket matching must not infer a pair outside the bounded source window")
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

	clipboard := Editor_Test_Clipboard{text="clipboard text", read_ok=true, write_ok=true}
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
	view.selection_anchor, view.caret_byte = u64(len(source)+10), u64(len(source)+11)
	clipboard.text = ""
	editor_clipboard_command(&app, &rt, ACTION_EDIT_PASTE)
	testing.expect(t, len(app.editor_edits) == 0 && clipboard.reads == 1,
		"an empty clipboard should be a no-op even when the selection is outside the loaded window")

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
	testing.expect(t, clipboard.writes == 2 && clipboard.last_write == "a" && len(app.editor_edits) == 1 &&
		len(view.optimistic_window.source) == len(source)-1 && view.optimistic_window.source[0] == 'a',
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

	view.selection_anchor, view.caret_byte = 0, 1
	view.optimistic_window.source[0] = 0xFF
	edit_count := len(app.editor_edits)
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
