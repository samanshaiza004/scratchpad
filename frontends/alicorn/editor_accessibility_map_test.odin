package main

import "core:testing"
import alicorn "alicorn:runtime"

@(test)
test_editor_accessibility_map_round_trips_unicode_grapheme_boundaries :: proc(t: ^testing.T) {
	source := "A\r\ncafé 日本語 👨‍👩‍👧‍👦 Z"
	projection := editor_accessibility_projection_build("unicode-document", source, 17, context.temp_allocator)
	defer editor_accessibility_projection_destroy(&projection)

	testing.expect(t, projection.complete && projection.supported && projection.unsupported_reason == .None,
		"a valid complete Unicode snapshot should produce a supported projection")
	testing.expect(t, projection.document_id == "unicode-document" && projection.byte_length == u64(len(source)),
		"the projection should identify its source document and exact byte length")
	testing.expect(t, projection.editor_revision == 17,
		"the projection should retain the exact source editor revision")
	testing.expect(t, len(projection.runs) == 1,
		"the small Unicode fixture should fit in one semantic text run")
	if len(projection.runs) != 1 { return }
	run := projection.runs[0]
	crlf_unit_found := false
	family_unit_found := false
	global_byte: u64 = 0
	for byte_length in run.character_lengths {
		if byte_length == 2 && global_byte == 1 { crlf_unit_found = true }
		if byte_length == 25 { family_unit_found = true }
		global_byte += u64(byte_length)
		position, position_ok := editor_accessibility_projection_source_to_position(&projection, global_byte)
		mapped_byte, byte_ok := editor_accessibility_position_to_source(&projection, position)
		testing.expect(t, position_ok && byte_ok && mapped_byte == global_byte,
			"every selectable grapheme boundary should round-trip to its exact source byte")
	}
	testing.expect(t, crlf_unit_found, "CRLF should be represented as one two-byte selectable unit")
	testing.expect(t, family_unit_found, "the family ZWJ sequence should remain one selectable grapheme")
	testing.expect(t, global_byte == u64(len(source)), "grapheme byte lengths should cover the source exactly")

	between_crlf, crlf_boundary_ok := editor_accessibility_projection_source_to_position(&projection, 2)
	_, _ = between_crlf, crlf_boundary_ok
	testing.expect(t, !crlf_boundary_ok, "the byte boundary between CR and LF must not split the selectable unit")
	_, combining_boundary_ok := editor_accessibility_projection_source_to_position(&projection, 7)
	testing.expect(t, !combining_boundary_ok, "a byte inside the combining grapheme must not map to a text position")
	_, family_boundary_ok := editor_accessibility_projection_source_to_position(&projection, 21)
	testing.expect(t, !family_boundary_ok, "a byte inside the family ZWJ grapheme must not map to a text position")

	selection, selection_ok := editor_accessibility_source_selection_to_semantic(&projection, u64(len(source)), 0)
	anchor_byte, caret_byte, reverse_ok := editor_accessibility_semantic_selection_to_source(&projection, selection)
	testing.expect(t, selection_ok && reverse_ok && anchor_byte == u64(len(source)) && caret_byte == 0,
		"directional anchor/caret order should survive semantic selection conversion")
	line_at_cr, line_at_cr_ok := editor_accessibility_source_to_line(&projection, 1)
	line_between_crlf, crlf_line_ok := editor_accessibility_source_to_line(&projection, 2)
	line_after_lf, after_lf_ok := editor_accessibility_source_to_line(&projection, 3)
	testing.expect(t, line_at_cr_ok && line_at_cr == 0 && crlf_line_ok && line_between_crlf == 0 && after_lf_ok && line_after_lf == 1,
		"line lookup should count LF once and keep CRLF on one logical line break")
}

@(test)
test_editor_accessibility_map_chunks_at_limits_and_prefers_newline :: proc(t: ^testing.T) {
	first_line_bytes := 40 * 1024
	second_line_bytes := 40 * 1024
	source_bytes := make([]u8, first_line_bytes+1+second_line_bytes, allocator=context.temp_allocator)
	defer delete(source_bytes, context.temp_allocator)
	for index in 0..<first_line_bytes { source_bytes[index] = 'a' }
	source_bytes[first_line_bytes] = '\n'
	for index in 0..<second_line_bytes { source_bytes[first_line_bytes+1+index] = 'b' }
	source := string(source_bytes)
	projection := editor_accessibility_projection_build("chunked-document", source, 3, context.temp_allocator)
	defer editor_accessibility_projection_destroy(&projection)

	testing.expect(t, projection.complete && projection.supported && len(projection.runs) == 2,
		"an 80 KiB two-line source should produce a complete pair of bounded runs")
	if len(projection.runs) != 2 { return }
	first, second := projection.runs[0], projection.runs[1]
	testing.expect(t, first.source_end == u64(first_line_bytes+1) && first.value[len(first.value)-1] == '\n',
		"the first chunk should prefer the available newline boundary")
	testing.expect(t, first.source_start == 0 && second.source_start == first.source_end && second.source_end == u64(len(source)),
		"chunks should form contiguous, non-overlapping coverage of the source")
	testing.expect(t, len(first.value) <= EDITOR_ACCESSIBILITY_MAX_RUN_BYTES && len(second.value) <= EDITOR_ACCESSIBILITY_MAX_RUN_BYTES,
		"no semantic run may exceed the 64 KiB byte cap")
	testing.expect(t, first.logical_start_line == 0 && second.logical_start_line == 1,
		"each run should retain its zero-based logical start line")

	boundary_position, boundary_ok := editor_accessibility_projection_source_to_position(&projection, first.source_end)
	testing.expect(t, boundary_ok && boundary_position.run_id == second.id && boundary_position.character_index == 0,
		"a run-boundary byte belongs to the following run")
	eof_position, eof_ok := editor_accessibility_projection_source_to_position(&projection, projection.byte_length)
	testing.expect(t, eof_ok && eof_position.run_id == second.id && eof_position.character_index == u64(len(second.character_lengths)),
		"EOF belongs to the final run")
	line_at_newline, line_at_newline_ok := editor_accessibility_source_to_line(&projection, u64(first_line_bytes))
	line_after_newline, after_newline_ok := editor_accessibility_source_to_line(&projection, u64(first_line_bytes+1))
	testing.expect(t, line_at_newline_ok && line_at_newline == 0 && after_newline_ok && line_after_newline == 1,
		"line lookup should advance only after consuming the LF byte")
	selection, selection_ok := editor_accessibility_source_selection_to_semantic(
		&projection,
		first.source_end-1,
		first.source_end+1,
	)
	anchor_byte, caret_byte, reverse_ok := editor_accessibility_semantic_selection_to_source(&projection, selection)
	testing.expect(t, selection_ok && reverse_ok && anchor_byte == first.source_end-1 && caret_byte == first.source_end+1,
		"directional selection should round-trip across two semantic runs")

	// No newline is available before the limit. The final three-byte Japanese
	// grapheme must move intact to the next chunk instead of being split.
	hard_boundary_bytes := make([]u8, EDITOR_ACCESSIBILITY_MAX_RUN_BYTES+2, allocator=context.temp_allocator)
	defer delete(hard_boundary_bytes, context.temp_allocator)
	for index in 0..<(EDITOR_ACCESSIBILITY_MAX_RUN_BYTES-1) { hard_boundary_bytes[index] = 'x' }
	hard_boundary_bytes[EDITOR_ACCESSIBILITY_MAX_RUN_BYTES-1] = 0xE6
	hard_boundary_bytes[EDITOR_ACCESSIBILITY_MAX_RUN_BYTES] = 0x97
	hard_boundary_bytes[EDITOR_ACCESSIBILITY_MAX_RUN_BYTES+1] = 0xA5
	hard_boundary := editor_accessibility_projection_build(
		"hard-boundary-document",
		string(hard_boundary_bytes),
		1,
		context.temp_allocator,
	)
	defer editor_accessibility_projection_destroy(&hard_boundary)
	testing.expect(t, hard_boundary.complete && hard_boundary.supported && len(hard_boundary.runs) == 2,
		"a source without a nearby newline should still split into bounded runs")
	if len(hard_boundary.runs) == 2 {
		testing.expect(t, len(hard_boundary.runs[0].value) == EDITOR_ACCESSIBILITY_MAX_RUN_BYTES-1 && hard_boundary.runs[1].value == "日",
			"the hard chunk boundary must fall before, not inside, a multibyte grapheme")
	}
}

@(test)
test_editor_accessibility_map_empty_document_has_caret_run :: proc(t: ^testing.T) {
	projection := editor_accessibility_projection_build("empty-document", "", 1, context.temp_allocator)
	defer editor_accessibility_projection_destroy(&projection)

	testing.expect(t, projection.complete && projection.supported && len(projection.runs) == 1,
		"an empty document should still have one empty text run for a caret")
	if len(projection.runs) != 1 { return }
	position, position_ok := editor_accessibility_projection_source_to_position(&projection, 0)
	byte_offset, byte_ok := editor_accessibility_position_to_source(&projection, position)
	line, line_ok := editor_accessibility_source_to_line(&projection, 0)
	testing.expect(t, position_ok && position.run_id == projection.runs[0].id && position.character_index == 0,
		"the empty document caret should address character zero in its sole run")
	testing.expect(t, byte_ok && byte_offset == 0 && line_ok && line == 0,
		"the empty document caret and line lookup should map to source zero")
}

@(test)
test_editor_accessibility_map_stable_area_and_run_ids :: proc(t: ^testing.T) {
	first := editor_accessibility_projection_build("stable-document", "one\ntwo", 1, context.temp_allocator)
	defer editor_accessibility_projection_destroy(&first)
	second := editor_accessibility_projection_build("stable-document", "changed", 9, context.temp_allocator)
	defer editor_accessibility_projection_destroy(&second)
	other := editor_accessibility_projection_build("other-document", "one\ntwo", 1, context.temp_allocator)
	defer editor_accessibility_projection_destroy(&other)

	testing.expect(t, first.area_id == second.area_id && first.area_id == editor_accessibility_area_id("stable-document"),
		"a document's Text_Area identity should survive source and revision changes")
	testing.expect(t, first.area_id != other.area_id,
		"different document identities should produce different Text_Area identities")
	if len(first.runs) > 0 && len(second.runs) > 0 && len(other.runs) > 0 {
		testing.expect(t, first.runs[0].id == editor_accessibility_run_id(first.area_id, first.editor_revision, 0) &&
			first.runs[0].id != second.runs[0].id && first.runs[0].id != other.runs[0].id,
			"run IDs should derive from area, revision, and ordinal so stale requests cannot target changed text")
		stale_selection := alicorn.Semantic_Text_Selection{
			anchor={run_id=first.runs[0].id, character_index=0},
			focus={run_id=first.runs[0].id, character_index=1},
			valid=true,
		}
		_, _, stale_ok := editor_accessibility_semantic_selection_to_source(&second, stale_selection)
		testing.expect(t, !stale_ok,
			"a queued selection from an older editor revision must not map onto the current source")
	}
	testing.expect(t, editor_accessibility_area_id("") == (alicorn.Semantic_ID{}),
		"an empty document ID should not manufacture a semantic identity")
}

@(test)
test_editor_accessibility_map_invalid_utf8_is_unsupported_without_partial_runs :: proc(t: ^testing.T) {
	invalid := [?]u8{0xE0, 0x80, 0x80}
	projection := editor_accessibility_projection_build("invalid-document", string(invalid[:]), 5, context.temp_allocator)
	defer editor_accessibility_projection_destroy(&projection)

	testing.expect(t, projection.complete && !projection.supported && projection.unsupported_reason == .Invalid_UTF8,
		"invalid UTF-8 should produce a complete unsupported result with an exact reason")
	testing.expect(t, projection.area_id == editor_accessibility_area_id("invalid-document") && projection.document_id == "invalid-document",
		"an unsupported document should keep its stable Text_Area identity and document ID")
	testing.expect(t, len(projection.runs) == 0,
		"invalid source bytes must not be escaped, split, or exposed as partial text runs")
	valid_replacement_character := [?]u8{0xEF, 0xBF, 0xBD}
	valid_replacement := editor_accessibility_projection_build(
		"replacement-character-document",
		string(valid_replacement_character[:]),
		5,
		context.temp_allocator,
	)
	defer editor_accessibility_projection_destroy(&valid_replacement)
	testing.expect(t, valid_replacement.complete && valid_replacement.supported,
		"the valid UTF-8 encoding of U+FFFD must not be confused with malformed bytes")
}

@(test)
test_editor_accessibility_map_rejects_overlong_grapheme :: proc(t: ^testing.T) {
	bytes := make([]u8, 256, allocator=context.temp_allocator)
	defer delete(bytes, context.temp_allocator)
	bytes[0] = 'a'
	for index in 0..<126 {
		bytes[1+index*2] = 0xCC
		bytes[2+index*2] = 0x81
	}
	bytes[253] = 0xE1
	bytes[254] = 0xAA
	bytes[255] = 0xB0
	projection := editor_accessibility_projection_build("long-grapheme", string(bytes), 4, context.temp_allocator)
	defer editor_accessibility_projection_destroy(&projection)

	testing.expect(t, projection.complete && !projection.supported && projection.unsupported_reason == .Grapheme_Exceeds_255_Bytes,
		"a grapheme wider than the semantic u8 contract should be explicitly unsupported")
	testing.expect(t, projection.area_id == editor_accessibility_area_id("long-grapheme") && len(projection.runs) == 0,
		"oversized graphemes should retain the area identity without publishing split runs")
}
