package main

import "core:strings"
import alicorn "alicorn:runtime"
import bridge "./bridge"

editor_accessibility_semantic_runs_remove :: proc(
	rt: ^alicorn.Runtime,
	area_id: alicorn.Semantic_ID,
	editor_revision: u64,
	run_count: int,
) {
	if rt == nil || area_id.namespace == 0 || run_count <= 0 { return }
	for ordinal in 0..<run_count {
		_ = alicorn.semantic_node_remove(rt, editor_accessibility_run_id(area_id, editor_revision, u64(ordinal)))
	}
}

editor_accessibility_retire :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil { return }
	has_projection_state := app.accessibility_semantic_area_id.namespace != 0 ||
	                        app.accessibility_semantic_run_count > 0 ||
	                        len(app.accessibility_projection.document_id) > 0 ||
	                        len(app.accessibility_source_error_document_id) > 0
	if !has_projection_state { return }
	accessibility_source_lane_cancel(&app.accessibility_source_lane)
	editor_accessibility_projection_destroy(&app.accessibility_projection)
	if rt != nil && app.accessibility_semantic_area_id.namespace != 0 {
		_ = alicorn.semantic_text_area_remove(rt, app.accessibility_semantic_area_id)
	}
	app.accessibility_semantic_area_id = {}
	app.accessibility_semantic_revision = 0
	app.accessibility_semantic_has_runs = false
	app.accessibility_semantic_run_count = 0
	editor_accessibility_clear_source_error(app)
}

editor_accessibility_projection_matches_document :: proc(
	projection: ^Editor_Accessibility_Projection,
	document: bridge.State_Document,
) -> bool {
	return projection != nil && projection.complete &&
	       projection.document_id == document.id &&
	       projection.editor_revision == document.editor_revision
}

editor_accessibility_clear_source_error :: proc(app: ^App) {
	if app == nil { return }
	if len(app.accessibility_source_error) > 0 { delete(app.accessibility_source_error, context.allocator) }
	if len(app.accessibility_source_error_document_id) > 0 { delete(app.accessibility_source_error_document_id, context.allocator) }
	app.accessibility_source_error = ""
	app.accessibility_source_error_document_id = ""
	app.accessibility_source_error_revision = 0
}

editor_accessibility_take_completion :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil { return }
	result, found := accessibility_source_lane_take(&app.accessibility_source_lane)
	if !found { return }
	defer accessibility_source_result_destroy(&result, app.accessibility_source_lane.allocator)
	if !app.backend.started { return }
	document, document_found := find_document(&app.backend.state, app.backend.state.active)
	if !document_found || result.request.document_id != document.id ||
	   result.request.editor_revision != document.editor_revision ||
	   result.request.byte_length != document.byte_length || result.request.line_count != document.line_count {
		return
	}
	if result.projection_owned {
		editor_accessibility_projection_destroy(&app.accessibility_projection)
		app.accessibility_projection = result.projection
		result.projection = {}
		result.projection_owned = false
		editor_accessibility_clear_source_error(app)
	} else {
		editor_accessibility_clear_source_error(app)
		app.accessibility_source_error, _ = strings.clone(result.error, context.allocator)
		app.accessibility_source_error_document_id, _ = strings.clone(document.id, context.allocator)
		app.accessibility_source_error_revision = document.editor_revision
	}
	if rt != nil { alicorn.invalidate_root(rt, "Scratchpad accessible document projection completed") }
}

editor_accessibility_document_has_pending_edit :: proc(app: ^App, document_id: string) -> bool {
	if app == nil { return false }
	for intent in app.editor_edits {
		if intent.document_id == document_id { return true }
	}
	return false
}

editor_accessibility_build_semantics :: proc(
	app: ^App,
	ui: ^alicorn.UI,
	rt: ^alicorn.Runtime,
	document: bridge.State_Document,
	area_node: alicorn.Node_ID,
	view: ^Editor_View_State,
) {
	if app == nil || ui == nil || rt == nil || view == nil || area_node == 0 || document.id == "" { return }
	if view.authoritative_revision == 0 && len(app.editor_edits) == 0 {
		view.authoritative_revision = document.editor_revision
	}
	area_id := editor_accessibility_area_id(document.id)
	area_changed := app.accessibility_semantic_area_id != area_id
	revision_changed := app.accessibility_semantic_revision != document.editor_revision
	semantic_identity_changed := area_changed || revision_changed
	if semantic_identity_changed {
		if area_changed && app.accessibility_semantic_area_id.namespace != 0 {
			_ = alicorn.semantic_text_area_remove(rt, app.accessibility_semantic_area_id)
			app.accessibility_semantic_has_runs = false
			app.accessibility_semantic_run_count = 0
		} else if revision_changed {
			editor_accessibility_semantic_runs_remove(
				rt,
				app.accessibility_semantic_area_id,
				app.accessibility_semantic_revision,
				app.accessibility_semantic_run_count,
			)
			app.accessibility_semantic_has_runs = false
			app.accessibility_semantic_run_count = 0
		}
		app.accessibility_semantic_area_id = area_id
		app.accessibility_semantic_revision = document.editor_revision
	}

	projection := &app.accessibility_projection
	projection_matches := editor_accessibility_projection_matches_document(projection, document)
	if len(projection.document_id) > 0 && !projection_matches {
		editor_accessibility_projection_destroy(projection)
		projection = &app.accessibility_projection
		projection_matches = false
	}

	error_matches := app.accessibility_source_error_document_id == document.id &&
	                 app.accessibility_source_error_revision == document.editor_revision
	lane_available := app.accessibility_source_lane.thread != nil
	if !projection_matches && !error_matches && lane_available {
		_, requested := accessibility_source_lane_request(
			&app.accessibility_source_lane,
			document.id,
			document.editor_revision,
			document.byte_length,
			document.line_count,
		)
		if !requested {
			editor_accessibility_clear_source_error(app)
			app.accessibility_source_error, _ = strings.clone("Could not start the accessible source-text read.", context.allocator)
			app.accessibility_source_error_document_id, _ = strings.clone(document.id, context.allocator)
			app.accessibility_source_error_revision = document.editor_revision
			error_matches = true
		}
	}

	pending_edit := editor_accessibility_document_has_pending_edit(app, document.id)
	view_revision_matches := view.authoritative_revision == document.editor_revision
	projection_usable := projection_matches && projection.supported && !pending_edit && view_revision_matches && view.optimistic_pending_edits == 0
	area_actions := alicorn.semantic_actions_add({}, .Focus)
	if projection_usable {
		area_actions = alicorn.semantic_actions_add(area_actions, .Set_Text_Selection)
		area_actions = alicorn.semantic_actions_add(area_actions, .Replace_Selected_Text)
	}
	area_states: alicorn.Semantic_States
	description := ""
	if pending_edit || !view_revision_matches {
		area_states = alicorn.semantic_states_add(area_states, .Busy)
		description = "Document text is synchronizing with the authoritative source."
	} else if projection_matches && !projection.supported {
		description = editor_accessibility_unsupported_reason_string(projection.unsupported_reason)
	} else if error_matches {
		description = app.accessibility_source_error
	} else if !lane_available && !projection_matches {
		description = "Accessible source-text worker is unavailable."
	} else if !projection_matches {
		area_states = alicorn.semantic_states_add(area_states, .Busy)
		description = "Accessible source text is loading."
	}
	area_label := document_title(document.path)
	if area_label == "" { area_label = "Document editor" }
	if !alicorn.semantic_describe_as(ui, editor_accessibility_area_id(document.id), .Text_Area, area_label,
	                                 description=description, states=area_states, actions=area_actions) {
		return
	}

	if !projection_usable {
		if app.accessibility_semantic_has_runs {
			editor_accessibility_semantic_runs_remove(
				rt,
				area_id,
				app.accessibility_semantic_revision,
				app.accessibility_semantic_run_count,
			)
			app.accessibility_semantic_has_runs = false
			app.accessibility_semantic_run_count = 0
		}
		return
	}

	if !app.accessibility_semantic_has_runs {
		for run, index in projection.runs {
			if !alicorn.semantic_text_run_set(rt, run.id, area_id, run.value, run.character_lengths, u64(index)) { return }
			app.accessibility_semantic_run_count = index+1
		}
		app.accessibility_semantic_has_runs = app.accessibility_semantic_run_count > 0
	}
	selection, selection_ok := editor_accessibility_source_selection_to_semantic(
		projection,
		view.selection_anchor,
		view.caret_byte,
	)
	if !selection_ok { selection = {} }
	_ = alicorn.semantic_text_area_selection_set(rt, area_id, selection)
}

editor_accessibility_requests_drain :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil { return }
	for {
		event, found := alicorn.semantic_request_pop(rt)
		if !found { break }
		if event.kind != .Perform || (event.action != .Set_Text_Selection && event.action != .Replace_Selected_Text) {
			alicorn.semantic_request_event_destroy(rt, &event)
			continue
		}
		document, document_found := find_document(&app.backend.state, app.backend.state.active)
		projection := &app.accessibility_projection
		if !document_found || event.id != projection.area_id ||
		   !editor_accessibility_projection_matches_document(projection, document) ||
		   !projection.supported || editor_accessibility_document_has_pending_edit(app, document.id) {
			alicorn.semantic_request_event_destroy(rt, &event)
			continue
		}
		view_index, view_found := editor_view_ensure(&app.editor_views, document.id)
		if !view_found {
			alicorn.semantic_request_event_destroy(rt, &event)
			continue
		}
		view := &app.editor_views[view_index]
		if view.authoritative_revision != document.editor_revision || view.optimistic_pending_edits != 0 ||
		   view.preedit_active || view.preedit_recoverable {
			alicorn.semantic_request_event_destroy(rt, &event)
			continue
		}
		if event.action == .Set_Text_Selection {
			anchor_byte, caret_byte, selection_ok := editor_accessibility_semantic_selection_to_source(projection, event.text_selection)
			if selection_ok {
				view.selection_anchor = anchor_byte
				view.caret_byte = caret_byte
				view.anchor_affinity = .Leading
				view.caret_affinity = .Trailing
				view.preferred_x_set = false
				editor_undo_group_break(view)
				if logical_line, line_ok := editor_accessibility_source_to_line(projection, caret_byte); line_ok {
					_ = editor_reveal_request_set(view, document.id, document.editor_revision,
					                             caret_byte, caret_byte, logical_line, .Nearest)
				}
				alicorn.invalidate_root(rt, "Scratchpad applied an accessible text selection")
			}
		} else if event.action == .Replace_Selected_Text && len(event.text_value) <= int(bridge.MAX_EDIT_BYTES) {
			start_byte := min(view.selection_anchor, view.caret_byte)
			end_byte := max(view.selection_anchor, view.caret_byte)
			if _, start_ok := editor_accessibility_projection_source_to_position(projection, start_byte); start_ok {
				if _, end_ok := editor_accessibility_projection_source_to_position(projection, end_byte); end_ok {
					logical_line, line_ok := editor_accessibility_source_to_line(projection, start_byte)
					if line_ok {
						replacement := transmute([]u8)event.text_value
						caret_after := start_byte+u64(len(replacement))
						_ = editor_apply_local_replace_with_wire(
							app, rt, start_byte, end_byte, replacement, nil,
							caret_after, caret_after, 0, "",
							allow_offscreen_authoritative=true,
							reveal_after_ack=true,
							reveal_logical_line=logical_line+editor_count_line_breaks(replacement),
						)
					}
				}
			}
		}
		alicorn.semantic_request_event_destroy(rt, &event)
	}
}
