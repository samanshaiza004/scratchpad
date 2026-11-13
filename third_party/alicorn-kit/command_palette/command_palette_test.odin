package command_palette

import "core:mem"
import "core:testing"
import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"

@(private)
palette_test_items :: [3]Item{
	{ id=Item_ID(11), title="Open Workspace" },
	{ id=Item_ID(22), title="Close Tab" },
	{ id=Item_ID(33), title="Disabled Action", disabled=true },
}

@(private)
Palette_Test_Allocator :: struct {
	backing: mem.Allocator,
	fail_new_allocations: bool,
}

@(private)
palette_test_allocator :: proc(
	data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	state := (^Palette_Test_Allocator)(data)
	if state.fail_new_allocations && (mode == .Alloc || mode == .Alloc_Non_Zeroed) {
		return nil, .Out_Of_Memory
	}
	return state.backing.procedure(state.backing.data, mode, size, alignment, old_memory, old_size, location)
}

@(private)
palette_test_describe :: proc(rt: ^alicorn.Runtime, state: ^State, items: []Item) -> alicorn.Node_ID {
	ctx, should_build := alicorn.begin_frame(rt)
	if !should_build { return 0 }
	root := alicorn.container_begin(&ctx, .Root,
		key=alicorn.key_string("alikit-palette-test-root"),
		style=alicorn.layout_style(.Column, width=480, height=320, padding=12, gap=8))
	if root == 0 {
		alicorn.end_frame(&ctx)
		return 0
	}
	editor := alicorn.text_field(&ctx, "editor", key=alicorn.key_string("alikit-palette-test-editor"))
	alicorn.container_end(&ctx)
	if state.open {
		_ = build(&ctx, state, items, alicorn.key_string("alikit-palette-test-overlay"))
	}
	alicorn.end_frame(&ctx)
	after_frame(state, rt)
	return editor
}

@(test)
test_keyboard_activation_and_focus_restore_use_retained_runtime :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 480, 320})
	defer alicorn.destroy_runtime(&rt)
	state: State
	if !init(&state, context.allocator) {
		testing.expect(t, false, "palette state should initialize")
		return
	}
	defer destroy(&state)
	items := palette_test_items
	editor := palette_test_describe(&rt, &state, items[:])
	testing.expect(t, editor != 0 && alicorn.focus(&rt, editor), "the app editor should receive initial focus")
	if !open_palette(&state, &rt) {
		testing.expect(t, false, "palette should open transactionally")
		return
	}
	_ = palette_test_describe(&rt, &state, items[:])
	testing.expect(t, alicorn.focused_node(&rt) == state.query_node,
		"opening should move focus into the palette query after reconciliation")
	handled, event := handle_key(&state, &rt, items[:], host.Application_Key.Down)
	testing.expect(t, handled && event.kind == .None && state.selection.id == Item_ID(22),
		"Down should move selection to the next enabled stable item")
	handled, event = handle_key(&state, &rt, items[:], host.Application_Key.Return)
	testing.expect(t, handled && event.kind == .Activated && event.item_id == Item_ID(22) && !state.open,
		"Return should activate the selected stable ID and close the palette")
	_ = palette_test_describe(&rt, &state, items[:])
	testing.expect(t, alicorn.focused_node(&rt) == editor,
		"closing should restore the focus owner captured before the modal opened")
}

@(test)
test_caller_filtered_mode_does_not_reapply_substring_search :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 480, 320})
	defer alicorn.destroy_runtime(&rt)
	state: State
	if !init(&state, context.allocator) {
		testing.expect(t, false, "palette state should initialize")
		return
	}
	defer destroy(&state)
	all_items := palette_test_items
	if !open_palette(&state, &rt, .Caller_Filtered) {
		testing.expect(t, false, "caller-filtered palette should open")
		return
	}
	_ = set_query(&state, &rt, "wrkspc")
	fuzzy_result := [1]Item{all_items[0]}
	_ = palette_test_describe(&rt, &state, fuzzy_result[:])
	testing.expect(t, state.match_count == 1 && state.selection.id == Item_ID(11),
		"a caller-selected fuzzy result should remain visible despite lacking a contiguous query substring")
	handled, event := handle_key(&state, &rt, fuzzy_result[:], host.Application_Key.Return)
	testing.expect(t, handled && event.kind == .Activated && event.item_id == Item_ID(11),
		"activation should use the current caller-filtered results")
}

@(test)
test_navigation_and_activation_yield_during_runtime_ime_composition :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 480, 320})
	defer alicorn.destroy_runtime(&rt)
	state: State
	if !init(&state, context.allocator) {
		testing.expect(t, false, "palette state should initialize")
		return
	}
	defer destroy(&state)
	items := palette_test_items
	_ = open_palette(&state, &rt)
	_ = palette_test_describe(&rt, &state, items[:])
	testing.expect(t, state.query_node != 0 && alicorn.focused_node(&rt) == state.query_node,
		"IME fixture should focus the palette query")
	if !alicorn.process_text_editing(&rt, state.query_node, "候補", 0, 0) {
		testing.expect(t, false, "query should accept runtime preedit composition")
		return
	}
	for key in ([2]host.Application_Key{.Down, .Return}) {
		handled, event := handle_key(&state, &rt, items[:], key)
		testing.expect(t, !handled && event.kind == .None && state.open,
			"palette navigation and activation should yield while the focused query is composing")
	}
	interaction, found := alicorn.text_field_interaction(&rt, state.query_node)
	testing.expect(t, found && interaction.composition_active,
		"the fixture should retain the active composition state after the keys are yielded")
}

@(test)
test_match_buffer_growth_failure_preserves_owned_buffer_and_retries :: proc(t: ^testing.T) {
	allocator_state := Palette_Test_Allocator{backing=context.allocator}
	allocator := mem.Allocator{procedure=palette_test_allocator, data=&allocator_state}
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 480, 320})
	defer alicorn.destroy_runtime(&rt)
	state: State
	if !init(&state, allocator) {
		testing.expect(t, false, "palette state should initialize before allocation failure")
		return
	}
	defer destroy(&state)
	if !open_palette(&state, &rt) {
		testing.expect(t, false, "palette should open before allocation failure")
		return
	}
	single_item := [1]Item{palette_test_items[0]}
	_ = palette_test_describe(&rt, &state, single_item[:])
	testing.expect(t, state.match_count == 1 && state.matches_capacity == 1,
		"the initial result buffer should be populated before growth")

	allocator_state.fail_new_allocations = true
	items := palette_test_items
	_ = palette_test_describe(&rt, &state, items[:])
	testing.expect(t, state.last_status == .Match_Buffer_Allocation_Failed &&
		state.matches_capacity == 1 && len(state.matches) == 1,
		"failed growth should report an error while retaining the previous owned buffer and capacity")
	testing.expect(t, state.match_count == 0 && state.selection.id == 0,
		"failed growth should expose no stale results or selection")

	allocator_state.fail_new_allocations = false
	alicorn.invalidate_root(&rt, "retry palette results after allocation recovery")
	_ = palette_test_describe(&rt, &state, items[:])
	testing.expect(t, state.last_status == .Ready && state.matches_capacity >= len(items) && state.match_count == len(items),
		"a later description should retry growth and recover normally")
}
