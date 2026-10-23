package main

import "core:testing"
import alicorn "alicorn:runtime"
import bridge "./bridge"

@(test)
test_compact_document_tabs_overflow_and_preview_presentation :: proc(t: ^testing.T) {
	documents := [?]bridge.State_Document{
		{id="tab-0", path="README.md", view_kind="text", preview=true},
		{id="tab-1", path=".caliber-cli-revision", view_kind="text"},
		{id="tab-2", path="LICENSE", view_kind="text"},
		{id="tab-3", path="package_windows_test.go", view_kind="text"},
		{id="tab-4", path=".gitignore", view_kind="text"},
		{id="tab-5", path="README.rst", view_kind="text"},
		{id="tab-6", path="accesskit.go", view_kind="text"},
		{id="tab-7", path="macos_build_test.go", view_kind="text"},
	}
	app := App{}
	app.backend.state.documents = documents[:]
	app.backend.state.active = documents[len(documents)-1].id
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 900, 48})
	defer alicorn.destroy_runtime(&rt)

	ui, should_build := alicorn.begin_frame(&rt)
	if !should_build {
		testing.expect(t, false, "the compact document tab fixture should build")
		return
	}
	alicorn.container_begin_simple(&ui, .Root, style=alicorn.layout_style(.Row, width=900, height=42))
	scratchpad_document_tabs_build(&app, &ui, &rt, width=900, height=SCRATCHPAD_CONTENT_TITLEBAR_TAB_HEIGHT, compact=true, show_empty=false)
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)

	left_controls, right_controls := 0, 0
	left_disabled, right_disabled := true, true
	tab_count := 0
	overflow_found := false
	left_control_found, right_control_found := false, false
	preview_tab_found := false
	preview_label_found := false
	preview_tooltip_found := false
	for node_id in rt.order {
		node, found := rt.nodes[node_id]
		if !found || !node.active { continue }
		if node.kind == .Button && node.button_variant == .Tab { tab_count += 1 }
		if node.kind == .Button && node.button_variant == .Tab && node.semantic_id == document_tab_semantic_id("tab-0") {
			preview_tab_found = true
			preview_tooltip_found = node.tooltip_text == "README.md"
		}
		if node.kind == .Text && node.text == "README.md" {
			preview_label_found = len(node.text_style_spans) == 1 && node.text_style_spans[0].italic &&
				node.text_style_spans[0].italic_set && len(node.text_paint_spans) == 1 &&
				node.text_paint_spans[0].color_set
		}
		if node.kind == .Scroll_Region && node.label == "tab-bar" {
			overflow_found = node.scroll_content_width > node.scroll_viewport_width
		}
	}
	for _, entity in rt.semantic_entities {
		if entity.node.role != .Button || entity.node.visual_node == 0 { continue }
		node, found := rt.nodes[entity.node.visual_node]
		if !found || !node.active { continue }
		if entity.node.label == "Scroll tabs left" {
			left_controls += 1
			left_disabled = node.disabled
			for candidate in rt.order {
				glyph, glyph_found := rt.nodes[candidate]
				if glyph_found && glyph.active && glyph.parent == node.id && glyph.kind == .Text && glyph.text == "‹" {
					left_control_found = true
				}
			}
		}
		if entity.node.label == "Scroll tabs right" {
			right_controls += 1
			right_disabled = node.disabled
			for candidate in rt.order {
				glyph, glyph_found := rt.nodes[candidate]
				if glyph_found && glyph.active && glyph.parent == node.id && glyph.kind == .Text && glyph.text == "›" {
					right_control_found = true
				}
			}
		}
	}
	testing.expect(t, left_controls == 1 && right_controls == 1,
		"a crowded titlebar should expose one accessible arrow control on each side")
	testing.expect(t, left_control_found && right_control_found,
		"both accessible overflow controls should contain visible chevron text")
	testing.expect(t, tab_count == len(documents),
		"scrolling should retain every logical document tab")
	testing.expect(t, overflow_found && !left_disabled && right_disabled,
		"the selected final tab should be revealed at the trailing edge, with arrows reporting the available direction")
	testing.expect(t, preview_tab_found && preview_label_found && preview_tooltip_found,
		"preview tabs should keep the bare filename, render it muted and italic, and expose the full label in a tooltip")
}
