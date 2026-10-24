package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"
import bridge "./bridge"

// These fixtures open files through the staged backend; source windows and
// folding plans always come from that document, never a fabricated buffer.
Semantic_Zoom_Test_Editor :: struct {
	app: App,
	rt: alicorn.Runtime,
	workspace, document_id: string,
	locked, runtime_ready: bool,
}

semantic_zoom_test_destroy :: proc(f: ^Semantic_Zoom_Test_Editor, t: ^testing.T) {
	app := &f.app
	_ = bridge.visible_window_lane_stop(&app.visible_window_lane)
	_ = bridge.editor_edit_lane_stop(&app.editor_edit_lane)
	if app.backend.started {
		stopped, message := bridge.backend_stop(&app.backend)
		testing.expect(t, stopped, message)
	}
	editor_window_destroy(&app.editor_window)
	editor_views_destroy(&app.editor_views)
	for i := len(app.editor_edits)-1; i >= 0; i -= 1 { editor_remove_edit(app, i) }
	delete(app.editor_edits)
	delete(app.editor_row_targets)
	deferred_actions_clear(app)
	delete(app.deferred_actions)
	deferred_action_destroy(&app.frame_deferred_action)
	editor_accessibility_projection_destroy(&app.accessibility_projection)
	delete(app.accessibility_source_error)
	delete(app.accessibility_source_error_document_id)
	tree_clear_directories(app)
	delete(app.tree_directories)
	tree_clear_focused_path(app)
	delete(app.tree_root_path)
	delete(app.editor_presented_document_id)
	delete(app.editor_window_error)
	delete(app.error_message)
	editor_window_rejection_clear(app)
	if f.runtime_ready { alicorn.destroy_runtime(&f.rt) }
	delete(f.document_id)
	if f.workspace != "" { _ = os.remove_all(f.workspace); delete(f.workspace) }
	if f.locked { sync.mutex_unlock(&backend_integration_test_mutex) }
	f^ = {}
}

semantic_zoom_test_load_window :: proc(f: ^Semantic_Zoom_Test_Editor, t: ^testing.T, start_line: u64 = 0) -> bool {
	result := bridge.backend_command(&f.app.backend, "read_visible_lines", document_id=f.document_id,
		start_line=start_line, max_lines=bridge.MAX_VISIBLE_LINES, max_bytes=bridge.MAX_VISIBLE_BYTES,
		include_presentation=true, read_latest_after=false)
	defer bridge.backend_command_result_destroy(&result, context.allocator)
	if !result.ok || !result.visible_window_owned {
		testing.expect(t, false, fmt.tprintf("the real source window must be available: line=%d message=%s", start_line, result.message)); return false
	}
	window, ok, message := editor_window_from_visible(&result.visible_window)
	testing.expect(t, ok, message)
	if !ok { return false }
	editor_window_destroy(&f.app.editor_window)
	f.app.editor_window, f.app.editor_window_ready = window, true
	return true
}

semantic_zoom_test_wait_ready :: proc(f: ^Semantic_Zoom_Test_Editor, t: ^testing.T, document_id: string = "") -> bool {
	id := document_id if document_id != "" else f.document_id
	wait_started := time.tick_now()
	for time.tick_since(wait_started) < 5*time.Second {
		_, ok, message := bridge.backend_consume_wake(&f.app.backend)
		if !ok { testing.expect(t, false, message); return false }
		document, exists := find_document(&f.app.backend.state, id)
		if exists && document.presentation_ready && document.presentation_revision == document.editor_revision { return true }
		time.sleep(time.Millisecond)
	}
	testing.expect(t, false, "the real Markdown/Go projection must become current")
	return false
}

semantic_zoom_test_open :: proc(f: ^Semantic_Zoom_Test_Editor, t: ^testing.T, extension, source: string) -> bool {
	sync.mutex_lock(&backend_integration_test_mutex)
	f.locked = true
	workspace, err := os.make_directory_temp("", "scratchpad-semantic-zoom-*", context.allocator)
	if err != nil { testing.expect(t, false, "semantic zoom needs a temporary workspace"); return false }
	f.workspace = workspace
	path := fmt.tprintf("%s/source.%s", workspace, extension)
	if os.write_entire_file_from_string(path, source) != nil {
		testing.expect(t, false, "semantic zoom fixture should be written"); return false
	}
	library, found := os.lookup_env("SCRATCHPAD_BACKEND_LIBRARY", context.temp_allocator)
	if !found { testing.expect(t, false, "semantic zoom requires the rebuilt staged backend"); return false }
	defer delete(library, context.temp_allocator)
	loaded, load_message := bridge.backend_load(&f.app.backend, library)
	if !loaded { testing.expect(t, false, load_message); return false }
	started, start_message := bridge.backend_start(&f.app.backend, workspace, tree_test_wake, nil)
	if !started { testing.expect(t, false, start_message); return false }
	opened := bridge.backend_command(&f.app.backend, "open_path", path=path)
	open_ok := opened.ok
	bridge.backend_command_result_destroy(&opened, context.allocator)
	if !open_ok { testing.expect(t, false, "the staged backend must open the source fixture"); return false }
	f.document_id, _ = strings.clone(f.app.backend.state.active)
	if !semantic_zoom_test_load_window(f, t) { return false }
	// Opting into presentation starts the real derived-projection coordinator.
	if !semantic_zoom_test_wait_ready(f, t) { return false }
	document, exists := find_document(&f.app.backend.state, f.document_id)
	if !exists || document.instance_id == 0 {
		testing.expect(t, false, "semantic zoom integration requires the rebuilt backend publishing document instance IDs"); return false
	}
	if !semantic_zoom_test_load_window(f, t) { return false }
	f.app.editor_views = make([dynamic]Editor_View_State, 0)
	f.app.editor_row_targets = make([dynamic]Editor_Row_Target, 0)
	f.app.editor_edits = make([dynamic]Editor_Edit_Intent, 0)
	f.rt = alicorn.new_runtime(alicorn.Rect{0, 0, 800, 180})
	f.runtime_ready = true
	if !alicorn.text_engine_load_font(&f.rt.text_engine, ALICORN_TEST_UI_FONT_DATA) ||
	   !alicorn.text_engine_load_font_role(&f.rt.text_engine, .Monospace, ALICORN_TEST_MONO_FONT_DATA) {
		testing.expect(t, false, "source geometry must use the bundled shaped fonts"); return false
	}
	for _ in 0..<8 { editor_paste_test_frame(&f.app, &f.rt) }
	return true
}

semantic_zoom_test_view :: proc(f: ^Semantic_Zoom_Test_Editor) -> ^Editor_View_State {
	i := editor_view_find(f.app.editor_views[:], f.document_id)
	return &f.app.editor_views[i] if i >= 0 else nil
}

semantic_zoom_test_settle :: proc(f: ^Semantic_Zoom_Test_Editor) {
	for _ in 0..<8 { editor_paste_test_frame(&f.app, &f.rt) }
}

semantic_zoom_test_source :: proc(extension: string) -> string {
	source := make([dynamic]u8, 0, allocator=context.temp_allocator)
	if extension == "go" { append(&source, "package demo\n\n") }
	for section in 0..<24 {
		if extension == "md" {
			append(&source, fmt.tprintf("# Section %d\n\nOpening %d.\n", section, section))
			for detail in 0..<6 {
				append(&source, fmt.tprintf("detail %d/%d café 日本語: This is deliberately wrapped prose with enough source text to occupy several visual rows while preserving its original byte coordinates. More prose keeps the source anchor well inside the wrapped line.\n", section, detail))
			}
			append(&source, "\n")
		} else {
			append(&source, fmt.tprintf("// Section%d documents real Go source.\nfunc Section%d() ", section, section))
			append(&source, "{\n")
			for detail in 0..<6 { append(&source, fmt.tprintf("\tprintln(\"detail %d/%d café 日本語\")\n", section, detail)) }
			append(&source, "}\n\n")
		}
	}
	return string(source[:])
}

semantic_zoom_test_hidden :: proc(view: ^Editor_View_State, source: u64) -> bool {
	for entry in view.zoom.rows.folds {
		if source >= entry.fold.start_byte && source < entry.fold.end_byte { return !entry.expanded }
	}
	return false
}

semantic_zoom_test_line_at_source :: proc(view: ^Editor_View_State, source: u64) -> (text: string, logical_line: u64, ok: bool) {
	if view == nil { return }
	for &window in view.zoom.windows {
		if line, found := editor_line_for_source(&window, source); found { return line.display, line.logical_line, true }
	}
	return
}

// Read the byte's actual shaped screen position, independently of the zoom
// height index and saved anchor. Hidden bytes deliberately have no source node.
semantic_zoom_test_position :: proc(f: ^Semantic_Zoom_Test_Editor, source: u64) -> (rect, viewport: alicorn.Rect, ok: bool) {
	view := semantic_zoom_test_view(f)
	for target in f.app.editor_row_targets {
		window := &f.app.editor_window
		if semantic_zoom_active(view) { window = semantic_zoom_find_window(view, target.logical_line) }
		line, found := editor_window_line(window, target.logical_line)
		if !found || source < line.source_start || source > line.source_end { continue }
		geometry := alicorn.text_node_caret_geometry(&f.rt, target.node,
			alicorn.Text_Position{byte=editor_source_to_display(line, source), affinity=view.caret_affinity})
		owner, owner_found := alicorn.node_info(&f.rt, f.app.editor_scroll_owner)
		return geometry.rect, owner.scroll_viewport_bounds, geometry.valid && owner_found
	}
	return
}

semantic_zoom_test_unchanged :: proc(f: ^Semantic_Zoom_Test_Editor, t: ^testing.T, source: string, revision: u64, dirty: bool, document_id: string = "") {
	id := document_id if document_id != "" else f.document_id
	document, found := find_document(&f.app.backend.state, id)
	testing.expect(t, found && document.editor_revision == revision && document.dirty == dirty &&
		document.byte_length == u64(len(source)) && (document.view_density == "" || document.view_density == "full"),
		"zoom must preserve source revision, dirty state, byte length and the editable source view")
	// Compare every authoritative byte, even for a fixture spanning many windows.
	at, line := 0, u64(0)
	for at < len(source) {
		result := bridge.backend_command(&f.app.backend, "read_visible_lines", document_id=id,
			start_line=line, max_lines=bridge.MAX_VISIBLE_LINES, max_bytes=bridge.MAX_VISIBLE_BYTES, read_latest_after=false)
		if !result.ok || !result.visible_window_owned {
			testing.expect(t, false, "canonical source must remain readable after zoom")
			bridge.backend_command_result_destroy(&result, context.allocator); return
		}
		window := result.visible_window
		end := at+len(window.source)
		same := window.start_byte == u64(at) && end <= len(source) && end > at
		if same { same = string(window.source) == source[at:end] }
		testing.expect(t, same, "semantic detail changes must preserve every original source byte")
		line, at = window.end_line, end
		bridge.backend_command_result_destroy(&result, context.allocator)
		if !same { return }
	}
}

semantic_zoom_test_roundtrip :: proc(t: ^testing.T, extension: string) {
	source := semantic_zoom_test_source(extension)
	f: Semantic_Zoom_Test_Editor
	defer semantic_zoom_test_destroy(&f, t)
	if !semantic_zoom_test_open(&f, t, extension, source) { return }
	view := semantic_zoom_test_view(&f)
	if view == nil { testing.expect(t, false, "source editor should retain its view"); return }
	document, _ := find_document(&f.app.backend.state, f.document_id)
	revision, dirty := document.editor_revision, document.dirty
	anchor_at := strings.index(source, "detail 12/3")
	anchor_at += 150 if extension == "md" else 7
	anchor := u64(anchor_at)
	selection := u64(strings.index(source, "detail 11/2")+7)
	caret := u64(strings.index(source, "detail 11/3")+7)
	if extension == "go" { selection, caret = caret, selection }
	view.selection_anchor, view.caret_byte = selection, caret
	view.anchor_affinity, view.caret_affinity = .Leading, .Trailing
	line, found := editor_line_for_source(&f.app.editor_window, anchor)
	if !found { testing.expect(t, false, "the source anchor must begin in a real loaded line"); return }
	// Put the byte, including its wrapped-line interior, 48px into the viewport.
	run, shaped := editor_navigation_text_run(&f.rt, &f.app.editor_window, line, document.language,
		view.wrap_measurement_width, true, view.wrap_mode, editor_text_scale_effective(&f.app))
	if !shaped { testing.expect(t, false, "the original source anchor should shape"); return }
	geometry := alicorn.text_run_caret_geometry(&run,
		alicorn.Text_Position{byte=editor_source_to_display(line, anchor), affinity=.Trailing}, context.temp_allocator)
	local_y := geometry.rect.y
	alicorn.text_run_destroy(&run)
	_ = alicorn.scroll_region_set_offset(&f.rt, f.app.editor_scroll_owner,
		alicorn.virtual_list_height_index_item_top(&view.wrap_height_index, int(line.logical_line))+local_y-48,
		"place a real source byte inside a scrolled viewport")
	semantic_zoom_test_settle(&f)
	before := alicorn.scroll_region_state(&f.rt, f.app.editor_scroll_owner)
	before_rect, before_viewport, before_ok := semantic_zoom_test_position(&f, anchor)
	testing.expect(t, before.offset_y > 500 && before_ok && before_rect.y >= before_viewport.y &&
		before_rect.y+before_rect.h <= before_viewport.y+before_viewport.h,
		"round trips must start at a visible byte in a nonzero source viewport")
	if !before_ok { return }
	if extension == "md" { testing.expect(t, local_y > 0, "the Markdown anchor must exercise the interior of a wrapped line") }

	// Exercise direct round trips and the full gesture loop. The source anchor
	// itself disappears in Skim/Overview; the separate caret is hidden in Focus.
	depths := [?]int{1, 0, 2, 0, 3, 0, 1, 2, 3, 2, 1, 0}
	for depth in depths {
		if !semantic_zoom_set_depth(&f.app, &f.rt, depth, anchor) {
			testing.expect(t, false, "real source must accept the semantic detail transition"); return
		}
		semantic_zoom_test_settle(&f)
		testing.expect(t, view.zoom.depth == depth && view.zoom.anchor_byte == anchor &&
			view.selection_anchor == selection && view.caret_byte == caret &&
			view.anchor_affinity == .Leading && view.caret_affinity == .Trailing,
			"folding must retain the exact byte anchor and both directional selection endpoints")
		if depth > 0 {
			testing.expect(t, semantic_zoom_active(view) && semantic_zoom_test_hidden(view, caret),
				fmt.tprintf("this regression must actually hide the caret: language=%s depth=%d caret=%d anchor=%d", extension, depth, caret, anchor))
			if depth >= 2 { testing.expect(t, semantic_zoom_test_hidden(view, anchor), fmt.tprintf("Skim/Overview must hide the original viewport byte: language=%s depth=%d", extension, depth)) }
		} else {
			after_rect, viewport, ok := semantic_zoom_test_position(&f, anchor)
			after := alicorn.scroll_region_state(&f.rt, f.app.editor_scroll_owner)
			testing.expect(t, ok && abs((after_rect.y-viewport.y)-(before_rect.y-before_viewport.y)) <= 4 &&
				abs(after.offset_y-before.offset_y) <= 4,
				fmt.tprintf("Full must restore the same shaped byte near its original screen position: language=%s before=%v after=%v screen_before=%v screen_after=%v valid=%v", extension, before.offset_y, after.offset_y, before_rect.y-before_viewport.y, after_rect.y-viewport.y, ok))
		}
		for id in f.rt.order {
			node := f.rt.nodes[id]
			testing.expect(t, !strings.has_prefix(node.key, "document-density-") && node.label != "scratchpad-semantic-view-controls",
				"the source editor must not show the old document-density button toolbar")
		}
		semantic_zoom_test_unchanged(&f, t, source, revision, dirty)
	}
}

@(test)
test_semantic_zoom_markdown_hidden_anchor_and_selection_roundtrip :: proc(t: ^testing.T) {
	semantic_zoom_test_roundtrip(t, "md")
}

@(test)
test_semantic_zoom_go_hidden_anchor_and_selection_roundtrip :: proc(t: ^testing.T) {
	semantic_zoom_test_roundtrip(t, "go")
}

@(test)
test_semantic_zoom_distant_source_rows_and_fold_expansion_stay_in_place :: proc(t: ^testing.T) {
	source_bytes := make([dynamic]u8, 0, allocator=context.temp_allocator)
	defer delete(source_bytes)
	append(&source_bytes, "# Near\n\nOpening near.\n")
	for i in 0..<340 { append(&source_bytes, fmt.tprintf("Hidden detail %d café.\n", i)) }
	append(&source_bytes, "\n# Far\n\nOpening far.\nFar detail.\n\n# Tail\n\nTail detail.\n")
	source := string(source_bytes[:])
	f: Semantic_Zoom_Test_Editor
	defer semantic_zoom_test_destroy(&f, t)
	if !semantic_zoom_test_open(&f, t, "md", source) { return }
	view := semantic_zoom_test_view(&f)
	if view == nil { testing.expect(t, false); return }
	document, _ := find_document(&f.app.backend.state, f.document_id)
	revision, dirty := document.editor_revision, document.dirty
	if !semantic_zoom_set_depth(&f.app, &f.rt, 3, 0) { testing.expect(t, false); return }
	semantic_zoom_test_settle(&f)
	near := u64(strings.index(source, "# Near"))
	far := u64(strings.index(source, "# Far"))
	near_rect, viewport, near_ok := semantic_zoom_test_position(&f, near)
	far_rect, _, far_ok := semantic_zoom_test_position(&f, far)
	testing.expect(t, near_ok && far_ok && near_rect.y >= viewport.y && far_rect.y+far_rect.h <= viewport.y+viewport.h,
		"source rows on both sides of a fold larger than a normal window must render together")
	testing.expect(t, f.app.editor_window.start_byte+u64(len(f.app.editor_window.source)) < far,
		"the far heading must be outside the real base window so a stale contiguous buffer cannot satisfy this test")
	near_text, far_text := false, false
	for target in f.app.editor_row_targets {
		node := f.rt.nodes[target.node]
		near_text = near_text || strings.contains(node.text, "Near")
		far_text = far_text || strings.contains(node.text, "Far")
	}
	testing.expect(t, near_text && far_text && len(view.zoom.windows) >= 2 && len(view.zoom.windows) <= 64,
		"both distant source labels must have real bounded backing windows")
	for window in view.zoom.windows {
		testing.expect(t, window.document_id == f.document_id && window.editor_revision == revision &&
			window.end_line-window.start_line <= 8 && len(window.source) <= 16*1024,
			"folded rendering must retain only bounded, revision-matched source windows")
	}
	if len(view.zoom.rows.folds) == 0 { testing.expect(t, false, "Overview must expose a clickable fold"); return }
	fold := view.zoom.rows.folds[0].fold
	testing.expect(t, fold.end_line-fold.start_line > bridge.MAX_VISIBLE_LINES,
		"the clicked fold must really span more than a base source window")
	marker_y, marker_found := f32(0), false
	for id in f.rt.order {
		node := f.rt.nodes[id]
		if node.kind == .Button && strings.contains(node.label, "expand") {
			marker_y, marker_found = node.bounds.y, true; break
		}
	}
	testing.expect(t, marker_found, "hidden source must have a visible expansion action")
	if !marker_found { return }
	// semantic_zoom_toggle_fold is the production action behind the disclosure button.
	semantic_zoom_toggle_fold(&f.app, &f.rt, f.document_id, revision+1, fold.start_line)
	testing.expect(t, semantic_zoom_test_hidden(view, fold.start_byte), "a stale fold action must not expand a different source revision")
	semantic_zoom_toggle_fold(&f.app, &f.rt, f.document_id, revision, fold.start_line)
	semantic_zoom_test_settle(&f)
	revealed, revealed_found, body_found := f32(0), false, false
	for target in f.app.editor_row_targets {
		body_found = body_found || strings.contains(f.rt.nodes[target.node].text, "Opening near.")
		if target.logical_line == fold.start_line {
			node, exists := alicorn.node_info(&f.rt, target.node)
			revealed, revealed_found = node.bounds.y, exists
		}
	}
	testing.expect(t, view.zoom.depth == 3 && !semantic_zoom_test_hidden(view, fold.start_byte) && body_found && revealed_found && abs(revealed-marker_y) < 2,
		"expanding a fold must reveal its original source at the marker's screen position without returning the document to Full")
	view.caret_byte, view.selection_anchor = fold.start_byte+2, fold.start_byte
	view.caret_affinity, view.anchor_affinity = .Leading, .Leading
	semantic_zoom_toggle_fold(&f.app, &f.rt, f.document_id, revision, fold.start_line)
	semantic_zoom_test_settle(&f)
	testing.expect(t, view.zoom.depth == 3 && semantic_zoom_test_hidden(view, fold.start_byte) &&
		view.caret_byte == fold.start_byte && view.selection_anchor == fold.start_byte,
		"collapsing a region under the caret returns focus to its disclosure boundary without changing global detail")
	if editor_text_key(rawptr(&f.app), &f.rt, f.app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Down}) {
		semantic_zoom_test_settle(&f)
		_, line_number, line_found := semantic_zoom_test_line_at_source(view, view.caret_byte)
		testing.expect(t, line_found && view.zoom.depth == 3 && !semantic_zoom_rows_hidden(&view.zoom.rows, int(line_number)),
			"Down from a collapsed disclosure continues through visible rows without opening Full source")
	} else {
		testing.expect(t, false, "Down from a collapsed disclosure is handled in reduced detail")
	}
	semantic_zoom_test_unchanged(&f, t, source, revision, dirty)
}

@(test)
test_semantic_zoom_keyboard_navigation_and_word_selection_stay_at_current_depth :: proc(t: ^testing.T) {
	source := semantic_zoom_test_source("go")
	f: Semantic_Zoom_Test_Editor
	defer semantic_zoom_test_destroy(&f, t)
	if !semantic_zoom_test_open(&f, t, "go", source) { return }
	view := semantic_zoom_test_view(&f)
	if !semantic_zoom_set_depth(&f.app, &f.rt, 3, 0) { testing.expect(t, false); return }
	semantic_zoom_test_settle(&f)
	word := u64(strings.index(source, "func Section0")+len("func "))
	rect, _, positioned := semantic_zoom_test_position(&f, word)
	testing.expect(t, positioned, "the function name must have source-aligned geometry in Overview")
	if !positioned { return }
	editor_pointer(rawptr(&f.app), &f.rt, alicorn.Pointer_Event{kind=.Down, button=1, click_count=2, x=rect.x+0.1, y=rect.y+rect.h*0.5}, f.app.editor_scroll_owner)
	start, end := min(view.selection_anchor, view.caret_byte), max(view.selection_anchor, view.caret_byte)
	testing.expect(t, view.zoom.depth == 3 && source[int(start):int(end)] == "Section0",
		"double-click selects the visible source word without leaving semantic zoom")
	editor_pointer(rawptr(&f.app), &f.rt, alicorn.Pointer_Event{kind=.Up, button=1, x=rect.x, y=rect.y}, 0)

	word_end := word+u64(len("Section0"))
	view.selection_anchor, view.caret_byte = word, word_end
	view.anchor_affinity, view.caret_affinity = .Leading, .Trailing
	right_collapse := editor_text_key(rawptr(&f.app), &f.rt, f.app.editor_scroll_owner,
		host.Application_Text_Key_Event{key=.Right})
	testing.expect(t, right_collapse && view.selection_anchor == word_end && view.caret_byte == word_end,
		"Right collapses a forward selection to its right edge even when the caret is already there")
	view.selection_anchor, view.caret_byte = word_end, word
	view.anchor_affinity, view.caret_affinity = .Trailing, .Leading
	left_collapse := editor_text_key(rawptr(&f.app), &f.rt, f.app.editor_scroll_owner,
		host.Application_Text_Key_Event{key=.Left})
	testing.expect(t, left_collapse && view.selection_anchor == word && view.caret_byte == word,
		"Left collapses a reverse selection to its left edge even when the caret is already there")

	end_rect, _, end_positioned := semantic_zoom_test_position(&f, word_end)
	testing.expect(t, end_positioned, "the word end must remain a source-aligned pointer target")
	if end_positioned {
		drag_down := alicorn.Pointer_Event{kind=.Down, button=1, click_count=1, x=rect.x+0.1, y=rect.y+rect.h*0.5}
		drag_target := alicorn.process_pointer(&f.rt, drag_down)
		editor_pointer(rawptr(&f.app), &f.rt, drag_down, drag_target)
		drag_move := alicorn.Pointer_Event{kind=.Move, x=end_rect.x+0.1, y=end_rect.y+end_rect.h*0.5}
		drag_move_target := alicorn.process_pointer(&f.rt, drag_move)
		editor_pointer(rawptr(&f.app), &f.rt, drag_move, drag_move_target)
		drag_start, drag_end := min(view.selection_anchor, view.caret_byte), max(view.selection_anchor, view.caret_byte)
		testing.expect(t, view.zoom.depth == 3 && drag_start == word && drag_end == word_end,
			"drag selection tracks the exact visible source span while preserving semantic zoom")
		drag_up := alicorn.Pointer_Event{kind=.Up, button=1, x=end_rect.x, y=end_rect.y}
		_ = alicorn.process_pointer(&f.rt, drag_up)
		editor_pointer(rawptr(&f.app), &f.rt, drag_up, 0)
	}

	second_word := u64(strings.index(source, "func Section1")+len("func "))
	second_rect, _, second_positioned := semantic_zoom_test_position(&f, second_word)
	testing.expect(t, second_positioned, "the next visible function name must have source-aligned pointer geometry")
	if second_positioned {
		reset := alicorn.Pointer_Event{kind=.Down, button=1, click_count=1, x=rect.x+0.1, y=rect.y+rect.h*0.5}
		reset_target := alicorn.process_pointer(&f.rt, reset)
		editor_pointer(rawptr(&f.app), &f.rt, reset, reset_target)
		_ = alicorn.process_pointer(&f.rt, alicorn.Pointer_Event{kind=.Up, button=1, x=rect.x, y=rect.y})
		before_anchor, before_caret := view.selection_anchor, view.caret_byte
		shift_click := alicorn.Pointer_Event{kind=.Down, button=1, click_count=1,
			x=second_rect.x+0.1, y=second_rect.y+second_rect.h*0.5, modifiers=alicorn.Input_Modifiers{shift=true}}
		shift_target := alicorn.process_pointer(&f.rt, shift_click)
		editor_pointer(rawptr(&f.app), &f.rt, shift_click, shift_target)
		testing.expect(t, view.zoom.depth == 3 && view.selection_anchor == before_anchor && view.caret_byte == before_caret,
			"Shift-click refuses to create a selection that silently crosses a collapsed fold")
		_ = alicorn.process_pointer(&f.rt, alicorn.Pointer_Event{kind=.Up, button=1, x=second_rect.x, y=second_rect.y})
		editor_pointer(rawptr(&f.app), &f.rt, alicorn.Pointer_Event{kind=.Up, button=1}, 0)
	}

	want_line := "func Section1()"
	found_next := false
	for _ in 0..<16 {
		text, logical_line, line_found := semantic_zoom_test_line_at_source(view, view.caret_byte)
		if line_found && strings.contains(text, want_line) {
			found_next = true
			break
		}
		handled := editor_text_key(rawptr(&f.app), &f.rt, f.app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Down})
		if !handled { break }
		semantic_zoom_test_settle(&f)
		text, logical_line, line_found = semantic_zoom_test_line_at_source(view, view.caret_byte)
		testing.expect(t, view.zoom.depth == 3 && line_found && !semantic_zoom_rows_hidden(&view.zoom.rows, int(logical_line)),
			"each arrow destination is a visible source row at the existing detail level")
	}
	testing.expect(t, found_next,
		"Down navigates across the collapsed body to the next visible function signature")
	document, found := find_document(&f.app.backend.state, f.document_id)
	testing.expect(t, found && semantic_zoom_plan_matches(view, document) && view.zoom.plan.depth == 3,
		"caret navigation reuses the same revision-matched semantic plan")
	if editor_text_key(rawptr(&f.app), &f.rt, f.app.editor_scroll_owner, host.Application_Text_Key_Event{key=.Up}) {
		semantic_zoom_test_settle(&f)
		testing.expect(t, view.zoom.depth == 3, "Up also preserves the semantic detail level")
	} else {
		testing.expect(t, false, "Up is handled inside the reduced source view")
	}
}

@(test)
test_semantic_zoom_copy_uses_distant_revision_matched_window_and_refuses_hidden_bytes :: proc(t: ^testing.T) {
	source_bytes := make([dynamic]u8, 0, allocator=context.temp_allocator)
	defer delete(source_bytes)
	append(&source_bytes, "package demo\n")
	for index in 0..<140 {
		append(&source_bytes, fmt.tprintf("func Section%d() {\n\tprintln(\"detail %d\")\n}\n", index, index))
	}
	source := string(source_bytes[:])
	f: Semantic_Zoom_Test_Editor
	defer semantic_zoom_test_destroy(&f, t)
	if !semantic_zoom_test_open(&f, t, "go", source) { return }
	view := semantic_zoom_test_view(&f)
	if view == nil { testing.expect(t, false, "semantic zoom should retain editor state"); return }
	document, exists := find_document(&f.app.backend.state, f.document_id)
	if !exists { testing.expect(t, false, "the source document should remain active"); return }
	target_index := strings.index(source, "func Section130")
	name_start := target_index+len("func ")
	next_function := strings.index(source, "func Section131")
	testing.expect(t, target_index >= 0 && next_function > target_index &&
		u64(name_start) > f.app.editor_window.start_byte+u64(len(f.app.editor_window.source)),
		"the selected function must be beyond the ordinary bounded source window")
	if target_index < 0 || next_function <= target_index { return }
	if !semantic_zoom_set_depth(&f.app, &f.rt, 3, u64(name_start)) { testing.expect(t, false, "semantic zoom should open at the distant function"); return }
	semantic_zoom_test_settle(&f)
	document, exists = find_document(&f.app.backend.state, f.document_id)
	if !exists { testing.expect(t, false, "the source document should remain active after zoom"); return }
	fallback_window := semantic_zoom_source_window_at_byte(&f.app, view, document, u64(name_start))
	testing.expect(t, fallback_window != nil && fallback_window.editor_revision == document.editor_revision,
		"a distant visible fold header should resolve to a bounded source window by byte")
	// Pointer hit testing loads bounded source windows by logical row before it
	// updates the selection. Derive this row from the parser's fold boundary so
	// the fixture follows the backend's source-line mapping.
	target_line: u64
	target_line_found := false
	for entry in view.zoom.rows.folds {
		if u64(name_start) < entry.fold.start_byte {
			target_line = entry.fold.start_line
			if target_line > 0 { target_line -= 1 }
			target_line_found = true
			break
		}
		if u64(name_start) < entry.fold.end_byte {
			target_line, target_line_found = entry.fold.start_line, true
			break
		}
	}
	testing.expect(t, target_line_found, "the distant selected function should map to a semantic source row")
	if !target_line_found { return }
	zoom_window := semantic_zoom_source_window(&f.app, view, document, target_line)
	testing.expect(t, zoom_window != nil && zoom_window.editor_revision == document.editor_revision,
		fmt.tprintf("semantic zoom should retain a current bounded window for the distant visible function (line=%d, document lines=%d, plan matches=%t, folds=%d)",
			target_line, document.line_count, semantic_zoom_plan_matches(view, document), len(view.zoom.rows.folds)))
	if zoom_window == nil { return }

	clipboard := Editor_Test_Clipboard{write_ok=true}
	f.app.services.clipboard = host.Clipboard_Service{
		data=rawptr(&clipboard),
		set_text=editor_test_clipboard_set_text,
	}
	defer {
		if len(clipboard.last_write) > 0 { delete(clipboard.last_write, context.temp_allocator) }
	}

	name_end := name_start+len("Section130")
	copy_window := semantic_zoom_source_window_at_byte(&f.app, view, document, u64(name_start))
	testing.expect(t, copy_window != nil && copy_window.document_id == document.id &&
		copy_window.editor_revision == document.editor_revision &&
		u64(name_end) <= copy_window.start_byte+u64(len(copy_window.source)),
		"Copy must use an exact bounded window from the selected document revision")
	if copy_window == nil { return }
	view.selection_anchor, view.caret_byte = u64(name_start), u64(name_end)
	view.anchor_affinity, view.caret_affinity = .Leading, .Trailing
	editor_clipboard_command(&f.app, &f.rt, ACTION_EDIT_COPY)
	testing.expect(t, clipboard.writes == 1 && clipboard.last_write == "Section130" && view.zoom.depth == 3,
		"Copy should read the distant selected function name without leaving semantic zoom")

	hidden_end: u64
	hidden_found := false
	for entry in view.zoom.rows.folds {
		if !entry.expanded && entry.fold.start_byte > u64(name_start) && entry.fold.end_byte <= u64(next_function) {
			hidden_end, hidden_found = entry.fold.end_byte, true
			break
		}
	}
	testing.expect(t, hidden_found, "the target function should have a collapsed body for the hidden-source check")
	if hidden_found {
		view.selection_anchor, view.caret_byte = u64(name_start), hidden_end
		writes_before := clipboard.writes
		editor_clipboard_command(&f.app, &f.rt, ACTION_EDIT_COPY)
		testing.expect(t, clipboard.writes == writes_before &&
			strings.contains(f.app.error_message, "Expand collapsed content"),
			"Copy must refuse ranges that would silently include hidden folded source")
	}
}

@(test)
test_semantic_zoom_reveals_original_bytes_before_input_and_refuses_unfinished_input :: proc(t: ^testing.T) {
	source := semantic_zoom_test_source("go")
	f: Semantic_Zoom_Test_Editor
	defer semantic_zoom_test_destroy(&f, t)
	if !semantic_zoom_test_open(&f, t, "go", source) { return }
	view := semantic_zoom_test_view(&f)
	if view == nil { testing.expect(t, false); return }
	document, _ := find_document(&f.app.backend.state, f.document_id)
	revision := document.editor_revision
	start := u64(strings.index(source, "detail 12/3"))
	end := start+u64(len("detail 12/3"))
	view.selection_anchor, view.caret_byte = end, start
	editor_text_input(rawptr(&f.app), &f.rt, f.app.editor_scroll_owner,
		host.Application_Text_Input_Event{kind=.Preedit, text="日本", selection_end_byte=6})
	testing.expect(t, view.preedit_active && !semantic_zoom_set_depth(&f.app, &f.rt, 2, start) && view.zoom.depth == 0 &&
		string(view.preedit_text) == "日本" && view.selection_anchor == end && view.caret_byte == start,
		"zoom must refuse an active composition without losing its text or original selection")
	editor_preedit_clear(view)
	testing.expect(t, editor_preedit_make_recoverable(view, "kept commit", start, end), "recoverable composition should retain committed input")
	testing.expect(t, !semantic_zoom_set_depth(&f.app, &f.rt, 3, start) && view.zoom.depth == 0 && string(view.preedit_text) == "kept commit",
		"zoom must also refuse committed input awaiting recovery")
	editor_preedit_clear(view)
	semantic_zoom_test_unchanged(&f, t, source, revision, false)
	if !semantic_zoom_set_depth(&f.app, &f.rt, 3, start) { testing.expect(t, false); return }
	semantic_zoom_test_settle(&f)
	testing.expect(t, semantic_zoom_test_hidden(view, start), "the edit must begin with its target hidden behind a fold")
	// Move the real base window away too: reveal must fetch the original bytes
	// before applying input, rather than editing the fold label or a nearby row.
	if !semantic_zoom_test_load_window(&f, t, 220) { return }
	_, loaded := editor_line_for_source(&f.app.editor_window, start)
	testing.expect(t, !loaded, "input reveal must exercise a missing canonical source window")
	signal: Editor_Edit_Test_Signal
	gate: sync.Sema
	if !bridge.editor_edit_lane_start(&f.app.editor_edit_lane, &f.app.backend, editor_edit_test_wake, rawptr(&signal), context.allocator, &gate) {
		testing.expect(t, false, "the real edit worker must start"); return
	}
	defer { for _ in 0..<4 { sync.sema_post(&gate) }; _ = bridge.editor_edit_lane_stop(&f.app.editor_edit_lane) }
	replacement := "changed 日本"
	editor_text_input(rawptr(&f.app), &f.rt, f.app.editor_scroll_owner,
		host.Application_Text_Input_Event{kind=.Commit, text=replacement})
	testing.expect(t, view.zoom.depth == 0 && len(f.app.editor_edits) == 1 &&
		view.caret_byte == start+u64(len(replacement)) && view.selection_anchor == view.caret_byte,
		"typing into a folded selection must reveal source and replace its original byte range")
	testing.expect(t, !semantic_zoom_set_depth(&f.app, &f.rt, 1, start) && view.zoom.depth == 0 && len(f.app.editor_edits) == 1,
		"zoom must refuse a real edit awaiting its backend acknowledgement")
	sync.sema_post(&gate)
	testing.expect(t, editor_flush_pending_edits(&f.app), "the real backend must acknowledge the revealed edit")
	expected := fmt.tprintf("%s%s%s", source[:int(start)], replacement, source[int(end):])
	semantic_zoom_test_unchanged(&f, t, expected, revision+1, true)
	semantic_zoom_test_settle(&f)
	testing.expect(t, view.zoom.depth == 0, "parser completion after typing must not fold the editor again")
	if !semantic_zoom_test_wait_ready(&f, t) { return }
	semantic_zoom_test_settle(&f)
	testing.expect(t, view.zoom.depth == 0, "an exact parser publication must leave the edited source unfolded")
	for depth in ([?]int{2, 0}) {
		testing.expect(t, semantic_zoom_set_depth(&f.app, &f.rt, depth, start), "an acknowledged edit must allow explicit semantic zoom again")
		semantic_zoom_test_settle(&f)
		semantic_zoom_test_unchanged(&f, t, expected, revision+1, true)
	}
}

semantic_zoom_test_wheel :: proc(f: ^Semantic_Zoom_Test_Editor, delta: f32, modifiers: alicorn.Input_Modifiers, target: alicorn.Node_ID = 0) -> bool {
	owner := target if target != 0 else f.app.editor_scroll_owner
	return semantic_zoom_scroll_capture(rawptr(&f.app), &f.rt,
		alicorn.Scroll_Event{delta_y=delta, x=-10, y=-10, modifiers=modifiers}, owner)
}

semantic_zoom_test_new_gesture :: proc(view: ^Editor_View_State) {
	// Expire the prior gesture deterministically, without sleeping in a test.
	view.zoom.wheel_at = time.tick_add(time.tick_now(), -time.Second)
}

@(test)
test_semantic_zoom_wheel_scope_modifiers_fractional_steps_and_inertia :: proc(t: ^testing.T) {
	f: Semantic_Zoom_Test_Editor
	defer semantic_zoom_test_destroy(&f, t)
	if !semantic_zoom_test_open(&f, t, "md", semantic_zoom_test_source("md")) { return }
	view := semantic_zoom_test_view(&f)
	if view == nil { testing.expect(t, false); return }
	f.app.semantic_zoom_wheel = .Primary_Alt
	primary := alicorn.Input_Modifiers{control=true, alt=true}
	wrong_primary := alicorn.Input_Modifiers{super=true, alt=true}
	when ODIN_OS == .Darwin {
		primary = alicorn.Input_Modifiers{super=true, alt=true}
		wrong_primary = alicorn.Input_Modifiers{control=true, alt=true}
	}
	pointer_tested := false
	owner, _ := alicorn.node_info(&f.rt, f.app.editor_scroll_owner)
	for target in f.app.editor_row_targets {
		node, exists := alicorn.node_info(&f.rt, target.node)
		if !exists || target.logical_line == 0 || len(f.rt.nodes[target.node].text) == 0 ||
		   node.bounds.y < owner.scroll_viewport_bounds.y || node.bounds.y+node.bounds.h > owner.scroll_viewport_bounds.y+owner.scroll_viewport_bounds.h { continue }
		x, y := node.bounds.x+12, node.bounds.y+node.bounds.h*0.5
		expected, _, hit := editor_source_at_pointer(&f.app, &f.rt, x, y)
		if !hit { continue }
		caret := view.caret_byte
		captured := semantic_zoom_scroll_capture(rawptr(&f.app), &f.rt,
			alicorn.Scroll_Event{delta_y=-1, x=x, y=y, modifiers=primary}, f.app.editor_scroll_owner)
		testing.expect(t, captured && expected != caret && view.zoom.depth == 1 && view.zoom.anchor_byte == expected && view.caret_byte == caret,
			"wheel zoom must anchor the byte under the pointer while preserving the separate source caret")
		pointer_tested = true
		break
	}
	testing.expect(t, pointer_tested, "wheel fixture must hit a visible source byte away from its caret")
	_ = semantic_zoom_set_depth(&f.app, &f.rt, 0, view.zoom.anchor_byte)
	semantic_zoom_test_settle(&f)
	testing.expect(t, !semantic_zoom_test_wheel(&f, -2, primary, f.app.editor_scroll_owner+1) && view.zoom.depth == 0,
		"semantic wheel capture must leave scrolling outside the source editor alone")
	wrong := [?]alicorn.Input_Modifiers{{}, {alt=true}, wrong_primary,
		{control=primary.control, super=primary.super}, {control=primary.control, super=primary.super, alt=true, shift=true}}
	for modifiers in wrong {
		semantic_zoom_test_new_gesture(view)
		testing.expect(t, !semantic_zoom_test_wheel(&f, -2, modifiers) && view.zoom.depth == 0,
			"only the configured platform primary+Alt chord may start semantic zoom")
	}
	f.app.command_palette_open = true
	testing.expect(t, !semantic_zoom_test_wheel(&f, -2, primary), "an open command palette must keep wheel input out of the editor")
	f.app.command_palette_open = false
	f.app.settings_surface_open = true
	testing.expect(t, !semantic_zoom_test_wheel(&f, -2, primary), "settings must keep wheel input out of the editor")
	f.app.settings_surface_open = false
	semantic_zoom_test_new_gesture(view)
	testing.expect(t, !semantic_zoom_test_wheel(&f, -0.25, {}) && !semantic_zoom_test_wheel(&f, -2, primary) && view.zoom.depth == 0,
		"adding modifiers during ordinary scroll inertia must not turn that gesture into semantic zoom")
	semantic_zoom_test_new_gesture(view)
	for delta in ([?]f32{-0.4, -0.35}) {
		testing.expect(t, semantic_zoom_test_wheel(&f, delta, primary) && view.zoom.depth == 0,
			"precise fractional wheel input must accumulate without an early detail change")
	}
	testing.expect(t, semantic_zoom_test_wheel(&f, -0.3, primary) && view.zoom.depth == 1,
		"fractional wheel deltas crossing one step must lower detail exactly once")
	testing.expect(t, semantic_zoom_test_wheel(&f, -2, {}) && view.zoom.depth == 1,
		"releasing the zoom modifiers must consume its inertia without scrolling or another zoom step")
	testing.expect(t, semantic_zoom_test_wheel(&f, -0.4, primary) && view.zoom.depth == 1 &&
		semantic_zoom_test_wheel(&f, -0.6, primary) && view.zoom.depth == 2,
		"resuming modifiers in a latched zoom gesture must start a fresh fractional step")
	testing.expect(t, semantic_zoom_test_wheel(&f, 1, primary) && view.zoom.depth == 1,
		"the opposite wheel direction must restore more source detail")
	testing.expect(t, !semantic_zoom_scroll_capture(rawptr(&f.app), &f.rt,
		alicorn.Scroll_Event{delta_x=2, modifiers=primary}, f.app.editor_scroll_owner),
		"horizontal-only wheel input must remain available to source scrolling")
	f.app.semantic_zoom_wheel = .Primary_Shift
	shift := primary
	shift.alt, shift.shift = false, true
	testing.expect(t, semantic_zoom_test_wheel(&f, -1, shift) && view.zoom.depth == 2,
		"changing the setting must allow platform primary+Shift to start a new zoom gesture")
	f.app.semantic_zoom_wheel = .Disabled
	testing.expect(t, !semantic_zoom_test_wheel(&f, -2, primary) && view.zoom.depth == 2,
		"disabled semantic wheel zoom must pass the gesture through")
}

@(test)
test_semantic_zoom_settled_source_is_truly_idle :: proc(t: ^testing.T) {
	f: Semantic_Zoom_Test_Editor
	defer semantic_zoom_test_destroy(&f, t)
	if !semantic_zoom_test_open(&f, t, "md", semantic_zoom_test_source("md")) { return }
	if !semantic_zoom_set_depth(&f.app, &f.rt, 2, 0) { testing.expect(t, false); return }
	semantic_zoom_test_settle(&f)
	builds, shapes, commands := f.rt.stats.frames_built, f.rt.text_engine.shape_calls, f.app.backend.request_id
	for _ in 0..<12 {
		ui, build := alicorn.begin_frame(&f.rt)
		testing.expect(t, !build, "a settled folded editor must not schedule another root description")
		if build { alicorn.end_frame(&ui); return }
	}
	testing.expect(t, f.rt.stats.frames_built == builds && f.rt.text_engine.shape_calls == shapes && f.app.backend.request_id == commands,
		"true idle must perform zero editor builds, text shaping or backend zoom/window queries")
}

@(test)
test_semantic_zoom_destroy_releases_real_plans_source_windows_and_geometry :: proc(t: ^testing.T) {
	f: Semantic_Zoom_Test_Editor
	defer semantic_zoom_test_destroy(&f, t)
	if !semantic_zoom_test_open(&f, t, "go", semantic_zoom_test_source("go")) { return }
	view := semantic_zoom_test_view(&f)
	if view == nil { testing.expect(t, false); return }
	backing := context.allocator
	tracking: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracking, backing)
	context.allocator = mem.tracking_allocator(&tracking)
	defer {
		semantic_zoom_destroy(&view.zoom)
		context.allocator = backing
		testing.expect(t, len(tracking.allocation_map) == 0 && tracking.current_memory_allocated == 0 && len(tracking.bad_free_array) == 0,
			"destroying semantic zoom must free its backend plans, labels, row map, geometry and bounded source windows exactly once")
		mem.tracking_allocator_destroy(&tracking)
	}
	for depth in ([?]int{1, 2, 3, 1}) {
		if !semantic_zoom_set_depth(&f.app, &f.rt, depth, 0) { testing.expect(t, false); return }
		document, _ := find_document(&f.app.backend.state, f.document_id)
		for line in ([?]u64{0, 120, 220}) {
			testing.expect(t, semantic_zoom_source_window(&f.app, view, document, line) != nil,
				fmt.tprintf("allocation coverage must own real source windows on both sides of folded code: line=%d document_lines=%d", line, document.line_count))
		}
		semantic_zoom_sync_geometry(view, &f.app.editor_window, 1)
		testing.expect(t, tracking.current_memory_allocated > 0, "cleanup regression must actually allocate retained zoom state")
	}
}

semantic_zoom_test_disk_source :: proc(t: ^testing.T, path, expected: string) {
	bytes, err := os.read_entire_file(path, context.allocator)
	defer delete(bytes)
	testing.expect(t, err == nil && string(bytes) == expected,
		"the saved file must contain every authoritative source byte, including folded text and Unicode")
}

@(test)
test_semantic_zoom_save_preserves_detail_and_undo_redo_restore_source_history :: proc(t: ^testing.T) {
	source := semantic_zoom_test_source("go")
	f: Semantic_Zoom_Test_Editor
	defer semantic_zoom_test_destroy(&f, t)
	if !semantic_zoom_test_open(&f, t, "go", source) { return }
	view := semantic_zoom_test_view(&f)
	if view == nil { testing.expect(t, false); return }
	document, _ := find_document(&f.app.backend.state, f.document_id)
	revision := document.editor_revision
	instance := document.instance_id
	start := u64(strings.index(source, "detail 12/3"))
	end := start+u64(len("detail 12/3"))
	view.selection_anchor, view.caret_byte = end, start
	testing.expect(t, alicorn.focus(&f.rt, f.app.editor_scroll_owner), "the source editor must own the real history commands")
	signal: Editor_Edit_Test_Signal
	if !bridge.editor_edit_lane_start(&f.app.editor_edit_lane, &f.app.backend, editor_edit_test_wake, rawptr(&signal)) {
		testing.expect(t, false, "history fixture needs the real frontend edit worker"); return
	}
	replacement := "saved change 日本"
	editor_text_input(rawptr(&f.app), &f.rt, f.app.editor_scroll_owner,
		host.Application_Text_Input_Event{kind=.Commit, text=replacement})
	if !editor_flush_pending_edits(&f.app) { testing.expect(t, false, "the frontend edit must be acknowledged before saving"); return }
	expected := fmt.tprintf("%s%s%s", source[:int(start)], replacement, source[int(end):])
	after_caret := start+u64(len(replacement))
	semantic_zoom_test_unchanged(&f, t, expected, revision+1, true)
	if !semantic_zoom_test_wait_ready(&f, t) { return }
	semantic_zoom_test_settle(&f)
	if !semantic_zoom_set_depth(&f.app, &f.rt, 2, start) { testing.expect(t, false); return }
	semantic_zoom_test_settle(&f)
	testing.expect(t, semantic_zoom_active(view) && semantic_zoom_test_hidden(view, start),
		"Save must run while the edited source itself is hidden in Skim")
	anchor_before := view.zoom.anchor_byte
	scroll_before := alicorn.scroll_region_state(&f.rt, f.app.editor_scroll_owner)
	testing.expect(t, action_enabled(&f.app.backend.state, ACTION_FILE_SAVE), "the dirty document must expose its real Save action")
	application_menu_command(rawptr(&f.app), &f.rt, action_id_for(ACTION_FILE_SAVE))
	semantic_zoom_test_settle(&f)
	testing.expect(t, f.app.error_message == "" && f.app.backend.state.active == f.document_id &&
		view.zoom.depth == 2 && semantic_zoom_active(view) && view.zoom.anchor_byte == anchor_before &&
		view.selection_anchor == after_caret && view.caret_byte == after_caret &&
		abs(alicorn.scroll_region_state(&f.rt, f.app.editor_scroll_owner).offset_y-scroll_before.offset_y) < 2,
		"frontend Save must retain the document, current detail, source anchor, selection and folded viewport")
	semantic_zoom_test_unchanged(&f, t, expected, revision+1, false)
	path := fmt.tprintf("%s/source.go", f.workspace)
	semantic_zoom_test_disk_source(t, path, expected)

	// Zooming and saving must not insert history entries. One Undo must restore
	// the original directional selection and source, away from the saved revision.
	if !semantic_zoom_set_depth(&f.app, &f.rt, 3, start) { testing.expect(t, false); return }
	semantic_zoom_test_settle(&f)
	testing.expect(t, action_enabled(&f.app.backend.state, ACTION_EDIT_UNDO), "the real source edit must remain undoable while zoomed")
	application_menu_command(rawptr(&f.app), &f.rt, action_id_for(ACTION_EDIT_UNDO))
	testing.expect(t, f.app.backend.state.active == f.document_id && view.zoom.depth == 0 &&
		view.selection_anchor == end && view.caret_byte == start &&
		!action_enabled(&f.app.backend.state, ACTION_EDIT_UNDO) && action_enabled(&f.app.backend.state, ACTION_EDIT_REDO),
		"Undo from Overview must reveal Full and restore this document's pre-edit selection and sole history entry")
	semantic_zoom_test_unchanged(&f, t, source, revision, true)
	semantic_zoom_test_disk_source(t, path, expected)
	if !semantic_zoom_test_wait_ready(&f, t) || !semantic_zoom_test_load_window(&f, t) { return }
	semantic_zoom_test_settle(&f)
	if !semantic_zoom_set_depth(&f.app, &f.rt, 1, start) { testing.expect(t, false); return }
	semantic_zoom_test_settle(&f)
	testing.expect(t, semantic_zoom_active(view), "Redo must also start from a real reduced source view")
	application_menu_command(rawptr(&f.app), &f.rt, action_id_for(ACTION_EDIT_REDO))
	testing.expect(t, f.app.backend.state.active == f.document_id && view.zoom.depth == 0 &&
		view.selection_anchor == after_caret && view.caret_byte == after_caret &&
		action_enabled(&f.app.backend.state, ACTION_EDIT_UNDO) && !action_enabled(&f.app.backend.state, ACTION_EDIT_REDO),
		"Redo from Focus must reveal Full and restore the same edited bytes and post-edit caret")
	semantic_zoom_test_unchanged(&f, t, expected, revision+1, false)
	semantic_zoom_test_disk_source(t, path, expected)
	if !semantic_zoom_test_wait_ready(&f, t) || !semantic_zoom_test_load_window(&f, t) { return }
	semantic_zoom_test_settle(&f)
	current, found := find_document(&f.app.backend.state, f.document_id)
	testing.expect(t, found && current.instance_id == instance && view.zoom.depth == 0,
		"settled history publications must keep the same document instance and restored source in Full")
}

semantic_zoom_test_floating_frame :: proc(window: ^Floating_Window_State, rt: ^alicorn.Runtime) -> bool {
	app, scope := floating_editor_scope_enter(window, rt)
	if app == nil { return false }
	defer floating_editor_scope_leave(window, app, &scope)
	editor_paste_test_frame(app, rt)
	return true
}

@(test)
test_semantic_zoom_detached_window_keeps_document_and_wheel_gestures_scoped :: proc(t: ^testing.T) {
	primary_source := semantic_zoom_test_source("md")
	child_source := semantic_zoom_test_source("go")
	f: Semantic_Zoom_Test_Editor
	defer semantic_zoom_test_destroy(&f, t)
	if !semantic_zoom_test_open(&f, t, "md", primary_source) { return }
	child_path := fmt.tprintf("%s/detached.go", f.workspace)
	if os.write_entire_file_from_string(child_path, child_source) != nil { testing.expect(t, false); return }
	opened := bridge.backend_command(&f.app.backend, "open_path", path=child_path)
	open_ok := opened.ok
	bridge.backend_command_result_destroy(&opened, context.allocator)
	if !open_ok { testing.expect(t, false, "a second real backend document must open"); return }
	child_id, _ := strings.clone(f.app.backend.state.active)
	defer delete(child_id)
	testing.expect(t, child_id != f.document_id && len(f.app.backend.state.documents) == 2,
		"detached scope must exercise two independent real documents")
	child_rt := alicorn.new_runtime(alicorn.Rect{0, 0, 800, 180})
	defer alicorn.destroy_runtime(&child_rt)
	if !alicorn.text_engine_load_font(&child_rt.text_engine, ALICORN_TEST_UI_FONT_DATA) ||
	   !alicorn.text_engine_load_font_role(&child_rt.text_engine, .Monospace, ALICORN_TEST_MONO_FONT_DATA) {
		testing.expect(t, false, "detached source must use the same real bundled fonts"); return
	}
	// Exercise the production detached-window scope without asking the native
	// host to create a window. Its source slice still comes from the real backend.
	window := new(Floating_Window_State)
	window.owner, window.runtime = &f.app, &child_rt
	window.document_id, _ = strings.clone(child_id)
	f.app.floating_window = window
	defer { f.app.floating_window = nil; floating_window_state_destroy(window) }
	for pass in 0..<2 {
		visible := bridge.backend_command(&f.app.backend, "read_visible_lines", document_id=child_id,
			max_lines=bridge.MAX_VISIBLE_LINES, max_bytes=bridge.MAX_VISIBLE_BYTES, include_presentation=true, read_latest_after=false)
		if !visible.ok || !visible.visible_window_owned {
			testing.expect(t, false, "detached source must have a real bounded window")
			bridge.backend_command_result_destroy(&visible, context.allocator); return
		}
		fresh, ok, message := editor_window_from_visible(&visible.visible_window)
		bridge.backend_command_result_destroy(&visible, context.allocator)
		if !ok { testing.expect(t, false, message); return }
		editor_window_destroy(&window.editor_window)
		window.editor_window, window.editor_window_ready = fresh, true
		if pass == 0 && !semantic_zoom_test_wait_ready(&f, t, child_id) { return }
	}
	select_document(&f.app, &f.rt, f.document_id)
	semantic_zoom_test_settle(&f)
	for _ in 0..<8 { testing.expect(t, semantic_zoom_test_floating_frame(window, &child_rt), "the second runtime must render through its floating scope") }
	primary_view := semantic_zoom_test_view(&f)
	child_index := editor_view_find(f.app.editor_views[:], child_id)
	if primary_view == nil || child_index < 0 { testing.expect(t, false, "each document must retain a source view"); return }
	child_view := &f.app.editor_views[child_index]
	primary_caret := u64(strings.index(primary_source, "detail 10/3")+7)
	primary_view.selection_anchor, primary_view.caret_byte = primary_caret-3, primary_caret
	child_caret := u64(strings.index(child_source, "detail 8/2")+7)
	child_view.selection_anchor, child_view.caret_byte = child_caret+3, child_caret
	if !semantic_zoom_set_depth(&f.app, &f.rt, 2, primary_caret) { testing.expect(t, false); return }
	semantic_zoom_test_settle(&f)
	primary_owner := f.app.editor_scroll_owner
	primary_scroll := alicorn.scroll_region_state(&f.rt, primary_owner)
	primary_builds := f.rt.stats.frames_built
	primary_anchor := primary_view.zoom.anchor_byte
	primary_document, _ := find_document(&f.app.backend.state, f.document_id)
	child_document, _ := find_document(&f.app.backend.state, child_id)
	primary_revision, child_revision := primary_document.editor_revision, child_document.editor_revision
	testing.expect(t, primary_document.instance_id != 0 && child_document.instance_id != 0 && primary_document.instance_id != child_document.instance_id,
		"the two windows must have distinct backend document instances")
	f.app.semantic_zoom_wheel = .Primary_Alt
	modifiers := alicorn.Input_Modifiers{control=true, alt=true}
	when ODIN_OS == .Darwin { modifiers = alicorn.Input_Modifiers{super=true, alt=true} }
	testing.expect(t, semantic_zoom_test_wheel(&f, -0.4, modifiers) && primary_view.zoom.depth == 2,
		"the primary window must retain an incomplete wheel step before detached input")
	event := alicorn.Scroll_Event{delta_y=-0.6, x=-10, y=-10, modifiers=modifiers}
	testing.expect(t, floating_window_scroll_capture(rawptr(window), &child_rt, event, window.editor_scroll_owner) && child_view.zoom.depth == 0,
		"detached wheel input must not combine with the primary document's fractional gesture")
	if len(window.editor_row_targets) == 0 { testing.expect(t, false, "detached source must have real rendered input targets"); return }
	testing.expect(t, !floating_window_scroll_capture(rawptr(window), &child_rt, event, window.editor_row_targets[0].node),
		"detached capture must reject a target outside its own scroll region")
	event.delta_y = -0.4
	testing.expect(t, floating_window_scroll_capture(rawptr(window), &child_rt, event, window.editor_scroll_owner) && child_view.zoom.depth == 1,
		"the detached document's own fractional gesture must lower only its source detail")
	for _ in 0..<8 { testing.expect(t, semantic_zoom_test_floating_frame(window, &child_rt)) }
	testing.expect(t, f.app.backend.state.active == f.document_id && f.app.editor_scroll_owner == primary_owner &&
		f.app.editor_window.document_id == f.document_id && window.editor_window.document_id == child_id &&
		primary_view.zoom.depth == 2 && primary_view.zoom.anchor_byte == primary_anchor &&
		primary_view.selection_anchor == primary_caret-3 && primary_view.caret_byte == primary_caret &&
		abs(alicorn.scroll_region_state(&f.rt, primary_owner).offset_y-primary_scroll.offset_y) < 0.5 && f.rt.stats.frames_built == primary_builds,
		"leaving detached callbacks must preserve the primary document, source window, selection, anchor and rendered viewport")
	testing.expect(t, semantic_zoom_active(child_view) && child_view.zoom.plan.document_id == child_id &&
		child_view.zoom.plan.instance_id == child_document.instance_id &&
		child_view.zoom.anchor_byte == child_caret && child_view.selection_anchor == child_caret+3 && child_view.caret_byte == child_caret,
		"the second runtime must render its own zoom plan without changing its directional source selection")
	// Rendering time is not a user pause between device events. Keep the final
	// interleaved event inside the same gesture even on a slow test machine.
	primary_view.zoom.wheel_at = time.tick_now()
	testing.expect(t, semantic_zoom_test_wheel(&f, -0.6, modifiers) && primary_view.zoom.depth == 3 && child_view.zoom.depth == 1,
		"returning to the primary window must finish its original fractional step without zooming the detached document")
	semantic_zoom_test_unchanged(&f, t, primary_source, primary_revision, false)
	semantic_zoom_test_unchanged(&f, t, child_source, child_revision, false, child_id)
}
