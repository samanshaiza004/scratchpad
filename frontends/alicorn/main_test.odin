package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
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
			key=alicorn.key_string(fmt.tprintf("short-editor-row:%d", position)),
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
	path := fmt.tprintf("%s/large-source.txt", workspace)
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
				shift_page_up := editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Page_Up, shift=true})
				shift_page_back_line, shift_page_back_found := editor_line_for_source(&app.editor_window, view.caret_byte)
				testing.expect(t, shift_page_down && shift_page_line_found && shift_page_up && shift_page_back_found &&
					shift_page_line.logical_line > page_up_line.logical_line &&
					shift_page_back_line.logical_line == page_up_line.logical_line && view.selection_anchor == page_anchor,
					"Shift+Page Up/Down should extend and contract selection without moving its anchor")

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

Editor_Edit_Test_Signal :: struct {
	sema: sync.Sema,
}

editor_edit_test_wake :: proc(data: rawptr) {
	if data == nil { return }
	signal := cast(^Editor_Edit_Test_Signal)data
	sync.sema_post(&signal.sema)
}

@(test)
test_optimistic_replacements_converge_and_stale_chain_recovers :: proc(t: ^testing.T) {
	sync.mutex_lock(&backend_integration_test_mutex)
	defer sync.mutex_unlock(&backend_integration_test_mutex)
	workspace, workspace_error := os.make_directory_temp("", "scratchpad-alicorn-edit-*", context.temp_allocator)
	if workspace_error != nil {
		testing.expect(t, false, "could not create a temporary workspace for the optimistic edit test")
		return
	}
	defer _ = os.remove_all(workspace)
	path := fmt.tprintf("%s/typing.txt", workspace)
	other_path := fmt.tprintf("%s/other.txt", workspace)
	if write_error := os.write_entire_file_from_string(path, "hello world\r\nsecond\r\nthird\r\nfourth"); write_error != nil {
		testing.expect(t, false, "could not create the committed-text source fixture")
		return
	}
	if write_error := os.write_entire_file_from_string(other_path, "another document"); write_error != nil {
		testing.expect(t, false, "could not create the deferred-tab fixture")
		return
	}
	backend_library, found_library := os.lookup_env("SCRATCHPAD_BACKEND_LIBRARY", context.temp_allocator)
	if !found_library { testing.expect(t, false, "optimistic editor test requires the staged shared backend"); return }
	defer delete(backend_library, context.temp_allocator)

	app: App
	app.tree_directories = make([dynamic]Tree_Directory, 0, allocator=context.allocator)
	app.editor_views = make([dynamic]Editor_View_State, 0, allocator=context.allocator)
	app.editor_row_targets = make([dynamic]Editor_Row_Target, 0, allocator=context.allocator)
	app.editor_edits = make([dynamic]Editor_Edit_Intent, 0, allocator=context.allocator)
	app.deferred_actions = make([dynamic]Deferred_Action, 0, allocator=context.allocator)
	init_menus(&app)
	loaded, load_message := bridge.backend_load(&app.backend, backend_library)
	testing.expect(t, loaded, fmt.tprintf("shared backend should load for optimistic editor test: %s", load_message))
	if !loaded { return }
	signal: Editor_Edit_Test_Signal
	started, start_message := bridge.backend_start(&app.backend, workspace, editor_edit_test_wake, rawptr(&signal), context.allocator)
	testing.expect(t, started, fmt.tprintf("shared backend should start for optimistic editor test: %s", start_message))
	if !started { return }
	window_lane_started := bridge.visible_window_lane_start(
		&app.visible_window_lane,
		&app.backend,
		editor_edit_test_wake,
		rawptr(&signal),
		context.allocator,
	)
	testing.expect(t, window_lane_started, "the authoritative recovery test should start the bounded visible-window lane")
	if !window_lane_started { _, _ = bridge.backend_stop(&app.backend, context.allocator); return }
	gate: sync.Sema
	lane_started := bridge.editor_edit_lane_start(
		&app.editor_edit_lane,
		&app.backend,
		editor_edit_test_wake,
		rawptr(&signal),
		context.allocator,
		&gate,
	)
	testing.expect(t, lane_started, "one serial editor edit worker should start")
	if !lane_started {
		_ = bridge.visible_window_lane_stop(&app.visible_window_lane)
		_, _ = bridge.backend_stop(&app.backend, context.allocator)
		return
	}
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 1000, 700})
	defer {
		if app.backend.started {
			_ = bridge.visible_window_lane_stop(&app.visible_window_lane)
			for _ in 0..<128 { sync.sema_post(&gate) }
			_ = editor_flush_pending_edits(&app)
			_ = bridge.editor_edit_lane_stop(&app.editor_edit_lane)
			_, _ = bridge.backend_stop(&app.backend, context.allocator)
		}
		editor_window_destroy(&app.editor_window, context.allocator)
		editor_views_destroy(&app.editor_views, context.allocator)
		tree_clear_directories(&app)
		tree_clear_focused_path(&app)
		if len(app.tree_root_path) > 0 { delete(app.tree_root_path, context.allocator) }
		for index := len(app.editor_edits)-1; index >= 0; index -= 1 { editor_remove_edit(&app, index) }
		delete(app.editor_edits)
		deferred_actions_clear(&app)
		delete(app.deferred_actions)
		delete(app.editor_row_targets)
		if len(app.editor_presented_document_id) > 0 { delete(app.editor_presented_document_id, context.allocator) }
		if len(app.editor_window_error) > 0 { delete(app.editor_window_error, context.allocator) }
		if len(app.error_message) > 0 { delete(app.error_message, context.allocator) }
		alicorn.destroy_runtime(&rt)
	}
	opened := bridge.backend_command(&app.backend, "open_path", path=path, allocator=context.temp_allocator)
	testing.expect(t, opened.ok && len(app.backend.state.documents) == 1, "Go should open the real source document before editing")
	bridge.backend_command_result_destroy(&opened, context.temp_allocator)
	typing_document_id, id_error := strings.clone(app.backend.state.active, context.allocator)
	testing.expect(t, id_error == nil && typing_document_id != "", "the typing document identity should be retained for deferred command assertions")
	defer delete(typing_document_id, context.allocator)
	opened_other := bridge.backend_command(&app.backend, "open_path", path=other_path, allocator=context.temp_allocator)
	testing.expect(t, opened_other.ok && len(app.backend.state.documents) == 2, "the second document should open for tab-switch ordering coverage")
	bridge.backend_command_result_destroy(&opened_other, context.temp_allocator)
	selected_typing := bridge.backend_command(&app.backend, "select_document", document_id=typing_document_id, allocator=context.temp_allocator)
	testing.expect(t, selected_typing.ok, "the typing document should be active before committed input begins")
	bridge.backend_command_result_destroy(&selected_typing, context.temp_allocator)
	document, document_found := find_document(&app.backend.state, app.backend.state.active)
	if !document_found { testing.expect(t, false, "opened source document should have authoritative state"); return }
	base_editor_revision := document.editor_revision
	base_application_revision := app.backend.state.application_rev
	visible := bridge.backend_command(
		&app.backend,
		"read_visible_lines",
		document_id=document.id,
		start_line=0,
		max_lines=bridge.MAX_VISIBLE_LINES,
		max_bytes=bridge.MAX_VISIBLE_BYTES,
		allocator=context.allocator,
	)
	testing.expect(t, visible.ok && visible.visible_window_owned, "the initial source should arrive through the existing bounded window resource")
	if !visible.visible_window_owned { bridge.backend_command_result_destroy(&visible, context.allocator); return }
	window, window_ok, window_error := editor_window_from_visible(&visible.visible_window, context.allocator)
	app.editor_window = window
	app.editor_window_ready = window_ok
	bridge.backend_command_result_destroy(&visible, context.allocator)
	testing.expect(t, window_ok, window_error)
	if !window_ok { return }
	if !alicorn.text_engine_load_font(&rt.text_engine, ALICORN_TEST_UI_FONT_DATA) ||
	   !alicorn.text_engine_load_font_role(&rt.text_engine, .Monospace, ALICORN_TEST_MONO_FONT_DATA) {
		testing.expect(t, false, "optimistic editor test should load the bundled UI and monospace fonts")
		return
	}
	_ = build_app(rawptr(&app), &rt, 1000, 700, 1)
	view_index, view_ok := editor_view_ensure(&app.editor_views, document.id)
	testing.expect(t, view_ok && app.editor_scroll_owner != 0, "the real document build should create a durable editor owner")
	if !view_ok { return }
	view := &app.editor_views[view_index]
	view.caret_byte = 9 // hello wor|ld
	view.selection_anchor = view.caret_byte
	_ = alicorn.focus(&rt, app.editor_scroll_owner)
	commits := [7]string{"x", "a", "b", "c", "d", "e", "f"}
	for text in commits {
		editor_text_input(
			rawptr(&app),
			&rt,
			app.editor_scroll_owner,
			host.Application_Text_Input_Event{kind=.Commit, text=text},
		)
	}
	// Replace a directional selection, then join lines with Backspace and
	// Delete. All three operations must share the same optimistic replacement
	// path while the first Caliber request remains deliberately blocked.
	view.selection_anchor = 9
	view.caret_byte = 16
	editor_text_input(
		rawptr(&app),
		&rt,
		app.editor_scroll_owner,
		host.Application_Text_Input_Event{kind=.Commit, text="X"},
	)
	second_line, second_found := editor_window_line(&view.optimistic_window, 1)
	testing.expect(t, second_found, "optimistic multi-line source should retain the second logical line")
	if second_found {
		view.selection_anchor = second_line.source_start
		view.caret_byte = second_line.source_start
		_ = editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Backspace})
	}
	joined_line, joined_found := editor_window_line(&view.optimistic_window, 0)
	testing.expect(t, joined_found, "Backspace at line start should leave the joined line available")
	if joined_found {
		view.selection_anchor = joined_line.source_end
		view.caret_byte = joined_line.source_end
		_ = editor_text_key(rawptr(&app), &rt, app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Delete})
	}
	expected_optimistic := "hello worXldsecondthird\r\nfourth"
	testing.expect(t, bridge.editor_edit_lane_is_active(&app.editor_edit_lane) && len(app.editor_edits) == 10,
		"the first request should be held in flight while later committed characters accumulate locally")
	testing.expect(t, view.optimistic_window_ready && string(view.optimistic_window.source) == expected_optimistic,
		"typing, selection replacement, and cross-line deletion should update the bounded projection before backend acknowledgement")
	testing.expect(t, view.caret_byte == 18 && view.optimistic_pending_edits == 10 &&
		view.optimistic_window.end_line == 2 && view.optimistic_line_delta == -2,
		"the replacement queue should preserve the caret and immediately reflect removed logical lines")
	other_document_id := ""
	for candidate in app.backend.state.documents {
		if candidate.id != typing_document_id { other_document_id = candidate.id; break }
	}
	other_document_id_copy, other_id_error := strings.clone(other_document_id, context.allocator)
	testing.expect(t, other_id_error == nil && other_document_id_copy != "", "the second document identity should be available for a queued tab switch")
	defer delete(other_document_id_copy, context.allocator)
	select_document(&app, &rt, other_document_id_copy)
	testing.expect(t, len(app.deferred_actions) == 1 && app.backend.state.active == typing_document_id && app.error_message == "",
		"tab selection should queue invisibly behind the edits without changing the active document or showing a wait error")
	_ = build_app(rawptr(&app), &rt, 1000, 700, 1)
	optimistic_text_rendered := false
	chrome_became_disabled := false
	for node_id in rt.order {
		if node, found := rt.nodes[node_id]; found {
			if node.key == fmt.tprintf("scratchpad-line:%s:0", document.id) {
				optimistic_text_rendered = node.text == "hello worXldsecondthird"
			}
			if node.key == "action-file-open" || node.key == "action-workspace-open" ||
			   node.key == "action-document-close" || node.key == fmt.tprintf("tab:%s", typing_document_id) ||
			   node.key == fmt.tprintf("tab-close:%s", typing_document_id) {
				chrome_became_disabled = chrome_became_disabled || node.disabled
			}
		}
	}
	testing.expect(t, optimistic_text_rendered,
		"the rebuilt Alicorn description should visibly contain all committed characters before the backend lane is released")
	testing.expect(t, !chrome_became_disabled,
		"pending editor acknowledgements must not flash the toolbar or tab controls into disabled styling")
	testing.expect(t, app.file_items[0].state.enabled && app.file_items[1].state.enabled,
		"native menu availability should remain stable while source edits are pending")
	state_while_held, state_held_ok, state_held_error := bridge.backend_read_latest(&app.backend, context.temp_allocator)
	testing.expect(t, state_held_ok && !state_while_held && app.backend.state.application_rev == base_application_revision,
		fmt.tprintf("the held worker must not mutate or publish backend state before its dispatch gate opens: %s", state_held_error))
	canonical_before_ack := bridge.backend_command(
		&app.backend,
		"read_visible_lines",
		document_id=document.id,
		start_line=0,
		max_lines=bridge.MAX_VISIBLE_LINES,
		max_bytes=bridge.MAX_VISIBLE_BYTES,
		allocator=context.temp_allocator,
	)
	testing.expect(t, canonical_before_ack.ok && string(canonical_before_ack.visible_window.source) == "hello world\r\nsecond\r\nthird\r\nfourth",
		"the authoritative document should remain unchanged while only the first local edit is queued")
	bridge.backend_command_result_destroy(&canonical_before_ack, context.temp_allocator)
	for _ in 0..<10 { sync.sema_post(&gate) }
	for _ in 0..<120 {
		if len(app.editor_edits) == 0 { break }
		_ = sync.sema_wait_with_timeout(&signal.sema, time.Duration(100_000_000))
		application_wake(rawptr(&app), &rt)
	}
	testing.expect(t, len(app.editor_edits) == 0 && len(app.deferred_actions) == 0 && view.optimistic_pending_edits == 0,
		"all delayed edits should be acknowledged serially and then drain the deferred tab selection")
	testing.expect(t, app.backend.state.active == other_document_id_copy,
		"the queued tab switch should execute after the final authoritative edit acknowledgement")
	document_after, found_after := find_document(&app.backend.state, document.id)
	testing.expect(t, found_after && document_after.editor_revision == base_editor_revision+10 && document_after.line_count == 2,
		"every replacement should converge through its own ordered revision and update authoritative line topology")
	canonical_after := bridge.backend_command(
		&app.backend,
		"read_visible_lines",
		document_id=typing_document_id,
		start_line=0,
		max_lines=bridge.MAX_VISIBLE_LINES,
		max_bytes=bridge.MAX_VISIBLE_BYTES,
		allocator=context.temp_allocator,
	)
	testing.expect(t, canonical_after.ok && canonical_after.visible_window_owned && string(canonical_after.visible_window.source) == expected_optimistic,
		"the final Caliber visible window should match the complete local replacement projection")
	bridge.backend_command_result_destroy(&canonical_after, context.temp_allocator)

	// Start a second chain, accept its first replacement, then mutate the
	// authoritative document before the next serialized request is dispatched.
	// The stale edit and all dependent local edits must be discarded together.
	select_document(&app, &rt, typing_document_id)
	document_before_stale, found_before_stale := find_document(&app.backend.state, typing_document_id)
	testing.expect(t, found_before_stale, "the source document should be active for stale-chain recovery")
	if !found_before_stale { return }
	stale_base_revision := document_before_stale.editor_revision
	view_index, view_ok = editor_view_ensure(&app.editor_views, typing_document_id)
	testing.expect(t, view_ok, "the source document should retain its local editor view across tab changes")
	if !view_ok { return }
	view = &app.editor_views[view_index]
	view.caret_byte = view.optimistic_window.start_byte+u64(len(view.optimistic_window.source))
	view.selection_anchor = view.caret_byte
	stale_chain_commits := [4]string{"a", "b", "c", "d"}
	for text in stale_chain_commits {
		editor_text_input(
			rawptr(&app),
			&rt,
			app.editor_scroll_owner,
			host.Application_Text_Input_Event{kind=.Commit, text=text},
		)
	}
	testing.expect(t, len(app.editor_edits) == 4 &&
		string(view.optimistic_window.source) == fmt.tprintf("%sabcd", expected_optimistic),
		"four rapid local edits should be visible while only the first request is in flight")
	sync.sema_post(&gate)
	for _ in 0..<120 {
		if len(app.editor_edits) == 3 && view.authoritative_revision == stale_base_revision+1 { break }
		_ = sync.sema_wait_with_timeout(&signal.sema, time.Duration(100_000_000))
		application_wake(rawptr(&app), &rt)
	}
	testing.expect(t, len(app.editor_edits) == 3 && view.authoritative_revision == stale_base_revision+1,
		"the first edit should be accepted and the dependent second edit should be the sole in-flight request")
	canonical_after_first := bridge.backend_command(
		&app.backend,
		"read_visible_lines",
		document_id=typing_document_id,
		start_line=0,
		max_lines=bridge.MAX_VISIBLE_LINES,
		max_bytes=bridge.MAX_VISIBLE_BYTES,
		allocator=context.temp_allocator,
	)
	testing.expect(t, canonical_after_first.ok && canonical_after_first.visible_window_owned &&
		string(canonical_after_first.visible_window.source) == fmt.tprintf("%sa", expected_optimistic),
		"the first replacement should be authoritative before the dependent request is challenged")
	concurrent_change_byte := canonical_after_first.visible_window.start_byte+u64(len(canonical_after_first.visible_window.source))
	bridge.backend_command_result_destroy(&canonical_after_first, context.temp_allocator)
	concurrent_change := bridge.backend_command(
		&app.backend,
		"replace_document",
		document_id=typing_document_id,
		editor_revision=view.authoritative_revision,
		start_byte=concurrent_change_byte,
		end_byte=concurrent_change_byte,
		replacement=[]int{'!'},
		allocator=context.temp_allocator,
	)
	testing.expect(t, concurrent_change.ok,
		"an external authoritative edit should advance the revision while the next serial request remains gated")
	bridge.backend_command_result_destroy(&concurrent_change, context.temp_allocator)
	testing.expect(t, view.optimistic_pending_edits == 3 && len(app.editor_edits) == 3,
		"the optimistic dependent chain should remain local until the stale response is handled")
	sync.sema_post(&gate)
	for _ in 0..<120 {
		if len(app.editor_edits) == 0 { break }
		_ = sync.sema_wait_with_timeout(&signal.sema, time.Duration(100_000_000))
		application_wake(rawptr(&app), &rt)
	}
	testing.expect(t, len(app.editor_edits) == 0 && view.optimistic_pending_edits == 0 &&
		!view.optimistic_window_ready && view.position_reconcile_pending,
		"a stale request must discard itself and every dependent optimistic edit, then invalidate the old bounded window")
	testing.expect(t, strings.contains(app.error_message, "reloading authoritative text"),
		"stale rejection should report the controlled recovery instead of silently diverging")

	// Rebuild asks the existing visible-window lane for the canonical revision.
	_ = build_app(rawptr(&app), &rt, 1000, 700, 1)
	for _ in 0..<120 {
		current_document, current_found := find_document(&app.backend.state, typing_document_id)
		if current_found && app.editor_window_ready &&
		   app.editor_window.document_id == typing_document_id &&
		   app.editor_window.editor_revision == current_document.editor_revision { break }
		_ = sync.sema_wait_with_timeout(&signal.sema, time.Duration(100_000_000))
		application_wake(rawptr(&app), &rt)
	}
	recovered_document, recovered_found := find_document(&app.backend.state, typing_document_id)
	testing.expect(t, recovered_found, "the authoritative source document should survive stale recovery")
	if !recovered_found { return }
	recovered_revision := recovered_document.editor_revision
	recovered_expected := fmt.tprintf("%sa!", expected_optimistic)
	_, caret_is_legal := editor_line_for_source(&app.editor_window, view.caret_byte)
	testing.expect(t, recovered_found && app.editor_window_ready &&
		app.editor_window.editor_revision == recovered_document.editor_revision &&
		string(app.editor_window.source) == recovered_expected,
		"the bounded window should reload the exact authoritative bytes, including the concurrent edit but excluding rejected dependents")
	testing.expect(t, !view.position_reconcile_pending &&
		view.authoritative_revision == recovered_revision &&
		view.caret_byte >= app.editor_window.start_byte &&
		view.caret_byte <= app.editor_window.start_byte+u64(len(app.editor_window.source)) &&
		caret_is_legal,
		"recovery should clamp and normalize the caret to a legal source boundary in the reloaded window")

	// The recovered editor remains usable: a new local edit should be accepted
	// against the new authoritative revision and converge normally.
	editor_text_input(
		rawptr(&app),
		&rt,
		app.editor_scroll_owner,
		host.Application_Text_Input_Event{kind=.Commit, text="z"},
	)
	testing.expect(t, len(app.editor_edits) == 1 &&
		string(view.optimistic_window.source) == fmt.tprintf("%sz", recovered_expected),
		"typing should resume immediately on the recovered authoritative projection")
	sync.sema_post(&gate)
	for _ in 0..<120 {
		if len(app.editor_edits) == 0 { break }
		_ = sync.sema_wait_with_timeout(&signal.sema, time.Duration(100_000_000))
		application_wake(rawptr(&app), &rt)
	}
	final_document, final_found := find_document(&app.backend.state, typing_document_id)
	canonical_final := bridge.backend_command(
		&app.backend,
		"read_visible_lines",
		document_id=typing_document_id,
		start_line=0,
		max_lines=bridge.MAX_VISIBLE_LINES,
		max_bytes=bridge.MAX_VISIBLE_BYTES,
		allocator=context.temp_allocator,
	)
	final_expected := fmt.tprintf("%sz", recovered_expected)
	testing.expect(t, len(app.editor_edits) == 0 && view.optimistic_pending_edits == 0 &&
		final_found && final_document.editor_revision == recovered_revision+1 &&
		view.authoritative_revision == final_document.editor_revision &&
		canonical_final.ok && canonical_final.visible_window_owned &&
		string(canonical_final.visible_window.source) == final_expected &&
		string(view.optimistic_window.source) == string(canonical_final.visible_window.source),
		"post-recovery editing should converge with no pending edits and identical optimistic/canonical bytes")
	bridge.backend_command_result_destroy(&canonical_final, context.temp_allocator)
	testing.expect(t, app.backend.state_leases == 0 && app.backend.resource_leases == 0,
		"the success and stale-recovery paths should leave no Caliber publication or resource leases outstanding")
}
