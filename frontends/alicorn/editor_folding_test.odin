package main

import "core:fmt"
import "core:testing"
import alicorn "alicorn:runtime"
import bridge "./bridge"

@(test)
test_manual_folding_selection_guard :: proc(t: ^testing.T) {
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
}

@(test)
test_manual_folding_gutter_paints_and_toggles :: proc(t: ^testing.T) {
	manual_folding_test_gutter_roundtrip(t, "# Product direction", .Off)
	manual_folding_test_gutter_roundtrip(t, "# A long Markdown heading with enough words to wrap on screen and leave space after its last visual line", .Auto)
}

manual_folding_test_gutter_roundtrip :: proc(t: ^testing.T, heading: string, wrap_mode: Editor_Wrap_Mode) {
	fixture: Semantic_Zoom_Test_Editor
	defer semantic_zoom_test_destroy(&fixture, t)
	source := fmt.tprintf("%s\n\nBody text.\n\n# Second\n\nMore text.\n", heading)
	if !semantic_zoom_test_open(&fixture, t, "md", source) { return }

	document, found := find_document(&fixture.app.backend.state, fixture.document_id)
	if !testing.expect(t, found, "the Markdown fixture must be open") { return }
	key := fmt.tprintf("manual-fold-gutter-%d-%d-0", document.instance_id, document.editor_revision)
	view := semantic_zoom_test_view(&fixture)
	view.wrap_mode = wrap_mode
	view.selection_anchor, view.caret_byte = 2, u64(len(heading))
	if wrap_mode == .Auto { _ = alicorn.set_presentation_scale(&fixture.rt, 1.25, 1.25) }
	semantic_zoom_test_settle(&fixture)

	header, _, _ := editor_stale_window_test_line(&fixture.app, &fixture.rt, 0)
	line_count := alicorn.text_node_line_count(&fixture.rt, header)
	last_before, found_before := alicorn.text_node_line_geometry(&fixture.rt, header, line_count-1)
	if !testing.expect(t, found_before && (line_count > 1) == (wrap_mode == .Auto),
		"the unfolded heading must have the expected wrapping") { return }

	expected_icons := [?]alicorn.Icon_ID{.Chevron_Down, .Chevron_Right}
	for expected_icon in expected_icons {
		button := connected_titlebar_test_key(&fixture.rt, key)
		visible: alicorn.Rect
		for command in fixture.rt.display {
			if command.owner != button || command.opacity <= 0 { continue }
			if icon, ok := command.payload.(alicorn.Icon_Paint); ok && icon.id == expected_icon {
				visible = alicorn.rect_intersection(command.bounds, command.clip)
				break
			}
		}
		if !testing.expect(t, button != 0 && visible.w >= 10 && visible.h >= 10,
			"the fold button must paint a visible chevron inside the gutter") { return }

		x, y := visible.x+visible.w/2, visible.y+visible.h/2
		_ = alicorn.process_pointer(&fixture.rt, {kind=.Down, x=x, y=y, button=alicorn.POINTER_BUTTON_PRIMARY})
		_ = alicorn.process_pointer(&fixture.rt, {kind=.Up, x=x, y=y, button=alicorn.POINTER_BUTTON_PRIMARY})
		editor_paste_test_frame(&fixture.app, &fixture.rt)
		frame_deferred_action_run(&fixture.app, &fixture.rt)
		semantic_zoom_test_settle(&fixture)
		collapsed := manual_folding_projection_active(view)
		testing.expect(t, collapsed == (expected_icon == .Chevron_Down), "clicking the chevron must toggle the fold")
		testing.expect(t, view.selection_anchor == 2 && view.caret_byte == u64(len(heading)),
			"folding must preserve a source selection on the heading")

		marker := connected_titlebar_test_key(&fixture.rt, "fold-inline-ellipsis")
		if !collapsed {
			testing.expect(t, marker == 0, "expanding the fold removes the ellipsis")
			continue
		}
		fold := view.manual_folding.plan.folds[0]
		button_label := fmt.tprintf("Expand %s, %d lines hidden", fold.label, fold.end_line-fold.body_start_line)
		button_semantics, has_button_semantics := alicorn.semantic_node_lookup(&fixture.rt, alicorn.semantic_visual_id(button))
		_, has_marker_semantics := alicorn.semantic_node_lookup(&fixture.rt, alicorn.semantic_visual_id(marker))
		testing.expect(t, has_button_semantics && button_semantics.label == button_label && !has_marker_semantics,
			"the chevron announces the hidden line count and the ellipsis is decorative")
		rows := &view.manual_folding.rows
		next, next_fold, mapped := semantic_zoom_rows_source_at(rows, 1)
		testing.expect(t, mapped && next == int(fold.end_line) && next_fold == -1 &&
			rows.row_count == int(document.line_count-fold.end_line+fold.body_start_line),
			"the first source line after the fold follows the heading with no marker row")
		header, displayed, _ := editor_stale_window_test_line(&fixture.app, &fixture.rt, 0)
		last_after, found_after := alicorn.text_node_line_geometry(&fixture.rt, header, line_count-1)
		testing.expect(t, found_after && displayed == heading &&
			alicorn.text_node_line_count(&fixture.rt, header) == line_count && last_after.bounds == last_before.bounds &&
			last_after.byte_start == last_before.byte_start && last_after.byte_end == last_before.byte_end,
			"the decoration must preserve the heading's wrap geometry and byte ranges")
		painted := false
		for command in fixture.rt.display {
			if command.owner != marker { continue }
			if paint, ok := command.payload.(alicorn.Text_Paint); ok {
				run, valid := alicorn.paint_text_run_resolve(&fixture.rt, paint.run)
				visible := alicorn.rect_intersection(command.bounds, command.clip)
				painted = valid && run.value == "…" && visible.w > 0 && visible.h > 0 &&
					command.bounds.x > last_after.bounds.x+last_after.bounds.w &&
					abs(command.bounds.y-last_after.bounds.y) <= 1
			}
		}
		testing.expect(t, painted, "the ellipsis must paint after the heading's last visual line")
	}
	semantic_zoom_test_unchanged(&fixture, t, source, document.editor_revision, false)
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
	folding := Editor_Manual_Folding{anchor_line=3, anchor_offset=4, anchor_pending=true}
	if !manual_folding_restore_anchor_at_row(&view, &folding, &index, 3) {
		testing.expect(t, false, "last-fold expansion must restore the source anchor using normal line geometry")
		return
	}
	testing.expect(t, view.scroll_y == 64 && view.restore_y_pending &&
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
	testing.expect(t, folding.rows.row_count == 3 && len(folding.rows.folds) == 1 &&
		manual_folding_row_for_source(&folding.rows, 7) == 0,
		"a collapsed parent hides its nested fold and anchors hidden lines to the visible heading")

	folding.collapsed[0] = false
	testing.expect(t, manual_folding_rebuild_rows(&folding), "expanded parent should reveal nested folds")
	testing.expect(t, folding.rows.row_count == 8 && len(folding.rows.folds) == 1 &&
		folding.rows.folds[0].fold.label == "child" && !folding.rows.folds[0].expanded,
		"the child's independent collapsed state survives the parent's collapse/expand cycle")
}
