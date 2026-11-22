package main

import "core:fmt"
import alicorn "alicorn:runtime"
import gui "alicorn:ui"

SCRATCHPAD_FIND_EDITOR_JOIN_RADIUS :: f32(8)

// The Find panel only forms a continuous vertical stack when one editor owns
// the workbench. Other layouts keep their ordinary independent surface
// geometry so a full-width Find bar does not imply a false join to split panes.
scratchpad_find_editor_join_enabled :: proc(app: ^App) -> bool {
	if app == nil || !app.find_open || app.workspace_search_mode || app.pinned.visible {
		return false
	}
	if app_workbench_group_count(app) != 1 || workbench_group_split_has_multiple(app) {
		return false
	}
	window := app_workbench_window(app)
	if window == nil { return false }
	group_index := workbench_group_find(window, window.focused_group_id)
	if group_index < 0 { return false }
	view_index := workbench_view_find(window, window.groups[group_index].active_view_id)
	return view_index >= 0 && window.views[view_index].kind == .Editor
}

Workbench_Tab_Entry :: struct {
	view_id: View_ID,
	search: bool,
}

app_workbench_tab_count :: proc(app: ^App, group_id: Pane_Group_ID) -> int {
	window := app_workbench_window(app)
	if window == nil { return 0 }
	count := 0
	for view in window.views {
		if view.group_id != group_id { continue }
		if app.floating_window != nil && view.kind == .Editor && view.resource.id == app.floating_window.document_id { continue }
		count += 1
	}
	if app.workspace_search_tab_open && window.focused_group_id == group_id { count += 1 }
	return count
}

workbench_group_views_ordered :: proc(window: ^Workbench_State, group_id: Pane_Group_ID, allocator := context.temp_allocator) -> [dynamic]View_ID {
	ordered := make([dynamic]View_ID, 0, allocator=allocator)
	if window == nil { return ordered }
	for view in window.views {
		if view.group_id == group_id { append(&ordered, view.id) }
	}
	for i := 1; i < len(ordered); i += 1 {
		j := i
		for j > 0 {
			left := workbench_view_find(window, ordered[j-1])
			right := workbench_view_find(window, ordered[j])
			if left < 0 || right < 0 || window.views[left].tab_order <= window.views[right].tab_order { break }
			ordered[j-1], ordered[j] = ordered[j], ordered[j-1]
			j -= 1
		}
	}
	return ordered
}

// scratchpad_workbench_group_tabs_build prepares the tab projection, then
// describes it either directly or through the #231 adopted region. The region
// exists only on the compact titlebar strip: the split-pane tab bar is built
// inside a retained surface whose own invalidation already scopes it.
scratchpad_workbench_group_tabs_build :: proc(
	app: ^App,
	ui: ^alicorn.UI,
	rt: ^alicorn.Runtime,
	group_id: Pane_Group_ID,
	width, height: f32,
	compact, show_empty: bool,
) {
	if app == nil || ui == nil || rt == nil { return }
	window := app_workbench_window(app)
	if window == nil { app.document_connected_tab_node_region_cache = 0; return }
	ordered := workbench_group_views_ordered(window, group_id)
	defer delete(ordered)
	entries := make([dynamic]Workbench_Tab_Entry, 0, len(ordered)+1, allocator=context.temp_allocator)
	defer delete(entries)
	items := make([dynamic]alicorn.Tab_Bar_Item, 0, len(ordered)+1, allocator=context.temp_allocator)
	defer delete(items)
	group_index := workbench_group_find(window, group_id)
	if group_index < 0 { app.document_connected_tab_node_region_cache = 0; return }
	for view_id in ordered {
		view_index := workbench_view_find(window, view_id)
		if view_index < 0 { continue }
		view := window.views[view_index]
		if app.floating_window != nil && view.kind == .Editor && view.resource.id == app.floating_window.document_id { continue }
		label := ""
		tooltip := ""
		dirty := false
		preview := false
		switch view.kind {
		case .Editor:
			if document, found := find_document(&app.backend.state, view.resource.id); found {
				label = document_title(document.path)
				tooltip = document.path
				dirty = document.dirty
				preview = document.preview && !document.dirty
			} else {
				label = "Missing document"
				tooltip = view.resource.id
			}
		case .History:
			label, tooltip = "History", "Repository History"
		case .Diff:
			label, tooltip = "Diff", "Read-only Git Diff"
			if app.backend.state.git.diff_path != "" { label = fmt.tprintf("Diff · %s", app.backend.state.git.diff_path) }
		}
		append(&entries, Workbench_Tab_Entry{view_id=view_id})
		semantic_id := workbench_view_semantic_id(view.id)
		if view.kind == .Editor { semantic_id = document_tab_semantic_id(view.resource.id) }
		append(&items, alicorn.Tab_Bar_Item{
			key=alicorn.key_string(fmt.tprintf("workbench-view-%d", u64(view.id))),
			label=label,
			label_italic=preview,
			label_muted=preview,
			tooltip=tooltip,
			selected=window.groups[group_index].active_view_id == view.id,
			closable=true,
			dirty=dirty,
			semantic_id=semantic_id,
		})
	}
	if app.workspace_search_tab_open && window.focused_group_id == group_id {
		search_tooltip := "Workspace Search"
		if app.workspace_search_query != "" { search_tooltip = fmt.tprintf("Search: %s", app.workspace_search_query) }
		append(&entries, Workbench_Tab_Entry{search=true})
		append(&items, alicorn.Tab_Bar_Item{
			key=alicorn.key_string("scratchpad-workspace-search-tab"),
			label="Search",
			tooltip=search_tooltip,
			selected=app.workspace_search_mode,
			closable=true,
		})
	}
	if len(items) == 0 {
		app.document_connected_tab_node_region_cache = 0
		if show_empty {
			label := "No views open"
			if len(app.backend.state.documents) == 0 { label = "No documents open" }
			gui.text(ui, label, style=alicorn.layout_style(.Row, grow=1, height=height))
		}
		return
	}
	options := alicorn.DEFAULT_TAB_BAR_OPTIONS
	options.height = height
	options.close_policy = .Selected_Or_Hover
	options.drag_type = SCRATCHPAD_DRAG_TABS
	options.animate_drag_reorder = true
	if !app.find_open && app.floating_window == nil {
		options.drag_tracking = alicorn.DRAG_TRACKING_HORIZONTAL_MAGNETIC
	}
	if compact {
		options.min_tab_width = SCRATCHPAD_CONTENT_TITLEBAR_MIN_TAB_WIDTH
		options.max_tab_width = 180
		options.gap = 0
		options.presentation = .Compact
		if !app.find_open {
			if paper, found := alicorn.style_extension_color(rt, app.editor_theme, scratchpad_editor_paper_surface_role()); found {
				options.appearance = .Connected
				options.selected_fill = paper
				options.selected_text = alicorn.style_theme_color(rt, app.editor_theme, .Text)
				options.selected_fill_set = true
			}
		}
	}
	style := alicorn.layout_style(.Row, grow=1, height=height, clip=true)
	if compact && width > 0 { style = alicorn.layout_style(.Row, width=width, height=height, clip=true) }

	result_revision: u64
	if compact {
		signature := scratchpad_document_tabs_region_signature(app, rt, window, entries[:], items[:], width, height)
		result_revision = region_generation_next(&app.document_tabs_region, signature)
		region_style := alicorn.layout_style(.Row, grow=1, height=height, clip=true)
		if width > 0 { region_style = alicorn.layout_style(.Row, width=width, height=height, clip=true) }
		region_id, reused := alicorn.region_begin(
			ui, "scratchpad-doc-tabs", result_revision,
			style=region_style,
		)
		if reused {
			if !app.find_open { app.document_connected_tab_node = app.document_connected_tab_node_region_cache }
			return
		}
		scratchpad_workbench_group_tabs_emit(app, ui, rt, group_id, window, entries[:], items[:], options, style, group_index, compact)
		alicorn.region_end(ui, region_id, false, 0)
		if !app.find_open { app.document_connected_tab_node = app.document_connected_tab_node_region_cache }
		return
	}
	scratchpad_workbench_group_tabs_emit(app, ui, rt, group_id, window, entries[:], items[:], options, style, group_index, compact)
}

// The region signature is the tab projection plus every non-item input the
// emit path reads. Interaction state is included because tab_bar reports a
// click only when the application calls it again: a reused region would leave
// the activation pending and drop the click.
scratchpad_document_tabs_region_signature :: proc(
	app: ^App,
	rt: ^alicorn.Runtime,
	window: ^Workbench_State,
	entries: []Workbench_Tab_Entry,
	items: []alicorn.Tab_Bar_Item,
	width, height: f32,
) -> u64 {
	hash := REGION_HASH_OFFSET
	for entry, index in entries {
		hash = region_hash_mix(hash, 1 if entry.search else 0)
		hash = region_hash_mix(hash, u64(entry.view_id))
		if index >= len(items) { continue }
		item := items[index]
		hash = region_hash_string(hash, item.label)
		hash = region_hash_string(hash, item.tooltip)
		hash = region_hash_bool(hash, item.selected)
		hash = region_hash_bool(hash, item.dirty)
		hash = region_hash_bool(hash, item.label_italic)
		hash = region_hash_bool(hash, item.label_muted)
		hash = region_hash_bool(hash, item.closable)
		hash = region_hash_mix(hash, item.semantic_id.namespace)
		hash = region_hash_mix(hash, item.semantic_id.value)
	}
	hash = region_hash_f32(hash, width)
	hash = region_hash_f32(hash, height)
	hash = region_hash_bool(hash, app.find_open)
	hash = region_hash_bool(hash, app.floating_window != nil)
	if app.floating_window != nil { hash = region_hash_string(hash, app.floating_window.document_id) }
	hash = region_hash_mix(hash, u64(app.editor_theme))
	hash = region_hash_mix(hash, u64(app.workbench_theme))
	hash = region_hash_bool(hash, app.workspace_search_tab_open)
	hash = region_hash_bool(hash, app.workspace_search_mode)
	hash = region_hash_string(hash, app.workspace_search_query)
	hash = region_hash_mix(hash, u64(window.focused_group_id))
	hash = region_hash_mix(hash, u64(window.groups[0].active_view_id if len(window.groups) > 0 else 0))
	hash = region_hash_string(hash, app.backend.state.git.diff_path)
	hash = region_hash_bool(hash, app.accessibility_appearance_override_enabled)
	hash = region_hash_bool(hash, app.accessibility_appearance.reduce_motion)
	// tab_bar sizes tabs from the retained tab-bar scroll viewport, which is
	// only known after the first layout of a new strip. Without this the first
	// description's provisional tab widths would stay cached after the parent
	// width settles.
	if len(window.groups) > 0 {
		tab_bar_key := alicorn.key_string(fmt.tprintf("workbench-group-tabs-%d", u64(window.groups[0].id)))
		if container_id, found := alicorn.node_by_key(rt, tab_bar_key, .Container); found {
			if info, ok := alicorn.node_info(rt, container_id); ok {
				hash = region_hash_f32(hash, info.bounds.w)
				hash = region_hash_f32(hash, info.bounds.h)
			}
			if node, ok := rt.nodes[container_id]; ok {
				for child_id in node.children {
					if child, child_ok := rt.nodes[child_id]; child_ok && child.kind == .Scroll_Region {
						hash = region_hash_f32(hash, child.scroll_viewport_width)
						hash = region_hash_f32(hash, child.scroll_offset_x)
						break
					}
				}
			}
		}
	}
	// Pointer/keyboard interaction and tab drag-reorder are application-polled
	// inputs, not retained state. A cached body would not observe them.
	if rt != nil {
		hash = region_hash_mix(hash, u64(rt.activation_node))
		hash = region_hash_mix(hash, u64(rt.activation_sequence))
		hash = region_hash_mix(hash, u64(rt.focused))
		hash = region_hash_bool(hash, rt.focus_visible)
	}
	hash = region_hash_mix(hash, u64(app.workspace_drag_kind))
	hash = region_hash_string(hash, app.workspace_drag_source_document_id)
	hash = region_hash_mix(hash, app.workspace_drag_target.namespace)
	hash = region_hash_mix(hash, app.workspace_drag_target.value)
	hash = region_hash_mix(hash, u64(app.workspace_drag_position))
	hash = region_hash_bool(hash, app.workspace_drag_motion_reset_pending)
	hash = region_hash_bool(hash, app.workspace_drag_motion_reset_snap)
	hash = region_hash_bool(hash, app.document_tab_reorder_motion_cleanup_needed)
	hash = region_hash_mix(hash, app.document_tab_reorder_motion_signature)
	return hash
}

// scratchpad_workbench_group_tabs_emit is the original tab-bar description.
// It keeps the early returns and the action dispatch unchanged; the caller
// places it inside the adopted region and owns the region end.
scratchpad_workbench_group_tabs_emit :: proc(
	app: ^App,
	ui: ^alicorn.UI,
	rt: ^alicorn.Runtime,
	group_id: Pane_Group_ID,
	window: ^Workbench_State,
	entries: []Workbench_Tab_Entry,
	items: []alicorn.Tab_Bar_Item,
	options: alicorn.Tab_Bar_Options,
	style: alicorn.Layout_Style,
	group_index: int,
	compact: bool,
) {
	if app == nil || ui == nil || rt == nil || window == nil { return }
	ordered := workbench_group_views_ordered(window, group_id)
	defer delete(ordered)
	result := alicorn.tab_bar(
		ui,
		alicorn.key_string(fmt.tprintf("workbench-group-tabs-%d", u64(group_id))),
		items[:], options, style,
	)
	if compact && len(entries) == len(ordered) && len(result.item_nodes) == len(entries) {
		all_editors := true
		document_indices := make([dynamic]int, 0, len(entries), allocator=context.temp_allocator)
		defer delete(document_indices)
		for entry in entries {
			view_index := workbench_view_find(window, entry.view_id)
			if view_index < 0 || window.views[view_index].kind != .Editor { all_editors = false; break }
			document_index := -1
			for document, index in app.backend.state.documents {
				if document.id == window.views[view_index].resource.id { document_index = index; break }
			}
			if document_index < 0 { all_editors = false; break }
			append(&document_indices, document_index)
		}
		if all_editors {
			scratchpad_document_tabs_reorder_motion(
				app, ui, rt, app.backend.state.documents, document_indices[:], result.item_nodes[:],
				app.floating_window == nil,
			)
		}
	}
	if !app.find_open { app.document_connected_tab_node_region_cache = result.selected_tab }
	if result.action == .None || result.item_index < 0 || result.item_index >= len(entries) { return }
	entry := entries[result.item_index]
	if entry.search {
		if result.action == .Select { workspace_search_open_surface(app, rt) }
		else { _ = workspace_search_close_tab(app, rt) }
		return
	}
	view_index := workbench_view_find(window, entry.view_id)
	if view_index < 0 { return }
	view := window.views[view_index]
	if result.action == .Close {
		if view.kind == .Editor {
			if !frame_deferred_action_schedule(app, .Close_Document, view.resource.id) {
				set_error(app, "Could not queue the document close until the current frame is complete.")
			}
		} else {
			app.workbench_pending_close_view_id = view.id
		}
		return
	}
	if result.action == .Select &&
		scratchpad_document_tab_selection_is_noop(app, group_id, view.id, view.resource.id) {
		return
	}
	if app.workspace_search_mode && !workspace_search_deactivate(app, rt) { return }
	if !app_workbench_activate_view(app, rt, view.id) {
		set_error(app, "Could not activate the selected workbench view.")
		return
	}
	alicorn.invalidate_root(rt, "Scratchpad workbench tab selected")
}

workbench_pane_render_node :: proc(
	app: ^App,
	ui: ^alicorn.UI,
	rt: ^alicorn.Runtime,
	dpi_scale, width, height: f32,
	node_id: Pane_Node_ID,
) {
	window := app_workbench_window(app)
	if window == nil || ui == nil || rt == nil { return }
	node_index := workbench_node_find(window, node_id)
	if node_index < 0 { return }
	node := window.nodes[node_index]
	if node.kind == .Group {
		workbench_group_render(app, ui, rt, dpi_scale, width, height, node.group_id)
		return
	}
	dimension := width if node.axis == .Horizontal else height
	if dimension <= 0 { dimension = 1 }
	initial := clamp(node.preferred_position, 0.1, 0.9)*dimension
	minimum := min(f32(220), max(dimension*0.32, 100))
	split := alicorn.split_begin(
		ui,
		key=alicorn.key_string(fmt.tprintf("workbench-pane-split-%d", u64(node.id))),
		axis=alicorn.Split_Axis(node.axis),
		initial=initial,
		min_first=minimum,
		min_second=minimum,
		style=alicorn.layout_style(.Row, grow=1, gap=2, clip=true),
		label="Scratchpad workbench pane split",
	)
	if split.position > 0 && dimension > 0 {
		if current_index := workbench_node_find(window, node.id); current_index >= 0 {
			window.nodes[current_index].preferred_position = clamp(split.position/dimension, 0.1, 0.9)
		}
	}
	alicorn.split_first_begin(ui, split)
	first_width, first_height := width, height
	second_width, second_height := width, height
	if node.axis == .Horizontal {
		first_width = split.position
		second_width = max(width-split.position-2, 1)
	} else {
		first_height = split.position
		second_height = max(height-split.position-2, 1)
	}
	workbench_pane_render_node(app, ui, rt, dpi_scale, first_width, first_height, node.first_child_id)
	alicorn.split_first_end(ui, split)
	alicorn.split_divider(ui, split)
	alicorn.split_second_begin(ui, split)
	workbench_pane_render_node(app, ui, rt, dpi_scale, second_width, second_height, node.second_child_id)
	alicorn.split_second_end(ui, split)
	alicorn.split_end(ui, split)
}

workbench_group_render :: proc(
	app: ^App,
	ui: ^alicorn.UI,
	rt: ^alicorn.Runtime,
	dpi_scale, width, height: f32,
	group_id: Pane_Group_ID,
) {
	window := app_workbench_window(app)
	if window == nil { return }
	group_index := workbench_group_find(window, group_id)
	if group_index < 0 { return }
	group := window.groups[group_index]
	key := alicorn.key_string(fmt.tprintf("workbench-group-%d", u64(group_id)))
	node := alicorn.container_begin(
		ui, .Container, key=key, label=fmt.tprintf("workbench-pane-group-%d", u64(group_id)),
		style=alicorn.layout_style(.Column, grow=1, gap=0, clip=true),
	)
	_ = node
	_ = alicorn.semantic_bind(ui, workbench_group_semantic_id(group_id))
	_ = alicorn.drop_target(ui, SCRATCHPAD_DRAG_TABS, workbench_group_semantic_id(group_id), .On)
	if app_workbench_group_count(app) > 1 {
		alicorn.surface_begin(ui, alicorn.surface_core_color_role(.Subtle_Surface),
			key=alicorn.key_string(fmt.tprintf("workbench-group-tab-surface-%d", u64(group_id))),
			label="workbench-group-tab-surface",
			style=alicorn.layout_style(.Row, height=34, gap=1, padding=2, clip=true),
			material=scratchpad_surface_material(app, app.raised_surface_material),
			physical_height=scratchpad_surface_height(app, 0.55),
		)
		scratchpad_workbench_group_tabs_build(app, ui, rt, group_id, width, 30, false, true)
		alicorn.surface_end(ui)
	}
	if app.workspace_search_mode && window.focused_group_id == group_id {
		alicorn.surface_begin(ui, alicorn.surface_core_color_role(.Surface),
			key=alicorn.key_string(fmt.tprintf("workbench-content-%d", u64(group_id))),
			label="workbench-view-content", style=alicorn.layout_style(.Column, grow=1, clip=true),
			material=scratchpad_surface_material(app, app.paper_surface_material),
			physical_height=scratchpad_surface_height(app, -0.75),
		)
		workspace_search_editor_build(app, ui, rt)
		alicorn.surface_end(ui)
		alicorn.container_end(ui)
		return
	}
	group_count := app_workbench_group_count(app)
	view_index := workbench_view_find(window, group.active_view_id)
	if view_index < 0 {
		if gui.column(ui, label=fmt.tprintf("workbench-empty-group-%d", u64(group_id)), height=-1, grow=1, align=.Center, justify=.Center, gap=8) {
			if group_count == 1 && len(app.backend.state.documents) == 0 {
				if app.brand_mark != 0 {
					_ = alicorn.image(ui, app.brand_mark, alt_text="Scratchpad mark",
						key=alicorn.key_string("scratchpad-brand-mark"),
						style=alicorn.layout_style(.Row, width=40, height=40))
				}
				gui.text(ui, "No document open")
				gui.text(ui, "Open a file from this workspace to begin editing.")
				if gui.button(ui, "Quick Open…", key="empty-editor-quick-open", width=210, height=42, variant=.Primary) {
					quick_open_open_surface(app, rt)
				}
				gui.text(ui, "Ctrl+P opens Quick Open")
			} else {
				gui.text(ui, "This pane has no view.")
			}
		}
		alicorn.container_end(ui)
		return
	}
	view := window.views[view_index]
	content_key := alicorn.key_string(fmt.tprintf("workbench-content-%d", u64(group_id)))
	content_label := "workbench-view-content"
	if view.kind == .Editor { content_label = "document-surface" }
	content := alicorn.surface_begin(ui, alicorn.surface_extension_color_role(scratchpad_editor_paper_surface_role()),
		key=content_key, label=content_label,
		style=alicorn.layout_style(.Column, grow=1, align=.Start, clip=true),
		material=scratchpad_surface_material(app, app.paper_surface_material),
		physical_height=scratchpad_surface_height(app, -0.75),
		open_top_edge=app.document_connected_tab_node if group_count == 1 else 0,
	)
	_ = content
	if window.focused_group_id == group_id { build_startup_notice(app, ui, rt) }
	switch view.kind {
	case .Editor:
		if document, found := find_document(&app.backend.state, view.resource.id); found {
			if floating_window_contains(app, document.id) {
				if gui.column(ui, label="floating-document-placeholder", height=-1, grow=1, align=.Center, justify=.Center, gap=10) {
					gui.text(ui, "No document open in this window.")
					if gui.button(ui, "Return to tabs", key="floating-document-return-main", width=140, height=32, variant=.Toolbar) {
						floating_window_return_to_tabs(app)
					}
				}
			} else if app.backend.state.active != document.id {
				if gui.column(ui, label="inactive-workbench-editor", height=-1, grow=1, align=.Center, justify=.Center, gap=8) {
					gui.text(ui, document_title(document.path))
					gui.text(ui, "This editor is not active in the shared editing session.")
					if gui.button(ui, "Activate Editor", key=fmt.tprintf("activate-editor-view-%d", u64(view.id)), width=150, height=32, variant=.Toolbar) {
						_ = app_workbench_activate_view(app, rt, view.id)
						alicorn.invalidate_root(rt, "Scratchpad activated an editor view")
					}
				}
			} else if alicorn.component_begin(ui, alicorn.key_string(document.id)) {
				switch document.view_kind {
				case "image":
					editor_accessibility_retire(app, rt)
					build_image_preview(app, ui, rt, document, dpi_scale)
				case "unsupported":
					editor_accessibility_retire(app, rt)
					build_unsupported_file_view(app, ui, document)
				case:
					build_document_editor(app, ui, rt, document)
				}
				alicorn.component_end(ui)
			}
		} else {
			gui.text(ui, "This document is no longer open.")
		}
	case .History:
		app.git_history_graph_node = 0
		app.git_history_list_node = 0
		git_history_build(app, ui, rt, dpi_scale, width)
	case .Diff:
		git_diff_build(app, ui, rt)
	}
	alicorn.surface_end(ui)
	if view.kind == .Editor {
		if document, found := find_document(&app.backend.state, view.resource.id); found && !floating_window_contains(app, document.id) {
			build_document_status(app, ui, rt, document)
		}
	}
	alicorn.container_end(ui)
}

workbench_group_activate_from_pointer :: proc(app: ^App, rt: ^alicorn.Runtime, event: alicorn.Pointer_Event) {
	if app == nil || rt == nil || event.kind != .Down { return }
	window := app_workbench_window(app)
	if window == nil { return }
	for group in window.groups {
		key := alicorn.key_string(fmt.tprintf("workbench-group-%d", u64(group.id)))
		if node, found := alicorn.node_by_key(rt, key, .Container); found {
			info, info_found := alicorn.node_info(rt, node)
			if !info_found { continue }
			if event.x >= info.bounds.x && event.x < info.bounds.x+info.bounds.w &&
			   event.y >= info.bounds.y && event.y < info.bounds.y+info.bounds.h {
				window.focused_group_id = group.id
				return
			}
		}
	}
}

workbench_group_activate_from_focus :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil { return }
	focus := alicorn.focused_node(rt)
	if focus == 0 { return }
	focused, found := alicorn.node_info(rt, focus)
	if !found || focused.bounds.w <= 0 || focused.bounds.h <= 0 { return }
	x := focused.bounds.x+focused.bounds.w*0.5
	y := focused.bounds.y+focused.bounds.h*0.5
	window := app_workbench_window(app)
	if window == nil { return }
	for group in window.groups {
		key := alicorn.key_string(fmt.tprintf("workbench-group-%d", u64(group.id)))
		if node, node_found := alicorn.node_by_key(rt, key, .Container); node_found {
			info, info_found := alicorn.node_info(rt, node)
			if info_found && x >= info.bounds.x && x < info.bounds.x+info.bounds.w &&
			   y >= info.bounds.y && y < info.bounds.y+info.bounds.h {
				window.focused_group_id = group.id
				return
			}
		}
	}
}

workbench_group_split_has_multiple :: proc(app: ^App) -> bool {
	return app_workbench_group_count(app) > 1
}
