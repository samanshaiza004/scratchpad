package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"
import bridge "./bridge"

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
test_editor_short_document_rows_keep_fixed_height :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 800, 520})
	ui, build := alicorn.begin_frame(&rt)
	if !build { alicorn.destroy_runtime(&rt); return }
	alicorn.container_begin(&ui, .Root, label="short-editor-root", style=alicorn.layout_style(.Column, width=800, height=520, clip=true))
	list := alicorn.virtual_list_begin(
		&ui,
		2,
		EDITOR_ROW_HEIGHT,
		key=alicorn.key_string("short-editor-list"),
		style=alicorn.layout_style(grow=1, clip=true),
	)
	row_ids: [2]alicorn.Node_ID
	for position := list.first; position < list.last; position += 1 {
		id := alicorn.container_begin(
			&ui,
			.Container,
			label="short-editor-logical-row",
			key=alicorn.key_u64(u64(position)),
			style=editor_logical_row_style(),
		)
		if position >= 0 && position < len(row_ids) { row_ids[position] = id }
		alicorn.container_end(&ui)
	}
	alicorn.virtual_list_end(&ui, list)
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)

	row0, row0_ok := rt.nodes[row_ids[0]]
	row1, row1_ok := rt.nodes[row_ids[1]]
	testing.expect(t, row0_ok && row1_ok, "both short-document rows should be realized")
	if row0_ok && row1_ok {
		testing.expect(t, row0.bounds.h == EDITOR_ROW_HEIGHT && row1.bounds.h == EDITOR_ROW_HEIGHT,
			"a short document must keep each source row at the fixed editor row height")
		testing.expect(t, row1.bounds.y-row0.bounds.y == EDITOR_ROW_HEIGHT,
			"unused viewport space must remain below short documents instead of spreading their rows")
	}
	alicorn.destroy_runtime(&rt)
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
	// This is deliberately a source-code fixture: soft-wrap policy should keep
	// long Go rows on the horizontal-scroll path while prose rows wrap.
	path := fmt.tprintf("%s/large-source.go", workspace)
	content := make([dynamic]u8, 0, allocator=context.temp_allocator)
	defer delete(content)
	for index in 0..<26_150 {
		if index == 1 {
			append(&content, 'x')
			append(&content, '\n')
			continue
		}
		line := fmt.tprintf("line-%05d:", index)
		for byte in transmute([]u8)line { append(&content, byte) }
		target_bytes := 800 if index == 2 else 400
		for _ in 0..<(target_bytes-len(line)) { append(&content, 'x') }
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
	testing.expect(t, active.language == "go", "the long-line fixture should exercise the source-code no-wrap policy")
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
	for target in app.editor_row_targets {
		node, node_found := rt.nodes[target.node]
		if !node_found { continue }
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
			click_x, click_y := row_node.bounds.x+70, row_node.bounds.y+row_node.bounds.h/2
			hit, hit_ok := alicorn.text_node_hit_test(&rt, target.node, click_x, click_y)
			testing.expect(t, hit_ok && hit.byte >= 0 && hit.byte <= len(row_node.text),
				"the realized source row should expose a shaped-run hit-test in local display bytes")
			document_revision := active.editor_revision
			application_revision := app.backend.state.revision
			pointer_event := alicorn.Pointer_Event{kind=.Down, x=click_x, y=click_y, button=1}
			pointer_target := alicorn.process_pointer(&rt, pointer_event)
			testing.expect(t, pointer_target == app.editor_scroll_owner,
				"the real retained hit-test should route source clicks to the durable generic text-input owner")
			editor_pointer(rawptr(&app), &rt, pointer_event, pointer_target)
			view_index := editor_view_find(app.editor_views[:], active.id)
			testing.expect(t, rt.focused == app.editor_scroll_owner && view_index >= 0,
				"a real pointer click should focus the durable editor viewport and assign per-document caret state")
			if view_index >= 0 {
				view := &app.editor_views[view_index]
				testing.expect(t, view.caret_byte >= line.source_start && view.caret_byte <= line.source_end,
					"pointer hit testing should map to a legal source byte within the clicked line")
				_ = alicorn.process_pointer(&rt, alicorn.Pointer_Event{kind=.Up, x=click_x, y=click_y, button=1})
				editor_pointer(rawptr(&app), &rt, alicorn.Pointer_Event{kind=.Up, x=click_x, y=click_y, button=1}, 0)

				// The line's clickable horizontal area is the editor viewport, not
				// only the glyph bounds. Clicking before text and after a short line
				// should map to legal source line boundaries.
				owner_node, _ = rt.nodes[app.editor_scroll_owner]
				before_text_x := owner_node.bounds.x+2
				before_text_y := row_node.bounds.y+row_node.bounds.h/2
				before_event := alicorn.Pointer_Event{kind=.Down, x=before_text_x, y=before_text_y, button=1}
				before_target := alicorn.process_pointer(&rt, before_event)
				editor_pointer(rawptr(&app), &rt, before_event, before_target)
				testing.expect(t, before_target == app.editor_scroll_owner && view.caret_byte == line.source_start,
					"clicking before the first glyph should place the caret at the source line start")
				_ = alicorn.process_pointer(&rt, alicorn.Pointer_Event{kind=.Up, x=before_text_x, y=before_text_y, button=1})
				editor_pointer(rawptr(&app), &rt, alicorn.Pointer_Event{kind=.Up, x=before_text_x, y=before_text_y, button=1}, 0)
				short_node := alicorn.Node_ID(0)
				for row in app.editor_row_targets {
					if row.logical_line == 1 { short_node = row.node; break }
				}
				short_row, short_found := rt.nodes[short_node]
				short_line, short_line_found := editor_window_line(&app.editor_window, 1)
				if short_found && short_line_found {
					far_right_x := owner_node.bounds.x+owner_node.scroll_viewport_width-4
					far_right_y := short_row.bounds.y+short_row.bounds.h/2
					right_event := alicorn.Pointer_Event{kind=.Down, x=far_right_x, y=far_right_y, button=1}
					right_target := alicorn.process_pointer(&rt, right_event)
					editor_pointer(rawptr(&app), &rt, right_event, right_target)
					testing.expect(t, view.caret_byte == short_line.source_end,
						"clicking beyond a short source line should place the caret at its end")
					_ = alicorn.process_pointer(&rt, alicorn.Pointer_Event{kind=.Up, x=far_right_x, y=far_right_y, button=1})
					editor_pointer(rawptr(&app), &rt, alicorn.Pointer_Event{kind=.Up, x=far_right_x, y=far_right_y, button=1}, 0)
				} else {
					testing.expect(t, false, "the fixture's short logical row should be realized for line-edge hit testing")
				}

				// Dragging is captured by the stable scroll owner while selection
				// endpoints move across independently retained text rows.
				drag_start_x := row_node.bounds.x+90
				drag_start_y := row_node.bounds.y+row_node.bounds.h/2
				drag_down := alicorn.Pointer_Event{kind=.Down, x=drag_start_x, y=drag_start_y, button=1}
				drag_target := alicorn.process_pointer(&rt, drag_down)
				editor_pointer(rawptr(&app), &rt, drag_down, drag_target)
				drag_anchor := view.selection_anchor
				third_target := Editor_Row_Target{}
				for row in app.editor_row_targets {
					if row.logical_line == 2 { third_target = row; break }
				}
				drag_row, drag_row_found := rt.nodes[third_target.node]
				drag_move := alicorn.Pointer_Event{kind=.Move, x=drag_row.bounds.x+150, y=drag_row.bounds.y+drag_row.bounds.h/2}
				drag_move_target := alicorn.process_pointer(&rt, drag_move)
				editor_pointer(rawptr(&app), &rt, drag_move, drag_move_target)
				third_line, third_line_found := editor_window_line(&app.editor_window, 2)
				testing.expect(t, drag_row_found && third_line_found && view.dragging_selection &&
					view.selection_anchor == drag_anchor && view.caret_byte >= third_line.source_start && view.caret_byte <= third_line.source_end,
					"captured pointer dragging should preserve the anchor and extend selection into the row under the pointer")
				_ = alicorn.process_pointer(&rt, alicorn.Pointer_Event{kind=.Up, x=drag_move.x, y=drag_move.y, button=1})
				editor_pointer(rawptr(&app), &rt, alicorn.Pointer_Event{kind=.Up, x=drag_move.x, y=drag_move.y, button=1}, 0)
				testing.expect(t, !view.dragging_selection, "pointer-up should release the frontend's drag-selection state")
				cancel_down := alicorn.Pointer_Event{kind=.Down, x=drag_start_x, y=drag_start_y, button=1}
				cancel_target := alicorn.process_pointer(&rt, cancel_down)
				editor_pointer(rawptr(&app), &rt, cancel_down, cancel_target)
				captured_before_cancel := rt.captured_node
				cancel_event := alicorn.Pointer_Event{kind=.Cancel}
				_ = alicorn.process_pointer(&rt, cancel_event)
				editor_pointer(rawptr(&app), &rt, cancel_event, captured_before_cancel)
				testing.expect(t, captured_before_cancel == app.editor_scroll_owner && rt.captured_node == 0 && !view.dragging_selection,
					"native pointer-capture cancellation should release both Alicorn capture and local drag state")
				// A plain click collapses the drag selection before testing the
				// ordinary Left/Right contract.
				reset_down := alicorn.Pointer_Event{kind=.Down, x=click_x, y=click_y, button=1}
				reset_target := alicorn.process_pointer(&rt, reset_down)
				editor_pointer(rawptr(&app), &rt, reset_down, reset_target)
				_ = alicorn.process_pointer(&rt, alicorn.Pointer_Event{kind=.Up, x=click_x, y=click_y, button=1})
				editor_pointer(rawptr(&app), &rt, alicorn.Pointer_Event{kind=.Up, x=click_x, y=click_y, button=1}, 0)

				semantic_focus_before_vertical_key := alicorn.semantic_focus_state(&rt).id
				vertical_tree_handled := application_key(rawptr(&app), &rt, .Down)
				testing.expect(t, !vertical_tree_handled && rt.focused == app.editor_scroll_owner &&
					alicorn.semantic_focus_state(&rt).id == semantic_focus_before_vertical_key,
					"vertical keys outside this editor slice must not fall through to workspace-tree navigation")
				clicked_caret := view.caret_byte
				right_handled := editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Right})
				testing.expect(t, right_handled && view.caret_byte > clicked_caret,
					"Right should move the read-only caret locally without an authoritative edit")
				anchor_before_extend := view.selection_anchor
				shift_handled := editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Right, shift=true})
				testing.expect(t, shift_handled && view.selection_anchor == anchor_before_extend && view.caret_byte > view.selection_anchor,
					"Shift+Right should extend a directional frontend-local selection")
				view.caret_byte = line.source_start
				view.selection_anchor = line.source_start
				view.caret_affinity = .Leading
				view.anchor_affinity = .Leading
				word_right_handled := editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Word_Right})
				word_right_caret := view.caret_byte
				testing.expect(t, word_right_handled, "the editor should consume a platform-normalized word-right key")
				testing.expect(t, word_right_caret > line.source_start, "word-right should move to a later Runa word boundary")
				view.caret_byte = line.source_start
				view.selection_anchor = line.source_start
				word_extend_handled := editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Word_Right, shift=true})
				testing.expect(t, word_extend_handled && view.selection_anchor == line.source_start && view.caret_byte > line.source_start,
					"Shift+word-right should extend a frontend-local directional selection through Runa boundaries")
				// Start at a nonzero column on a long row, then move through a one-character row and
				// back. preferred_x must survive the short row and restore the same
				// visual column on the following long row.
				preferred_click_x := row_node.bounds.x+170
				preferred_click_y := row_node.bounds.y+row_node.bounds.h/2
				preferred_down := alicorn.Pointer_Event{kind=.Down, x=preferred_click_x, y=preferred_click_y, button=1}
				preferred_target := alicorn.process_pointer(&rt, preferred_down)
				editor_pointer(rawptr(&app), &rt, preferred_down, preferred_target)
				_ = alicorn.process_pointer(&rt, alicorn.Pointer_Event{kind=.Up, x=preferred_click_x, y=preferred_click_y, button=1})
				editor_pointer(rawptr(&app), &rt, alicorn.Pointer_Event{kind=.Up, x=preferred_click_x, y=preferred_click_y, button=1}, 0)
				first_caret := view.caret_byte
				down_short := editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Down})
				short_caret := view.caret_byte
				down_long := editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Down, shift=true})
				long_caret := view.caret_byte
				selection_anchor_after_shift_down := view.selection_anchor
				up_short := editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Up, shift=true})
				up_caret := view.caret_byte
			down_restore := editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Down, shift=true})
				testing.expect(t, preferred_target == app.editor_scroll_owner && down_short && down_long && up_short && down_restore &&
					view.preferred_x_set && short_line_found && short_caret == short_line.source_end &&
					up_caret == short_caret && view.caret_byte == long_caret && long_caret > first_caret &&
					view.selection_anchor == selection_anchor_after_shift_down && view.selection_anchor == short_caret,
					"vertical motion should keep its preferred visual X across a short row and return to the original column")

				// Page keys use the same local geometry and reveal the resulting
				// logical row through the retained virtual-list viewport.
				_ = editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Home})
				page_down_handled := editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Page_Down})
				page_down_line, page_down_line_found := editor_line_for_source(&app.editor_window, view.caret_byte)
				owner_after_page, owner_after_page_found := rt.nodes[app.editor_scroll_owner]
				page_scroll_moved := owner_after_page_found && owner_after_page.scroll_offset_y > 0
				page_up_handled := editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Page_Up})
				page_up_line, page_up_line_found := editor_line_for_source(&app.editor_window, view.caret_byte)
				testing.expect(t, page_down_handled && page_down_line_found && page_down_line.logical_line > 0 && page_scroll_moved &&
					page_up_handled && page_up_line_found && page_up_line.logical_line < page_down_line.logical_line,
					"Page Down/Up should navigate by viewport-sized logical ranges and keep the caret visible")
				page_anchor := view.selection_anchor
				shift_page_down := editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Page_Down, shift=true})
				shift_page_line, shift_page_line_found := editor_line_for_source(&app.editor_window, view.caret_byte)
				shift_page_down_caret := view.caret_byte
				shift_page_up := editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Page_Up, shift=true})
				shift_page_back_line, shift_page_back_found := editor_line_for_source(&app.editor_window, view.caret_byte)
				shift_page_down_distance := shift_page_down_caret-page_anchor if shift_page_down_caret >= page_anchor else page_anchor-shift_page_down_caret
				shift_page_back_distance := view.caret_byte-page_anchor if view.caret_byte >= page_anchor else page_anchor-view.caret_byte
				testing.expect(t, shift_page_down && shift_page_line_found && shift_page_up && shift_page_back_found &&
					shift_page_line.logical_line > page_up_line.logical_line &&
					shift_page_back_distance < shift_page_down_distance && view.selection_anchor == page_anchor,
					fmt.tprintf("Shift+Page Up/Down should extend then contract selection without moving its anchor (down=%t line=%d start=%d up=%t line=%d down-distance=%d up-distance=%d anchor=%d expected_anchor=%d)",
						shift_page_down, shift_page_line.logical_line, page_up_line.logical_line,
						shift_page_up, shift_page_back_line.logical_line, shift_page_down_distance, shift_page_back_distance,
						view.selection_anchor, page_anchor))

				_ = editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Right, shift=true})
				paint_line, paint_line_found := editor_line_for_source(&app.editor_window, view.caret_byte)
				paint_node_id := alicorn.Node_ID(0)
				if paint_line_found { paint_node_id = editor_row_node_for_line(app.editor_row_targets[:], paint_line.logical_line) }
				_ = build_app(rawptr(&app), &rt, 1100, 720, 1)
				row_node, row_found = rt.nodes[paint_node_id]
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
			_ = alicorn.process_pointer(&rt, alicorn.Pointer_Event{kind=.Up, x=click_x, y=click_y, button=1})
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

	workspace_split_id := alicorn.Node_ID(0)
	for node_id in rt.order {
		node, node_found := rt.nodes[node_id]
		if node_found && node.kind == .Split && node.label == "scratchpad-workspace-editor-split" {
			workspace_split_id = node_id
			break
		}
	}
	testing.expect(t, workspace_split_id != 0, "the Scratchpad tree and editor should use Alicorn's retained split primitive")
	if workspace_split_id == 0 { return }
	workspace_split, split_found := rt.nodes[workspace_split_id]
	testing.expect(t, split_found && workspace_split.split_min_first == 180 && workspace_split.split_min_second == 480,
		"the workspace split should preserve useful minimum widths for both panes")
	if !split_found || len(workspace_split.children) != 3 { return }
	first_before, first_found := rt.nodes[workspace_split.children[0]]
	divider, divider_found := rt.nodes[workspace_split.children[1]]
	second_before, second_found := rt.nodes[workspace_split.children[2]]
	if !first_found || !divider_found || !second_found { return }
	position_before := workspace_split.split_position
	first_before_width := first_before.bounds.w
	second_before_width := second_before.bounds.w
	start_x := divider.bounds.x + divider.bounds.w/2
	start_y := divider.bounds.y + divider.bounds.h/2
	_ = alicorn.process_pointer(&rt, alicorn.Pointer_Event{kind=.Down, x=start_x, y=start_y, button=1})
	_ = alicorn.process_pointer(&rt, alicorn.Pointer_Event{kind=.Move, x=start_x+40, y=start_y})
	presentation_ui, presentation_ready := alicorn.begin_presentation_frame(&rt)
	if presentation_ready { alicorn.end_presentation_frame(&presentation_ui) }
	workspace_split_after, split_after_found := rt.nodes[workspace_split_id]
	first_after, first_after_found := rt.nodes[workspace_split.children[0]]
	second_after, second_after_found := rt.nodes[workspace_split.children[2]]
	testing.expect(t, presentation_ready, "the workspace divider drag should resolve a retained presentation frame")
	testing.expect(t, split_after_found && workspace_split_after.split_position == position_before+40,
		"dragging the Alicorn divider should update the retained split position")
	testing.expect(t, first_after_found && first_after.bounds.w > first_before_width &&
		second_after_found && second_after.bounds.w < second_before_width,
		fmt.tprintf("dragging the Alicorn divider should resize the real tree and editor panes (first %v -> %v; second %v -> %v)",
			first_before_width, first_after.bounds.w, second_before_width, second_after.bounds.w))
	_ = alicorn.process_pointer(&rt, alicorn.Pointer_Event{kind=.Up, x=start_x+40, y=start_y, button=1})
	alicorn.invalidate_root(&rt, "Scratchpad workspace split retention test rebuild")
	_ = build_app(rawptr(&app), &rt, 1100, 720, 1)
	workspace_split_id = 0
	for node_id in rt.order {
		node, node_found := rt.nodes[node_id]
		if node_found && node.kind == .Split && node.label == "scratchpad-workspace-editor-split" {
			workspace_split_id = node_id
			break
		}
	}
	retained_split, retained_split_found := rt.nodes[workspace_split_id]
	testing.expect(t, retained_split_found && retained_split.split_position == position_before+40,
		"the keyed split should retain the user's width across an application description rebuild")
}
