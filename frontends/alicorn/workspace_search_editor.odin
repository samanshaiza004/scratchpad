package main

import "core:fmt"
import alicorn "alicorn:runtime"
import gui "alicorn:ui"

workspace_search_editor_build :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime) {
	if app == nil || ui == nil || rt == nil { return }
	app.workspace_search_query_node = 0
	if gui.row(ui, label="workspace-search-editor-toolbar", height=42, gap=8, align=.Center) {
		gui.text(ui, "Search", style=alicorn.layout_style(.Row, width=58),
			text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_MEDIUM})
		query_node := alicorn.text_field(ui, app.workspace_search_query,
			key=alicorn.key_string(WORKSPACE_SEARCH_QUERY_KEY),
			style=alicorn.layout_style(.Row, grow=1, height=36),
			text_style=SCRATCHPAD_PROMINENT_INPUT_TEXT_STYLE)
		app.workspace_search_query_node = query_node
		if query_node != 0 { _ = alicorn.semantic_text_field_label(ui, "Search the workspace") }
		if gui.button(ui, "×", key="workspace-search-close", width=34, height=32,
			variant=.Toolbar) {
			_ = workspace_search_close_tab(app, rt)
		}
		_ = alicorn.tooltip(ui, "Close Search tab")
	}

	status := "Type to search workspace files"
	if !app.backend.state.has_workspace { status = "Open a workspace to search files" }
	if app.workspace_search_error != "" { status = app.workspace_search_error
	} else if app.workspace_search_query != "" {
		if app.workspace_search_view.done {
			status = fmt.tprintf("%d matches", app.workspace_search_view.count)
			if app.workspace_search_view.truncated { status = fmt.tprintf("%s · result limit reached", status) }
			if len(app.workspace_search_view.results) == 0 { status = "No matches" }
		} else {
			status = fmt.tprintf("Searching…  %d matches", app.workspace_search_view.count)
		}
	}
	gui.text(ui, status,
		style=alicorn.layout_style(.Row, height=24),
		color=alicorn.style_color(ui, .Muted_Text),
		text_style=alicorn.Text_Style{font_size=12, overflow=.Ellipsis})
	if len(app.workspace_search_view.results) == 0 {
		if gui.column(ui, label="workspace-search-empty-state", height=-1, grow=1, align=.Center, justify=.Center, gap=8) {
			message := "Type a workspace query to see matching source excerpts here."
			if app.workspace_search_query != "" && app.workspace_search_view.done { message = "Try a different query or search options." }
			gui.text(ui, message, color=alicorn.style_color(ui, .Muted_Text),
				text_style=alicorn.Text_Style{font_size=14, overflow=.Ellipsis})
			gui.text(ui, "Click an excerpt to edit it; click its file and line to open the source.",
				color=alicorn.style_color(ui, .Muted_Text),
				text_style=alicorn.Text_Style{font_size=12, overflow=.Ellipsis})
		}
		return
	}

	_ = workspace_search_edit_validate_window(app, rt)
	search_palette := editor_markdown_palette(rt, app.workbench_theme)
	rows := workspace_search_display_rows(app.workspace_search_view.results[:], alicorn.runtime_scratch_allocator(rt))
	defer delete(rows)
	search_list := alicorn.virtual_list_begin(
		ui,
		len(rows),
		WORKSPACE_SEARCH_ROW_HEIGHT,
		key=alicorn.key_string("scratchpad-workspace-search-results"),
		style=alicorn.layout_style(grow=1, clip=true),
		label="Workspace search results",
		focusable=true,
	)
	app.workspace_search_results_owner = search_list.scroll.id
	for display_index := search_list.first; display_index < search_list.last; display_index += 1 {
		row := rows[display_index]
		position := row.result_index
		result := app.workspace_search_view.results[position]
		if row.file_header {
			if gui.row(ui, key=alicorn.key_pair(app.workspace_search_view.generation, result.projection_key),
				label="workspace-search-file-header", height=WORKSPACE_SEARCH_ROW_HEIGHT, gap=8, align=.Center) {
				heading_node := gui.text(ui, result.path,
					style=alicorn.layout_style(.Row, height=24, grow=1, justify=.Start),
					text_style=alicorn.Text_Style{font_size=13, font_weight=alicorn.FONT_WEIGHT_MEDIUM, overflow=.Ellipsis})
				append(&app.workspace_search_pointer_targets, Workspace_Search_Pointer_Target{
					node=heading_node, generation=app.workspace_search_view.generation,
					projection_key=result.projection_key, kind=.Navigate_Source,
				})
				gui.text(ui, fmt.tprintf("%d matches", row.match_count),
					style=alicorn.layout_style(.Row, width=100, height=24, justify=.End),
					color=alicorn.style_color(ui, .Muted_Text),
					text_style=alicorn.Text_Style{font_size=12, overflow=.Ellipsis})
			}
			continue
		}
		active_edit := workspace_search_edit_session_matches(app, position)
		diverged := active_edit && workspace_search_result_diverged(
			app.workspace_search_edit_buffer.text,
			app.workspace_search_started_query,
			app.workspace_search_edit_source_changed,
		)
		selected := app.workspace_search_selected == position
		row_color := alicorn.NO_BACKGROUND_COLOR
		if selected { row_color = editor_markdown_tint(alicorn.style_color(ui, .Selection), 0.14) }
		else if diverged { row_color = editor_markdown_tint(alicorn.style_color(ui, .Accent_Hover), 0.10) }
		alicorn.container_begin(ui, .Container,
			key=alicorn.key_pair(app.workspace_search_view.generation, result.projection_key),
			label="workspace-search-result",
			style=alicorn.layout_style(.Row, height=WORKSPACE_SEARCH_ROW_HEIGHT, gap=10, align=.Center, clip=true),
			color=row_color,
		)
		heading_node := gui.text(ui, fmt.tprintf("%d", result.line+1),
			style=alicorn.layout_style(.Row, width=54, height=WORKSPACE_SEARCH_TEXT_HEIGHT, justify=.End),
			font=.Monospace,
			color=alicorn.style_color(ui, .Muted_Text),
			text_style=alicorn.Text_Style{font_size=12, overflow=.Ellipsis},
		)
		append(&app.workspace_search_pointer_targets, Workspace_Search_Pointer_Target{
			node=heading_node,
			generation=app.workspace_search_view.generation,
			projection_key=result.projection_key,
			kind=.Navigate_Source,
		})
		if active_edit {
			if app.workspace_search_edit_ready {
				edit_field := alicorn.text_field_controlled(ui, &app.workspace_search_edit_buffer,
					key=alicorn.key_pair(app.workspace_search_edit_generation, app.workspace_search_edit_projection_key),
					style=alicorn.layout_style(.Row, grow=1, height=WORKSPACE_SEARCH_TEXT_HEIGHT, clip=true, justify=.Start),
					font=.Monospace,
					text_style=alicorn.Text_Style{font_size=14, font_weight=alicorn.FONT_WEIGHT_REGULAR, overflow=.Ellipsis},
				)
				app.workspace_search_edit_node = edit_field.node
				if edit_field.node != 0 {
					_ = alicorn.semantic_text_field_label(ui, fmt.tprintf("Search result in %s, line %d", result.path, result.line+1))
					match_start := min(max(app.workspace_search_edit_match_start, 0), len(app.workspace_search_edit_buffer.text))
					match_end := min(max(app.workspace_search_edit_match_end, match_start), len(app.workspace_search_edit_buffer.text))
					if !diverged && match_end > match_start {
						match_paint := [?]alicorn.Text_Paint_Span{{
							start=match_start,
							end=match_end,
							background=search_palette.workspace_search_background,
							background_set=true,
						}}
						_ = alicorn.text_paint_spans(ui, edit_field.node, match_paint[:])
					}
				}
				if edit_field.changed { _ = workspace_search_edit_apply_change(app, rt) }
			} else {
				gui.text(ui, "Validating source context…",
					style=alicorn.layout_style(.Row, height=WORKSPACE_SEARCH_TEXT_HEIGHT),
					text_style=alicorn.Text_Style{font_size=14})
			}
		} else {
			preview := workspace_search_result_preview(result)
			preview_node := gui.text(ui, preview.text,
				style=alicorn.layout_style(.Row, grow=1, height=WORKSPACE_SEARCH_TEXT_HEIGHT, clip=true, justify=.Start),
				font=.Monospace,
				color=alicorn.style_color(ui, .Text) if result.editable else alicorn.style_color(ui, .Muted_Text),
				text_style=alicorn.Text_Style{font_size=14, font_weight=alicorn.FONT_WEIGHT_REGULAR, overflow=.Ellipsis},
			)
			if result.editable {
				match_start := preview.match_start
				match_end := preview.match_end
				if match_start >= preview.prefix_bytes && match_end > match_start {
					match_paint := [?]alicorn.Text_Paint_Span{{
						start=match_start,
						end=match_end,
						background=search_palette.workspace_search_background,
						background_set=true,
					}}
					_ = alicorn.text_paint_spans(ui, preview_node, match_paint[:])
				}
			}
			append(&app.workspace_search_pointer_targets, Workspace_Search_Pointer_Target{
				node=preview_node,
				generation=app.workspace_search_view.generation,
				projection_key=result.projection_key,
				kind=.Edit_Text,
			})
		}
		if diverged {
			alicorn.icon(ui, .Warning, key=alicorn.key_string("workspace-search-diverged-icon"), size=14, color_role=.Accent_Hover)
			_ = gui.text(ui, "No match", key=alicorn.key_string("workspace-search-diverged-label"),
				style=alicorn.layout_style(.Row, width=62, height=22),
				color=alicorn.style_color(ui, .Accent_Hover),
				text_style=alicorn.Text_Style{font_size=11, font_weight=alicorn.FONT_WEIGHT_MEDIUM, overflow=.Ellipsis},
			)
			status_description := "This edited line no longer matches the search query. Finish editing to refresh the results."
			_ = alicorn.semantic_description(ui, .Status, "Edited result no longer matches",
				description=status_description, value="No match")
			_ = alicorn.tooltip(ui, status_description)
		}
		alicorn.container_end(ui)
	}
	alicorn.virtual_list_end(ui, search_list)
}
