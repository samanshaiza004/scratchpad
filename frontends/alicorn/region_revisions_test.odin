package main

import "core:testing"
import alicorn "alicorn:runtime"

// Issue #231 adoption: the monotonic generation is the whole contract between
// a non-monotonic input signature (hash, id, scroll offset) and Alicorn's
// region cache. These tests pin the two failure modes the mechanism must make
// observable: a signature change that is not turned into a bump (stale
// output) and a revision that goes backwards (rejected by the runtime). They
// cover the shared mechanism used by the adopted tab-strip and workspace-tree
// regions; they are synthetic fixtures, not a live Scratchpad description.

@(test)
test_region_generation_is_monotonic_and_changes_only_with_the_signature :: proc(t: ^testing.T) {
	generation: Region_Generation
	first := region_generation_next(&generation, 10)
	testing.expect(t, first > 0, "the first region generation must be usable as a revision")
	testing.expect(t, region_generation_next(&generation, 10) == first,
		"an unchanged signature must keep the cached region revision")
	second := region_generation_next(&generation, 11)
	testing.expect(t, second > first, "a changed signature must advance the revision")

	// A zero signature is a legitimate input (for example an empty string
	// hash). It must still be stable, not churn every frame.
	zero_first := region_generation_next(&generation, 0)
	testing.expect(t, zero_first > second, "a different signature must advance even when it hashes to zero")
	testing.expect(t, region_generation_next(&generation, 0) == zero_first,
		"an unchanged zero signature must remain cached")
}

// region_guard_state and region_guard_build simulate an application that
// derives a region revision from its state. The test deliberately uses
// region_generation_peek on the stale pass to model a forgotten bump.
region_guard_state: struct {
	generation: Region_Generation,
	value:      string,
}

region_guard_build :: proc(rt: ^alicorn.Runtime, stale: bool) {
	ui, should_build := alicorn.begin_frame(rt)
	if !should_build { return }
	alicorn.container_begin(&ui, .Root, key=alicorn.key_string("region-guard-root"), style=alicorn.layout_style(.Column, grow=1, padding=8))
	revision: u64
	if stale {
		revision = region_generation_peek(&region_guard_state.generation)
	} else {
		revision = region_generation_next(&region_guard_state.generation, region_hash_string(REGION_HASH_OFFSET, region_guard_state.value))
	}
	region_id, reused := alicorn.region_begin(
		&ui, "region-guard-fixture", revision,
		style=alicorn.layout_style(.Column, height=40),
	)
	if !reused {
		_ = alicorn.text(&ui, region_guard_state.value, key=alicorn.key_string("region-guard-text"), style=alicorn.layout_style(.Row, width=80, height=20), font=.Monospace, text_style=alicorn.Text_Style{overflow=.Wrap})
		alicorn.region_end(&ui, region_id, false, 0)
	}
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
}

@(test)
test_forgotten_region_bump_leaves_stale_output_detectable_via_public_queries :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 480, 240})
	defer alicorn.destroy_runtime(&rt)
	if !alicorn.text_engine_load_font_role(&rt.text_engine, .Monospace, ALICORN_TEST_MONO_FONT_DATA) {
		testing.expect(t, false, "the region guard fixture requires a monospace font role")
		return
	}
	region_guard_state = {}
	region_guard_state.value = "short"

	alicorn.invalidate_root(&rt, "region guard fixture description")
	region_guard_build(&rt, false)
	text_node, found := alicorn.node_by_key(&rt, alicorn.key_string("region-guard-text"), .Text)
	if !found { testing.expect(t, false, "the guard fixture must describe its text"); return }
	short_lines := alicorn.text_node_line_count(&rt, text_node)
	if short_lines <= 0 {
		testing.expect(t, false, "the guard fixture must retain text geometry")
		return
	}

	region_guard_state.value = "a substantially longer replacement value"
	skipped_before := rt.stats.regions_skipped
	alicorn.invalidate_root(&rt, "region guard stale description")
	region_guard_build(&rt, true) // forgotten bump: reuse the cached revision
	stale_lines := alicorn.text_node_line_count(&rt, text_node)
	testing.expectf(t, rt.stats.regions_skipped-skipped_before == 1,
		"a forgotten bump must be visible as a reused region (skipped %d)",
		rt.stats.regions_skipped-skipped_before)
	testing.expectf(t, stale_lines == short_lines,
		"a forgotten bump must retain the old text layout; stale output is therefore detectable (%d vs %d lines)",
		stale_lines, short_lines)

	alicorn.invalidate_root(&rt, "region guard fresh description")
	region_guard_build(&rt, false) // correct bump
	fresh_lines := alicorn.text_node_line_count(&rt, text_node)
	testing.expectf(t, fresh_lines > short_lines,
		"the bumped revision must rebuild the region and re-measure the new text (%d vs %d lines)",
		fresh_lines, short_lines)
}
