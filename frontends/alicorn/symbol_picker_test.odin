package main

import "core:testing"
import alicorn "alicorn:runtime"
import bridge "./bridge"

@(test)
test_symbol_picker_sizes_to_results_with_bounded_height :: proc(t: ^testing.T) {
	previous_height: f32
	for count in ([3]int{1, 8, 64}) {
		rt := alicorn.new_runtime({0, 0, 1000, 800})
		defer alicorn.destroy_runtime(&rt)
		_ = alicorn.text_engine_load_font(&rt.text_engine, ALICORN_TEST_UI_FONT_DATA)
		app: App
		app.symbol_picker_open = true
		app.structural_view_owned = true
		segments := make([]bridge.Semantic_View_Segment, count, context.temp_allocator)
		defer delete(segments, context.temp_allocator)
		for &segment, index in segments { segment = {ordinal=index, label="heading", text="Heading"} }
		app.structural_view_window = {ready=true, supported=true, total=count, segments=segments}
		documents := [?]bridge.State_Document{{id="symbols", path="notes.md", language="markdown"}}
		app.backend.state.active = "symbols"
		app.backend.state.documents = documents[:]
		ui, _ := alicorn.begin_frame(&rt)
		alicorn.container_begin(&ui, .Root, style=alicorn.layout_style(.Column, width=1000, height=800))
		symbol_picker_build(&app, &ui, &rt)
		alicorn.container_end(&ui)
		alicorn.end_frame(&ui)
		panel, found := alicorn.node_info(&rt, app.symbol_picker_panel_node)
		testing.expect(t, found && panel.bounds.h <= 520 && panel.bounds.h > previous_height,
			"the Symbol picker should grow with its results up to a bounded scrollable height")
		if count == 1 { testing.expect(t, panel.bounds.h < 220, "one symbol should not produce a tall empty dialog") }
		previous_height = panel.bounds.h
	}
}
