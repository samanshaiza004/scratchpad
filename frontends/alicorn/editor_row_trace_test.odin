package main

import "core:testing"
import alicorn "alicorn:runtime"
import gui "alicorn:ui"
import bridge "./bridge"

Editor_Row_Trace_Test_Frame :: struct {
	rows: [3]alicorn.Node_ID,
}

editor_row_trace_test_build :: proc(
	rt: ^alicorn.Runtime,
	texts: [3]string,
	bold_row: int = -1,
	paint_row: int = -1,
	tall_row: int = -1,
) -> Editor_Row_Trace_Test_Frame {
	frame: Editor_Row_Trace_Test_Frame
	alicorn.invalidate_root(rt, "row trace fixture rebuild")
	ui, should_build := alicorn.begin_frame(rt)
	if !should_build { return frame }
	alicorn.container_begin(&ui, .Root, key="row-trace-test-root", style=alicorn.layout_style(.Column, grow=1, clip=true))
	for index in 0..<3 {
		row := alicorn.container_begin(
			&ui,
			.Container,
			label="scratchpad-editor-logical-line",
			key=alicorn.key_u64(u64(index+1)),
			style=alicorn.layout_style(.Row, height=40 if index == tall_row else 28, clip=true),
			color=alicorn.Color{0.12, 0.14, 0.18, 1},
		)
		frame.rows[index] = gui.text(&ui, texts[index], key=alicorn.key_string("text"), style=alicorn.layout_style(.Row, width=-1, height=-1), font=.Monospace)
		if index == bold_row {
			span := [?]alicorn.Text_Style_Span{{
				start=0,
				end=len(texts[index]),
				font_weight=700.25,
				font_weight_set=true,
			}}
			_ = alicorn.text_style_spans(&ui, frame.rows[index], span[:])
		}
		if index == paint_row {
			span := [?]alicorn.Text_Paint_Span{{
				start=0,
				end=len(texts[index]),
				color=alicorn.Color{0.9, 0.2, 0.1, 1},
				color_set=true,
			}}
			_ = alicorn.text_paint_spans(&ui, frame.rows[index], span[:])
		}
		_ = row
		alicorn.container_end(&ui)
	}
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
	return frame
}

@(test)
test_editor_row_trace_separates_text_style_geometry_and_paint_changes :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 640, 360})
	defer alicorn.destroy_runtime(&rt)
	fonts_loaded := alicorn.text_engine_load_font(&rt.text_engine, ALICORN_TEST_UI_FONT_DATA) &&
		alicorn.text_engine_load_font_role(&rt.text_engine, .Monospace, ALICORN_TEST_MONO_FONT_DATA)
	testing.expect(t, fonts_loaded, "row trace fixture should use the bundled test fonts")
	if !fonts_loaded { return }
	base_texts := [3]string{"unchanged one", "unchanged two", "unchanged three"}
	base := editor_row_trace_test_build(&rt, base_texts)
	targets := [?]Editor_Row_Target{
		{node=base.rows[0], logical_line=10},
		{node=base.rows[1], logical_line=11},
		{node=base.rows[2], logical_line=12},
	}
	base_fingerprints: [3]Editor_Row_Trace_Fingerprints
	for target, index in targets {
		fingerprints, _, found := editor_row_trace_fingerprints(&rt, target)
		testing.expect(t, found, "each realized source row should have traceable retained nodes and paint")
		base_fingerprints[index] = fingerprints
	}
	trace: Editor_Row_Trace_State
	trace_ready := editor_row_trace_init(&trace, "editor-row-trace-test.tsv", context.allocator)
	defer editor_row_trace_release(&trace)
	testing.expect(t, trace_ready, "row trace state should initialize for the automated per-row comparison")
	if !trace_ready { return }
	editor_row_trace_capture(&trace, &rt, targets[:], "fixture-document", 1, 1)
	if len(trace.records) >= 3 {
		testing.expect(t, !trace.records[0].compared_previous && !trace.records[1].compared_previous && !trace.records[2].compared_previous,
			"the first trace build should be recorded as a baseline, not as a change")
	}

	text_changed := [3]string{"modified one!", "unchanged two", "unchanged three"}
	text_frame := editor_row_trace_test_build(&rt, text_changed)
	text_fingerprints: [3]Editor_Row_Trace_Fingerprints
	for index in 0..<3 {
		fingerprints, _, found := editor_row_trace_fingerprints(&rt, Editor_Row_Target{node=text_frame.rows[index], logical_line=u64(10+index)})
		testing.expect(t, found, "row trace should resolve after a text-only description rebuild")
		text_fingerprints[index] = fingerprints
	}
	editor_row_trace_capture(&trace, &rt, targets[:], "fixture-document", 2, 1)
	testing.expect(t, trace.build_count == 2 && len(trace.records) == 6,
		"two captured descriptions should produce one record per visible row each")
	if len(trace.records) >= 6 {
		row_zero_changes := trace.records[3].changes
		row_one_changes := trace.records[4].changes
		row_two_changes := trace.records[5].changes
		testing.expect(t, .Text in row_zero_changes && .Paint in row_zero_changes && .Style not_in row_zero_changes && .Geometry not_in row_zero_changes,
			"trace records should attribute the edit to text and paint on its source row")
		testing.expect(t, row_one_changes == {} && row_two_changes == {},
			"trace records should prove unaffected visible source rows retain all visual fingerprints")
	}
	text_changes := editor_row_trace_changed(base_fingerprints[0], text_fingerprints[0])
	testing.expect(t, .Text in text_changes && .Paint in text_changes && .Style not_in text_changes && .Geometry not_in text_changes,
		"editing one fixed-size row should report text/paint change without style or geometry change")
	testing.expect(t, editor_row_trace_changed(base_fingerprints[1], text_fingerprints[1]) == {},
		"an unaffected sibling row must retain all four visual fingerprints")

	style_frame := editor_row_trace_test_build(&rt, text_changed, bold_row=1)
	style_fingerprints: [3]Editor_Row_Trace_Fingerprints
	for index in 0..<3 {
		fingerprints, _, found := editor_row_trace_fingerprints(&rt, Editor_Row_Target{node=style_frame.rows[index], logical_line=u64(10+index)})
		testing.expect(t, found, "row trace should resolve after a style-only description rebuild")
		style_fingerprints[index] = fingerprints
	}
	editor_row_trace_capture(&trace, &rt, targets[:], "fixture-document", 3, 2)
	style_changes := editor_row_trace_changed(text_fingerprints[1], style_fingerprints[1])
	testing.expect(t, .Style in style_changes && .Text not_in style_changes,
		"typography changes should be distinguishable from source text changes")
	testing.expect(t, editor_row_trace_changed(text_fingerprints[0], style_fingerprints[0]) == {},
		"changing another row's typography must not change the first row's fingerprints")
	if len(trace.records) >= 9 {
		testing.expect(t, .Style in trace.records[7].changes && .Text not_in trace.records[7].changes,
			"the trace should attribute a typography change to the correct visible row")
		testing.expect(t, trace.records[6].changes == {} && trace.records[8].changes == {},
			"a typography-only change must leave other visible rows unchanged")
	}

	paint_frame := editor_row_trace_test_build(&rt, text_changed, bold_row=1, paint_row=2)
	paint_fingerprints: [3]Editor_Row_Trace_Fingerprints
	for index in 0..<3 {
		fingerprints, _, found := editor_row_trace_fingerprints(&rt, Editor_Row_Target{node=paint_frame.rows[index], logical_line=u64(10+index)})
		testing.expect(t, found, "row trace should resolve after a paint-only description rebuild")
		paint_fingerprints[index] = fingerprints
	}
	editor_row_trace_capture(&trace, &rt, targets[:], "fixture-document", 4, 3)
	paint_changes := editor_row_trace_changed(style_fingerprints[2], paint_fingerprints[2])
	testing.expect(t, .Paint in paint_changes && .Text not_in paint_changes && .Style not_in paint_changes && .Geometry not_in paint_changes,
		"foreground decoration changes should be isolated to the paint fingerprint")
	if len(trace.records) >= 12 {
		testing.expect(t, .Paint in trace.records[11].changes && .Text not_in trace.records[11].changes &&
			.Style not_in trace.records[11].changes && .Geometry not_in trace.records[11].changes,
			"the trace should attribute a foreground paint change to its source row")
		testing.expect(t, trace.records[9].changes == {} && trace.records[10].changes == {},
			"a foreground paint change must leave other visible rows unchanged")
	}

	geometry_frame := editor_row_trace_test_build(&rt, text_changed, bold_row=1, paint_row=2, tall_row=2)
	geometry, _, geometry_found := editor_row_trace_fingerprints(&rt, Editor_Row_Target{node=geometry_frame.rows[2], logical_line=12})
	testing.expect(t, geometry_found, "row trace should resolve after a row-height change")
	editor_row_trace_capture(&trace, &rt, targets[:], "fixture-document", 5, 4)
	if geometry_found {
		geometry_changes := editor_row_trace_changed(paint_fingerprints[2], geometry)
		testing.expect(t, .Geometry in geometry_changes,
			"row bounds and clip changes should be identified independently from source/style")
	}
	if len(trace.records) >= 15 {
		testing.expect(t, .Geometry in trace.records[14].changes,
			"the trace should attribute a bounds change to its source row")
	}
}

@(test)
test_editor_wrap_fingerprint_distinguishes_fractional_inputs :: proc(t: ^testing.T) {
	window := Editor_Window{}
	line := Editor_Display_Line{logical_line=1, display="a wrapped line"}
	width_a := editor_wrap_line_measurement_fingerprint(&window, &line, 200.001, true, false, 1)
	width_b := editor_wrap_line_measurement_fingerprint(&window, &line, 200.002, true, false, 1)
	testing.expect(t, width_a != width_b, "fractional viewport widths must not collide in the row-measurement cache")
	scale_a := editor_wrap_line_measurement_fingerprint(&window, &line, 200, true, false, 1.0001)
	scale_b := editor_wrap_line_measurement_fingerprint(&window, &line, 200, true, false, 1.0002)
	testing.expect(t, scale_a != scale_b, "fractional text scales must not collide in the row-measurement cache")
	threshold_a := editor_wrap_line_measurement_fingerprint(&window, &line, 200.004, true, false, 1)
	threshold_b := editor_wrap_line_measurement_fingerprint(&window, &line, 200.006, true, false, 1)
	testing.expect(t, threshold_a != threshold_b, "near-threshold width inputs must retain exact cache identity")

	heading_bytes := [?]u8{'#', ' ', 'H', 'e', 'a', 'd', 'i', 'n', 'g'}
	heading_source := string(heading_bytes[:])
	heading_line := Editor_Display_Line{logical_line=1, source_start=0, source_end=u64(len(heading_source)), display=heading_source}
	heading_records := [?]bridge.Presentation_Record{{
		kind=EDITOR_PRESENTATION_HEADING,
		start_byte=0,
		end_byte=u32(len(heading_source)),
		level_flags=1,
	}}
	heading_window := Editor_Window{
		editor_revision=1,
		presentation_revision=1,
		presentation_ready=true,
		presentation_spans=heading_records[:],
		source=heading_bytes[:],
	}
	heading_h1 := editor_wrap_line_measurement_fingerprint(&heading_window, &heading_line, 200, true, true, 1)
	heading_window.presentation_spans[0].level_flags = 2
	heading_h2 := editor_wrap_line_measurement_fingerprint(&heading_window, &heading_line, 200, true, true, 1)
	testing.expect(t, heading_h1 != heading_h2,
		"Markdown heading typography and its line-height policy must invalidate the measured-row cache")

	table_bytes := [?]u8{'|', ' ', 'a', ' ', '|', ' ', 'l', 'o', 'n', 'g', ' ', '|'}
	table_source := string(table_bytes[:])
	table_line := Editor_Display_Line{logical_line=1, source_start=0, source_end=u64(len(table_source)), display=table_source}
	table_records := [?]bridge.Presentation_Record{{
		kind=EDITOR_PRESENTATION_BLOCK_TABLE,
		start_byte=0,
		end_byte=u32(len(table_source)),
		level_flags=2,
	}}
	table_window := Editor_Window{
		editor_revision=3,
		presentation_revision=3,
		presentation_ready=true,
		presentation_blocks=table_records[:],
		source=table_bytes[:],
		table_plan_cache_valid=true,
		table_plan_cache_start=0,
		table_plan_cache_end=u64(len(table_source)),
		table_plan_cache_revision=3,
		table_plan_cache_presentation_revision=3,
		table_plan_cache_width=200.006,
		table_plan_cache_text_scale=1,
		table_plan_cache_wraps=true,
		table_plan_cache_width_count=2,
	}
	table_window.table_plan_cache_widths[0] = 72.001
	table_window.table_plan_cache_widths[1] = 128.005
	table_a := editor_wrap_line_measurement_fingerprint(&table_window, &table_line, 200.006, true, true, 1)
	table_window.table_plan_cache_widths[0] = 72.002
	table_b := editor_wrap_line_measurement_fingerprint(&table_window, &table_line, 200.006, true, true, 1)
	testing.expect(t, table_a != table_b,
		"fractional shared table-column widths must invalidate every dependent row measurement")
}
