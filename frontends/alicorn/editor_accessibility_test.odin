package main

import "core:testing"
import alicorn "alicorn:runtime"

@(test)
test_editor_accessibility_retire_removes_area_and_projection :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 320, 200})
	defer alicorn.destroy_runtime(&rt)
	projection := editor_accessibility_projection_build("retired-document", "text", 7, context.temp_allocator)
	area_id := projection.area_id
	run := projection.runs[0]
	area_actions := alicorn.semantic_actions_add({}, .Focus)
	_ = alicorn.semantic_node_set(&rt, alicorn.Semantic_Node_Description{
		id=area_id,
		role=.Text_Area,
		label="Document",
		actions=area_actions,
	})
	_ = alicorn.semantic_text_run_set(&rt, run.id, area_id, run.value, run.character_lengths)

	app: App
	app.accessibility_projection = projection
	app.accessibility_semantic_area_id = area_id
	app.accessibility_semantic_revision = projection.editor_revision
	app.accessibility_semantic_has_runs = true
	app.accessibility_semantic_run_count = len(projection.runs)
	editor_accessibility_retire(&app, &rt)

	_, area_found := alicorn.semantic_node_lookup(&rt, area_id)
	_, run_found := alicorn.semantic_node_lookup(&rt, run.id)
	testing.expect(t, !area_found && !run_found && len(app.accessibility_projection.document_id) == 0,
		"retiring the final open document should remove its semantic subtree and full source projection")
	testing.expect(t, app.accessibility_semantic_area_id == (alicorn.Semantic_ID{}) &&
		!app.accessibility_semantic_has_runs && app.accessibility_semantic_run_count == 0,
		"retiring an editor should clear retained semantic identity bookkeeping")
}

@(test)
test_editor_accessibility_revision_run_removal_preserves_area :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 320, 200})
	defer alicorn.destroy_runtime(&rt)
	projection := editor_accessibility_projection_build("revised-document", "text", 3, context.temp_allocator)
	defer editor_accessibility_projection_destroy(&projection)
	area_id := projection.area_id
	run_id := projection.runs[0].id
	_ = alicorn.semantic_node_set(&rt, alicorn.Semantic_Node_Description{
		id=area_id,
		role=.Text_Area,
		label="Document",
	})
	_ = alicorn.semantic_text_run_set(&rt, run_id, area_id, projection.runs[0].value, projection.runs[0].character_lengths)

	editor_accessibility_semantic_runs_remove(&rt, area_id, projection.editor_revision, len(projection.runs))
	_, area_found := alicorn.semantic_node_lookup(&rt, area_id)
	_, run_found := alicorn.semantic_node_lookup(&rt, run_id)
	testing.expect(t, area_found && !run_found,
		"replacing document contents should retire revision-scoped runs without removing the stable Text_Area")
}
