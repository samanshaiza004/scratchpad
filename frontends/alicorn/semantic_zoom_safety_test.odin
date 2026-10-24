package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"
import bridge "./bridge"

// These regressions share Arendt's real-document/runtime fixtures. No source
// plan, projection, or editor source page is fabricated by the safety tests.
semantic_zoom_safety_current_document :: proc(f: ^Semantic_Zoom_Test_Editor, t: ^testing.T) -> (document: bridge.State_Document, ok: bool) {
	document, ok = find_document(&f.app.backend.state, f.document_id)
	ok = ok && document.instance_id != 0
	testing.expect(t, ok, "safety tests require the rebuilt staged backend publishing nonzero document instance_id")
	return
}

semantic_zoom_safety_distant_source :: proc() -> string {
	bytes := make([dynamic]u8, 0, allocator=context.temp_allocator)
	append(&bytes, "# Near\n\nNear opening.\n")
	for i in 0..<340 { append(&bytes, fmt.tprintf("Near hidden detail %d.\n", i)) }
	append(&bytes, "\n# Far\n\nFar opening.\n")
	for i in 0..<80 { append(&bytes, fmt.tprintf("Far hidden detail %d.\n", i)) }
	append(&bytes, "\n# Tail\n\nTail opening.\nTail hidden detail.\n")
	return string(bytes[:])
}

semantic_zoom_safety_click :: proc(f: ^Semantic_Zoom_Test_Editor, t: ^testing.T, source: u64) -> bool {
	rect, viewport, ok := semantic_zoom_test_position(f, source)
	ok = ok && rect.y >= viewport.y && rect.y+rect.h <= viewport.y+viewport.h
	testing.expect(t, ok, "the requested real source byte must have a visible shaped caret")
	if !ok { return false }
	editor_pointer(rawptr(&f.app), &f.rt,
		alicorn.Pointer_Event{kind=.Down, button=1, x=rect.x+0.1, y=rect.y+rect.h*0.5}, f.app.editor_scroll_owner)
	view := semantic_zoom_test_view(f)
	testing.expect(t, view.caret_byte == source && view.selection_anchor == source,
		"the production pointer callback must retain the exact clicked source byte")
	return view.caret_byte == source && view.selection_anchor == source
}

@(test)
test_semantic_zoom_safety_table_cell_hit_and_preedit_use_exact_source_bytes :: proc(t: ^testing.T) {
	source := "# Table\n\n| Left header with enough words to force independent wrapping in this narrow table cell | café 日本 target with enough words to force independent wrapping in this second cell |\n| --- | --- |\n| left body | right body |\n\n# Hidden\n\nOpening.\nHidden detail.\n\n# Tail\n\nTail detail.\n"
	f: Semantic_Zoom_Test_Editor
	defer semantic_zoom_test_destroy(&f, t)
	if !semantic_zoom_test_open(&f, t, "md", source) { return }
	_, current := semantic_zoom_safety_current_document(&f, t)
	if !current { return }
	view := semantic_zoom_test_view(&f)
	view.wrap_mode = .On
	if !semantic_zoom_set_depth(&f.app, &f.rt, 1, 0) { testing.expect(t, false, "Focus must preserve the real table section"); return }
	semantic_zoom_test_settle(&f)
	testing.expect(t, semantic_zoom_active(view), "another section must remain folded while the table is editable")
	expected := u64(strings.index(source, "日本"))
	found_cell := false
	for target in f.app.editor_row_targets {
		if !target.is_cell || target.cell_index != 1 || expected < target.cell_start || expected >= target.cell_end { continue }
		found_cell = true
		node, present := f.rt.nodes[target.node]
		at := strings.index(node.text, "日本")
		testing.expect(t, present && at >= 0 && alicorn.text_node_line_count(&f.rt, target.node) > 1,
			"the fixture must exercise a separately shaped, wrapped second table cell")
		if !present || at < 0 { return }
		geometry := alicorn.text_node_caret_geometry(&f.rt, target.node,
			alicorn.Text_Position{byte=at, affinity=.Leading})
		testing.expect(t, geometry.valid, "the literal Japanese token must have shaped cell geometry")
		if !geometry.valid { return }
		x, y := geometry.rect.x+0.1, geometry.rect.y+geometry.rect.h*0.5
		hit, _, hit_ok := semantic_zoom_pointer_source(&f.app, &f.rt, view, x, y)
		testing.expect(t, hit_ok && hit == expected,
			fmt.tprintf("cell-local hit must map to the literal source token: got=%d want=%d", hit, expected))
		editor_pointer(rawptr(&f.app), &f.rt, alicorn.Pointer_Event{kind=.Down, button=1, x=x, y=y}, f.app.editor_scroll_owner)
		testing.expect(t, view.selection_anchor == expected && view.caret_byte == expected,
			"clicking the second cell must not select a pipe or bytes in the first cell")
		editor_text_input(rawptr(&f.app), &f.rt, f.app.editor_scroll_owner,
			host.Application_Text_Input_Event{kind=.Preedit, text="入力", selection_end_byte=6})
		testing.expect(t, view.zoom.depth == 0 && view.preedit_active && view.preedit_replace_start == expected && view.preedit_replace_end == expected,
			"IME must reveal Full source and start composition at the exact clicked cell byte")
		break
	}
	testing.expect(t, found_cell, "the rendered source table must expose its second cell target")
}

@(test)
test_semantic_zoom_safety_stale_revision_pointer_then_ime_in_same_pump :: proc(t: ^testing.T) {
	source := semantic_zoom_safety_distant_source()
	f: Semantic_Zoom_Test_Editor
	defer semantic_zoom_test_destroy(&f, t)
	if !semantic_zoom_test_open(&f, t, "md", source) { return }
	document, current := semantic_zoom_safety_current_document(&f, t)
	if !current { return }
	view := semantic_zoom_test_view(&f)
	if !semantic_zoom_set_depth(&f.app, &f.rt, 3, 0) { testing.expect(t, false); return }
	semantic_zoom_test_settle(&f)
	far := u64(strings.index(source, "# Far"))+2
	rect, _, visible := semantic_zoom_test_position(&f, far)
	testing.expect(t, visible && len(view.zoom.windows) > 1, "the stale pointer must target a retained distant source page")
	if !visible { return }
	before_anchor, before_caret := view.selection_anchor, view.caret_byte
	before_plan_revision := view.zoom.plan.revision
	prefix := [?]int{'#', ' ', 'N', 'e', 'w', '\n', '\n'}
	replaced := bridge.backend_command(&f.app.backend, "replace_document", document_id=f.document_id,
		editor_revision=document.editor_revision, start_byte=0, end_byte=0, replacement=prefix[:])
	testing.expect(t, replaced.ok, replaced.message)
	edit_ok := replaced.ok
	bridge.backend_command_result_destroy(&replaced, context.allocator)
	if !edit_ok { return }
	document, _ = find_document(&f.app.backend.state, f.document_id)
	testing.expect(t, document.editor_revision != before_plan_revision && view.zoom.plan.revision == before_plan_revision,
		"state adoption must advance the real source while the retained folded tree still describes the old revision")
	// Deliberately no frame/prepare between publication adoption and these
	// callbacks: this is the ordering possible within one native event pump.
	x, y := rect.x+0.1, rect.y+rect.h*0.5
	_, _, hit_ok := semantic_zoom_pointer_source(&f.app, &f.rt, view, x, y)
	testing.expect(t, !hit_ok, "a retained old-revision source page must lose pointer authority immediately")
	editor_pointer(rawptr(&f.app), &f.rt, alicorn.Pointer_Event{kind=.Down, button=1, x=x, y=y}, f.app.editor_scroll_owner)
	testing.expect(t, view.selection_anchor == before_anchor && view.caret_byte == before_caret,
		"the production pointer callback must not adopt stale source offsets before the next frame")
	editor_text_input(rawptr(&f.app), &f.rt, f.app.editor_scroll_owner,
		host.Application_Text_Input_Event{kind=.Preedit, text="日本", selection_end_byte=6})
	testing.expect(t, view.zoom.depth == 0 && !view.zoom.owned && len(view.zoom.windows) == 0 && view.preedit_active &&
		view.preedit_replace_start == min(document.anchor_byte, document.cursor_byte) &&
		view.preedit_replace_end == max(document.anchor_byte, document.cursor_byte),
		"same-pump IME must discard stale folds/pages and use the newly published authoritative selection")
}

@(test)
test_semantic_zoom_safety_idle_optimistic_window_yields_to_revealed_input :: proc(t: ^testing.T) {
	source := semantic_zoom_safety_distant_source()
	f: Semantic_Zoom_Test_Editor
	defer semantic_zoom_test_destroy(&f, t)
	if !semantic_zoom_test_open(&f, t, "md", source) { return }
	document, current := semantic_zoom_safety_current_document(&f, t)
	if !current { return }
	view := semantic_zoom_test_view(&f)
	prefix := [?]int{' '}
	replaced := bridge.backend_command(&f.app.backend, "replace_document", document_id=f.document_id,
		editor_revision=document.editor_revision, start_byte=0, end_byte=0, replacement=prefix[:])
	edit_ok := replaced.ok
	testing.expect(t, edit_ok, replaced.message)
	bridge.backend_command_result_destroy(&replaced, context.allocator)
	if !edit_ok { return }
	document, _ = find_document(&f.app.backend.state, f.document_id)
	// Reproduce an acknowledged optimistic projection ahead of the base lane
	// using actual current bytes from the backend, leaving the old base intact.
	result := bridge.backend_command(&f.app.backend, "read_visible_lines", document_id=f.document_id,
		start_line=0, max_lines=bridge.MAX_VISIBLE_LINES, max_bytes=bridge.MAX_VISIBLE_BYTES,
		include_presentation=true, read_latest_after=false)
	if !result.ok || !result.visible_window_owned {
		testing.expect(t, false, "the acknowledged source window must be readable")
		bridge.backend_command_result_destroy(&result, context.allocator); return
	}
	optimistic, converted, message := editor_window_from_visible(&result.visible_window)
	bridge.backend_command_result_destroy(&result, context.allocator)
	testing.expect(t, converted, message)
	if !converted { return }
	view.optimistic_window, view.optimistic_window_ready = optimistic, true
	view.optimistic_pending_edits, view.authoritative_revision = 0, document.editor_revision
	testing.expect(t, f.app.editor_window.editor_revision != document.editor_revision && view.optimistic_window.editor_revision == document.editor_revision,
		"the idle optimistic page must be ahead of the ordinary app source page")
	if !semantic_zoom_test_wait_ready(&f, t) { return }
	if !semantic_zoom_set_depth(&f.app, &f.rt, 3, 0) { testing.expect(t, false); return }
	semantic_zoom_test_settle(&f)
	far := u64(strings.index(source, "# Far"))+3 // one inserted byte, then '# '
	if !semantic_zoom_safety_click(&f, t, far) { return }
	_, loaded := editor_line_for_source(&view.optimistic_window, far)
	testing.expect(t, !loaded && view.optimistic_window_ready, "the distant caret must be outside the idle optimistic page")
	signal: Editor_Edit_Test_Signal
	gate: sync.Sema
	if !bridge.editor_edit_lane_start(&f.app.editor_edit_lane, &f.app.backend, editor_edit_test_wake, rawptr(&signal), context.allocator, &gate) {
		testing.expect(t, false, "the actual edit lane must start"); return
	}
	defer { for _ in 0..<4 { sync.sema_post(&gate) }; _ = bridge.editor_edit_lane_stop(&f.app.editor_edit_lane) }
	editor_text_input(rawptr(&f.app), &f.rt, f.app.editor_scroll_owner,
		host.Application_Text_Input_Event{kind=.Commit, text="X"})
	testing.expect(t, view.zoom.depth == 0 && !view.preedit_recoverable && len(f.app.editor_edits) == 1 &&
		view.caret_byte == far+1 && view.selection_anchor == far+1,
		"the first committed character must edit the newly revealed page instead of entering recovery behind an idle optimistic page")
	if len(f.app.editor_edits) != 1 { return }
	sync.sema_post(&gate)
	testing.expect(t, editor_flush_pending_edits(&f.app), "the revealed edit must be accepted by the real backend")
	current_source := fmt.tprintf(" %s", source)
	expected := fmt.tprintf("%sX%s", current_source[:int(far)], current_source[int(far):])
	semantic_zoom_test_unchanged(&f, t, expected, document.editor_revision+1, true)
}

@(test)
test_semantic_zoom_safety_distant_expansion_finishes_anchor_and_allows_scroll :: proc(t: ^testing.T) {
	source := semantic_zoom_safety_distant_source()
	f: Semantic_Zoom_Test_Editor
	defer semantic_zoom_test_destroy(&f, t)
	if !semantic_zoom_test_open(&f, t, "md", source) { return }
	document, current := semantic_zoom_safety_current_document(&f, t)
	if !current { return }
	view := semantic_zoom_test_view(&f)
	if !semantic_zoom_set_depth(&f.app, &f.rt, 3, 0) { testing.expect(t, false); return }
	semantic_zoom_test_settle(&f)
	far := u64(strings.index(source, "# Far"))
	far_line: u64
	for entry in view.zoom.rows.folds {
		if entry.fold.start_byte > far { far_line = entry.fold.start_line; break }
	}
	testing.expect(t, far_line >= f.app.editor_window.end_line && len(view.zoom.rows.folds) > 1,
		"the expanded fold must be outside the base page while another section remains collapsed")
	if far_line < f.app.editor_window.end_line { return }
	semantic_zoom_toggle_fold(&f.app, &f.rt, f.document_id, document.editor_revision, far_line)
	semantic_zoom_test_settle(&f)
	testing.expect(t, semantic_zoom_active(view) && !view.zoom.anchor_pending,
		"an expanded distant source page must resolve and clear its pending anchor")
	testing.expect(t, far_line >= f.app.editor_window.end_line,
		"anchor resolution must use a semantic page without relying on replacement of the base window")
	scroll := alicorn.scroll_region_state(&f.rt, f.app.editor_scroll_owner)
	requested := scroll.offset_y+44
	testing.expect(t, requested < scroll.max_scroll_y, "the expanded body must provide room for an unclamped scroll")
	testing.expect(t, alicorn.scroll_region_set_offset(&f.rt, f.app.editor_scroll_owner, requested, "safety regression scroll after distant expansion"),
		"the user scroll must move the retained source viewport")
	semantic_zoom_test_settle(&f)
	after := alicorn.scroll_region_state(&f.rt, f.app.editor_scroll_owner)
	testing.expect(t, !view.zoom.anchor_pending && abs(after.offset_y-requested) < 1,
		"subsequent rebuilds must preserve the user's new scroll rather than reapplying the expansion anchor")
}

// Quarantine freed blocks until fixture teardown, poisoning every byte on free.
// A borrowed pending string is therefore deterministic bad text, not a flaky
// access to reclaimed heap memory. Resizes also quarantine their old block.
Semantic_Zoom_Safety_Block :: struct { bytes: []u8, alignment: int, live: bool }
Semantic_Zoom_Safety_Poison :: struct {
	backing: mem.Allocator,
	blocks: [dynamic]Semantic_Zoom_Safety_Block,
	frees: int,
}

semantic_zoom_safety_poison_free :: proc(state: ^Semantic_Zoom_Safety_Poison, pointer: rawptr) -> bool {
	if pointer == nil { return true }
	for &block in state.blocks {
		if raw_data(block.bytes) != pointer || !block.live { continue }
		for &byte in block.bytes { byte = 0xdd }
		block.live = false
		state.frees += 1
		return true
	}
	return false
}

semantic_zoom_safety_poison_proc :: proc(data: rawptr, mode: mem.Allocator_Mode, size, alignment: int,
	old_memory: rawptr, old_size: int, loc := #caller_location) -> (result: []u8, err: mem.Allocator_Error) {
	state := cast(^Semantic_Zoom_Safety_Poison)data
	#partial switch mode {
	case .Free:
		if semantic_zoom_safety_poison_free(state, old_memory) { return nil, .None }
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		if size > 0 {
			allocation_mode := mem.Allocator_Mode.Alloc
			if mode == .Alloc_Non_Zeroed || mode == .Resize_Non_Zeroed { allocation_mode = .Alloc_Non_Zeroed }
			result, err = state.backing.procedure(state.backing.data, allocation_mode, size, alignment, nil, 0, loc)
			if err != .None { return }
			if old_memory != nil && (mode == .Resize || mode == .Resize_Non_Zeroed) {
				mem.copy(raw_data(result), old_memory, min(size, old_size))
			}
			append(&state.blocks, Semantic_Zoom_Safety_Block{result, alignment, true})
		}
		if old_memory != nil && (mode == .Resize || mode == .Resize_Non_Zeroed) {
			if !semantic_zoom_safety_poison_free(state, old_memory) {
				_, _ = state.backing.procedure(state.backing.data, .Free, 0, alignment, old_memory, old_size, loc)
			}
		}
		return
	}
	return state.backing.procedure(state.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

semantic_zoom_safety_tall_frame :: proc(f: ^Semantic_Zoom_Test_Editor, t: ^testing.T, verify: bool) -> int {
	alicorn.invalidate_root(&f.rt, "safety regression for source pages surviving pending reconciliation")
	ui, build := alicorn.begin_frame(&f.rt)
	if !build { testing.expect(t, false, "the tall source fixture must build"); return 0 }
	clear(&f.app.editor_row_targets)
	alicorn.container_begin(&ui, .Root, key=alicorn.key_string("semantic-safety-tall-root"),
		style=alicorn.layout_style(.Column, width=800, height=5000, clip=true))
	document, _ := find_document(&f.app.backend.state, f.document_id)
	build_document_editor(&f.app, &ui, &f.rt, document)
	alicorn.container_end(&ui)
	headings := 0
	for target in f.app.editor_row_targets {
		if target.logical_line%15 != 0 || target.logical_line >= 72*15 { continue }
		headings += 1
		if !verify { continue }
		expected := fmt.tprintf("# Page %03d", target.logical_line/15)
		found := false
		for item in f.rt.pending {
			if item.kind != .Description || item.description.id != target.node { continue }
			found = true
			testing.expect(t, item.description.text == expected,
				fmt.tprintf("pending source text must survive eviction until end_frame: line=%d", target.logical_line))
			break
		}
		testing.expect(t, found, "every emitted source target must still have a pending text description")
	}
	alicorn.end_frame(&ui)
	if verify {
		for target in f.app.editor_row_targets {
			if target.logical_line%15 != 0 || target.logical_line >= 72*15 { continue }
			node, found := f.rt.nodes[target.node]
			testing.expect(t, found && node.text == fmt.tprintf("# Page %03d", target.logical_line/15),
				"retained reconciliation must copy the original heading, never poisoned freed page text")
		}
	}
	editor_view_restore_after_frame(&f.app, &f.rt, f.app.editor_scroll_owner)
	return headings
}

@(test)
test_semantic_zoom_safety_more_than_64_pages_survive_pending_reconciliation :: proc(t: ^testing.T) {
	backing := context.allocator
	poison := Semantic_Zoom_Safety_Poison{backing=backing,
		blocks=make([dynamic]Semantic_Zoom_Safety_Block, 0, allocator=backing)}
	context.allocator = mem.Allocator{procedure=semantic_zoom_safety_poison_proc, data=&poison}
	f: Semantic_Zoom_Test_Editor
	defer {
		semantic_zoom_test_destroy(&f, t)
		context.allocator = backing
		for block in poison.blocks {
			_ = mem.free(raw_data(block.bytes), backing)
		}
		delete(poison.blocks)
	}
	bytes := make([dynamic]u8, 0, allocator=context.temp_allocator)
	for page in 0..<72 {
		append(&bytes, fmt.tprintf("# Page %03d\n\n", page))
		for detail in 0..<12 { append(&bytes, fmt.tprintf("Hidden detail %03d/%02d.\n", page, detail)) }
		append(&bytes, "\n")
	}
	if !semantic_zoom_test_open(&f, t, "md", string(bytes[:])) { return }
	_, current := semantic_zoom_safety_current_document(&f, t)
	if !current { return }
	view := semantic_zoom_test_view(&f)
	if !semantic_zoom_set_depth(&f.app, &f.rt, 3, 0) { testing.expect(t, false); return }
	f.rt.viewport = alicorn.Rect{0, 0, 800, 5000}
	_ = semantic_zoom_safety_tall_frame(&f, t, false)
	before_frees := poison.frees
	headings := semantic_zoom_safety_tall_frame(&f, t, true)
	// Text surviving reconciliation must also remain usable after its backing
	// page leaves the bounded cache: the earliest heading is still on screen.
	oldest_found := false
	for target in f.app.editor_row_targets {
		if target.logical_line != 0 { continue }
		oldest_found = true
		geometry := alicorn.text_node_caret_geometry(&f.rt, target.node,
			alicorn.Text_Position{byte=2, affinity=.Leading})
		testing.expect(t, geometry.valid, "the evicted page's retained heading must have valid shaped geometry")
		if !geometry.valid { break }
		x, y := geometry.rect.x+0.1, geometry.rect.y+geometry.rect.h*0.5
		hit, _, hit_ok := semantic_zoom_pointer_source(&f.app, &f.rt, view, x, y)
		testing.expect(t, hit_ok && hit == 2,
			"the oldest visibly rendered page must retain exact pointer authority after cache eviction")
		editor_pointer(rawptr(&f.app), &f.rt, alicorn.Pointer_Event{kind=.Down, button=1, x=x, y=y}, f.app.editor_scroll_owner)
		testing.expect(t, view.caret_byte == 2 && view.selection_anchor == 2,
			"the production pointer callback must select a visible heading even when its old page was evicted")
		break
	}
	testing.expect(t, oldest_found, "the cache regression must retain the oldest heading as a real visible source target")
	testing.expect(t, headings > 64 && poison.frees > before_frees && len(view.zoom.windows) <= 64,
		fmt.tprintf("the real frame must exceed the bounded page cache and evict storage: headings=%d pages=%d frees=%d", headings, len(view.zoom.windows), poison.frees-before_frees))
}

@(test)
test_semantic_zoom_safety_same_path_new_instance_discards_frontend_pages :: proc(t: ^testing.T) {
	source := semantic_zoom_safety_distant_source()
	f: Semantic_Zoom_Test_Editor
	defer semantic_zoom_test_destroy(&f, t)
	if !semantic_zoom_test_open(&f, t, "md", source) { return }
	document, current := semantic_zoom_safety_current_document(&f, t)
	if !current { return }
	old_instance, old_revision := document.instance_id, document.editor_revision
	view := semantic_zoom_test_view(&f)
	if !semantic_zoom_set_depth(&f.app, &f.rt, 3, 0) { testing.expect(t, false); return }
	semantic_zoom_test_settle(&f)
	far := u64(strings.index(source, "# Far"))+2
	if !semantic_zoom_safety_click(&f, t, far) { return }
	rect, _, visible := semantic_zoom_test_position(&f, far)
	if !visible { testing.expect(t, false); return }
	closed := bridge.backend_command(&f.app.backend, "close_document", document_id=f.document_id, discard=true)
	closed_ok := closed.ok
	testing.expect(t, closed_ok, closed.message)
	bridge.backend_command_result_destroy(&closed, context.allocator)
	if !closed_ok { return }
	path := fmt.tprintf("%s/source.md", f.workspace)
	replacement := "# Replacement\n\nCurrent opening.\nCurrent detail.\n"
	written := os.write_entire_file_from_string(path, replacement)
	testing.expect(t, written == nil, "the same path must now contain different source bytes")
	if written != nil { return }
	opened := bridge.backend_command(&f.app.backend, "open_path", path=path)
	opened_ok := opened.ok
	testing.expect(t, opened_ok, opened.message)
	bridge.backend_command_result_destroy(&opened, context.allocator)
	if !opened_ok { return }
	document, current = semantic_zoom_safety_current_document(&f, t)
	if !current { return }
	testing.expect(t, document.id == f.document_id && document.instance_id != old_instance && document.editor_revision == old_revision,
		"the real backend must reuse the path/revision while assigning a different source instance")
	// No frontend prune/build occurred between close and reopen; the old view
	// and retained source nodes are still present when the new state arrives.
	_, _, old_hit := semantic_zoom_pointer_source(&f.app, &f.rt, view, rect.x+0.1, rect.y+rect.h*0.5)
	testing.expect(t, !old_hit, "equal revisions must not give another document instance's cached pages pointer authority")
	semantic_zoom_prepare(&f.app, &f.rt, document, view)
	testing.expect(t, view.zoom.depth == 0 && !view.zoom.owned && len(view.zoom.windows) == 0 &&
		view.selection_anchor == document.anchor_byte && view.caret_byte == document.cursor_byte,
		"instance replacement must discard frontend folds/pages and adopt the new source selection")
	window, exact := editor_view_window(view, &f.app.editor_window, f.app.editor_window_ready, document.id, document.editor_revision)
	testing.expect(t, exact && window != nil && string(window.source) == replacement,
		"equal revision numbers must never preserve the previous instance's ordinary or semantic source bytes")
}
