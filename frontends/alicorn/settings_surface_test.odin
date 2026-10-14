package main

import "core:fmt"
import "core:testing"
import alicorn "alicorn:runtime"

settings_test_find_node :: proc(rt: ^alicorn.Runtime, key, label: string) -> alicorn.Node_ID {
	for id in rt.order {
		node, found := rt.nodes[id]
		if !found { continue }
		if key != "" && node.key == key || label != "" && node.label == label { return id }
	}
	return 0
}

settings_test_build :: proc(app: ^App, rt: ^alicorn.Runtime, scale: f32) -> bool {
	if !scratchpad_styles_ensure(app, rt) { return false }
	ui, build := alicorn.begin_frame(rt)
	if !build { return false }
	alicorn.container_begin(&ui, .Root, label="settings-test-root", style=alicorn.layout_style(grow=1))
	scope := alicorn.style_environment_push(&ui, alicorn.Style_Environment{theme=app.workbench_theme, text_scale=scale})
	alicorn.container_end(&ui)
	settings_surface_build(app, &ui, rt, scale)
	alicorn.style_environment_pop(&ui, scope)
	alicorn.end_frame(&ui)
	return true
}

settings_test_descendant :: proc(rt: ^alicorn.Runtime, id, ancestor: alicorn.Node_ID) -> bool {
	current := id
	for current != 0 {
		if current == ancestor { return true }
		current = rt.nodes[current].parent
	}
	return false
}

@(test)
test_settings_pages_fit_large_and_narrow_windows_without_text_overlap :: proc(t: ^testing.T) {
	viewports := [4]alicorn.Rect{{0, 0, 2560, 1390}, {0, 0, 900, 650}, {0, 0, 720, 420}, {0, 0, 480, 360}}
	scales := [4]f32{1, 1.25, 1.5, 2}
	for viewport in viewports {
	for scale in scales {
		rt := alicorn.new_runtime(viewport)
		app: App
		app.settings_surface_open = true
		app.accessibility_appearance_override_enabled = true
		if viewport.w < 500 {
			app.editor_text_scale = EDITOR_FONT_SIZE_MAX/EDITOR_FONT_SIZE_DEFAULT
			app.editor_font_family = "A very long installed font family name that requires ellipsis in a narrow Settings page"
		}
		fonts := alicorn.text_engine_load_font(&rt.text_engine, ALICORN_TEST_UI_FONT_DATA) && alicorn.text_engine_load_font_role(&rt.text_engine, .Monospace, ALICORN_TEST_MONO_FONT_DATA)
		testing.expect(t, fonts, "Settings fixtures should load bundled fonts")
		if !fonts { alicorn.destroy_runtime(&rt); continue }
		for category in Settings_Category {
			app.settings_category = category
			alicorn.invalidate_root(&rt, "Settings page layout regression")
			_ = settings_test_build(&app, &rt, scale)
			panel := settings_test_find_node(&rt, "", "scratchpad-settings")
			form := settings_test_find_node(&rt, "settings-form", "")
			scroll := settings_test_find_node(&rt, "scratchpad-settings-scroll", "")
			done := settings_test_find_node(&rt, "settings-done", "")
			testing.expect(t, panel != 0 && form != 0 && scroll != 0 && done != 0, "each page should retain its panel, content, scroll viewport and Done button")
			if panel == 0 || form == 0 || scroll == 0 || done == 0 { continue }
			bounds := rt.nodes[panel].bounds
			done_bounds := rt.nodes[done].bounds
			region := alicorn.scroll_region_state(&rt, scroll)
			testing.expect(t, bounds.x >= 23 && bounds.y >= 23 && bounds.x+bounds.w <= viewport.w-23 && bounds.y+bounds.h <= viewport.h-23, fmt.tprintf("Settings panel %v should fit %.0fx%.0f at scale %.2f", bounds, viewport.w, viewport.h, scale))
			if viewport.w > 2000 { testing.expect(t, bounds.w >= 1400 && bounds.h >= 1000, "Settings should use substantial space in a full-screen window") }
			testing.expect(t, done_bounds.y+done_bounds.h <= bounds.y+bounds.h && region.viewport_bounds.y+region.viewport_height <= done_bounds.y, "the Done action must remain visible below the scrolling page")
			testing.expect(t, abs(region.content_height-rt.nodes[form].bounds.h) < 0.1, "the scroll extent must match the emitted form, including wrapped paragraphs")
			for id in rt.order {
				node := rt.nodes[id]
				if !settings_test_descendant(&rt, id, form) { continue }
				if node.kind == .Text {
					testing.expect(t, node.text_run_valid && node.text_run.height <= node.bounds.h+1 && node.text_run.width <= node.bounds.w+1,
						fmt.tprintf("page %v at %.0fx%.0f scale %.2f must contain text %s (run %.2fx%.2f, bounds %.2fx%.2f)", category, viewport.w, viewport.h, scale, node.key, node.text_run.width, node.text_run.height, node.bounds.w, node.bounds.h))
				}
				if node.style.direction == .Column && len(node.children) > 0 {
					bottom := f32(-100000)
					for child_id in node.children {
						child := rt.nodes[child_id]
						testing.expect(t, child.bounds.y >= bottom-0.1, "consecutive Settings rows must not overlap")
						testing.expect(t, child.bounds.y+child.bounds.h <= node.bounds.y+node.bounds.h+1, "Settings children must fit their measured parent")
						bottom = child.bounds.y+child.bounds.h
					}
				}
			}
			if category == .Editor {
				family := settings_test_find_node(&rt, "settings-editor-font-family", "")
				value := settings_test_find_node(&rt, "settings-editor-font-family-value", "")
				chevron := settings_test_find_node(&rt, "settings-editor-font-family-chevron", "")
				testing.expect(t, family != 0 && value != 0 && chevron != 0 && rt.nodes[family].label == "" && rt.nodes[chevron].icon_id == .Chevron_Down,
					"the font selector must paint one family value and a graphical chevron, without also painting its semantic name")
				snapshot := alicorn.semantic_snapshot(&rt, context.temp_allocator)
				family_name := app.editor_font_family
				if family_name == "" { family_name = "Atkinson Hyperlegible Mono" }
				accessible_family := false
				for entry in snapshot.nodes {
					if entry.visual_node == family && entry.role == .Button && entry.label == fmt.tprintf("Choose editor font family: %s", family_name) { accessible_family = true }
				}
				alicorn.semantic_snapshot_destroy(&snapshot)
				testing.expect(t, accessible_family, "the selector must preserve its accessible name and Button role without painting the name")
				preview := settings_test_find_node(&rt, "settings-editor-font-preview", "")
				testing.expect(t, preview != 0 && rt.nodes[preview].font == .Monospace && rt.nodes[preview].text_style.font_size == scratchpad_editor_font_size(&app), "the sample must use the current editor font and size")
			}
		}
		alicorn.destroy_runtime(&rt)
	}
	}
}

@(test)
test_settings_navigation_and_scrolling_preserve_focus_and_page_state :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 900, 420})
	defer alicorn.destroy_runtime(&rt)
	_ = alicorn.text_engine_load_font(&rt.text_engine, ALICORN_TEST_UI_FONT_DATA)
	_ = alicorn.text_engine_load_font_role(&rt.text_engine, .Monospace, ALICORN_TEST_MONO_FONT_DATA)
	app: App
	app.settings_surface_open = true
	_ = settings_test_build(&app, &rt, 1)
	editor_category := settings_test_find_node(&rt, "settings-category-1", "")
	testing.expect(t, editor_category != 0 && alicorn.focus(&rt, editor_category) && alicorn.activate_focused(&rt, .Enter), "the Editor category should support keyboard activation")
	_ = settings_test_build(&app, &rt, 1)
	testing.expect(t, app.settings_category == .Editor && alicorn.focused_node(&rt) == editor_category, "changing pages must preserve navigation focus")
	scroll := settings_test_find_node(&rt, "scratchpad-settings-scroll", "")
	_ = alicorn.scroll_region_set_offset(&rt, scroll, 100000, "Settings scroll regression")
	_ = settings_test_build(&app, &rt, 1)
	before := alicorn.scroll_region_state(&rt, scroll)
	title := settings_test_find_node(&rt, "settings-page-title", "")
	testing.expect(t, before.offset_y > 0 && rt.nodes[title].bounds.y < before.viewport_bounds.y, "scrolling must move the actual form, with the footer fixed")
	alicorn.invalidate_root(&rt, "Settings same-page rebuild")
	_ = settings_test_build(&app, &rt, 1)
	testing.expect(t, abs(alicorn.scroll_region_state(&rt, scroll).offset_y-before.offset_y) < 0.1, "an ordinary rebuild must preserve the page scroll offset")
	settings_category_select(&app, &rt, .Workspace)
	_ = settings_test_build(&app, &rt, 1)
	testing.expect(t, alicorn.scroll_region_state(&rt, scroll).offset_y == 0 && settings_test_find_node(&rt, "settings-editor-font-family", "") == 0, "a new category should start at its top and remove the previous page's controls")
}
