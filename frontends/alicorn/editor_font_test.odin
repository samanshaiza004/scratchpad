package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import alicorn "alicorn:runtime"

editor_font_test_owned_string :: proc(value: string, allocator: mem.Allocator) -> string {
	copy, err := strings.clone(value, allocator)
	if err != nil { return "" }
	return copy
}

editor_font_test_build_ui_field :: proc(rt: ^alicorn.Runtime, value: string) -> alicorn.Node_ID {
	ui, build := alicorn.begin_frame(rt)
	if !build { return 0 }
	alicorn.container_begin(&ui, .Root, key=alicorn.key_string("font-hot-swap-ui-root"), style=alicorn.layout_style(.Column, width=320, height=120))
	id := alicorn.text_field(
		&ui, value,
		key=alicorn.key_string("font-hot-swap-ui-field"),
		style=alicorn.layout_style(width=260, height=40),
		text_style=alicorn.Text_Style{font_size=16},
	)
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
	return id
}

@(test)
test_editor_font_hot_swap_preserves_runtime_state_and_releases_old_faces :: proc(t: ^testing.T) {
	backing_allocator := context.allocator
	tracking: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracking, backing_allocator)
	context.allocator = mem.tracking_allocator(&tracking)
	defer {
		context.allocator = backing_allocator
		mem.tracking_allocator_destroy(&tracking)
	}

	root, root_error := os.make_directory_temp("", "scratchpad-editor-font-*", context.temp_allocator)
	if root_error != nil { testing.expect(t, false, "font fixtures should have a temporary directory"); return }
	defer _ = os.remove_all(root)
	font_a_path := fmt.tprintf("%s/a-regular.ttf", root)
	font_a_italic_path := fmt.tprintf("%s/a-italic.ttf", root)
	font_b_path := fmt.tprintf("%s/b-regular.ttf", root)
	font_b_italic_path := fmt.tprintf("%s/b-italic.ttf", root)
	invalid_path := fmt.tprintf("%s/invalid.ttf", root)
	files_written := os.write_entire_file(font_a_path, SCRATCHPAD_MONO_FONT_DATA) == nil &&
		os.write_entire_file(font_a_italic_path, SCRATCHPAD_MONO_ITALIC_FONT_DATA) == nil &&
		os.write_entire_file(font_b_path, SCRATCHPAD_UI_FONT_DATA) == nil &&
		os.write_entire_file(font_b_italic_path, SCRATCHPAD_UI_ITALIC_FONT_DATA) == nil &&
		os.write_entire_file(invalid_path, []u8{0, 1, 2, 3}) == nil
	testing.expect(t, files_written, "bundled real font faces should be written to the temporary catalog")
	if !files_written { return }

	app: App
	app.editor_font_catalog = make([dynamic]System_Font_Family, 3, allocator=context.allocator)
	app.editor_font_catalog[0] = System_Font_Family{
		family=editor_font_test_owned_string("Bundled Mono A", context.allocator),
		regular_path=editor_font_test_owned_string(font_a_path, context.allocator),
		italic_path=editor_font_test_owned_string(font_a_italic_path, context.allocator),
	}
	app.editor_font_catalog[1] = System_Font_Family{
		family=editor_font_test_owned_string("Bundled Mono B", context.allocator),
		regular_path=editor_font_test_owned_string(font_b_path, context.allocator),
		italic_path=editor_font_test_owned_string(font_b_italic_path, context.allocator),
	}
	app.editor_font_catalog[2] = System_Font_Family{
		family=editor_font_test_owned_string("Invalid Fixture", context.allocator),
		regular_path=editor_font_test_owned_string(invalid_path, context.allocator),
	}
	app.editor_font_catalog_ready = true
	defer {
		scratchpad_editor_font_destroy(&app)
		editor_views_destroy(&app.editor_views)
		delete(app.error_message, context.allocator)
	}

	primary := alicorn.new_runtime(alicorn.Rect{0, 0, 800, 600})
	defer alicorn.destroy_runtime(&primary)
	secondary := alicorn.new_runtime(alicorn.Rect{0, 0, 640, 480})
	defer alicorn.destroy_runtime(&secondary)
	new_floating := alicorn.new_runtime(alicorn.Rect{0, 0, 640, 480})
	defer alicorn.destroy_runtime(&new_floating)
	app.primary_runtime = &primary
	app.floating_window = new(Floating_Window_State)
	app.floating_window.owner = &app
	app.floating_window.runtime = &secondary
	app.floating_window.document_id = "font-test-doc"
	defer {
		free(app.floating_window)
		app.floating_window = nil
	}

	view_index, view_ok := editor_view_ensure(&app.editor_views, "font-test-doc", context.allocator)
	testing.expect(t, view_ok, "font test view should be retained")
	if !view_ok { return }
	view := &app.editor_views[view_index]
	view.selection_anchor = 9
	view.caret_byte = 23
	view.caret_affinity = .Trailing
	view.wrap_height_index_ready = alicorn.virtual_list_height_index_init(
		&view.wrap_height_index, 4, EDITOR_ROW_HEIGHT, context.allocator,
	)
	if !view.wrap_height_index_ready { testing.expect(t, false, "font test wrap-height index should initialize"); return }
	_ = alicorn.virtual_list_height_index_set_height(&view.wrap_height_index, 1, EDITOR_ROW_HEIGHT*3)
	_ = alicorn.virtual_list_height_index_set_height(&view.wrap_height_index, 3, EDITOR_ROW_HEIGHT*2)
	view.wrap_measurement_width = 412
	view.wrap_measurement_revision = 7
	view.wrap_measurement_presentation_revision = 8
	view.wrap_measurement_start_line = 2
	view.wrap_measurement_end_line = 4
	view.wrap_measurement_pending_edits = 3

	selected_a := scratchpad_editor_font_select(&app, &primary, "Bundled Mono A", EDITOR_FONT_SIZE_DEFAULT*1.2, persist=false)
	testing.expect(t, selected_a && app.editor_font_family == "Bundled Mono A",
		"a known bundled family should replace the current editor face")
	testing.expect(t, editor_bytes_equal(primary.text_engine.monospace_font_data, SCRATCHPAD_MONO_FONT_DATA) &&
		editor_bytes_equal(primary.text_engine.monospace_italic_font_data, SCRATCHPAD_MONO_ITALIC_FONT_DATA) &&
		editor_bytes_equal(secondary.text_engine.monospace_font_data, SCRATCHPAD_MONO_FONT_DATA) &&
		editor_bytes_equal(secondary.text_engine.monospace_italic_font_data, SCRATCHPAD_MONO_ITALIC_FONT_DATA),
		"font selection should install regular and authentic italic bytes in both primary and floating runtimes")
	testing.expect(t, app.editor_text_scale == 1.2 && view.selection_anchor == 9 && view.caret_byte == 23 && view.caret_affinity == .Trailing,
		"font-size changes should preserve source-byte selection and caret affinity")
	if view.wrap_height_index_ready {
		testing.expect(t, abs(alicorn.virtual_list_height_index_item_height(&view.wrap_height_index, 1)-EDITOR_ROW_HEIGHT*1.2) < 0.1 &&
			abs(alicorn.virtual_list_height_index_item_height(&view.wrap_height_index, 3)-EDITOR_ROW_HEIGHT*1.2) < 0.1 &&
			view.wrap_measurement_width == -1 && view.wrap_measurement_revision == 0 &&
			view.wrap_measurement_presentation_revision == 0 && view.wrap_measurement_start_line == 0 &&
			view.wrap_measurement_end_line == 0 && view.wrap_measurement_pending_edits == 0,
			"font replacement should clear measured row heights and all retained wrap-measurement keys")
	}

	fresh_window := Floating_Window_State{owner=&app}
	floating_window_initialize(rawptr(&fresh_window), &new_floating)
	testing.expect(t, editor_bytes_equal(new_floating.text_engine.monospace_font_data, app.editor_font_data) &&
		editor_bytes_equal(new_floating.text_engine.monospace_italic_font_data, app.editor_font_italic_data),
		"a floating window initialized after selection should inherit the selected regular and italic bytes")

	primary_generation := primary.text_engine.font_generation
	secondary_generation := secondary.text_engine.font_generation
	kept_family := editor_font_test_owned_string(app.editor_font_family, context.allocator)
	kept_regular := make([]u8, len(app.editor_font_data), allocator=context.allocator)
	copy(kept_regular, app.editor_font_data)
	kept_italic := make([]u8, len(app.editor_font_italic_data), allocator=context.allocator)
	copy(kept_italic, app.editor_font_italic_data)
	defer { delete(kept_family, context.allocator); delete(kept_regular, context.allocator); delete(kept_italic, context.allocator) }
	invalid_selected := scratchpad_editor_font_select(&app, &primary, "Invalid Fixture", EDITOR_FONT_SIZE_DEFAULT, persist=false)
	testing.expect(t, !invalid_selected && app.editor_font_family == kept_family &&
		primary.text_engine.font_generation == primary_generation && secondary.text_engine.font_generation == secondary_generation &&
		editor_bytes_equal(app.editor_font_data, kept_regular) && editor_bytes_equal(app.editor_font_italic_data, kept_italic),
		"invalid font bytes should preserve the active family, both runtimes, and their font generations")

	allocator_after_a := tracking.current_memory_allocated
	for _ in 0..<4 {
		selected_b := scratchpad_editor_font_select(&app, &primary, "Bundled Mono B", EDITOR_FONT_SIZE_DEFAULT*1.2, persist=false)
		selected_a_again := scratchpad_editor_font_select(&app, &primary, "Bundled Mono A", EDITOR_FONT_SIZE_DEFAULT*1.2, persist=false)
		stable_a := selected_b && selected_a_again && app.editor_font_family == "Bundled Mono A" &&
			editor_bytes_equal(app.editor_font_data, SCRATCHPAD_MONO_FONT_DATA) &&
			editor_bytes_equal(app.editor_font_italic_data, SCRATCHPAD_MONO_ITALIC_FONT_DATA) &&
			editor_bytes_equal(primary.text_engine.monospace_font_data, app.editor_font_data) &&
			editor_bytes_equal(secondary.text_engine.monospace_font_data, app.editor_font_data)
		testing.expect(t, stable_a, "repeated hot swaps should keep both runtimes on the selected face")
		testing.expect(t, tracking.current_memory_allocated == allocator_after_a,
			fmt.tprintf("replacing real font assets repeatedly should release prior retained bytes (expected %d bytes, found %d)", allocator_after_a, tracking.current_memory_allocated))
	}
}

@(test)
test_editor_font_hot_swap_reflows_editor_but_preserves_focused_ui_field :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp("", "scratchpad-font-reflow-*", context.temp_allocator)
	if root_error != nil { testing.expect(t, false, "font reflow fixture directory should be created"); return }
	defer _ = os.remove_all(root)
	font_a_path := fmt.tprintf("%s/a-regular.ttf", root)
	font_a_italic_path := fmt.tprintf("%s/a-italic.ttf", root)
	font_b_path := fmt.tprintf("%s/b-regular.ttf", root)
	font_b_italic_path := fmt.tprintf("%s/b-italic.ttf", root)
	files_written := os.write_entire_file(font_a_path, SCRATCHPAD_MONO_FONT_DATA) == nil &&
		os.write_entire_file(font_a_italic_path, SCRATCHPAD_MONO_ITALIC_FONT_DATA) == nil &&
		os.write_entire_file(font_b_path, SCRATCHPAD_UI_FONT_DATA) == nil &&
		os.write_entire_file(font_b_italic_path, SCRATCHPAD_UI_ITALIC_FONT_DATA) == nil
	testing.expect(t, files_written, "both bundled real families should be available for the reflow fixture")
	if !files_written { return }

	app: App
	app.editor_font_catalog = make([dynamic]System_Font_Family, 2, allocator=context.allocator)
	app.editor_font_catalog[0] = System_Font_Family{
		family=editor_font_test_owned_string("Bundled Mono A", context.allocator),
		regular_path=editor_font_test_owned_string(font_a_path, context.allocator),
		italic_path=editor_font_test_owned_string(font_a_italic_path, context.allocator),
	}
	app.editor_font_catalog[1] = System_Font_Family{
		family=editor_font_test_owned_string("Bundled UI B", context.allocator),
		regular_path=editor_font_test_owned_string(font_b_path, context.allocator),
		italic_path=editor_font_test_owned_string(font_b_italic_path, context.allocator),
	}
	app.editor_font_catalog_ready = true
	defer {
		scratchpad_editor_font_destroy(&app)
		editor_views_destroy(&app.editor_views)
		delete(app.error_message, context.allocator)
	}

	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 360, 180})
	defer alicorn.destroy_runtime(&rt)
	app.primary_runtime = &rt
	_ = alicorn.font_load_bytes(&rt, .UI, SCRATCHPAD_UI_FONT_DATA)
	_ = alicorn.font_load_italic_bytes(&rt, .UI, SCRATCHPAD_UI_ITALIC_FONT_DATA)
	selected_mono := scratchpad_editor_font_select(&app, &rt, "Bundled Mono A", 16, persist=false)
	testing.expect(t, selected_mono, "the real bundled monospaced face should load at the fixed 16-unit size")
	if !selected_mono { return }

	text := "iiiiiiii wwww iiiiiiii wwww iiiiiiii wwww"
	mono_run, mono_ok := alicorn.runtime_text_run_build(
		&rt, text, size=16, max_width=100, font=.Monospace, overflow=.Wrap,
	)
	defer alicorn.text_run_destroy(&mono_run)
	testing.expect(t, mono_ok, fmt.tprintf("the monospaced editor sample should shape at width 100 (rows=%d size=%v width=%v font_loaded=%t)", len(mono_run.lines), mono_run.size, mono_run.width, rt.text_engine.monospace_font_loaded))
	if !mono_ok { return }
	mono_rows := len(mono_run.lines)

	field_id := editor_font_test_build_ui_field(&rt, "keep selection")
	testing.expect(t, field_id != 0 && alicorn.focus(&rt, field_id), "the independent UI text field should be built and focused")
	if field_id == 0 { return }
	_ = alicorn.set_text_selection(&rt, field_id, 2, 8)
	field_before := rt.nodes[field_id]
	selection_anchor_before, selection_focus_before := field_before.selection_anchor, field_before.selection_focus
	ui_size_before := field_before.text_run.size
	testing.expect(t, field_before.font == .UI && field_before.text_run_valid && ui_size_before == 16,
		fmt.tprintf("expected UI role and 16-unit run before swap; font=%v run_valid=%t run_size=%v field_id=%d ui_loaded=%t", field_before.font, field_before.text_run_valid, ui_size_before, field_id, rt.text_engine.font_loaded))

	selected_ui := scratchpad_editor_font_select(&app, &rt, "Bundled UI B", 16, persist=false)
	testing.expect(t, selected_ui && app.editor_text_scale == 1,
		"switching only the editor face at the same size should not change the UI scale")
	if !selected_ui { return }
	ui_run, ui_ok := alicorn.runtime_text_run_build(
		&rt, text, size=16, max_width=100, font=.Monospace, overflow=.Wrap,
	)
	defer alicorn.text_run_destroy(&ui_run)
	testing.expect(t, ui_ok && len(ui_run.lines) != mono_rows,
		fmt.tprintf("expected different wraps at size=16 width=100; mono rows=%d mono size=%v mono width=%v UI rows=%d UI run built=%t UI size=%v UI width=%v", mono_rows, mono_run.size, mono_run.width, len(ui_run.lines), ui_ok, ui_run.size, ui_run.width))
	if !ui_ok { return }

	field_after_id := editor_font_test_build_ui_field(&rt, "keep selection")
	if field_after_id == 0 {
		testing.expect(t, false, "the focused UI field should rebuild after the editor font swap")
		return
	}
	field_after := rt.nodes[field_after_id]
	caret := alicorn.text_field_caret_geometry(&rt, field_after_id)
	testing.expect(t, field_after_id == field_id && alicorn.focused_node(&rt) == field_id &&
		field_after.text_run_valid && field_after.font == .UI && field_after.text_run.size == ui_size_before &&
		field_after.selection_anchor == selection_anchor_before && field_after.selection_focus == selection_focus_before && caret.valid,
		fmt.tprintf("expected preserved focus/size/selection/caret; before_id=%d after_id=%d focused=%d valid=%t font=%v before_size=%v after_size=%v before_selection=(%v,%v) after_selection=(%v,%v) caret_valid=%t", field_id, field_after_id, alicorn.focused_node(&rt), field_after.text_run_valid, field_after.font, ui_size_before, field_after.text_run.size, selection_anchor_before, selection_focus_before, field_after.selection_anchor, field_after.selection_focus, caret.valid))
}
