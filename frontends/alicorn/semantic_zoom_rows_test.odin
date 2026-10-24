package main

import "core:mem"
import "core:testing"
import bridge "./bridge"

@(test)
test_semantic_zoom_rows_identity_and_empty :: proc(t: ^testing.T) {
	rows: Semantic_Zoom_Rows
	defer semantic_zoom_rows_destroy(&rows)
	testing.expect(t, semantic_zoom_rows_init(&rows, nil, 0))
	testing.expect(t, rows.line_count == 0 && rows.row_count == 0 && cap(rows.folds) == 0)
	line, fold, ok := semantic_zoom_rows_source_at(&rows, 0)
	testing.expect(t, !ok && line == -1 && fold == -1)
	testing.expect(t, semantic_zoom_rows_row_for_source(&rows, 0) == -1)
	testing.expect(t, !semantic_zoom_rows_hidden(&rows, 0))
	testing.expect(t, !semantic_zoom_rows_expand(&rows, 0))

	testing.expect(t, semantic_zoom_rows_init(&rows, nil, 7))
	testing.expect(t, rows.line_count == 7 && rows.row_count == 7 && cap(rows.folds) == 0)
	for source in 0..<7 {
		line, fold, ok := semantic_zoom_rows_source_at(&rows, source)
		testing.expect(t, ok && line == source && fold == -1)
		testing.expect(t, semantic_zoom_rows_row_for_source(&rows, source) == source)
		testing.expect(t, !semantic_zoom_rows_hidden(&rows, source))
	}
	invalid_sources := [?]int{-1, 7, 8}
	for invalid in invalid_sources {
		line, fold, ok := semantic_zoom_rows_source_at(&rows, invalid)
		testing.expect(t, !ok && line == -1 && fold == -1)
		testing.expect(t, semantic_zoom_rows_row_for_source(&rows, invalid) == -1)
		testing.expect(t, !semantic_zoom_rows_hidden(&rows, invalid))
	}
	testing.expect(t, !semantic_zoom_rows_init(nil, nil, 0))
	_, _, nil_ok := semantic_zoom_rows_source_at(nil, 0)
	testing.expect(t, !nil_ok && semantic_zoom_rows_row_for_source(nil, 0) == -1)
	testing.expect(t, !semantic_zoom_rows_hidden(nil, 0) && !semantic_zoom_rows_expand(nil, 0))
	semantic_zoom_rows_destroy(nil)
}

@(test)
test_semantic_zoom_rows_boundaries_adjacent_and_single_line :: proc(t: ^testing.T) {
	folds := [?]bridge.Semantic_Zoom_Fold{
		{start_line=0, end_line=2},
		{start_line=2, end_line=5},
		{start_line=6, end_line=7},
		{start_line=8, end_line=12},
	}
	rows: Semantic_Zoom_Rows
	if !semantic_zoom_rows_init(&rows, folds[:], 12) { testing.expect(t, false); return }
	defer semantic_zoom_rows_destroy(&rows)
	testing.expect(t, rows.row_count == 6)
	expected_sources := [?]int{0, 2, 5, 6, 7, 8}
	expected_folds := [?]int{0, 1, -1, 2, -1, 3}
	for source, row in expected_sources {
		actual_source, actual_fold, ok := semantic_zoom_rows_source_at(&rows, row)
		testing.expect(t, ok && actual_source == source && actual_fold == expected_folds[row])
	}
	expected_rows := [?]int{0, 0, 1, 1, 1, 2, 3, 4, 5, 5, 5, 5}
	for row, source in expected_rows {
		testing.expect(t, semantic_zoom_rows_row_for_source(&rows, source) == row)
		testing.expect(t, semantic_zoom_rows_hidden(&rows, source) == (source != 5 && source != 7))
	}
	testing.expect(t, rows.folds[0].removed_before == 0 && rows.folds[1].removed_before == 1 &&
		rows.folds[2].removed_before == 3 && rows.folds[3].removed_before == 3)
	_, _, eof_ok := semantic_zoom_rows_source_at(&rows, rows.row_count)
	testing.expect(t, !eof_ok && semantic_zoom_rows_row_for_source(&rows, rows.line_count) == -1)
}

@(test)
test_semantic_zoom_rows_silent_whitespace_uses_no_marker_row :: proc(t: ^testing.T) {
	folds := [?]bridge.Semantic_Zoom_Fold{
		{start_line=0, end_line=1, silent=true},
		{start_line=2, end_line=4},
		{start_line=5, end_line=7, silent=true},
	}
	rows: Semantic_Zoom_Rows
	if !semantic_zoom_rows_init(&rows, folds[:], 8) { testing.expect(t, false); return }
	defer semantic_zoom_rows_destroy(&rows)
	testing.expect(t, rows.row_count == 4, "silent folds remove every blank row; meaningful folds retain one marker")
	expected := [?]struct { row, source, marker: int }{
		{0, 1, -1}, {1, 2, 1}, {2, 4, -1}, {3, 7, -1},
	}
	for item in expected {
		source, marker, ok := semantic_zoom_rows_source_at(&rows, item.row)
		testing.expect(t, ok && source == item.source && marker == item.marker,
			"silent whitespace must not become an actionable hidden-lines marker")
	}
	cases := [?]struct { source, row: int }{{0, 0}, {1, 0}, {2, 1}, {3, 1}, {4, 2}, {5, 3}, {6, 3}, {7, 3}}
	for item in cases {
		source, row := item.source, item.row
		testing.expect(t, semantic_zoom_rows_row_for_source(&rows, source) == row)
	}
	testing.expect(t, semantic_zoom_rows_hidden(&rows, 0) && semantic_zoom_rows_hidden(&rows, 5) &&
		semantic_zoom_rows_hidden(&rows, 6), "source whitespace remains in the document while its display rows disappear")
	testing.expect(t, semantic_zoom_rows_expand(&rows, 1) && rows.row_count == 5,
		"expanding meaningful content preserves silent whitespace elision")
	semantic_zoom_rows_test_roundtrip(t, &rows)
}

@(test)
test_semantic_zoom_rows_million_lines_sparse_geometry :: proc(t: ^testing.T) {
	folds := [?]bridge.Semantic_Zoom_Fold{
		{start_line=10, end_line=100},
		{start_line=500_000, end_line=999_999},
	}
	rows: Semantic_Zoom_Rows
	if !semantic_zoom_rows_init(&rows, folds[:], 1_000_000) { testing.expect(t, false); return }
	defer semantic_zoom_rows_destroy(&rows)
	testing.expect(t, rows.line_count == 1_000_000 && rows.row_count == 499_913)
	testing.expect(t, len(rows.folds) == 2 && cap(rows.folds) == 2,
		"storage must depend only on fold count, not document length")
	cases := [?]struct { row, source, fold: int }{
		{0, 0, -1}, {9, 9, -1}, {10, 10, 0}, {11, 100, -1},
		{499_910, 499_999, -1}, {499_911, 500_000, 1}, {499_912, 999_999, -1},
	}
	for check in cases {
		source, fold, ok := semantic_zoom_rows_source_at(&rows, check.row)
		testing.expect(t, ok && source == check.source && fold == check.fold)
		testing.expect(t, semantic_zoom_rows_row_for_source(&rows, check.source) == check.row)
	}
	testing.expect(t, semantic_zoom_rows_row_for_source(&rows, 99) == 10)
	testing.expect(t, semantic_zoom_rows_row_for_source(&rows, 999_998) == 499_911)
	testing.expect(t, semantic_zoom_rows_hidden(&rows, 999_998) && !semantic_zoom_rows_hidden(&rows, 999_999))
}

// A linear source walk is an independent oracle for the compact binary searches.
// Also run it after each expansion, when all following prefixes must change.
semantic_zoom_rows_test_roundtrip :: proc(t: ^testing.T, rows: ^Semantic_Zoom_Rows) {
	source, row, fold_index := 0, 0, 0
	for source < rows.line_count {
		expected_fold := -1
		next_source := source+1
		if fold_index < len(rows.folds) && int(rows.folds[fold_index].fold.start_line) == source {
			if rows.folds[fold_index].fold.silent {
				next_source = int(rows.folds[fold_index].fold.end_line)
				for hidden_source in source..<next_source {
					testing.expect(t, semantic_zoom_rows_row_for_source(rows, hidden_source) == row &&
						semantic_zoom_rows_hidden(rows, hidden_source),
						"silent folds keep source identity while consuming no presentation row")
				}
				source = next_source
				fold_index += 1
				continue
			}
			expected_fold = fold_index
			next_source = int(rows.folds[fold_index].fold.end_line)
			fold_index += 1
		}
		actual_source, actual_fold, ok := semantic_zoom_rows_source_at(rows, row)
		testing.expect(t, ok && actual_source == source && actual_fold == expected_fold,
			"each row must map to the original source ID or the start of its hidden interval")
		for hidden_source in source..<next_source {
			mapped_row := semantic_zoom_rows_row_for_source(rows, hidden_source)
			testing.expect(t, mapped_row == row)
			testing.expect(t, semantic_zoom_rows_hidden(rows, hidden_source) == (expected_fold >= 0))
			roundtrip_source, roundtrip_fold, roundtrip_ok := semantic_zoom_rows_source_at(rows, mapped_row)
			testing.expect(t, roundtrip_ok && roundtrip_source == source && roundtrip_fold == expected_fold)
		}
		source = next_source
		row += 1
	}
	testing.expect(t, row == rows.row_count && fold_index == len(rows.folds))
}

@(test)
test_semantic_zoom_rows_generated_roundtrips_and_expansions :: proc(t: ^testing.T) {
	state: u64 = 0x534f55524345
	for case_index in 0..<192 {
		line_count := case_index%65
		folds: [64]bridge.Semantic_Zoom_Fold
		fold_count, source := 0, 0
		for source < line_count {
			state = state*6364136223846793005+1
			source += int((state >> 32)%4)
			if source >= line_count { break }
			state = state*6364136223846793005+1
			end := min(source+1+int((state >> 32)%9), line_count)
			folds[fold_count] = {start_line=u64(source), end_line=u64(end), silent=(state & 3) == 0}
			fold_count += 1
			source = end
		}
		rows: Semantic_Zoom_Rows
		if !semantic_zoom_rows_init(&rows, folds[:fold_count], line_count) {
			testing.expect(t, false, "generated sorted, disjoint folds must be accepted")
			return
		}
		semantic_zoom_rows_test_roundtrip(t, &rows)
		for len(rows.folds) > 0 {
			state = state*6364136223846793005+1
			index := int((state >> 32)%u64(len(rows.folds)))
			testing.expect(t, semantic_zoom_rows_expand(&rows, index))
			semantic_zoom_rows_test_roundtrip(t, &rows)
		}
		testing.expect(t, rows.row_count == line_count)
		semantic_zoom_rows_destroy(&rows)
	}
}

@(test)
test_semantic_zoom_rows_invalid_ranges_limits_and_failure_preserves_mapping :: proc(t: ^testing.T) {
	valid := [?]bridge.Semantic_Zoom_Fold{{start_line=2, end_line=6}}
	rows: Semantic_Zoom_Rows
	if !semantic_zoom_rows_init(&rows, valid[:], 10) { testing.expect(t, false); return }
	defer semantic_zoom_rows_destroy(&rows)
	invalid := [?][2]bridge.Semantic_Zoom_Fold{
		{{start_line=2, end_line=2}, {start_line=6, end_line=7}},
		{{start_line=5, end_line=3}, {start_line=6, end_line=7}},
		{{start_line=2, end_line=11}, {start_line=12, end_line=13}},
		{{start_line=2, end_line=6}, {start_line=5, end_line=8}},
		{{start_line=6, end_line=8}, {start_line=2, end_line=5}},
		{{start_line=2, end_line=6}, {start_line=2, end_line=6}},
		{{start_line=0, end_line=1}, {start_line=1, end_line=~u64(0)}},
		{{start_line=0, end_line=1}, {start_line=~u64(0)-1, end_line=~u64(0)}},
	}
	for &folds in invalid {
		testing.expect(t, !semantic_zoom_rows_init(&rows, folds[:], 10))
		testing.expect(t, rows.row_count == 7 && len(rows.folds) == 1 && rows.folds[0].fold.start_line == 2)
	}
	testing.expect(t, !semantic_zoom_rows_init(&rows, nil, -1))
	testing.expect(t, !semantic_zoom_rows_init(&rows, valid[:], 0))
	testing.expect(t, !semantic_zoom_rows_init(&rows, valid[:], 10, mem.nil_allocator()))
	testing.expect(t, rows.row_count == 7 && semantic_zoom_rows_row_for_source(&rows, 9) == 6)
	testing.expect(t, !semantic_zoom_rows_expand(&rows, -1) && !semantic_zoom_rows_expand(&rows, 1))
	testing.expect(t, rows.row_count == 7 && len(rows.folds) == 1)

	many := make([]bridge.Semantic_Zoom_Fold, 4097)
	defer delete(many)
	for &fold, index in many { fold = {start_line=u64(index), end_line=u64(index+1)} }
	testing.expect(t, !semantic_zoom_rows_init(&rows, many, 4097))
	testing.expect(t, rows.row_count == 7 && len(rows.folds) == 1)
	testing.expect(t, semantic_zoom_rows_init(&rows, many[:4096], 4096))
	testing.expect(t, len(rows.folds) == 4096 && rows.row_count == 4096)
	semantic_zoom_rows_test_roundtrip(t, &rows)
}

@(test)
test_semantic_zoom_rows_borrows_labels_copies_ranges_and_expands :: proc(t: ^testing.T) {
	label := [?]u8{'f', 'o', 'l', 'd'}
	folds := [?]bridge.Semantic_Zoom_Fold{
		{start_line=1, end_line=4, start_byte=10, end_byte=40, label=string(label[:])},
		{start_line=4, end_line=7, start_byte=40, end_byte=70, label="next"},
		{start_line=8, end_line=10, start_byte=80, end_byte=100, label="last"},
	}
	rows: Semantic_Zoom_Rows
	if !semantic_zoom_rows_init(&rows, folds[:], 11) { testing.expect(t, false); return }
	defer semantic_zoom_rows_destroy(&rows)
	folds[0].start_line, folds[0].end_byte = 0, 999
	label[0] = 'F'
	testing.expect(t, rows.folds[0].fold.start_line == 1 && rows.folds[0].fold.start_byte == 10 &&
		rows.folds[0].fold.end_byte == 40 && rows.folds[0].fold.label == "Fold",
		"numeric values must be copied while label bytes remain borrowed")
	testing.expect(t, semantic_zoom_rows_expand(&rows, 1))
	testing.expect(t, len(rows.folds) == 2 && rows.row_count == 8)
	testing.expect(t, rows.folds[1].row == 6 && rows.folds[1].removed_before == 2)
	testing.expect(t, !semantic_zoom_rows_hidden(&rows, 4) && !semantic_zoom_rows_hidden(&rows, 6))
	semantic_zoom_rows_test_roundtrip(t, &rows)
	testing.expect(t, semantic_zoom_rows_expand(&rows, 0))
	testing.expect(t, rows.folds[0].row == 8 && rows.folds[0].removed_before == 0)
	semantic_zoom_rows_test_roundtrip(t, &rows)
	testing.expect(t, semantic_zoom_rows_expand(&rows, 0) && rows.row_count == 11)
	semantic_zoom_rows_test_roundtrip(t, &rows)
	semantic_zoom_rows_destroy(&rows)
	testing.expect(t, len(rows.folds) == 0 && cap(rows.folds) == 0 && rows.line_count == 0 && rows.row_count == 0)
	testing.expect(t, string(label[:]) == "Fold", "destroy must not free a label borrowed from the plan")
}
