package main

import "core:testing"
import alicorn "alicorn:runtime"
import bridge "./bridge"

@(test)
test_manual_folding_selection_guard_and_marker_glyphs :: proc(t: ^testing.T) {
	fold := bridge.Editor_Fold{start_byte=4, body_start_byte=10, end_byte=20}
	view := Editor_View_State{selection_anchor=0, caret_byte=20}
	testing.expect(t, manual_folding_selection_overlaps_fold(&view, fold),
		"a selection crossing hidden source bytes must keep that fold expanded")
	view.selection_anchor, view.caret_byte = 0, 10
	testing.expect(t, !manual_folding_selection_overlaps_fold(&view, fold),
		"a selection ending at the hidden range boundary does not overlap it")
	view.selection_anchor, view.caret_byte = 12, 12
	testing.expect(t, !manual_folding_selection_overlaps_fold(&view, fold),
		"a collapsed caret is not a source selection")
	manual_folding_move_caret_out_of_fold(&view, fold)
	testing.expect(t, view.caret_byte == fold.start_byte && view.selection_anchor == fold.start_byte,
		"collapsing around an unselected caret moves it to the visible header")

	testing.expect(t, manual_folding_header_marker_glyph(true) == "›",
		"a collapsed fold uses the right-pointing disclosure glyph")
	testing.expect(t, manual_folding_header_marker_glyph(false) == "⌄",
		"an expanded fold uses the down-pointing disclosure glyph")
}

@(test)
test_manual_folding_restores_anchor_when_last_fold_opens :: proc(t: ^testing.T) {
	index: alicorn.Virtual_List_Height_Index
	if !alicorn.virtual_list_height_index_init(&index, 5, 10) {
		testing.expect(t, false, "could not create virtual line geometry")
		return
	}
	defer alicorn.virtual_list_height_index_destroy(&index)
	_ = alicorn.virtual_list_height_index_set_height(&index, 1, 20)
	_ = alicorn.virtual_list_height_index_set_height(&index, 2, 30)
	alicorn.virtual_list_height_index_rebuild_prefix(&index)

	view := Editor_View_State{}
	folding := Editor_Manual_Folding{anchor_line=3, anchor_offset=-4, anchor_pending=true}
	if !manual_folding_restore_anchor_at_row(&view, &folding, &index, 3) {
		testing.expect(t, false, "last-fold expansion must restore the source anchor using normal line geometry")
		return
	}
	testing.expect(t, view.scroll_y == 56 && view.restore_y_pending &&
		view.restore_token == alicorn.RESTORE_TOKEN_NONE && !folding.anchor_pending,
		"restored scroll keeps the same source line and intra-line offset")
}

@(test)
test_manual_folding_nested_state_survives_parent_toggle :: proc(t: ^testing.T) {
	folding := Editor_Manual_Folding{owned=true}
	folding.plan = bridge.Editor_Fold_Plan{ready=true, supported=true, line_count=10}
	folding.plan.folds = make([]bridge.Editor_Fold, 2, allocator=context.allocator)
	folding.plan.folds[0] = bridge.Editor_Fold{
		start_line=0, body_start_line=1, end_line=8,
		start_byte=0, body_start_byte=10, end_byte=80, label="parent",
	}
	folding.plan.folds[1] = bridge.Editor_Fold{
		start_line=2, body_start_line=3, end_line=5,
		start_byte=20, body_start_byte=30, end_byte=50, label="child",
	}
	folding.collapsed, _ = make([dynamic]bool, 2, allocator=context.allocator)
	folding.collapsed[0], folding.collapsed[1] = true, true
	defer {
		semantic_zoom_rows_destroy(&folding.rows)
		delete(folding.collapsed)
		delete(folding.plan.folds, context.allocator)
	}

	testing.expect(t, manual_folding_rebuild_rows(&folding), "nested fold plan should project")
	testing.expect(t, folding.rows.row_count == 4 && len(folding.rows.folds) == 1,
		"a collapsed parent suppresses its nested disclosure row")

	folding.collapsed[0] = false
	testing.expect(t, manual_folding_rebuild_rows(&folding), "expanded parent should reveal nested folds")
	testing.expect(t, folding.rows.row_count == 9 && len(folding.rows.folds) == 1 &&
		folding.rows.folds[0].fold.label == "child" && !folding.rows.folds[0].expanded,
		"the child's independent collapsed state survives the parent's collapse/expand cycle")
}
