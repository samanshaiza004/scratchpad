package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"
import bridge "./bridge"

ACTION_FILE_OPEN       :: "file.open"
ACTION_FILE_QUICK_OPEN :: "file.quick-open"
ACTION_WORKSPACE_OPEN  :: "workspace.open"
ACTION_FILE_SAVE       :: "file.save"
ACTION_FILE_SAVE_AS    :: "file.save-as"
ACTION_DOCUMENT_CLOSE  :: "document.close"
ACTION_TAB_NEXT        :: "tab.next"
ACTION_TAB_PREVIOUS    :: "tab.previous"
ACTION_DOCUMENT_FORMAT :: "document.format"
ACTION_DOCUMENT_GO_TO_LINE :: "document.go-to-line"
ACTION_DOCUMENT_TOGGLE_WRAP :: "document.toggle-wrap"
ACTION_VIEW_COMMAND_PALETTE :: "view.command-palette"
ACTION_MARKDOWN_TABLE_NEXT :: "markdown.table-next"
ACTION_MARKDOWN_TABLE_PREVIOUS :: "markdown.table-previous"
ACTION_MARKDOWN_TABLE_ENTER :: "markdown.table-enter"
ACTION_MARKDOWN_ENTER :: "markdown.enter"
ACTION_MARKDOWN_TOGGLE_STRONG :: "markdown.toggle-strong"
ACTION_MARKDOWN_TOGGLE_EMPHASIS :: "markdown.toggle-emphasis"
ACTION_MARKDOWN_TOGGLE_STRIKE :: "markdown.toggle-strike"
ACTION_MARKDOWN_TOGGLE_INLINE_CODE :: "markdown.toggle-inline-code"
ACTION_MARKDOWN_INSERT_LINK :: "markdown.insert-link"
ACTION_MARKDOWN_HEADING_1 :: "markdown.heading-1"
ACTION_MARKDOWN_HEADING_2 :: "markdown.heading-2"
ACTION_MARKDOWN_HEADING_3 :: "markdown.heading-3"
ACTION_MARKDOWN_TOGGLE_BULLETED_LIST :: "markdown.toggle-bulleted-list"
ACTION_MARKDOWN_TOGGLE_NUMBERED_LIST :: "markdown.toggle-numbered-list"
ACTION_MARKDOWN_TOGGLE_QUOTE :: "markdown.toggle-quote"
ACTION_MARKDOWN_INSERT_TASK :: "markdown.insert-task"
ACTION_MARKDOWN_INSERT_CODE_BLOCK :: "markdown.insert-code-block"
ACTION_MARKDOWN_SET_FENCE_LANGUAGE :: "markdown.set-fence-language"
ACTION_MARKDOWN_INSERT_TABLE :: "markdown.insert-table"
ACTION_MARKDOWN_INSERT_DIVIDER :: "markdown.insert-divider"
ACTION_MARKDOWN_SMART_PASTE :: "markdown.smart-paste"
ACTION_ITEM_TOGGLE :: "item.toggle"
ACTION_WORKSPACE_REFRESH :: "workspace.refresh"
ACTION_WORKSPACE_NEW_FILE :: "workspace.new-file"
ACTION_WORKSPACE_NEW_FOLDER :: "workspace.new-folder"
ACTION_WORKSPACE_SETTINGS :: "workspace.settings"
ACTION_WORKSPACE_RENAME :: "workspace.rename"
ACTION_WORKSPACE_MOVE :: "workspace.move"
ACTION_WORKSPACE_TRASH :: "workspace.trash"
ACTION_EDIT_UNDO       :: "edit.undo"
ACTION_EDIT_REDO       :: "edit.redo"
ACTION_EDIT_CUT        :: "edit.cut"
ACTION_EDIT_COPY       :: "edit.copy"
ACTION_EDIT_PASTE      :: "edit.paste"
ACTION_EDIT_SELECT_ALL :: "edit.select_all"
ACTION_EDIT_DELETE_LINE :: "edit.delete-line"
ACTION_EDIT_INDENT_LINES :: "edit.indent-lines"
ACTION_EDIT_OUTDENT_LINES :: "edit.outdent-lines"
ACTION_EDIT_INSERT_LINE_ABOVE :: "edit.insert-line-above"
ACTION_EDIT_INSERT_LINE_BELOW :: "edit.insert-line-below"
ACTION_EDIT_MOVE_LINE_UP :: "edit.move-line-up"
ACTION_EDIT_MOVE_LINE_DOWN :: "edit.move-line-down"
ACTION_EDIT_DUPLICATE_LINE :: "edit.duplicate-line"
ACTION_EDIT_JOIN_LINES :: "edit.join-lines"
ACTION_COMMENT_TOGGLE :: "comment.toggle"
ACTION_VIEW_EDITOR_ZOOM_IN :: "view.editor-zoom-in"
ACTION_VIEW_EDITOR_ZOOM_OUT :: "view.editor-zoom-out"
ACTION_VIEW_EDITOR_ZOOM_RESET :: "view.editor-zoom-reset"
ACTION_VIEW_THEME_WARM :: "view.theme-warm"
ACTION_VIEW_THEME_COOL_LIGHT :: "view.theme-cool-light"

App :: struct {
	workbench_theme: alicorn.Style_Theme_ID,
	editor_theme:    alicorn.Style_Theme_ID,
	warm_workbench_theme: alicorn.Style_Theme_ID,
	warm_editor_theme: alicorn.Style_Theme_ID,
	cool_light_theme: alicorn.Style_Theme_ID,
	theme_choice: Scratchpad_Theme_Choice,
	theme_preferences_directory: string,
	theme_preferences_path: string,
	accessibility_appearance: alicorn.Accessibility_Appearance_Preferences,
	accessibility_appearance_override_enabled: bool,
	style_theme_runtime: ^alicorn.Runtime,
	paper_surface_material: alicorn.Material_ID,
	raised_surface_material: alicorn.Material_ID,
	floating_surface_material: alicorn.Material_ID,
	backend:                bridge.Backend,
	visible_window_lane:    bridge.Visible_Window_Lane,
	accessibility_source_lane: Accessibility_Source_Lane,
	accessibility_projection: Editor_Accessibility_Projection,
	accessibility_source_error: string,
	accessibility_source_error_document_id: string,
	accessibility_source_error_revision: u64,
	accessibility_semantic_area_id: alicorn.Semantic_ID,
	accessibility_semantic_revision: u64,
	accessibility_semantic_has_runs: bool,
	accessibility_semantic_run_count: int,
	editor_edit_lane:       bridge.Editor_Edit_Lane,
	quick_open_lane:        bridge.Workspace_Files_Lane,
	editor_edits:           [dynamic]Editor_Edit_Intent,
	deferred_actions:       [dynamic]Deferred_Action,
	editor_edit_sequence:   u64,
	editor_views:           [dynamic]Editor_View_State,
	editor_row_targets:     [dynamic]Editor_Row_Target,
	editor_window:          Editor_Window,
	editor_window_ready:    bool,
	editor_text_scale:      f32,
	editor_request_generation: u64,
	editor_scroll_owner:    alicorn.Node_ID,
	editor_restore_scroll:  bool,
	editor_restore_vertical: bool,
	editor_restore_horizontal: bool,
	editor_restore_x:       f32,
	editor_restore_y:       f32,
	editor_presented_document_id: string,
	editor_input_anchor_node: alicorn.Node_ID,
	editor_input_anchor_byte: int,
	editor_input_anchor_affinity: alicorn.Text_Affinity,
	editor_window_error:    string,
	editor_window_rejected_request: bridge.Visible_Window_Request,
	editor_window_request_rejected: bool,
	waker:                  host.Application_Waker,
	services:               host.Application_Services,
	workspace_path:         string,
	backend_library:        string,
	error_message:          string,
	recovery_notice_dismissed: bool,
	close_document_id:      string,
	save_as_confirmation_open: bool,
	save_as_confirmation_document_id: string,
	save_as_confirmation_path: string,
	save_as_confirmation_token: u64,
	dialog_document_id:     string,
	shutdown_intent:        Shutdown_Intent,
	shutdown_edit_failed:   bool,
	tree_root_path:         string,
	tree_directories:       [dynamic]Tree_Directory,
	tree_focused_path:      string,
	tree_focused_is_dir:    bool,
	workspace_context_target: Workspace_Context_Target,
	workspace_context_path: string,
	workspace_context_is_dir: bool,
	workspace_drag_kind: Scratchpad_Drag_Kind,
	workspace_drag_source_document_id: string,
	workspace_drag_source_path: string,
	workspace_drag_source_is_dir: bool,
	workspace_mutation_kind: Workspace_Mutation_Kind,
	workspace_mutation_source: string,
	workspace_mutation_name: string,
	workspace_mutation_error: string,
	workspace_mutation_name_node: alicorn.Node_ID,
	workspace_mutation_focus_pending: bool,
	workspace_mutation_restore_pending: bool,
	workspace_mutation_restore_editor: bool,
	workspace_mutation_restore_node: alicorn.Node_ID,
	workspace_mutation_restore_semantic: alicorn.Semantic_Focus_State,
	workspace_mutation_source_is_dir: bool,
	workspace_mutation_dirty: bool,
	workspace_editor_split_node: alicorn.Node_ID,
	workspace_mutation_queued: bool,
	frame_deferred_action: Deferred_Action,
	frame_deferred_action_pending: bool,
	show_ignored_files:     bool,
	settings_surface_open:  bool,
	workspace_search_mode:  bool,
	workspace_search_query: string,
	workspace_search_started_query: string,
	workspace_search_started_root: string,
	workspace_search_query_node: alicorn.Node_ID,
	workspace_search_focus_pending: bool,
	workspace_search_generation: u64,
	workspace_search_view: Workspace_Search_View,
	workspace_search_error: string,
	workspace_search_selected: int,
	workspace_search_results_owner: alicorn.Node_ID,
	find_open:              bool,
	find_query:             string,
	find_replace_text:      string,
	find_match_case:        bool,
	find_whole_word:        bool,
	find_query_node:        alicorn.Node_ID,
	find_replace_node:      alicorn.Node_ID,
	find_focus_pending:     bool,
	find_select_query_pending: bool,
	find_restore_pending:   bool,
	find_restore_valid:     bool,
	find_restore_document_id: string,
	find_restore_anchor:    u64,
	find_restore_caret:     u64,
	find_restore_anchor_affinity: alicorn.Text_Affinity,
	find_restore_caret_affinity: alicorn.Text_Affinity,
	editor_focus_pending:   bool,
	find_presentation:      Find_Presentation,
	find_error:             string,
	find_replace_message:   string,
	go_to_line_open:        bool,
	go_to_line_query:       string,
	go_to_line_query_node:  alicorn.Node_ID,
	go_to_line_focus_pending: bool,
	go_to_line_error:       string,
	command_palette_open: bool,
	command_palette_query: string,
	command_palette_node: alicorn.Node_ID,
	command_palette_overlay_node: alicorn.Node_ID,
	command_palette_panel_node: alicorn.Node_ID,
	command_palette_results_scroll_node: alicorn.Node_ID,
	command_palette_focus_pending: bool,
	command_palette_restore_pending: bool,
	command_palette_previous_focus: alicorn.Node_ID,
	command_palette_selected_index: int,
	command_palette_recent: [8]host.Application_Command_ID,
	command_palette_recent_count: int,
	quick_open_open: bool,
	quick_open_query: string,
	quick_open_node: alicorn.Node_ID,
	quick_open_overlay_node: alicorn.Node_ID,
	quick_open_panel_node: alicorn.Node_ID,
	quick_open_results_scroll_node: alicorn.Node_ID,
	quick_open_focus_pending: bool,
	quick_open_restore_pending: bool,
	quick_open_previous_focus: alicorn.Node_ID,
	quick_open_selected_index: int,
	quick_open_generation: u64,
	quick_open_path_root: string,
	quick_open_paths: []string,
	quick_open_truncated: bool,
	quick_open_loading: bool,
	quick_open_ready: bool,
	quick_open_error: string,
	tree_scroll_owner:      alicorn.Node_ID,
	dialog_sequence:        u64,
	dialog_action:          string,
	file_items:             [7]host.Application_Menu_Item,
	edit_items:             [10]host.Application_Menu_Item,
	workspace_items:        [6]host.Application_Menu_Item,
	document_items:         [11]host.Application_Menu_Item,
	view_items:             [8]host.Application_Menu_Item,
	menus:                  [5]host.Application_Menu,
	smoke:                  bool,
	smoke_rendered:         bool,
	smoke_wake_observed:    bool,
	smoke_shutdown:         bool,
}

editor_window_request_is_rejected :: proc(app: ^App, request: bridge.Visible_Window_Request) -> bool {
	return app != nil && app.editor_window_request_rejected &&
	       bridge.visible_window_request_equal(app.editor_window_rejected_request, request)
}

editor_window_rejection_clear :: proc(app: ^App) {
	if app == nil { return }
	if len(app.editor_window_rejected_request.document_id) > 0 {
		delete(app.editor_window_rejected_request.document_id, context.allocator)
	}
	app.editor_window_rejected_request = {}
	app.editor_window_request_rejected = false
}

editor_window_rejection_set :: proc(app: ^App, request: bridge.Visible_Window_Request) -> bool {
	if app == nil { return false }
	owned_document_id, clone_error := strings.clone(request.document_id, context.allocator)
	if clone_error != nil { return false }
	editor_window_rejection_clear(app)
	app.editor_window_rejected_request = request
	app.editor_window_rejected_request.document_id = owned_document_id
	app.editor_window_request_rejected = true
	return true
}

editor_metadata_result_should_suppress_retry :: proc(
	request: bridge.Visible_Window_Request,
	document: bridge.State_Document,
	window: bridge.Visible_Window,
) -> bool {
	return request.include_presentation &&
	       request.editor_revision == document.editor_revision &&
	       request.presentation_revision == document.presentation_revision &&
	       request.presentation_ready == document.presentation_ready &&
	       !window.presentation_ready
}

start_backend :: proc(app: ^App) {
	if app == nil { return }
	loaded, load_error := bridge.backend_load(&app.backend, app.backend_library)
	if !loaded { set_error(app, load_error); return }
	started, start_error := bridge.backend_start(&app.backend, app.workspace_path, app.waker.wake, app.waker.data)
	if !started { set_error(app, start_error) } else {
		lane_started := bridge.visible_window_lane_start(
			&app.visible_window_lane,
			&app.backend,
			app.waker.wake,
			app.waker.data,
		)
		if !lane_started {
			_, _ = bridge.backend_stop(&app.backend)
			set_error(app, "Could not start the bounded document-window worker.")
			return
		}
		edit_lane_started := bridge.editor_edit_lane_start(
			&app.editor_edit_lane,
			&app.backend,
			app.waker.wake,
			app.waker.data,
		)
		if !edit_lane_started {
			_ = bridge.visible_window_lane_stop(&app.visible_window_lane)
			_, _ = bridge.backend_stop(&app.backend)
			set_error(app, "Could not start the serial editor edit worker.")
			return
		}
		quick_open_lane_started := bridge.workspace_files_lane_start(
			&app.quick_open_lane,
			&app.backend,
			app.waker.wake,
			app.waker.data,
		)
		if !quick_open_lane_started {
			_ = bridge.editor_edit_lane_stop(&app.editor_edit_lane)
			_ = bridge.visible_window_lane_stop(&app.visible_window_lane)
			_, _ = bridge.backend_stop(&app.backend)
			set_error(app, "Could not start the asynchronous Quick Open file index worker.")
			return
		}
		accessibility_lane_started := accessibility_source_lane_start(
			&app.accessibility_source_lane,
			&app.backend,
			app.waker.wake,
			app.waker.data,
		)
		if !accessibility_lane_started {
			_ = bridge.workspace_files_lane_stop(&app.quick_open_lane)
			_ = bridge.editor_edit_lane_stop(&app.editor_edit_lane)
			_ = bridge.visible_window_lane_stop(&app.visible_window_lane)
			_, _ = bridge.backend_stop(&app.backend)
			set_error(app, "Could not start the active-document accessibility source worker.")
			return
		}
	app.recovery_notice_dismissed = false
		set_error(app, "")
		tree_sync_workspace(app)
	}
}

stop_backend :: proc(app: ^App) -> (stopped: bool, message: string) {
	if app == nil { return false, "application state is unavailable" }
	if !bridge.workspace_files_lane_stop(&app.quick_open_lane) {
		return false, "Quick Open file index worker did not join cleanly"
	}
	if !bridge.visible_window_lane_stop(&app.visible_window_lane) {
		return false, "visible-window worker did not join cleanly"
	}
	if !accessibility_source_lane_stop(&app.accessibility_source_lane) {
		return false, "accessibility source worker did not join cleanly"
	}
	if !editor_flush_pending_edits(app) {
		return false, "pending editor edits did not drain cleanly"
	}
	if !bridge.editor_edit_lane_stop(&app.editor_edit_lane) {
		return false, "editor edit worker did not join cleanly"
	}
	_, _, _ = bridge.backend_consume_wake(&app.backend)
	return bridge.backend_stop(&app.backend)
}

application_start :: proc(state: rawptr, waker: host.Application_Waker) {
	app := cast(^App)state
	app.waker = waker
	start_backend(app)
}

application_services :: proc(state: rawptr, services: host.Application_Services) {
	app := cast(^App)state
	app.services = services
}

editor_capture_source_anchor_before_publication :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil || !app.editor_window_ready || app.editor_scroll_owner == 0 { return }
	window := &app.editor_window
	if window.document_id == "" || window.document_id != app.backend.state.active { return }
	document, found := find_document(&app.backend.state, window.document_id)
	if !found || document.editor_revision == window.editor_revision { return }
	view_index := editor_view_find(app.editor_views[:], window.document_id)
	if view_index < 0 { return }
	view := &app.editor_views[view_index]
	if view.optimistic_pending_edits > 0 { return }
	if view.viewport_anchor_skip_next_source_change {
		view.viewport_anchor_skip_next_source_change = false
		view.viewport_anchor_pending = false
		view.viewport_anchor_resolved = false
		return
	}
	if !view.wrap_height_index_ready { return }
	scroll := alicorn.scroll_region_state(rt, app.editor_scroll_owner)
	if scroll.id == 0 { return }
	_, viewport_height := editor_wrap_viewport_size(app, rt, view, scroll)
	metrics := alicorn.virtual_list_variable_metrics(&view.wrap_height_index, scroll.offset_y, viewport_height)
	line_number := max(metrics.first, 0)
	line, line_found := editor_window_line(window, u64(line_number))
	if !line_found { return }
	line_top := alicorn.virtual_list_height_index_item_top(&view.wrap_height_index, line_number)
	view.viewport_anchor_byte = line.source_start
	view.viewport_anchor_revision = window.editor_revision
	view.viewport_anchor_line = u64(line_number)
	view.viewport_anchor_offset = scroll.offset_y-line_top
	view.viewport_anchor_pending = true
	view.viewport_anchor_resolved = false
}

application_wake :: proc(state: rawptr, rt: ^alicorn.Runtime) {
	app := cast(^App)state
	if !app.backend.started { return }
	app.smoke_wake_observed = true
	if !bridge.editor_edit_lane_is_active(&app.editor_edit_lane) {
		changed, ok, message := bridge.backend_consume_wake(&app.backend)
		if !ok { set_error(app, message); alicorn.invalidate_root(rt, "Scratchpad backend state read failed"); return }
		if changed {
			editor_capture_source_anchor_before_publication(app, rt)
			sync_runtime_actions(app, rt)
			sync_menu_states(app)
			tree_sync_workspace(app, rt)
			editor_views_prune(app)
			editor_window_rejection_clear(app)
			alicorn.invalidate_root(rt, "Scratchpad Caliber state publication")
		}
	}
	_ = workspace_search_sync_wake(app, rt)
	quick_open_take_completion(app, rt)
	window_result, window_found := bridge.visible_window_lane_take(&app.visible_window_lane)
	if window_found {
		installed := false
		visible_error_changed := false
		active, active_found := find_document(&app.backend.state, app.backend.state.active)
		if window_result.generation == app.editor_request_generation && window_result.window_owned {
			if active_found && window_result.window.document_id == active.id && window_result.window.editor_revision == active.editor_revision {
				view_index := editor_view_find(app.editor_views[:], active.id)
				pending_edits := view_index >= 0 && app.editor_views[view_index].optimistic_pending_edits > 0
				window, converted, conversion_error := editor_window_from_visible(&window_result.window)
				if view_index >= 0 && window_result.request.has_source_anchor {
					view := &app.editor_views[view_index]
					if converted && window.has_source_anchor {
						view.viewport_anchor_byte = window.source_anchor_byte
						view.viewport_anchor_line = window.source_anchor_line
						view.viewport_anchor_revision = window.editor_revision
						view.viewport_anchor_resolved = true
					} else if converted {
						view.viewport_anchor_pending = false
						view.viewport_anchor_resolved = false
					}
				}
				if converted && pending_edits {
					view := &app.editor_views[view_index]
					if editor_window_chase_pending_edits(app, &window, view) {
						editor_window_destroy(&view.optimistic_window)
						view.optimistic_window = window
						view.optimistic_window_ready = true
						installed = true
						editor_window_rejection_clear(app)
						if len(app.editor_window_error) > 0 { delete(app.editor_window_error, context.allocator) }
						app.editor_window_error = ""
					} else {
						// A parser response outside the bounded optimistic source window
						// cannot be safely chased. Keep the current text and retry after
						// the edit queue or request window changes.
						_ = editor_window_rejection_set(app, window_result.request)
						editor_window_destroy(&window)
					}
				} else if converted {
						if view_index >= 0 && app.editor_views[view_index].optimistic_window_ready {
							editor_window_destroy(&app.editor_views[view_index].optimistic_window)
							app.editor_views[view_index].optimistic_window_ready = false
						}
						advancing_long_line := app.editor_window_ready &&
						                       app.editor_window.document_id == window.document_id &&
						                       app.editor_window.editor_revision == window.editor_revision &&
						                       app.editor_window.start_line == window.start_line &&
						                       window.start_byte > app.editor_window.start_byte &&
						                       window.line_byte_length == app.editor_window.line_byte_length
						editor_window_destroy(&app.editor_window)
						app.editor_window = window
						app.editor_window_ready = true
						if view_index >= 0 {
							view := &app.editor_views[view_index]
							if view.optimistic_pending_edits == 0 && view.authoritative_revision != 0 &&
							   view.authoritative_revision != window.editor_revision {
								editor_wrap_heights_reset(view, int(active.line_count), editor_text_scale_effective(app))
							}
							view.authoritative_revision = window.editor_revision
							if view.position_reconcile_pending {
								_ = editor_view_reconcile_positions(view, &app.editor_window)
							}
						}
						if advancing_long_line && app.editor_scroll_owner != 0 {
							_ = alicorn.scroll_region_set_offset_x(rt, app.editor_scroll_owner, 0, "advance bounded long-line chunk")
						}
						editor_window_rejection_clear(app)
						if editor_metadata_result_should_suppress_retry(window_result.request, active, window_result.window) {
							// Prevent an unchanged not-ready result from causing a request on
							// every retained frame. A later state publication clears this
							// request identity and allows the exact revision to be retried.
							_ = editor_window_rejection_set(app, window_result.request)
						}
						if len(app.editor_window_error) > 0 { delete(app.editor_window_error, context.allocator) }
						app.editor_window_error = ""
						installed = true
						if strings.has_prefix(app.error_message, "Edit was not accepted; reloading authoritative text:") {
							set_error(app, "")
						}
				} else if pending_edits && editor_metadata_result_should_suppress_retry(window_result.request, active, window_result.window) {
					// Parser work has not caught this revision yet. Keep the optimistic
					// text and avoid retrying the same not-ready response every frame.
					_ = editor_window_rejection_set(app, window_result.request)
				} else {
					_ = editor_window_rejection_set(app, window_result.request)
					if len(app.editor_window_error) > 0 { delete(app.editor_window_error, context.allocator) }
					app.editor_window_error, _ = strings.clone(conversion_error, context.allocator)
					visible_error_changed = true
				}
			} else if active_found && window_result.window.document_id == active.id {
				_ = editor_window_rejection_set(app, window_result.request)
				if len(app.editor_window_error) > 0 { delete(app.editor_window_error, context.allocator) }
				message := fmt.tprintf(
					"response revision %d does not match published editor revision %d",
					window_result.window.editor_revision,
					active.editor_revision,
				)
				owned_error, clone_error := strings.clone(message, context.allocator)
				if clone_error == nil { app.editor_window_error = owned_error }
				visible_error_changed = true
			}
		} else if window_result.generation == app.editor_request_generation && window_result.error != "" {
			_ = editor_window_rejection_set(app, window_result.request)
			if len(app.editor_window_error) > 0 { delete(app.editor_window_error, context.allocator) }
			app.editor_window_error, _ = strings.clone(window_result.error, context.allocator)
			visible_error_changed = true
		}
		bridge.visible_window_lane_result_destroy(&window_result, app.visible_window_lane.allocator)
		if installed || visible_error_changed {
			alicorn.invalidate_root(rt, "Scratchpad bounded editor window completed")
		}
	}
	edit_result, edit_found := bridge.editor_edit_lane_take(&app.editor_edit_lane)
	if edit_found {
		editor_handle_edit_result(app, rt, &edit_result)
		bridge.editor_edit_lane_result_destroy(&edit_result, app.editor_edit_lane.allocator)
		alicorn.invalidate_root(rt, "Scratchpad optimistic editor edit acknowledged")
	}
	editor_accessibility_take_completion(app, rt)
	editor_accessibility_requests_drain(app, rt)
	shutdown_advance(app, rt)
}

// Apply every still-unacknowledged local edit that follows an authoritative
// parser window, so a useful Goldmark result can catch up with the text already
// visible in Alicorn. Edit coordinates are revision-scoped and applied in queue
// order, matching the serial backend lane.
editor_window_chase_pending_edits :: proc(
	app: ^App,
	window: ^Editor_Window,
	view: ^Editor_View_State,
) -> bool {
	if app == nil || window == nil || view == nil || !view.optimistic_window_ready ||
	   !window.presentation_ready || window.presentation_revision != window.editor_revision {
		return false
	}
	base_revision := window.editor_revision
	for intent in app.editor_edits {
		if intent.document_id != window.document_id || intent.base_editor_revision < base_revision { continue }
		next, replaced, _ := editor_window_replace_bytes(
			window,
			intent.start_byte,
			intent.end_byte,
			intent.replacement,
		)
		if !replaced { return false }
		editor_window_destroy(window)
		window^ = next
	}
	target := &view.optimistic_window
	if target.document_id != window.document_id || target.start_line != window.start_line ||
	   target.end_line != window.end_line || target.start_byte != window.start_byte ||
	   len(target.source) != len(window.source) {
		return false
	}
	for index in 0..<len(window.source) {
		if target.source[index] != window.source[index] { return false }
	}
	return true
}

application_scheduled_wake :: proc(state: rawptr, rt: ^alicorn.Runtime, class: host.Scheduled_Wake_Class) {
	if class != .Frequent { return }
	app := cast(^App)state
	if app == nil || !app.backend.started { return }
	if document, found := find_document(&app.backend.state, app.backend.state.active); found {
		if view_index := editor_view_find(app.editor_views[:], document.id); view_index >= 0 {
			view := &app.editor_views[view_index]
			if view.dragging_selection && view.drag_pointer_valid {
				_ = editor_update_pointer_selection(app, rt, view)
				return
			}
		}
	}
	editor_schedule_selection_autoscroll(app, false)
}

go_to_line_open_surface :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil || !app.backend.started { return }
	if _, found := find_document(&app.backend.state, app.backend.state.active); !found { return }
	app.go_to_line_open = true
	app.go_to_line_query_node = 0
	app.go_to_line_focus_pending = true
	find_set_message(&app.go_to_line_query, "")
	find_set_message(&app.go_to_line_error, "")
	app.find_focus_pending = false
	app.editor_focus_pending = false
	alicorn.invalidate_root(rt, "Scratchpad Go to Line opened")
}

go_to_line_close :: proc(app: ^App, rt: ^alicorn.Runtime, restore_editor: bool) {
	if app == nil { return }
	app.go_to_line_open = false
	app.go_to_line_focus_pending = false
	app.go_to_line_query_node = 0
	find_set_message(&app.go_to_line_error, "")
	if restore_editor { app.editor_focus_pending = true }
	if rt != nil { alicorn.invalidate_root(rt, "Scratchpad Go to Line closed") }
}

go_to_line_parse_decimal :: proc(text: string) -> (value: u64, ok: bool) {
	if len(text) == 0 { return 0, false }
	for character in text {
		if character < '0' || character > '9' { return 0, false }
		digit := u64(character-'0')
		if value > (0xFFFF_FFFF_FFFF_FFFF-digit)/10 { return 0, false }
		value = value*10+digit
	}
	return value, true
}

go_to_line_parse :: proc(query: string, line_count: u64) -> (line, column: u64, ok: bool) {
	start, end := 0, len(query)
	for start < end && (query[start] == ' ' || query[start] == '\t') { start += 1 }
	for end > start && (query[end-1] == ' ' || query[end-1] == '\t') { end -= 1 }
	if start == end || line_count == 0 { return 0, 0, false }
	colon := -1
	for index in start..<end {
		if query[index] == ':' {
			if colon >= 0 { return 0, 0, false }
			colon = index
		}
	}
	line_end := end if colon < 0 else colon
	parsed_line, line_ok := go_to_line_parse_decimal(query[start:line_end])
	if !line_ok || parsed_line == 0 { return 0, 0, false }
	column = 1
	if colon >= 0 {
		column, ok = go_to_line_parse_decimal(query[colon+1:end])
		if !ok || column == 0 { return 0, 0, false }
	}
	line = min(parsed_line, line_count)-1
	return line, column, true
}

go_to_line_submit :: proc(app: ^App, rt: ^alicorn.Runtime) -> bool {
	if app == nil || rt == nil || !app.backend.started { return true }
	document, found := find_document(&app.backend.state, app.backend.state.active)
	if !found { app.go_to_line_error = "No active document."; return true }
	line_count := document.line_count
	if view_index := editor_view_find(app.editor_views[:], document.id); view_index >= 0 {
		view := &app.editor_views[view_index]
		if view.optimistic_pending_edits > 0 {
			if view.optimistic_line_delta < 0 {
				removed := u64(-view.optimistic_line_delta)
				line_count = line_count-removed if removed < line_count else 1
			} else { line_count += u64(view.optimistic_line_delta) }
		}
	}
	target_line, column, parsed := go_to_line_parse(app.go_to_line_query, line_count)
	if !parsed {
		find_set_message(&app.go_to_line_error, "Enter a line number or line:column (both start at 1).")
		alicorn.invalidate_root(rt, "Scratchpad Go to Line input was invalid")
		return true
	}
	view_index, view_ok := editor_view_ensure(&app.editor_views, document.id)
	if !view_ok { app.go_to_line_error = "Could not retain the active document view."; return true }
	view := &app.editor_views[view_index]
	view.pending_goto_line = true
	view.pending_goto_target_line = target_line
	view.pending_goto_column = column
	view.preferred_x_set = false
	view.viewport_anchor_pending = false
	view.viewport_anchor_resolved = false
	if window, exact := editor_view_window(view, &app.editor_window, app.editor_window_ready, document.id, document.editor_revision); exact {
		if editor_view_resolve_goto_line(view, window, line_count) { view.pending_goto_target_line = target_line }
	}
	app.go_to_line_open = false
	app.go_to_line_query_node = 0
	app.go_to_line_focus_pending = false
	app.editor_focus_pending = true
	alicorn.invalidate_root(rt, "Scratchpad Go to Line requested its bounded source window")
	return true
}

application_key :: proc(state: rawptr, rt: ^alicorn.Runtime, key: host.Application_Key) -> bool {
	app := cast(^App)state
	if app.shutdown_intent != .None {
		if key == .Escape { shutdown_cancel(app, rt); return true }
		return key != .Return
	}
	if app.save_as_confirmation_open {
		if key == .Escape { save_as_cancel_overwrite(app, rt); return true }
		if key == .Return { save_as_confirm_overwrite(app, rt); return true }
		return true
	}
	if app.close_document_id != "" {
		if key == .Escape {
			clear_close_prompt(app)
			deferred_actions_run(app, rt)
			alicorn.invalidate_root(rt, "dirty close cancelled by Escape")
			return true
		}
		return key != .Return
	}
	if app.command_palette_open {
		#partial switch key {
		case .Open_Command_Palette, .Escape:
			command_palette_close_surface(app, rt, true)
			return true
		case .Return:
			return command_palette_execute_selected(app, rt)
		case .Up:
			return command_palette_move_selection(app, rt, -1)
		case .Down:
			return command_palette_move_selection(app, rt, 1)
		case:
			return false
		}
	}
	if app.quick_open_open { return quick_open_handle_key(app, rt, key) }
	if app.go_to_line_open {
		if key == .Escape { go_to_line_close(app, rt, true); return true }
		if key == .Return { return go_to_line_submit(app, rt) }
		return true
	}
	if app.workspace_mutation_kind != .None {
		return workspace_mutation_handle_key(app, rt, key)
	}
	if app.settings_surface_open {
		return settings_surface_handle_key(app, rt, key)
	}
	if key == .Tab_Next {
		navigate_tab(app, rt, 1)
		return true
	}
	if key == .Tab_Previous {
		navigate_tab(app, rt, -1)
		return true
	}
	if key == .Zoom_In { return editor_text_zoom_step(app, rt, 1) }
	if key == .Zoom_Out { return editor_text_zoom_step(app, rt, -1) }
	if key == .Zoom_Reset { return editor_text_zoom_set(app, rt, 1) }
	if key == .Open_Command_Palette {
		command_palette_open_surface(app, rt)
		return true
	}
	if key == .Context_Menu {
		return workspace_context_menu_open_focused(app, rt)
	}
	if key == .Workspace_Rename {
		if app.tree_scroll_owner != 0 && alicorn.focused_node(rt) == app.tree_scroll_owner && app.tree_focused_path != "" {
			workspace_mutation_open_selected(app, rt, .Rename)
			return true
		}
		return false
	}
	if key == .Find {
		find_open_surface(app)
		alicorn.invalidate_root(rt, "Scratchpad Find opened")
		return true
	}
	if key == .Workspace_Search {
		if app.find_open { find_close_surface(app) }
		app.workspace_search_mode = true
		app.workspace_search_focus_pending = true
		app.editor_focus_pending = false
		alicorn.invalidate_root(rt, "Scratchpad Workspace Search opened")
		return true
	}
	if app.workspace_search_mode && alicorn.focused_node(rt) == app.workspace_search_query_node {
		#partial switch key {
		case .Up:
			return workspace_search_move_selection(app, rt, -1)
		case .Down:
			return workspace_search_move_selection(app, rt, 1)
		case:
		}
	}
	if key == .Find_Next {
		return find_move_match(app, rt, 1)
	}
	if key == .Find_Previous {
		return find_move_match(app, rt, -1)
	}
	if key == .Escape && app.find_open {
		find_close_surface(app)
		alicorn.invalidate_root(rt, "Scratchpad Find closed")
		return true
	}
	if key == .Escape && app.workspace_search_mode {
		workspace_search_cancel_active(app)
		workspace_search_match_clear_all(app)
		app.workspace_search_mode = false
		app.workspace_search_query_node = 0
		app.editor_focus_pending = true
		alicorn.invalidate_root(rt, "Scratchpad Workspace Search closed")
		return true
	}
	if key == .Return && app.find_open && alicorn.focused_node(rt) == app.find_query_node {
		return find_move_match(app, rt, 1)
	}
	if key == .Return && app.find_open && alicorn.focused_node(rt) == app.find_replace_node {
		return find_replace_current(app, rt)
	}
	if key == .Return && app.workspace_search_mode && alicorn.focused_node(rt) == app.workspace_search_query_node {
		if len(app.workspace_search_view.results) > 0 {
			index := app.workspace_search_selected
			if index < 0 || index >= len(app.workspace_search_view.results) { index = 0 }
			return workspace_search_activate_result(app, rt, index)
		}
		if !app.workspace_search_view.done { workspace_search_start_query(app, rt) }
		return true
	}
	if key == .Return && app.editor_scroll_owner != 0 && alicorn.focused_node(rt) == app.editor_scroll_owner {
		if document, found := find_document(&app.backend.state, app.backend.state.active); found && document.language == "markdown" {
			if view_index := editor_view_find(app.editor_views[:], document.id); view_index >= 0 {
				view := &app.editor_views[view_index]
				window, window_matches := editor_view_window(view, &app.editor_window, app.editor_window_ready, document.id, document.editor_revision)
				if window_matches && editor_cursor_in_markdown_table(window, view.caret_byte) {
					dispatch_action(app, rt, ACTION_MARKDOWN_TABLE_ENTER)
					return true
				}
			}
		}
		return editor_insert_newline(app, rt)
	}
	if app.tree_scroll_owner != 0 && alicorn.focused_node(rt) == app.tree_scroll_owner {
		#partial switch key {
		case .Left, .Right:
			return tree_move_horizontal_focus(app, rt, key)
		case .Up, .Down, .Page_Up, .Page_Down, .Home, .End:
			return tree_move_focus(app, rt, key)
		case .Return:
			return tree_activate_focused(app, rt)
		case:
		}
	}
	return false
}

editor_source_at_pointer :: proc(
	app: ^App,
	rt: ^alicorn.Runtime,
	x, y: f32,
	clamp_to_viewport := false,
) -> (source_byte: u64, affinity: alicorn.Text_Affinity, ok: bool) {
	if app == nil || rt == nil || app.editor_scroll_owner == 0 { return }
	owner, owner_found := alicorn.node_info(rt, app.editor_scroll_owner)
	if !owner_found || owner.scroll_viewport_width <= 0 || owner.scroll_viewport_height <= 0 { return }
	left, top := owner.bounds.x, owner.bounds.y
	right, bottom := left+owner.scroll_viewport_width, top+owner.scroll_viewport_height
	hit_x, hit_y := x, y
	if clamp_to_viewport {
		hit_x = min(max(x, left), right-0.5)
		hit_y = min(max(y, top), bottom-0.5)
	} else if hit_x < left || hit_x >= right || hit_y < top || hit_y >= bottom {
		return
	}
	document, found := find_document(&app.backend.state, app.backend.state.active)
	if !found { return }
	view_index, view_ok := editor_view_ensure(&app.editor_views, document.id)
	if !view_ok { return }
	view := &app.editor_views[view_index]
	window, window_matches := editor_view_window(view, &app.editor_window, app.editor_window_ready, document.id, document.editor_revision)
	if !window_matches { return }
	// Choose the realized row containing Y. During a captured drag, clamp into
	// the nearest realized row so leaving the viewport selects its visible edge
	// rather than dropping the interaction; scheduled autoscroll advances the
	// viewport and retries from the retained pointer coordinates.
	best_distance := f32(1e30)
	best_line: u64
	best_y := hit_y
	for row_target in app.editor_row_targets {
		row_node, row_found := alicorn.node_info(rt, row_target.node)
		if !row_found || row_node.bounds.h <= 0 { continue }
		if hit_y >= row_node.bounds.y && hit_y < row_node.bounds.y+row_node.bounds.h {
			best_line, best_y = row_target.logical_line, hit_y
			best_distance = 0
			break
		}
		row_y := min(max(hit_y, row_node.bounds.y), row_node.bounds.y+row_node.bounds.h-0.5)
		distance := abs(hit_y-row_y)
		if distance < best_distance {
			best_distance = distance
			best_line, best_y = row_target.logical_line, row_y
		}
	}
	if best_distance == 1e30 || (!clamp_to_viewport && best_distance > EDITOR_ROW_HEIGHT*editor_text_scale_effective(app)) { return }
	best_target: Editor_Row_Target
	best_x_distance := f32(1e30)
	best_hit_x := hit_x
	for target in app.editor_row_targets {
		if target.logical_line != best_line { continue }
		node, node_found := alicorn.node_info(rt, target.node)
		if !node_found { continue }
		distance: f32 = 0
		if hit_x < node.bounds.x { distance = node.bounds.x-hit_x }
		else if hit_x >= node.bounds.x+node.bounds.w { distance = hit_x-(node.bounds.x+node.bounds.w) }
		if distance < best_x_distance {
			best_x_distance = distance
			best_target = target
			best_hit_x = min(max(hit_x, node.bounds.x), node.bounds.x+node.bounds.w-0.5)
		}
	}
	if best_x_distance == 1e30 { return }
	line, line_found := editor_window_line(window, best_line)
	if !line_found { return }
	position, hit := alicorn.text_node_hit_test(rt, best_target.node, best_hit_x, best_y)
	if !hit { return }
	display_line, display_found := editor_display_line_for_target(window, line, best_target)
	if !display_found { return }
	return editor_normalize_source_position(&display_line, editor_display_to_source(&display_line, position.byte)), position.affinity, true
}

editor_ensure_line_visible :: proc(
	rt: ^alicorn.Runtime,
	view: ^Editor_View_State,
	owner: alicorn.Node_ID,
	logical_line: int,
	reason: string,
) -> bool {
	if view != nil && view.wrap_height_index_ready {
		return alicorn.virtual_list_variable_ensure_visible(
			rt, &view.wrap_height_index, owner, logical_line, reason,
		)
	}
	return alicorn.virtual_list_ensure_visible(rt, owner, logical_line, reason)
}

editor_pointer_outside_viewport :: proc(rt: ^alicorn.Runtime, owner_id: alicorn.Node_ID, x, y: f32) -> (outside: bool, dx, dy: f32) {
	if rt == nil || owner_id == 0 { return }
	owner, found := alicorn.node_info(rt, owner_id)
	if !found || owner.scroll_viewport_width <= 0 || owner.scroll_viewport_height <= 0 { return }
	left, top := owner.bounds.x, owner.bounds.y
	right, bottom := left+owner.scroll_viewport_width, top+owner.scroll_viewport_height
	if x < left { dx = -editor_selection_autoscroll_step(left-x) }
	if x >= right { dx = editor_selection_autoscroll_step(x-right+0.5) }
	if y < top { dy = -editor_selection_autoscroll_step(top-y) }
	if y >= bottom { dy = editor_selection_autoscroll_step(y-bottom+0.5) }
	return dx != 0 || dy != 0, dx, dy
}

editor_schedule_selection_autoscroll :: proc(app: ^App, outside: bool) {
	if app == nil { return }
	if outside {
		_ = host.application_schedule_after(app.services.scheduler, .Frequent, EDITOR_SELECTION_AUTOSCROLL_INTERVAL_NS)
	} else {
		_ = host.application_cancel_scheduled_wake(app.services.scheduler, .Frequent)
	}
}

editor_update_pointer_selection :: proc(app: ^App, rt: ^alicorn.Runtime, view: ^Editor_View_State) -> bool {
	if app == nil || rt == nil || view == nil || !view.dragging_selection || !view.drag_pointer_valid { return false }
	document, document_found := find_document(&app.backend.state, view.document_id)
	if !document_found || document.id != app.backend.state.active { return false }
	window, authoritative := editor_view_window(view, &app.editor_window, app.editor_window_ready, document.id, document.editor_revision)
	if !authoritative { return false }
	old_anchor, old_caret := view.selection_anchor, view.caret_byte
	old_anchor_affinity, old_caret_affinity := view.anchor_affinity, view.caret_affinity
	source_byte, affinity, hit := editor_source_at_pointer(app, rt, view.drag_pointer_x, view.drag_pointer_y, true)
	if hit { _ = editor_extend_pointer_selection(view, window, source_byte, affinity) }
	outside, dx, dy := editor_pointer_outside_viewport(rt, app.editor_scroll_owner, view.drag_pointer_x, view.drag_pointer_y)
	scrolled := false
	if outside {
		if owner, found := alicorn.node_info(rt, app.editor_scroll_owner); found {
			if dy != 0 { scrolled = alicorn.scroll_region_set_offset(rt, app.editor_scroll_owner, owner.scroll_offset_y+dy, "Scratchpad selection drag autoscrolled vertically") || scrolled }
			if dx != 0 { scrolled = alicorn.scroll_region_set_offset_x(rt, app.editor_scroll_owner, owner.scroll_offset_x+dx, "Scratchpad selection drag autoscrolled horizontally") || scrolled }
		}
	}
	editor_schedule_selection_autoscroll(app, outside && scrolled)
	changed := old_anchor != view.selection_anchor || old_caret != view.caret_byte ||
	           old_anchor_affinity != view.anchor_affinity || old_caret_affinity != view.caret_affinity
	if changed && !scrolled { alicorn.invalidate_root(rt, "Scratchpad editor pointer selection extended") }
	return changed || scrolled
}

// editor_presentation_window keeps a last-good projection visible across an
// authoritative revision change. The bool remains strict: only an exact
// revision match grants source/edit interaction authority.
editor_presentation_window :: proc(
	view: ^Editor_View_State,
	base: ^Editor_Window,
	base_ready: bool,
	document_id: string,
	editor_revision: u64,
) -> (window: ^Editor_Window, authoritative: bool) {
	window, authoritative = editor_view_window(view, base, base_ready, document_id, editor_revision)
	if authoritative { return }
	if view != nil && view.optimistic_window_ready && view.optimistic_window.document_id == document_id {
		// Keep the newest user-visible projection while a fresh authoritative
		// window is in flight. This snapshot is presentation-only: callers must
		// continue to use the strict authority result for editing and hit testing.
		return &view.optimistic_window, false
	}
	if base_ready && base != nil && base.document_id == document_id {
		// Revision mismatch invalidates interaction authority, not immediately
		// the pixels: this snapshot may remain visible until its replacement is
		// installed as one retained-tree update.
		return base, false
	}
	return nil, false
}

// Editor-local pointer placement is owned by the durable scroll region. The
// generic text-input owner captures the pointer; realized rows provide only
// shaped geometry, and Scratchpad retains caret/selection as source bytes.
editor_pointer :: proc(state: rawptr, rt: ^alicorn.Runtime, event: alicorn.Pointer_Event, target: alicorn.Node_ID) {
	app := cast(^App)state
	if app == nil || !app.backend.started || app.editor_scroll_owner == 0 { return }
	if event.kind == .Move {
		if captured, found := alicorn.node_info(rt, alicorn.captured_node(rt)); found &&
		   captured.kind == .Split_Handle && captured.split_owner == app.workspace_editor_split_node {
			// Alicorn marks retained layout dirty immediately, but Scratchpad's
			// sparse wrapped-row heights are application-owned and must be
			// remeasured for the new editor width. That measurement visits only
			// the bounded visible source window.
			alicorn.invalidate_root(rt, "Scratchpad editor width changed during split resize")
			return
		}
	}
	if event.kind == .Cancel || event.kind == .Up {
		drag_ended := false
		for &view in app.editor_views {
			if view.dragging_selection {
				view.dragging_selection = false
				view.drag_pointer_valid = false
				drag_ended = true
			}
		}
		editor_schedule_selection_autoscroll(app, false)
		if event.kind == .Up && drag_ended {
			alicorn.invalidate_root(rt, "Scratchpad editor pointer selection ended")
		}
		return
	}
	if event.kind == .Move {
		if document, found := find_document(&app.backend.state, app.backend.state.active); found {
			if view_index := editor_view_find(app.editor_views[:], document.id); view_index >= 0 {
				view := &app.editor_views[view_index]
				if view.dragging_selection && alicorn.captured_node(rt) == app.editor_scroll_owner {
					view.drag_pointer_x, view.drag_pointer_y = event.x, event.y
					view.drag_pointer_valid = true
					_ = editor_update_pointer_selection(app, rt, view)
					_ = alicorn.focus(rt, app.editor_scroll_owner)
				}
			}
		}
		return
	}
	if event.kind != .Down || event.button != 1 || target != app.editor_scroll_owner { return }
	document, found := find_document(&app.backend.state, app.backend.state.active)
	if !found { return }
	view_index, view_ok := editor_view_ensure(&app.editor_views, document.id)
	if !view_ok { return }
	view := &app.editor_views[view_index]
	if source_byte, affinity, ok := editor_source_at_pointer(app, rt, event.x, event.y); ok {
		editor_undo_group_break(view)
		view.pending_document_edge = .None
		view.pending_document_edge_shift = false
		window, authoritative := editor_view_window(view, &app.editor_window, app.editor_window_ready, document.id, document.editor_revision)
		if !authoritative || !editor_apply_pointer_selection(view, window, source_byte, affinity, event.click_count, event.modifiers.shift) { return }
		view.dragging_selection = true
		view.drag_pointer_x, view.drag_pointer_y = event.x, event.y
		view.drag_pointer_valid = true
		_ = alicorn.focus(rt, app.editor_scroll_owner)
		alicorn.invalidate_root(rt, "Scratchpad editor pointer selection placed")
	}
}

// Read-only movement stays entirely in the Alicorn frontend. It translates a
// caret through the bounded visible projection and never dispatches a Caliber
// document mutation.
editor_text_key :: proc(
	state: rawptr,
	rt: ^alicorn.Runtime,
	owner: alicorn.Node_ID,
	event: host.Application_Text_Key_Event,
) -> bool {
	app := cast(^App)state
	if app == nil || owner == 0 || owner != app.editor_scroll_owner || !app.backend.started { return false }
	document, found := find_document(&app.backend.state, app.backend.state.active)
	if !found { return false }
	view_index, view_ok := editor_view_ensure(&app.editor_views, document.id)
	if !view_ok { return false }
	view := &app.editor_views[view_index]
	window, window_matches := editor_view_window(view, &app.editor_window, app.editor_window_ready, document.id, document.editor_revision)
	if !window_matches { return false }
	if view.preedit_active {
		// The platform IME owns navigation/commit keys while it has an active
		// composition. Tab is consumed specifically to prevent the native host
		// from moving focus away before it can deliver the corresponding commit.
		if event.key == .Tab { return true }
		return false
	}
	if view.pending_document_edge != .None && event.key != .Document_Start && event.key != .Document_End {
		view.pending_document_edge = .None
		view.pending_document_edge_shift = false
	}
	if event.key == .Tab {
		if event.control || event.alt || event.super { return false }
		table_action := ACTION_MARKDOWN_TABLE_NEXT
		if event.shift { table_action = ACTION_MARKDOWN_TABLE_PREVIOUS }
		if document.language == "markdown" && editor_cursor_in_markdown_table(window, view.caret_byte) {
			dispatch_action(app, rt, table_action)
			return true
		}
		// A collapsed Tab inserts one indentation unit. A non-empty selection
		// indents every touched logical line as one source replacement; Shift+Tab
		// outdents every touched line (or the caret's line) in the same way.
		tab_indent := EDITOR_TAB_INSERT
		if !event.shift {
			if view.selection_anchor != view.caret_byte {
				projection := editor_line_indent_projection(
					window,
					view.selection_anchor,
					view.caret_byte,
					tab_indent[:],
					false,
				)
				defer delete(projection.replacement)
				if !projection.ok {
					set_error(app, "The selected lines are not fully present in the bounded editor window; move them into view before indenting.")
					alicorn.invalidate_root(rt, "Scratchpad deferred indentation outside the authoritative source window")
					return true
				}
				if projection.changed {
					return editor_apply_local_replace(
						app, rt, projection.start_byte, projection.end_byte,
						projection.replacement, projection.anchor_byte, projection.caret_byte,
					)
				}
				return true
			}
			start_byte := min(view.selection_anchor, view.caret_byte)
			end_byte := max(view.selection_anchor, view.caret_byte)
			caret := start_byte+u64(len(EDITOR_TAB_INSERT))
			return editor_apply_local_replace(app, rt, start_byte, end_byte, tab_indent[:], caret, caret)
		}
		projection := editor_line_indent_projection(
			window,
			view.selection_anchor,
			view.caret_byte,
			tab_indent[:],
			true,
		)
		defer delete(projection.replacement)
		if !projection.ok {
			set_error(app, "The selected lines are not fully present in the bounded editor window; move them into view before outdenting.")
			alicorn.invalidate_root(rt, "Scratchpad deferred outdent outside the authoritative source window")
			return true
		}
		if projection.changed {
			_ = editor_apply_local_replace(
				app, rt, projection.start_byte, projection.end_byte,
				projection.replacement, projection.anchor_byte, projection.caret_byte,
			)
		}
		return true
	}
	if event.control || event.alt || event.super {
		#partial switch event.key {
		case .Word_Left, .Word_Right, .Line_Start, .Line_End, .Document_Start, .Document_End,
			.Delete_Word_Backward, .Delete_Word_Forward, .Delete_Line_Backward, .Delete_Line_Forward:
		case:
			return false
		}
	}
	if event.key == .Backspace || event.key == .Delete ||
	   event.key == .Delete_Word_Backward || event.key == .Delete_Word_Forward ||
	   event.key == .Delete_Line_Backward || event.key == .Delete_Line_Forward {
		if event.key == .Backspace && view.selection_anchor == view.caret_byte && view.auto_pair_valid &&
		   view.caret_byte == view.auto_pair_closer_byte && view.caret_byte > window.start_byte {
			local := int(view.caret_byte-window.start_byte)
			if local > 0 && local < len(window.source) {
				opener, closer := window.source[local-1], window.source[local]
				if editor_pair_closer_for_opener(opener) == closer {
					_ = editor_apply_local_replace(app, rt, view.caret_byte-1, view.caret_byte+1, {}, view.caret_byte-1, view.caret_byte-1)
					view.auto_pair_valid = false
					return true
				}
			}
		}
		start_byte := view.caret_byte
		end_byte := view.caret_byte
		if view.selection_anchor != view.caret_byte {
			start_byte = min(view.selection_anchor, view.caret_byte)
			end_byte = max(view.selection_anchor, view.caret_byte)
		} else {
			line, line_found := editor_line_for_source(window, view.caret_byte)
			if !line_found { return true }
			#partial switch event.key {
			case .Backspace:
				if view.caret_byte > line.source_start {
					previous, _, moved := editor_move_horizontal(line, view.caret_byte, view.caret_affinity, -1)
					if !moved { return true }
					start_byte = previous
				} else if line.logical_line > window.start_line {
					if previous, found := editor_window_line(window, line.logical_line-1); found {
						start_byte = previous.source_end
					} else { return true }
				} else {
					return true
				}
			case .Delete:
				if view.caret_byte < line.source_end {
					next, _, moved := editor_move_horizontal(line, view.caret_byte, view.caret_affinity, 1)
					if !moved { return true }
					end_byte = next
				} else if next, found := editor_window_line(window, line.logical_line+1); found {
					end_byte = next.source_start
				} else {
					return true
				}
			case .Delete_Word_Backward:
				move := editor_move_word_source
				if event.control && event.alt { move = editor_move_subword_source }
				previous, _, moved := move(window, view.caret_byte, view.caret_affinity, -1)
				if !moved { return true }
				start_byte = previous
			case .Delete_Word_Forward:
				move := editor_move_word_source
				if event.control && event.alt { move = editor_move_subword_source }
				next, _, moved := move(window, view.caret_byte, view.caret_affinity, 1)
				if !moved { return true }
				end_byte = next
			case .Delete_Line_Backward:
				start_byte = line.source_start
			case .Delete_Line_Forward:
				end_byte = line.source_end
				if end_byte == view.caret_byte {
					if next, next_found := editor_window_line(window, line.logical_line+1); next_found {
						end_byte = next.source_start
					}
				}
			case:
				return false
			}
		}
		if start_byte < end_byte {
			_ = editor_apply_local_replace(app, rt, start_byte, end_byte, {}, start_byte, start_byte)
		}
		return true
	}
	old_caret := view.caret_byte
	old_affinity := view.caret_affinity
	next_caret := old_caret
	next_affinity := old_affinity
	shift := event.shift
	selection_exists := view.selection_anchor != view.caret_byte
	leftward := event.key == .Left || event.key == .Word_Left
	rightward := event.key == .Right || event.key == .Word_Right
	move_word := editor_move_word_source
	if event.control && event.alt && (event.key == .Word_Left || event.key == .Word_Right) {
		move_word = editor_move_subword_source
	}
	if !shift && selection_exists && (leftward || rightward) {
		boundary := view.selection_anchor
		boundary_affinity := view.anchor_affinity
		if (leftward && view.caret_byte < view.selection_anchor) || (rightward && view.caret_byte > view.selection_anchor) {
			boundary, boundary_affinity = view.caret_byte, view.caret_affinity
		}
		if event.key == .Word_Left || event.key == .Word_Right {
			direction := -1 if leftward else 1
			moved_caret, moved_affinity, moved := move_word(window, boundary, boundary_affinity, direction)
			if moved { next_caret, next_affinity = moved_caret, moved_affinity }
		} else {
			next_caret, next_affinity = boundary, boundary_affinity
		}
	} else {
		line, line_found := editor_line_for_source(window, old_caret)
		if !line_found { return false }
		#partial switch event.key {
		case .Left, .Right, .Word_Left, .Word_Right:
			direction := -1 if leftward else 1
			if event.key == .Word_Left || event.key == .Word_Right {
				moved_caret, moved_affinity, moved := move_word(window, old_caret, old_affinity, direction)
				if !moved { return true }
				next_caret, next_affinity = moved_caret, moved_affinity
			} else if direction < 0 && old_caret == line.source_start {
				for index := len(window.lines)-1; index >= 0; index -= 1 {
					candidate := &window.lines[index]
					if candidate.logical_line+1 == line.logical_line {
						next_caret = candidate.source_end
						next_affinity = .Trailing
						break
					}
				}
			} else if direction > 0 && old_caret == line.source_end {
				for candidate in window.lines {
					if candidate.logical_line == line.logical_line+1 {
						next_caret = candidate.source_start
						next_affinity = .Leading
						break
					}
				}
			} else {
				moved_caret, moved_affinity, moved := editor_move_horizontal(line, old_caret, old_affinity, direction)
				if !moved { return false }
				next_caret, next_affinity = moved_caret, moved_affinity
			}
		case .Home, .Line_Start:
			// Home and End intentionally target logical source-line boundaries;
			// wrapping changes visual rows, never the meaning of these commands.
			next_caret = editor_normalize_source_position(line, line.source_start)
			next_affinity = .Leading
		case .End, .Line_End:
			next_caret = editor_normalize_source_position(line, line.source_end)
			next_affinity = .Trailing
		case .Document_Start, .Document_End:
			line_count := document.line_count
			if view.optimistic_pending_edits > 0 {
				if view.optimistic_line_delta < 0 {
					removed := u64(-view.optimistic_line_delta)
					line_count = line_count-removed if removed < line_count else 1
				} else {
					line_count += u64(view.optimistic_line_delta)
				}
			}
			target_line := u64(0) if event.key == .Document_Start else (line_count-1 if line_count > 0 else 0)
			target, target_found := editor_window_line(window, target_line)
			if !target_found {
				view.pending_document_edge = .Start if event.key == .Document_Start else .End
				view.pending_document_edge_shift = shift
				_ = editor_ensure_line_visible(rt, view, owner, int(target_line), "Scratchpad editor moved to document edge")
				view.preferred_x_set = false
				alicorn.invalidate_root(rt, "Scratchpad editor requested a bounded document-edge window")
				return true
			}
			if event.key == .Document_Start {
				next_caret = editor_normalize_source_position(target, target.source_start)
				next_affinity = .Leading
			} else {
				next_caret = editor_normalize_source_position(target, target.source_end)
				next_affinity = .Trailing
			}
		case .Up, .Down, .Page_Up, .Page_Down:
			current_line := line.logical_line
			owner_node, owner_found := alicorn.node_info(rt, owner)
			text_scale := editor_text_scale_effective(app)
			gutter_width := editor_line_number_gutter_width(document.line_count, text_scale)
			wrap_width := f32(0)
			if owner_found { wrap_width = max(owner_node.scroll_viewport_width-gutter_width-16*text_scale, 80*text_scale) }
			presentation_current := window.presentation_ready &&
			                       (window.presentation_stale ||
			                        (window.presentation_revision == window.editor_revision &&
			                         document.presentation_ready &&
			                         document.presentation_revision == window.presentation_revision))
			current_target, current_target_found := editor_row_target_for_source(app.editor_row_targets[:], current_line, old_caret)
			current_display_line := line^
			current_node := alicorn.Node_ID(0)
			current_width := wrap_width
			if current_target_found {
				current_node = current_target.node
				if current_target.is_cell { current_width = current_target.cell_width }
				if target_display, target_display_ok := editor_display_line_for_target(window, line, current_target); target_display_ok {
					current_display_line = target_display
				}
			}
			current_geometry, current_visual_rows, _, current_measured := editor_line_visual_caret_metrics(
				rt, window, &current_display_line, document.language, current_width, presentation_current,
				current_node, old_caret, old_affinity, true, view.wrap_mode, text_scale,
			)
			if !current_measured || !current_geometry.valid { return true }
			if !view.preferred_x_set {
				view.preferred_x = current_geometry.rect.x
				if current_target_found && current_target.is_cell { view.preferred_x += current_target.cell_origin_x }
				view.preferred_x_set = true
			}
			target_line := current_line
			target_visual_row := -1
			target_visual_y: f32 = 0
			if event.key == .Up || event.key == .Down {
				direction := -1 if event.key == .Up else 1
				next_visual_row := current_geometry.line_index+direction
				if next_visual_row >= 0 && next_visual_row < current_visual_rows {
					target_visual_row = next_visual_row
				} else if direction < 0 {
					target_line = current_line-1 if current_line > 0 else 0
				} else {
					line_count := document.line_count
					if view.optimistic_pending_edits > 0 {
						if view.optimistic_line_delta < 0 {
							removed := u64(-view.optimistic_line_delta)
						line_count = line_count-removed if removed < line_count else 1
						} else {
							line_count += u64(view.optimistic_line_delta)
						}
					}
					last_line := line_count-1 if line_count > 0 else 0
					target_line = min(current_line+1, last_line)
				}
			} else {
				if view.wrap_height_index_ready && owner_found {
					page := max(owner_node.scroll_viewport_height-current_geometry.rect.h, current_geometry.rect.h)
					current_content_y := alicorn.virtual_list_height_index_item_top(&view.wrap_height_index, int(current_line)) +
					                     current_geometry.rect.y + current_geometry.rect.h*0.5
					target_content_y := current_content_y-page if event.key == .Page_Up else current_content_y+page
					target_line = u64(alicorn.virtual_list_height_index_item_at(&view.wrap_height_index, target_content_y))
					target_visual_y = target_content_y-alicorn.virtual_list_height_index_item_top(&view.wrap_height_index, int(target_line))
				} else {
					step := u64(1)
					if owner_found {
					step = u64(max(int(owner_node.scroll_viewport_height/(EDITOR_ROW_HEIGHT*text_scale))-1, 1))
					}
					if event.key == .Page_Up {
						target_line = current_line-step if current_line > step else 0
					} else {
						line_count := document.line_count
						last_line := line_count-1 if line_count > 0 else 0
						target_line = min(current_line+step, last_line)
					}
				}
			}
			target, target_found := editor_window_line(window, target_line)
			if !target_found {
				_ = editor_ensure_line_visible(rt, view, owner, int(target_line), "Scratchpad requested the bounded window for vertical editor navigation")
				alicorn.invalidate_root(rt, "Scratchpad vertical editor navigation reached the bounded source window edge")
				return true
			}
			target_node := alicorn.Node_ID(0)
			target_width := wrap_width
			target_display_line := target^
			target_target: Editor_Row_Target
			target_target_found := false
			target_origin_x: f32 = 0
			if editor_table_line_is_projected(window, target) && editor_table_line_fit(window, target, wrap_width, text_scale) {
				target_layout := editor_table_row_layout(window, target, wrap_width, text_scale=text_scale)
				target_cell_index := editor_table_cell_for_x(target_layout, view.preferred_x)
				if current_target_found && current_target.is_cell { target_cell_index = current_target.cell_index }
				if target_cell_index >= 0 && target_cell_index < len(target_layout.cells) {
					target_display_line = target_layout.cells[target_cell_index]
					target_width = target_layout.widths[target_cell_index]
					target_origin_x = target_layout.origins[target_cell_index]
					for candidate in app.editor_row_targets {
						if candidate.logical_line == target_line && candidate.is_cell && candidate.cell_index == target_cell_index {
							target_target, target_target_found = candidate, true
							break
						}
					}
				}
			}
			if !target_target_found && (!current_target_found || !current_target.is_cell || !editor_table_line_is_projected(window, target)) {
				target_target, target_target_found = editor_row_target_for_source(app.editor_row_targets[:], target_line, target.source_start)
				if target_target_found { target_display_line, _ = editor_display_line_for_target(window, target, target_target) }
			}
			if target_target_found {
				target_node = target_target.node
				if target_target.is_cell {
					target_width = target_target.cell_width
					target_origin_x = target_target.cell_origin_x
				}
			}
			mapped_visual_row := -1
			if event.key == .Up || event.key == .Down {
				if target_line != current_line {
					_, target_visual_rows, _, target_measured := editor_line_visual_caret_metrics(
						rt, window, &target_display_line, document.language, target_width, presentation_current,
						target_node, 0, .Leading, false, view.wrap_mode, text_scale,
					)
					if !target_measured { return true }
					mapped_visual_row = 0 if event.key == .Down else target_visual_rows-1
				} else {
					mapped_visual_row = target_visual_row
				}
			}
			target_visual_x := view.preferred_x
			if target_target_found && target_target.is_cell || target_origin_x > 0 {
				target_visual_x -= target_origin_x
			}
			mapped_caret, mapped_affinity, moved := editor_source_at_visual_point(
				rt, window, &target_display_line, document.language, target_width, presentation_current,
				target_node, target_visual_x, target_visual_y, mapped_visual_row, view.wrap_mode, text_scale,
			)
			if !moved { return true }
			next_caret, next_affinity = mapped_caret, mapped_affinity
		case .Backspace, .Delete, .Delete_Word_Backward, .Delete_Word_Forward,
			.Delete_Line_Backward, .Delete_Line_Forward, .Tab:
			// Handled by the replacement path above; keep the navigation switch
			// exhaustive as the generic text-input key set grows.
			return true
		case:
			return false
		}
	}
	if event.key == .Left || event.key == .Right || event.key == .Word_Left || event.key == .Word_Right ||
	   event.key == .Home || event.key == .End || event.key == .Line_Start || event.key == .Line_End ||
	   event.key == .Document_Start || event.key == .Document_End {
		view.preferred_x_set = false
	}
	if next_caret == old_caret && next_affinity == old_affinity { return true }
	editor_undo_group_break(view)
	if !shift {
		view.selection_anchor = next_caret
		view.anchor_affinity = next_affinity
	}
	view.caret_byte = next_caret
	view.caret_affinity = next_affinity
	if target_line, target_found := editor_line_for_source(window, next_caret); target_found {
		_ = editor_ensure_line_visible(rt, view, owner, int(target_line.logical_line), "Scratchpad editor caret moved outside the viewport")
		if caret_target, target_available := editor_row_target_for_source(app.editor_row_targets[:], target_line.logical_line, next_caret); target_available {
			if display_line, display_ok := editor_display_line_for_target(window, target_line, caret_target); display_ok {
			if geometry := alicorn.text_node_caret_geometry(rt, caret_target.node, alicorn.Text_Position{byte=editor_source_to_display(&display_line, next_caret), affinity=next_affinity}); geometry.valid {
				if owner_node, owner_found := alicorn.node_info(rt, owner); owner_found {
					top, bottom := owner_node.scroll_viewport_bounds.y, owner_node.scroll_viewport_bounds.y+owner_node.scroll_viewport_height
					next_y := owner_node.scroll_offset_y
					if geometry.rect.y < top { next_y -= top-geometry.rect.y }
					if geometry.rect.y+geometry.rect.h > bottom { next_y += geometry.rect.y+geometry.rect.h-bottom }
					_ = alicorn.scroll_region_set_offset(rt, owner, next_y, "Scratchpad editor caret followed vertically across visual rows")
					left, right := owner_node.bounds.x, owner_node.bounds.x+owner_node.scroll_viewport_width
					next_x := owner_node.scroll_offset_x
					if geometry.rect.x < left { next_x -= left-geometry.rect.x }
					if geometry.rect.x+geometry.rect.w > right { next_x += geometry.rect.x+geometry.rect.w-right }
					_ = alicorn.scroll_region_set_offset_x(rt, owner, next_x, "Scratchpad editor caret followed horizontally")
				}
			}
			}
		}
	}
	alicorn.invalidate_root(rt, "Scratchpad read-only editor caret navigation")
	return true
}

editor_pending_replacement_bytes :: proc(app: ^App) -> int {
	if app == nil { return 0 }
	count := 0
	for edit in app.editor_edits { count += len(edit.replacement) }
	return count
}

editor_apply_local_replace :: proc(
	app: ^App,
	rt: ^alicorn.Runtime,
	start_byte, end_byte: u64,
	replacement: []u8,
	resulting_anchor, resulting_caret: u64,
) -> bool {
	return editor_apply_local_replace_with_wire(
		app, rt, start_byte, end_byte, replacement, {}, resulting_anchor, resulting_caret,
	)
}

editor_apply_local_typing_replace :: proc(
	app: ^App,
	rt: ^alicorn.Runtime,
	start_byte, end_byte: u64,
	replacement: []u8,
	resulting_anchor, resulting_caret: u64,
) -> bool {
	if app == nil { return false }
	document, found := find_document(&app.backend.state, app.backend.state.active)
	if !found { return false }
	view_index, view_ok := editor_view_ensure(&app.editor_views, document.id)
	if !view_ok { return false }
	group_id := editor_typing_group_id(&app.editor_views[view_index])
	return editor_apply_local_replace_with_wire(
		app, rt, start_byte, end_byte, replacement, {}, resulting_anchor, resulting_caret, group_id,
	)
}

editor_apply_local_replace_with_wire :: proc(
	app: ^App,
	rt: ^alicorn.Runtime,
	start_byte, end_byte: u64,
	replacement, wire_replacement: []u8,
	resulting_anchor, resulting_caret: u64,
	typing_group_id: u64 = 0,
	action_id := "",
	allow_offscreen_authoritative := false,
	reveal_after_ack := false,
	reveal_logical_line: u64 = 0,
) -> bool {
	if app == nil || rt == nil || !app.backend.started || end_byte < start_byte {
		return false
	}
	document, found := find_document(&app.backend.state, app.backend.state.active)
	if !found { return false }
	view_index, view_ok := editor_view_ensure(&app.editor_views, document.id)
	if !view_ok {
		set_error(app, "Could not retain the active document's optimistic editor view.")
		return false
	}
	view := &app.editor_views[view_index]
	selection_snapshot := editor_edit_selection_snapshot(view, resulting_anchor, resulting_caret)
	window, window_matches := editor_view_window(view, &app.editor_window, app.editor_window_ready, document.id, document.editor_revision)
	window_end: u64 = 0
	if window_matches { window_end = window.start_byte+u64(len(window.source)) }
	optimistic_projection := window_matches && start_byte >= window.start_byte && end_byte <= window_end
	if !optimistic_projection && !allow_offscreen_authoritative {
		set_error(app, "The bounded source window is not ready for local editing.")
		alicorn.invalidate_root(rt, "Scratchpad local replacement waited for a source window")
		return false
	}
	if allow_offscreen_authoritative && !optimistic_projection && end_byte > document.byte_length {
		set_error(app, "The replacement range is outside the authoritative document.")
		alicorn.invalidate_root(rt, "Scratchpad rejected an out-of-document replacement")
		return false
	}
	if optimistic_projection && editor_window_is_long_line_chunk(window) && editor_count_line_breaks(replacement) > 0 {
		set_error(app, "Enter is unavailable inside a partially loaded long line; move to a complete line window first.")
		alicorn.invalidate_root(rt, "Scratchpad deferred a line break beyond the bounded long-line projection")
		return false
	}
	if editor_pending_replacement_bytes(app)+len(replacement) > int(bridge.MAX_EDIT_BYTES) {
		set_error(app, "Pending local edits reached the bounded 128 KiB queue limit.")
		alicorn.invalidate_root(rt, "Scratchpad optimistic edit queue is full")
		return false
	}
	if typing_group_id == 0 { editor_undo_group_break(view) }
	workspace_search_match_clear(view)
	local_start, local_end: int
	if optimistic_projection {
		local_start = int(start_byte-window.start_byte)
		local_end = int(end_byte-window.start_byte)
	}
	if view.auto_pair_valid {
		marker := view.auto_pair_closer_byte
		if start_byte <= marker && end_byte <= marker {
			delta := i64(len(replacement))-i64(end_byte-start_byte)
			if delta < 0 {
				removed := u64(-delta)
				view.auto_pair_closer_byte = marker-removed if removed <= marker else 0
			} else { view.auto_pair_closer_byte = marker+u64(delta) }
		} else if start_byte <= marker && end_byte > marker {
			view.auto_pair_valid = false
		}
	}
	removed_line_breaks: u64 = 0
	new_window: Editor_Window
	if optimistic_projection {
		removed_line_breaks = editor_count_line_breaks(window.source[local_start:local_end])
		replaced: bool
		replace_error: string
		new_window, replaced, replace_error = editor_window_replace_bytes(window, start_byte, end_byte, replacement)
		if !replaced {
			set_error(app, replace_error)
			alicorn.invalidate_root(rt, "Scratchpad could not apply a bounded optimistic replacement")
			return false
		}
	}
	document_id, id_error := strings.clone(document.id, context.allocator)
	if id_error != nil {
		if optimistic_projection { editor_window_destroy(&new_window) }
		set_error(app, "Could not retain the edit's document identity.")
		return false
	}
	owned_action_id: string
	if action_id != "" {
		owned_action_id, id_error = strings.clone(action_id, context.allocator)
		if id_error != nil {
			delete(document_id, context.allocator)
			if optimistic_projection { editor_window_destroy(&new_window) }
			set_error(app, "Could not retain the semantic edit intent.")
			return false
		}
	}
	replacement_copy, replacement_error := make([]u8, len(replacement), allocator=context.allocator)
	if replacement_error != nil {
		delete(document_id, context.allocator)
		if len(owned_action_id) > 0 { delete(owned_action_id, context.allocator) }
		if optimistic_projection { editor_window_destroy(&new_window) }
		set_error(app, "Could not retain replacement bytes for the serial edit queue.")
		return false
	}
	if len(replacement) > 0 { mem.copy(rawptr(&replacement_copy[0]), rawptr(&replacement[0]), len(replacement)) }
	wire_copy: []u8
	if len(wire_replacement) > 0 && !editor_bytes_equal(replacement, wire_replacement) {
		wire_copy, replacement_error = make([]u8, len(wire_replacement), allocator=context.allocator)
		if replacement_error != nil {
			delete(document_id, context.allocator)
			if len(owned_action_id) > 0 { delete(owned_action_id, context.allocator) }
			delete(replacement_copy, context.allocator)
			if optimistic_projection { editor_window_destroy(&new_window) }
			set_error(app, "Could not retain the authoritative replacement bytes for the serial edit queue.")
			return false
		}
		mem.copy(rawptr(&wire_copy[0]), rawptr(&wire_replacement[0]), len(wire_replacement))
	}
	if optimistic_projection {
		view.viewport_anchor_skip_next_source_change = true
		view.viewport_anchor_pending = false
		view.viewport_anchor_resolved = false
	}
	if view.authoritative_revision == 0 { view.authoritative_revision = document.editor_revision }
	edit_base_revision := view.authoritative_revision
	for pending in app.editor_edits {
		if pending.document_id == document.id && pending.base_editor_revision >= edit_base_revision {
			edit_base_revision = pending.base_editor_revision+1
		}
	}
	app.editor_edit_sequence += 1
	if app.editor_edit_sequence == 0 { app.editor_edit_sequence = 1 }
	if optimistic_projection {
		editor_wrap_heights_apply_edit(view, window, start_byte, end_byte, replacement, removed_line_breaks, editor_text_scale_effective(app))
		if view.optimistic_window_ready { editor_window_destroy(&view.optimistic_window) }
		view.optimistic_window = new_window
		view.optimistic_window_ready = true
		view.optimistic_pending_edits += 1
		view.optimistic_line_delta += i64(editor_count_line_breaks(replacement))-i64(removed_line_breaks)
	}
	append(&app.editor_edits, Editor_Edit_Intent{
		sequence=app.editor_edit_sequence,
		document_id=document_id,
		base_editor_revision=edit_base_revision,
		start_byte=start_byte,
		end_byte=end_byte,
		before_anchor_byte=selection_snapshot.before_anchor_byte,
		before_cursor_byte=selection_snapshot.before_cursor_byte,
		after_anchor_byte=selection_snapshot.after_anchor_byte,
		after_cursor_byte=selection_snapshot.after_cursor_byte,
		typing_group_id=typing_group_id,
		action_id=owned_action_id,
		replacement=replacement_copy,
		wire_replacement=wire_copy,
		optimistic_projection=optimistic_projection,
		reveal_after_ack=reveal_after_ack,
		reveal_logical_line=reveal_logical_line,
	})
	view.selection_anchor = resulting_anchor
	view.caret_byte = resulting_caret
	view.anchor_affinity = .Trailing
	view.caret_affinity = .Trailing
	view.preferred_x_set = false
	sync_menu_states(app)
	// Text and the next key can arrive in the same SDL pump, before the next
	// application build refreshes action metadata.
	sync_runtime_actions(app, rt)
	accepted, dispatch_error := editor_dispatch_next_edit(app)
	if !accepted { set_error(app, dispatch_error) } else { set_error(app, "") }
	alicorn.invalidate_root(rt, "Scratchpad source replacement was submitted")
	return true
}

editor_insert_newline :: proc(app: ^App, rt: ^alicorn.Runtime) -> bool {
	if app == nil || rt == nil || app.editor_scroll_owner == 0 { return false }
	document, found := find_document(&app.backend.state, app.backend.state.active)
	if !found { return true }
	view_index, view_ok := editor_view_ensure(&app.editor_views, document.id)
	if !view_ok { return true }
	view := &app.editor_views[view_index]
	window, window_matches := editor_view_window(view, &app.editor_window, app.editor_window_ready, document.id, document.editor_revision)
	if !window_matches {
		set_error(app, "The bounded source window is not ready for Enter.")
		alicorn.invalidate_root(rt, "Scratchpad Enter waited for the bounded source window")
		return true
	}
	start_byte := min(view.selection_anchor, view.caret_byte)
	end_byte := max(view.selection_anchor, view.caret_byte)
	line, line_found := editor_line_for_source(window, start_byte)
	if !line_found {
		set_error(app, "The source line needed for Enter is outside the loaded window.")
		return true
	}
	action_id := ""
	if document.language == "markdown" && view.selection_anchor == view.caret_byte {
		projection, projection_ok := editor_markdown_enter_projection(window, line, view.caret_byte)
		if !projection_ok {
			set_error(app, "Could not project Markdown Enter into the bounded source window.")
			return true
		}
		start_byte, end_byte = projection.start_byte, projection.end_byte
		replacement := projection.replacement
		defer delete(replacement, context.temp_allocator)
		caret := start_byte+u64(len(replacement))
		action_id = ACTION_MARKDOWN_ENTER
		_ = editor_apply_local_replace_with_wire(
			app, rt, start_byte, end_byte, replacement, []u8{'\n'}, caret, caret, 0, action_id,
		)
		return true
	}
	replacement, projection_ok := editor_enter_projection(window, line)
	if !projection_ok {
		set_error(app, "Could not project Scratchpad's Enter indentation into the visible editor window.")
		return true
	}
	caret := start_byte+u64(len(replacement))
	_ = editor_apply_local_replace_with_wire(
		app,
		rt,
		start_byte,
		end_byte,
		replacement,
		[]u8{'\n'},
		caret,
		caret,
	)
	return true
}

editor_remove_edit :: proc(app: ^App, index: int) {
	if app == nil || index < 0 || index >= len(app.editor_edits) { return }
	editor_edit_intent_destroy(&app.editor_edits[index])
	ordered_remove(&app.editor_edits, index)
}

editor_discard_document_edits :: proc(app: ^App, document_id: string) {
	if app == nil { return }
	for index := len(app.editor_edits)-1; index >= 0; index -= 1 {
		if app.editor_edits[index].document_id == document_id { editor_remove_edit(app, index) }
	}
	view_index := editor_view_find(app.editor_views[:], document_id)
	if view_index >= 0 {
		view := &app.editor_views[view_index]
		view.optimistic_pending_edits = 0
		view.optimistic_line_delta = 0
		view.position_reconcile_pending = true
		if view.optimistic_window_ready {
			editor_window_destroy(&view.optimistic_window)
			view.optimistic_window_ready = false
		}
		if document, found := find_document(&app.backend.state, document_id); found {
			view.authoritative_revision = document.editor_revision
			editor_wrap_heights_reset(view, int(document.line_count), editor_text_scale_effective(app))
		}
	}
	if app.editor_window_ready && app.editor_window.document_id == document_id {
		if document, found := find_document(&app.backend.state, document_id); !found || document.editor_revision != app.editor_window.editor_revision {
			editor_window_destroy(&app.editor_window)
			app.editor_window_ready = false
		} else if view_index >= 0 {
			_ = editor_view_reconcile_positions(&app.editor_views[view_index], &app.editor_window)
		}
	}
}

editor_dispatch_next_edit :: proc(app: ^App) -> (accepted: bool, message: string) {
	if app == nil || len(app.editor_edits) == 0 { return true, "" }
	if !app.backend.started || app.editor_edit_lane.thread == nil { return false, "serial editor edit worker is not running" }
	if !bridge.editor_edit_lane_can_submit(&app.editor_edit_lane) { return true, "" }
	edit := &app.editor_edits[0]
	document, found := find_document(&app.backend.state, edit.document_id)
	if !found {
		missing_id, _ := strings.clone(edit.document_id, context.allocator)
		editor_discard_document_edits(app, missing_id)
		delete(missing_id, context.allocator)
		return false, "the edited document is no longer open"
	}
	view_index, view_ok := editor_view_ensure(&app.editor_views, edit.document_id)
	if !view_ok { return false, "could not retain the document's authoritative editor revision" }
	view := &app.editor_views[view_index]
	if view.authoritative_revision == 0 { view.authoritative_revision = document.editor_revision }
	wire_replacement := edit.replacement
	if len(edit.wire_replacement) > 0 { wire_replacement = edit.wire_replacement }
	return bridge.editor_edit_lane_submit(
		&app.editor_edit_lane,
		edit.sequence,
		edit.document_id,
		app.backend.state.application_rev,
		view.authoritative_revision,
		edit.start_byte,
		edit.end_byte,
		wire_replacement,
		edit.before_anchor_byte,
		edit.before_cursor_byte,
		edit.after_anchor_byte,
		edit.after_cursor_byte,
		edit.typing_group_id,
		edit.action_id,
	)
}

editor_reconcile_applied_replacement :: proc(
	app: ^App,
	view: ^Editor_View_State,
	intent: ^Editor_Edit_Intent,
	applied: []u8,
) -> bool {
	if app == nil || view == nil || intent == nil || !view.optimistic_window_ready { return false }
	if editor_bytes_equal(intent.replacement, applied) { return true }
	old_end := intent.start_byte+u64(len(intent.replacement))
	window, replaced, _ := editor_window_replace_bytes(
		&view.optimistic_window,
		intent.start_byte,
		old_end,
		applied,
	)
	if !replaced { return false }
	view.optimistic_line_delta += i64(editor_count_line_breaks(applied))-i64(editor_count_line_breaks(intent.replacement))
	editor_window_destroy(&view.optimistic_window)
	view.optimistic_window = window
	for index in 1..<len(app.editor_edits) {
		app.editor_edits[index].start_byte = editor_rebase_replacement_position(
			app.editor_edits[index].start_byte,
			intent.start_byte,
			intent.replacement,
			applied,
		)
		app.editor_edits[index].end_byte = editor_rebase_replacement_position(
			app.editor_edits[index].end_byte,
			intent.start_byte,
			intent.replacement,
			applied,
		)
		app.editor_edits[index].before_anchor_byte = editor_rebase_replacement_position(app.editor_edits[index].before_anchor_byte, intent.start_byte, intent.replacement, applied)
		app.editor_edits[index].before_cursor_byte = editor_rebase_replacement_position(app.editor_edits[index].before_cursor_byte, intent.start_byte, intent.replacement, applied)
		app.editor_edits[index].after_anchor_byte = editor_rebase_replacement_position(app.editor_edits[index].after_anchor_byte, intent.start_byte, intent.replacement, applied)
		app.editor_edits[index].after_cursor_byte = editor_rebase_replacement_position(app.editor_edits[index].after_cursor_byte, intent.start_byte, intent.replacement, applied)
	}
	view.selection_anchor = editor_rebase_replacement_position(view.selection_anchor, intent.start_byte, intent.replacement, applied)
	view.caret_byte = editor_rebase_replacement_position(view.caret_byte, intent.start_byte, intent.replacement, applied)
	return true
}

editor_handle_edit_result :: proc(app: ^App, rt: ^alicorn.Runtime, result: ^bridge.Editor_Edit_Lane_Result) {
	if app == nil || result == nil { return }
	if len(app.editor_edits) == 0 {
		shutdown_note_edit_failure(app)
		set_error(app, "Scratchpad returned an editor acknowledgement that did not match the queued edit.")
		return
	}
	if app.editor_edits[0].sequence != result.sequence {
		failed_document, _ := strings.clone(app.editor_edits[0].document_id, context.allocator)
		shutdown_note_edit_failure(app)
		set_error(app, "Scratchpad returned an out-of-order editor acknowledgement; reloading authoritative text.")
		editor_discard_document_edits(app, failed_document)
		delete(failed_document, context.allocator)
		editor_views_prune(app)
		sync_menu_states(app)
		_, _ = editor_dispatch_next_edit(app)
		if len(app.editor_edits) == 0 { deferred_actions_run(app, rt) }
		if rt != nil { alicorn.invalidate_root(rt, "Scratchpad discarded edits after an out-of-order acknowledgement") }
		return
	}
	intent := app.editor_edits[0]
	if result.command.ok && result.command.edit.document_id == intent.document_id {
		acknowledged_length := len(intent.replacement)
		if len(result.command.edit.applied_replacement) > 0 {
			acknowledged_length = len(result.command.edit.applied_replacement)
		}
		ack_matches := result.command.edit.start_byte == intent.start_byte &&
		               result.command.edit.old_end_byte == intent.end_byte &&
		               result.command.edit.new_end_byte == result.command.edit.start_byte+u64(acknowledged_length)
		if !ack_matches {
			failed_document, _ := strings.clone(intent.document_id, context.allocator)
			shutdown_note_edit_failure(app)
			set_error(app, "Scratchpad returned an edit acknowledgement with inconsistent source ranges; reloading authoritative text.")
			editor_discard_document_edits(app, failed_document)
			delete(failed_document, context.allocator)
			editor_views_prune(app)
			sync_menu_states(app)
			if len(app.editor_edits) == 0 { deferred_actions_run(app, rt) }
			if rt != nil { alicorn.invalidate_root(rt, "Scratchpad recovered from an inconsistent edit acknowledgement") }
			return
		}
		if view_index := editor_view_find(app.editor_views[:], intent.document_id); view_index >= 0 {
			view := &app.editor_views[view_index]
			if intent.optimistic_projection && len(result.command.edit.applied_replacement) > 0 &&
			   !editor_reconcile_applied_replacement(app, view, &app.editor_edits[0], result.command.edit.applied_replacement) {
				failed_document, _ := strings.clone(intent.document_id, context.allocator)
				shutdown_note_edit_failure(app)
				set_error(app, "Could not reconcile Scratchpad's canonical Enter text; reloading authoritative text.")
				editor_discard_document_edits(app, failed_document)
				delete(failed_document, context.allocator)
				editor_views_prune(app)
				sync_menu_states(app)
				if len(app.editor_edits) == 0 { deferred_actions_run(app, rt) }
				if rt != nil { alicorn.invalidate_root(rt, "Scratchpad reloaded after edit acknowledgement reconciliation failed") }
				return
			}
			if intent.optimistic_projection && view.optimistic_pending_edits > 0 { view.optimistic_pending_edits -= 1 }
			view.authoritative_revision = result.command.edit.editor_revision
			if intent.reveal_after_ack {
				view.selection_anchor = result.command.edit.new_end_byte
				view.caret_byte = result.command.edit.new_end_byte
				_ = editor_reveal_request_set(
					view,
					intent.document_id,
					result.command.edit.editor_revision,
					result.command.edit.new_end_byte,
					result.command.edit.new_end_byte,
					intent.reveal_logical_line,
					.Nearest,
				)
			}
			if view.optimistic_pending_edits == 0 && view.optimistic_window_ready {
				view.optimistic_window.editor_revision = result.command.edit.editor_revision
				view.optimistic_window.application_rev = app.backend.state.application_rev
				view.optimistic_line_delta = 0
			}
		}
		editor_remove_edit(app, 0)
		sync_menu_states(app)
		_, _ = editor_dispatch_next_edit(app)
		if len(app.editor_edits) == 0 { deferred_actions_run(app, rt) }
		if rt != nil { alicorn.invalidate_root(rt, "Scratchpad accepted an optimistic document edit") }
		return
	}
	failed_document, _ := strings.clone(intent.document_id, context.allocator)
	message := result.command.message
	if message == "" { message = result.command.code }
	stale_revision := result.command.code == "stale_editor_revision"
	if stale_revision {
		// A conflict can arrive after another command advanced the document while
		// this frontend still holds an older publication. Refresh before using the
		// local document descriptor to schedule the authoritative window reload.
		changed, refreshed, refresh_message := bridge.backend_consume_wake(&app.backend, context.allocator)
		if refreshed && changed {
			sync_runtime_actions(app, rt)
			sync_menu_states(app)
			tree_sync_workspace(app, rt)
			editor_views_prune(app)
		} else if !refreshed {
			message = fmt.tprintf("%s (latest state refresh failed: %s)", message, refresh_message)
		}
	}
	shutdown_note_edit_failure(app)
	set_error(app, fmt.tprintf("Edit was not accepted; reloading authoritative text: %s", message))
	editor_discard_document_edits(app, failed_document)
	if stale_revision && app.editor_window_ready && app.editor_window.document_id == failed_document {
		// A rejected edit proves that matching revision numbers alone are not
		// enough to trust this cached projection (Undo can reuse old revisions).
		editor_window_destroy(&app.editor_window)
		app.editor_window_ready = false
	}
	delete(failed_document, context.allocator)
	editor_views_prune(app)
	sync_menu_states(app)
	_, _ = editor_dispatch_next_edit(app)
	if len(app.editor_edits) == 0 { deferred_actions_run(app, rt) }
	if rt != nil { alicorn.invalidate_root(rt, "Scratchpad rejected an optimistic document edit") }
}

shutdown_note_edit_failure :: proc(app: ^App) {
	if app != nil && app.shutdown_intent != .None { app.shutdown_edit_failed = true }
}

editor_pair_closer_for_opener :: proc(opener: u8) -> u8 {
	switch opener {
	case '(': return ')'
	case '[': return ']'
	case '{': return '}'
	case '"': return '"'
	case '\'': return '\''
	case '`': return '`'
	}
	return 0
}

editor_flush_pending_edits :: proc(app: ^App) -> bool {
	if app == nil { return false }
	for len(app.editor_edits) > 0 {
		result, found := bridge.editor_edit_lane_take(&app.editor_edit_lane)
		if !found {
			if !bridge.editor_edit_lane_is_active(&app.editor_edit_lane) {
				accepted, _ := editor_dispatch_next_edit(app)
				if !accepted && len(app.editor_edits) > 0 { return false }
			}
			result, found = bridge.editor_edit_lane_wait_take(&app.editor_edit_lane)
		}
		if !found { return false }
		_, _, _ = bridge.backend_consume_wake(&app.backend)
		editor_handle_edit_result(app, nil, &result)
		bridge.editor_edit_lane_result_destroy(&result, app.editor_edit_lane.allocator)
	}
	return true
}

editor_text_input :: proc(
	state: rawptr,
	rt: ^alicorn.Runtime,
	owner: alicorn.Node_ID,
	event: host.Application_Text_Input_Event,
) {
	app := cast(^App)state
	if app == nil { return }
	if event.kind == .Cancel {
		cleared := false
		for &view in app.editor_views {
			// SDL commonly sends an empty TEXT_EDITING cancel immediately after
			// TEXT_INPUT. Preserve committed text that could not be queued as an
			// edit so the terminal event cannot silently erase it.
			if view.preedit_active && !view.preedit_recoverable {
				editor_preedit_clear(&view)
				cleared = true
			}
		}
		if cleared {
			sync_menu_states(app)
			if rt != nil {
				sync_runtime_actions(app, rt)
				alicorn.invalidate_root(rt, "Scratchpad IME composition canceled")
			}
		}
		return
	}
	if !app.backend.started || owner == 0 || owner != app.editor_scroll_owner { return }
	document, found := find_document(&app.backend.state, app.backend.state.active)
	if !found { return }
	view_index, view_ok := editor_view_ensure(&app.editor_views, document.id)
	if !view_ok { set_error(app, "Could not retain the active document's optimistic editor view."); return }
	view := &app.editor_views[view_index]
	if event.kind == .Preedit {
		if view.preedit_recoverable {
			set_error(app, "A committed composition still needs recovery. Use Edit > Copy before starting another composition.")
			sync_menu_states(app)
			if rt != nil {
				sync_runtime_actions(app, rt)
				alicorn.invalidate_root(rt, "Scratchpad preserved committed IME text during a new preedit")
			}
			return
		}
		if !editor_preedit_update(view, event.text, event.selection_start_byte, event.selection_end_byte) {
			set_error(app, "Could not retain the active IME preedit text.")
		}
		sync_menu_states(app)
		if rt != nil {
			sync_runtime_actions(app, rt)
			alicorn.invalidate_root(rt, "Scratchpad IME preedit updated")
		}
		return
	}
	if event.kind != .Commit { return }
	view.pending_document_edge = .None
	view.pending_document_edge_shift = false
	if len(event.text) == 0 {
		if view.preedit_active && !view.preedit_recoverable {
			editor_preedit_clear(view)
			sync_menu_states(app)
			if rt != nil {
				sync_runtime_actions(app, rt)
				alicorn.invalidate_root(rt, "Scratchpad IME composition ended without committed text")
			}
		}
		return
	}
	was_composition := view.preedit_active || view.preedit_recoverable
	start_byte, end_byte := min(view.selection_anchor, view.caret_byte), max(view.selection_anchor, view.caret_byte)
	if view.preedit_recoverable {
		// A later text-input commit must not replace (and lose) the earlier OS
		// commit that could not be applied. Append in place to the preallocated
		// bounded recovery buffer and retry the original source span.
		start_byte, end_byte = view.preedit_replace_start, view.preedit_replace_end
		if !editor_preedit_append_recovery(view, event.text) {
			set_error(app, "Committed input was refused because the recovery buffer is full. Earlier text remains available; use Edit > Copy or Discard Recovery.")
			sync_menu_states(app)
			sync_runtime_actions(app, rt)
			if rt != nil {
				_ = alicorn.text_input_target_set_suspended(rt, owner, true)
				alicorn.invalidate_root(rt, "Scratchpad refused an IME commit beyond the recovery limit")
			}
			return
		}
		replacement := view.preedit_text
		resulting_caret := start_byte+u64(len(replacement))
		if editor_apply_local_typing_replace(app, rt, start_byte, end_byte, replacement, resulting_caret, resulting_caret) {
			editor_preedit_clear(view)
			editor_resume_text_input_target(app, rt, document.id)
			sync_menu_states(app)
			sync_runtime_actions(app, rt)
		} else {
			failure_reason := app.error_message
			set_error(app, fmt.tprintf("Committed input was appended to the recovery text, but the combined edit was rejected (%s). Use Edit > Copy to recover the text.", failure_reason))
			sync_menu_states(app)
			sync_runtime_actions(app, rt)
			if rt != nil {
				if editor_preedit_recovery_is_full(view) { _ = alicorn.text_input_target_set_suspended(rt, owner, true) }
				alicorn.invalidate_root(rt, "Scratchpad retained rejected combined IME text")
			}
		}
		return
	}
	if view.preedit_active {
		// Preserve the preedit and its original source span until the optimistic
		// replacement is accepted. On rejection, committed OS text can replace
		// the preedit and remain visible for retry.
		start_byte, end_byte = view.preedit_replace_start, view.preedit_replace_end
	}
	replacement := transmute([]u8)event.text
	if !was_composition && len(replacement) == 1 {
		window, exact_window := editor_view_window(view, &app.editor_window, app.editor_window_ready, document.id, document.editor_revision)
		if exact_window && view.selection_anchor == view.caret_byte && view.auto_pair_valid &&
		   view.caret_byte == view.auto_pair_closer_byte && view.caret_byte >= window.start_byte {
			local := int(view.caret_byte-window.start_byte)
			if local < len(window.source) && window.source[local] == replacement[0] && replacement[0] == view.auto_pair_closer {
				view.caret_byte += 1
				view.selection_anchor = view.caret_byte
				view.anchor_affinity = .Trailing
				view.caret_affinity = .Trailing
				view.preferred_x_set = false
				view.auto_pair_valid = false
				editor_undo_group_break(view)
				alicorn.invalidate_root(rt, "Scratchpad skipped the matching auto-pair closer")
				return
			}
		}
		closer := editor_pair_closer_for_opener(replacement[0])
		if exact_window && closer != 0 {
			selected, selection_available := editor_selected_source_bytes(window, view.selection_anchor, view.caret_byte)
			if selection_available {
				pair_bytes, allocation_error := make([]u8, len(selected)+2, allocator=context.temp_allocator)
				if allocation_error == nil {
					pair_bytes[0], pair_bytes[len(pair_bytes)-1] = replacement[0], closer
					if len(selected) > 0 { mem.copy(rawptr(&pair_bytes[1]), rawptr(&selected[0]), len(selected)) }
					inner_start := start_byte+1
					inner_end := inner_start+u64(len(selected))
					result_anchor, result_caret := inner_start, inner_end
					if view.selection_anchor > view.caret_byte { result_anchor, result_caret = inner_end, inner_start }
					if editor_apply_local_replace(app, rt, start_byte, end_byte, pair_bytes, result_anchor, result_caret) {
						view.auto_pair_closer_byte = inner_end
						view.auto_pair_closer = closer
						view.auto_pair_valid = true
						editor_preedit_clear(view)
						sync_menu_states(app)
						sync_runtime_actions(app, rt)
						return
					}
				}
			}
		}
	}
	resulting_caret := start_byte+u64(len(replacement))
	if editor_apply_local_typing_replace(app, rt, start_byte, end_byte, replacement, resulting_caret, resulting_caret) {
		editor_preedit_clear(view)
		sync_menu_states(app)
		sync_runtime_actions(app, rt)
	} else {
		failure_reason := app.error_message
		retained := editor_preedit_make_recoverable(view, event.text, start_byte, end_byte)
		if retained {
			set_error(app, fmt.tprintf("The input method committed text but the edit was rejected (%s). The text remains in the editor as a retryable composition.", failure_reason))
			if rt != nil && editor_preedit_recovery_is_full(view) {
				_ = alicorn.text_input_target_set_suspended(rt, owner, true)
			}
		} else {
			set_error(app, "The input method committed text but the edit was rejected and could not be retained for retry.")
		}
		sync_menu_states(app)
		sync_runtime_actions(app, rt)
		if rt != nil { alicorn.invalidate_root(rt, "Scratchpad could not apply committed IME text") }
	}
}

handle_command_result :: proc(app: ^App, rt: ^alicorn.Runtime, result: ^bridge.Backend_Command_Result, prune_editor_state := true) {
	if result == nil { return }
	if len(result.close_decision.document_id) > 0 && result.close_decision.dirty {
		clear_close_prompt(app)
		app.close_document_id, _ = strings.clone(result.close_decision.document_id, context.allocator)
		set_error(app, "")
		alicorn.invalidate_root(rt, "Scratchpad requested a dirty-close decision")
		return
	}
	if result.state_changed {
		sync_runtime_actions(app, rt)
		sync_menu_states(app)
		tree_sync_workspace(app, rt)
		if prune_editor_state { editor_views_prune(app) }
		if app.editor_window_ready && !document_is_open(&app.backend.state, app.editor_window.document_id) {
			editor_window_destroy(&app.editor_window)
			app.editor_window_ready = false
		}
		alicorn.invalidate_root(rt, "Scratchpad command published new state")
	}
	if !result.ok {
		set_error(app, result.message)
		alicorn.invalidate_root(rt, "Scratchpad command failed")
		return
	}
	set_error(app, "")
	if app.close_document_id != "" && !document_is_open(&app.backend.state, app.close_document_id) {
		clear_close_prompt(app)
		alicorn.invalidate_root(rt, "Scratchpad closed prompted document")
	}
}

editor_has_pending_active_document_edit :: proc(app: ^App) -> bool {
	if app == nil { return false }
	for edit in app.editor_edits {
		if edit.document_id == app.backend.state.active { return true }
	}
	return false
}

editor_active_preedit :: proc(app: ^App) -> bool {
	if app == nil || app.backend.state.active == "" { return false }
	if index := editor_view_find(app.editor_views[:], app.backend.state.active); index >= 0 {
		return app.editor_views[index].preedit_active
	}
	return false
}

active_editor_context :: proc(app: ^App) -> (document: bridge.State_Document, view: ^Editor_View_State, window: ^Editor_Window, ok: bool) {
	if app == nil || !app.backend.started { return }
	document, ok = find_document(&app.backend.state, app.backend.state.active)
	if !ok { return }
	view_index := editor_view_find(app.editor_views[:], document.id)
	if view_index < 0 { return document, nil, nil, false }
	view = &app.editor_views[view_index]
	window, ok = editor_view_window(view, &app.editor_window, app.editor_window_ready, document.id, document.editor_revision)
	return
}

editor_clipboard_command :: proc(app: ^App, rt: ^alicorn.Runtime, action_id: string) {
	if app == nil || rt == nil || !app.backend.started { return }
	if index := editor_view_find(app.editor_views[:], app.backend.state.active); index >= 0 {
		view := &app.editor_views[index]
		if view.preedit_active {
			switch action_id {
			case ACTION_EDIT_COPY:
				if view.preedit_recoverable {
					_ = editor_copy_recoverable_preedit(app, rt, app.backend.state.active)
					return
				}
				if len(view.preedit_text) == 0 { return }
				if !editor_source_bytes_valid_utf8(view.preedit_text) {
					set_error(app, "The active text composition is not valid UTF-8; it was not copied.")
					alicorn.invalidate_root(rt, "Scratchpad refused invalid IME text for the UTF-8 clipboard")
					return
				}
				if !host.ClipboardSetText(app.services.clipboard, string(view.preedit_text)) {
					set_error(app, "Could not copy the active text composition to the system clipboard.")
					alicorn.invalidate_root(rt, "Scratchpad clipboard write failed during IME composition")
					return
				}
				return
			case ACTION_EDIT_CUT, ACTION_EDIT_PASTE, ACTION_EDIT_SELECT_ALL:
				set_error(app, "Finish or cancel the active text composition before using Cut, Paste, or Select All.")
				alicorn.invalidate_root(rt, "Scratchpad clipboard command refused during IME composition")
				return
			}
		}
	}
	if action_id == ACTION_EDIT_PASTE && len(app.editor_edits) > 0 {
		if !deferred_action_enqueue(app, .Action, value=action_id) {
			set_error(app, "Could not queue Paste behind pending editor edits.")
		}
		alicorn.invalidate_root(rt, "Scratchpad queued Paste behind pending editor edits")
		return
	}
	document, view, window, ready := active_editor_context(app)
	if !ready || view == nil || window == nil {
		set_error(app, "The active document's bounded source window is not ready for this Edit command.")
		alicorn.invalidate_root(rt, "Scratchpad Edit command needs a bounded source window")
		return
	}
	switch action_id {
	case ACTION_EDIT_SELECT_ALL:
		editor_select_all(view, editor_current_byte_length(app, document))
		alicorn.invalidate_root(rt, "Scratchpad Select All updated the local editor selection")
	case ACTION_EDIT_COPY, ACTION_EDIT_CUT:
		start_byte := min(view.selection_anchor, view.caret_byte)
		end_byte := max(view.selection_anchor, view.caret_byte)
		if start_byte == end_byte { return }
		bytes, available := editor_selected_source_bytes(window, view.selection_anchor, view.caret_byte)
		if !available {
			set_error(app, "The full selection is outside the loaded source window; copy and cut were not performed.")
			alicorn.invalidate_root(rt, "Scratchpad refused a partial bounded-window clipboard operation")
			return
		}
		if !editor_source_bytes_valid_utf8(bytes) {
			set_error(app, "The selected source contains invalid UTF-8 bytes; copy and cut were not performed.")
			alicorn.invalidate_root(rt, "Scratchpad refused to send invalid source bytes to the UTF-8 clipboard")
			return
		}
		if !host.ClipboardSetText(app.services.clipboard, string(bytes)) {
			set_error(app, "Could not copy text to the system clipboard.")
			alicorn.invalidate_root(rt, "Scratchpad clipboard write failed")
			return
		}
		if action_id == ACTION_EDIT_CUT {
			_ = editor_apply_local_replace(app, rt, start_byte, end_byte, {}, start_byte, start_byte)
		}
	case ACTION_EDIT_PASTE:
		text, clipboard_ok := host.ClipboardGetText(app.services.clipboard, allocator=context.allocator)
		if !clipboard_ok {
			set_error(app, "Could not read text from the system clipboard.")
			alicorn.invalidate_root(rt, "Scratchpad clipboard read failed")
			return
		}
		defer delete(text, context.allocator)
		if len(text) == 0 { return }
		if len(text) > int(bridge.MAX_EDIT_BYTES) {
			set_error(app, "Clipboard text exceeds the 128 KiB per-edit limit.")
			alicorn.invalidate_root(rt, "Scratchpad rejected oversized clipboard text")
			return
		}
		start_byte := min(view.selection_anchor, view.caret_byte)
		end_byte := max(view.selection_anchor, view.caret_byte)
		window_end := window.start_byte+u64(len(window.source))
		if start_byte < window.start_byte || end_byte > window_end {
			set_error(app, "The replacement range is outside the loaded source window; paste was not performed.")
			alicorn.invalidate_root(rt, "Scratchpad refused a paste across the bounded source-window edge")
			return
		}
		wire_replacement, conversion_ok := string_bytes_to_wire(text)
		if !conversion_ok {
			set_error(app, "Could not prepare clipboard text for Scratchpad.")
			alicorn.invalidate_root(rt, "Scratchpad could not encode clipboard bytes")
			return
		}
		document_id, id_error := strings.clone(document.id, context.temp_allocator)
		if id_error != nil {
			set_error(app, "Could not retain the active document identity for Paste.")
			return
		}
		document_revision := document.editor_revision
		before_anchor, before_cursor := view.selection_anchor, view.caret_byte
		response := bridge.backend_command(
			&app.backend,
			"paste_document",
			document_id=document_id,
			editor_revision=document_revision,
			start_byte=start_byte,
			end_byte=end_byte,
			replacement=wire_replacement,
			has_selection_state=true,
			before_anchor_byte=before_anchor,
			before_cursor_byte=before_cursor,
		)
		if response.ok && response.command_outcome != "no_op" &&
		   response.edit.document_id == document_id && response.edit.editor_revision > document_revision &&
		   response.edit.start_byte == start_byte && response.edit.old_end_byte == end_byte {
			applied := transmute([]u8)text
			if len(response.edit.applied_replacement) > 0 {
				applied = response.edit.applied_replacement
			}
			if response.edit.new_end_byte == start_byte+u64(len(applied)) {
				next_window, projected, _ := editor_window_replace_bytes(window, start_byte, end_byte, applied)
				view_index := editor_view_find(app.editor_views[:], document_id)
				if projected && view_index >= 0 {
						editor_wrap_heights_apply_edit(
						&app.editor_views[view_index], window, start_byte, end_byte, applied,
						editor_count_line_breaks(window.source[int(start_byte-window.start_byte):int(end_byte-window.start_byte)]),
							editor_text_scale_effective(app),
					)
					view = &app.editor_views[view_index]
					if view.optimistic_window_ready {
						editor_window_destroy(&view.optimistic_window)
					}
					next_window.editor_revision = response.edit.editor_revision
					next_window.application_rev = app.backend.state.application_rev
					view.optimistic_window = next_window
					view.optimistic_window_ready = true
					view.optimistic_pending_edits = 0
					view.optimistic_line_delta = 0
					view.authoritative_revision = response.edit.editor_revision
				} else if projected {
					editor_window_destroy(&next_window)
				}
			}
		}
		handle_command_result(app, rt, &response)
		if response.ok && response.source_refresh_needed && response.editor_selection.document_id == document_id {
			if view_index := editor_view_find(app.editor_views[:], document_id); view_index >= 0 {
				app.editor_views[view_index].authoritative_revision = response.editor_selection.editor_revision
			}
			editor_apply_backend_selection(app, rt, response.editor_selection)
			app.find_presentation.editor_revision = 0
		}
		bridge.backend_command_result_destroy(&response, context.allocator)
		delete(document_id, context.temp_allocator)
	}
}

editor_current_byte_length :: proc(app: ^App, document: bridge.State_Document) -> u64 {
	length := document.byte_length
	if app == nil { return length }
	for edit in app.editor_edits {
		if edit.document_id != document.id || edit.end_byte < edit.start_byte { continue }
		removed := edit.end_byte-edit.start_byte
		inserted := u64(len(edit.replacement))
		if inserted >= removed {
			delta := inserted-removed
			if length > u64(0xFFFF_FFFF_FFFF_FFFF)-delta { length = u64(0xFFFF_FFFF_FFFF_FFFF) } else { length += delta }
		} else {
			delta := removed-inserted
			length = length-delta if length >= delta else 0
		}
	}
	return length
}

editor_apply_backend_selection :: proc(
	app: ^App,
	rt: ^alicorn.Runtime,
	selection: bridge.Editor_Selection,
	selection_only := false,
) {
	if app == nil || selection.document_id == "" { return }
	document, found := find_document(&app.backend.state, selection.document_id)
	if !found || selection.anchor_byte > document.byte_length || selection.cursor_byte > document.byte_length { return }
	view_index, view_ok := editor_view_ensure(&app.editor_views, selection.document_id)
	if !view_ok { set_error(app, "Could not restore the document selection after a command."); return }
	view := &app.editor_views[view_index]
	editor_undo_group_break(view)
	if view.workspace_search_match_active && selection.editor_revision != view.workspace_search_match_revision {
		workspace_search_match_clear(view)
	}
	if !selection_only {
		editor_preedit_clear(view)
		editor_wrap_heights_reset(view, int(document.line_count), editor_text_scale_effective(app))
		view.authoritative_revision = selection.editor_revision
	}
	view.selection_anchor = selection.anchor_byte
	view.caret_byte = selection.cursor_byte
	view.anchor_affinity = .Leading
	view.caret_affinity = .Trailing
	view.preferred_x_set = false
	view.pending_document_edge = .None
	view.pending_document_edge_shift = false
	line_needs_reveal := !selection_only || !editor_line_fully_visible(
		rt, app.editor_scroll_owner, app.editor_row_targets[:], selection.cursor_line,
	)
	if line_needs_reveal {
		_ = editor_reveal_request_set(
			&app.editor_views[view_index],
			selection.document_id,
			selection.editor_revision,
			selection.cursor_byte,
			selection.cursor_byte,
			selection.cursor_line,
			.Nearest,
		)
	} else if selection_only {
		editor_reveal_request_clear(&app.editor_views[view_index].reveal_request)
	}
	reason := "Scratchpad restored selection after Undo/Redo" if !selection_only else "Scratchpad applied selection-only command result"
	alicorn.invalidate_root(rt, reason)
}

editor_line_fully_visible :: proc(
	rt: ^alicorn.Runtime,
	owner: alicorn.Node_ID,
	rows: []Editor_Row_Target,
	logical_line: u64,
) -> bool {
	if rt == nil || owner == 0 { return false }
	viewport, viewport_found := alicorn.node_info(rt, owner)
	if !viewport_found || viewport.scroll_viewport_height <= 0 { return false }
	top := viewport.bounds.y
	bottom := top+viewport.scroll_viewport_height
	for target in rows {
		if target.logical_line != logical_line { continue }
		row, row_found := alicorn.node_info(rt, target.node)
		if row_found && row.bounds.h > 0 && row.bounds.y >= top && row.bounds.y+row.bounds.h <= bottom {
			return true
		}
	}
	return false
}

find_document :: proc(state: ^bridge.State_Envelope, id: string) -> (document: bridge.State_Document, found: bool) {
	for document in state.documents { if document.id == id { return document, true } }
	return
}

document_is_open :: proc(state: ^bridge.State_Envelope, id: string) -> bool {
	_, found := find_document(state, id)
	return found
}

editor_document_has_recoverable_preedit :: proc(app: ^App, document_id: string) -> bool {
	if app == nil || document_id == "" { return false }
	if index := editor_view_find(app.editor_views[:], document_id); index >= 0 {
		return app.editor_views[index].preedit_active && app.editor_views[index].preedit_recoverable
	}
	return false
}

editor_register_text_input_target :: proc(ui: ^alicorn.UI, owner: alicorn.Node_ID, view: ^Editor_View_State) -> bool {
	if ui == nil || owner == 0 || editor_preedit_recovery_is_full(view) { return false }
	return alicorn.text_input_target(ui, owner)
}

editor_resume_text_input_target :: proc(app: ^App, rt: ^alicorn.Runtime, document_id: string) {
	if app == nil || rt == nil || !app.backend.started || app.backend.state.active != document_id || app.editor_scroll_owner == 0 { return }
	_ = alicorn.text_input_target_set_suspended(rt, app.editor_scroll_owner, false)
}

editor_copy_recoverable_preedit :: proc(app: ^App, rt: ^alicorn.Runtime, document_id: string) -> bool {
	if app == nil || rt == nil { return false }
	index := editor_view_find(app.editor_views[:], document_id)
	if index < 0 { return false }
	view := &app.editor_views[index]
	if !view.preedit_active || !view.preedit_recoverable || len(view.preedit_text) == 0 { return false }
	if !editor_source_bytes_valid_utf8(view.preedit_text) {
		set_error(app, "The committed recovery text is not valid UTF-8; it was not copied or discarded.")
		alicorn.invalidate_root(rt, "Scratchpad refused invalid recovery text for the UTF-8 clipboard")
		return false
	}
	if !host.ClipboardSetText(app.services.clipboard, string(view.preedit_text)) {
		set_error(app, "Could not copy the committed recovery text. It remains available in this document.")
		alicorn.invalidate_root(rt, "Scratchpad clipboard write failed during IME recovery")
		return false
	}
	editor_preedit_clear(view)
	editor_resume_text_input_target(app, rt, document_id)
	sync_menu_states(app)
	sync_runtime_actions(app, rt)
	set_error(app, "Committed composition copied to the clipboard; the document was left unchanged.")
	alicorn.invalidate_root(rt, "Scratchpad copied committed IME recovery text")
	return true
}

editor_discard_recoverable_preedit :: proc(app: ^App, rt: ^alicorn.Runtime, document_id: string) -> bool {
	if app == nil || rt == nil { return false }
	index := editor_view_find(app.editor_views[:], document_id)
	if index < 0 { return false }
	view := &app.editor_views[index]
	if !view.preedit_active || !view.preedit_recoverable { return false }
	editor_preedit_clear(view)
	editor_resume_text_input_target(app, rt, document_id)
	sync_menu_states(app)
	sync_runtime_actions(app, rt)
	set_error(app, "Committed composition recovery text was explicitly discarded; the document source was left unchanged.")
	alicorn.invalidate_root(rt, "Scratchpad explicitly discarded committed IME recovery text")
	return true
}

editor_views_prune :: proc(app: ^App) {
	if app == nil { return }
	for index := len(app.editor_views)-1; index >= 0; index -= 1 {
		if !document_is_open(&app.backend.state, app.editor_views[index].document_id) &&
		   app.editor_views[index].optimistic_pending_edits == 0 {
			editor_view_remove(&app.editor_views, index)
		}
	}
}

set_error :: proc(app: ^App, message: string) {
	if app == nil { return }
	if len(app.error_message) > 0 { delete(app.error_message, context.allocator) }
	app.error_message = ""
	if len(message) > 0 { app.error_message, _ = strings.clone(message, context.allocator) }
}

application_stop :: proc(state: rawptr) {
	app := cast(^App)state
	if app.backend.started {
		stopped, message := stop_backend(app)
		app.smoke_shutdown = stopped && !app.backend.started && app.backend.waiter.thread == nil && app.backend.state_leases == 0 && app.backend.resource_leases == 0 && app.visible_window_lane.thread == nil && app.editor_edit_lane.thread == nil && app.quick_open_lane.thread == nil && app.accessibility_source_lane.thread == nil
		if !stopped { fmt.eprintln("Scratchpad backend shutdown error:", message) }
	} else {
		app.smoke_shutdown = true
	}
	editor_accessibility_projection_destroy(&app.accessibility_projection)
	if len(app.accessibility_source_error) > 0 { delete(app.accessibility_source_error, context.allocator) }
	if len(app.accessibility_source_error_document_id) > 0 { delete(app.accessibility_source_error_document_id, context.allocator) }
	app.accessibility_source_error = ""
	app.accessibility_source_error_document_id = ""
	app.accessibility_source_error_revision = 0
	tree_clear_directories(app)
	if len(app.tree_root_path) > 0 { delete(app.tree_root_path, context.allocator) }
	app.tree_root_path = ""
	tree_clear_focused_path(app)
	app.tree_scroll_owner = 0
	editor_window_destroy(&app.editor_window)
	editor_views_destroy(&app.editor_views)
	delete(app.editor_row_targets)
	app.editor_row_targets = {}
	for index := len(app.editor_edits)-1; index >= 0; index -= 1 { editor_remove_edit(app, index) }
	delete(app.editor_edits)
	app.editor_edits = {}
	deferred_actions_clear(app)
	delete(app.deferred_actions)
	app.deferred_actions = {}
	deferred_action_destroy(&app.frame_deferred_action)
	app.frame_deferred_action_pending = false
	if len(app.editor_presented_document_id) > 0 { delete(app.editor_presented_document_id, context.allocator) }
	app.editor_presented_document_id = ""
	if len(app.editor_window_error) > 0 { delete(app.editor_window_error, context.allocator) }
	app.editor_window_error = ""
	editor_window_rejection_clear(app)
	workspace_mutation_clear(app)
	workspace_context_menu_clear(app)
	find_presentation_destroy(&app.find_presentation, context.allocator)
	workspace_search_view_destroy(&app.workspace_search_view, app.workspace_search_view.allocator)
	find_discard_saved_selection(app)
	find_set_message(&app.find_query, "")
	find_set_message(&app.find_replace_text, "")
	find_set_message(&app.find_replace_message, "")
	find_set_message(&app.find_error, "")
	find_set_message(&app.command_palette_query, "")
	quick_open_destroy(app)
	find_set_message(&app.workspace_search_query, "")
	find_set_message(&app.workspace_search_started_query, "")
	find_set_message(&app.workspace_search_started_root, "")
	find_set_message(&app.workspace_search_error, "")
	if len(app.theme_preferences_directory) > 0 { delete(app.theme_preferences_directory, context.allocator) }
	if len(app.theme_preferences_path) > 0 { delete(app.theme_preferences_path, context.allocator) }
	app.theme_preferences_directory = ""
	app.theme_preferences_path = ""
}

main :: proc() {
	app: App
	app.tree_directories = make([dynamic]Tree_Directory, 0, allocator=context.allocator)
	app.workspace_search_selected = -1
	app.editor_views = make([dynamic]Editor_View_State, 0, allocator=context.allocator)
	app.editor_row_targets = make([dynamic]Editor_Row_Target, 0, allocator=context.allocator)
	app.editor_edits = make([dynamic]Editor_Edit_Intent, 0, allocator=context.allocator)
	app.deferred_actions = make([dynamic]Deferred_Action, 0, allocator=context.allocator)
	app.editor_text_scale = 1
	init_menus(&app)
	if config_root, config_error := os.user_config_dir(context.allocator); config_error == nil {
		preferences_directory, preferences_path, ok := scratchpad_theme_preferences_location(config_root, context.allocator)
		delete(config_root, context.allocator)
		if ok {
			app.theme_preferences_directory = preferences_directory
			app.theme_preferences_path = preferences_path
			if choice, found := scratchpad_theme_preferences_load(preferences_path); found {
				app.theme_choice = choice
			}
		}
	}
	if library, found := os.lookup_env("SCRATCHPAD_BACKEND_LIBRARY", context.allocator); found { app.backend_library = library }
	if workspace, found := os.lookup_env("SCRATCHPAD_ALICORN_WORKSPACE", context.allocator); found { app.workspace_path = workspace }
	if smoke, found := os.lookup_env("SCRATCHPAD_ALICORN_SMOKE", context.allocator); found { app.smoke = smoke == "1" || smoke == "true" }
	host.Run(host.Application{
		state=rawptr(&app),
		title="Scratchpad — Alicorn",
		width=1200,
		height=760,
		menus=app.menus[:],
		build=build_app,
		on_key=application_key,
		on_pointer=application_pointer,
		on_drag=application_drag,
		on_text_key=editor_text_key,
		on_text_input=editor_text_input,
		on_text_change=command_palette_text_change,
		on_services=application_services,
		on_start=application_start,
		on_close_requested=application_close_requested,
		on_dialog=application_dialog,
		on_wake=application_wake,
		on_scheduled_wake=application_scheduled_wake,
		on_stop=application_stop,
		on_menu_command=application_menu_command,
	}, app.smoke)
	if app.smoke {
		passed := app.smoke_rendered && app.smoke_wake_observed && app.smoke_shutdown
		fmt.println("alicorn-smoke", "publication_rendered", app.smoke_rendered, "wake_observed", app.smoke_wake_observed, "ordered_shutdown", app.smoke_shutdown)
		if !passed { os.exit(1) }
	}
}
