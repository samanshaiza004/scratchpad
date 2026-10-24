package main

import bridge "./bridge"

Semantic_Zoom_Row_Fold :: struct {
	fold:           bridge.Semantic_Zoom_Fold,
	row:            int,
	removed_before: int,
}

Semantic_Zoom_Rows :: struct {
	folds:      [dynamic]Semantic_Zoom_Row_Fold,
	line_count: int,
	row_count:  int,
}

// Folds hide zero-based, half-open source-line ranges. Their labels remain
// borrowed from the plan, which must outlive this mapping. Initialize a zeroed
// or previously initialized mapping; failure leaves its existing contents intact.
semantic_zoom_rows_init :: proc(
	rows: ^Semantic_Zoom_Rows,
	folds: []bridge.Semantic_Zoom_Fold,
	line_count: int,
	allocator := context.allocator,
) -> bool {
	if rows == nil || line_count < 0 || len(folds) > 4096 { return false }
	previous_end: u64
	for fold in folds {
		if fold.start_line >= fold.end_line || fold.end_line > u64(line_count) ||
			fold.start_line < previous_end {
			return false
		}
		previous_end = fold.end_line
	}

	next := Semantic_Zoom_Rows{line_count=line_count, row_count=line_count}
	if len(folds) > 0 {
		storage, err := make([dynamic]Semantic_Zoom_Row_Fold, len(folds), allocator=allocator)
		if err != nil || len(storage) != len(folds) {
			delete(storage)
			return false
		}
		next.folds = storage
		for fold, index in folds { next.folds[index].fold = fold }
		semantic_zoom_rows_recompute(&next)
	}
	semantic_zoom_rows_destroy(rows)
	rows^ = next
	return true
}

// The dynamic array remembers its allocator. No borrowed label is freed here.
semantic_zoom_rows_destroy :: proc(rows: ^Semantic_Zoom_Rows) {
	if rows == nil { return }
	delete(rows.folds)
	rows^ = {}
}

semantic_zoom_rows_recompute :: proc(rows: ^Semantic_Zoom_Rows) {
	removed := 0
	for &entry in rows.folds {
		entry.row = int(entry.fold.start_line)-removed
		entry.removed_before = removed
		removed += int(entry.fold.end_line-entry.fold.start_line)-1
	}
	rows.row_count = rows.line_count-removed
}

// A marker maps to the first hidden source line and its current fold index.
// Ordinary rows retain their original logical line IDs and return fold_index=-1.
semantic_zoom_rows_source_at :: proc(rows: ^Semantic_Zoom_Rows, row: int) -> (source_line: int, fold_index: int, ok: bool) {
	if rows == nil || row < 0 || row >= rows.row_count { return -1, -1, false }
	lo, hi := 0, len(rows.folds)
	for lo < hi {
		mid := lo+(hi-lo)/2
		if rows.folds[mid].row <= row { lo = mid+1 } else { hi = mid }
	}
	if lo == 0 { return row, -1, true }
	index := lo-1
	entry := rows.folds[index]
	if row == entry.row { return int(entry.fold.start_line), index, true }
	removed := entry.removed_before+int(entry.fold.end_line-entry.fold.start_line)-1
	return row+removed, -1, true
}

// Returns the last fold starting at or before source_line, or -1.
semantic_zoom_rows_fold_before_source :: proc(rows: ^Semantic_Zoom_Rows, source_line: int) -> int {
	lo, hi := 0, len(rows.folds)
	for lo < hi {
		mid := lo+(hi-lo)/2
		if rows.folds[mid].fold.start_line <= u64(source_line) { lo = mid+1 } else { hi = mid }
	}
	return lo-1
}

// Hidden source lines map to their marker. Out-of-range source lines return -1.
semantic_zoom_rows_row_for_source :: proc(rows: ^Semantic_Zoom_Rows, source_line: int) -> int {
	if rows == nil || source_line < 0 || source_line >= rows.line_count { return -1 }
	index := semantic_zoom_rows_fold_before_source(rows, source_line)
	if index < 0 { return source_line }
	entry := rows.folds[index]
	if u64(source_line) < entry.fold.end_line { return entry.row }
	removed := entry.removed_before+int(entry.fold.end_line-entry.fold.start_line)-1
	return source_line-removed
}

semantic_zoom_rows_hidden :: proc(rows: ^Semantic_Zoom_Rows, source_line: int) -> bool {
	if rows == nil || source_line < 0 || source_line >= rows.line_count { return false }
	index := semantic_zoom_rows_fold_before_source(rows, source_line)
	return index >= 0 && u64(source_line) < rows.folds[index].fold.end_line
}

// Indices refer to the current folds array and can shift after expansion.
semantic_zoom_rows_expand :: proc(rows: ^Semantic_Zoom_Rows, fold_index: int) -> bool {
	if rows == nil || fold_index < 0 || fold_index >= len(rows.folds) { return false }
	ordered_remove(&rows.folds, fold_index)
	semantic_zoom_rows_recompute(rows)
	return true
}
