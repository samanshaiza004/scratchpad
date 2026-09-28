package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"
import bridge "./bridge"

ALICORN_TEST_UI_FONT_DATA :: #load("../../.deps/alicorn/assets/fonts/AtkinsonHyperlegibleNext-Variable.ttf")
ALICORN_TEST_MONO_FONT_DATA :: #load("../../.deps/alicorn/assets/fonts/AtkinsonHyperlegibleMono-Variable.ttf")

tree_test_wake :: proc(data: rawptr) {}

backend_integration_test_mutex: sync.Mutex

@(test)
test_editor_view_scroll_restores_only_after_document_activation :: proc(t: ^testing.T) {
	view := Editor_View_State{scroll_y=0, scroll_x=0}

	// Ordinary input/rebuild flow must treat the retained runtime offset as the
	// current value, never as a reason to restore an older snapshot.
	live := editor_view_sync_scroll(&view, 100, 40, 900, 500, true)
	testing.expect(t, !live.vertical && !live.horizontal, "ordinary scroll movement must not schedule a restore")
	testing.expect(t, view.scroll_y == 100 && view.scroll_x == 40, "ordinary rebuilds should save both live scroll offsets")

	// A document transition is the only event that pushes the saved view back
	// into Alicorn. Horizontal restore waits for the bounded window/content width.
	view.scroll_y = 480
	view.scroll_x = 210
	editor_view_mark_active(&view)
	vertical := editor_view_sync_scroll(&view, 0, 0, 900, 100, false)
	testing.expect(t, vertical.vertical && vertical.scroll_y == 480, "activating a document should restore its saved vertical view once")
	testing.expect(t, !vertical.horizontal && view.restore_x_pending && view.scroll_x == 210,
		"horizontal restore should remain pending until content geometry is available")

	horizontal := editor_view_sync_scroll(&view, 480, 0, 900, 120, true)
	testing.expect(t, !horizontal.vertical && horizontal.horizontal && horizontal.scroll_x == 120,
		"horizontal restore should happen once and clamp to current content geometry")
	next := editor_view_sync_scroll(&view, 520, 90, 900, 120, true)
	testing.expect(t, !next.vertical && !next.horizontal && view.scroll_y == 520 && view.scroll_x == 90,
		"after restoration, normal scrolling should again update saved view state")
}

@(test)
test_editor_line_number_text_has_no_fixed_zero_padding :: proc(t: ^testing.T) {
	testing.expect(t, editor_line_number_text(1) == "1", "the first line number should not be padded")
	testing.expect(t, editor_line_number_text(10) == "10", "two-digit line numbers should use their natural width")
	testing.expect(t, editor_line_number_text(100_000) == "100000", "large line numbers should remain accurate without extra padding")
	testing.expect(t, editor_line_number_gutter_width(167) == 42, "ordinary documents should use a compact three-digit gutter")
	testing.expect(t, editor_line_number_gutter_width(100_000) == 72, "the gutter should widen only when the logical line count needs another digit")
}

@(test)
test_editor_horizontal_extent_is_high_water_per_revision :: proc(t: ^testing.T) {
	view := Editor_View_State{}
	width := editor_view_observe_horizontal_extent(&view, 3, 1_800)
	testing.expect(t, width == 1_800, "the first bounded window establishes a minimum horizontal extent")
	width = editor_view_observe_horizontal_extent(&view, 3, 600)
	testing.expect(t, width == 1_800, "a shorter bounded window must not shrink horizontal scroll geometry")
	width = editor_view_observe_horizontal_extent(&view, 3, 2_400)
	testing.expect(t, width == 2_400, "a newly observed wider window should grow horizontal extent")
	width = editor_view_observe_horizontal_extent(&view, 3, 900)
	testing.expect(t, width == 2_400, "later short windows should preserve the widest observed extent")
	width = editor_view_observe_horizontal_extent(&view, 4, 720)
	testing.expect(t, width == 720, "a new editor revision should reset the old revision's extent")
}

@(test)
test_editor_projection_preserves_source_bytes_and_maps_expansions :: proc(t: ^testing.T) {
	raw := [?]u8{0xEF, 0xBB, 0xBF, 'A', '\t', 0xFF, '\r', '\n', 'e', 0xCC, 0x81}
	source_bytes, allocation_error := make([]u8, len(raw), context.temp_allocator)
	testing.expect(t, allocation_error == nil, "projection fixture should allocate")
	if allocation_error != nil { return }
	defer delete(source_bytes, context.temp_allocator)
	for index in 0..<len(raw) { source_bytes[index] = raw[index] }
	source := bridge.Visible_Window{
		document_id="projection-doc",
		application_rev=4,
		editor_revision=9,
		start_line=0,
		end_line=2,
		start_byte=0,
		source=source_bytes,
	}
	window, ok, message := editor_window_from_visible(&source, context.temp_allocator)
	testing.expect(t, ok, message)
	if !ok { return }
	source_bytes = {}
	defer editor_window_destroy(&window, context.temp_allocator)
	testing.expect(t, len(window.lines) == 2, "SPVS source should project only its declared logical rows")
	if len(window.lines) == 2 {
		line := window.lines[0]
		testing.expect(t, line.display == "A   \\xFF", "BOM should be hidden, tabs expanded, and invalid bytes escaped deterministically")
		expected_offsets := [?]u64{3, 4, 4, 4, 5, 5, 5, 5, 6}
		offsets_match := len(line.display_bytes) == len(expected_offsets)
		if offsets_match {
			for index in 0..<len(expected_offsets) {
				if line.display_bytes[index] != expected_offsets[index] { offsets_match = false; break }
			}
		}
		testing.expect(t, offsets_match, "display boundaries should map back to exact source byte boundaries")
		testing.expect(t, window.lines[1].display == "e\xCC\x81", "valid combining Unicode bytes should be preserved")
	}
}

@(test)
test_editor_projection_hit_testing_keeps_synthetic_spans_atomic :: proc(t: ^testing.T) {
	source := [?]u8{'A', '\t', 0xFF, 'B'}
	line, ok := editor_project_line(source[:], 100, 0, context.temp_allocator)
	testing.expect(t, ok && line.display == "A   \\xFFB", "tab and invalid byte projection should remain visible and deterministic")
	if !ok { return }
	defer {
		delete(line.display, context.temp_allocator)
		delete(line.display_bytes, context.temp_allocator)
	}
	// The tab occupies display byte boundaries 1..4 but source bytes 101..102.
	testing.expect(t, editor_display_to_source(&line, 1) == 101, "the leading edge of a tab should map before its source byte")
	testing.expect(t, editor_display_to_source(&line, 2) == 101, "the left half of an expanded tab should snap before the source byte")
	testing.expect(t, editor_display_to_source(&line, 3) == 102, "the right half of an expanded tab should snap after the source byte")
	testing.expect(t, editor_source_to_display(&line, 101) == 1 && editor_source_to_display(&line, 102) == 4,
		"source boundaries around an expanded tab should map to its visual edges")
	// The escaped invalid byte occupies four display bytes but one source byte.
	testing.expect(t, editor_display_to_source(&line, 6) == 103, "the right half of an escaped byte should snap after its one source byte")
	testing.expect(t, editor_source_to_display(&line, 103) == 8, "the source boundary after an escaped byte should map after the full escape")
	from_tab, tab_affinity, tab_moved := editor_move_horizontal(&line, 101, alicorn.Text_Affinity.Leading, 1)
	testing.expect(t, tab_moved && from_tab == 102, "one horizontal movement should cross an expanded tab atomically")
	from_escape, escape_affinity, escape_moved := editor_move_horizontal(&line, 102, alicorn.Text_Affinity.Leading, 1)
	testing.expect(t, escape_moved && from_escape == 103, "one horizontal movement should cross an escaped byte atomically")
	_ = tab_affinity
	_ = escape_affinity
}

@(test)
test_editor_projection_caret_movement_respects_grapheme_boundaries :: proc(t: ^testing.T) {
	combining := [?]u8{'e', 0xCC, 0x81, 'x'}
	line, ok := editor_project_line(combining[:], 40, 0, context.temp_allocator)
	testing.expect(t, ok, "valid combining-mark source should project")
	if !ok { return }
	defer {
		delete(line.display, context.temp_allocator)
		delete(line.display_bytes, context.temp_allocator)
	}
	next, combining_affinity, combining_moved := editor_move_horizontal(&line, 40, alicorn.Text_Affinity.Leading, 1)
	testing.expect(t, combining_moved && next == 43, "right movement should treat a base plus combining mark as one grapheme")
	previous, previous_affinity, previous_moved := editor_move_horizontal(&line, 43, alicorn.Text_Affinity.Leading, -1)
	testing.expect(t, previous_moved && previous == 40, "left movement should not split a combining grapheme")
	_ = combining_affinity
	_ = previous_affinity

	family := [?]u8{0xF0, 0x9F, 0x91, 0xA8, 0xE2, 0x80, 0x8D, 0xF0, 0x9F, 0x91, 0xA9, 0xE2, 0x80, 0x8D, 0xF0, 0x9F, 0x91, 0xA7}
	emoji, emoji_ok := editor_project_line(family[:], 0, 0, context.temp_allocator)
	testing.expect(t, emoji_ok, "emoji ZWJ sequence should project")
	if !emoji_ok { return }
	defer {
		delete(emoji.display, context.temp_allocator)
		delete(emoji.display_bytes, context.temp_allocator)
	}
	emoji_next, emoji_affinity, emoji_moved := editor_move_horizontal(&emoji, 0, alicorn.Text_Affinity.Leading, 1)
	testing.expect(t, emoji_moved && emoji_next == u64(len(family)), "one horizontal movement should keep an emoji ZWJ sequence atomic")
	_ = emoji_affinity
}

@(test)
test_editor_projection_accepts_multilingual_utf8_and_rejects_invalid_sequences :: proc(t: ^testing.T) {
	multilingual := [?]u8{0xC3, 0xA9, 0xE0, 0xA4, 0x95, 0xD8, 0xA7, 0xD7, 0x90, 0xF0, 0x9F, 0x91, 0xA9, 0xE2, 0x80, 0x8D, 0xF0, 0x9F, 0x92, 0xBB}
	line, ok := editor_project_line(multilingual[:], 0, 0, context.temp_allocator)
	testing.expect(t, ok && line.display == string(multilingual[:]), "multilingual UTF-8 and emoji ZWJ bytes should pass through without normalization")
	if ok { delete(line.display, context.temp_allocator); delete(line.display_bytes, context.temp_allocator) }
	invalid := [?]u8{0xE0, 0x80, 0x80}
	line, ok = editor_project_line(invalid[:], 0, 0, context.temp_allocator)
	testing.expect(t, ok && line.display == "\\xE0\\x80\\x80", "overlong UTF-8 sequences should escape each invalid source byte")
	if ok { delete(line.display, context.temp_allocator); delete(line.display_bytes, context.temp_allocator) }
}

@(test)
test_editor_long_line_chunks_preserve_source_anchor_and_request_only_at_frontier :: proc(t: ^testing.T) {
	source_bytes, allocation_error := make([]u8, 16*1024, context.temp_allocator)
	testing.expect(t, allocation_error == nil, "long-line projection fixture should allocate")
	if allocation_error != nil { return }
	defer delete(source_bytes, context.temp_allocator)
	for i in 0..<len(source_bytes) { source_bytes[i] = 'x' }
	visible := bridge.Visible_Window{
		document_id="long-line",
		application_rev=2,
		editor_revision=3,
		start_line=7,
		end_line=8,
		start_byte=16*1024-32,
		line_byte_length=2*1024*1024,
		truncated=true,
		source=source_bytes,
	}
	window, ok, message := editor_window_from_visible(&visible, context.temp_allocator)
	testing.expect(t, ok, message)
	if !ok { return }
	visible.source = {}
	defer editor_window_destroy(&window, context.temp_allocator)
	testing.expect(t, editor_window_is_long_line_chunk(&window), "truncated one-line resources should be recognized as byte chunks")
	if len(window.lines) == 1 && len(window.lines[0].display_bytes) > 0 {
		testing.expect(t, window.lines[0].display_bytes[0] == window.start_byte, "display mapping should retain the absolute byte anchor")
	}
	anchor, needed := editor_long_line_next_anchor(&window, 7, 100, 200)
	testing.expect(t, !needed && anchor == 0, "a chunk request should not run before the horizontal frontier")
	anchor, needed = editor_long_line_next_anchor(&window, 7, 160, 200)
	want_anchor := window.start_byte+u64(len(window.source))-64
	testing.expect(t, needed && anchor == want_anchor && anchor > window.start_byte, "reaching the horizontal frontier should request a forward byte window with a small overlap")
	anchor, needed = editor_long_line_next_anchor(&window, 8, 200, 200)
	testing.expect(t, !needed && anchor == 0, "a neighboring logical row must not advance this line's byte window")
}

@(test)
test_read_only_editor_emits_only_realized_monospace_rows :: proc(t: ^testing.T) {
	sync.mutex_lock(&backend_integration_test_mutex)
	defer sync.mutex_unlock(&backend_integration_test_mutex)
	workspace, workspace_error := os.make_directory_temp("", "scratchpad-alicorn-editor-*", context.temp_allocator)
	if workspace_error != nil { testing.expect(t, false, "could not create editor-surface workspace"); return }
	defer _ = os.remove_all(workspace)
	path := fmt.tprintf("%s/large-source.txt", workspace)
	content := make([dynamic]u8, 0, allocator=context.temp_allocator)
	defer delete(content)
	for index in 0..<26_150 {
		line := fmt.tprintf("line-%05d:", index)
		for byte in transmute([]u8)line { append(&content, byte) }
		for _ in 0..<(400-len(line)) { append(&content, 'x') }
		append(&content, '\n')
	}
	if err := os.write_entire_file_from_string(path, string(content[:])) ; err != nil {
		testing.expect(t, false, "could not write virtualized editor fixture")
		return
	}
	backend_library, found_library := os.lookup_env("SCRATCHPAD_BACKEND_LIBRARY", context.temp_allocator)
	if !found_library { testing.expect(t, false, "editor-surface test requires the staged shared backend"); return }
	defer delete(backend_library, context.temp_allocator)

	app: App
	app.tree_directories = make([dynamic]Tree_Directory, 0, allocator=context.allocator)
	app.editor_views = make([dynamic]Editor_View_State, 0, allocator=context.allocator)
	app.editor_row_targets = make([dynamic]Editor_Row_Target, 0, allocator=context.allocator)
	loaded, load_message := bridge.backend_load(&app.backend, backend_library)
	testing.expect(t, loaded, fmt.tprintf("shared backend should load for editor-surface test: %s", load_message))
	if !loaded { return }
	started, start_message := bridge.backend_start(&app.backend, workspace, tree_test_wake, nil, context.allocator)
	testing.expect(t, started, fmt.tprintf("shared backend should start for editor-surface test: %s", start_message))
	if !started { return }
	rt: alicorn.Runtime
	defer {
		if app.backend.started { _, _ = bridge.backend_stop(&app.backend, context.allocator) }
		editor_window_destroy(&app.editor_window, context.allocator)
		editor_views_destroy(&app.editor_views, context.allocator)
		delete(app.editor_row_targets)
		if len(app.editor_presented_document_id) > 0 { delete(app.editor_presented_document_id, context.allocator) }
		alicorn.destroy_runtime(&rt)
	}
	opened := bridge.backend_command(&app.backend, "open_path", path=path, allocator=context.temp_allocator)
	testing.expect(t, opened.ok && len(app.backend.state.documents) == 1, "Go should publish the real source document")
	bridge.backend_command_result_destroy(&opened, context.temp_allocator)
	active, active_found := find_document(&app.backend.state, app.backend.state.active)
	testing.expect(t, active_found && active.line_count > 26_000 && len(content) > 10*1024*1024,
		"10 MiB fixture should expose real logical-line metadata without a whole-document frontend copy")
	if !active_found { return }
	visible := bridge.backend_command(
		&app.backend,
		"read_visible_lines",
		document_id=active.id,
		start_line=0,
		max_lines=bridge.MAX_VISIBLE_LINES,
		max_bytes=bridge.MAX_VISIBLE_BYTES,
		allocator=context.allocator,
	)
	testing.expect(t, visible.ok && visible.visible_window_owned, "generic Caliber resource should supply a bounded source window")
	if !visible.visible_window_owned { bridge.backend_command_result_destroy(&visible, context.allocator); return }
	window, window_ok, window_message := editor_window_from_visible(&visible.visible_window, context.allocator)
	testing.expect(t, window_ok, window_message)
	if window_ok {
		app.editor_window = window
		app.editor_window_ready = true
		testing.expect(t, len(app.editor_window.source) <= int(bridge.MAX_VISIBLE_BYTES),
			"the frontend must retain only the bounded Caliber source window, never the full document")
	}
	bridge.backend_command_result_destroy(&visible, context.allocator)
	if !window_ok { return }

	rt = alicorn.new_runtime(alicorn.Rect{0, 0, 1100, 720})
	testing.expect(t,
		alicorn.text_engine_load_font(&rt.text_engine, ALICORN_TEST_UI_FONT_DATA) &&
		alicorn.text_engine_load_font_role(&rt.text_engine, .Monospace, ALICORN_TEST_MONO_FONT_DATA),
		"read-only editor interaction test should load the same bundled UI and monospace roles as the native host",
	)
	_ = build_app(rawptr(&app), &rt, 1100, 720, 1)
	realized_rows := 0
	first_row_found := false
	last_fixture_row_found := false
	for node_id in rt.order {
		node, node_found := rt.nodes[node_id]
		if !node_found || !strings.has_prefix(node.key, "scratchpad-line:") { continue }
		realized_rows += 1
		if node.font != .Monospace { testing.expect(t, false, "source lines should use Alicorn's monospace/Runa role") }
	if strings.contains(node.text, "line-00000") { first_row_found = true }
	if strings.contains(node.text, "line-26149") { last_fixture_row_found = true }
	}
	testing.expect(t, realized_rows > 0 && realized_rows < len(app.editor_window.lines),
		"the editor should emit only the virtualized viewport rows, not all document lines")
	testing.expect(t, first_row_found && !last_fixture_row_found,
		"the first viewport should contain real source and omit offscreen logical rows")

	// The interactive read-only editor owns focus at the durable list owner,
	// maps pointer geometry back into source bytes, and keeps navigation local.
	if len(app.editor_row_targets) > 0 {
		target := app.editor_row_targets[0]
		row_node, row_found := rt.nodes[target.node]
		line, line_found := editor_window_line(&app.editor_window, target.logical_line)
		testing.expect(t, row_found && line_found, "a realized editor text node should have a corresponding bounded source row")
		if row_found && line_found {
			owner_node, owner_found := rt.nodes[app.editor_scroll_owner]
			testing.expect(t, owner_found && owner_node.text_input_target && owner_node.focusable,
				"the editor scroll owner should be retained as a generic text-input target")
			hit, hit_ok := alicorn.text_node_hit_test(&rt, target.node, row_node.bounds.x+70, row_node.bounds.y+row_node.bounds.h/2)
			testing.expect(t, hit_ok && hit.byte >= 0 && hit.byte <= len(row_node.text),
				"the realized source row should expose a shaped-run hit-test in local display bytes")
			document_revision := active.editor_revision
			application_revision := app.backend.state.revision
			editor_pointer(rawptr(&app), &rt, alicorn.Pointer_Event{kind=.Down, x=row_node.bounds.x+70, y=row_node.bounds.y+row_node.bounds.h/2, button=1}, target.node)
			view_index := editor_view_find(app.editor_views[:], active.id)
			testing.expect(t, rt.focused == app.editor_scroll_owner && view_index >= 0,
				"clicking a virtual text row should focus the durable editor viewport and assign per-document caret state")
			if view_index >= 0 {
				view := &app.editor_views[view_index]
				testing.expect(t, view.caret_byte >= line.source_start && view.caret_byte <= line.source_end,
					"pointer hit testing should map to a legal source byte within the clicked line")
				clicked_caret := view.caret_byte
				right_handled := editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Right})
				testing.expect(t, right_handled && view.caret_byte > clicked_caret,
					"Right should move the read-only caret locally without an authoritative edit")
				anchor_before_extend := view.selection_anchor
				shift_handled := editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Right, shift=true})
				testing.expect(t, shift_handled && view.selection_anchor == anchor_before_extend && view.caret_byte > view.selection_anchor,
					"Shift+Right should extend a directional frontend-local selection")
				_ = build_app(rawptr(&app), &rt, 1100, 720, 1)
				row_node, row_found = rt.nodes[target.node]
				selection_commands, caret_commands := 0, 0
				if row_found {
					for command in row_node.paint {
						if command.kind == .Text_Selection { selection_commands += 1 }
						if command.kind == .Text_Caret { caret_commands += 1 }
					}
				}
				testing.expect(t, selection_commands > 0 && caret_commands == 1,
					"the retained Runa text node should paint the local selection and caret after navigation")
			}
			active_after, active_still_found := find_document(&app.backend.state, active.id)
			testing.expect(t, active_still_found && active_after.editor_revision == document_revision && app.backend.state.revision == application_revision,
				"read-only pointer and keyboard navigation must emit no Caliber mutation or revision change")
		}
	}

	// Simulate wheel movement, then rebuild. The newly observed retained offset
	// must be saved rather than mistaken for a stale view that needs restoring.
	vertical_changed := alicorn.scroll_region_set_offset(&rt, app.editor_scroll_owner, 1_000, "test editor wheel scroll")
	horizontal_changed := alicorn.scroll_region_set_offset_x(&rt, app.editor_scroll_owner, 300, "test editor horizontal scroll")
	testing.expect(t, vertical_changed && horizontal_changed, "the large editor fixture should have scroll range on both axes")
	_ = build_app(rawptr(&app), &rt, 1100, 720, 1)
	view_index := editor_view_find(app.editor_views[:], active.id)
	view_saved := view_index >= 0 && app.editor_views[view_index].scroll_y == 1_000 && app.editor_views[view_index].scroll_x == 300
	testing.expect(t, view_saved, "ordinary description rebuilds must preserve live vertical and horizontal offsets")
}

@(test)
test_workspace_tree_expansion_and_semantic_selection_refresh_immediately :: proc(t: ^testing.T) {
	sync.mutex_lock(&backend_integration_test_mutex)
	defer sync.mutex_unlock(&backend_integration_test_mutex)
	workspace, workspace_error := os.make_directory_temp("", "scratchpad-alicorn-tree-*", context.temp_allocator)
	if workspace_error != nil {
		testing.expect(t, false, "could not create a temporary workspace for the Alicorn tree test")
		return
	}
	defer _ = os.remove_all(workspace)

	runa := fmt.tprintf("%s/Runa", workspace)
	parse := fmt.tprintf("%s/Runa/parse", workspace)
	cff2 := fmt.tprintf("%s/Runa/parse/cff2.odin", workspace)
	avar := fmt.tprintf("%s/Runa/parse/avar.odin", workspace)
	stable_file := fmt.tprintf("%s/stable.txt", workspace)
	if err := os.make_directory(runa); err != nil {
		testing.expect(t, false, "could not create Runa test directory")
		return
	}
	if err := os.make_directory(parse); err != nil {
		testing.expect(t, false, "could not create parse test directory")
		return
	}
	if err := os.write_entire_file_from_string(cff2, "package cff2\n"); err != nil {
		testing.expect(t, false, "could not create cff2 test file")
		return
	}
	if err := os.write_entire_file_from_string(avar, "package avar\n"); err != nil {
		testing.expect(t, false, "could not create avar test file")
		return
	}
	if err := os.write_entire_file_from_string(stable_file, "stable sibling\n"); err != nil {
		testing.expect(t, false, "could not create stable sibling test file")
		return
	}

	backend_library, found_library := os.lookup_env("SCRATCHPAD_BACKEND_LIBRARY", context.temp_allocator)
	if !found_library {
		testing.expect(t, false, "Alicorn tree integration test requires the staged shared Scratchpad backend")
		return
	}
	defer delete(backend_library, context.temp_allocator)

	app: App
	app.tree_directories = make([dynamic]Tree_Directory, 0, allocator=context.allocator)
	loaded, load_message := bridge.backend_load(&app.backend, backend_library)
	testing.expect(t, loaded, fmt.tprintf("shared Scratchpad backend should load: %s", load_message))
	if !loaded { return }
	started, start_message := bridge.backend_start(&app.backend, workspace, tree_test_wake, nil, context.allocator)
	testing.expect(t, started, fmt.tprintf("shared Scratchpad backend should start: %s", start_message))
	if !started { return }

	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 800, 600})
	defer tree_test_cleanup(t, &app, &rt)
	tree_sync_workspace(&app, &rt)
	alicorn.invalidate_root(&rt, "initial Scratchpad tree description")
	testing.expect(t, test_render_workspace_tree(t, &app, &rt), "initial workspace tree should build")

	runa_id, runa_found := test_workspace_tree_row(&rt, "Runa")
	stable_id, stable_found := test_workspace_tree_row(&rt, "stable.txt")
	initial_tree_scroll_owner := app.tree_scroll_owner
	testing.expect(t, runa_found, "root listing should contain the initially collapsed Runa folder")
	testing.expect(t, stable_found && initial_tree_scroll_owner != 0, "the root should contain an unaffected sibling and a retained scroll owner")
	if !runa_found || !stable_found { return }

	// Loading and expanding a never-opened folder must publish a new description
	// without requiring another user input event.
	testing.expect(t, test_click_workspace_tree_row(t, &app, &rt, "Runa"), "Runa folder should accept a click")
	testing.expect(t, tree_directory_index(&app, "Runa") >= 0 && app.tree_directories[tree_directory_index(&app, "Runa")].expanded,
		"the first Runa click should load and expand it")
	testing.expect(t, rt.invalidated, "folder expansion during description must retain its follow-up invalidation")
	testing.expect(t, test_render_workspace_tree(t, &app, &rt), "folder expansion should trigger the next description without new input")
	parse_id, parse_found := test_workspace_tree_row(&rt, "Runa/parse")
	testing.expect(t, parse_found, "parse should appear immediately after Runa's follow-up description")
	runa_id, _ = test_workspace_tree_row(&rt, "Runa")
	stable_id_after_expansion, stable_sibling_still_found := test_workspace_tree_row(&rt, "stable.txt")
	testing.expect(t, stable_sibling_still_found && stable_id_after_expansion == stable_id,
		"expanding a directory should retain the Node_ID of an unchanged sibling row")
	testing.expect(t, app.tree_scroll_owner == initial_tree_scroll_owner,
		"directory expansion should retain the tree's durable scroll-owner identity")
	testing.expect(t, rt.nodes[runa_id].selected, "the expanded folder should receive its selected presentation on the follow-up description")
	if !parse_found { return }

	testing.expect(t, test_click_workspace_tree_row(t, &app, &rt, "Runa/parse"), "parse folder should accept a click")
	testing.expect(t, rt.invalidated, "nested expansion should retain its follow-up invalidation")
	testing.expect(t, test_render_workspace_tree(t, &app, &rt), "nested expansion should trigger a description without new input")
	cff2_id, cff2_found := test_workspace_tree_row(&rt, "Runa/parse/cff2.odin")
	avar_id, avar_found := test_workspace_tree_row(&rt, "Runa/parse/avar.odin")
	testing.expect(t, cff2_found && avar_found, "both nested source files should appear immediately after expansion")
	parse_id, _ = test_workspace_tree_row(&rt, "Runa/parse")
	testing.expect(t, rt.nodes[parse_id].selected, "the nested folder should receive its selected presentation immediately")
	if !cff2_found || !avar_found { return }

	testing.expect(t, test_click_workspace_tree_row(t, &app, &rt, "Runa/parse/cff2.odin"), "cff2 file should accept a click")
	testing.expect(t, rt.invalidated, "opening a file during description should retain its follow-up invalidation")
	testing.expect(t, test_render_workspace_tree(t, &app, &rt), "opening a file should refresh its selected row without another input event")
	cff2_id, _ = test_workspace_tree_row(&rt, "Runa/parse/cff2.odin")
	cff2_document, cff2_active := find_document(&app.backend.state, app.backend.state.active)
	testing.expect(t, rt.nodes[cff2_id].selected && cff2_active && strings.contains(cff2_document.path, "cff2.odin"),
		"cff2 should be both the semantic focus and active document after its click")

	testing.expect(t, test_click_workspace_tree_row(t, &app, &rt, "Runa/parse/avar.odin"), "avar file should accept a click")
	testing.expect(t, rt.invalidated, "changing the active file during description should retain its follow-up invalidation")
	avar_id, _ = test_workspace_tree_row(&rt, "Runa/parse/avar.odin")
	cff2_id, _ = test_workspace_tree_row(&rt, "Runa/parse/cff2.odin")
	avar_path := rt.nodes[avar_id].key[len("workspace-entry:"):]
	focus_before_followup := alicorn.semantic_focus_state(&rt)
	testing.expect(t, focus_before_followup.id == tree_semantic_id(avar_path, false),
		"semantic focus should move to avar in the click frame")
	testing.expect(t, rt.nodes[cff2_id].selected && !rt.nodes[avar_id].selected,
		"the click frame should still contain its old description until the pending follow-up is built")
	testing.expect(t, test_render_workspace_tree(t, &app, &rt), "active file change should update selection without another input event")
	avar_id, _ = test_workspace_tree_row(&rt, "Runa/parse/avar.odin")
	cff2_id, _ = test_workspace_tree_row(&rt, "Runa/parse/cff2.odin")
	focus := alicorn.semantic_focus_state(&rt)
	testing.expect(t, focus.id == tree_semantic_id(avar_path, false), "semantic focus should move to avar immediately")
	testing.expect(t, rt.nodes[avar_id].selected && !rt.nodes[cff2_id].selected,
		"the blue selected presentation should move from cff2 to avar on that same follow-up description")
	active, active_found := find_document(&app.backend.state, app.backend.state.active)
	testing.expect(t, active_found && strings.contains(active.path, "avar.odin"), "the shared Go backend should publish avar as the active document")
}

test_render_workspace_tree :: proc(t: ^testing.T, app: ^App, rt: ^alicorn.Runtime) -> bool {
	ui, should_build := alicorn.begin_frame(rt)
	if !should_build { return false }
	alicorn.container_begin(&ui, .Root, label="scratchpad-tree-integration-test", style=alicorn.layout_style(.Column, width=800, height=600, clip=true))
	build_workspace_tree(app, &ui, rt)
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
	return true
}

test_click_workspace_tree_row :: proc(t: ^testing.T, app: ^App, rt: ^alicorn.Runtime, path: string) -> bool {
	id, found := test_workspace_tree_row(rt, path)
	if !found { return false }
	bounds := rt.nodes[id].bounds
	x, y := bounds.x + bounds.w/2, bounds.y + bounds.h/2
	_ = alicorn.process_pointer(rt, alicorn.Pointer_Event{.Down, x, y, 1})
	alicorn.invalidate_root(rt, "test pointer down")
	if !test_render_workspace_tree(t, app, rt) { return false }
	_ = alicorn.process_pointer(rt, alicorn.Pointer_Event{.Up, x, y, 1})
	alicorn.invalidate_root(rt, "test pointer release")
	return test_render_workspace_tree(t, app, rt)
}

test_workspace_tree_row :: proc(rt: ^alicorn.Runtime, path: string) -> (id: alicorn.Node_ID, found: bool) {
	for node_id in rt.order {
		if node, exists := rt.nodes[node_id]; exists && tree_test_key_matches_path(node.key, path) {
			return node_id, true
		}
	}
	return 0, false
}

tree_test_key_matches_path :: proc(key, path: string) -> bool {
	prefix := "workspace-entry:"
	if !strings.has_prefix(key, prefix) { return false }
	actual := key[len(prefix):]
	if len(actual) != len(path) { return false }
	for i in 0..<len(path) {
		actual_byte := actual[i]
		if actual_byte == '\\' { actual_byte = '/' }
		if actual_byte != path[i] { return false }
	}
	return true
}

tree_test_cleanup :: proc(t: ^testing.T, app: ^App, rt: ^alicorn.Runtime) {
	if app.backend.started {
		stopped, message := bridge.backend_stop(&app.backend, context.allocator)
		testing.expect(t, stopped, fmt.tprintf("shared Scratchpad backend should stop cleanly: %s", message))
	}
	tree_clear_directories(app)
	tree_clear_focused_path(app)
	if len(app.tree_root_path) > 0 { delete(app.tree_root_path, context.allocator) }
	alicorn.destroy_runtime(rt)
}
