package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"
import bridge "./bridge"

COLOR_BACKGROUND :: alicorn.Color{0.055, 0.065, 0.09, 1}
COLOR_PANEL      :: alicorn.Color{0.08, 0.095, 0.13, 1}
COLOR_SUBTLE     :: alicorn.Color{0.10, 0.12, 0.16, 1}

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
TREE_SEMANTIC_NAMESPACE :: u64(0x5343524154434850)
TREE_ROW_HEIGHT :: 28
TREE_SCROLL_KEY :: "scratchpad-workspace-tree"

Tree_Directory :: struct {
	path:      string,
	entries:   []bridge.Directory_Entry,
	truncated: bool,
	expanded:  bool,
}

Tree_Row :: struct {
	name:      string,
	path:      string,
	depth:     int,
	is_dir:    bool,
	expanded:  bool,
}

Deferred_Action_Kind :: enum {
	Action,
	Select_Document,
	Close_Document,
	Open_Path,
	Workspace_Mutation,
	Close_After_Save,
	Close_With_Discard,
	Cancel_Close_Prompt,
	Save_As_Path,
	Conflict_Reload,
	Conflict_Keep_Mine,
}

Deferred_Action :: struct {
	kind:        Deferred_Action_Kind,
	value:       string,
	path:        string,
	relative_path: string,
	name:        string,
	disposition: string,
	workspace_root: string,
	workspace_mutation_kind: Workspace_Mutation_Kind,
	source_is_dir: bool,
	discard:     bool,
}

Shutdown_Intent :: enum {None, Quit_Application}

MAX_DEFERRED_ACTIONS :: 64

App :: struct {
	backend:                bridge.Backend,
	visible_window_lane:    bridge.Visible_Window_Lane,
	editor_edit_lane:       bridge.Editor_Edit_Lane,
	quick_open_lane:        bridge.Workspace_Files_Lane,
	editor_edits:           [dynamic]Editor_Edit_Intent,
	deferred_actions:       [dynamic]Deferred_Action,
	editor_edit_sequence:   u64,
	editor_views:           [dynamic]Editor_View_State,
	editor_row_targets:     [dynamic]Editor_Row_Target,
	editor_window:          Editor_Window,
	editor_window_ready:    bool,
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
	workspace_context_path: string,
	workspace_context_is_dir: bool,
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
	view_items:             [1]host.Application_Menu_Item,
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

editor_render_table_pipe :: proc(ui: ^alicorn.UI, document_id: string, logical_line: u64, pipe_index: int, row_height: f32) {
	if ui == nil { return }
	pipe := alicorn.text(
		ui,
		"|",
		key=alicorn.key_string(fmt.tprintf("scratchpad-table-pipe:%s:%d:%d", document_id, logical_line, pipe_index)),
		style=alicorn.layout_style(.Row, width=10, height=row_height, align=.Start),
		font=.Monospace,
		text_style=alicorn.Text_Style{overflow=.Clip},
	)
	paint := [?]alicorn.Text_Paint_Span{{
		start=0,
		end=1,
		color=alicorn.Color{0.57, 0.63, 0.74, 1},
		color_set=true,
	}}
	_ = alicorn.text_paint_spans(ui, pipe, paint[:])
}

editor_render_table_cells :: proc(
	ui: ^alicorn.UI,
	app: ^App,
	rt: ^alicorn.Runtime,
	document_id: string,
	view: ^Editor_View_State,
	window: ^Editor_Window,
	line: ^Editor_Display_Line,
	table: Editor_Table_Row_Layout,
	row_height, wrap_width: f32,
	scroll_owner: alicorn.Node_ID,
	window_matches, paint_current: bool,
) {
	if ui == nil || app == nil || rt == nil || view == nil || window == nil || line == nil || !table.ok || !table.wraps { return }
	alicorn.container_begin(
		ui,
		.Container,
		label="scratchpad-table-visual-row",
		key=alicorn.key_string(fmt.tprintf("scratchpad-table-row:%s:%d", document_id, line.logical_line)),
		style=alicorn.layout_style(.Row, width=wrap_width, height=row_height, gap=0, align=.Start, clip=true),
	)
	pipe_index := 0
	if table.leading_pipe && pipe_index < len(table.pipes) {
		editor_render_table_pipe(ui, document_id, line.logical_line, pipe_index, row_height)
		pipe_index += 1
	}
	for &cell, cell_index in table.cells {
		cell_overflow := alicorn.Text_Overflow.Wrap
		if table.delimiter { cell_overflow = .Clip }
		cell_node := alicorn.text(
			ui,
			cell.display,
			key=alicorn.key_string(fmt.tprintf("scratchpad-table-cell:%s:%d:%d", document_id, line.logical_line, cell_index)),
			style=alicorn.layout_style(.Row, width=table.widths[cell_index], height=row_height, align=.Start, clip=true),
			font=.Monospace,
			text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_REGULAR, overflow=cell_overflow},
		)
		anchor_source := min(max(view.selection_anchor, cell.source_start), cell.source_end)
		caret_source := min(max(view.caret_byte, cell.source_start), cell.source_end)
		anchor_display := editor_source_to_display(&cell, anchor_source)
		caret_display := editor_source_to_display(&cell, caret_source)
		show_caret := window_matches && rt.focused == scroll_owner && view.caret_byte >= cell.source_start && view.caret_byte <= cell.source_end
		paint_spans: []alicorn.Text_Paint_Span
		text_style_spans: []alicorn.Text_Style_Span
		if paint_current {
			paint_spans = editor_presentation_spans_for_line(window, &cell, rt.scratch_allocator)
			text_style_spans = editor_presentation_text_styles_for_line(window, &cell, rt.scratch_allocator)
		}
		if show_caret && !view.preedit_active && !view.preedit_recoverable {
			if row_start, row_end, row_ok := editor_visual_row_display_range(
				rt, &cell, caret_display, view.caret_affinity, table.widths[cell_index], true, text_style_spans,
			); row_ok {
				caret_row := [?]alicorn.Text_Paint_Span{{
					start=row_start,
					end=row_end,
					background=EDITOR_CARET_ROW_BACKGROUND,
					background_set=true,
				}}
				paint_spans = editor_merge_text_paint_spans(paint_spans, caret_row[:], rt.scratch_allocator)
			}
		}
		search_spans := workspace_search_match_paint_spans_for_line(window, &cell, view, rt.scratch_allocator)
		paint_spans = editor_merge_text_paint_spans(paint_spans, search_spans, rt.scratch_allocator)
		if app.find_open { paint_spans = find_merge_paint_spans(window, &cell, &app.find_presentation, paint_spans, rt.scratch_allocator) }
		_ = alicorn.text_paint_spans(ui, cell_node, paint_spans)
		_ = alicorn.text_style_spans(ui, cell_node, text_style_spans)
		if !window_matches { anchor_display = caret_display }
		_ = alicorn.text_interaction(
			ui,
			cell_node,
			alicorn.Text_Position{byte=anchor_display, affinity=view.anchor_affinity},
			alicorn.Text_Position{byte=caret_display, affinity=view.caret_affinity},
			show_caret,
		)
		append(&app.editor_row_targets, Editor_Row_Target{
			node=cell_node,
			logical_line=line.logical_line,
			cell_start=cell.source_start,
			cell_end=cell.source_end,
			cell_index=cell_index,
			cell_width=table.widths[cell_index],
			cell_origin_x=table.origins[cell_index],
			is_cell=true,
		})
		if window_matches && rt.focused == scroll_owner && show_caret {
			app.editor_input_anchor_node = cell_node
			app.editor_input_anchor_byte = caret_display
			app.editor_input_anchor_affinity = view.caret_affinity
		}
		if cell_index+1 < len(table.cells) && pipe_index < len(table.pipes) {
			editor_render_table_pipe(ui, document_id, line.logical_line, pipe_index, row_height)
			pipe_index += 1
		}
	}
	if table.trailing_pipe && pipe_index < len(table.pipes) {
		editor_render_table_pipe(ui, document_id, line.logical_line, pipe_index, row_height)
	}
	alicorn.container_end(ui)
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
		alicorn.container_begin(&ui, .Container, label="workspace-panel-heading", style=alicorn.layout_style(.Row, height=30, gap=6, align=.Center))
		alicorn.text(&ui, "SEARCH" if app.workspace_search_mode else "FILES", style=alicorn.layout_style(.Row, grow=1, height=26))
		if alicorn.button(&ui, "Quick Open", key=alicorn.key_string("workspace-quick-open"), style=alicorn.layout_style(.Row, width=84, height=28)) {
			quick_open_open_surface(app, rt)
		}
		if alicorn.button(&ui, "Commands…", key=alicorn.key_string("workspace-command-palette-open"), style=alicorn.layout_style(.Row, width=100, height=28)) {
			command_palette_open_surface(app, rt)
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
					if alicorn.button(&ui, label, key=alicorn.key_string(fmt.tprintf("workspace-search-result:%d:%d", app.workspace_search_view.generation, position)), style=alicorn.layout_style(.Row, height=68), state=alicorn.Button_State{selected=app.workspace_search_selected == position}, text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_REGULAR, overflow=.Wrap}, content_style=alicorn.button_content_style(.Start, padding_x=7, padding_y=5)) {
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
			title := document_title(document.path)
			if document.preview && !document.dirty { title = fmt.tprintf("%s (preview)", title) }
			if document.dirty { title = fmt.tprintf("%s •", title) }
			selected := state.active == document.id
			if alicorn.button(&ui, title, key=alicorn.key_string(fmt.tprintf("tab:%s", document.id)), style=alicorn.layout_style(.Row, width=180, height=32), state=alicorn.Button_State{selected=selected}, content_style=alicorn.button_content_style(.Start, padding_x=10)) {
				if !frame_deferred_action_schedule(app, .Select_Document, document.id) {
					set_error(app, "Could not queue document selection until the current frame is complete.")
					alicorn.invalidate_root(rt, "Scratchpad could not defer tab selection")
				}
			}
			if alicorn.button(&ui, "×", key=alicorn.key_string(fmt.tprintf("tab-close:%s", document.id)), style=alicorn.layout_style(.Row, width=30, height=32)) {
				if !frame_deferred_action_schedule(app, .Close_Document, document.id) {
					set_error(app, "Could not queue document close until the current frame is complete.")
					alicorn.invalidate_root(rt, "Scratchpad could not defer tab close")
				}
			}
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
			build_document_editor(app, &ui, rt, active)
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
			if node, found := rt.nodes[app.go_to_line_query_node]; found && node.kind == .Text_Field {
				_ = alicorn.set_text_selection(rt, app.go_to_line_query_node, 0, len(node.text))
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
				rect=alicorn.Rect{geometry.rect.x, geometry.rect.y, 1, max(geometry.rect.h, EDITOR_ROW_HEIGHT)},
				cursor_x=0,
			}
			_ = alicorn.text_input_target_area_set(rt, app.editor_scroll_owner, area)
		}
	}
	workspace_search_reveal_after_frame(app, rt)
	if app.smoke && app.backend.started && app.backend.state.revision > 0 { app.smoke_rendered = true }
	return root
}

shutdown_has_uncommitted_work :: proc(app: ^App) -> bool {
	if app == nil { return false }
	if len(app.editor_edits) > 0 { return true }
	for document in app.backend.state.documents { if document.dirty { return true } }
	for view in app.editor_views {
		if view.preedit_active && view.preedit_recoverable { return true }
	}
	return false
}

shutdown_dirty_document_count :: proc(app: ^App) -> int {
	if app == nil { return 0 }
	count := 0
	for document in app.backend.state.documents { if document.dirty { count += 1 } }
	return count
}

shutdown_recoverable_document :: proc(app: ^App) -> string {
	if app == nil { return "" }
	for view in app.editor_views {
		if view.preedit_active && view.preedit_recoverable { return view.document_id }
	}
	return ""
}

shutdown_begin :: proc(app: ^App, rt: ^alicorn.Runtime, intent: Shutdown_Intent) {
	if app == nil || intent == .None { return }
	app.shutdown_intent = intent
	app.shutdown_edit_failed = false
	if rt != nil { alicorn.invalidate_root(rt, "Scratchpad deferred shutdown for unsaved editor work") }
}

application_close_requested :: proc(state: rawptr, rt: ^alicorn.Runtime) -> host.Application_Close_Result {
	app := cast(^App)state
	if app == nil || !app.backend.started { return .Allow }
	if app.shutdown_intent != .None { return .Defer }
	if !shutdown_has_uncommitted_work(app) { return .Allow }
	shutdown_begin(app, rt, .Quit_Application)
	return .Defer
}

shutdown_cancel :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil { return }
	app.shutdown_intent = .None
	app.shutdown_edit_failed = false
	if rt != nil { alicorn.invalidate_root(rt, "Scratchpad shutdown request cancelled") }
}

shutdown_finish :: proc(app: ^App) {
	if app == nil { return }
	intent := app.shutdown_intent
	app.shutdown_intent = .None
	app.shutdown_edit_failed = false
	if intent == .Quit_Application {
		host.application_request_quit(app.services.quit)
	}
}

shutdown_advance :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || app.shutdown_intent == .None || app.shutdown_edit_failed || len(app.editor_edits) > 0 { return }
	if shutdown_dirty_document_count(app) > 0 || shutdown_recoverable_document(app) != "" { return }
	shutdown_finish(app)
}

shutdown_save_all :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || !app.backend.started || len(app.editor_edits) > 0 { return }
	document_ids := make([dynamic]string, 0, allocator=context.allocator)
	for document in app.backend.state.documents {
		if !document.dirty { continue }
		id, clone_error := strings.clone(document.id, context.allocator)
		if clone_error != nil {
			for owned_id in document_ids { delete(owned_id, context.allocator) }
			delete(document_ids)
			set_error(app, "Could not retain document identities while saving before shutdown.")
			if rt != nil { alicorn.invalidate_root(rt, "Scratchpad could not prepare save-all shutdown") }
			return
		}
		append(&document_ids, id)
	}
	for id in document_ids {
		response := bridge.backend_command(&app.backend, "save_document", document_id=id)
		if !response.ok { handle_command_result(app, rt, &response) }
		ok := response.ok
		bridge.backend_command_result_destroy(&response, context.allocator)
		if !ok {
			for owned_id in document_ids { delete(owned_id, context.allocator) }
			delete(document_ids)
			return
		}
	}
	for owned_id in document_ids { delete(owned_id, context.allocator) }
	delete(document_ids)
	set_error(app, "")
	shutdown_advance(app, rt)
	if rt != nil { alicorn.invalidate_root(rt, "Scratchpad saved modified documents before shutdown") }
}

shutdown_discard_all :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || len(app.editor_edits) > 0 { return }
	for &view in app.editor_views {
		if view.preedit_active && view.preedit_recoverable {
			editor_preedit_clear(&view)
		}
	}
	shutdown_finish(app)
}

build_shutdown_dialog :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime) {
	if app == nil || ui == nil { return }
	alicorn.modal_overlay_begin(ui, alicorn.key_string("shutdown-overlay"), style=alicorn.layout_style(.Column, grow=1, align=.Center), backdrop_color=alicorn.Color{0.015, 0.02, 0.03, 0.72})
	alicorn.container_begin(ui, .Container, label="shutdown-dialog", style=alicorn.layout_style(.Column, width=540, height=320, padding=22, gap=12, align=.Start, clip=true), color=COLOR_PANEL)
	alicorn.text(ui, "Save changes before closing Scratchpad?")
	if len(app.editor_edits) > 0 {
		alicorn.text(ui, fmt.tprintf("Waiting for %d pending editor change(s) to finish.", len(app.editor_edits)))
	} else {
		dirty_count := shutdown_dirty_document_count(app)
		if dirty_count > 0 {
			alicorn.text(ui, fmt.tprintf("%d modified document(s) have unsaved changes.", dirty_count))
		}
		if app.shutdown_edit_failed {
			alicorn.text(ui, "An editor change could not be saved. Review the error above or explicitly discard it.")
		}
		recoverable_id := shutdown_recoverable_document(app)
		if recoverable_id != "" {
			if document, found := find_document(&app.backend.state, recoverable_id); found {
				alicorn.text(ui, fmt.tprintf("Committed input in %s is waiting to be copied or discarded.", document_title(document.path)))
			} else {
				alicorn.text(ui, "Committed input is waiting to be copied or discarded.")
			}
			alicorn.container_begin(ui, .Container, label="shutdown-recovery-actions", style=alicorn.layout_style(.Row, height=38, gap=8, align=.Center))
			if alicorn.button(ui, "Copy Recovery", key=alicorn.key_string("shutdown-copy-recovery"), style=alicorn.layout_style(.Row, width=135, height=34)) {
				_ = editor_copy_recoverable_preedit(app, rt, recoverable_id)
				shutdown_advance(app, rt)
			}
			if alicorn.button(ui, "Discard Recovery", key=alicorn.key_string("shutdown-discard-recovery"), style=alicorn.layout_style(.Row, width=145, height=34)) {
				_ = editor_discard_recoverable_preedit(app, rt, recoverable_id)
				shutdown_advance(app, rt)
			}
			alicorn.container_end(ui)
		}
		if dirty_count > 0 {
			alicorn.container_begin(ui, .Container, label="shutdown-document-actions", style=alicorn.layout_style(.Row, height=38, gap=8, align=.Center))
			if alicorn.button(ui, "Save All", key=alicorn.key_string("shutdown-save-all"), style=alicorn.layout_style(.Row, width=115, height=34)) {
				shutdown_save_all(app, rt)
			}
			if alicorn.button(ui, "Discard All", key=alicorn.key_string("shutdown-discard-all"), style=alicorn.layout_style(.Row, width=115, height=34)) {
				shutdown_discard_all(app, rt)
			}
			alicorn.container_end(ui)
		}
		if app.shutdown_edit_failed && dirty_count == 0 {
			if alicorn.button(ui, "Close Anyway", key=alicorn.key_string("shutdown-edit-failure-discard"), style=alicorn.layout_style(.Row, width=135, height=34)) {
				shutdown_discard_all(app, rt)
			}
		}
	}
	alicorn.container_begin(ui, .Container, label="shutdown-cancel-actions", style=alicorn.layout_style(.Row, height=38, gap=8, align=.End))
	if alicorn.button(ui, "Cancel", key=alicorn.key_string("shutdown-cancel"), style=alicorn.layout_style(.Row, width=90, height=34)) {
		shutdown_cancel(app, rt)
	}
	alicorn.container_end(ui)
	alicorn.container_end(ui)
	alicorn.modal_overlay_end(ui)
}

editor_wrap_viewport_size :: proc(
	rt: ^alicorn.Runtime,
	view: ^Editor_View_State,
	previous: alicorn.Scroll_Region_Handle,
) -> (width, height: f32) {
	if rt == nil || view == nil { return 240, EDITOR_ROW_HEIGHT }
	outer_width, outer_height := rt.viewport.w, rt.viewport.h
	width, height = previous.viewport_width, previous.viewport_height
	if previous.id == 0 || width <= 0 {
		width = max(outer_width-320, 240)
	} else if view.wrap_last_outer_width > 0 {
		width += outer_width-view.wrap_last_outer_width
	}
	if previous.id == 0 || height <= 0 {
		height = max(outer_height-220, EDITOR_ROW_HEIGHT)
	} else if view.wrap_last_outer_height > 0 {
		height += outer_height-view.wrap_last_outer_height
	}
	for node_id in rt.order {
		node, found := rt.nodes[node_id]
		if !found || node.kind != .Split || node.label != "scratchpad-workspace-editor-split" { continue }
		// If retained layout has already applied the drag, the scroll region
		// width includes the split movement. While layout is pending, its saved
		// viewport is still from the previous split position, so apply the delta
		// exactly once. This avoids both stale row heights and double-counting
		// when the editor narrows during a drag.
		if view.wrap_last_split_position_valid && (!node.split_dragging || rt.layout_pending) {
			width -= node.split_position-view.wrap_last_split_position
		}
		view.wrap_last_split_position = node.split_position
		view.wrap_last_split_position_valid = true
		break
	}
	view.wrap_last_outer_width = outer_width
	view.wrap_last_outer_height = outer_height
	return max(width, 240), max(height, EDITOR_ROW_HEIGHT)
}

build_document_editor :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime, document: bridge.State_Document) {
	view_index, view_ok := editor_view_ensure(&app.editor_views, document.id)
	if !view_ok {
		alicorn.text(ui, "Could not retain this document's view state.")
		return
	}
	view := &app.editor_views[view_index]
	if view.workspace_search_match_active && view.workspace_search_match_revision != document.editor_revision {
		workspace_search_match_clear(view)
	}
	if app.editor_presented_document_id != document.id {
		if old_view_index := editor_view_find(app.editor_views[:], app.editor_presented_document_id); old_view_index >= 0 {
			editor_preedit_clear_for_document_switch(&app.editor_views[old_view_index])
		}
		presented_id, clone_error := strings.clone(document.id, context.allocator)
		if clone_error != nil {
			alicorn.text(ui, "Could not retain the active document identity.")
			return
		}
		if len(app.editor_presented_document_id) > 0 { delete(app.editor_presented_document_id, context.allocator) }
		app.editor_presented_document_id = presented_id
		editor_view_mark_active(view)
	}
	alicorn.container_begin(ui, .Container, label="document-view-heading", style=alicorn.layout_style(.Row, height=30, gap=12, align=.Center))
	display_line_count := document.line_count
	if view.optimistic_pending_edits > 0 {
		if view.optimistic_line_delta < 0 {
			removed := u64(-view.optimistic_line_delta)
			display_line_count = display_line_count-removed if removed < display_line_count else 1
		} else {
			display_line_count += u64(view.optimistic_line_delta)
		}
	}
	heading := fmt.tprintf("%s  ·  %s  ·  %d lines", document_title(document.path), document.language, display_line_count)
	alicorn.text(ui, heading)
	if app.editor_window_error != "" { alicorn.text(ui, fmt.tprintf("Window: %s", app.editor_window_error)) }
	alicorn.container_end(ui)
	if document.status == "conflict" {
		alicorn.container_begin(ui, .Container, label="document-conflict-actions", key=alicorn.key_string(fmt.tprintf("document-conflict:%s", document.id)), style=alicorn.layout_style(.Column, height=68, padding=7, gap=4), color=COLOR_SUBTLE)
		alicorn.text(ui, "This file changed on disk. Your edits are preserved. Reload discards them; Keep Mine overwrites the disk version.")
		alicorn.container_begin(ui, .Container, label="document-conflict-buttons", style=alicorn.layout_style(.Row, height=30, gap=8, align=.Center))
		if alicorn.button(ui, "Reload from Disk", key=alicorn.key_string(fmt.tprintf("conflict-reload:%s", document.id)), style=alicorn.layout_style(.Row, width=140, height=28)) {
			editor_resolve_conflict(app, rt, document.id, false)
		}
		if alicorn.button(ui, "Keep Mine", key=alicorn.key_string(fmt.tprintf("conflict-keep:%s", document.id)), style=alicorn.layout_style(.Row, width=104, height=28)) {
			editor_resolve_conflict(app, rt, document.id, true)
		}
		if alicorn.button(ui, "Save As…", key=alicorn.key_string(fmt.tprintf("conflict-save-as:%s", document.id)), style=alicorn.layout_style(.Row, width=100, height=28)) {
			request_file_dialog(app, rt, .Save_File, "Save As")
		}
		alicorn.container_end(ui)
		alicorn.container_end(ui)
	}

	window, window_matches := editor_presentation_window(
		view,
		&app.editor_window,
		app.editor_window_ready,
		document.id,
		document.editor_revision,
	)
	window_available := window != nil
	// The backend rebuilds the Markdown table projection synchronously when a
	// semantic command arrives. Do not make the menu depend on an asynchronous,
	// bounded presentation window; the command reports when the caret is outside
	// a formattable table.
	format_table_enabled := document.language == "markdown"
	for &item in app.document_items {
		if item.kind == .Command && item.command == action_id_for(ACTION_DOCUMENT_FORMAT) {
			item.state.enabled = format_table_enabled
		}
	}
	if window_matches {
		_ = editor_view_resolve_document_edge(view, window, display_line_count)
		_ = editor_view_resolve_goto_line(view, window, display_line_count)
		if line, found := editor_line_for_source(window, view.caret_byte); found {
			previous_caret := view.caret_byte
			view.caret_byte = editor_normalize_source_position(line, view.caret_byte)
			if view.selection_anchor == previous_caret { view.selection_anchor = view.caret_byte }
		}
		if line, found := editor_line_for_source(window, view.selection_anchor); found {
			view.selection_anchor = editor_normalize_source_position(line, view.selection_anchor)
		}
	}
	gutter_width := editor_line_number_gutter_width(display_line_count)
	line_count := int(display_line_count)
	if line_count < 1 { line_count = 1 }
	if !view.wrap_height_index_ready {
		view.wrap_height_index_ready = alicorn.virtual_list_height_index_init(
			&view.wrap_height_index, line_count, EDITOR_ROW_HEIGHT, context.allocator,
		)
	}
	if view.wrap_height_index_ready {
		_ = alicorn.virtual_list_height_index_set_count(&view.wrap_height_index, line_count)
	}
	previous_scroll := alicorn.scroll_region_state(rt, app.editor_scroll_owner)
	viewport_width, viewport_height := editor_wrap_viewport_size(rt, view, previous_scroll)
	wrap_width := max(viewport_width-gutter_width-16, 80)
	scroll_y := view.scroll_y
	if !view.restore_y_pending && previous_scroll.id != 0 { scroll_y = previous_scroll.offset_y }
	if view.viewport_anchor_pending && view.viewport_anchor_resolved && window_matches {
		if anchor_line, anchor_found := editor_line_for_source(window, view.viewport_anchor_byte); anchor_found {
			anchor_top := alicorn.virtual_list_height_index_item_top(&view.wrap_height_index, int(anchor_line.logical_line))
			scroll_y = max(anchor_top+view.viewport_anchor_offset, 0)
			view.scroll_y = scroll_y
			view.restore_y_pending = true
		}
	}
	request_presentation := document.language == "markdown"
	presentation_window_matches := document.presentation_ready && window_matches && window.presentation_ready &&
	                              !window.presentation_stale &&
	                              window.presentation_revision == document.presentation_revision &&
	                              window.presentation_revision == document.editor_revision
	// Exact parser metadata is authoritative. A locally rebased presentation is
	// also safe for visual continuity after the edit ACK; it stays presentation-
	// only until the exact projection for the accepted source revision arrives.
	presentation_visual := presentation_window_matches ||
	                       (document.language == "markdown" && window_matches && window.presentation_ready &&
	                        window.presentation_stale)
	// A rebased projection can keep the current text styled, but it is not the
	// parser's answer for a newer revision. Fetch exact metadata when Goldmark
	// catches up; if this revision was already chased into the optimistic window,
	// do not request the same projection repeatedly.
	metadata_refresh_needed := request_presentation && document.presentation_ready && !presentation_window_matches
	if window_matches && window.presentation_ready && window.presentation_revision == document.presentation_revision {
		metadata_refresh_needed = false
	}
	if view.wrap_height_index_ready && window_available {
		needs_measurement := abs(view.wrap_measurement_width-wrap_width) > 0.5 ||
		                     view.wrap_measurement_mode != view.wrap_mode ||
		                     view.wrap_measurement_revision != window.editor_revision ||
		                     view.wrap_measurement_presentation_revision != window.presentation_revision ||
		                     view.wrap_measurement_start_line != window.start_line ||
		                     view.wrap_measurement_end_line != window.end_line ||
		                     view.wrap_measurement_pending_edits != view.optimistic_pending_edits ||
		                     metadata_refresh_needed || view.viewport_anchor_pending
		if needs_measurement {
			before := alicorn.virtual_list_variable_metrics(&view.wrap_height_index, scroll_y, viewport_height)
			anchor_line := before.first
			anchor_top := alicorn.virtual_list_height_index_item_top(&view.wrap_height_index, anchor_line)
			anchor_byte := u64(0)
			anchor_offset := scroll_y-anchor_top
			if anchor_source_line, anchor_line_found := editor_window_line(window, u64(anchor_line)); anchor_line_found {
				anchor_byte = anchor_source_line.source_start
			}
			if view.viewport_anchor_pending && view.viewport_anchor_resolved {
				anchor_byte = view.viewport_anchor_byte
				anchor_offset = view.viewport_anchor_offset
			}
			_ = editor_measure_window_wrapping(
				rt, view, window, document.language, wrap_width,
				presentation_visual,
			)
			new_anchor_line := anchor_line
			if mapped_line, mapped := editor_line_for_source(window, anchor_byte); mapped {
				new_anchor_line = int(mapped_line.logical_line)
			}
			new_anchor_top := alicorn.virtual_list_height_index_item_top(&view.wrap_height_index, new_anchor_line)
			if previous_scroll.id != 0 {
				scroll_y = max(new_anchor_top+anchor_offset, 0)
				if view.restore_y_pending {
					view.scroll_y = scroll_y
				} else if abs(scroll_y-previous_scroll.offset_y) > 0.01 {
					_ = alicorn.scroll_region_set_offset(rt, previous_scroll.id, scroll_y, "Scratchpad preserved the source-relative viewport anchor while text reflowed")
				}
			}
			if view.viewport_anchor_pending && view.viewport_anchor_resolved {
				view.viewport_anchor_pending = false
				view.viewport_anchor_resolved = false
			}
			view.wrap_measurement_width = wrap_width
			view.wrap_measurement_mode = view.wrap_mode
			view.wrap_measurement_revision = window.editor_revision
			view.wrap_measurement_presentation_revision = window.presentation_revision
			view.wrap_measurement_start_line = window.start_line
			view.wrap_measurement_end_line = window.end_line
			view.wrap_measurement_pending_edits = view.optimistic_pending_edits
		}
	}
	// Search navigation is an explicit source destination, so it takes
	// precedence over the document's saved tab scroll position. Resolve its
	// vertical location after wrapping measurements, then apply it after this
	// frame has emitted the destination document's retained scroll region.
	if view.workspace_search_reveal_pending &&
	   view.workspace_search_match_revision == document.editor_revision &&
	   view.wrap_height_index_ready &&
	   view.workspace_search_reveal_line < u64(max(line_count, 0)) {
		target_line := int(view.workspace_search_reveal_line)
		target_top := alicorn.virtual_list_height_index_item_top(&view.wrap_height_index, target_line)
		target_height := alicorn.virtual_list_height_index_item_height(&view.wrap_height_index, target_line)
		if target_height <= 0 { target_height = EDITOR_ROW_HEIGHT }
		desired_y, _ := find_match_center_offset(scroll_y, viewport_height, target_top, target_height)
		max_y := max(view.wrap_height_index.total_height-viewport_height, 0)
		desired_y = min(max(desired_y, 0), max_y)
		scroll_y = desired_y
		view.scroll_y = desired_y
		view.restore_y_pending = true
	}
	visible_intrinsic_width: f32 = 0
	if window_matches {
		visible_intrinsic_width = editor_visible_window_content_width(
			window,
			&view.wrap_height_index,
			scroll_y,
			viewport_height,
			gutter_width,
			document.language,
			presentation_visual,
			wrap_width,
			view.wrap_mode,
		)
	}
	content_width := max(viewport_width, visible_intrinsic_width)
	// Keep editor rows in a fixed horizontal viewport. The scroll region still
	// owns horizontal extent and its scrollbar, but only individual no-wrap
	// source lanes consume scroll_x. This leaves the gutter and clipped text
	// lane fixed while long source lines move inside that lane.
	alicorn.virtual_list_height_index_rebuild_prefix(&view.wrap_height_index)
	editor_scroll := alicorn.scroll_region_begin(
		ui,
		key=alicorn.key_string(fmt.tprintf("scratchpad-editor:%s", document.id)),
		content_height=view.wrap_height_index.total_height,
		line_height=view.wrap_height_index.estimated_height,
		content_width=content_width,
		style=alicorn.layout_style(grow=1, clip=true),
		label="scratchpad-visible-document-lines",
		axes=.Both,
		focusable=true,
	)
	list_metrics := alicorn.virtual_list_variable_metrics(
		&view.wrap_height_index,
		editor_scroll.offset_y,
		editor_scroll.viewport_height,
	)
	list_content_style := alicorn.layout_style(width=-1, height=editor_scroll.viewport_height, clip=true)
	if content_width > 0 { list_content_style.width = content_width }
	alicorn.container_begin(
		ui,
		.Virtual_List,
		label="scratchpad-visible-document-lines",
		style=list_content_style,
		scroll_offset_y=list_metrics.offset_y,
		layout_scroll_offset_y=list_metrics.leading_offset_y,
		scroll_offset_x=editor_scroll.offset_x,
		layout_scroll_offset_x=0,
	)
	list := alicorn.Virtual_List_Handle{
		scroll=editor_scroll,
		first=list_metrics.first,
		last=list_metrics.last,
	}
	horizontal_ready := window_matches && list.scroll.max_scroll_x > 0.5
	editor_has_focus := rt.focused == list.scroll.id
	if view.undo_group_editor_focus != editor_has_focus {
		editor_undo_group_break(view)
		view.undo_group_editor_focus = editor_has_focus
	}
	_ = editor_register_text_input_target(ui, list.scroll.id, view)
	if rt != nil {
		// Keep native text input away from stale source bytes. The editor input
		// handlers independently reject edits until an exact-revision window is
		// installed; suspending here also prevents IME preedit from targeting an
		// obsolete caret location.
		suspend_text_input := !window_matches || editor_preedit_recovery_is_full(view)
		_ = alicorn.text_input_target_set_suspended(rt, list.scroll.id, suspend_text_input)
	}
	app.editor_scroll_owner = list.scroll.id
	restore := editor_view_sync_scroll(
		view,
		list.scroll.offset_y,
		list.scroll.offset_x,
		list.scroll.max_scroll_y,
		list.scroll.max_scroll_x,
		horizontal_ready,
	)
	if restore.vertical || restore.horizontal {
		app.editor_restore_scroll = true
		app.editor_restore_vertical = restore.vertical
		app.editor_restore_horizontal = restore.horizontal
		app.editor_restore_y = restore.scroll_y
		app.editor_restore_x = restore.scroll_x
	}
	visible_start := u64(max(list.first, 0))
	visible_end := u64(max(list.last, 0))
	window_covers_view := window_matches &&
	                      window.start_line <= visible_start &&
	                      window.end_line >= visible_end
	if metadata_refresh_needed { window_covers_view = false }
	bracket_match: Editor_Bracket_Match
	bracket_match_found := false
	if window_matches && !view.preedit_active && !view.preedit_recoverable {
		bracket_match, bracket_match_found = editor_bracket_match_in_window(window, view.caret_byte)
	}
	for position := list.first; position < list.last; position += 1 {
		line_number := u64(position)
		row_height := alicorn.virtual_list_height_index_item_height(&view.wrap_height_index, position)
		if row_height <= 0 { row_height = EDITOR_ROW_HEIGHT }
		if line, found := editor_window_line(window, line_number); window_available && found {
			table_row := editor_table_row_layout(window, line, wrap_width)
			table_wrap_active := table_row.ok && table_row.wraps && !view.preedit_active && !view.preedit_recoverable
			line_wraps := editor_line_should_wrap_for_view(document.language, window, line, presentation_visual, wrap_width, view.wrap_mode)
			if editor_table_line_is_projected(window, line) && !table_wrap_active { line_wraps = false }
			row_presentation_current := document.language == "markdown" && presentation_visual &&
			                           !view.preedit_active && !view.preedit_recoverable
			markdown_row := editor_markdown_row_presentation(window, line, row_presentation_current)
			row_background := editor_markdown_row_background(markdown_row)
			row_key := alicorn.key_string(fmt.tprintf("scratchpad-row:%s:%d", document.id, line.logical_line))
			alicorn.container_begin(
				ui,
				.Container,
				label="scratchpad-editor-logical-line",
				key=row_key,
				style=alicorn.layout_style(.Row, height=row_height, gap=8, align=.Center, clip=true),
				color=row_background,
			)
			// The parent virtual list shifts the whole row for horizontal scroll.
			// Counter-shift fixed chrome and wrapped prose; no-wrap text stays in
			// the parent's scrolling lane.
			alicorn.container_begin_ex(
				ui,
				.Virtual_List,
				label="scratchpad-editor-line-number-gutter",
				key=fmt.tprintf("scratchpad-gutter-lane:%s:%d", document.id, line.logical_line),
				style=alicorn.layout_style(.Row, width=gutter_width, height=row_height, align=.Center, clip=true),
				color=COLOR_BACKGROUND,
			)
			alicorn.container_begin(ui, .Container, label="scratchpad-editor-line-number-spacer", style=alicorn.layout_style(.Row, grow=1))
			alicorn.container_end(ui)
			line_number_text := editor_line_number_text(line.logical_line+1)
			line_number_node := alicorn.text(
				ui,
				line_number_text,
				key=alicorn.key_string(fmt.tprintf("scratchpad-line-number:%s:%d", document.id, line.logical_line)),
				font=.Monospace,
			)
			if window_matches && rt.focused == list.scroll.id &&
			   view.caret_byte >= line.source_start && view.caret_byte <= line.source_end &&
			   !view.preedit_active && !view.preedit_recoverable {
				gutter_paint := [?]alicorn.Text_Paint_Span{{
					start=0,
					end=len(line_number_text),
					background=EDITOR_CARET_GUTTER_BACKGROUND,
					background_set=true,
				}}
				_ = alicorn.text_paint_spans(ui, line_number_node, gutter_paint[:])
			}
			alicorn.container_end(ui)
			alicorn.container_begin_ex(
				ui,
				.Virtual_List,
				label="scratchpad-editor-source-lane",
				key=fmt.tprintf("scratchpad-source-lane:%s:%d", document.id, line.logical_line),
				style=alicorn.layout_style(.Row, width=wrap_width, height=row_height, clip=true),
				scroll_offset_x=list.scroll.offset_x if !line_wraps else 0,
				layout_scroll_offset_x=list.scroll.offset_x if !line_wraps else 0,
			)
			if table_wrap_active {
				paint_table := window_covers_view && presentation_visual &&
				               window.document_id == document.id && !view.preedit_active && !view.preedit_recoverable
				editor_render_table_cells(
					ui, app, rt, document.id, view, window, line, table_row,
					row_height, wrap_width, list.scroll.id, window_matches, paint_table,
				)
			} else {
			anchor_source := min(max(view.selection_anchor, line.source_start), line.source_end)
			caret_source := min(max(view.caret_byte, line.source_start), line.source_end)
			display_text := line.display
			anchor_display := editor_source_to_display(line, anchor_source)
			caret_display := editor_source_to_display(line, caret_source)
			caret_area_byte := caret_display
			caret_area_affinity := view.caret_affinity
			show_caret := window_matches && rt.focused == list.scroll.id && view.caret_byte >= line.source_start && view.caret_byte <= line.source_end
			if window_matches {
				if composition_display, composition_start, composition_end, applies := editor_preedit_display_for_line(view, window, line); applies {
				display_text = composition_display
				anchor_display, caret_display = composition_start, composition_end
				if anchor_display == caret_display && len(view.preedit_text) > 0 {
					// A zero-width SDL composition range still needs visible
					// feedback; highlight the composed text as the underline
					// equivalent while keeping the candidate caret at SDL's byte
					// position.
					anchor_display = composition_start
					caret_display = composition_start+len(view.preedit_text)
				}
				caret_area_byte = composition_end
				caret_area_affinity = .Trailing
				composition_start_line, start_found := editor_line_for_source(window, view.preedit_replace_start)
				show_caret = start_found && composition_start_line.logical_line == line.logical_line && rt.focused == list.scroll.id
				}
			} else {
				// The last authoritative selection may not describe the last-good
				// bytes after an undo. Render the old text without stale selection
				// or caret decoration while interaction authority is suspended.
				anchor_display = caret_display
			}
			line_text_style := alicorn.layout_style(.Row, height=row_height)
			text_overflow := alicorn.Text_Overflow.Clip
			if line_wraps {
				line_text_style.width = wrap_width
				text_overflow = .Wrap
			}
			line_node := alicorn.text(
				ui,
				display_text,
				key=alicorn.key_string(fmt.tprintf("scratchpad-line:%s:%d", document.id, line.logical_line)),
				style=line_text_style,
				font=.Monospace,
				text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_REGULAR, overflow=text_overflow},
			)
			paint_spans: []alicorn.Text_Paint_Span
			paint_current := window_covers_view && presentation_visual &&
			                 window.document_id == document.id && !view.preedit_active && !view.preedit_recoverable
			if paint_current {
				paint_spans = editor_presentation_spans_for_line(window, line, rt.scratch_allocator)
			}
			text_style_spans: []alicorn.Text_Style_Span
			if paint_current { text_style_spans = editor_presentation_text_styles_for_line(window, line, rt.scratch_allocator) }
			decoration_current := window_covers_view && window.document_id == document.id &&
			                      !view.preedit_active && !view.preedit_recoverable
			if decoration_current && show_caret {
				if row_start, row_end, row_ok := editor_visual_row_display_range(
					rt, line, caret_display, view.caret_affinity, wrap_width, line_wraps, text_style_spans,
				); row_ok {
					caret_row := [?]alicorn.Text_Paint_Span{{
						start=row_start,
						end=row_end,
						background=EDITOR_CARET_ROW_BACKGROUND,
						background_set=true,
					}}
					paint_spans = editor_merge_text_paint_spans(paint_spans, caret_row[:], rt.scratch_allocator)
				}
			}
			if decoration_current {
				search_spans := workspace_search_match_paint_spans_for_line(window, line, view, rt.scratch_allocator)
				paint_spans = editor_merge_text_paint_spans(paint_spans, search_spans, rt.scratch_allocator)
				if app.find_open { paint_spans = find_merge_paint_spans(window, line, &app.find_presentation, paint_spans, rt.scratch_allocator) }
			}
			if bracket_match_found {
				combined_spans := make([dynamic]alicorn.Text_Paint_Span, 0, len(paint_spans)+2, allocator=rt.scratch_allocator)
				for span in paint_spans { append(&combined_spans, span) }
				bracket_bytes := [2]u64{bracket_match.first, bracket_match.second}
				for source_byte in bracket_bytes {
					if source_byte < line.source_start || source_byte >= line.source_end { continue }
					start, end, mapped := editor_source_range_to_display(line, source_byte, source_byte+1)
					if !mapped { continue }
					append(&combined_spans, alicorn.Text_Paint_Span{
						start=start,
						end=end,
						background=alicorn.Color{0.34, 0.48, 0.72, 0.7},
						background_set=true,
					})
				}
				paint_spans = combined_spans[:]
			}
			_ = alicorn.text_paint_spans(ui, line_node, paint_spans)
			_ = alicorn.text_style_spans(ui, line_node, text_style_spans)
			append(&app.editor_row_targets, Editor_Row_Target{node=line_node, logical_line=line.logical_line})
			composition_row := false
			if window_matches && view.preedit_active {
				if composition_line, composition_found := editor_line_for_source(window, view.preedit_replace_start); composition_found {
					composition_row = composition_line.logical_line == line.logical_line
				}
			}
			if window_matches && rt.focused == list.scroll.id && ((view.caret_byte >= line.source_start && view.caret_byte <= line.source_end) || composition_row) {
				app.editor_input_anchor_node = line_node
				app.editor_input_anchor_byte = caret_area_byte
				app.editor_input_anchor_affinity = caret_area_affinity
			}
			_ = alicorn.text_interaction(
				ui,
				line_node,
				alicorn.Text_Position{byte=anchor_display, affinity=view.anchor_affinity},
				alicorn.Text_Position{byte=caret_display, affinity=view.caret_affinity},
				show_caret,
			)
			}
			alicorn.container_end(ui)
			alicorn.container_end(ui)
		} else if window_matches || !window_available {
			label := fmt.tprintf("Loading line %d…", line_number+1)
			alicorn.text(
				ui,
				label,
				key=alicorn.key_string(fmt.tprintf("scratchpad-loading-line:%s:%d", document.id, line_number)),
				style=alicorn.layout_style(.Row, height=row_height),
			)
		} else {
			// A newer document snapshot may have added rows that do not exist in
			// the last-good bounded window. Preserve the current topology without
			// claiming those bytes are loading; the matching refresh will fill it.
			alicorn.text(
				ui,
				"",
				key=alicorn.key_string(fmt.tprintf("scratchpad-stale-line:%s:%d", document.id, line_number)),
				style=alicorn.layout_style(.Row, height=row_height),
			)
		}
	}
	alicorn.virtual_list_end(ui, list)

	request_start := visible_start
	if request_start > 64 { request_start -= 64 } else { request_start = 0 }
	remaining := document.line_count-request_start
	request_lines := min(remaining, bridge.MAX_VISIBLE_LINES)
	if request_lines == 0 { request_lines = 1 }
	request_anchor, long_line_chunk_needed := editor_long_line_next_anchor(
		window,
		visible_start,
		list.scroll.offset_x,
		list.scroll.max_scroll_x,
	)
	if !window_matches { request_anchor = 0 }
	if long_line_chunk_needed && window_matches {
		request_start = window.start_line
		request_lines = 1
	}
	request_source_anchor := view.viewport_anchor_pending && !view.viewport_anchor_resolved && view.viewport_anchor_revision != 0
	if document.line_count > 0 && (!window_covers_view || request_anchor > 0 || metadata_refresh_needed) {
		if metadata_refresh_needed && window_matches && !editor_window_is_long_line_chunk(window) {
			// Request the same source window so a returned parser projection can be
			// rebased through the queued local edits without changing its byte origin.
			request_start = window.start_line
			request_lines = window.end_line-window.start_line
			request_anchor = 0
		}
		request := bridge.Visible_Window_Request{
			document_id=document.id,
			application_rev=app.backend.state.application_rev,
			editor_revision=document.editor_revision,
			start_line=request_start,
			anchor_byte=request_anchor,
			max_lines=request_lines,
			max_bytes=bridge.MAX_VISIBLE_BYTES,
			include_presentation=request_presentation,
			presentation_revision=document.presentation_revision,
			presentation_ready=document.presentation_ready,
			has_source_anchor=request_source_anchor,
			source_anchor_revision=view.viewport_anchor_revision,
			source_anchor_byte=view.viewport_anchor_byte,
			source_anchor_line=view.viewport_anchor_line,
		}
		if !editor_window_request_is_rejected(app, request) {
			generation, accepted, request_error := bridge.visible_window_lane_request(
				&app.visible_window_lane,
				document.id,
				app.backend.state.application_rev,
				document.editor_revision,
				request_start,
				request_lines,
				bridge.MAX_VISIBLE_BYTES,
				request_anchor,
				request_presentation,
				document.presentation_revision,
				document.presentation_ready,
				request_source_anchor,
				view.viewport_anchor_revision,
				view.viewport_anchor_byte,
				view.viewport_anchor_line,
			)
			if accepted {
				app.editor_request_generation = generation
				editor_window_rejection_clear(app)
				if app.editor_window_error != "" { delete(app.editor_window_error, context.allocator) }
				app.editor_window_error = ""
			} else if request_error != "" {
				if app.editor_window_error != "" { delete(app.editor_window_error, context.allocator) }
				app.editor_window_error, _ = strings.clone(request_error, context.allocator)
			}
		}
	}
	if len(app.editor_edits) > 0 && bridge.editor_edit_lane_can_submit(&app.editor_edit_lane) {
		_, _ = editor_dispatch_next_edit(app)
	}
}

build_workspace_tree :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime) {
	if !app.backend.state.has_workspace {
		alicorn.container_begin(ui, .Container, label="workspace-tree-empty", style=alicorn.layout_style(grow=1, padding=12), color=COLOR_SUBTLE)
		alicorn.text(ui, "Open a folder to browse files.")
		alicorn.container_end(ui)
		return
	}
	root_index := tree_directory_index(app, "")
	if root_index < 0 {
		alicorn.container_begin(ui, .Container, label="workspace-tree-loading", style=alicorn.layout_style(grow=1, padding=12), color=COLOR_SUBTLE)
		alicorn.text(ui, "Loading workspace…")
		alicorn.container_end(ui)
		return
	}

	rows := make([dynamic]Tree_Row, 0, allocator=context.temp_allocator)
	defer delete(rows)
	tree_flatten_directory(app, "", 0, &rows)
	list := alicorn.virtual_list_begin(
		ui,
		len(rows),
		TREE_ROW_HEIGHT,
		key=alicorn.key_string(TREE_SCROLL_KEY),
		style=alicorn.layout_style(grow=1, clip=true),
		label="scratchpad-workspace-tree",
		focusable=true,
	)
	app.tree_scroll_owner = list.scroll.id
	focus_state := alicorn.semantic_focus_state(rt)
	for position := list.first; position < list.last; position += 1 {
		row := rows[position]
		indent, _ := strings.repeat("  ", row.depth, context.temp_allocator)
		marker := "   "
		if row.is_dir { marker = ">  "; if row.expanded { marker = "v  " } }
		label := fmt.tprintf("%s%s%s", indent, marker, row.name)
		semantic_id := tree_semantic_id(row.path, row.is_dir)
		selected := focus_state.id == semantic_id
		clicked := alicorn.button(
			ui,
			label,
			key=alicorn.key_string(fmt.tprintf("workspace-entry:%s", row.path)),
			style=alicorn.layout_style(.Row, height=TREE_ROW_HEIGHT),
			state=alicorn.Button_State{selected=selected},
			content_style=alicorn.button_content_style(.Start, padding_x=8),
		)
		_ = alicorn.semantic_bind(ui, semantic_id)
		if clicked { tree_activate_row(app, rt, row) }
	}
	alicorn.virtual_list_end(ui, list)
	if tree_any_truncated(app) {
		alicorn.text(ui, "Some folders show only the first 200 entries.")
	}
}

tree_sync_workspace :: proc(app: ^App, rt: ^alicorn.Runtime = nil) {
	if app == nil || !app.backend.started { return }
	workspace_root := app.backend.state.workspace_root if app.backend.state.has_workspace else ""
	if app.tree_root_path == workspace_root && (workspace_root == "" || tree_directory_index(app, "") >= 0) { return }
	tree_clear_directories(app)
	delete(app.tree_directories)
	app.tree_directories = {}
	if len(app.tree_root_path) > 0 { delete(app.tree_root_path, context.allocator) }
	app.tree_root_path, _ = strings.clone(workspace_root, context.allocator)
	tree_clear_focused_path(app)
	if rt != nil { _ = alicorn.semantic_focus_clear(rt) }
	if workspace_root != "" {
		_ = tree_load_directory(app, "", true)
	}
}

tree_load_directory :: proc(app: ^App, relative_path: string, expanded := true) -> bool {
	if app == nil || !app.backend.started || !app.backend.state.has_workspace { return false }
	if index := tree_directory_index(app, relative_path); index >= 0 {
		app.tree_directories[index].expanded = expanded
		return true
	}
	response := bridge.backend_command(&app.backend, "list_directory", relative_path=relative_path, include_ignored=app.show_ignored_files)
	if !response.ok {
		set_error(app, response.message if response.message != "" else "Could not load this folder.")
		bridge.backend_command_result_destroy(&response, context.allocator)
		return false
	}
	if !response.directory_listing_owned || response.directory_listing.relative_path != relative_path {
		set_error(app, "Scratchpad returned an incomplete directory listing.")
		bridge.backend_command_result_destroy(&response, context.allocator)
		return false
	}
	stored := tree_store_listing(app, response.directory_listing, expanded)
	bridge.backend_command_result_destroy(&response, context.allocator)
	if !stored { set_error(app, "Could not retain this folder listing.") }
	return stored
}

// Changing ignore visibility reloads expanded directories that remain visible
// under the new policy. Expanded subtrees hidden by the toggle keep their last
// listing so they can be restored when ignored entries become visible again.
tree_set_show_ignored_files :: proc(app: ^App, rt: ^alicorn.Runtime, enabled: bool) {
	if app == nil || app.show_ignored_files == enabled { return }
	old_directories := app.tree_directories
	app.tree_directories = make([dynamic]Tree_Directory, 0, allocator=context.allocator)
	app.show_ignored_files = enabled
	_ = tree_load_directory(app, "", true)
	preserved_hidden_paths := make([dynamic]string, 0, allocator=context.temp_allocator)
	defer delete(preserved_hidden_paths)
	for old_directory, old_index in old_directories {
		if !old_directory.expanded || old_directory.path == "" { continue }
		parent_path := tree_parent_relative_path(old_directory.path)
		parent_hidden := tree_path_in_list(preserved_hidden_paths[:], parent_path)
		parent_visible := tree_directory_has_entry(app, parent_path, old_directory.path)
		if parent_hidden || !parent_visible {
			append(&app.tree_directories, old_directory)
			old_directories[old_index] = {}
			append(&preserved_hidden_paths, old_directory.path)
		} else {
			_ = tree_load_directory(app, old_directory.path, true)
		}
	}
	for &directory in old_directories { tree_directory_destroy(&directory) }
	delete(old_directories)
	rows := make([dynamic]Tree_Row, 0, allocator=context.temp_allocator)
	defer delete(rows)
	tree_flatten_directory(app, "", 0, &rows)
	focus_restored := false
	for row, index in rows {
		if row.path == app.tree_focused_path && row.is_dir == app.tree_focused_is_dir {
			tree_set_focused_row(app, rt, row, index)
			focus_restored = true
			break
		}
	}
	if len(app.tree_focused_path) > 0 && !focus_restored {
		tree_clear_focused_path(app)
		_ = alicorn.semantic_focus_clear(rt)
	}
	alicorn.invalidate_root(rt, "Scratchpad ignored-file visibility changed")
}

tree_parent_relative_path :: proc(path: string) -> string {
	last_separator := -1
	for index in 0..<len(path) {
		if path[index] == '/' || path[index] == '\\' { last_separator = index }
	}
	if last_separator < 0 { return "" }
	return path[:last_separator]
}

tree_path_in_list :: proc(paths: []string, target: string) -> bool {
	for path in paths { if path == target { return true } }
	return false
}

tree_directory_has_entry :: proc(app: ^App, directory_path, entry_path: string) -> bool {
	index := tree_directory_index(app, directory_path)
	if index < 0 { return false }
	for entry in app.tree_directories[index].entries {
		if entry.path == entry_path { return true }
	}
	return false
}

tree_store_listing :: proc(app: ^App, listing: bridge.Directory_Listing, expanded: bool) -> bool {
	directory := Tree_Directory{truncated=listing.truncated, expanded=expanded}
	clone_error: mem.Allocator_Error
	directory.path, clone_error = strings.clone(listing.relative_path, context.allocator)
	if clone_error != nil { tree_directory_destroy(&directory); return false }
	directory.entries = make([]bridge.Directory_Entry, len(listing.entries), allocator=context.allocator)
	for entry, i in listing.entries {
		directory.entries[i].name, clone_error = strings.clone(entry.name, context.allocator)
		if clone_error != nil { tree_directory_destroy(&directory); return false }
		directory.entries[i].path, clone_error = strings.clone(entry.path, context.allocator)
		if clone_error != nil { tree_directory_destroy(&directory); return false }
		directory.entries[i].dir = entry.dir
	}
	if index := tree_directory_index(app, listing.relative_path); index >= 0 {
		tree_directory_destroy(&app.tree_directories[index])
		app.tree_directories[index] = directory
	} else {
		append(&app.tree_directories, directory)
	}
	return true
}

tree_clear_directories :: proc(app: ^App) {
	if app == nil { return }
	for &directory in app.tree_directories { tree_directory_destroy(&directory) }
	delete(app.tree_directories)
	app.tree_directories = make([dynamic]Tree_Directory, 0, allocator=context.allocator)
}

tree_directory_destroy :: proc(directory: ^Tree_Directory) {
	if directory == nil { return }
	delete(directory.path, context.allocator)
	for &entry in directory.entries {
		delete(entry.name, context.allocator)
		delete(entry.path, context.allocator)
	}
	delete(directory.entries, context.allocator)
	directory^ = {}
}

tree_clear_focused_path :: proc(app: ^App) {
	if app == nil { return }
	if len(app.tree_focused_path) > 0 { delete(app.tree_focused_path, context.allocator) }
	app.tree_focused_path = ""
	app.tree_focused_is_dir = false
}

tree_directory_index :: proc(app: ^App, path: string) -> int {
	if app == nil { return -1 }
	for directory, index in app.tree_directories {
		if directory.path == path { return index }
	}
	return -1
}

tree_flatten_directory :: proc(app: ^App, path: string, depth: int, rows: ^[dynamic]Tree_Row) {
	if app == nil || rows == nil || depth > 64 { return }
	index := tree_directory_index(app, path)
	if index < 0 { return }
	directory := app.tree_directories[index]
	for entry in directory.entries {
		child_index := tree_directory_index(app, entry.path)
		expanded := entry.dir && child_index >= 0 && app.tree_directories[child_index].expanded
		append(rows, Tree_Row{name=entry.name, path=entry.path, depth=depth, is_dir=entry.dir, expanded=expanded})
		if expanded { tree_flatten_directory(app, entry.path, depth+1, rows) }
	}
}

tree_any_truncated :: proc(app: ^App) -> bool {
	if app == nil { return false }
	for directory in app.tree_directories { if directory.truncated { return true } }
	return false
}

tree_semantic_id :: proc(path: string, is_directory: bool) -> alicorn.Semantic_ID {
	hash: u64 = 14_695_981_039_346_656_037
	hash = (hash ~ (1 if is_directory else 2)) * 1_099_511_628_211
	for character in path { hash = (hash ~ u64(character)) * 1_099_511_628_211 }
	if hash == 0 { hash = 1 }
	return alicorn.Semantic_ID{namespace=TREE_SEMANTIC_NAMESPACE, value=hash}
}

tree_set_focused_row :: proc(app: ^App, rt: ^alicorn.Runtime, row: Tree_Row, index: int) {
	if app == nil || rt == nil { return }
	if len(app.tree_focused_path) > 0 { delete(app.tree_focused_path, context.allocator) }
	app.tree_focused_path, _ = strings.clone(row.path, context.allocator)
	app.tree_focused_is_dir = row.is_dir
	_ = alicorn.focus(rt, app.tree_scroll_owner)
	_ = alicorn.semantic_focus_set(rt, tree_semantic_id(row.path, row.is_dir), app.tree_scroll_owner)
	_ = alicorn.virtual_list_ensure_visible(rt, app.tree_scroll_owner, index, "Scratchpad tree keyboard focus moved")
}

tree_activate_row :: proc(app: ^App, rt: ^alicorn.Runtime, row: Tree_Row) {
	if app == nil || rt == nil { return }
	rows := make([dynamic]Tree_Row, 0, allocator=context.temp_allocator)
	defer delete(rows)
	tree_flatten_directory(app, "", 0, &rows)
	row_index := -1
	for candidate, index in rows {
		if candidate.path == row.path && candidate.is_dir == row.is_dir { row_index = index; break }
	}
	tree_set_focused_row(app, rt, row, row_index)
	if row.is_dir {
		if row.expanded {
			if child_index := tree_directory_index(app, row.path); child_index >= 0 { app.tree_directories[child_index].expanded = false }
		} else {
			_ = tree_load_directory(app, row.path, true)
		}
		alicorn.invalidate_root(rt, "Scratchpad workspace directory toggled")
		return
	}
	absolute_path, path_error := os.join_path({app.tree_root_path, row.path}, context.allocator)
	if path_error != nil {
		set_error(app, "Could not resolve the workspace file path.")
		alicorn.invalidate_root(rt, "Scratchpad workspace path resolution failed")
		return
	}
	if len(app.editor_edits) > 0 {
		queued := deferred_action_enqueue(app, .Open_Path, path=absolute_path, disposition="preview")
		delete(absolute_path, context.allocator)
		if !queued { set_error(app, "Could not queue the file open behind pending edits.") }
		alicorn.invalidate_root(rt, "workspace file open queued behind editor edits")
		return
	}
	response := bridge.backend_command(&app.backend, "open_path", path=absolute_path, disposition="preview")
	delete(absolute_path, context.allocator)
	handle_command_result(app, rt, &response)
	bridge.backend_command_result_destroy(&response, context.allocator)
}

tree_move_focus :: proc(app: ^App, rt: ^alicorn.Runtime, key: host.Application_Key) -> bool {
	rows := make([dynamic]Tree_Row, 0, allocator=context.temp_allocator)
	defer delete(rows)
	tree_flatten_directory(app, "", 0, &rows)
	if len(rows) == 0 { return false }
	current := -1
	for row, index in rows {
		if row.path == app.tree_focused_path && row.is_dir == app.tree_focused_is_dir { current = index; break }
	}
	next := current
	#partial switch key {
	case .Up: next -= 1
	case .Down: next += 1
	case .Page_Up, .Page_Down:
		page := 8
		if metrics := alicorn.scroll_region_state(rt, app.tree_scroll_owner); metrics.viewport_bounds.h > 0 {
			page = max(1, int(metrics.viewport_bounds.h/f32(TREE_ROW_HEIGHT))-1)
		}
		if key == .Page_Up { next -= page } else { next += page }
	case .Home: next = 0
	case .End: next = len(rows)-1
	case: return false
	}
	if next < 0 { next = 0 }
	if next >= len(rows) { next = len(rows)-1 }
	if next == current { return true }
	tree_set_focused_row(app, rt, rows[next], next)
	alicorn.invalidate_root(rt, "Scratchpad workspace tree keyboard navigation")
	return true
}

tree_activate_focused :: proc(app: ^App, rt: ^alicorn.Runtime) -> bool {
	rows := make([dynamic]Tree_Row, 0, allocator=context.temp_allocator)
	defer delete(rows)
	tree_flatten_directory(app, "", 0, &rows)
	for row in rows {
		if row.path == app.tree_focused_path && row.is_dir == app.tree_focused_is_dir {
			tree_activate_row(app, rt, row)
			return true
		}
	}
	return false
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
	_, viewport_height := editor_wrap_viewport_size(rt, view, scroll)
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
								editor_wrap_heights_reset(view, int(active.line_count))
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

application_dialog :: proc(state: rawptr, rt: ^alicorn.Runtime, result: ^host.File_Dialog_Result) {
	app := cast(^App)state
	if result == nil { return }
	if result.status == .Error {
		app.dialog_action = ""
		clear_dialog_document(app)
		set_error(app, result.error)
		alicorn.invalidate_root(rt, "Scratchpad native dialog failed")
		deferred_actions_run(app, rt)
		return
	}
	if result.status != .Accepted || len(result.paths) == 0 {
		app.dialog_action = ""
		clear_dialog_document(app)
		deferred_actions_run(app, rt)
		return
	}
	path := result.paths[0]
	if app.dialog_action == ACTION_FILE_SAVE_AS {
		if len(app.editor_edits) > 0 {
			if !deferred_action_enqueue(app, .Save_As_Path, value=app.dialog_document_id, path=path) {
				set_error(app, "Could not queue the selected Save As destination behind pending edits.")
			}
		} else {
			save_as_to_path(app, rt, app.dialog_document_id, path)
		}
		app.dialog_action = ""
		clear_dialog_document(app)
		deferred_actions_run(app, rt)
		return
	}
	if len(app.editor_edits) > 0 {
		if !deferred_action_enqueue(app, .Open_Path, path=path) {
			set_error(app, "Could not queue the selected file behind pending edits.")
		}
	} else {
		open_path, clone_error := strings.clone(path, context.allocator)
		if clone_error != nil {
			set_error(app, "Could not retain the selected file path.")
			alicorn.invalidate_root(rt, "Scratchpad could not retain selected dialog path")
		} else {
			open_path_from_dialog(app, rt, open_path)
		}
	}
	app.dialog_action = ""
	clear_dialog_document(app)
	deferred_actions_run(app, rt)
}

clear_dialog_document :: proc(app: ^App) {
	if app == nil { return }
	if len(app.dialog_document_id) > 0 { delete(app.dialog_document_id, context.allocator) }
	app.dialog_document_id = ""
}

save_as_to_path :: proc(app: ^App, rt: ^alicorn.Runtime, document_id, path: string) {
	if app == nil || rt == nil || !app.backend.started || document_id == "" || path == "" { return }
	response := bridge.backend_command(&app.backend, "save_as_document", document_id=document_id, path=path)
	if !response.ok && response.code == "save_as_destination_exists" && response.save_as_conflict.token != 0 {
		save_as_confirmation_clear(app)
		app.save_as_confirmation_document_id, _ = strings.clone(document_id, context.allocator)
		app.save_as_confirmation_path, _ = strings.clone(response.save_as_conflict.path, context.allocator)
		if app.save_as_confirmation_document_id != "" && app.save_as_confirmation_path != "" {
			app.save_as_confirmation_token = response.save_as_conflict.token
			app.save_as_confirmation_open = true
			set_error(app, "")
		} else {
			save_as_confirmation_clear(app)
			set_error(app, "Could not retain the Save As overwrite confirmation.")
		}
		alicorn.invalidate_root(rt, "Scratchpad requested Save As overwrite confirmation")
	} else {
		if response.ok { editor_migrate_after_save_as(app, rt, document_id) }
		handle_command_result(app, rt, &response)
	}
	bridge.backend_command_result_destroy(&response, context.allocator)
}

save_as_confirm_overwrite :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil || !app.save_as_confirmation_open || app.save_as_confirmation_token == 0 { return }
	response := bridge.backend_command(
		&app.backend, "confirm_save_as",
		document_id=app.save_as_confirmation_document_id,
		save_as_token=app.save_as_confirmation_token,
	)
	if response.ok { editor_migrate_after_save_as(app, rt, app.save_as_confirmation_document_id) }
	save_as_confirmation_clear(app)
	handle_command_result(app, rt, &response)
	bridge.backend_command_result_destroy(&response, context.allocator)
	deferred_actions_run(app, rt)
}

save_as_cancel_overwrite :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil || !app.save_as_confirmation_open { return }
	response := bridge.backend_command(
		&app.backend, "cancel_save_as",
		document_id=app.save_as_confirmation_document_id,
		save_as_token=app.save_as_confirmation_token,
		read_latest_after=false,
	)
	bridge.backend_command_result_destroy(&response, context.allocator)
	save_as_confirmation_clear(app)
	deferred_actions_run(app, rt)
	alicorn.invalidate_root(rt, "Scratchpad cancelled Save As overwrite")
}

save_as_confirmation_clear :: proc(app: ^App) {
	if app == nil { return }
	if len(app.save_as_confirmation_document_id) > 0 { delete(app.save_as_confirmation_document_id, context.allocator) }
	if len(app.save_as_confirmation_path) > 0 { delete(app.save_as_confirmation_path, context.allocator) }
	app.save_as_confirmation_document_id = ""
	app.save_as_confirmation_path = ""
	app.save_as_confirmation_token = 0
	app.save_as_confirmation_open = false
}

editor_migrate_after_save_as :: proc(app: ^App, rt: ^alicorn.Runtime, old_id: string) {
	if app == nil || old_id == "" { return }
	new_id := app.backend.state.active
	if new_id == "" || new_id == old_id { return }
	if index := editor_view_find(app.editor_views[:], old_id); index >= 0 {
		copy, err := strings.clone(new_id, context.allocator)
		if err == nil {
			delete(app.editor_views[index].document_id, context.allocator)
			app.editor_views[index].document_id = copy
		}
	}
	if app.editor_presented_document_id == old_id {
		copy, err := strings.clone(new_id, context.allocator)
		if err == nil {
			delete(app.editor_presented_document_id, context.allocator)
			app.editor_presented_document_id = copy
		}
	}
	if app.editor_window_ready && app.editor_window.document_id == old_id {
		editor_window_destroy(&app.editor_window)
		app.editor_window_ready = false
		app.editor_request_generation += 1
		editor_window_rejection_clear(app)
		if rt != nil { alicorn.invalidate_root(rt, "Scratchpad reloaded editor projection after Save As identity change") }
	}
}

open_path_from_dialog :: proc(app: ^App, rt: ^alicorn.Runtime, path: string) {
	defer delete(path, context.allocator)
	if action, found := find_action(&app.backend.state, app.dialog_action); found {
		cause := alicorn.cause_begin(rt, .Application, "native file dialog selection", action_id_for(action.id))
		alicorn.trace_action(rt, action_id_for(action.id), action.title)
		response := bridge.backend_command(&app.backend, "open_path", path=path)
		handle_command_result(app, rt, &response)
		bridge.backend_command_result_destroy(&response, context.allocator)
		alicorn.cause_end(rt, cause)
	} else {
		set_error(app, "The file dialog completed without a matching Scratchpad action.")
		alicorn.invalidate_root(rt, "Scratchpad dialog action was unavailable")
	}
}

application_menu_command :: proc(state: rawptr, rt: ^alicorn.Runtime, command: host.Application_Command_ID) {
	app := cast(^App)state
	if command == action_id_for(ACTION_VIEW_COMMAND_PALETTE) { command_palette_open_surface(app, rt); return }
	if command == action_id_for(ACTION_DOCUMENT_GO_TO_LINE) { go_to_line_open_surface(app, rt); return }
	if command == action_id_for(ACTION_DOCUMENT_TOGGLE_WRAP) { editor_toggle_wrap_mode(app, rt); return }
	if command == action_id_for(ACTION_WORKSPACE_NEW_FILE) { dispatch_action(app, rt, ACTION_WORKSPACE_NEW_FILE); return }
	if command == action_id_for(ACTION_WORKSPACE_NEW_FOLDER) { dispatch_action(app, rt, ACTION_WORKSPACE_NEW_FOLDER); return }
	if command == action_id_for(ACTION_WORKSPACE_SETTINGS) { dispatch_action(app, rt, ACTION_WORKSPACE_SETTINGS); return }
	if command == action_id_for(ACTION_EDIT_CUT) { editor_clipboard_command(app, rt, ACTION_EDIT_CUT); return }
	if command == action_id_for(ACTION_EDIT_COPY) { editor_clipboard_command(app, rt, ACTION_EDIT_COPY); return }
	if command == action_id_for(ACTION_EDIT_PASTE) { editor_clipboard_command(app, rt, ACTION_EDIT_PASTE); return }
	if command == action_id_for(ACTION_EDIT_SELECT_ALL) { editor_clipboard_command(app, rt, ACTION_EDIT_SELECT_ALL); return }
	for action in app.backend.state.actions {
		if action_id_for(action.id) == command {
			dispatch_action(app, rt, action.id)
			return
		}
	}
}

editor_toggle_wrap_mode :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil || !app.backend.started { return }
	document, found := find_document(&app.backend.state, app.backend.state.active)
	if !found { return }
	view_index, view_ok := editor_view_ensure(&app.editor_views, document.id)
	if !view_ok { set_error(app, "Could not retain this document's wrap preference."); return }
	view := &app.editor_views[view_index]
	switch view.wrap_mode {
	case .Auto: view.wrap_mode = .On
	case .On: view.wrap_mode = .Off
	case .Off: view.wrap_mode = .Auto
	}
	view.wrap_measurement_width = -1
	alicorn.invalidate_root(rt, "Scratchpad per-document word-wrap preference changed")
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
	if app.editor_scroll_owner != 0 {
		_ = editor_ensure_line_visible(rt, view, app.editor_scroll_owner, int(target_line), "Scratchpad Go to Line navigated to the requested logical row")
	}
	app.go_to_line_open = false
	app.go_to_line_query_node = 0
	app.go_to_line_focus_pending = false
	app.editor_focus_pending = true
	alicorn.invalidate_root(rt, "Scratchpad Go to Line requested its bounded source window")
	return true
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

editor_resolve_conflict :: proc(app: ^App, rt: ^alicorn.Runtime, document_id: string, keep_mine: bool) {
	if app == nil || rt == nil || document_id == "" { return }
	if len(app.editor_edits) > 0 {
		kind := Deferred_Action_Kind.Conflict_Reload
		if keep_mine { kind = .Conflict_Keep_Mine }
		if !deferred_action_enqueue(app, kind, value=document_id) {
			set_error(app, "Could not queue conflict resolution behind pending edits.")
		}
		alicorn.invalidate_root(rt, "Scratchpad conflict resolution queued behind pending edits")
		return
	}
	editor_resolve_conflict_now(app, rt, document_id, keep_mine)
}

editor_resolve_conflict_now :: proc(app: ^App, rt: ^alicorn.Runtime, document_id: string, keep_mine: bool) {
	command := "reload_conflict"
	if keep_mine { command = "keep_mine_conflict" }
	response := bridge.backend_command(&app.backend, command, document_id=document_id)
	handle_command_result(app, rt, &response)
	bridge.backend_command_result_destroy(&response, context.allocator)
	deferred_actions_run(app, rt)
}

build_document_status :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime, document: bridge.State_Document) {
	if app == nil || ui == nil { return }
	view_index, view_ok := editor_view_ensure(&app.editor_views, document.id)
	if !view_ok { return }
	view := &app.editor_views[view_index]
	window, _ := editor_presentation_window(view, &app.editor_window, app.editor_window_ready, document.id, document.editor_revision)
	line_count := document.line_count
	if view.optimistic_pending_edits > 0 {
		if view.optimistic_line_delta < 0 {
			removed := u64(-view.optimistic_line_delta)
			line_count = line_count-removed if removed < line_count else 1
		} else { line_count += u64(view.optimistic_line_delta) }
	}
	location := "Ln —  Col —"
	if view.pending_goto_line {
		location = fmt.tprintf("Ln %d  Col %d", view.pending_goto_target_line+1, view.pending_goto_column)
	} else if line, found := editor_line_for_source(window, view.caret_byte); found {
		column := u64(1)
		position := line.source_start
		for position < min(view.caret_byte, line.source_end) {
			next, _, moved := editor_move_horizontal(line, position, .Leading, 1)
			if !moved || next <= position { break }
			position = next
			column += 1
		}
		location = fmt.tprintf("Ln %d  Col %d", line.logical_line+1, column)
		if editor_window_is_long_line_chunk(window) { location = fmt.tprintf("%s  (chunk)", location) }
	}
	modified := ""
	if document.dirty || view.optimistic_pending_edits > 0 { modified = "  • Modified" }
	wrap_label := "Auto"
	switch view.wrap_mode {
	case .On: wrap_label = "On"
	case .Off: wrap_label = "Off"
	case .Auto: wrap_label = "Auto"
	}
	alicorn.container_begin(ui, .Container, label="document-status-bar", key=alicorn.key_string(fmt.tprintf("document-status:%s", document.id)), style=alicorn.layout_style(.Row, height=28, gap=14, padding=8, align=.Center), color=COLOR_SUBTLE)
	alicorn.text(ui, fmt.tprintf("%s%s  ·  %s  ·  %d lines", location, modified, document.language, line_count))
	if alicorn.button(ui, fmt.tprintf("Wrap: %s", wrap_label), key=alicorn.key_string(fmt.tprintf("document-wrap:%s", document.id)), style=alicorn.layout_style(.Row, width=96, height=24)) {
		editor_toggle_wrap_mode(app, rt)
	}
	if alicorn.button(ui, "Go to Line…", key=alicorn.key_string(fmt.tprintf("document-goto:%s", document.id)), style=alicorn.layout_style(.Row, width=106, height=24)) {
		go_to_line_open_surface(app, rt)
	}
	alicorn.container_end(ui)
}

dispatch_action :: proc(app: ^App, rt: ^alicorn.Runtime, action_id: string) {
	if app == nil || !app.backend.started { return }
	if action_id == ACTION_FILE_QUICK_OPEN {
		quick_open_open_surface(app, rt)
		return
	}
	if action_id == ACTION_EDIT_PASTE {
		editor_clipboard_command(app, rt, action_id)
		return
	}
	switch action_id {
	case ACTION_WORKSPACE_NEW_FILE:
		workspace_mutation_open_create(app, rt, .Create_File)
		return
	case ACTION_WORKSPACE_NEW_FOLDER:
		workspace_mutation_open_create(app, rt, .Create_Folder)
		return
	case ACTION_WORKSPACE_SETTINGS:
		app.settings_surface_open = true
		alicorn.invalidate_root(rt, "Scratchpad Settings opened")
		return
	}
	if editor_active_preedit(app) && (action_id == ACTION_EDIT_UNDO || action_id == ACTION_EDIT_REDO) {
		set_error(app, "Finish or cancel the active text composition before using Undo or Redo.")
		alicorn.invalidate_root(rt, "Scratchpad history command refused during IME composition")
		return
	}
	if len(app.editor_edits) > 0 && (action_id == ACTION_EDIT_UNDO || action_id == ACTION_EDIT_REDO) {
		// The current published action state can still say disabled while a
		// local edit is waiting for acknowledgement. Queue history navigation
		// behind that edit so the refreshed state decides whether it is enabled.
		if !deferred_action_enqueue(app, .Action, value=action_id) {
			set_error(app, "Could not queue Undo/Redo behind pending editor edits.")
		}
		alicorn.invalidate_root(rt, "Scratchpad history action queued behind pending editor edits")
		return
	}
	entry, found := find_action(&app.backend.state, action_id)
	if !found || !entry.visible { return }
	markdown_selection_command := action_id == ACTION_DOCUMENT_FORMAT ||
	                     action_id == ACTION_ITEM_TOGGLE ||
	                     action_id == ACTION_MARKDOWN_TOGGLE_STRONG ||
	                     action_id == ACTION_MARKDOWN_TOGGLE_EMPHASIS ||
	                     action_id == ACTION_MARKDOWN_TOGGLE_STRIKE ||
	                     action_id == ACTION_MARKDOWN_TOGGLE_INLINE_CODE ||
	                     action_id == ACTION_MARKDOWN_INSERT_LINK ||
	                     action_id == ACTION_MARKDOWN_HEADING_1 ||
	                     action_id == ACTION_MARKDOWN_HEADING_2 ||
	                     action_id == ACTION_MARKDOWN_HEADING_3 ||
	                     action_id == ACTION_MARKDOWN_TOGGLE_BULLETED_LIST ||
	                     action_id == ACTION_MARKDOWN_TOGGLE_NUMBERED_LIST ||
	                     action_id == ACTION_MARKDOWN_TOGGLE_QUOTE ||
	                     action_id == ACTION_MARKDOWN_INSERT_TASK ||
	                     action_id == ACTION_MARKDOWN_INSERT_CODE_BLOCK ||
	                     action_id == ACTION_MARKDOWN_SET_FENCE_LANGUAGE ||
	                     action_id == ACTION_MARKDOWN_INSERT_TABLE ||
	                     action_id == ACTION_MARKDOWN_INSERT_DIVIDER ||
	                     action_id == ACTION_MARKDOWN_TABLE_NEXT ||
	                     action_id == ACTION_MARKDOWN_TABLE_PREVIOUS ||
	                     action_id == ACTION_MARKDOWN_TABLE_ENTER
	if markdown_selection_command {
		document, document_found := find_document(&app.backend.state, app.backend.state.active)
		if !document_found || document.language != "markdown" { return }
	} else if !entry.enabled {
		return
	}
	if len(app.editor_edits) > 0 {
		if !deferred_action_enqueue(app, .Action, value=action_id) {
			set_error(app, "Could not queue the command behind pending editor edits.")
		}
		alicorn.invalidate_root(rt, "Scratchpad command queued behind editor edits")
		return
	}
	if document, found := find_document(&app.backend.state, app.backend.state.active); found {
		if view_index := editor_view_find(app.editor_views[:], document.id); view_index >= 0 {
			editor_undo_group_break(&app.editor_views[view_index])
		}
	}
	command_token := action_id_for(action_id)
	cause := alicorn.cause_begin(rt, .Application, "Scratchpad semantic action", command_token)
	alicorn.trace_action(rt, command_token, entry.title)
	switch action_id {
	case ACTION_FILE_OPEN:
		request_file_dialog(app, rt, .Open_File, "Open File")
	case ACTION_FILE_SAVE_AS:
		if app.backend.state.active != "" {
			request_file_dialog(app, rt, .Save_File, "Save As")
		}
	case ACTION_WORKSPACE_OPEN:
		request_file_dialog(app, rt, .Open_Folder, "Open Folder")
	case ACTION_FILE_SAVE:
		if app.backend.state.active != "" {
			response := bridge.backend_command(&app.backend, "save_document", document_id=app.backend.state.active)
			handle_command_result(app, rt, &response)
			bridge.backend_command_result_destroy(&response, context.allocator)
		}
	case ACTION_EDIT_UNDO, ACTION_EDIT_REDO:
		previous_editor_revision: u64 = 0
		if document, found := find_document(&app.backend.state, app.backend.state.active); found {
			previous_editor_revision = document.editor_revision
		}
		response := bridge.backend_command(&app.backend, action_id, document_id=app.backend.state.active)
		handle_command_result(app, rt, &response)
		if response.ok && response.editor_selection.editor_revision != 0 &&
		   response.editor_selection.editor_revision != previous_editor_revision {
			if view_index := editor_view_find(app.editor_views[:], response.editor_selection.document_id); view_index >= 0 {
				view := &app.editor_views[view_index]
				view.viewport_anchor_skip_next_source_change = true
				view.viewport_anchor_pending = false
				view.viewport_anchor_resolved = false
			}
		}
		if response.ok && response.editor_selection.document_id != "" {
			editor_apply_backend_selection(app, rt, response.editor_selection)
		}
		bridge.backend_command_result_destroy(&response, context.allocator)
	case ACTION_DOCUMENT_FORMAT, ACTION_MARKDOWN_TOGGLE_STRONG, ACTION_MARKDOWN_TOGGLE_EMPHASIS,
		 ACTION_MARKDOWN_TOGGLE_STRIKE, ACTION_MARKDOWN_TOGGLE_INLINE_CODE, ACTION_MARKDOWN_INSERT_LINK,
		 ACTION_MARKDOWN_HEADING_1, ACTION_MARKDOWN_HEADING_2, ACTION_MARKDOWN_HEADING_3,
		 ACTION_MARKDOWN_TOGGLE_BULLETED_LIST, ACTION_MARKDOWN_TOGGLE_NUMBERED_LIST, ACTION_MARKDOWN_TOGGLE_QUOTE,
		 ACTION_MARKDOWN_INSERT_TASK, ACTION_MARKDOWN_INSERT_CODE_BLOCK, ACTION_MARKDOWN_SET_FENCE_LANGUAGE,
		 ACTION_MARKDOWN_INSERT_TABLE, ACTION_MARKDOWN_INSERT_DIVIDER, ACTION_MARKDOWN_SMART_PASTE,
		 ACTION_EDIT_DELETE_LINE,
		 ACTION_EDIT_INDENT_LINES, ACTION_EDIT_OUTDENT_LINES, ACTION_EDIT_INSERT_LINE_ABOVE,
		 ACTION_EDIT_INSERT_LINE_BELOW, ACTION_EDIT_MOVE_LINE_UP, ACTION_EDIT_MOVE_LINE_DOWN,
		 ACTION_EDIT_DUPLICATE_LINE, ACTION_EDIT_JOIN_LINES, ACTION_COMMENT_TOGGLE,
		 ACTION_MARKDOWN_TABLE_NEXT, ACTION_MARKDOWN_TABLE_PREVIOUS, ACTION_MARKDOWN_TABLE_ENTER:
		document, found := find_document(&app.backend.state, app.backend.state.active)
		if !found { break }
		view_index, view_ok := editor_view_ensure(&app.editor_views, document.id)
		if !view_ok {
			set_error(app, "Could not retain the active editor selection for the command.")
			break
		}
		view := &app.editor_views[view_index]
		clipboard_text := ""
		if action_id == ACTION_MARKDOWN_SMART_PASTE {
			text, clipboard_ok := host.ClipboardGetText(app.services.clipboard, allocator=context.allocator)
			if !clipboard_ok {
				set_error(app, "Could not read text from the system clipboard.")
				alicorn.invalidate_root(rt, "Scratchpad smart paste clipboard read failed")
				break
			}
			defer delete(text, context.allocator)
			if len(text) > int(bridge.MAX_EDIT_BYTES) {
				set_error(app, "Clipboard text exceeds the 128 KiB per-edit limit.")
				alicorn.invalidate_root(rt, "Scratchpad rejected oversized Markdown smart paste")
				break
			}
			clipboard_text = string(text)
		}
		response := bridge.backend_command(
			&app.backend,
			"execute_command",
			action_id=action_id,
			argument=clipboard_text,
			document_id=document.id,
			editor_revision=document.editor_revision,
			editor_anchor_byte=view.selection_anchor,
			editor_cursor_byte=view.caret_byte,
		)
		handle_command_result(app, rt, &response)
		if action_id == ACTION_DOCUMENT_FORMAT && response.ok &&
		   response.editor_selection.editor_revision != 0 && response.editor_selection.editor_revision != document.editor_revision {
			view.viewport_anchor_skip_next_source_change = true
			view.viewport_anchor_pending = false
			view.viewport_anchor_resolved = false
		}
		if action_id == ACTION_DOCUMENT_FORMAT && response.ok && response.command_outcome == "no_op" {
			set_error(app, "Table is already aligned.")
			alicorn.invalidate_root(rt, "Scratchpad reported an unchanged table format")
		}
		if response.ok && response.editor_selection.document_id != "" {
			selection_only := response.command_outcome == "selection_only"
			editor_apply_backend_selection(app, rt, response.editor_selection, selection_only)
		}
		bridge.backend_command_result_destroy(&response, context.allocator)
	case ACTION_DOCUMENT_CLOSE:
		request_close_document(app, rt, app.backend.state.active)
	case ACTION_TAB_NEXT:
		navigate_tab(app, rt, 1)
	case ACTION_TAB_PREVIOUS:
		navigate_tab(app, rt, -1)
	case ACTION_WORKSPACE_REFRESH:
		response := bridge.backend_command(&app.backend, "refresh_workspace", include_ignored=app.show_ignored_files)
		if response.ok {
			quick_open_invalidate_index(app)
			tree_clear_directories(app)
			if response.directory_listing_owned {
				if !tree_store_listing(app, response.directory_listing, true) { set_error(app, "Could not retain the refreshed workspace listing.") }
			} else {
				set_error(app, "Scratchpad did not return the refreshed workspace listing.")
			}
			sync_runtime_actions(app, rt)
			sync_menu_states(app)
			alicorn.invalidate_root(rt, "Scratchpad workspace refreshed")
		} else {
			handle_command_result(app, rt, &response)
		}
		bridge.backend_command_result_destroy(&response, context.allocator)
	case:
		set_error(app, fmt.tprintf("Action %s is not available in the Alicorn shell yet", action_id))
		alicorn.invalidate_root(rt, "unavailable Scratchpad action")
	}
	alicorn.cause_end(rt, cause)
}

deferred_action_enqueue :: proc(
	app: ^App,
	kind: Deferred_Action_Kind,
	value: string = "",
	path: string = "",
	disposition: string = "",
	relative_path: string = "",
	name: string = "",
	workspace_mutation_kind: Workspace_Mutation_Kind = .None,
	source_is_dir := false,
	discard := false,
	workspace_root := "",
) -> bool {
	if app == nil || len(app.deferred_actions) >= MAX_DEFERRED_ACTIONS { return false }
	action := Deferred_Action{kind=kind}
	if len(value) > 0 {
		value_copy, err := strings.clone(value, context.allocator)
		if err != nil { deferred_action_destroy(&action); return false }
		action.value = value_copy
	}
	if len(path) > 0 {
		path_copy, err := strings.clone(path, context.allocator)
		if err != nil { deferred_action_destroy(&action); return false }
		action.path = path_copy
	}
	if len(relative_path) > 0 {
		path_copy, err := strings.clone(relative_path, context.allocator)
		if err != nil { deferred_action_destroy(&action); return false }
		action.relative_path = path_copy
	}
	if len(name) > 0 {
		name_copy, err := strings.clone(name, context.allocator)
		if err != nil { deferred_action_destroy(&action); return false }
		action.name = name_copy
	}
	if len(workspace_root) > 0 {
		root_copy, err := strings.clone(workspace_root, context.allocator)
		if err != nil { deferred_action_destroy(&action); return false }
		action.workspace_root = root_copy
	}
	action.workspace_mutation_kind = workspace_mutation_kind
	action.source_is_dir = source_is_dir
	action.discard = discard
	if len(disposition) > 0 {
		disposition_copy, err := strings.clone(disposition, context.allocator)
		if err != nil { deferred_action_destroy(&action); return false }
		action.disposition = disposition_copy
	}
	append(&app.deferred_actions, action)
	return true
}

deferred_action_destroy :: proc(action: ^Deferred_Action) {
	if action == nil { return }
	if len(action.value) > 0 { delete(action.value, context.allocator) }
	if len(action.path) > 0 { delete(action.path, context.allocator) }
	if len(action.relative_path) > 0 { delete(action.relative_path, context.allocator) }
	if len(action.name) > 0 { delete(action.name, context.allocator) }
	if len(action.disposition) > 0 { delete(action.disposition, context.allocator) }
	if len(action.workspace_root) > 0 { delete(action.workspace_root, context.allocator) }
	action^ = Deferred_Action{}
}

frame_deferred_action_schedule :: proc(app: ^App, kind: Deferred_Action_Kind, value: string = "") -> bool {
	if app == nil || app.frame_deferred_action_pending { return false }
	action := Deferred_Action{kind=kind}
	if len(value) > 0 {
		value_copy, err := strings.clone(value, context.allocator)
		if err != nil { return false }
		action.value = value_copy
	}
	app.frame_deferred_action = action
	app.frame_deferred_action_pending = true
	return true
}

frame_deferred_action_run :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || !app.frame_deferred_action_pending { return }
	action := app.frame_deferred_action
	app.frame_deferred_action = Deferred_Action{}
	app.frame_deferred_action_pending = false
	#partial switch action.kind {
	case .Select_Document:
		select_document(app, rt, action.value)
	case .Close_Document:
		request_close_document(app, rt, action.value)
	case .Open_Path:
		quick_open_open_path(app, rt, action.value)
	case .Save_As_Path:
		save_as_to_path(app, rt, action.value, action.path)
	case .Close_After_Save:
		close_after_save(app, rt)
	case .Close_With_Discard:
		close_with_discard(app, rt)
	case .Cancel_Close_Prompt:
		clear_close_prompt(app)
		deferred_actions_run(app, rt)
		alicorn.invalidate_root(rt, "dirty close cancelled")
		case .Action:
			application_menu_command(rawptr(app), rt, action_id_for(action.value))
	case:
		set_error(app, "Scratchpad received an unsupported deferred frame action.")
		alicorn.invalidate_root(rt, "Scratchpad rejected an unsupported deferred frame action")
	}
	deferred_action_destroy(&action)
}

deferred_actions_clear :: proc(app: ^App) {
	if app == nil { return }
	for index := len(app.deferred_actions)-1; index >= 0; index -= 1 {
		deferred_action_destroy(&app.deferred_actions[index])
	}
	clear(&app.deferred_actions)
}

deferred_actions_run :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil || !app.backend.started || len(app.editor_edits) > 0 || app.dialog_action != "" || app.save_as_confirmation_open {
		return
	}
	if app.close_document_id != "" {
		// A close decision owns the modal until Save & Close or Discard is
		// chosen. Let that decision pass queued work so it cannot deadlock
		// behind actions that the modal itself prevents from running.
		close_action_index := -1
		for action, index in app.deferred_actions {
			if action.kind == .Close_After_Save || action.kind == .Close_With_Discard {
				close_action_index = index
				break
			}
		}
		if close_action_index < 0 { return }
		if close_action_index > 0 {
			close_action := app.deferred_actions[close_action_index]
			for index := close_action_index; index > 0; index -= 1 {
				app.deferred_actions[index] = app.deferred_actions[index-1]
			}
			app.deferred_actions[0] = close_action
		}
	}
	for len(app.deferred_actions) > 0 {
		action := app.deferred_actions[0]
		ordered_remove(&app.deferred_actions, 0)
		switch action.kind {
		case .Action:
			dispatch_action(app, rt, action.value)
		case .Select_Document:
			select_document(app, rt, action.value)
		case .Close_Document:
			request_close_document(app, rt, action.value)
		case .Open_Path:
			if action.disposition != "" {
				response := bridge.backend_command(&app.backend, "open_path", path=action.path, disposition=action.disposition)
				handle_command_result(app, rt, &response)
				bridge.backend_command_result_destroy(&response, context.allocator)
			} else {
				response := bridge.backend_command(&app.backend, "open_path", path=action.path)
				handle_command_result(app, rt, &response)
				bridge.backend_command_result_destroy(&response, context.allocator)
			}
		case .Save_As_Path:
			save_as_to_path(app, rt, action.value, action.path)
		case .Conflict_Reload:
			editor_resolve_conflict_now(app, rt, action.value, false)
		case .Conflict_Keep_Mine:
			editor_resolve_conflict_now(app, rt, action.value, true)
		case .Workspace_Mutation:
			app.workspace_mutation_queued = false
			workspace_mutation_execute(
				app,
				rt,
				action.workspace_mutation_kind,
				action.path,
				action.name,
				action.relative_path,
				action.source_is_dir,
				action.discard,
				action.workspace_root,
			)
		case .Close_After_Save:
			close_after_save(app, rt)
		case .Close_With_Discard:
			close_with_discard(app, rt)
		case .Cancel_Close_Prompt:
			clear_close_prompt(app)
			alicorn.invalidate_root(rt, "dirty close cancelled")
		}
		deferred_action_destroy(&action)
		if app.dialog_action != "" || app.close_document_id != "" || app.save_as_confirmation_open || app.workspace_mutation_kind != .None { break }
	}
}

request_file_dialog :: proc(app: ^App, rt: ^alicorn.Runtime, kind: host.File_Dialog_Kind, title: string) {
	app.dialog_sequence += 1
	app.dialog_action = ACTION_WORKSPACE_OPEN
	if kind == .Open_File { app.dialog_action = ACTION_FILE_OPEN }
	if kind == .Save_File {
		app.dialog_action = ACTION_FILE_SAVE_AS
		clear_dialog_document(app)
		copy, clone_error := strings.clone(app.backend.state.active, context.allocator)
		if clone_error != nil {
			app.dialog_action = ""
			set_error(app, "Could not retain the active document for Save As.")
			alicorn.invalidate_root(rt, "Scratchpad could not retain the Save As document identity")
			return
		}
		app.dialog_document_id = copy
	}
	request := host.File_Dialog_Request{
		id=host.Dialog_ID(app.dialog_sequence),
		kind=kind,
		title=title,
		initial_location=app.backend.state.workspace_root,
		allow_many=false,
	}
	if !host.ShowFileDialog(app.services.dialogs, request) {
		app.dialog_action = ""
		clear_dialog_document(app)
		set_error(app, "The native file dialog could not be opened.")
		alicorn.invalidate_root(rt, "Scratchpad native dialog request failed")
		deferred_actions_run(app, rt)
	}
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
	if key == .Open_Command_Palette {
		command_palette_open_surface(app, rt)
		return true
	}
	if key == .Context_Menu {
		return workspace_context_menu_open_focused(app, rt)
	}
	if key == .Workspace_Rename {
		if app.tree_scroll_owner != 0 && rt.focused == app.tree_scroll_owner && app.tree_focused_path != "" {
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
	if app.workspace_search_mode && rt.focused == app.workspace_search_query_node {
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
	if key == .Return && app.find_open && rt.focused == app.find_query_node {
		return find_move_match(app, rt, 1)
	}
	if key == .Return && app.find_open && rt.focused == app.find_replace_node {
		return find_replace_current(app, rt)
	}
	if key == .Return && app.workspace_search_mode && rt.focused == app.workspace_search_query_node {
		if len(app.workspace_search_view.results) > 0 {
			index := app.workspace_search_selected
			if index < 0 || index >= len(app.workspace_search_view.results) { index = 0 }
			return workspace_search_activate_result(app, rt, index)
		}
		if !app.workspace_search_view.done { workspace_search_start_query(app, rt) }
		return true
	}
	if key == .Return && app.editor_scroll_owner != 0 && rt.focused == app.editor_scroll_owner {
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
	if app.tree_scroll_owner != 0 && rt.focused == app.tree_scroll_owner {
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
	owner, owner_found := rt.nodes[app.editor_scroll_owner]
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
		row_node, row_found := rt.nodes[row_target.node]
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
	if best_distance == 1e30 || (!clamp_to_viewport && best_distance > EDITOR_ROW_HEIGHT) { return }
	best_target: Editor_Row_Target
	best_x_distance := f32(1e30)
	best_hit_x := hit_x
	for target in app.editor_row_targets {
		if target.logical_line != best_line { continue }
		node, node_found := rt.nodes[target.node]
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
	owner, found := rt.nodes[owner_id]
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
		if owner, found := rt.nodes[app.editor_scroll_owner]; found {
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
		if captured, found := rt.nodes[rt.captured_node]; found && captured.kind == .Split_Handle {
			if owner, owner_found := rt.nodes[captured.split_owner]; owner_found && owner.label == "scratchpad-workspace-editor-split" {
				// Alicorn marks retained layout dirty immediately, but Scratchpad's
				// sparse wrapped-row heights are application-owned and must be
				// remeasured for the new editor width. That measurement visits only
				// the bounded visible source window.
				alicorn.invalidate_root(rt, "Scratchpad editor width changed during split resize")
				return
			}
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
				if view.dragging_selection && rt.captured_node == app.editor_scroll_owner {
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
			owner_node, owner_found := rt.nodes[owner]
			gutter_width := editor_line_number_gutter_width(document.line_count)
			wrap_width := f32(0)
			if owner_found { wrap_width = max(owner_node.scroll_viewport_width-gutter_width-16, 80) }
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
				current_node, old_caret, old_affinity, true, view.wrap_mode,
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
						step = u64(max(int(owner_node.scroll_viewport_height/EDITOR_ROW_HEIGHT)-1, 1))
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
			if editor_table_line_is_projected(window, target) && editor_table_line_fit(window, target, wrap_width) {
				target_layout := editor_table_row_layout(window, target, wrap_width)
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
						target_node, 0, .Leading, false, view.wrap_mode,
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
				target_node, target_visual_x, target_visual_y, mapped_visual_row, view.wrap_mode,
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
				if owner_node, owner_found := rt.nodes[owner]; owner_found {
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
	if !window_matches {
		set_error(app, "The bounded source window is not ready for local editing.")
		alicorn.invalidate_root(rt, "Scratchpad local replacement waited for a source window")
		return false
	}
	window_end := window.start_byte + u64(len(window.source))
	if start_byte < window.start_byte || end_byte > window_end {
		set_error(app, "The replacement range is outside the loaded source window.")
		alicorn.invalidate_root(rt, "Scratchpad replacement crossed a bounded window edge")
		return false
	}
	if editor_window_is_long_line_chunk(window) && editor_count_line_breaks(replacement) > 0 {
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
	local_start := int(start_byte-window.start_byte)
	local_end := int(end_byte-window.start_byte)
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
	removed_line_breaks := editor_count_line_breaks(window.source[local_start:local_end])
	new_window, replaced, replace_error := editor_window_replace_bytes(window, start_byte, end_byte, replacement)
	if !replaced {
		set_error(app, replace_error)
		alicorn.invalidate_root(rt, "Scratchpad could not apply a bounded optimistic replacement")
		return false
	}
	document_id, id_error := strings.clone(document.id, context.allocator)
	if id_error != nil {
		editor_window_destroy(&new_window)
		set_error(app, "Could not retain the edit's document identity.")
		return false
	}
	owned_action_id: string
	if action_id != "" {
		owned_action_id, id_error = strings.clone(action_id, context.allocator)
		if id_error != nil {
			delete(document_id, context.allocator)
			editor_window_destroy(&new_window)
			set_error(app, "Could not retain the semantic edit intent.")
			return false
		}
	}
	replacement_copy, replacement_error := make([]u8, len(replacement), allocator=context.allocator)
	if replacement_error != nil {
		delete(document_id, context.allocator)
		if len(owned_action_id) > 0 { delete(owned_action_id, context.allocator) }
		editor_window_destroy(&new_window)
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
			editor_window_destroy(&new_window)
			set_error(app, "Could not retain the authoritative replacement bytes for the serial edit queue.")
			return false
		}
		mem.copy(rawptr(&wire_copy[0]), rawptr(&wire_replacement[0]), len(wire_replacement))
	}
	view.viewport_anchor_skip_next_source_change = true
	view.viewport_anchor_pending = false
	view.viewport_anchor_resolved = false
	if view.authoritative_revision == 0 { view.authoritative_revision = document.editor_revision }
	edit_base_revision := view.authoritative_revision
	for pending in app.editor_edits {
		if pending.document_id == document.id && pending.base_editor_revision >= edit_base_revision {
			edit_base_revision = pending.base_editor_revision+1
		}
	}
	app.editor_edit_sequence += 1
	if app.editor_edit_sequence == 0 { app.editor_edit_sequence = 1 }
	editor_wrap_heights_apply_edit(view, window, start_byte, end_byte, replacement, removed_line_breaks)
	if view.optimistic_window_ready { editor_window_destroy(&view.optimistic_window) }
	view.optimistic_window = new_window
	view.optimistic_window_ready = true
	view.optimistic_pending_edits += 1
	view.optimistic_line_delta += i64(editor_count_line_breaks(replacement))-i64(removed_line_breaks)
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
	alicorn.invalidate_root(rt, "Scratchpad source replacement appeared optimistically")
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
			editor_wrap_heights_reset(view, int(document.line_count))
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
			if len(result.command.edit.applied_replacement) > 0 &&
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
			if view.optimistic_pending_edits > 0 { view.optimistic_pending_edits -= 1 }
			view.authoritative_revision = result.command.edit.editor_revision
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

request_close_document :: proc(app: ^App, rt: ^alicorn.Runtime, document_id: string) {
	if document_id == "" { return }
	if editor_document_has_recoverable_preedit(app, document_id) {
		if app.close_document_id != document_id {
			clear_close_prompt(app)
			app.close_document_id, _ = strings.clone(document_id, context.allocator)
		}
		set_error(app, "Copy or explicitly discard the committed IME recovery text before closing this document.")
		if rt != nil { alicorn.invalidate_root(rt, "Scratchpad blocked close to preserve committed IME text") }
		return
	}
	if len(app.editor_edits) > 0 {
		if !deferred_action_enqueue(app, .Close_Document, value=document_id) {
			set_error(app, "Could not queue the document close behind pending edits.")
			alicorn.invalidate_root(rt, "Scratchpad document close queue is full")
		}
		return
	}
	response := bridge.backend_command(&app.backend, "close_document", document_id=document_id)
	handle_command_result(app, rt, &response)
	bridge.backend_command_result_destroy(&response, context.allocator)
}

close_after_save :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if editor_document_has_recoverable_preedit(app, app.close_document_id) {
		set_error(app, "Copy the committed IME recovery text with Edit > Copy before closing this document.")
		if rt != nil { alicorn.invalidate_root(rt, "Scratchpad blocked save-and-close to preserve committed IME text") }
		return
	}
	if len(app.editor_edits) > 0 {
		if !deferred_action_enqueue(app, .Close_After_Save) {
			set_error(app, "Could not queue save-and-close behind pending edits.")
			alicorn.invalidate_root(rt, "Scratchpad save-and-close queue is full")
		}
		return
	}
	document_id, clone_err := strings.clone(app.close_document_id, context.allocator)
	if clone_err != nil { set_error(app, "Could not retain the pending document identity."); return }
	saved := bridge.backend_command(&app.backend, "save_document", document_id=document_id)
	if !saved.ok {
		handle_command_result(app, rt, &saved)
		bridge.backend_command_result_destroy(&saved, context.allocator)
		delete(document_id, context.allocator)
		return
	}
	bridge.backend_command_result_destroy(&saved, context.allocator)
	closed := bridge.backend_command(&app.backend, "close_document", document_id=document_id)
	handle_command_result(app, rt, &closed)
	bridge.backend_command_result_destroy(&closed, context.allocator)
	delete(document_id, context.allocator)
	deferred_actions_run(app, rt)
}

close_with_discard :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if editor_document_has_recoverable_preedit(app, app.close_document_id) {
		set_error(app, "Copy the committed IME recovery text with Edit > Copy before closing this document.")
		if rt != nil { alicorn.invalidate_root(rt, "Scratchpad blocked discard-and-close to preserve committed IME text") }
		return
	}
	if len(app.editor_edits) > 0 {
		if !deferred_action_enqueue(app, .Close_With_Discard) {
			set_error(app, "Could not queue discard-and-close behind pending edits.")
			alicorn.invalidate_root(rt, "Scratchpad discard-and-close queue is full")
		}
		return
	}
	response := bridge.backend_command(&app.backend, "close_document", document_id=app.close_document_id, discard=true)
	handle_command_result(app, rt, &response)
	bridge.backend_command_result_destroy(&response, context.allocator)
	deferred_actions_run(app, rt)
}

handle_command_result :: proc(app: ^App, rt: ^alicorn.Runtime, result: ^bridge.Backend_Command_Result) {
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
		editor_views_prune(app)
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

select_document :: proc(app: ^App, rt: ^alicorn.Runtime, document_id: string) {
	if len(app.editor_edits) > 0 {
		if !deferred_action_enqueue(app, .Select_Document, value=document_id) {
			set_error(app, "Could not queue document selection behind pending edits.")
			alicorn.invalidate_root(rt, "Scratchpad document selection queue is full")
		}
		return
	}
	response := bridge.backend_command(&app.backend, "select_document", document_id=document_id)
	handle_command_result(app, rt, &response)
	bridge.backend_command_result_destroy(&response, context.allocator)
}

navigate_tab :: proc(app: ^App, rt: ^alicorn.Runtime, direction: int) {
	documents := app.backend.state.documents
	if len(documents) < 2 { return }
	index := 0
	for document, i in documents {
		if document.id == app.backend.state.active { index = i; break }
	}
	index = (index + direction + len(documents)) % len(documents)
	select_document(app, rt, documents[index].id)
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

sync_runtime_actions :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil { return }
	composition_active := editor_active_preedit(app)
	for action in app.backend.state.actions {
		if action.id == "" || action.title == "" { continue }
		enabled := action.enabled
		if action.id == ACTION_DOCUMENT_FORMAT {
			enabled = false
			if document, found := find_document(&app.backend.state, app.backend.state.active); found {
				enabled = document.language == "markdown"
			}
		}
		if action.id == ACTION_EDIT_UNDO && editor_has_pending_active_document_edit(app) { enabled = true }
		if composition_active && (action.id == ACTION_EDIT_UNDO || action.id == ACTION_EDIT_REDO) { enabled = false }
		accepted := alicorn.action_update(rt,
			alicorn.Action_Descriptor{id=action_id_for(action.id), name=action.id, label=action.title},
			alicorn.Action_State{enabled=enabled, checked=action.checked},
		)
		if !accepted { set_error(app, fmt.tprintf("Alicorn rejected action metadata for %s", action.id)) }
	}
}

sync_menu_states :: proc(app: ^App) {
	if app == nil { return }
	composition_active := editor_active_preedit(app)
	for &item in app.file_items {
		if item.kind != .Command { continue }
		item.state = menu_action_state(&app.backend.state, item.command)
	}
	for &item in app.workspace_items {
		if item.kind != .Command { continue }
		switch {
		case item.command == action_id_for(ACTION_WORKSPACE_NEW_FILE), item.command == action_id_for(ACTION_WORKSPACE_NEW_FOLDER):
			item.state = alicorn.Action_State{enabled=app.backend.started && app.backend.state.has_workspace}
		case item.command == action_id_for(ACTION_WORKSPACE_SETTINGS):
			item.state = alicorn.Action_State{enabled=true}
		case:
			item.state = menu_action_state(&app.backend.state, item.command)
		}
	}
	for &item in app.document_items {
		if item.kind != .Command { continue }
		item.state = menu_action_state(&app.backend.state, item.command)
	}
	active_document, has_document := find_document(&app.backend.state, app.backend.state.active)
	for &item in app.document_items {
		if item.kind == .Command && item.command == action_id_for(ACTION_DOCUMENT_FORMAT) {
			item.state.enabled = has_document && active_document.language == "markdown"
		} else if item.kind == .Command && item.command == action_id_for(ACTION_DOCUMENT_GO_TO_LINE) {
			item.state.enabled = has_document
		} else if item.kind == .Command && item.command == action_id_for(ACTION_DOCUMENT_TOGGLE_WRAP) {
			item.state.enabled = has_document
		}
	}
	active_view: ^Editor_View_State
	active_window: ^Editor_Window
	window_matches := false
	if has_document {
		if view_index := editor_view_find(app.editor_views[:], active_document.id); view_index >= 0 {
			active_view = &app.editor_views[view_index]
			active_window, window_matches = editor_view_window(
				active_view,
				&app.editor_window,
				app.editor_window_ready,
				active_document.id,
				active_document.editor_revision,
			)
		}
	}
	selection_nonempty := active_view != nil && active_view.selection_anchor != active_view.caret_byte
	selection_available := false
	if selection_nonempty && window_matches {
		_, selection_available = editor_selected_source_bytes(active_window, active_view.selection_anchor, active_view.caret_byte)
		if selection_available {
			selected_bytes, _ := editor_selected_source_bytes(active_window, active_view.selection_anchor, active_view.caret_byte)
			selection_available = editor_source_bytes_valid_utf8(selected_bytes)
		}
	}
	for &item in app.edit_items {
		if item.kind != .Command { continue }
		switch string_for_action_id(item.command) {
		case ACTION_EDIT_UNDO:
			item.state = menu_action_state(&app.backend.state, item.command)
			if editor_has_pending_active_document_edit(app) { item.state.enabled = true }
		case ACTION_EDIT_REDO:
			item.state = menu_action_state(&app.backend.state, item.command)
		case ACTION_EDIT_COPY:
			item.state = alicorn.Action_State{enabled=selection_nonempty && selection_available}
		case ACTION_EDIT_CUT:
			item.state = alicorn.Action_State{enabled=selection_nonempty && selection_available}
		case ACTION_EDIT_PASTE:
			paste_range_available := false
			if active_view != nil && window_matches {
				start_byte := min(active_view.selection_anchor, active_view.caret_byte)
				end_byte := max(active_view.selection_anchor, active_view.caret_byte)
				window_end := active_window.start_byte+u64(len(active_window.source))
				paste_range_available = start_byte >= active_window.start_byte && end_byte <= window_end
			}
			item.state = alicorn.Action_State{enabled=has_document && paste_range_available && app.services.clipboard.get_text != nil}
		case ACTION_EDIT_SELECT_ALL:
			item.state = alicorn.Action_State{enabled=has_document && editor_current_byte_length(app, active_document) > 0}
		case ACTION_EDIT_DELETE_LINE:
			item.state = alicorn.Action_State{enabled=has_document}
		}
		if composition_active {
			switch string_for_action_id(item.command) {
			case ACTION_EDIT_UNDO, ACTION_EDIT_REDO, ACTION_EDIT_CUT, ACTION_EDIT_PASTE, ACTION_EDIT_SELECT_ALL:
				item.state.enabled = false
			case ACTION_EDIT_COPY:
				item.state = alicorn.Action_State{enabled=active_view != nil && len(active_view.preedit_text) > 0 && app.services.clipboard.set_text != nil}
			}
		}
	}
}

string_for_action_id :: proc(id: host.Application_Command_ID) -> string {
	if id == action_id_for(ACTION_EDIT_UNDO) { return ACTION_EDIT_UNDO }
	if id == action_id_for(ACTION_EDIT_REDO) { return ACTION_EDIT_REDO }
	if id == action_id_for(ACTION_EDIT_CUT) { return ACTION_EDIT_CUT }
	if id == action_id_for(ACTION_EDIT_COPY) { return ACTION_EDIT_COPY }
	if id == action_id_for(ACTION_EDIT_PASTE) { return ACTION_EDIT_PASTE }
	if id == action_id_for(ACTION_EDIT_SELECT_ALL) { return ACTION_EDIT_SELECT_ALL }
	if id == action_id_for(ACTION_EDIT_DELETE_LINE) { return ACTION_EDIT_DELETE_LINE }
	return ""
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
		editor_wrap_heights_reset(view, int(document.line_count))
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
	if line_needs_reveal && app.editor_scroll_owner != 0 && selection.cursor_line <= u64(0x7FFF_FFFF_FFFF_FFFF) {
		_ = editor_ensure_line_visible(
			rt,
			&app.editor_views[view_index],
			app.editor_scroll_owner,
			int(selection.cursor_line),
			"Scratchpad revealed the authoritative command caret line",
		)
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
	viewport, viewport_found := rt.nodes[owner]
	if !viewport_found || viewport.scroll_viewport_height <= 0 { return false }
	top := viewport.bounds.y
	bottom := top+viewport.scroll_viewport_height
	for target in rows {
		if target.logical_line != logical_line { continue }
		row, row_found := rt.nodes[target.node]
		if row_found && row.bounds.h > 0 && row.bounds.y >= top && row.bounds.y+row.bounds.h <= bottom {
			return true
		}
	}
	return false
}

menu_action_state :: proc(state: ^bridge.State_Envelope, id: host.Application_Command_ID) -> alicorn.Action_State {
	for action in state.actions {
		if action_id_for(action.id) == id { return alicorn.Action_State{enabled=action.visible && action.enabled, checked=action.checked} }
	}
	return alicorn.Action_State{}
}

action_enabled :: proc(state: ^bridge.State_Envelope, id: string) -> bool {
	for action in state.actions {
		if action.id == id { return action.visible && action.enabled }
	}
	return false
}

find_action :: proc(state: ^bridge.State_Envelope, id: string) -> (action: bridge.Action_State, found: bool) {
	for action in state.actions { if action.id == id { return action, true } }
	return
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

document_title :: proc(path: string) -> string {
	start := 0
	for character, index in path {
		if character == '/' || character == '\\' { start = index + 1 }
	}
	if start >= len(path) { return path }
	return path[start:]
}

action_id_for :: proc(name: string) -> host.Application_Command_ID {
	hash: u32 = 2_166_136_261
	for character in name {
		hash = (hash ~ u32(character)) * 16_777_619
	}
	if hash == 0 { hash = 1 }
	return host.Application_Command_ID(hash)
}

set_error :: proc(app: ^App, message: string) {
	if app == nil { return }
	if len(app.error_message) > 0 { delete(app.error_message, context.allocator) }
	app.error_message = ""
	if len(message) > 0 { app.error_message, _ = strings.clone(message, context.allocator) }
}

clear_close_prompt :: proc(app: ^App) {
	if app == nil { return }
	if len(app.close_document_id) > 0 { delete(app.close_document_id, context.allocator) }
	app.close_document_id = ""
}

init_menus :: proc(app: ^App) {
	app.file_items = [7]host.Application_Menu_Item{
		{kind=.Command, command=action_id_for(ACTION_FILE_OPEN), label="Open File…", state=alicorn.Action_State{enabled=true}, shortcut=host.Application_Menu_Shortcut{'O', {.Primary}}},
		{kind=.Command, command=action_id_for(ACTION_FILE_QUICK_OPEN), label="Quick Open…", state=alicorn.Action_State{enabled=true}, shortcut=host.Application_Menu_Shortcut{'P', {.Primary}}},
		{kind=.Command, command=action_id_for(ACTION_WORKSPACE_OPEN), label="Open Folder…", state=alicorn.Action_State{enabled=true}},
		{kind=.Separator},
		{kind=.Command, command=action_id_for(ACTION_FILE_SAVE), label="Save", shortcut=host.Application_Menu_Shortcut{'S', {.Primary}}},
		{kind=.Command, command=action_id_for(ACTION_FILE_SAVE_AS), label="Save As…", shortcut=host.Application_Menu_Shortcut{'S', {.Primary, .Shift}}},
		{kind=.Command, command=action_id_for(ACTION_DOCUMENT_CLOSE), label="Close Document", shortcut=host.Application_Menu_Shortcut{'W', {.Primary}}},
	}
	app.edit_items = [10]host.Application_Menu_Item{
		{kind=.Command, command=action_id_for(ACTION_EDIT_UNDO), label="Undo", shortcut=host.Application_Menu_Shortcut{'Z', {.Primary}}},
		{kind=.Command, command=action_id_for(ACTION_EDIT_REDO), label="Redo", shortcut=host.Application_Menu_Shortcut{'Z', {.Primary, .Shift}}},
		{kind=.Separator},
		{kind=.Command, command=action_id_for(ACTION_EDIT_CUT), label="Cut", shortcut=host.Application_Menu_Shortcut{'X', {.Primary}}},
		{kind=.Command, command=action_id_for(ACTION_EDIT_COPY), label="Copy", shortcut=host.Application_Menu_Shortcut{'C', {.Primary}}},
		{kind=.Command, command=action_id_for(ACTION_EDIT_PASTE), label="Paste", shortcut=host.Application_Menu_Shortcut{'V', {.Primary}}},
		{kind=.Separator},
		{kind=.Command, command=action_id_for(ACTION_EDIT_SELECT_ALL), label="Select All", shortcut=host.Application_Menu_Shortcut{'A', {.Primary}}},
		{kind=.Separator},
		{kind=.Command, command=action_id_for(ACTION_EDIT_DELETE_LINE), label="Delete Line", shortcut=host.Application_Menu_Shortcut{'K', {.Primary, .Shift}}},
	}
	app.workspace_items = [6]host.Application_Menu_Item{
		{kind=.Command, command=action_id_for(ACTION_WORKSPACE_NEW_FILE), label="New File"},
		{kind=.Command, command=action_id_for(ACTION_WORKSPACE_NEW_FOLDER), label="New Folder"},
		{kind=.Separator},
		{kind=.Command, command=action_id_for(ACTION_WORKSPACE_REFRESH), label="Refresh Workspace", shortcut=host.Application_Menu_Shortcut{'R', {.Primary, .Shift}}},
		{kind=.Separator},
		{kind=.Command, command=action_id_for(ACTION_WORKSPACE_SETTINGS), label="Settings…"},
	}
	app.document_items = [11]host.Application_Menu_Item{
		{kind=.Command, command=action_id_for(ACTION_TAB_NEXT), label="Next Document"},
		{kind=.Command, command=action_id_for(ACTION_TAB_PREVIOUS), label="Previous Document"},
		{kind=.Separator},
		{kind=.Command, command=action_id_for(ACTION_DOCUMENT_FORMAT), label="Format Table"},
		{kind=.Command, command=action_id_for(ACTION_DOCUMENT_GO_TO_LINE), label="Go to Line…", shortcut=host.Application_Menu_Shortcut{'G', {.Primary}}},
		{kind=.Command, command=action_id_for(ACTION_DOCUMENT_TOGGLE_WRAP), label="Cycle Word Wrap"},
		{kind=.Separator},
		{kind=.Command, command=action_id_for(ACTION_MARKDOWN_TOGGLE_STRONG), label="Strong", shortcut=host.Application_Menu_Shortcut{'B', {.Primary}}},
		{kind=.Command, command=action_id_for(ACTION_MARKDOWN_TOGGLE_EMPHASIS), label="Emphasis", shortcut=host.Application_Menu_Shortcut{'I', {.Primary}}},
		{kind=.Command, command=action_id_for(ACTION_MARKDOWN_TOGGLE_INLINE_CODE), label="Inline Code"},
		{kind=.Command, command=action_id_for(ACTION_MARKDOWN_INSERT_TASK), label="Task Checkbox"},
	}
	app.view_items = [1]host.Application_Menu_Item{
		{kind=.Command, command=action_id_for(ACTION_VIEW_COMMAND_PALETTE), label="Command Palette…", state=alicorn.Action_State{enabled=true}, shortcut=host.Application_Menu_Shortcut{'P', {.Primary, .Shift}}},
	}
	app.menus = [5]host.Application_Menu{
		{label="File", items=app.file_items[:]},
		{label="Edit", items=app.edit_items[:]},
		{label="Workspace", items=app.workspace_items[:]},
		{label="Document", items=app.document_items[:]},
		{label="View", items=app.view_items[:]},
	}
}

application_stop :: proc(state: rawptr) {
	app := cast(^App)state
	if app.backend.started {
		stopped, message := stop_backend(app)
		app.smoke_shutdown = stopped && !app.backend.started && app.backend.waiter.thread == nil && app.backend.state_leases == 0 && app.backend.resource_leases == 0 && app.visible_window_lane.thread == nil && app.editor_edit_lane.thread == nil && app.quick_open_lane.thread == nil
		if !stopped { fmt.eprintln("Scratchpad backend shutdown error:", message) }
	} else {
		app.smoke_shutdown = true
	}
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
}

main :: proc() {
	app: App
	app.tree_directories = make([dynamic]Tree_Directory, 0, allocator=context.allocator)
	app.workspace_search_selected = -1
	app.editor_views = make([dynamic]Editor_View_State, 0, allocator=context.allocator)
	app.editor_row_targets = make([dynamic]Editor_Row_Target, 0, allocator=context.allocator)
	app.editor_edits = make([dynamic]Editor_Edit_Intent, 0, allocator=context.allocator)
	app.deferred_actions = make([dynamic]Deferred_Action, 0, allocator=context.allocator)
	init_menus(&app)
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
