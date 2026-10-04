package main

import "core:fmt"
import alicorn "alicorn:runtime"

build_app :: proc(
	state: rawptr,
	rt: ^alicorn.Runtime,
	logical_width, logical_height: int,
	dpi_scale: f32,
) -> alicorn.Node_ID {
	app := cast(^App)state
	ui, should_build := alicorn.begin_frame(rt)
	if !should_build { return 0 }
	_ = find_capture_text_field(rt, app.find_query_node, &app.find_query)
	_ = find_capture_text_field(rt, app.find_replace_node, &app.find_replace_text)
	_ = find_capture_text_field(rt, app.workspace_search_query_node, &app.workspace_search_query)
	app.workspace_search_results_owner = 0
	_ = find_capture_text_field(rt, app.workspace_mutation_name_node, &app.workspace_mutation_name)
	_ = find_capture_text_field(rt, app.go_to_line_query_node, &app.go_to_line_query)
	_ = find_capture_text_field(rt, app.command_palette_node, &app.command_palette_query)
	_ = find_capture_text_field(rt, app.quick_open_node, &app.quick_open_query)
	if app.find_open { find_refresh_if_needed(app, rt) }
	if app.workspace_search_mode { workspace_search_start_query(app, rt) }
	clear(&app.editor_row_targets)
	app.editor_input_anchor_node = 0
	if app.backend.started {
		sync_runtime_actions(app, rt)
		sync_menu_states(app)
	}

	root := alicorn.container_begin(
		&ui,
		.Root,
		label="scratchpad-alicorn-workbench",
		style=alicorn.layout_style(.Column, grow=1, gap=12, clip=true),
		color=COLOR_BACKGROUND,
	)

	if app.error_message != "" {
		alicorn.container_begin(&ui, .Container, label="workbench-error", style=alicorn.layout_style(.Column, height=132, padding=9, gap=2), color=alicorn.Color{0.28, 0.11, 0.12, 1})
		alicorn.text(&ui, "Scratchpad needs attention.")
		alicorn.text(&ui, app.error_message)
		alicorn.container_end(&ui)
	}

	if app.backend.started && !app.backend.state.has_workspace && len(app.backend.state.documents) == 0 {
		build_start_screen(app, &ui, rt)
	} else if app.backend.started {
		state := &app.backend.state
		workspace_split := alicorn.split_begin(
			&ui,
			key=alicorn.key_string("scratchpad-workspace-editor-split"),
			axis=.Horizontal,
			initial=250,
			min_first=180,
			min_second=480,
			style=alicorn.layout_style(.Row, grow=1, gap=12, clip=true),
			label="scratchpad-workspace-editor-split",
		)
		app.workspace_editor_split_node = workspace_split.id
		alicorn.split_first_begin(&ui, workspace_split)
		alicorn.container_begin(&ui, .Container, label="files-sidebar", style=alicorn.layout_style(.Column, grow=1, padding=14, gap=12, clip=true), color=COLOR_PANEL)
		alicorn.container_begin(&ui, .Container, label="workspace-panel-tabs", style=alicorn.layout_style(.Row, height=32, gap=6))
		if alicorn.button(&ui, "Files", key=alicorn.key_string("workspace-panel-files"), style=alicorn.layout_style(.Row, grow=1, height=30), state=alicorn.Button_State{selected=!app.workspace_search_mode}) {
			workspace_search_cancel_active(app)
			workspace_search_match_clear_all(app)
			app.workspace_search_mode = false
			app.workspace_search_query_node = 0
			app.editor_focus_pending = true
		}
		if alicorn.button(&ui, "Search", key=alicorn.key_string("workspace-panel-search"), style=alicorn.layout_style(.Row, grow=1, height=30), state=alicorn.Button_State{selected=app.workspace_search_mode}) {
			app.workspace_search_mode = true
			app.workspace_search_focus_pending = true
		}
		alicorn.container_end(&ui)
		if app.workspace_search_mode {
			query_node := alicorn.text_field(&ui, app.workspace_search_query, key=alicorn.key_string(WORKSPACE_SEARCH_QUERY_KEY), style=alicorn.layout_style(.Row, height=34))
			app.workspace_search_query_node = query_node
			if app.workspace_search_error != "" { alicorn.text(&ui, app.workspace_search_error) }
			else if !state.has_workspace { alicorn.text(&ui, "Open a workspace to search.") }
			else if app.workspace_search_query == "" { alicorn.text(&ui, "Type to search workspace files.") }
			else if app.workspace_search_view.done && app.workspace_search_view.count == 0 { alicorn.text(&ui, "No matches") }
			else if app.workspace_search_view.done {
				count_text := fmt.tprintf("%d matches", app.workspace_search_view.count)
				if app.workspace_search_view.truncated { count_text = fmt.tprintf("%s · result limit reached", count_text) }
				alicorn.text(&ui, count_text)
			} else {
				alicorn.text(&ui, fmt.tprintf("Searching… %d matches", app.workspace_search_view.count))
			}
			if len(app.workspace_search_view.results) > 0 {
				search_list := alicorn.virtual_list_begin(&ui, len(app.workspace_search_view.results), 72, key=alicorn.key_string("scratchpad-workspace-search-results"), style=alicorn.layout_style(grow=1, clip=true), label="scratchpad-workspace-search-results", focusable=true)
				app.workspace_search_results_owner = search_list.scroll.id
				for position := search_list.first; position < search_list.last; position += 1 {
					result := app.workspace_search_view.results[position]
					label := workspace_search_result_label(result)
					if alicorn.button(&ui, label, key=alicorn.key_pair(app.workspace_search_view.generation, u64(position)), style=alicorn.layout_style(.Row, height=68), state=alicorn.Button_State{selected=app.workspace_search_selected == position}, text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_REGULAR, overflow=.Wrap}, content_style=alicorn.button_content_style(.Start, padding_x=7, padding_y=5)) {
						app.workspace_search_selected = position
						_ = workspace_search_activate_result(app, rt, position)
					}
				}
				alicorn.virtual_list_end(&ui, search_list)
			}
		} else {
			alicorn.text(&ui, state.workspace_root if state.has_workspace else "No workspace open")
			build_workspace_tree(app, &ui, rt)
		}
		alicorn.container_end(&ui)
		alicorn.split_first_end(&ui, workspace_split)
		alicorn.split_divider(&ui, workspace_split)
		alicorn.split_second_begin(&ui, workspace_split)

		alicorn.container_begin(&ui, .Container, label="document-workbench", style=alicorn.layout_style(.Column, grow=1, gap=0, clip=true), color=COLOR_PANEL)
		alicorn.container_begin(&ui, .Container, label="document-tabs", style=alicorn.layout_style(.Row, height=42, gap=2, padding=5, clip=true), color=COLOR_SUBTLE)
		for document in state.documents {
			if !alicorn.component_begin(&ui, alicorn.key_string(document.id)) { continue }
			title := document_title(document.path)
			if document.preview && !document.dirty { title = fmt.tprintf("%s (preview)", title) }
			if document.dirty { title = fmt.tprintf("%s •", title) }
			selected := state.active == document.id
			if alicorn.button(&ui, title, key=alicorn.key_string("document-tab"), style=alicorn.layout_style(.Row, width=180, height=32), state=alicorn.Button_State{selected=selected}, content_style=alicorn.button_content_style(.Start, padding_x=10)) {
				if !frame_deferred_action_schedule(app, .Select_Document, document.id) {
					set_error(app, "Could not queue document selection until the current frame is complete.")
					alicorn.invalidate_root(rt, "Scratchpad could not defer tab selection")
				}
			}
			_ = alicorn.drag_source(&ui, SCRATCHPAD_DRAG_TABS, document_tab_semantic_id(document.id))
			_ = alicorn.drop_target(&ui, SCRATCHPAD_DRAG_TABS, document_tab_semantic_id(document.id), .Between_Horizontal)
			if alicorn.button(&ui, "×", key=alicorn.key_string("document-tab-close"), style=alicorn.layout_style(.Row, width=30, height=32)) {
				if !frame_deferred_action_schedule(app, .Close_Document, document.id) {
					set_error(app, "Could not queue document close until the current frame is complete.")
					alicorn.invalidate_root(rt, "Scratchpad could not defer tab close")
				}
			}
			alicorn.component_end(&ui)
		}
		if len(state.documents) == 0 {
			alicorn.text(&ui, "No documents open")
		}
		alicorn.container_end(&ui)
		if app.find_open {
			alicorn.container_begin(&ui, .Container, label="scratchpad-find-panel", style=alicorn.layout_style(.Column, height=78, gap=4, padding=5), color=COLOR_SUBTLE)
			alicorn.container_begin(&ui, .Container, label="scratchpad-find-bar", style=alicorn.layout_style(.Row, height=32, gap=8, align=.Center))
			alicorn.text(&ui, "Find")
			find_node := alicorn.text_field(&ui, app.find_query, key=alicorn.key_string(FIND_QUERY_KEY), style=alicorn.layout_style(.Row, grow=1, height=30))
			app.find_query_node = find_node
			if alicorn.button(&ui, "Aa", key=alicorn.key_string("find-match-case"), style=alicorn.layout_style(.Row, width=38, height=28), state=alicorn.Button_State{selected=app.find_match_case}) {
				app.find_match_case = !app.find_match_case
				app.find_presentation.editor_revision = 0
				find_refresh_if_needed(app, rt)
			}
			if alicorn.button(&ui, "W", key=alicorn.key_string("find-whole-word"), style=alicorn.layout_style(.Row, width=34, height=28), state=alicorn.Button_State{selected=app.find_whole_word}) {
				app.find_whole_word = !app.find_whole_word
				app.find_presentation.editor_revision = 0
				find_refresh_if_needed(app, rt)
			}
			find_status := ""
			if app.find_query == "" { find_status = "Type to find" }
			else if app.find_error != "" { find_status = app.find_error }
			else if len(app.find_presentation.matches) == 0 { find_status = "No matches" }
			else {
				find_status = fmt.tprintf("%d of %d", app.find_presentation.active_match+1, len(app.find_presentation.matches))
				if app.find_presentation.truncated { find_status = fmt.tprintf("%s+", find_status) }
			}
			alicorn.text(&ui, find_status)
			if alicorn.button(&ui, "↑", key=alicorn.key_string("find-previous"), style=alicorn.layout_style(.Row, width=34, height=28)) { _ = find_move_match(app, rt, -1) }
			if alicorn.button(&ui, "↓", key=alicorn.key_string("find-next"), style=alicorn.layout_style(.Row, width=34, height=28)) { _ = find_move_match(app, rt, 1) }
			if alicorn.button(&ui, "×", key=alicorn.key_string("find-close"), style=alicorn.layout_style(.Row, width=30, height=28)) { find_close_surface(app) }
			alicorn.container_end(&ui)
			alicorn.container_begin(&ui, .Container, label="scratchpad-replace-bar", style=alicorn.layout_style(.Row, height=32, gap=8, align=.Center))
			alicorn.text(&ui, "Replace")
			replace_node := alicorn.text_field(&ui, app.find_replace_text, key=alicorn.key_string("scratchpad-find-replace-text"), style=alicorn.layout_style(.Row, grow=1, height=30))
			app.find_replace_node = replace_node
			can_replace := app.find_query != "" && len(app.find_presentation.matches) > 0 && len(app.editor_edits) == 0 && !editor_active_preedit(app)
			if alicorn.button(&ui, "Replace", key=alicorn.key_string("find-replace-current"), style=alicorn.layout_style(.Row, width=82, height=28), state=alicorn.Button_State{disabled=!can_replace}) {
				_ = find_replace_current(app, rt)
			}
			if alicorn.button(&ui, "All", key=alicorn.key_string("find-replace-all"), style=alicorn.layout_style(.Row, width=58, height=28), state=alicorn.Button_State{disabled=!can_replace}) {
				_ = find_replace_all(app, rt)
			}
			if app.find_replace_message != "" { alicorn.text(&ui, app.find_replace_message) }
			alicorn.container_end(&ui)
			alicorn.container_end(&ui)
		}

		alicorn.container_begin(&ui, .Container, label="document-surface", style=alicorn.layout_style(.Column, grow=1, padding=10, gap=6, align=.Start, clip=true), color=COLOR_PANEL)
		build_startup_notice(app, &ui, rt)
		if active, found := find_document(state, state.active); found {
			if alicorn.component_begin(&ui, alicorn.key_string(active.id)) {
				build_document_editor(app, &ui, rt, active)
				alicorn.component_end(&ui)
			}
		} else {
			alicorn.text(&ui, "Open a file to begin")
			alicorn.text(&ui, "Open a document to view its bounded source window.")
		}
		alicorn.container_end(&ui)
		if active, found := find_document(state, state.active); found {
			build_document_status(app, &ui, rt, active)
		}
		alicorn.container_end(&ui)
		alicorn.split_second_end(&ui, workspace_split)
		alicorn.split_end(&ui, workspace_split)
	} else {
		alicorn.container_begin(&ui, .Container, label="backend-starting-card", style=alicorn.layout_style(.Column, grow=1, padding=24, gap=12), color=COLOR_PANEL)
		alicorn.text(&ui, "Starting Scratchpad…")
		alicorn.container_end(&ui)
	}
	alicorn.container_end(&ui)

	if app.shutdown_intent == .None && app.close_document_id == "" && !app.save_as_confirmation_open && app.workspace_mutation_kind == .None && !app.settings_surface_open && !app.command_palette_open && !app.quick_open_open {
		workspace_context_menu_build(app, &ui, rt)
	}

	if app.shutdown_intent != .None {
		build_shutdown_dialog(app, &ui, rt)
	} else if app.close_document_id != "" {
		alicorn.modal_overlay_begin(&ui, alicorn.key_string("dirty-close-overlay"), style=alicorn.layout_style(.Column, grow=1, align=.Center), backdrop_color=alicorn.Color{0.015, 0.02, 0.03, 0.72})
		alicorn.container_begin(&ui, .Container, label="dirty-close-dialog", style=alicorn.layout_style(.Column, width=440, height=190, padding=22, gap=14, align=.Start, clip=true), color=COLOR_PANEL)
		recovery_pending := editor_document_has_recoverable_preedit(app, app.close_document_id)
		if recovery_pending {
			alicorn.text(&ui, "A committed text composition is waiting for recovery.")
			alicorn.text(&ui, "Copy it or explicitly discard it before closing this document.")
		} else {
			alicorn.text(&ui, "Save changes before closing?")
		}
		if document, found := find_document(&app.backend.state, app.close_document_id); found {
			alicorn.text(&ui, document_title(document.path))
		}
		alicorn.container_begin(&ui, .Container, label="dirty-close-actions", style=alicorn.layout_style(.Row, height=38, gap=8, align=.Center))
		if recovery_pending {
			if alicorn.button(&ui, "Copy Recovery", key=alicorn.key_string("recovery-close-copy"), style=alicorn.layout_style(.Row, width=130, height=34)) {
				if editor_copy_recoverable_preedit(app, rt, app.close_document_id) {
					if frame_deferred_action_schedule(app, .Close_Document, app.close_document_id) {
						clear_close_prompt(app)
					} else {
						set_error(app, "Could not queue document close until the current frame is complete.")
					}
				}
			}
			if alicorn.button(&ui, "Discard Recovery", key=alicorn.key_string("recovery-close-discard"), style=alicorn.layout_style(.Row, width=140, height=34)) {
				if editor_discard_recoverable_preedit(app, rt, app.close_document_id) {
					if frame_deferred_action_schedule(app, .Close_Document, app.close_document_id) {
						clear_close_prompt(app)
					} else {
						set_error(app, "Could not queue document close until the current frame is complete.")
					}
				}
			}
		} else {
			if alicorn.button(&ui, "Save & Close", key=alicorn.key_string("dirty-close-save"), style=alicorn.layout_style(.Row, width=130, height=34)) {
				if !frame_deferred_action_schedule(app, .Close_After_Save) {
					set_error(app, "Could not queue save-and-close until the current frame is complete.")
					alicorn.invalidate_root(rt, "Scratchpad could not defer save-and-close")
				}
			}
			if alicorn.button(&ui, "Discard", key=alicorn.key_string("dirty-close-discard"), style=alicorn.layout_style(.Row, width=100, height=34)) {
				if !frame_deferred_action_schedule(app, .Close_With_Discard) {
					set_error(app, "Could not queue discard-and-close until the current frame is complete.")
					alicorn.invalidate_root(rt, "Scratchpad could not defer discard-and-close")
				}
			}
		}
		if alicorn.button(&ui, "Cancel", key=alicorn.key_string("dirty-close-cancel"), style=alicorn.layout_style(.Row, width=90, height=34)) {
			if !frame_deferred_action_schedule(app, .Cancel_Close_Prompt) {
				set_error(app, "Could not queue close cancellation until the current frame is complete.")
				alicorn.invalidate_root(rt, "Scratchpad could not defer close cancellation")
			}
		}
		alicorn.container_end(&ui)
		alicorn.container_end(&ui)
		alicorn.modal_overlay_end(&ui)
	} else if app.save_as_confirmation_open {
		alicorn.modal_overlay_begin(&ui, alicorn.key_string("save-as-confirmation-overlay"), style=alicorn.layout_style(.Column, grow=1, align=.Center), backdrop_color=alicorn.Color{0.015, 0.02, 0.03, 0.72})
		alicorn.container_begin(&ui, .Container, label="save-as-confirmation-dialog", style=alicorn.layout_style(.Column, width=480, height=176, padding=22, gap=12, align=.Start, clip=true), color=COLOR_PANEL)
		alicorn.text(&ui, "Replace the existing file?")
		alicorn.text(&ui, app.save_as_confirmation_path, style=alicorn.layout_style(.Row, height=52), text_style=alicorn.Text_Style{overflow=.Wrap})
		alicorn.container_begin(&ui, .Container, label="save-as-confirmation-actions", style=alicorn.layout_style(.Row, height=38, gap=8, align=.Center))
		if alicorn.button(&ui, "Replace", key=alicorn.key_string("save-as-confirmation-replace"), style=alicorn.layout_style(.Row, width=104, height=34)) {
			save_as_confirm_overwrite(app, rt)
		}
		if alicorn.button(&ui, "Cancel", key=alicorn.key_string("save-as-confirmation-cancel"), style=alicorn.layout_style(.Row, width=90, height=34)) {
			save_as_cancel_overwrite(app, rt)
		}
		alicorn.container_end(&ui)
		alicorn.container_end(&ui)
		alicorn.modal_overlay_end(&ui)
	} else if app.workspace_mutation_kind != .None {
		workspace_mutation_build_dialog(app, &ui, rt)
	} else if app.go_to_line_open {
		alicorn.modal_overlay_begin(&ui, alicorn.key_string("go-to-line-overlay"), style=alicorn.layout_style(.Column, grow=1, align=.Center), backdrop_color=alicorn.Color{0.015, 0.02, 0.03, 0.72})
		alicorn.container_begin(&ui, .Container, label="go-to-line-dialog", style=alicorn.layout_style(.Column, width=420, height=150, padding=20, gap=10, align=.Start, clip=true), color=COLOR_PANEL)
		alicorn.text(&ui, "Go to Line")
		app.go_to_line_query_node = alicorn.text_field(&ui, app.go_to_line_query, key=alicorn.key_string("go-to-line-query"), style=alicorn.layout_style(.Row, height=34))
		if app.go_to_line_error != "" { alicorn.text(&ui, app.go_to_line_error) }
		alicorn.container_begin(&ui, .Container, label="go-to-line-actions", style=alicorn.layout_style(.Row, height=36, gap=8, align=.Center))
		if alicorn.button(&ui, "Go", key=alicorn.key_string("go-to-line-submit"), style=alicorn.layout_style(.Row, width=80, height=32)) { _ = go_to_line_submit(app, rt) }
		if alicorn.button(&ui, "Cancel", key=alicorn.key_string("go-to-line-cancel"), style=alicorn.layout_style(.Row, width=88, height=32)) { go_to_line_close(app, rt, true) }
		alicorn.container_end(&ui)
		alicorn.container_end(&ui)
		alicorn.modal_overlay_end(&ui)
	} else if app.settings_surface_open {
		settings_surface_build(app, &ui, rt)
	} else if app.quick_open_open {
		quick_open_build(app, &ui, rt)
	} else if app.command_palette_open {
		command_palette_build(app, &ui, rt)
	}

	alicorn.end_frame(&ui)
	frame_deferred_action_run(app, rt)
	command_palette_restore_focus_after_frame(app, rt)
	quick_open_restore_focus_after_frame(app, rt)
	find_restore_after_frame(app, rt)
	workspace_mutation_focus_after_frame(app, rt)
	if app.go_to_line_open && app.go_to_line_focus_pending && app.go_to_line_query_node != 0 {
		if alicorn.focus(rt, app.go_to_line_query_node) {
			if text, found := alicorn.text_field_value(rt, app.go_to_line_query_node); found {
				_ = alicorn.set_text_selection(rt, app.go_to_line_query_node, 0, len(text))
			}
			app.go_to_line_focus_pending = false
		}
	}
	if app.editor_restore_scroll && app.editor_scroll_owner != 0 {
		if app.editor_restore_vertical {
			_ = alicorn.scroll_region_set_offset(rt, app.editor_scroll_owner, app.editor_restore_y, "restore per-document vertical view")
		}
		if app.editor_restore_horizontal {
			_ = alicorn.scroll_region_set_offset_x(rt, app.editor_scroll_owner, app.editor_restore_x, "restore per-document horizontal view")
		}
		app.editor_restore_scroll = false
		app.editor_restore_vertical = false
		app.editor_restore_horizontal = false
	}
	if app.editor_input_anchor_node != 0 && app.editor_scroll_owner != 0 {
		geometry := alicorn.text_node_caret_geometry(
			rt,
			app.editor_input_anchor_node,
			alicorn.Text_Position{byte=app.editor_input_anchor_byte, affinity=app.editor_input_anchor_affinity},
		)
		if geometry.valid {
			area := alicorn.Text_Input_Area{
				rect=alicorn.Rect{geometry.rect.x, geometry.rect.y, 1, max(geometry.rect.h, EDITOR_ROW_HEIGHT*editor_text_scale_effective(app))},
				cursor_x=0,
			}
			_ = alicorn.text_input_target_area_set(rt, app.editor_scroll_owner, area)
		}
	}
	editor_reveal_after_frame(app, rt)
	if app.smoke && app.backend.started && app.backend.state.revision > 0 { app.smoke_rendered = true }
	return root
}

build_startup_notice :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime) {
	if app == nil || ui == nil || app.recovery_notice_dismissed || app.backend.state.startup_notice == "" { return }
	alicorn.container_begin(ui, .Container, label="scratchpad-startup-notice", style=alicorn.layout_style(.Column, height=72, padding=6, gap=4), color=COLOR_SUBTLE)
	alicorn.text(ui, app.backend.state.startup_notice, style=alicorn.layout_style(.Row, height=42), text_style=alicorn.Text_Style{overflow=.Wrap})
	if alicorn.button(ui, "Dismiss", key=alicorn.key_string("scratchpad-startup-notice-dismiss"), style=alicorn.layout_style(.Row, width=82, height=24)) {
		app.recovery_notice_dismissed = true
		alicorn.invalidate_root(rt, "Scratchpad recovery notice dismissed")
	}
	alicorn.container_end(ui)
}
