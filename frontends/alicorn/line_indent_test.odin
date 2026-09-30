package main

import "core:mem"
import "core:testing"
import bridge "./bridge"

editor_test_indent_window :: proc(t: ^testing.T, text: string, truncated: bool = false) -> (Editor_Window, bool) {
	bytes, allocation_error := make([]u8, len(text), allocator=context.temp_allocator)
	testing.expect(t, allocation_error == nil, "indent fixture should allocate source bytes")
	if allocation_error != nil { return {}, false }
	if len(text) > 0 { mem.copy(rawptr(&bytes[0]), rawptr(raw_data(text)), len(text)) }
	line_count := 1
	for value in text { if value == '\n' { line_count += 1 } }
	visible := bridge.Visible_Window{
		document_id="indent-test",
		application_rev=1,
		editor_revision=1,
		start_line=0,
		end_line=u64(line_count),
		start_byte=0,
		truncated=truncated,
		source=bytes,
	}
	parsed, parsed_ok, message := editor_window_from_visible(&visible, context.temp_allocator)
	testing.expect(t, parsed_ok, message)
	if !parsed_ok && len(visible.source) > 0 { delete(visible.source, context.temp_allocator) }
	return parsed, parsed_ok
}

@(test)
test_editor_multiline_indent_preserves_crlf_and_directional_selection :: proc(t: ^testing.T) {
	window, ok := editor_test_indent_window(t, "one\r\n  two\r\nthree\r\nfour")
	if !ok { return }
	defer editor_window_destroy(&window, context.temp_allocator)
	indent := [?]u8{' ', ' ', ' ', ' '}
	projection := editor_line_indent_projection(&window, 16, 7, indent[:], false, context.temp_allocator)
	defer delete(projection.replacement, context.temp_allocator)
	testing.expect(t, projection.ok && projection.changed, "a complete multi-line selection should produce an indent edit")
	testing.expect(t, projection.start_byte == 5 && projection.end_byte == 19,
		"indent should replace exactly the touched complete rows including their original CRLF separators")
	testing.expect(t, string(projection.replacement) == "      two\r\n    three\r\n",
		"indent should prefix each selected logical row without normalizing CRLF")
	testing.expect(t, projection.anchor_byte == 24 && projection.caret_byte == 11,
		"indent should preserve reverse selection direction and each endpoint's source-relative position")

	// Treat the indented projection as the current authoritative window and
	// verify that the reverse transformation restores the original selection.
	updated, updated_ok, update_error := editor_window_replace_bytes(
		&window, projection.start_byte, projection.end_byte, projection.replacement, context.temp_allocator,
	)
	if !updated_ok { testing.expect(t, false, update_error); return }
	defer editor_window_destroy(&updated, context.temp_allocator)
	undo_projection := editor_line_indent_projection(
		&updated, projection.anchor_byte, projection.caret_byte, indent[:], true, context.temp_allocator,
	)
	defer delete(undo_projection.replacement, context.temp_allocator)
	testing.expect(t, undo_projection.ok && string(undo_projection.replacement) == "  two\r\nthree\r\n",
		"outdent should reverse the complete line block without changing line endings")
	testing.expect(t, undo_projection.anchor_byte == 16 && undo_projection.caret_byte == 7,
		"outdent should restore the original directional selection coordinates")
}

@(test)
test_editor_multiline_indent_excludes_line_at_selection_end :: proc(t: ^testing.T) {
	window, ok := editor_test_indent_window(t, "a\nb\nc")
	if !ok { return }
	defer editor_window_destroy(&window, context.temp_allocator)
	indent := [?]u8{' ', ' ', ' ', ' '}
	projection := editor_line_indent_projection(&window, 4, 0, indent[:], false, context.temp_allocator)
	defer delete(projection.replacement, context.temp_allocator)
	testing.expect(t, projection.ok && string(projection.replacement) == "    a\n    b\n",
		"a selection ending at column zero should indent the preceding row but exclude the next row")
	testing.expect(t, projection.anchor_byte == 12 && projection.caret_byte == 4,
		"selection endpoints should map through preceding line insertions without changing direction")
}

@(test)
test_editor_multiline_outdent_handles_tabs_partial_spaces_and_bom :: proc(t: ^testing.T) {
	window, ok := editor_test_indent_window(t, "\xEF\xBB\xBF\talpha\n  beta\n gamma\nplain")
	if !ok { return }
	defer editor_window_destroy(&window, context.temp_allocator)
	indent := [?]u8{' ', ' ', ' ', ' '}
	projection := editor_line_indent_projection(&window, 0, u64(len(window.source)), indent[:], true, context.temp_allocator)
	defer delete(projection.replacement, context.temp_allocator)
	testing.expect(t, projection.ok && projection.changed, "outdent should remove available indentation from selected rows")
	testing.expect(t, string(projection.replacement) == "\xEF\xBB\xBFalpha\nbeta\ngamma\nplain",
		"outdent should preserve a BOM, remove one tab or up to one indentation unit, and leave unindented rows intact")
}

@(test)
test_editor_multiline_indent_refuses_a_truncated_last_row :: proc(t: ^testing.T) {
	window, ok := editor_test_indent_window(t, "a\nb", true)
	if !ok { return }
	defer editor_window_destroy(&window, context.temp_allocator)
	indent := [?]u8{' ', ' ', ' ', ' '}
	projection := editor_line_indent_projection(&window, 0, 3, indent[:], false, context.temp_allocator)
	defer delete(projection.replacement, context.temp_allocator)
	testing.expect(t, !projection.ok, "a selected final row in a truncated window must not be transformed")
}
