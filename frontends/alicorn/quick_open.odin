package main

import "core:fmt"
import "core:strings"
import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"
import bridge "./bridge"

QUICK_OPEN_MAX_VISIBLE_ROWS :: 10
QUICK_OPEN_ROW_HEIGHT :: f32(36)

Quick_Open_Result :: struct {
	path: string,
	score: int,
	order: int,
}

quick_open_cache_clear :: proc(app: ^App) {
	if app == nil { return }
	for &path in app.quick_open_paths { delete(path, context.allocator) }
	delete(app.quick_open_paths)
	app.quick_open_paths = {}
	if len(app.quick_open_path_root) > 0 { delete(app.quick_open_path_root, context.allocator) }
	app.quick_open_path_root = ""
	app.quick_open_truncated = false
	app.quick_open_ready = false
	app.quick_open_loading = false
	app.quick_open_generation = 0
}

quick_open_request_index :: proc(app: ^App) {
	if app == nil || !app.backend.started || !app.backend.state.has_workspace { return }
	root := app.backend.state.workspace_root
	if app.quick_open_ready && app.quick_open_path_root == root { return }
	if app.quick_open_loading && app.quick_open_path_root == root { return }
	if app.quick_open_path_root != root { quick_open_cache_clear(app) }
	root_copy, clone_error := strings.clone(root, context.allocator)
	if clone_error != nil {
		find_set_message(&app.quick_open_error, "Could not retain the workspace identity for Quick Open.")
		return
	}
	generation, accepted := bridge.workspace_files_lane_request(&app.quick_open_lane, root)
	if !accepted {
		delete(root_copy, context.allocator)
		find_set_message(&app.quick_open_error, "The Quick Open path index is still being prepared.")
		return
	}
	if len(app.quick_open_path_root) > 0 { delete(app.quick_open_path_root, context.allocator) }
	app.quick_open_path_root = root_copy
	app.quick_open_generation = generation
	app.quick_open_loading = true
	find_set_message(&app.quick_open_error, "")
}

quick_open_invalidate_index :: proc(app: ^App) {
	if app == nil { return }
	quick_open_cache_clear(app)
	if app.quick_open_open { quick_open_request_index(app) }
}

quick_open_take_completion :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil { return }
	result, found := bridge.workspace_files_lane_take(&app.quick_open_lane)
	if !found { return }
	defer bridge.workspace_files_lane_result_destroy(&result, context.allocator)
	if result.generation != app.quick_open_generation || result.workspace_root != app.backend.state.workspace_root {
		if app.quick_open_path_root != app.backend.state.workspace_root { quick_open_cache_clear(app) }
		if app.quick_open_open { quick_open_request_index(app) }
		return
	}
	app.quick_open_loading = false
	if result.error != "" {
		find_set_message(&app.quick_open_error, result.error)
	} else if result.files_owned {
		root_copy, clone_error := strings.clone(result.workspace_root, context.allocator)
		if clone_error != nil {
			quick_open_cache_clear(app)
			find_set_message(&app.quick_open_error, "Could not retain the workspace identity for Quick Open results.")
			if rt != nil { alicorn.invalidate_root(rt, "Scratchpad Quick Open result identity allocation failed") }
			return
		}
		quick_open_cache_clear(app)
		app.quick_open_generation = result.generation
		app.quick_open_path_root = root_copy
		app.quick_open_paths = result.files.paths
		app.quick_open_truncated = result.files.truncated
		app.quick_open_ready = true
		result.files.paths = {}
		result.files_owned = false
		app.quick_open_selected_index = 0
		find_set_message(&app.quick_open_error, "")
	} else {
		find_set_message(&app.quick_open_error, "Scratchpad returned an invalid Quick Open path index.")
	}
	if rt != nil { alicorn.invalidate_root(rt, "Scratchpad Quick Open path index completed") }
}

quick_open_open_surface :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil || !app.backend.started || app.shutdown_intent != .None ||
	   app.close_document_id != "" || app.workspace_mutation_kind != .None ||
	   app.settings_surface_open || app.go_to_line_open {
		return
	}
	if !app.backend.state.has_workspace {
		request_file_dialog(app, rt, .Open_File, "Open File")
		return
	}
	if app.quick_open_open {
		quick_open_close_surface(app, rt, true)
		return
	}
	if app.command_palette_open { command_palette_close_surface(app, rt, false) }
	app.quick_open_previous_focus = alicorn.focused_node(rt)
	app.quick_open_open = true
	app.quick_open_focus_pending = true
	app.quick_open_restore_pending = false
	app.quick_open_node = 0
	app.quick_open_results_scroll_node = 0
	app.quick_open_selected_index = 0
	find_set_message(&app.quick_open_query, "")
	find_set_message(&app.quick_open_error, "")
	quick_open_request_index(app)
	alicorn.invalidate_root(rt, "Scratchpad Quick Open opened")
}

quick_open_close_surface :: proc(app: ^App, rt: ^alicorn.Runtime, restore_focus: bool) {
	if app == nil { return }
	app.quick_open_open = false
	app.quick_open_focus_pending = false
	app.quick_open_restore_pending = restore_focus
	app.quick_open_node = 0
	app.quick_open_results_scroll_node = 0
	find_set_message(&app.quick_open_query, "")
	if rt != nil { alicorn.invalidate_root(rt, "Scratchpad Quick Open closed") }
}

quick_open_restore_focus_after_frame :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil { return }
	if app.quick_open_open && app.quick_open_focus_pending && app.quick_open_node != 0 {
		if alicorn.focus(rt, app.quick_open_node) {
			app.quick_open_focus_pending = false
			if text, found := alicorn.text_field_value(rt, app.quick_open_node); found {
				_ = alicorn.set_text_selection(rt, app.quick_open_node, 0, len(text))
			}
		}
	}
	if !app.quick_open_restore_pending { return }
	app.quick_open_restore_pending = false
	focus := app.quick_open_previous_focus
	app.quick_open_previous_focus = 0
	if focus != 0 {
		if _, found := alicorn.node_info(rt, focus); found { _ = alicorn.focus(rt, focus) }
	}
}

quick_open_path_basename :: proc(path: string) -> string {
	start := 0
	for value, index in path {
		if value == '/' || value == '\\' { start = index+1 }
	}
	return path[start:]
}

quick_open_match_score :: proc(query, path: string) -> int {
	if len(query) == 0 { return 0 }
	total := 0
	position := 0
	for position < len(query) {
		for position < len(query) && (query[position] == ' ' || query[position] == '\t' || query[position] == '\n') { position += 1 }
		if position >= len(query) { break }
		start := position
		for position < len(query) && query[position] != ' ' && query[position] != '\t' && query[position] != '\n' { position += 1 }
		term := query[start:position]
		basename_score := command_palette_field_score(term, quick_open_path_basename(path))
		path_score := command_palette_field_score(term, path)
		best := max(basename_score+180, path_score+80)
		if basename_score < 0 && path_score < 0 { return -1 }
		total += best
	}
	return total
}

quick_open_result_precedes :: proc(left, right: Quick_Open_Result) -> bool {
	if left.score != right.score { return left.score > right.score }
	return left.order < right.order
}

quick_open_sort :: proc(results: []Quick_Open_Result) {
	// Shell sort keeps filtering the bounded 5,000-path index comfortably
	// subquadratic without relying on allocator-heavy general-purpose sorting.
	gap := len(results)/2
	for gap > 0 {
		for index := gap; index < len(results); index += 1 {
			value := results[index]
			position := index
			for position >= gap && quick_open_result_precedes(value, results[position-gap]) {
				results[position] = results[position-gap]
				position -= gap
			}
			results[position] = value
		}
		gap /= 2
	}
}

quick_open_filter :: proc(paths: []string, query: string, allocator := context.temp_allocator) -> [dynamic]Quick_Open_Result {
	results := make([dynamic]Quick_Open_Result, 0, min(len(paths), 512), allocator=allocator)
	for path, index in paths {
		score := quick_open_match_score(query, path)
		if score >= 0 { append(&results, Quick_Open_Result{path=path, score=score, order=index}) }
	}
	quick_open_sort(results[:])
	return results
}

quick_open_open_path :: proc(app: ^App, rt: ^alicorn.Runtime, path: string) {
	if app == nil || rt == nil || path == "" { return }
	if len(app.editor_edits) > 0 {
		if !deferred_action_enqueue(app, .Open_Path, path=path) {
			set_error(app, "Could not queue the selected file behind pending editor edits.")
			alicorn.invalidate_root(rt, "Scratchpad could not defer Quick Open selection")
		}
		return
	}
	response := bridge.backend_command(&app.backend, "open_path", path=path)
	handle_command_result(app, rt, &response)
	if response.ok { app.editor_focus_pending = true }
	bridge.backend_command_result_destroy(&response, context.allocator)
}

quick_open_execute :: proc(app: ^App, rt: ^alicorn.Runtime, path: string, from_build := false) -> bool {
	if app == nil || rt == nil || path == "" { return false }
	quick_open_close_surface(app, rt, false)
	if from_build {
		if !frame_deferred_action_schedule(app, .Open_Path, path) {
			set_error(app, "Could not queue the selected Quick Open file until this frame completes.")
			return false
		}
	} else {
		quick_open_open_path(app, rt, path)
	}
	return true
}

quick_open_move_selection :: proc(app: ^App, rt: ^alicorn.Runtime, direction: int) -> bool {
	if app == nil || rt == nil || !app.quick_open_open { return false }
	results := quick_open_filter(app.quick_open_paths, app.quick_open_query, context.temp_allocator)
	defer delete(results)
	if len(results) > 0 {
		app.quick_open_selected_index = clamp(app.quick_open_selected_index+direction, 0, len(results)-1)
		if app.quick_open_results_scroll_node != 0 {
			_ = alicorn.virtual_list_ensure_visible(rt, app.quick_open_results_scroll_node, app.quick_open_selected_index, "Scratchpad Quick Open selection visibility")
		}
	}
	alicorn.invalidate_root(rt, "Scratchpad Quick Open selection moved")
	return true
}

quick_open_execute_selected :: proc(app: ^App, rt: ^alicorn.Runtime, from_build := false) -> bool {
	if app == nil || rt == nil || !app.quick_open_open { return false }
	results := quick_open_filter(app.quick_open_paths, app.quick_open_query, context.temp_allocator)
	defer delete(results)
	if app.quick_open_selected_index < 0 || app.quick_open_selected_index >= len(results) { return true }
	return quick_open_execute(app, rt, results[app.quick_open_selected_index].path, from_build)
}

quick_open_text_change :: proc(state: rawptr, rt: ^alicorn.Runtime, change: alicorn.Text_Change) {
	app := cast(^App)state
	if app == nil || rt == nil || !app.quick_open_open || change.node != app.quick_open_node || !change.changed { return }
	find_set_message(&app.quick_open_query, change.text)
	app.quick_open_selected_index = 0
	alicorn.invalidate_root(rt, "Scratchpad Quick Open query changed")
}

quick_open_build :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime) {
	if app == nil || ui == nil || rt == nil || !app.quick_open_open { return }
	quick_open_request_index(app)
	results := quick_open_filter(app.quick_open_paths, app.quick_open_query, alicorn.runtime_scratch_allocator(rt))
	defer delete(results)
	if len(results) == 0 { app.quick_open_selected_index = 0
	} else { app.quick_open_selected_index = clamp(app.quick_open_selected_index, 0, len(results)-1) }
	visible_rows := min(max(len(results), 1), QUICK_OPEN_MAX_VISIBLE_ROWS)
	results_height := f32(visible_rows)*QUICK_OPEN_ROW_HEIGHT
	panel_height := f32(132)+results_height
	app.quick_open_overlay_node = alicorn.modal_overlay_begin(
		ui,
		alicorn.key_string("scratchpad-quick-open-overlay"),
		style=alicorn.layout_style(.Column, grow=1, padding=48, align=.Center, clip=true),
		backdrop_color=alicorn.Color{0.015, 0.02, 0.03, 0.72},
	)
	app.quick_open_panel_node = alicorn.surface_begin(
		ui,
		alicorn.surface_core_color_role(.Surface),
		label="scratchpad-quick-open-panel",
		key=alicorn.key_string("scratchpad-quick-open-panel"),
		style=alicorn.layout_style(.Column, max_width=760, height=panel_height, padding=12, gap=8, clip=true),
		material=app.floating_surface_material,
		physical_height=1,
	)
	alicorn.text(ui, "Quick Open", style=alicorn.layout_style(.Row, height=22))
	app.quick_open_node = alicorn.text_field(ui, app.quick_open_query, key=alicorn.key_string("scratchpad-quick-open-query"), style=alicorn.layout_style(.Row, height=38), text_style=alicorn.Text_Style{overflow=.Ellipsis})
	if app.quick_open_error != "" {
		alicorn.text(ui, app.quick_open_error, style=alicorn.layout_style(.Row, height=22))
	} else if app.quick_open_loading && !app.quick_open_ready {
		alicorn.text(ui, "Indexing workspace paths…", style=alicorn.layout_style(.Row, height=22))
	} else if len(results) == 0 {
		alicorn.text(ui, "No matching files", style=alicorn.layout_style(.Row, height=22))
	} else {
		list := alicorn.virtual_list_begin(ui, len(results), QUICK_OPEN_ROW_HEIGHT, key=alicorn.key_string("scratchpad-quick-open-results"), style=alicorn.layout_style(height=results_height, clip=true), label="scratchpad-quick-open-results")
		app.quick_open_results_scroll_node = list.scroll.id
		for index := list.first; index < list.last; index += 1 {
			result := results[index]
			if alicorn.button(ui, result.path, key=alicorn.key_string(result.path), style=alicorn.layout_style(.Row, height=QUICK_OPEN_ROW_HEIGHT), state=alicorn.Button_State{selected=index == app.quick_open_selected_index}, variant=.Quiet, text_style=alicorn.Text_Style{overflow=.Ellipsis}, content_style=alicorn.button_content_style(.Start, padding_x=9, padding_y=4)) {
				app.quick_open_selected_index = index
				_ = quick_open_execute(app, rt, result.path, true)
			}
		}
		alicorn.virtual_list_end(ui, list)
	}
	footer := fmt.tprintf("%d files  ·  ↑/↓ navigate  ·  Enter open  ·  Esc close", len(results))
	if app.quick_open_truncated { footer = fmt.tprintf("%s  ·  index capped at 5,000 files", footer) }
	alicorn.text(ui, footer, style=alicorn.layout_style(.Row, height=20))
	alicorn.surface_end(ui)
	alicorn.modal_overlay_end(ui)
}

quick_open_pointer :: proc(app: ^App, rt: ^alicorn.Runtime, event: alicorn.Pointer_Event, target: alicorn.Node_ID) -> bool {
	if app == nil || rt == nil || !app.quick_open_open { return false }
	if event.kind == .Down && event.button == alicorn.POINTER_BUTTON_PRIMARY && target == app.quick_open_overlay_node {
		panel, found := alicorn.node_info(rt, app.quick_open_panel_node)
		inside := found && event.x >= panel.bounds.x && event.x < panel.bounds.x+panel.bounds.w && event.y >= panel.bounds.y && event.y < panel.bounds.y+panel.bounds.h
		if !inside { quick_open_close_surface(app, rt, true) }
		return true
	}
	return true
}

quick_open_handle_key :: proc(app: ^App, rt: ^alicorn.Runtime, key: host.Application_Key) -> bool {
	if app == nil || rt == nil || !app.quick_open_open { return false }
	#partial switch key {
	case .Escape:
		quick_open_close_surface(app, rt, true)
		return true
	case .Return:
		if !app.quick_open_loading || app.quick_open_ready { return quick_open_execute_selected(app, rt) }
		return true
	case .Up:
		return quick_open_move_selection(app, rt, -1)
	case .Down:
		return quick_open_move_selection(app, rt, 1)
	case:
		return true
	}
}

quick_open_destroy :: proc(app: ^App) {
	if app == nil { return }
	quick_open_cache_clear(app)
	find_set_message(&app.quick_open_query, "")
	find_set_message(&app.quick_open_error, "")
}
