package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import alicorn "alicorn:runtime"
import bridge "./bridge"

UI_DOGFOOD_WARMUP_BUILDS :: 2
UI_DOGFOOD_MEASURED_BUILDS :: 32
UI_DOGFOOD_IDLE_ATTEMPTS :: 8

Ui_Dogfood_Build :: proc(app: ^App, rt: ^alicorn.Runtime) -> bool

Ui_Dogfood_Scene :: struct {
	name: string,
	build: Ui_Dogfood_Build,
}

ui_dogfood_build_settings_appearance :: proc(app: ^App, rt: ^alicorn.Runtime) -> bool {
	app.settings_surface_open = true
	app.settings_category = .Appearance
	return settings_test_build(app, rt, 1)
}

ui_dogfood_build_settings_editor :: proc(app: ^App, rt: ^alicorn.Runtime) -> bool {
	app.settings_surface_open = true
	app.settings_category = .Editor
	return settings_test_build(app, rt, 1)
}

ui_dogfood_build_document_status :: proc(app: ^App, rt: ^alicorn.Runtime) -> bool {
	if !scratchpad_styles_ensure(app, rt) { return false }
	ui, should_build := alicorn.begin_frame(rt)
	if !should_build { return false }
	alicorn.container_begin(&ui, .Root, key="ui-dogfood-document-root", style=alicorn.layout_style(.Column, grow=1))
	scope := alicorn.style_environment_push(&ui, scratchpad_workbench_style_environment(app))
	if len(app.backend.state.documents) > 0 {
		build_document_status(app, &ui, rt, app.backend.state.documents[0])
	}
	alicorn.style_environment_pop(&ui, scope)
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
	return true
}

ui_dogfood_build_startup_recent :: proc(app: ^App, rt: ^alicorn.Runtime) -> bool {
	if !scratchpad_styles_ensure(app, rt) { return false }
	app.recent_workspaces_open = true
	ui, should_build := alicorn.begin_frame(rt)
	if !should_build { return false }
	alicorn.container_begin(&ui, .Root, key="ui-dogfood-startup-root", style=alicorn.layout_style(.Column, grow=1, clip=true))
	scope := alicorn.style_environment_push(&ui, scratchpad_workbench_style_environment(app))
	build_start_screen(app, &ui, rt)
	alicorn.container_end(&ui)
	recent_workspaces_surface_build(app, &ui, rt)
	alicorn.style_environment_pop(&ui, scope)
	alicorn.end_frame(&ui)
	return true
}

ui_dogfood_scene_node_path_append :: proc(
	rt: ^alicorn.Runtime,
	node_id: alicorn.Node_ID,
	sb: ^strings.Builder,
	depth: int = 0,
) {
	if depth > 64 {
		fmt.sbprintf(sb, "/<depth-limit>")
		return
	}
	node, found := rt.nodes[node_id]
	if !found {
		fmt.sbprintf(sb, "/<missing>")
		return
	}
	if node.parent != 0 {
		ui_dogfood_scene_node_path_append(rt, node.parent, sb, depth+1)
	}
	sibling_index := -1
	if parent, parent_found := rt.nodes[node.parent]; parent_found {
		for child_id, index in parent.children {
			if child_id == node_id { sibling_index = index; break }
		}
	}
	if node.explicit_key {
		switch node.identity_key_kind {
		case 1:
			fmt.sbprintf(sb, "/%v[key=%q]@%d", node.kind, node.key, sibling_index)
		case 2:
			fmt.sbprintf(sb, "/%v[key=#%d]@%d", node.kind, node.identity_key_u64, sibling_index)
		case 3:
			fmt.sbprintf(sb, "/%v[key=(%d,%d)]@%d", node.kind,
				node.identity_key_pair.first, node.identity_key_pair.second, sibling_index)
		case:
			fmt.sbprintf(sb, "/%v[key=<explicit>]@%d", node.kind, sibling_index)
		}
	} else if node.label != "" {
		fmt.sbprintf(sb, "/%v[label=%q]@%d", node.kind, node.label, sibling_index)
	} else {
		fmt.sbprintf(sb, "/%v[@%d]", node.kind, sibling_index)
	}
}

ui_dogfood_scene_node_path :: proc(rt: ^alicorn.Runtime, node_id: alicorn.Node_ID) -> string {
	sb := strings.builder_make(0, 96, context.temp_allocator)
	ui_dogfood_scene_node_path_append(rt, node_id, &sb)
	return strings.to_string(sb)
}

ui_dogfood_scene_payload_name :: proc(paint_payload: alicorn.Paint_Payload) -> string {
	switch payload in paint_payload {
	case alicorn.Surface_Paint: return "surface"
	case alicorn.Icon_Paint: return "icon"
	case alicorn.Image_Paint: return "image"
	case alicorn.Text_Paint: return "text"
	case alicorn.Geometry_Paint: return "geometry"
	}
	return "unknown"
}

ui_dogfood_scene_append_paint :: proc(
	sb: ^strings.Builder,
	owner_path: string,
	paint_index: int,
	command: alicorn.Paint_Command,
) {
	fmt.sbprintf(sb,
		"PAINT owner=%q index=%d kind=%s bounds=%v clip=%v opacity=%.4f translation=%v stroke_placement=%v ",
		owner_path, paint_index, ui_dogfood_scene_payload_name(command.payload),
		command.bounds, command.clip, command.opacity, command.translation, command.stroke_placement)
	switch payload in command.payload {
	case alicorn.Surface_Paint:
		fmt.sbprintf(sb, "shape=%v fill=%v stroke=%v material=%d height=%.3f group=%d\n",
			payload.shape, payload.fill, payload.stroke, u32(payload.material),
			payload.physical_height, u32(payload.material_group))
	case alicorn.Icon_Paint:
		fmt.sbprintf(sb, "icon=%v color=%v\n", payload.id, payload.color)
	case alicorn.Image_Paint:
		fmt.sbprintf(sb, "image_resource=present\n")
	case alicorn.Text_Paint:
		fmt.sbprintf(sb, "text_color=%v span_count=%d run_source=%v\n",
			payload.color, len(payload.spans), payload.run.source)
		for span, span_index in payload.spans {
			fmt.sbprintf(sb,
				"TEXT_SPAN owner=%q paint=%d span=%d bytes=%d..%d color=%v color_set=%t underline=%t strike=%t background=%v background_set=%t\n",
				owner_path, paint_index, span_index, span.start, span.end, span.color,
				span.color_set, span.underline, span.strikethrough, span.background,
				span.background_set)
		}
	case alicorn.Geometry_Paint:
		fmt.sbprintf(sb, "geometry_resource=present\n")
	}
}

ui_dogfood_scene_semantic_order :: proc(nodes: []alicorn.Semantic_Node, id: alicorn.Semantic_ID) -> int {
	if id == {} { return -1 }
	for candidate, index in nodes {
		if candidate.id == id { return index }
	}
	return -1
}

ui_dogfood_scene_snapshot :: proc(scene_name: string, rt: ^alicorn.Runtime) -> string {
	sb := strings.builder_make(0, 16384, context.temp_allocator)
	active_nodes, node_paints := 0, 0
	for node_id in rt.order {
		node, found := rt.nodes[node_id]
		if !found { continue }
		if node.active && node.present { active_nodes += 1 }
		node_paints += len(node.paint)
	}
	fmt.sbprintf(&sb,
		"SCENE name=%q viewport=%v retained_nodes=%d ordered_nodes=%d active_nodes=%d node_paints=%d display_paints=%d semantic_nodes=%d\n",
		scene_name, rt.viewport, len(rt.nodes), len(rt.order), active_nodes, node_paints,
		len(rt.display), len(rt.semantic_entities))
	for node_id, order in rt.order {
		node, found := rt.nodes[node_id]
		if !found { continue }
		path := ui_dogfood_scene_node_path(rt, node_id)
		parent_path := ""
		if node.parent != 0 { parent_path = ui_dogfood_scene_node_path(rt, node.parent) }
		fmt.sbprintf(&sb,
		"NODE order=%d path=%q parent=%q kind=%v children=%d key=%q explicit_key=%t label=%q text=%q active=%t present=%t focusable=%t disabled=%t selected=%t hovered=%t pressed=%t semantic_active=%t bounds=%v clip=%v color=%v background=%t style=%v text_style=%v font=%v button_variant=%v button_content=%v\n",
		order, path, parent_path, node.kind, len(node.children), node.key, node.explicit_key, node.label, node.text,
			node.active, node.present, node.focusable, node.disabled, node.selected, node.hovered,
			node.pressed, node.semantic_active, node.bounds, node.clip, node.color,
			node.paint_background, node.style, node.text_style, node.font,
			node.button_variant, node.button_content_style)
		for command, paint_index in node.paint {
			ui_dogfood_scene_append_paint(&sb, path, paint_index, command)
		}
		delete(path, context.temp_allocator)
		if parent_path != "" { delete(parent_path, context.temp_allocator) }
	}
	for command, display_index in rt.display {
		if command.owner != 0 {
			owner_path := ui_dogfood_scene_node_path(rt, command.owner)
			ui_dogfood_scene_append_paint(&sb, owner_path, display_index, command)
			delete(owner_path, context.temp_allocator)
		} else {
			ui_dogfood_scene_append_paint(&sb,
				"<owner-root>", display_index, command)
		}
	}
	semantics := alicorn.semantic_snapshot(rt, context.temp_allocator)
	defer alicorn.semantic_snapshot_destroy(&semantics)
	focused_semantic_order := ui_dogfood_scene_semantic_order(semantics.nodes[:], semantics.keyboard_focus)
	for semantic, index in semantics.nodes {
		visual_path, parent_semantic_index := "", -1
		if semantic.visual_node != 0 { visual_path = ui_dogfood_scene_node_path(rt, semantic.visual_node) }
		parent_semantic_index = ui_dogfood_scene_semantic_order(semantics.nodes[:], semantic.parent)
		fmt.sbprintf(&sb,
			"SEMANTIC order=%d visual=%q parent_order=%d role=%v label=%q description=%q value=%q states=%v actions=%v bounds=%v has_bounds=%t collection=%t logical_count=%d realized=%d..%d selected_order=%d current_order=%d collection_order=%d position=%d size=%d virtual=%t numeric=%t:%g:%g:%g:%g live=%v live_atomic=%t text_selection=%t:%d:%d\n",
			index, visual_path, parent_semantic_index, semantic.role, semantic.label,
			semantic.description, semantic.value, semantic.states, semantic.actions,
			semantic.bounds, semantic.has_bounds, semantic.is_collection, semantic.logical_count,
			semantic.realized_first, semantic.realized_last,
			ui_dogfood_scene_semantic_order(semantics.nodes[:], semantic.selected_id),
			ui_dogfood_scene_semantic_order(semantics.nodes[:], semantic.current_id),
			ui_dogfood_scene_semantic_order(semantics.nodes[:], semantic.collection_id),
			semantic.position_in_set, semantic.size_of_set, semantic.is_virtual_item, semantic.has_numeric_value,
			semantic.numeric_value, semantic.numeric_minimum, semantic.numeric_maximum,
			semantic.numeric_step, semantic.live, semantic.live_atomic,
			semantic.text_selection.valid,
			ui_dogfood_scene_semantic_order(semantics.nodes[:], semantic.text_selection.anchor.run_id),
			ui_dogfood_scene_semantic_order(semantics.nodes[:], semantic.text_selection.focus.run_id))
		if visual_path != "" { delete(visual_path, context.temp_allocator) }
	}
	fmt.sbprintf(&sb, "SEMANTIC_FOCUS order=%d\n", focused_semantic_order)
	return strings.to_string(sb)
}

ui_dogfood_scene_ids_match :: proc(rt: ^alicorn.Runtime, expected: []alicorn.Node_ID) -> bool {
	if len(rt.order) != len(expected) { return false }
	for node_id, index in rt.order {
		if node_id != expected[index] { return false }
	}
	return true
}

ui_dogfood_scene_semantic_ids_match :: proc(rt: ^alicorn.Runtime, expected: []alicorn.Semantic_ID) -> bool {
	snapshot := alicorn.semantic_snapshot(rt, context.temp_allocator)
	defer alicorn.semantic_snapshot_destroy(&snapshot)
	if len(snapshot.nodes) != len(expected) { return false }
	for node, index in snapshot.nodes {
		if node.id != expected[index] { return false }
	}
	return true
}

ui_dogfood_scene_measure :: proc(
	t: ^testing.T,
	scene: Ui_Dogfood_Scene,
	artifact: ^strings.Builder,
) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 1024, 768})
	defer alicorn.destroy_runtime(&rt)
	app: App
	document := bridge.State_Document{
		id="dogfood-document",
		path="/workspace/src/document.go",
		status="open",
		editor_revision=17,
		line_count=137,
		byte_length=4096,
		language="go",
		view_kind="text",
	}
	documents := [?]bridge.State_Document{document}
	recent_workspaces := [?]string{
		"/workspaces/alicorn",
		"/workspaces/scratchpad",
		"/workspaces/scratchpad/examples",
	}
	app.backend.state.recent_workspaces = recent_workspaces[:]
	app.editor_views = make([dynamic]Editor_View_State, 0, allocator=context.allocator)
	defer editor_views_destroy(&app.editor_views, context.allocator)
	if scene.name == "document-status" {
		app.backend.state.documents = documents[:]
		app.backend.state.active = document.id
	}
	if !alicorn.text_engine_load_font(&rt.text_engine, ALICORN_TEST_UI_FONT_DATA) ||
	   !alicorn.text_engine_load_font_role(&rt.text_engine, .Monospace, ALICORN_TEST_MONO_FONT_DATA) {
		testing.expect(t, false, fmt.tprintf("%s fixture fonts must load", scene.name))
		return
	}
	if !scene.build(&app, &rt) {
		testing.expect(t, false, fmt.tprintf("%s scene should build", scene.name))
		return
	}
	// No GPU host is attached; acknowledge the completed display at the same
	// boundary where the native host reports a successful submission.
	alicorn.frame_submission_succeeded(&rt)
	testing.expect(t, !rt.frame_open && len(rt.stack) == 0 && len(rt.identity_stack) == 0 &&
		len(rt.style_scope_stack) == 0 && len(rt.adaptive_description_scopes) == 0,
		fmt.tprintf("%s scene must close its frame and retained scopes", scene.name))
	for _ in 0..<UI_DOGFOOD_WARMUP_BUILDS {
		alicorn.invalidate_root(&rt, "UI API dogfood warm-up")
		built := scene.build(&app, &rt)
		if built { alicorn.frame_submission_succeeded(&rt) }
		testing.expect(t, built && !rt.frame_open && len(rt.stack) == 0 && len(rt.identity_stack) == 0 &&
			len(rt.style_scope_stack) == 0 && len(rt.adaptive_description_scopes) == 0,
			fmt.tprintf("%s warm-up description must build and balance scopes", scene.name))
	}
	baseline_snapshot := ui_dogfood_scene_snapshot(scene.name, &rt)
	defer delete(baseline_snapshot, context.temp_allocator)
	node_ids := make([dynamic]alicorn.Node_ID, 0, len(rt.order), allocator=context.temp_allocator)
	append(&node_ids, ..rt.order[:])
	defer delete(node_ids)
	semantic_snapshot := alicorn.semantic_snapshot(&rt, context.temp_allocator)
	semantic_ids := make([dynamic]alicorn.Semantic_ID, 0, len(semantic_snapshot.nodes), allocator=context.temp_allocator)
	for semantic in semantic_snapshot.nodes { append(&semantic_ids, semantic.id) }
	defer {
		delete(semantic_ids)
		alicorn.semantic_snapshot_destroy(&semantic_snapshot)
	}

	allocations_before := rt.allocation_stats^
	// Frame_Stats counters are cumulative, so subtract this warmed baseline.
	layout_before := rt.stats.layout_nodes_visited
	samples: [UI_DOGFOOD_MEASURED_BUILDS]i64
	for index in 0..<UI_DOGFOOD_MEASURED_BUILDS {
		start := time.tick_now()
		alicorn.invalidate_root(&rt, "UI API dogfood measured warm rebuild")
		built := scene.build(&app, &rt)
		samples[index] = time.duration_nanoseconds(time.tick_since(start))
		if built { alicorn.frame_submission_succeeded(&rt) }
		testing.expect(t, built && !rt.frame_open && len(rt.stack) == 0 && len(rt.identity_stack) == 0 &&
			len(rt.style_scope_stack) == 0 && len(rt.adaptive_description_scopes) == 0,
			fmt.tprintf("%s measured rebuild %d must build and balance scopes", scene.name, index))
		testing.expect(t, ui_dogfood_scene_ids_match(&rt, node_ids[:]),
			fmt.tprintf("%s retained node IDs/order must remain stable at rebuild %d", scene.name, index))
		testing.expect(t, ui_dogfood_scene_semantic_ids_match(&rt, semantic_ids[:]),
			fmt.tprintf("%s semantic IDs/order must remain stable at rebuild %d", scene.name, index))
	}
	slice.sort(samples[:])
	p95_index := (len(samples)*95+99)/100 - 1
	persistent_bytes_delta := rt.allocation_stats.persistent_requested_bytes_live - allocations_before.persistent_requested_bytes_live
	persistent_alloc_calls_delta := rt.allocation_stats.persistent_alloc_calls - allocations_before.persistent_alloc_calls
	persistent_free_calls_delta := rt.allocation_stats.persistent_free_calls - allocations_before.persistent_free_calls
	layout_visits_delta := rt.stats.layout_nodes_visited - layout_before
	final_snapshot := ui_dogfood_scene_snapshot(scene.name, &rt)
	defer delete(final_snapshot, context.temp_allocator)
	testing.expect(t, baseline_snapshot == final_snapshot,
		fmt.tprintf("%s node/style/bounds/semantics/paint snapshot should be deterministic across warm rebuilds", scene.name))

	fmt.sbprintf(artifact,
		"METRICS scene=%q warm_rebuilds=%d retained_nodes=%d ordered_nodes=%d display_paints=%d persistent_live_delta=%d persistent_alloc_calls=%d persistent_free_calls=%d layout_visits=%d\n",
		scene.name, UI_DOGFOOD_MEASURED_BUILDS, len(rt.nodes), len(rt.order), len(rt.display),
		persistent_bytes_delta, persistent_alloc_calls_delta, persistent_free_calls_delta,
		layout_visits_delta)
	fmt.println("UI_DOGFOOD scene=", scene.name,
		" warm_rebuilds=", UI_DOGFOOD_MEASURED_BUILDS,
		" persistent_live_delta=", persistent_bytes_delta,
		" persistent_alloc_calls=", persistent_alloc_calls_delta,
		" layout_visits=", layout_visits_delta,
		" local_p95_ns=", samples[p95_index])
	fmt.sbprintf(artifact, "%s", final_snapshot)

	stats_before_idle := rt.stats
	allocations_before_idle := rt.allocation_stats^
	presentation_before_idle := rt.presentation_revision
	submitted_before_idle := rt.submitted_revision
	display_count_before_idle := len(rt.display)
	for index in 0..<UI_DOGFOOD_IDLE_ATTEMPTS {
		_, should_build := alicorn.begin_frame(&rt)
		testing.expect(t, !should_build,
			fmt.tprintf("%s idle attempt %d must not request a description", scene.name, index))
		presentation_ui, should_present := alicorn.begin_presentation_frame(&rt)
		testing.expect(t, !should_present,
			fmt.tprintf("%s idle attempt %d must not request retained presentation", scene.name, index))
		if should_present { alicorn.end_presentation_frame(&presentation_ui) }
	}
	testing.expect(t, rt.stats.frames_built == stats_before_idle.frames_built &&
		rt.stats.descriptions_emitted == stats_before_idle.descriptions_emitted &&
		rt.stats.descriptions_reused == stats_before_idle.descriptions_reused &&
		rt.stats.reconcile_nodes_visited == stats_before_idle.reconcile_nodes_visited &&
		rt.stats.layout_nodes_visited == stats_before_idle.layout_nodes_visited &&
		rt.stats.paint_nodes_visited == stats_before_idle.paint_nodes_visited &&
		rt.stats.composition_nodes_visited == stats_before_idle.composition_nodes_visited &&
		rt.stats.measure_requests == stats_before_idle.measure_requests &&
		rt.stats.text_shape_requests == stats_before_idle.text_shape_requests &&
		rt.stats.paint_updates == stats_before_idle.paint_updates &&
		rt.stats.composite_updates == stats_before_idle.composite_updates &&
		rt.stats.semantic_descriptions_emitted == stats_before_idle.semantic_descriptions_emitted &&
		rt.stats.semantic_entities_resolved == stats_before_idle.semantic_entities_resolved &&
		rt.stats.idle_frames == stats_before_idle.idle_frames+UI_DOGFOOD_IDLE_ATTEMPTS,
		fmt.tprintf("%s idle attempts must add no descriptions, presentation work, or retained visits", scene.name))
	testing.expect(t, rt.presentation_revision == presentation_before_idle &&
		rt.submitted_revision == submitted_before_idle && len(rt.display) == display_count_before_idle,
		fmt.tprintf("%s idle attempts must not change composed or submitted presentation", scene.name))
	testing.expect(t, rt.allocation_stats.persistent_requested_bytes_live == allocations_before_idle.persistent_requested_bytes_live &&
		rt.allocation_stats.persistent_requested_bytes_peak == allocations_before_idle.persistent_requested_bytes_peak &&
		rt.allocation_stats.persistent_alloc_calls == allocations_before_idle.persistent_alloc_calls &&
		rt.allocation_stats.persistent_free_calls == allocations_before_idle.persistent_free_calls &&
		rt.allocation_stats.scratch_alloc_calls == allocations_before_idle.scratch_alloc_calls &&
		rt.allocation_stats.scratch_requested_bytes_epoch == allocations_before_idle.scratch_requested_bytes_epoch &&
		rt.allocation_stats.scratch_requested_bytes_peak == allocations_before_idle.scratch_requested_bytes_peak &&
		rt.allocation_stats.scratch_resets == allocations_before_idle.scratch_resets,
		fmt.tprintf("%s idle attempts must perform no tracked persistent or scratch allocations", scene.name))
}

@(test)
test_ui_api_dogfood_before_after_harness :: proc(t: ^testing.T) {
	scenes := [4]Ui_Dogfood_Scene{
		{name="settings-appearance", build=ui_dogfood_build_settings_appearance},
		{name="settings-editor", build=ui_dogfood_build_settings_editor},
		{name="document-status", build=ui_dogfood_build_document_status},
		{name="startup-recent-workspaces", build=ui_dogfood_build_startup_recent},
	}
	artifact := strings.builder_make(0, 32768, context.temp_allocator)
	defer strings.builder_destroy(&artifact)
	fmt.sbprintln(&artifact, "scratchpad-ui-api-dogfood-v1")
	for scene in scenes { ui_dogfood_scene_measure(t, scene, &artifact) }
	artifact_text := strings.to_string(artifact)
	if path, found := os.lookup_env_alloc("SCRATCHPAD_UI_API_DOGFOOD_ARTIFACT", context.allocator); found && path != "" {
		defer delete(path, context.allocator)
		if err := os.write_entire_file_from_string(path, artifact_text); err != nil {
			testing.expect(t, false, fmt.tprintf("could not write UI dogfood artifact %q: %v", path, err))
		}
	}
}
