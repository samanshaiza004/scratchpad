package main

import "core:fmt"
import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"

SCRATCHPAD_CONTENT_TITLEBAR_HEIGHT :: f32(42)
SCRATCHPAD_CONTENT_TITLEBAR_TAB_HEIGHT :: f32(34)
SCRATCHPAD_CONTENT_TITLEBAR_MIN_TAB_WIDTH :: f32(136)

build_app :: proc(
	state: rawptr,
	rt: ^alicorn.Runtime,
	logical_width, logical_height: int,
	dpi_scale: f32,
) -> alicorn.Node_ID {
	app := cast(^App)state
	scratchpad_editor_font_apply_pending(app, rt)
	scratchpad_application_assets_release_retired(app, rt)
	scratchpad_image_preview_sync(app, rt)
	session_ui_prepare(app, rt)
	ui, should_build := alicorn.begin_frame(rt)
	if !should_build { return 0 }
	find_text_history_initialize(&app.find_replace_edit_history, app.find_replace_text)
	if find_capture_text_field(rt, app.find_replace_node, &app.find_replace_text) {
		find_text_history_observe(&app.find_replace_edit_history, app.find_replace_text)
	}
	_ = find_capture_text_field(rt, app.workspace_search_query_node, &app.workspace_search_query)
	app.workspace_search_results_owner = 0
	_ = find_capture_text_field(rt, app.workspace_mutation_name_node, &app.workspace_mutation_name)
	_ = find_capture_text_field(rt, app.go_to_line_query_node, &app.go_to_line_query)
	_ = find_capture_text_field(rt, app.command_palette_node, &app.command_palette_query)
	_ = find_capture_text_field(rt, app.quick_open_node, &app.quick_open_query)
	_ = find_capture_text_field(rt, app.editor_font_picker_query_node, &app.editor_font_picker_query)
	if active, found := find_document(&app.backend.state, app.backend.state.active); found &&
	   (active.view_kind == "image" || active.view_kind == "unsupported" || floating_window_contains(app, active.id)) {
		if app.find_open { find_close_surface(app) }
		app.editor_scroll_owner = 0
		app.editor_restore_scroll = false
		app.editor_restore_vertical = false
		app.editor_restore_horizontal = false
		app.editor_focus_pending = false
		app.editor_input_anchor_node = 0
		if floating_window_contains(app, active.id) { editor_accessibility_retire(app, rt) }
	}
	app.image_scroll_owner = 0
	if app.workspace_search_mode { workspace_search_start_query(app, rt) }
	clear(&app.editor_row_targets)
	app.editor_input_anchor_node = 0
	if !scratchpad_styles_ensure(app, rt) { set_error(app, "Could not initialize the warm style palette.") }
	if app.backend.started {
		sync_runtime_actions(app, rt)
		sync_menu_states(app)
		find_sync_focused_edit_menu_states(app, rt)
	}

	root_gap := f32(8)
	when ODIN_OS == .Darwin || ODIN_OS == .Windows { root_gap = 0 }
	root := alicorn.container_begin(
		&ui,
		.Root,
		label="scratchpad-alicorn-workbench",
		style=alicorn.layout_style(.Column, grow=1, gap=root_gap, clip=true),
		color=alicorn.style_theme_color(rt, app.workbench_theme, .Window_Background),
	)
	workbench_style_scope := alicorn.style_environment_push(&ui, scratchpad_workbench_style_environment(app))
	when ODIN_OS == .Darwin || ODIN_OS == .Windows {
		scratchpad_content_titlebar_build(app, &ui, rt, logical_width)
	}

	if app.backend.started && !app.backend.state.has_workspace && len(app.backend.state.documents) == 0 {
		build_start_screen(app, &ui, rt)
	} else if app.backend.started {
		state := &app.backend.state
		split_initial := state.sidebar_width
		if split_initial < 180 || split_initial > 2048 { split_initial = 250 }
		if app.workspace_split_restore_runtime != rt {
			app.workspace_split_restore_runtime = rt
			app.workspace_split_restore_token = alicorn.restore_token_next(rt)
			app.workspace_split_restore_complete = false
		}
		split_restore := alicorn.Split_Restore_Request{}
		if !app.workspace_split_restore_complete {
			split_restore = alicorn.Split_Restore_Request{token=app.workspace_split_restore_token, preferred_position=split_initial}
		}
		workspace_split := alicorn.split_begin(
			&ui,
			key=alicorn.key_string("scratchpad-workspace-editor-split"),
			axis=.Horizontal,
			initial=split_initial,
			min_first=180,
			min_second=480,
			style=alicorn.layout_style(.Row, grow=1, gap=2, clip=true),
			label="scratchpad-workspace-editor-split",
			restore=split_restore,
		)
		app.workspace_editor_split_node = workspace_split.id
		app.workspace_sidebar_width = workspace_split.position
		alicorn.split_first_begin(&ui, workspace_split)
		alicorn.surface_begin(&ui, alicorn.surface_core_color_role(.Surface), label="files-sidebar", style=alicorn.layout_style(.Column, grow=1, padding=8, gap=6, clip=true), material=scratchpad_structural_material(app), physical_height=scratchpad_optical_height(.Recessed))
		alicorn.container_begin(&ui, .Container, label="workspace-panel-tabs", style=alicorn.layout_style(.Row, height=30, gap=4))
		if alicorn.button(&ui, "Files", key=alicorn.key_string("workspace-panel-files"), style=alicorn.layout_style(.Row, grow=1, height=28), state=alicorn.Button_State{selected=!app.workspace_search_mode}, variant=.Tab) {
			workspace_search_cancel_active(app)
			workspace_search_match_clear_all(app)
			app.workspace_search_mode = false
			app.workspace_search_query_node = 0
			app.editor_focus_pending = true
		}
		if alicorn.button(&ui, "Search", key=alicorn.key_string("workspace-panel-search"), style=alicorn.layout_style(.Row, grow=1, height=28), state=alicorn.Button_State{selected=app.workspace_search_mode}, variant=.Tab) {
			app.workspace_search_mode = true
			app.workspace_search_focus_pending = true
		}
		alicorn.container_end(&ui)
		if app.workspace_search_mode {
			query_node := alicorn.text_field(&ui, app.workspace_search_query, key=alicorn.key_string(WORKSPACE_SEARCH_QUERY_KEY), style=alicorn.layout_style(.Row, height=32))
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
					if alicorn.button(&ui, label, key=alicorn.key_pair(app.workspace_search_view.generation, u64(position)), style=alicorn.layout_style(.Row, height=68), state=alicorn.Button_State{selected=app.workspace_search_selected == position}, text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_REGULAR, overflow=.Wrap}, content_style=alicorn.button_content_style(.Start, padding_x=7, padding_y=5), variant=.Quiet) {
						app.workspace_search_selected = position
						_ = workspace_search_activate_result(app, rt, position)
					}
				}
				alicorn.virtual_list_end(&ui, search_list)
			}
		} else {
			alicorn.surface_begin(&ui, alicorn.surface_core_color_role(.Surface), label="workspace-root-row", style=alicorn.layout_style(.Row, height=26, gap=4, align=.Center), material=scratchpad_structural_material(app), physical_height=scratchpad_optical_height(.Groove))
			alicorn.text(&ui, state.workspace_root if state.has_workspace else "No workspace open", style=alicorn.layout_style(.Row, grow=1), text_style=alicorn.Text_Style{overflow=.Ellipsis})
			alicorn.container_end(&ui)
			build_workspace_tree(app, &ui, rt)
		}
		alicorn.surface_end(&ui)
		alicorn.split_first_end(&ui, workspace_split)
		alicorn.split_divider(&ui, workspace_split)
		alicorn.split_second_begin(&ui, workspace_split)

		alicorn.container_begin(&ui, .Container, label="document-workbench", style=alicorn.layout_style(.Column, grow=1, gap=0, clip=true), color=alicorn.style_color(&ui, .Surface))
		when ODIN_OS != .Darwin && ODIN_OS != .Windows {
			alicorn.surface_begin(&ui, alicorn.surface_core_color_role(.Subtle_Surface), key=alicorn.key_string("document-tabs"), label="document-tabs", style=alicorn.layout_style(.Row, height=42, gap=2, padding=5, clip=true), material=scratchpad_surface_material(app, app.raised_surface_material), physical_height=scratchpad_surface_height(app, 0.65))
			scratchpad_document_tabs_build(app, &ui, rt, width=0, height=32, compact=false, show_empty=true)
			alicorn.surface_end(&ui)
		}
		if app.find_open {
			alicorn.surface_begin(&ui, alicorn.surface_core_color_role(.Subtle_Surface), label="scratchpad-find-panel", style=alicorn.layout_style(.Column, height=94, gap=4, padding=5), material=scratchpad_structural_material(app), physical_height=scratchpad_optical_height(.Groove))
			alicorn.container_begin(&ui, .Container, label="scratchpad-find-bar", style=alicorn.layout_style(.Row, height=38, gap=8, align=.Center))
			alicorn.text(&ui, "Find")
			_ = find_query_build(app, &ui, rt)
			if alicorn.button(&ui, "Aa", key=alicorn.key_string("find-match-case"), style=alicorn.layout_style(.Row, width=38, height=28), state=alicorn.Button_State{selected=app.find_match_case}, variant=.Toolbar) {
				app.find_match_case = !app.find_match_case
				app.find_presentation.editor_revision = 0
				find_refresh_if_needed(app, rt)
			}
			_ = alicorn.tooltip(&ui, "Match case")
			if alicorn.button(&ui, "W", key=alicorn.key_string("find-whole-word"), style=alicorn.layout_style(.Row, width=34, height=28), state=alicorn.Button_State{selected=app.find_whole_word}, variant=.Toolbar) {
				app.find_whole_word = !app.find_whole_word
				app.find_presentation.editor_revision = 0
				find_refresh_if_needed(app, rt)
			}
			_ = alicorn.tooltip(&ui, "Whole word")
			find_status := ""
			if app.find_query.text == "" { find_status = "Type to find" }
			else if app.find_error != "" { find_status = app.find_error }
			else if len(app.find_presentation.matches) == 0 { find_status = "No matches" }
			else {
				find_status = fmt.tprintf("%d of %d", app.find_presentation.active_match+1, len(app.find_presentation.matches))
				if app.find_presentation.truncated { find_status = fmt.tprintf("%s+", find_status) }
			}
			alicorn.text(&ui, find_status)
			if alicorn.button(&ui, "↑", key=alicorn.key_string("find-previous"), style=alicorn.layout_style(.Row, width=34, height=28), variant=.Toolbar) { _ = find_move_match(app, rt, -1) }
			if alicorn.button(&ui, "↓", key=alicorn.key_string("find-next"), style=alicorn.layout_style(.Row, width=34, height=28), variant=.Toolbar) { _ = find_move_match(app, rt, 1) }
			if alicorn.button(&ui, "×", key=alicorn.key_string("find-close"), style=alicorn.layout_style(.Row, width=30, height=28), variant=.Toolbar) { find_close_surface(app) }
			alicorn.container_end(&ui)
			alicorn.container_begin(&ui, .Container, label="scratchpad-replace-bar", style=alicorn.layout_style(.Row, height=38, gap=8, align=.Center))
			alicorn.text(&ui, "Replace")
			replace_node := alicorn.text_field(&ui, app.find_replace_text, key=alicorn.key_string("scratchpad-find-replace-text"), style=alicorn.layout_style(.Row, grow=1, height=36), text_style=SCRATCHPAD_PROMINENT_INPUT_TEXT_STYLE)
			app.find_replace_node = replace_node
			can_replace := app.find_query.text != "" && len(app.find_presentation.matches) > 0 && len(app.editor_edits) == 0 && !editor_active_preedit(app)
			if alicorn.button(&ui, "Replace", key=alicorn.key_string("find-replace-current"), style=alicorn.layout_style(.Row, width=82, height=28), state=alicorn.Button_State{disabled=!can_replace}, variant=.Toolbar) {
				_ = find_replace_current(app, rt)
			}
			if alicorn.button(&ui, "All", key=alicorn.key_string("find-replace-all"), style=alicorn.layout_style(.Row, width=58, height=28), state=alicorn.Button_State{disabled=!can_replace}, variant=.Toolbar) {
				_ = find_replace_all(app, rt)
			}
			if app.find_replace_message != "" { alicorn.text(&ui, app.find_replace_message) }
			alicorn.container_end(&ui)
			alicorn.surface_end(&ui)
		}

		editor_theme_scope := alicorn.style_environment_push(&ui, alicorn.Style_Environment{theme=app.editor_theme})
		paper_padding := scratchpad_editor_surface_padding(&ui, rt, app.editor_theme)
		alicorn.surface_begin(&ui, alicorn.surface_extension_color_role(scratchpad_editor_paper_surface_role()), key=alicorn.key_string("document-surface"), label="document-surface", style=alicorn.layout_style(.Column, grow=1, padding=paper_padding, gap=6, align=.Start, clip=true), material=scratchpad_surface_material(app, app.paper_surface_material), physical_height=scratchpad_surface_height(app, -0.75))
		build_startup_notice(app, &ui, rt)
		if active, found := find_document(state, state.active); found {
			if alicorn.component_begin(&ui, alicorn.key_string(active.id)) {
				if floating_window_contains(app, active.id) {
					alicorn.container_begin(&ui, .Container, label="floating-document-placeholder", style=alicorn.layout_style(.Column, grow=1, align=.Center, justify=.Center, gap=10))
					alicorn.text(&ui, "No document open in this window.")
					if alicorn.button(&ui, "Return to tabs", key=alicorn.key_string("floating-document-return-main"), style=alicorn.layout_style(.Row, width=140, height=32), variant=.Toolbar) {
						floating_window_return_to_tabs(app)
					}
					alicorn.container_end(&ui)
				} else {
					switch active.view_kind {
				case "image":
					editor_accessibility_retire(app, rt)
					build_image_preview(app, &ui, rt, active, dpi_scale)
				case "unsupported":
					editor_accessibility_retire(app, rt)
					build_unsupported_file_view(app, &ui, active)
				case:
					build_document_editor(app, &ui, rt, active)
					}
				}
				alicorn.component_end(&ui)
			}
		} else {
			editor_accessibility_retire(app, rt)
			alicorn.container_begin(&ui, .Container, label="workspace-empty-editor-welcome", style=alicorn.layout_style(.Column, grow=1, align=.Center, justify=.Center, gap=12))
			if app.brand_mark != 0 { _ = alicorn.image(&ui, app.brand_mark, alt_text="Scratchpad mark", key=alicorn.key_string("scratchpad-brand-mark"), style=alicorn.layout_style(.Row, width=40, height=40)) }
			alicorn.text(&ui, "No document open")
			alicorn.text(&ui, "Open a file from this workspace to begin editing.")
			if alicorn.button(&ui, "Quick Open…", key=alicorn.key_string("empty-editor-quick-open"), style=alicorn.layout_style(.Row, width=210, height=42), variant=.Primary) {
				quick_open_open_surface(app, rt)
			}
			alicorn.text(&ui, "Ctrl+P opens Quick Open")
			alicorn.container_end(&ui)
		}
		alicorn.style_environment_pop(&ui, editor_theme_scope)
		alicorn.surface_end(&ui)
		if active, found := find_document(state, state.active); found && !floating_window_contains(app, active.id) {
			build_document_status(app, &ui, rt, active)
		}
		alicorn.container_end(&ui)
		alicorn.split_second_end(&ui, workspace_split)
		alicorn.split_end(&ui, workspace_split)
	} else {
		alicorn.container_begin(&ui, .Container, label="backend-starting-card", style=alicorn.layout_style(.Column, grow=1, padding=24, gap=12), color=alicorn.style_color(&ui, .Surface))
		alicorn.text(&ui, "Starting Scratchpad…")
		alicorn.container_end(&ui)
	}
	alicorn.container_end(&ui)

	if app.shutdown_intent == .None && app.close_document_id == "" && !app.save_as_confirmation_open && app.workspace_mutation_kind == .None && !app.settings_surface_open && !app.recent_workspaces_open && !app.command_palette_open && !app.quick_open_open {
		workspace_context_menu_build(app, &ui, rt)
	}

	if app.shutdown_intent != .None {
		build_shutdown_dialog(app, &ui, rt)
	} else if app.close_document_id != "" {
		alicorn.modal_overlay_begin(&ui, alicorn.key_string("dirty-close-overlay"), style=alicorn.layout_style(.Column, grow=1, align=.Center), backdrop_color=alicorn.Color{0.015, 0.02, 0.03, 0.72})
		alicorn.container_begin(&ui, .Container, label="dirty-close-dialog", style=alicorn.layout_style(.Column, width=440, height=190, padding=22, gap=14, align=.Start, clip=true), color=alicorn.style_color(&ui, .Surface))
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
			if alicorn.button(&ui, "Save & Close", key=alicorn.key_string("dirty-close-save"), style=alicorn.layout_style(.Row, width=130, height=34), variant=.Primary) {
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
		if alicorn.button(&ui, "Cancel", key=alicorn.key_string("dirty-close-cancel"), style=alicorn.layout_style(.Row, width=90, height=34), variant=.Quiet) {
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
		alicorn.container_begin(&ui, .Container, label="save-as-confirmation-dialog", style=alicorn.layout_style(.Column, width=480, height=176, padding=22, gap=12, align=.Start, clip=true), color=alicorn.style_color(&ui, .Surface))
		alicorn.text(&ui, "Replace the existing file?")
		alicorn.text(&ui, app.save_as_confirmation_path, style=alicorn.layout_style(.Row, height=52), text_style=alicorn.Text_Style{overflow=.Wrap})
		alicorn.container_begin(&ui, .Container, label="save-as-confirmation-actions", style=alicorn.layout_style(.Row, height=38, gap=8, align=.Center))
		if alicorn.button(&ui, "Replace", key=alicorn.key_string("save-as-confirmation-replace"), style=alicorn.layout_style(.Row, width=104, height=34), variant=.Primary) {
			save_as_confirm_overwrite(app, rt)
		}
		if alicorn.button(&ui, "Cancel", key=alicorn.key_string("save-as-confirmation-cancel"), style=alicorn.layout_style(.Row, width=90, height=34), variant=.Quiet) {
			save_as_cancel_overwrite(app, rt)
		}
		alicorn.container_end(&ui)
		alicorn.container_end(&ui)
		alicorn.modal_overlay_end(&ui)
	} else if app.workspace_mutation_kind != .None {
		workspace_mutation_build_dialog(app, &ui, rt)
	} else if app.go_to_line_open {
		alicorn.modal_overlay_begin(&ui, alicorn.key_string("go-to-line-overlay"), style=alicorn.layout_style(.Column, grow=1, align=.Center), backdrop_color=alicorn.Color{0.015, 0.02, 0.03, 0.72})
		alicorn.container_begin(&ui, .Container, label="go-to-line-dialog", style=alicorn.layout_style(.Column, width=420, height=150, padding=20, gap=10, align=.Start, clip=true), color=alicorn.style_color(&ui, .Surface))
		alicorn.text(&ui, "Go to Line")
		app.go_to_line_query_node = alicorn.text_field(&ui, app.go_to_line_query, key=alicorn.key_string("go-to-line-query"), style=alicorn.layout_style(.Row, height=34))
		if app.go_to_line_error != "" { alicorn.text(&ui, app.go_to_line_error) }
		alicorn.container_begin(&ui, .Container, label="go-to-line-actions", style=alicorn.layout_style(.Row, height=36, gap=8, align=.Center))
		if alicorn.button(&ui, "Go", key=alicorn.key_string("go-to-line-submit"), style=alicorn.layout_style(.Row, width=80, height=32), variant=.Primary) { _ = go_to_line_submit(app, rt) }
		if alicorn.button(&ui, "Cancel", key=alicorn.key_string("go-to-line-cancel"), style=alicorn.layout_style(.Row, width=88, height=32), variant=.Quiet) { go_to_line_close(app, rt, true) }
		alicorn.container_end(&ui)
		alicorn.container_end(&ui)
		alicorn.modal_overlay_end(&ui)
	} else if app.recent_workspaces_open {
		recent_workspaces_surface_build(app, &ui, rt)
	} else if app.settings_surface_open {
		settings_surface_build(app, &ui, rt, 1)
		if app.editor_font_picker_open { scratchpad_editor_font_picker_build(app, &ui, rt) }
	} else if app.quick_open_open {
		quick_open_build(app, &ui, rt)
	} else if app.command_palette_open {
		command_palette_build(app, &ui, rt)
	}
	alicorn.style_environment_pop(&ui, workbench_style_scope)

	alicorn.end_frame(&ui)
	image_preview_after_frame(app, rt)
	if !app.workspace_split_restore_complete &&
	   app.workspace_split_restore_token != alicorn.RESTORE_TOKEN_NONE &&
	   app.workspace_editor_split_node != 0 {
		split_restore_state, found := alicorn.restore_state_query(
			rt, .Split, app.workspace_editor_split_node, app.workspace_split_restore_token,
		)
		if found && split_restore_state.outcome != .None &&
		   split_restore_state.outcome != .Requested && split_restore_state.outcome != .Deferred {
			app.workspace_split_restore_complete = true
		}
	}
	editor_view_restore_after_frame(app, rt, app.editor_scroll_owner)
	if app.editor_focus_pending && app.image_scroll_owner != 0 {
		if alicorn.focus(rt, app.image_scroll_owner) { app.editor_focus_pending = false }
	}
	scratchpad_error_notice_sync(app, rt)
	frame_deferred_action_run(app, rt)
	command_palette_restore_focus_after_frame(app, rt)
	quick_open_restore_focus_after_frame(app, rt)
	scratchpad_editor_font_picker_restore_focus_after_frame(app, rt)
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
	session_ui_after_frame(app, rt)
	scratchpad_application_assets_build_completed(app)
	return root
}

build_startup_notice :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime) {
	if app == nil || ui == nil || app.recovery_notice_dismissed || app.backend.state.startup_notice == "" { return }
	alicorn.container_begin(ui, .Container, label="scratchpad-startup-notice", style=alicorn.layout_style(.Column, height=72, padding=6, gap=4), color=alicorn.style_color(ui, .Subtle_Surface))
	alicorn.text(ui, app.backend.state.startup_notice, style=alicorn.layout_style(.Row, height=42), text_style=alicorn.Text_Style{overflow=.Wrap})
	if alicorn.button(ui, "Dismiss", key=alicorn.key_string("scratchpad-startup-notice-dismiss"), style=alicorn.layout_style(.Row, width=82, height=24)) {
		app.recovery_notice_dismissed = true
		alicorn.invalidate_root(rt, "Scratchpad recovery notice dismissed")
	}
	alicorn.container_end(ui)
}

scratchpad_content_titlebar_metrics :: proc(state: rawptr, rt: ^alicorn.Runtime, metrics: host.Window_Chrome_Metrics) {
	app := cast(^App)state
	if app == nil { return }
	app.window_chrome_metrics = metrics
}

scratchpad_content_titlebar_layout :: proc(state: rawptr, rt: ^alicorn.Runtime) -> host.Window_Chrome_Layout {
	app := cast(^App)state
	if app == nil { return {} }
	return host.Window_Chrome_Layout{
		header=app.window_chrome_header_node,
		regions=app.window_chrome_regions[:app.window_chrome_region_count],
	}
}

scratchpad_content_titlebar_region_add :: proc(
	app: ^App,
	node: alicorn.Node_ID,
	kind: host.Window_Chrome_Region_Kind,
) {
	if app == nil || node == 0 || app.window_chrome_region_count >= len(app.window_chrome_regions) { return }
	app.window_chrome_regions[app.window_chrome_region_count] = host.Window_Chrome_Region{node=node, kind=kind}
	app.window_chrome_region_count += 1
}

scratchpad_content_titlebar_build :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime, logical_width: int) {
	if app == nil || ui == nil || rt == nil { return }
	app.window_chrome_header_node = 0
	app.window_chrome_region_count = 0
	metrics := app.window_chrome_metrics
	if metrics.header.h <= 0 { return }
	if metrics.header.y > 0 {
		alicorn.container_begin(ui, .Container, label="scratchpad-titlebar-safe-area",
			style=alicorn.layout_style(.Row, height=metrics.header.y))
		alicorn.container_end(ui)
	}
	window_width := f32(max(logical_width, 0))
	leading_width := clamp(metrics.content_start_x, 0, window_width)
	content_end_x := metrics.content_end_x
	if content_end_x <= 0 { content_end_x = window_width }
	content_end_x = clamp(content_end_x, leading_width, window_width)
	available_width := max(content_end_x-leading_width, 0)
	header := alicorn.container_begin(
		ui,
		.Container,
		label="scratchpad-content-titlebar",
		style=alicorn.layout_style(.Row, height=metrics.header.h, gap=0, align=.Center, clip=true),
		color=alicorn.style_color(ui, .Subtle_Surface),
	)
	app.window_chrome_header_node = header

	leading_drag := alicorn.container_begin(
		ui,
		.Container,
		label="scratchpad-titlebar-leading-drag",
		style=alicorn.layout_style(.Row, width=leading_width, height=metrics.header.h),
	)
	scratchpad_content_titlebar_region_add(app, leading_drag, .Window_Drag)
	alicorn.container_end(ui)
	middle := alicorn.container_begin(
		ui,
		.Container,
		label="scratchpad-titlebar-content-band",
		style=alicorn.layout_style(.Row, width=available_width, height=metrics.header.h, align=.Center, clip=true),
	)

	visible_tabs := 0
	for document in app.backend.state.documents {
		if app.floating_window != nil && document.id == app.floating_window.document_id { continue }
		visible_tabs += 1
	}
	drag_reserve := min(160, available_width*0.2)
	tab_width := min(f32(visible_tabs)*180, max(available_width-drag_reserve, 0))
	if visible_tabs > 0 && tab_width > 0 {
		tab_region := alicorn.container_begin(
			ui,
			.Container,
			label="scratchpad-titlebar-tabs-region",
			style=alicorn.layout_style(.Row, width=tab_width, height=metrics.header.h, align=.Center, clip=true),
		)
		scratchpad_content_titlebar_region_add(app, tab_region, .Interactive)
		scratchpad_document_tabs_build(
			app, ui, rt,
			width=tab_width,
			height=min(SCRATCHPAD_CONTENT_TITLEBAR_TAB_HEIGHT, metrics.header.h),
			compact=true,
			show_empty=false,
		)
		alicorn.container_end(ui)
	}

	trailing_drag := alicorn.container_begin(
		ui,
		.Container,
		label="scratchpad-titlebar-trailing-drag",
		style=alicorn.layout_style(.Row, grow=1, height=metrics.header.h),
	)
	scratchpad_content_titlebar_region_add(app, trailing_drag, .Window_Drag)
	alicorn.container_end(ui)
	alicorn.container_end(ui)
	alicorn.container_end(ui)
}

scratchpad_document_tabs_build :: proc(
	app: ^App,
	ui: ^alicorn.UI,
	rt: ^alicorn.Runtime,
	width, height: f32,
	compact: bool,
	show_empty: bool,
) {
	if app == nil || ui == nil || rt == nil { return }
	state := &app.backend.state
	detached_document_id := ""
	if app.floating_window != nil { detached_document_id = app.floating_window.document_id }
	tab_document_indices := floating_window_tab_document_indices(state.documents, detached_document_id, context.temp_allocator)
	defer delete(tab_document_indices)
	if len(tab_document_indices) == 0 {
		if show_empty {
			empty_label := "No documents open" if len(state.documents) == 0 else "No documents in this window"
			alicorn.text(ui, empty_label, style=alicorn.layout_style(.Row, grow=1, height=height))
		}
		return
	}
	tab_items := make([dynamic]alicorn.Tab_Bar_Item, 0, len(tab_document_indices), allocator=context.temp_allocator)
	defer delete(tab_items)
	for index in tab_document_indices {
		document := state.documents[index]
		title := document_title(document.path)
		is_preview := document.preview && !document.dirty
		append(&tab_items, alicorn.Tab_Bar_Item{
			key=alicorn.key_string(document.id),
			label=title,
			label_italic=is_preview,
			label_muted=is_preview,
			tooltip=title,
			selected=state.active == document.id,
			closable=true,
			dirty=document.dirty,
			semantic_id=document_tab_semantic_id(document.id),
		})
	}
	tab_options := alicorn.DEFAULT_TAB_BAR_OPTIONS
	tab_options.height = height
	tab_options.close_policy = .Selected_Or_Hover
	tab_options.drag_type = SCRATCHPAD_DRAG_TABS
	tab_style := alicorn.layout_style(.Row, grow=1, height=height, clip=true)
	if compact {
		tab_options.min_tab_width = SCRATCHPAD_CONTENT_TITLEBAR_MIN_TAB_WIDTH
		tab_options.max_tab_width = 180
		tab_options.gap = 0
		tab_options.presentation = .Compact
		tab_style = alicorn.layout_style(.Row, width=width, height=height, clip=true)
	}
	tab_result := alicorn.tab_bar(
		ui,
		alicorn.key_string("scratchpad-document-tab-bar"),
		tab_items[:],
		tab_options,
		tab_style,
	)
	if tab_result.action != .None && tab_result.item_index >= 0 && tab_result.item_index < len(tab_document_indices) {
		document_id := state.documents[tab_document_indices[tab_result.item_index]].id
		action := Deferred_Action_Kind.Select_Document if tab_result.action == .Select else Deferred_Action_Kind.Close_Document
		if !frame_deferred_action_schedule(app, action, document_id) {
			set_error(app, "Could not queue the document tab action until the current frame is complete.")
			alicorn.invalidate_root(rt, "Scratchpad could not defer a document tab action")
		}
	}
}
