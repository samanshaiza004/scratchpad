package main

import "core:testing"
import "core:fmt"
import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"

@(test)
test_editor_font_picker_filter_handles_large_catalog_and_terms :: proc(t: ^testing.T) {
	catalog := make([dynamic]System_Font_Family, 220, allocator=context.temp_allocator)
	defer delete(catalog)
	for index in 0..<len(catalog) {
		catalog[index] = System_Font_Family{family=fmt.tprintf("Test Family %03d", index), monospaced=index%2 == 0}
	}
	catalog[173].family = "Atkinson Hyperlegible Mono"
	catalog[173].unsupported_reason = "Missing regular face"

	all := editor_font_picker_filter(catalog[:], "", context.temp_allocator)
	defer delete(all)
	testing.expect(t, len(all) == 220 && all[219] == 219,
		"an empty font query should preserve the complete catalog ordering past 128 entries")

	filtered := editor_font_picker_filter(catalog[:], "ATKINSON mono", context.temp_allocator)
	defer delete(filtered)
	testing.expect(t, len(filtered) == 1 && filtered[0] == 173,
		"font search should match case-insensitive multiple terms over the whole catalog")
	testing.expect(t, catalog[filtered[0]].unsupported_reason != "",
		"filtering should retain unavailable families so their reason can be shown to the user")

	missing := editor_font_picker_filter(catalog[:], "not-a-font", context.temp_allocator)
	defer delete(missing)
	testing.expect(t, len(missing) == 0,
		"a query without a family match should produce the empty state")
}

editor_font_picker_test_build_frame :: proc(t: ^testing.T, app: ^App, rt: ^alicorn.Runtime) -> bool {
	if !scratchpad_styles_ensure(app, rt) {
		testing.expect(t, false, "font-picker test themes should register")
		return false
	}
	ui, should_build := alicorn.begin_frame(rt)
	if !should_build {
		testing.expect(t, false, "font-picker test frame should build")
		return false
	}
	alicorn.container_begin(&ui, .Root, key=alicorn.key_string("font-picker-test-root"),
		style=alicorn.layout_style(grow=1),
		color=alicorn.style_theme_color(rt, app.workbench_theme, .Window_Background))
	alicorn.container_end(&ui)
	theme_scope := alicorn.style_environment_push(&ui, scratchpad_workbench_style_environment(app))
	scratchpad_editor_font_picker_build(app, &ui, rt)
	alicorn.style_environment_pop(&ui, theme_scope)
	alicorn.end_frame(&ui)
	return true
}

@(test)
test_editor_font_picker_virtualization_caps_visible_rows :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 360, 280})
	defer alicorn.destroy_runtime(&rt)
	fonts_loaded := alicorn.text_engine_load_font(&rt.text_engine, ALICORN_TEST_UI_FONT_DATA) &&
		alicorn.text_engine_load_font_role(&rt.text_engine, .Monospace, ALICORN_TEST_MONO_FONT_DATA)
	testing.expect(t, fonts_loaded, "font picker fixture should load the bundled UI and monospace fonts")
	if !fonts_loaded { return }
	app: App
	app.editor_font_catalog = make([dynamic]System_Font_Family, 144, allocator=context.temp_allocator)
	defer delete(app.editor_font_catalog)
	for index in 0..<len(app.editor_font_catalog) {
		app.editor_font_catalog[index] = System_Font_Family{family=fmt.tprintf("Family %03d", index)}
	}
	app.editor_font_catalog_ready = true
	app.editor_font_picker_open = true
	if !editor_font_picker_test_build_frame(t, &app, &rt) { return }
	list, found := alicorn.node_info(&rt, app.editor_font_picker_results_owner)
	panel_id, panel_key_found := alicorn.node_by_key(&rt, alicorn.key_string("scratchpad-editor-font-picker-panel"), .Container)
	panel, panel_found := alicorn.node_info(&rt, panel_id)
	panel_found = panel_found && panel_key_found
	testing.expect(t, panel_found && panel.bounds.x >= 0 && panel.bounds.y >= 0 && panel.bounds.x+panel.bounds.w <= 360 && panel.bounds.y+panel.bounds.h <= 280 && panel.bounds.w == 312,
		"the picker panel should remain within a narrow viewport")
	testing.expect(t, found && list.scroll_content_height == 144*EDITOR_FONT_PICKER_ROW_HEIGHT,
		"font results should use a virtual list whose extent represents every catalog entry")
	testing.expect(t, found && list.scroll_viewport_height <= f32(EDITOR_FONT_PICKER_MAX_VISIBLE_ROWS)*EDITOR_FONT_PICKER_ROW_HEIGHT+0.1,
		"the searchable font picker should keep its visible result window near ten rows")
	first_panel_id := panel_id
	rt.viewport = alicorn.Rect{0, 0, 900, 700}
	app.theme_choice = .Workbench_Relief
	alicorn.invalidate_root(&rt, "font-picker viewport and theme changed")
	if !editor_font_picker_test_build_frame(t, &app, &rt) { return }
	resized_panel_id, resized_panel_found := alicorn.node_by_key(&rt, alicorn.key_string("scratchpad-editor-font-picker-panel"), .Container)
	resized_panel, resized_info_found := alicorn.node_info(&rt, resized_panel_id)
	testing.expect(t, resized_panel_found && resized_info_found && resized_panel_id == first_panel_id &&
		resized_panel.bounds.w == 852 && resized_panel.bounds.x >= 0 &&
		resized_panel.bounds.x+resized_panel.bounds.w <= rt.viewport.w,
		"viewport resizing and the relief theme should preserve panel identity while its percentage width follows the overlay")
	focused_result, focused_result_found := alicorn.node_by_key(&rt, alicorn.key_string("Family 000"), .Button)
	testing.expect(t, focused_result_found && alicorn.focus(&rt, focused_result),
		"a visible font result should be focusable through normal Tab traversal")
	app.editor_font_picker_selected = 2
	_ = scratchpad_editor_font_picker_handle_key(&app, &rt, .Return)
	testing.expect(t, !app.editor_font_picker_open && app.editor_font_pending_family == "Family 000",
		"Enter on a focused result should apply that focused family even when query selection points elsewhere")
	delete(app.editor_font_pending_family, context.allocator)
}

@(test)
test_editor_font_picker_keyboard_selection_traverses_large_and_filtered_results :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 800, 600})
	defer alicorn.destroy_runtime(&rt)
	app: App
	app.editor_font_catalog = make([dynamic]System_Font_Family, 180, allocator=context.temp_allocator)
	defer delete(app.editor_font_catalog)
	for index in 0..<len(app.editor_font_catalog) {
		app.editor_font_catalog[index] = System_Font_Family{family=fmt.tprintf("Typeface %03d", index)}
	}
	app.editor_font_picker_open = true
	for _ in 0..<137 { _ = scratchpad_editor_font_picker_handle_key(&app, &rt, .Down) }
	testing.expect(t, app.editor_font_picker_selected == 137,
		"keyboard navigation should reach entries beyond the first 128 catalog entries")
	app.editor_font_picker_query = "typeface 14"
	app.editor_font_picker_selected = 0
	_ = scratchpad_editor_font_picker_handle_key(&app, &rt, .Down)
	filtered := editor_font_picker_filter(app.editor_font_catalog[:], app.editor_font_picker_query, context.temp_allocator)
	defer delete(filtered)
	testing.expect(t, len(filtered) == 12 && app.editor_font_picker_selected == 1,
		"keyboard navigation should move within the currently filtered result set")
	tab_was_consumed := scratchpad_editor_font_picker_handle_key(&app, &rt, .Tab_Next)
	testing.expect(t, !tab_was_consumed && app.editor_font_picker_open,
		"Tab should remain available to the normal focus traversal while the picker is open")
}

@(test)
test_editor_font_picker_declines_native_text_editing_keys :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 600, 400})
	defer alicorn.destroy_runtime(&rt)
	app: App
	app.editor_font_picker_open = true
	app.editor_font_picker_query = "query text"
	for key in ([2]host.Application_Key{.Left, .Find}) {
		handled := scratchpad_editor_font_picker_handle_key(&app, &rt, key)
		testing.expect(t, !handled && app.editor_font_picker_query == "query text",
			"unhandled keys should reach the native font-picker query field without changing its contents")
	}
	// Backspace and Select All are delivered as native text-key intents rather
	// than Application_Key values, so they never enter this modal callback.
}

editor_font_picker_dual_modal_test_build :: proc(t: ^testing.T, app: ^App, rt: ^alicorn.Runtime) -> bool {
	if app == nil || rt == nil || !scratchpad_styles_ensure(app, rt) { return false }
	ui, should_build := alicorn.begin_frame(rt)
	if !should_build {
		testing.expect(t, false, "Settings and font picker fixture should build its invalidated description")
		return false
	}
	alicorn.container_begin(&ui, .Root, key=alicorn.key_string("settings-font-picker-test-root"), style=alicorn.layout_style(grow=1), color=alicorn.style_theme_color(rt, app.workbench_theme, .Window_Background))
	scope := alicorn.style_environment_push(&ui, alicorn.Style_Environment{theme=app.workbench_theme, text_scale=1})
	alicorn.container_end(&ui)
	settings_surface_build(app, &ui, rt, 1)
	if app.editor_font_picker_open { scratchpad_editor_font_picker_build(app, &ui, rt) }
	alicorn.style_environment_pop(&ui, scope)
	alicorn.end_frame(&ui)
	scratchpad_editor_font_picker_restore_focus_after_frame(app, rt)
	return true
}

@(test)
test_editor_font_picker_keeps_settings_modal_behind_and_restores_family_focus :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 900, 650})
	defer alicorn.destroy_runtime(&rt)
	fonts_loaded := alicorn.text_engine_load_font(&rt.text_engine, ALICORN_TEST_UI_FONT_DATA) &&
		alicorn.text_engine_load_font_role(&rt.text_engine, .Monospace, ALICORN_TEST_MONO_FONT_DATA)
	testing.expect(t, fonts_loaded, "dual-modal font picker fixture should load the bundled fonts")
	if !fonts_loaded { return }
	app: App
	app.settings_surface_open = true
	app.settings_category = .Editor
	app.accessibility_appearance_override_enabled = true
	app.editor_font_catalog = make([dynamic]System_Font_Family, 1, allocator=context.temp_allocator)
	defer delete(app.editor_font_catalog)
	app.editor_font_catalog[0] = System_Font_Family{family="Picker Test Mono", monospaced=true}
	app.editor_font_catalog_ready = true
	if !editor_font_picker_dual_modal_test_build(t, &app, &rt) { return }
	family_button, family_found := alicorn.node_by_key(&rt, alicorn.key_string("settings-editor-font-family"), .Button)
	testing.expect(t, family_found && alicorn.focus(&rt, family_button),
		"the Settings family control should be focusable before opening the nested picker")
	if !family_found { return }
	scratchpad_editor_font_picker_open(&app, &rt)
	if !editor_font_picker_dual_modal_test_build(t, &app, &rt) { return }
	query_focus := alicorn.focused_node(&rt)
	testing.expect(t, query_focus == app.editor_font_picker_query_node,
		"opening the picker should focus its query while Settings remains open behind it")
	default_button, default_found := alicorn.node_by_key(&rt, alicorn.key_string("scratchpad-editor-font-picker-default"), .Button)
	chosen_font, chosen_found := alicorn.node_by_key(&rt, alicorn.key_string("Picker Test Mono"), .Button)
	testing.expect(t, default_found && chosen_found,
		"the open picker should expose both the bundled default and a searchable system-family result")
	background_size_control, background_found := alicorn.node_by_key(&rt, alicorn.key_string("settings-editor-font-size-up"), .Button)
	if background_found {
		application_pointer(rawptr(&app), &rt, alicorn.Pointer_Event{kind=.Down, button=alicorn.POINTER_BUTTON_PRIMARY}, background_size_control)
	}
	testing.expect(t, background_found && app.editor_font_picker_open && !app.editor_font_pending,
		"a pointer aimed at the obscured Settings size control should not change editor typography while the picker is open")
	_ = scratchpad_editor_font_picker_handle_key(&app, &rt, .Escape)
	testing.expect(t, !app.editor_font_picker_open && app.settings_surface_open,
		"Escape should close only the top font-picker modal")
	if !editor_font_picker_dual_modal_test_build(t, &app, &rt) { return }
	testing.expect(t, alicorn.focused_node(&rt) == family_button,
		"closing the picker should restore focus to the Settings family control")
	_ = default_button
	_ = chosen_font
}
