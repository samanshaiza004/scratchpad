package main

import "core:fmt"
import "core:mem"
import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"

COMMAND_PALETTE_MAX_VISIBLE_ROWS :: 8
COMMAND_PALETTE_ROW_HEIGHT :: f32(38)

Command_Palette_Result :: struct {
	action_id:   string,
	title:       string,
	category:    string,
	shortcut:   string,
	enabled:     bool,
	score:       int,
	recent_rank: int,
	order:       int,
}

command_palette_ascii_lower :: proc(value: u8) -> u8 {
	if value >= 'A' && value <= 'Z' { return value + ('a'-'A') }
	return value
}

command_palette_ascii_upper :: proc(value: u8) -> u8 {
	if value >= 'a' && value <= 'z' { return value - ('a'-'A') }
	return value
}

command_palette_word_boundary :: proc(previous, current: u8) -> bool {
	previous_alphanumeric :=
		(previous >= 'a' && previous <= 'z') ||
		(previous >= 'A' && previous <= 'Z') ||
		(previous >= '0' && previous <= '9')
	current_alphanumeric :=
		(current >= 'a' && current <= 'z') ||
		(current >= 'A' && current <= 'Z') ||
		(current >= '0' && current <= '9')
	if !previous_alphanumeric { return true }
	if current >= 'A' && current <= 'Z' && previous >= 'a' && previous <= 'z' { return true }
	return !current_alphanumeric
}

// A field score favors complete/prefix/contiguous matches, then falls back to
// a word-boundary-aware subsequence. The command set is small, so this stays
// deterministic and allocation-free while handling typos-in-spacing well.
command_palette_field_score :: proc(query, field: string) -> int {
	if len(query) == 0 || len(field) == 0 { return -1 }
	if len(query) == len(field) {
		equal := true
		for index in 0..<len(query) {
			if command_palette_ascii_lower(query[index]) != command_palette_ascii_lower(field[index]) {
				equal = false
				break
			}
		}
		if equal { return 1200 + len(query)*8 }
	}

	best_contiguous := -1
	for start in 0..<len(field) {
		if command_palette_ascii_lower(field[start]) != command_palette_ascii_lower(query[0]) { continue }
		matched := 0
		for matched < len(query) && start+matched < len(field) &&
		    command_palette_ascii_lower(field[start+matched]) == command_palette_ascii_lower(query[matched]) {
			matched += 1
		}
		if matched != len(query) { continue }
		score := 760 + min(len(query), 24)*8 - start*4
		if start == 0 { score += 120
		} else if command_palette_word_boundary(field[start-1], field[start]) { score += 80 }
		if start+len(query) == len(field) { score += 24 }
		best_contiguous = max(best_contiguous, score)
	}
	if best_contiguous >= 0 { return best_contiguous }

	query_index := 0
	last_match := -2
	score := 180 + min(len(query), 24)*5
	for index in 0..<len(field) {
		if command_palette_ascii_lower(field[index]) != command_palette_ascii_lower(query[query_index]) { continue }
		if index == 0 || command_palette_word_boundary(field[index-1], field[index]) { score += 28 }
		if index == last_match+1 { score += 16
		} else if last_match >= 0 { score -= min(index-last_match-1, 24)*5 }
		score -= index
		last_match = index
		query_index += 1
		if query_index == len(query) { return score }
	}
	return -1
}

command_palette_aliases :: proc(action_id: string) -> string {
	switch action_id {
	case "markdown.toggle-strong": return "bold"
	case "markdown.toggle-emphasis": return "italic italics"
	case "markdown.toggle-inline-code": return "code monospace"
	case "markdown.insert-task": return "checkbox checklist todo"
	case "markdown.toggle-bulleted-list": return "unordered list bullets"
	case "markdown.toggle-numbered-list": return "ordered list numbering"
	case "markdown.toggle-quote": return "blockquote"
	case "workspace.trash": return "delete remove"
	case "workspace.focus-files": return "explorer sidebar tree"
	case "document.toggle-wrap": return "word wrap soft wrap"
	case "document.go-to-line": return "goto jump line number"
	case "edit.undo": return "back"
	case "edit.redo": return "forward"
	case "file.open": return "open file browse"
	case "file.quick-open": return "quick file path picker"
	case "workspace.open": return "open folder project"
	case "file.save": return "write"
	case "edit.select_all": return "select everything"
	case:
		return ""
	}
}

// Queries are split into whitespace-delimited terms; every term must match at
// least one field. This lets "markdown bold", "workspace trash", and shortcut
// queries work without requiring the words to be adjacent in the title.
command_palette_weighted_field_score :: proc(query, field: string, weight: int) -> int {
	score := command_palette_field_score(query, field)
	if score < 0 { return -1 }
	return score + weight
}

command_palette_match_score :: proc(query: string, result: Command_Palette_Result) -> int {
	total := 0
	position := 0
	for position < len(query) {
		for position < len(query) && (query[position] == ' ' || query[position] == '\t' || query[position] == '\n') {
			position += 1
		}
		if position >= len(query) { break }
		start := position
		for position < len(query) && query[position] != ' ' && query[position] != '\t' && query[position] != '\n' {
			position += 1
		}
		term := query[start:position]
		best := -1
		best = max(best, command_palette_weighted_field_score(term, result.title, 360))
		best = max(best, command_palette_weighted_field_score(term, result.action_id, 190))
		best = max(best, command_palette_weighted_field_score(term, result.category, 150))
		best = max(best, command_palette_weighted_field_score(term, result.shortcut, 125))
		binding_label := command_palette_binding_label(result.shortcut)
		best = max(best, command_palette_weighted_field_score(term, binding_label, 140))
		best = max(best, command_palette_weighted_field_score(term, command_palette_aliases(result.action_id), 110))
		if best < 0 { return -1 }
		total += best
	}
	return total
}

command_palette_binding_label :: proc(binding: string) -> string {
	if len(binding) == 0 { return "" }
	label := ""
	start := 0
	for index in 0..=len(binding) {
		if index != len(binding) && binding[index] != '+' { continue }
		token := binding[start:index]
		start = index+1
		if len(token) == 0 { continue }
		mapped := token
		switch token {
		case "primary": mapped = "Ctrl/Cmd"
		case "shift": mapped = "Shift"
		case "alt": mapped = "Alt/Option"
		case "super": mapped = "Super"
		case "arrowup": mapped = "↑"
		case "arrowdown": mapped = "↓"
		case "arrowleft": mapped = "←"
		case "arrowright": mapped = "→"
		case:
			if len(token) == 1 { mapped = fmt.tprintf("%c", command_palette_ascii_upper(token[0]))
			} else { mapped = fmt.tprintf("%c%s", command_palette_ascii_upper(token[0]), token[1:]) }
		}
		if len(label) == 0 { label = mapped
		} else { label = fmt.tprintf("%s+%s", label, mapped) }
	}
	return label
}

command_palette_result_precedes :: proc(left, right: Command_Palette_Result) -> bool {
	if left.enabled != right.enabled { return left.enabled }
	if left.score != right.score { return left.score > right.score }
	if (left.recent_rank >= 0) != (right.recent_rank >= 0) { return left.recent_rank >= 0 }
	if left.recent_rank >= 0 && left.recent_rank != right.recent_rank { return left.recent_rank < right.recent_rank }
	return left.order < right.order
}

command_palette_sort :: proc(results: []Command_Palette_Result) {
	for index in 1..<len(results) {
		item := results[index]
		position := index
		for position > 0 && command_palette_result_precedes(item, results[position-1]) {
			results[position] = results[position-1]
			position -= 1
		}
		results[position] = item
	}
}

command_palette_recent_rank :: proc(action_id: host.Application_Command_ID, recent: []host.Application_Command_ID) -> int {
	for id, index in recent {
		if id == action_id { return index }
	}
	return -1
}

command_palette_menu_binding :: proc(shortcut: host.Application_Menu_Shortcut) -> string {
	if shortcut.key == 0 { return "" }
	binding := ""
	if host.Application_Menu_Modifier.Primary in shortcut.modifiers { binding = "primary" }
	if host.Application_Menu_Modifier.Shift in shortcut.modifiers { binding = command_palette_binding_append(binding, "shift") }
	if host.Application_Menu_Modifier.Alt in shortcut.modifiers { binding = command_palette_binding_append(binding, "alt") }
	if host.Application_Menu_Modifier.Super in shortcut.modifiers { binding = command_palette_binding_append(binding, "super") }
	if len(binding) > 0 { return fmt.tprintf("%s+%c", binding, command_palette_ascii_lower(u8(shortcut.key))) }
	return fmt.tprintf("%c", command_palette_ascii_lower(u8(shortcut.key)))
}

command_palette_binding_append :: proc(binding, modifier: string) -> string {
	if len(binding) == 0 { return modifier }
	return fmt.tprintf("%s+%s", binding, modifier)
}

command_palette_add_or_enrich :: proc(
	results: ^[dynamic]Command_Palette_Result,
	action_id, title, category, shortcut: string,
	enabled: bool,
) {
	if results == nil || action_id == "" || action_id == ACTION_VIEW_COMMAND_PALETTE { return }
	for &result in results^ {
		if result.action_id != action_id { continue }
		result.enabled = enabled
		if result.title == "" { result.title = title }
		if result.category == "" { result.category = category }
		if result.shortcut == "" { result.shortcut = shortcut }
		return
	}
	append(results, Command_Palette_Result{
		action_id=action_id,
		title=title,
		category=category,
		shortcut=shortcut,
		enabled=enabled,
		order=len(results^),
	})
}

command_palette_menu_action_name :: proc(app: ^App, id: host.Application_Command_ID) -> string {
	if app != nil {
		for action in app.backend.state.actions {
			if action_id_for(action.id) == id { return action.id }
		}
	}
	switch id {
	case action_id_for(ACTION_DOCUMENT_GO_TO_LINE): return ACTION_DOCUMENT_GO_TO_LINE
	case action_id_for(ACTION_DOCUMENT_TOGGLE_WRAP): return ACTION_DOCUMENT_TOGGLE_WRAP
	case action_id_for(ACTION_WORKSPACE_SETTINGS): return ACTION_WORKSPACE_SETTINGS
	case action_id_for(ACTION_EDIT_CUT): return ACTION_EDIT_CUT
	case action_id_for(ACTION_EDIT_COPY): return ACTION_EDIT_COPY
	case action_id_for(ACTION_EDIT_PASTE): return ACTION_EDIT_PASTE
	case action_id_for(ACTION_EDIT_SELECT_ALL): return ACTION_EDIT_SELECT_ALL
	case:
		return ""
	}
}

command_palette_collect_results :: proc(app: ^App, allocator: mem.Allocator) -> [dynamic]Command_Palette_Result {
	results := make([dynamic]Command_Palette_Result, 0, allocator=allocator)
	if app == nil { return results }
	for action in app.backend.state.actions {
		if !action.visible { continue }
		shortcut := ""
		if len(action.bindings) > 0 { shortcut = action.bindings[0] }
		command_palette_add_or_enrich(&results, action.id, action.title, action.category, shortcut, action.enabled)
	}
	for menu in app.menus {
		for item in menu.items {
			if item.kind != .Command { continue }
			action_id := command_palette_menu_action_name(app, item.command)
			if action_id == "" { continue }
			binding := command_palette_menu_binding(item.shortcut)
			command_palette_add_or_enrich(&results, action_id, item.label, menu.label, binding, item.state.enabled)
		}
	}
	return results
}

command_palette_filter_results :: proc(
	candidates: []Command_Palette_Result,
	query: string,
	recent: []host.Application_Command_ID,
	allocator: mem.Allocator,
) -> [dynamic]Command_Palette_Result {
	results := make([dynamic]Command_Palette_Result, 0, allocator=allocator)
	for index in 0..<len(candidates) {
		candidate := candidates[index]
		candidate.score = command_palette_match_score(query, candidate)
		if candidate.score < 0 { continue }
		candidate.order = index
		candidate.recent_rank = command_palette_recent_rank(action_id_for(candidate.action_id), recent)
		append(&results, candidate)
	}
	command_palette_sort(results[:])
	return results
}

command_palette_open_surface :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil || app.shutdown_intent != .None || app.close_document_id != "" ||
	   app.workspace_mutation_kind != .None || app.settings_surface_open || app.go_to_line_open {
		return
	}
	if app.command_palette_open {
		command_palette_close_surface(app, rt, true)
		return
	}
	app.command_palette_previous_focus = rt.focused
	app.command_palette_open = true
	app.command_palette_focus_pending = true
	app.command_palette_restore_pending = false
	app.command_palette_node = 0
	app.command_palette_results_scroll_node = 0
	app.command_palette_selected_index = 0
	find_set_message(&app.command_palette_query, "")
	alicorn.invalidate_root(rt, "Scratchpad command palette opened")
}

command_palette_close_surface :: proc(app: ^App, rt: ^alicorn.Runtime, restore_focus: bool) {
	if app == nil { return }
	app.command_palette_open = false
	app.command_palette_focus_pending = false
	app.command_palette_restore_pending = restore_focus
	app.command_palette_node = 0
	app.command_palette_results_scroll_node = 0
	find_set_message(&app.command_palette_query, "")
	if rt != nil { alicorn.invalidate_root(rt, "Scratchpad command palette closed") }
}

command_palette_restore_focus_after_frame :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil { return }
	if app.command_palette_open && app.command_palette_focus_pending && app.command_palette_node != 0 {
		if alicorn.focus(rt, app.command_palette_node) {
			app.command_palette_focus_pending = false
			if node, found := rt.nodes[app.command_palette_node]; found && node.kind == .Text_Field {
				_ = alicorn.set_text_selection(rt, app.command_palette_node, 0, len(node.text))
			}
		}
	}
	if !app.command_palette_restore_pending { return }
	app.command_palette_restore_pending = false
	focus := app.command_palette_previous_focus
	app.command_palette_previous_focus = 0
	if focus != 0 {
		if _, found := rt.nodes[focus]; found { _ = alicorn.focus(rt, focus) }
	}
}

command_palette_recent_add :: proc(app: ^App, id: host.Application_Command_ID) {
	if app == nil || id == 0 { return }
	new_recent: [8]host.Application_Command_ID
	new_recent[0] = id
	count := 1
	for old in app.command_palette_recent[:app.command_palette_recent_count] {
		if old == id { continue }
		if count >= len(new_recent) { break }
		new_recent[count] = old
		count += 1
	}
	app.command_palette_recent = new_recent
	app.command_palette_recent_count = count
}

command_palette_execute :: proc(app: ^App, rt: ^alicorn.Runtime, result: Command_Palette_Result, from_build := false) -> bool {
	if app == nil || rt == nil || !result.enabled { return false }
	id := action_id_for(result.action_id)
	command_palette_recent_add(app, id)
	command_palette_close_surface(app, rt, true)
	if from_build {
		if !frame_deferred_action_schedule(app, .Action, result.action_id) {
			set_error(app, "Could not queue the command palette action until this frame completes.")
			return false
		}
	} else {
		application_menu_command(rawptr(app), rt, id)
	}
	return true
}

command_palette_move_selection :: proc(app: ^App, rt: ^alicorn.Runtime, delta: int) -> bool {
	if app == nil || rt == nil || !app.command_palette_open { return false }
	results := command_palette_collect_results(app, context.temp_allocator)
		defer delete(results)
	filtered := command_palette_filter_results(results[:], app.command_palette_query, app.command_palette_recent[:app.command_palette_recent_count], context.temp_allocator)
		defer delete(filtered)
	if len(filtered) > 0 {
		next := app.command_palette_selected_index+delta
		for next >= 0 && next < len(filtered) {
			if filtered[next].enabled {
				app.command_palette_selected_index = next
				break
			}
			next += delta
		}
		if app.command_palette_results_scroll_node != 0 {
			_ = alicorn.virtual_list_ensure_visible(
				rt,
				app.command_palette_results_scroll_node,
				app.command_palette_selected_index,
				"Scratchpad command palette selection visibility",
			)
		}
	}
	alicorn.invalidate_root(rt, "Scratchpad command palette selection moved")
	return true
}

command_palette_execute_selected :: proc(app: ^App, rt: ^alicorn.Runtime) -> bool {
	if app == nil || rt == nil || !app.command_palette_open { return false }
	results := command_palette_collect_results(app, context.temp_allocator)
	defer delete(results)
	filtered := command_palette_filter_results(results[:], app.command_palette_query, app.command_palette_recent[:app.command_palette_recent_count], context.temp_allocator)
	defer delete(filtered)
	if app.command_palette_selected_index < 0 || app.command_palette_selected_index >= len(filtered) { return true }
	if !filtered[app.command_palette_selected_index].enabled { return true }
	return command_palette_execute(app, rt, filtered[app.command_palette_selected_index])
}

command_palette_text_change :: proc(state: rawptr, rt: ^alicorn.Runtime, change: alicorn.Text_Change) {
	quick_open_text_change(state, rt, change)
	app := cast(^App)state
	if app == nil || rt == nil || !app.command_palette_open || change.node != app.command_palette_node || !change.changed { return }
	find_set_message(&app.command_palette_query, change.text)
	app.command_palette_selected_index = 0
	alicorn.invalidate_root(rt, "Scratchpad command palette query changed")
}

command_palette_build :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime) {
	if app == nil || ui == nil || rt == nil || !app.command_palette_open { return }
	results := command_palette_collect_results(app, rt.scratch_allocator)
	defer delete(results)
	filtered := command_palette_filter_results(results[:], app.command_palette_query, app.command_palette_recent[:app.command_palette_recent_count], rt.scratch_allocator)
	defer delete(filtered)
	if len(filtered) == 0 { app.command_palette_selected_index = 0
	} else { app.command_palette_selected_index = clamp(app.command_palette_selected_index, 0, len(filtered)-1) }
	visible_rows := min(max(len(filtered), 1), COMMAND_PALETTE_MAX_VISIBLE_ROWS)
	results_height := f32(visible_rows)*COMMAND_PALETTE_ROW_HEIGHT
	panel_height := f32(24+40+16+20)+results_height
	app.command_palette_overlay_node = alicorn.modal_overlay_begin(
		ui,
		alicorn.key_string("scratchpad-command-palette-overlay"),
		style=alicorn.layout_style(.Column, grow=1, padding=48, align=.Center, clip=true),
		backdrop_color=alicorn.Color{0.015, 0.02, 0.03, 0.72},
	)
	app.command_palette_panel_node = alicorn.container_begin(
		ui,
		.Container,
		label="scratchpad-command-palette-panel",
		key=alicorn.key_string("scratchpad-command-palette-panel"),
		style=alicorn.layout_style(.Column, max_width=760, height=panel_height, padding=12, gap=8, clip=true),
		color=COLOR_PANEL,
	)
	alicorn.container_begin(ui, .Container, label="scratchpad-command-palette-query-row", style=alicorn.layout_style(.Row, height=40, gap=8, align=.Center))
	alicorn.text(ui, ">", style=alicorn.layout_style(.Row, width=18, height=36), text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_SEMIBOLD})
	app.command_palette_node = alicorn.text_field(
		ui,
		app.command_palette_query,
		key=alicorn.key_string("scratchpad-command-palette-query"),
		style=alicorn.layout_style(.Row, grow=1, height=38),
		text_style=alicorn.Text_Style{overflow=.Ellipsis},
	)
	alicorn.container_end(ui)
	if len(filtered) == 0 {
		alicorn.text(ui, "No matching commands", style=alicorn.layout_style(.Row, height=COMMAND_PALETTE_ROW_HEIGHT, padding=8))
	} else {
		list := alicorn.virtual_list_begin(
			ui,
			len(filtered),
			COMMAND_PALETTE_ROW_HEIGHT,
			key=alicorn.key_string("scratchpad-command-palette-results"),
			style=alicorn.layout_style(height=results_height, clip=true),
			label="scratchpad-command-palette-results",
		)
		app.command_palette_results_scroll_node = list.scroll.id
		for index := list.first; index < list.last; index += 1 {
			result := filtered[index]
			label := result.title
			if result.category != "" { label = fmt.tprintf("%s  ·  %s", label, result.category) }
			if result.shortcut != "" { label = fmt.tprintf("%s     %s", label, command_palette_binding_label(result.shortcut)) }
			if !result.enabled { label = fmt.tprintf("%s  ·  Unavailable here", label) }
			if alicorn.button(
				ui,
				label,
				key=alicorn.key_string(result.action_id),
				state=alicorn.Button_State{selected=index == app.command_palette_selected_index, disabled=!result.enabled, quiet=index != app.command_palette_selected_index},
				style=alicorn.layout_style(.Row, height=COMMAND_PALETTE_ROW_HEIGHT),
				text_style=alicorn.Text_Style{overflow=.Ellipsis},
				content_style=alicorn.button_content_style(horizontal=.Start, vertical=.Center, padding_x=10, padding_y=5),
			) {
				_ = command_palette_execute(app, rt, result, true)
			}
		}
		alicorn.virtual_list_end(ui, list)
	}
	alicorn.text(ui, fmt.tprintf("%d commands  ·  ↑/↓ navigate  ·  Enter run  ·  Esc close", len(filtered)), style=alicorn.layout_style(.Row, height=20))
	alicorn.container_end(ui)
	alicorn.modal_overlay_end(ui)
}

command_palette_pointer :: proc(app: ^App, rt: ^alicorn.Runtime, event: alicorn.Pointer_Event, target: alicorn.Node_ID) -> bool {
	if app == nil || rt == nil || !app.command_palette_open { return false }
	if event.kind == .Down && event.button == alicorn.POINTER_BUTTON_PRIMARY && target == app.command_palette_overlay_node {
		panel, found := rt.nodes[app.command_palette_panel_node]
		inside := found && event.x >= panel.bounds.x && event.x < panel.bounds.x+panel.bounds.w &&
		         event.y >= panel.bounds.y && event.y < panel.bounds.y+panel.bounds.h
		if !inside { command_palette_close_surface(app, rt, true) }
		return true
	}
	return true
}
