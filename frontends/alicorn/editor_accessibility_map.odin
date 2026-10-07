package main

import "core:mem"
import "core:strings"
import "core:unicode/utf8"
import alicorn "alicorn:runtime"

EDITOR_ACCESSIBILITY_MAX_RUN_BYTES :: 64 * 1024
EDITOR_ACCESSIBILITY_NEWLINE_PREFERENCE_MIN_BYTES :: EDITOR_ACCESSIBILITY_MAX_RUN_BYTES / 2

// This namespace is owned by Scratchpad and intentionally does not overlap
// Alicorn's semantic-ID namespaces.
EDITOR_ACCESSIBILITY_SEMANTIC_NAMESPACE :: u64(0x5350435250414301)

Editor_Accessibility_Unsupported_Reason :: enum {
	None,
	Invalid_Document_ID,
	Invalid_UTF8,
	Grapheme_Exceeds_255_Bytes,
	Allocation_Failure,
}

Editor_Accessibility_Run :: struct {
	id:                 alicorn.Semantic_ID,
	source_start:       u64,
	source_end:         u64,
	logical_start_line: u64,
	value:              string,
	character_lengths:  []u8,
}

Editor_Accessibility_Projection :: struct {
	document_id:          string,
	area_id:              alicorn.Semantic_ID,
	byte_length:          u64,
	editor_revision:      u64,
	complete:             bool,
	supported:            bool,
	unsupported_reason:   Editor_Accessibility_Unsupported_Reason,
	runs:                 [dynamic]Editor_Accessibility_Run,
	allocator:            mem.Allocator,
}

// editor_accessibility_area_id is stable across document revisions and does
// not depend on a retained visual Node_ID. An empty document ID has no ID.
editor_accessibility_area_id :: proc(document_id: string) -> alicorn.Semantic_ID {
	if len(document_id) == 0 { return {} }
	return alicorn.Semantic_ID{
		namespace=EDITOR_ACCESSIBILITY_SEMANTIC_NAMESPACE,
		value=editor_accessibility_hash(document_id, 0x41524541, 0),
	}
}

editor_accessibility_run_id :: proc(area_id: alicorn.Semantic_ID, editor_revision, ordinal: u64) -> alicorn.Semantic_ID {
	if area_id.namespace == 0 || area_id.value == 0 { return {} }
	hash: u64 = 1469598103934665603
	parts := [4]u64{area_id.namespace, area_id.value, editor_revision, ordinal}
	for part in parts {
		for shift in 0..<8 {
			hash = (hash ~ u64(u8(part >> u64(shift*8)))) * 1099511628211
		}
	}
	if hash == 0 { hash = 1 }
	return alicorn.Semantic_ID{
		namespace=EDITOR_ACCESSIBILITY_SEMANTIC_NAMESPACE,
		value=hash,
	}
}

editor_accessibility_hash :: proc(document_id: string, kind, ordinal: u64) -> u64 {
	hash: u64 = 1469598103934665603
	for shift in 0..<8 {
		hash = (hash ~ u64(u8(kind >> u64(shift*8)))) * 1099511628211
	}
	for index := 0; index < len(document_id); index += 1 {
		hash = (hash ~ u64(document_id[index])) * 1099511628211
	}
	for shift in 0..<8 {
		hash = (hash ~ u64(u8(ordinal >> u64(shift*8)))) * 1099511628211
	}
	if hash == 0 { hash = 1 }
	return hash
}

editor_accessibility_unsupported_reason_string :: proc(reason: Editor_Accessibility_Unsupported_Reason) -> string {
	switch reason {
	case .None:
		return ""
	case .Invalid_Document_ID:
		return "The document has no stable identity."
	case .Invalid_UTF8:
		return "Accessible source-text editing is unavailable because the document contains invalid UTF-8."
	case .Grapheme_Exceeds_255_Bytes:
		return "Accessible source-text editing is unavailable because a selectable grapheme exceeds 255 UTF-8 bytes."
	case .Allocation_Failure:
		return "The accessible source-text projection could not be allocated."
	}
	return "The accessible source-text projection is unsupported."
}

// editor_accessibility_projection_build consumes a complete source snapshot.
// complete means the snapshot has been fully classified for this exact pair
// of revisions; unsupported snapshots contain no partial Text_Run records,
// but retain their stable Text_Area identity and a precise reason.
editor_accessibility_projection_build :: proc(
	document_id: string,
	source: string,
	editor_revision: u64,
	allocator := context.allocator,
) -> Editor_Accessibility_Projection {
	projection := Editor_Accessibility_Projection{
		area_id=editor_accessibility_area_id(document_id),
		byte_length=u64(len(source)),
		editor_revision=editor_revision,
		allocator=allocator,
	}
	projection.runs = make([dynamic]Editor_Accessibility_Run, 0, allocator=allocator)
	if len(document_id) == 0 {
		projection.unsupported_reason = .Invalid_Document_ID
		return projection
	}
	document_id_copy, clone_error := strings.clone(document_id, allocator)
	if clone_error != nil {
		projection.unsupported_reason = .Allocation_Failure
		return projection
	}
	projection.document_id = document_id_copy

	valid_utf8 := editor_accessibility_utf8_valid(source)
	if !valid_utf8 {
		projection.complete = true
		projection.unsupported_reason = .Invalid_UTF8
		return projection
	}

	character_lengths, lengths_ok := alicorn.semantic_text_character_lengths(source, allocator)
	if !lengths_ok {
		projection.complete = true
		projection.unsupported_reason = .Grapheme_Exceeds_255_Bytes
		return projection
	}
	defer {
		if len(character_lengths) > 0 { delete(character_lengths, allocator) }
	}

	projection.supported = true
	projection.complete = true
	projection.unsupported_reason = .None

	if len(source) == 0 {
		empty_value, value_error := strings.clone("", allocator)
		if value_error != nil {
			projection.complete = false
			projection.supported = false
			projection.unsupported_reason = .Allocation_Failure
			return projection
		}
		append(&projection.runs, Editor_Accessibility_Run{
			id=editor_accessibility_run_id(projection.area_id, editor_revision, 0),
			source_start=0,
			source_end=0,
			logical_start_line=0,
			value=empty_value,
			character_lengths=nil,
		})
		return projection
	}

	start_byte: u64 = 0
	start_character := 0
	logical_line: u64 = 0
	ordinal: u64 = 0
	for start_byte < u64(len(source)) {
		end_character := start_character
		end_byte := start_byte
		byte_limit := min(start_byte+u64(EDITOR_ACCESSIBILITY_MAX_RUN_BYTES), u64(len(source)))
		for end_character < len(character_lengths) {
			next_byte := end_byte+u64(character_lengths[end_character])
			if next_byte > byte_limit { break }
			end_byte = next_byte
			end_character += 1
		}
		// Every grapheme is at most 255 bytes, so at least one unit must fit.
		if end_character == start_character {
			editor_accessibility_projection_clear_runs(&projection)
			projection.complete = false
			projection.supported = false
			projection.unsupported_reason = .Allocation_Failure
			return projection
		}

		if end_byte < u64(len(source)) {
			preferred_minimum := start_byte+u64(EDITOR_ACCESSIBILITY_NEWLINE_PREFERENCE_MIN_BYTES)
			candidate_byte := start_byte
			preferred_character := start_character
			for character_index in start_character..<end_character {
				candidate_byte += u64(character_lengths[character_index])
				last_byte := source[int(candidate_byte)-1]
				if candidate_byte >= preferred_minimum && (last_byte == '\n' || last_byte == '\r') {
					preferred_character = character_index+1
				}
			}
			if preferred_character > start_character && preferred_character < end_character {
				end_character = preferred_character
				end_byte = start_byte
				for character_index in start_character..<end_character {
					end_byte += u64(character_lengths[character_index])
				}
			}
		}

		value_copy, value_error := strings.clone(source[int(start_byte):int(end_byte)], allocator)
		if value_error != nil {
			editor_accessibility_projection_clear_runs(&projection)
			projection.complete = false
			projection.supported = false
			projection.unsupported_reason = .Allocation_Failure
			return projection
		}
		run_lengths := make([]u8, end_character-start_character, allocator=allocator)
		if len(run_lengths) > 0 {
			copy(run_lengths, character_lengths[start_character:end_character])
		}
		append(&projection.runs, Editor_Accessibility_Run{
			id=editor_accessibility_run_id(projection.area_id, editor_revision, ordinal),
			source_start=start_byte,
			source_end=end_byte,
			logical_start_line=logical_line,
			value=value_copy,
			character_lengths=run_lengths,
		})
		for byte_index in int(start_byte)..<int(end_byte) {
			if source[byte_index] == '\n' { logical_line += 1 }
		}
		start_byte = end_byte
		start_character = end_character
		ordinal += 1
	}
	return projection
}

editor_accessibility_utf8_valid :: proc(source: string) -> bool {
	byte_index := 0
	for byte_index < len(source) {
		rune_value, width := utf8.decode_rune_in_string(source[byte_index:])
		if width <= 0 { return false }
		// The valid encoding of U+FFFD has width 3. Odin's decoder reports
		// malformed bytes as RUNE_ERROR with width 1, one byte at a time.
		if rune_value == utf8.RUNE_ERROR && width == 1 { return false }
		byte_index += width
	}
	return true
}

editor_accessibility_projection_source_to_position :: proc(
	projection: ^Editor_Accessibility_Projection,
	source_byte: u64,
) -> (position: alicorn.Semantic_Text_Position, ok: bool) {
	if projection == nil || !projection.complete || !projection.supported || source_byte > projection.byte_length { return }
	for run_index in 0..<len(projection.runs) {
		run := projection.runs[run_index]
		is_last := run_index == len(projection.runs)-1
		if source_byte < run.source_start || source_byte > run.source_end { continue }
		if source_byte == run.source_end && !is_last { continue }
		byte_offset := source_byte-run.source_start
		character_index, boundary := editor_accessibility_run_byte_to_character(run, byte_offset)
		if !boundary { return }
		return alicorn.Semantic_Text_Position{run_id=run.id, character_index=character_index}, true
	}
	return
}

editor_accessibility_position_to_source :: proc(
	projection: ^Editor_Accessibility_Projection,
	position: alicorn.Semantic_Text_Position,
) -> (source_byte: u64, ok: bool) {
	if projection == nil || !projection.complete || !projection.supported { return }
	for run in projection.runs {
		if run.id != position.run_id { continue }
		if position.character_index > u64(len(run.character_lengths)) { return }
		source_byte = run.source_start
		for index in 0..<int(position.character_index) {
			source_byte += u64(run.character_lengths[index])
		}
		return source_byte, true
	}
	return
}

// A byte on a newline belongs to the preceding logical line; the byte after
// LF belongs to the next line. Counting LF makes CRLF exactly one line break.
editor_accessibility_source_to_line :: proc(
	projection: ^Editor_Accessibility_Projection,
	source_byte: u64,
) -> (logical_line: u64, ok: bool) {
	if projection == nil || !projection.complete || !projection.supported || source_byte > projection.byte_length { return }
	for run_index in 0..<len(projection.runs) {
		run := projection.runs[run_index]
		is_last := run_index == len(projection.runs)-1
		if source_byte < run.source_start || source_byte > run.source_end { continue }
		if source_byte == run.source_end && !is_last { continue }
		logical_line = run.logical_start_line
		local_end := int(source_byte-run.source_start)
		for byte_index in 0..<local_end {
			if run.value[byte_index] == '\n' { logical_line += 1 }
		}
		return logical_line, true
	}
	return
}

editor_accessibility_source_selection_to_semantic :: proc(
	projection: ^Editor_Accessibility_Projection,
	anchor_byte, caret_byte: u64,
) -> (selection: alicorn.Semantic_Text_Selection, ok: bool) {
	anchor, anchor_ok := editor_accessibility_projection_source_to_position(projection, anchor_byte)
	caret, caret_ok := editor_accessibility_projection_source_to_position(projection, caret_byte)
	if !anchor_ok || !caret_ok { return {}, false }
	return alicorn.Semantic_Text_Selection{anchor=anchor, focus=caret, valid=true}, true
}

editor_accessibility_semantic_selection_to_source :: proc(
	projection: ^Editor_Accessibility_Projection,
	selection: alicorn.Semantic_Text_Selection,
) -> (anchor_byte, caret_byte: u64, ok: bool) {
	if !selection.valid { return }
	mapped_anchor_byte, anchor_ok := editor_accessibility_position_to_source(projection, selection.anchor)
	mapped_caret_byte, caret_ok := editor_accessibility_position_to_source(projection, selection.focus)
	return mapped_anchor_byte, mapped_caret_byte, anchor_ok && caret_ok
}

editor_accessibility_run_byte_to_character :: proc(
	run: Editor_Accessibility_Run,
	byte_offset: u64,
) -> (character_index: u64, ok: bool) {
	if byte_offset > u64(len(run.value)) { return 0, false }
	if byte_offset == 0 { return 0, true }
	current: u64 = 0
	for index in 0..<len(run.character_lengths) {
		current += u64(run.character_lengths[index])
		if current == byte_offset { return u64(index+1), true }
		if current > byte_offset { return 0, false }
	}
	return 0, false
}

editor_accessibility_projection_destroy :: proc(projection: ^Editor_Accessibility_Projection) {
	if projection == nil { return }
	allocator := projection.allocator
	editor_accessibility_projection_clear_runs(projection)
	if len(projection.document_id) > 0 { delete(projection.document_id, allocator) }
	projection^ = {}
}

editor_accessibility_projection_clear_runs :: proc(projection: ^Editor_Accessibility_Projection) {
	if projection == nil { return }
	allocator := projection.allocator
	for run in projection.runs {
		if len(run.value) > 0 { delete(run.value, allocator) }
		if len(run.character_lengths) > 0 { delete(run.character_lengths, allocator) }
	}
	if len(projection.runs) > 0 { delete(projection.runs) }
	projection.runs = {}
}
