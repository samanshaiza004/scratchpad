package main

import "core:testing"

@(test)
test_quick_open_matches_basenames_paths_and_multiple_terms :: proc(t: ^testing.T) {
	readme := "docs/README.md"
	config := "frontends/alicorn/caliber.config.json"
	other := "docs/RESEARCH.md"

	testing.expect(t, quick_open_match_score("readme", readme) >= 0,
		"Quick Open should match a filename without requiring its directory")
	testing.expect(t, quick_open_match_score("front alicorn config", config) >= 0,
		"separate fuzzy terms should match across a relative path")
	testing.expect(t, quick_open_match_score("missing-file", readme) < 0,
		"a path missing a query term should not be returned")
	testing.expect(t, quick_open_match_score("", readme) == 0,
		"an empty query should keep the stable backend path ordering")
}

@(test)
test_quick_open_filter_orders_by_match_then_source_order :: proc(t: ^testing.T) {
	paths := [?]string{
		"src/README.md.backup",
		"README.md",
		"docs/README.md.old",
	}
	results := quick_open_filter(paths[:], "readme.md", context.temp_allocator)
	defer delete(results)
	testing.expect(t, len(results) == 3,
		"all matching paths should be retained in the filtered result set")
	testing.expect(t, results[0].path == "README.md",
		"an exact basename match should rank ahead of weaker path matches")
}

@(test)
test_quick_open_is_a_file_menu_command_with_primary_p_shortcut :: proc(t: ^testing.T) {
	app: App
	init_menus(&app)
	found := false
	for item in app.file_items {
		if item.kind == .Command && item.command == action_id_for(ACTION_FILE_QUICK_OPEN) && item.label == "Quick Open…" &&
		   item.shortcut.key == 'P' && item.shortcut.modifiers == {.Primary} {
			found = true
			break
		}
	}
	testing.expect(t, found,
		"Quick Open should be discoverable from the File menu with its registered action identity")
}
