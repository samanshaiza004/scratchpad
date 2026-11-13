package palette_model

import "core:testing"

@(test)
test_filter_matches_terms_case_insensitively_and_preserves_order :: proc(t: ^testing.T) {
	items := [3]Item{
		{ id=Item_ID(10), title="Open Workspace", keywords="project" },
		{ id=Item_ID(20), title="Workspace Pane", description="Split editor" },
		{ id=Item_ID(30), title="Close Tab" },
	}
	output: [3]Match
	count, status := filter(items[:], "WORK pane", output[:])
	testing.expect(t, status == .Ok && count == 1, "every query token should match case-insensitively")
	if count == 1 {
		testing.expect(t, output[0].item_index == 1, "filtering should preserve the caller's result order")
	}
	count, status = filter(items[:], "wrkspc", output[:])
	testing.expect(t, status == .Ok && count == 0, "built-in matching should remain contiguous substring search")
}

@(test)
test_caller_filtered_results_preserve_application_matching :: proc(t: ^testing.T) {
	items := [2]Item{
		{ id=Item_ID(41), title="Workspace" },
		{ id=Item_ID(42), title="Worktree" },
	}
	output: [2]Match
	count, status := index_all(items[:1], output[:])
	testing.expect(t, status == .Ok && count == 1, "caller-filtered mode should index the supplied result set")
	if count == 1 {
		testing.expect(t, output[0].item_index == 0 && items[output[0].item_index].id == Item_ID(41),
			"caller ordering and stable item identity should be preserved without a second query predicate")
	}
}

@(test)
test_selection_survives_reorder_and_reconciles_unavailable_items :: proc(t: ^testing.T) {
	selection := Selection{id=Item_ID(20)}
	reordered := [3]Item{
		{ id=Item_ID(30), title="Close" },
		{ id=Item_ID(20), title="Workspace", disabled=false },
		{ id=Item_ID(10), title="Open" },
	}
	visible: [3]Match
	count, status := index_all(reordered[:], visible[:])
	testing.expect(t, status == .Ok && count == 3, "the reordered item fixture should be indexable")
	changed := reconcile(&selection, reordered[:], visible[:count])
	testing.expect(t, !changed && selection.id == Item_ID(20), "selection should follow the stable ID across reorder")

	unavailable := [2]Item{
		{ id=Item_ID(20), title="Workspace", disabled=true },
		{ id=Item_ID(30), title="Close" },
	}
	count, status = index_all(unavailable[:], visible[:])
	changed = reconcile(&selection, unavailable[:], visible[:count])
	testing.expect(t, status == .Ok && changed && selection.id == Item_ID(30),
		"a removed or disabled selection should fall back to the first enabled result")
}

@(test)
test_move_wraps_and_skips_disabled_items :: proc(t: ^testing.T) {
	items := [3]Item{
		{ id=Item_ID(1), title="First" },
		{ id=Item_ID(2), title="Disabled", disabled=true },
		{ id=Item_ID(3), title="Last" },
	}
	visible: [3]Match
	count, status := index_all(items[:], visible[:])
	selection := Selection{id=Item_ID(3)}
	moved_forward := move(&selection, items[:], visible[:count], 1)
	testing.expect(t, status == .Ok && moved_forward && selection.id == Item_ID(1),
		"moving down from the last item should wrap and skip disabled entries")
	moved_backward := move(&selection, items[:], visible[:count], -1)
	testing.expect(t, moved_backward && selection.id == Item_ID(3),
		"moving up should wrap and skip disabled entries")
	activated_id, activated := activate(selection, items[:], visible[:count])
	testing.expect(t, activated && activated_id == Item_ID(3), "an enabled selected item should activate by stable ID")
	selection.id = Item_ID(2)
	_, activated = activate(selection, items[:], visible[:count])
	testing.expect(t, !activated, "a disabled item must never activate")
}
