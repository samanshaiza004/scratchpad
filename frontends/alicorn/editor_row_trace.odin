package main

// This opt-in observer is the one frontend diagnostic allowed to read
// Alicorn's retained presentation internals. It only hashes runtime state;
// normal editor behavior does not depend on the trace being enabled.

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import alicorn "alicorn:runtime"

EDITOR_ROW_TRACE_MAX_BUILDS :: 128
EDITOR_ROW_TRACE_MAX_ROWS_PER_BUILD :: 512
EDITOR_ROW_TRACE_MAX_RECORDS :: EDITOR_ROW_TRACE_MAX_BUILDS*EDITOR_ROW_TRACE_MAX_ROWS_PER_BUILD

Editor_Row_Trace_Change :: enum u8 {
	Text,
	Style,
	Geometry,
	Paint,
}

Editor_Row_Trace_Changes :: distinct bit_set[Editor_Row_Trace_Change; u8]

Editor_Row_Trace_Fingerprints :: struct {
	text:     u64,
	style:    u64,
	geometry: u64,
	paint:    u64,
}

Editor_Row_Trace_Previous :: struct {
	document_hash: u64,
	row_node:      alicorn.Node_ID,
	text_node:     alicorn.Node_ID,
	logical_line:  u64,
	cell_index:    int,
	fingerprints:  Editor_Row_Trace_Fingerprints,
}

Editor_Row_Trace_Record :: struct {
	build:                u64,
	document_hash:        u64,
	editor_revision:      u64,
	presentation_revision: u64,
	logical_line:         u64,
	row_node:             alicorn.Node_ID,
	text_node:            alicorn.Node_ID,
	cell_index:           int,
	compared_previous:    bool,
	fingerprints:         Editor_Row_Trace_Fingerprints,
	changes:              Editor_Row_Trace_Changes,
}

Editor_Row_Trace_State :: struct {
	path:            string,
	allocator:       mem.Allocator,
	previous:        [dynamic]Editor_Row_Trace_Previous,
	next:            [dynamic]Editor_Row_Trace_Previous,
	records:         [dynamic]Editor_Row_Trace_Record,
	build_count:     int,
	dropped_rows:    u64,
	limit_reached:   bool,
}

editor_row_trace_init :: proc(trace: ^Editor_Row_Trace_State, path: string, allocator := context.allocator) -> bool {
	if trace == nil || len(path) == 0 { return false }
	path_copy, clone_error := strings.clone(path, allocator)
	if clone_error != nil { return false }
	trace^ = Editor_Row_Trace_State{
		path=path_copy,
		allocator=allocator,
		previous=make([dynamic]Editor_Row_Trace_Previous, 0, EDITOR_ROW_TRACE_MAX_ROWS_PER_BUILD, allocator=allocator),
		next=make([dynamic]Editor_Row_Trace_Previous, 0, EDITOR_ROW_TRACE_MAX_ROWS_PER_BUILD, allocator=allocator),
		records=make([dynamic]Editor_Row_Trace_Record, 0, EDITOR_ROW_TRACE_MAX_RECORDS, allocator=allocator),
	}
	return true
}

editor_row_trace_mix_f32 :: proc(hash: u64, value: f32) -> u64 {
	return editor_wrap_fingerprint_mix(hash, u64(transmute(u32)value))
}

editor_row_trace_mix_color :: proc(hash: u64, color: alicorn.Color) -> u64 {
	result := editor_row_trace_mix_f32(hash, color.r)
	result = editor_row_trace_mix_f32(result, color.g)
	result = editor_row_trace_mix_f32(result, color.b)
	return editor_row_trace_mix_f32(result, color.a)
}

editor_row_trace_mix_rect :: proc(hash: u64, rect: alicorn.Rect) -> u64 {
	result := editor_row_trace_mix_f32(hash, rect.x)
	result = editor_row_trace_mix_f32(result, rect.y)
	result = editor_row_trace_mix_f32(result, rect.w)
	return editor_row_trace_mix_f32(result, rect.h)
}

editor_row_trace_mix_text_paint_span :: proc(hash: u64, span: alicorn.Text_Paint_Span) -> u64 {
	result := editor_wrap_fingerprint_mix(hash, u64(max(span.start, 0)))
	result = editor_wrap_fingerprint_mix(result, u64(max(span.end, 0)))
	result = editor_wrap_fingerprint_bool(result, span.color_set)
	result = editor_row_trace_mix_color(result, span.color)
	result = editor_wrap_fingerprint_bool(result, span.background_set)
	result = editor_row_trace_mix_color(result, span.background)
	result = editor_wrap_fingerprint_bool(result, span.underline)
	return editor_wrap_fingerprint_bool(result, span.strikethrough)
}

editor_row_trace_mix_text_style_span :: proc(hash: u64, span: alicorn.Text_Style_Span) -> u64 {
	result := editor_wrap_fingerprint_mix(hash, u64(max(span.start, 0)))
	result = editor_wrap_fingerprint_mix(result, u64(max(span.end, 0)))
	result = editor_row_trace_mix_f32(result, span.font_weight)
	result = editor_wrap_fingerprint_bool(result, span.font_weight_set)
	result = editor_wrap_fingerprint_bool(result, span.italic)
	return editor_wrap_fingerprint_bool(result, span.italic_set)
}

editor_row_trace_find_root :: proc(rt: ^alicorn.Runtime, text_node: alicorn.Node_ID) -> alicorn.Node_ID {
	if rt == nil { return 0 }
	current := text_node
	for _ in 0..<64 {
		node, found := rt.nodes[current]
		if !found || node == nil { return text_node }
		if node.label == "scratchpad-editor-logical-line" || node.label == "scratchpad-table-visual-row" {
			return current
		}
		if node.parent == 0 { break }
		current = node.parent
	}
	return text_node
}

editor_row_trace_node_in_subtree :: proc(rt: ^alicorn.Runtime, node_id, root_id: alicorn.Node_ID) -> bool {
	if rt == nil || node_id == 0 || root_id == 0 { return false }
	current := node_id
	for _ in 0..<64 {
		if current == root_id { return true }
		node, found := rt.nodes[current]
		if !found || node == nil || node.parent == 0 { return false }
		current = node.parent
	}
	return false
}

editor_row_trace_style_node :: proc(hash: u64, node: ^alicorn.Node) -> u64 {
	if node == nil { return hash }
	result := editor_wrap_fingerprint_mix(hash, u64(node.kind))
	result = editor_wrap_fingerprint_mix(result, u64(node.font))
	result = editor_row_trace_mix_f32(result, node.text_style.font_weight)
	result = editor_row_trace_mix_f32(result, node.text_style.font_size)
	result = editor_wrap_fingerprint_mix(result, u64(node.text_style.overflow))
	result = editor_wrap_fingerprint_mix(result, u64(u32(node.style_environment.theme)))
	result = editor_row_trace_mix_f32(result, node.style_environment.density)
	result = editor_row_trace_mix_f32(result, node.style_environment.text_scale)
	result = editor_wrap_fingerprint_mix(result, u64(node.style_environment.accent))
	result = editor_wrap_fingerprint_bool(result, node.style_environment.accessibility_set)
	result = editor_wrap_fingerprint_bool(result, node.style_environment.accessibility.increased_contrast)
	result = editor_wrap_fingerprint_bool(result, node.style_environment.accessibility.reduce_motion)
	result = editor_wrap_fingerprint_bool(result, node.style_environment.accessibility.reduce_transparency)
	result = editor_wrap_fingerprint_bool(result, node.style_environment.accessibility.differentiate_without_color)
	result = editor_wrap_fingerprint_mix(result, u64(len(node.text_style_spans)))
	for span in node.text_style_spans { result = editor_row_trace_mix_text_style_span(result, span) }
	if node.text_run_valid {
		result = editor_wrap_fingerprint_bool(result, true)
		result = editor_wrap_fingerprint_mix(result, node.text_run.font_generation)
		result = editor_wrap_fingerprint_mix(result, node.text_run.style_hash)
		result = editor_row_trace_mix_f32(result, node.text_run.size)
		result = editor_row_trace_mix_f32(result, node.text_run.max_width)
		result = editor_wrap_fingerprint_mix(result, u64(node.text_run.font))
		result = editor_wrap_fingerprint_mix(result, u64(node.text_run.font_source))
		result = editor_row_trace_mix_f32(result, node.text_run.font_weight)
	} else {
		result = editor_wrap_fingerprint_bool(result, false)
	}
	return result
}

editor_row_trace_paint_command :: proc(hash: u64, command: alicorn.Paint_Command) -> u64 {
	result := editor_row_trace_mix_rect(hash, command.bounds)
	result = editor_row_trace_mix_rect(result, command.clip)
	result = editor_row_trace_mix_f32(result, command.opacity)
	result = editor_row_trace_mix_f32(result, command.translation[0])
	result = editor_row_trace_mix_f32(result, command.translation[1])
	result = editor_wrap_fingerprint_mix(result, u64(command.stroke_placement))
	switch payload in command.payload {
	case alicorn.Surface_Paint:
		result = editor_wrap_fingerprint_mix(result, u64(payload.shape.kind))
		result = editor_row_trace_mix_f32(result, payload.shape.corner_radius)
		result = editor_row_trace_mix_color(result, payload.fill)
		result = editor_row_trace_mix_color(result, payload.stroke.color)
		result = editor_row_trace_mix_f32(result, payload.stroke.width)
		result = editor_wrap_fingerprint_mix(result, u64(u32(payload.material)))
		result = editor_row_trace_mix_f32(result, payload.physical_height)
		result = editor_wrap_fingerprint_mix(result, u64(u32(payload.material_group)))
		result = editor_row_trace_mix_f32(result, payload.top_edge_gap[0])
		result = editor_row_trace_mix_f32(result, payload.top_edge_gap[1])
	case alicorn.Backdrop_Effect_Paint:
		result = editor_row_trace_mix_f32(result, payload.sigma)
		result = editor_wrap_fingerprint_mix(result, u64(payload.fallback))
	case alicorn.Icon_Paint:
		result = editor_wrap_fingerprint_mix(result, u64(payload.id))
		result = editor_row_trace_mix_color(result, payload.color)
	case alicorn.Image_Paint:
		result = editor_wrap_fingerprint_mix(result, u64(payload.image))
	case alicorn.Text_Paint:
		result = editor_wrap_fingerprint_mix(result, u64(payload.run.source))
		result = editor_wrap_fingerprint_mix(result, payload.run.resource)
		result = editor_wrap_fingerprint_mix(result, payload.run.generation)
		result = editor_row_trace_mix_color(result, payload.color)
		result = editor_wrap_fingerprint_mix(result, u64(len(payload.spans)))
		for span in payload.spans { result = editor_row_trace_mix_text_paint_span(result, span) }
	case alicorn.Geometry_Paint:
		result = editor_wrap_fingerprint_mix(result, u64(payload.geometry.resource))
		result = editor_wrap_fingerprint_mix(result, payload.geometry.generation)
	}
	return result
}

editor_row_trace_fingerprints :: proc(
	rt: ^alicorn.Runtime,
	target: Editor_Row_Target,
) -> (fingerprints: Editor_Row_Trace_Fingerprints, row_node: alicorn.Node_ID, found: bool) {
	if rt == nil || target.node == 0 { return }
	text_node, text_found := rt.nodes[target.node]
	if !text_found || text_node == nil { return }
	row_node = editor_row_trace_find_root(rt, target.node)
	if row_node == 0 { return }
	row_found := false
	row_found = row_node != target.node
	if _, exists := rt.nodes[row_node]; exists { row_found = true }
	if !row_found { return }
	found = true

	text_hash := u64(14695981039346656037)
	text_hash = editor_wrap_fingerprint_bytes(text_hash, text_node.text)
	text_hash = editor_wrap_fingerprint_mix(text_hash, u64(len(text_node.text)))
	text_hash = editor_wrap_fingerprint_mix(text_hash, target.logical_line)
	text_hash = editor_wrap_fingerprint_mix(text_hash, target.cell_start)
	text_hash = editor_wrap_fingerprint_mix(text_hash, target.cell_end)
	text_hash = editor_wrap_fingerprint_mix(text_hash, u64(max(target.cell_index, 0)))
	text_hash = editor_wrap_fingerprint_bool(text_hash, target.is_cell)
	text_hash = editor_wrap_fingerprint_bool(text_hash, target.is_segment)
	fingerprints.text = text_hash

	style_hash := u64(14695981039346656037)
	geometry_hash := u64(14695981039346656037)
	paint_hash := u64(14695981039346656037)
	for node_id in rt.order {
		if !editor_row_trace_node_in_subtree(rt, node_id, row_node) { continue }
		node, node_found := rt.nodes[node_id]
		if !node_found || node == nil { continue }
		style_hash = editor_wrap_fingerprint_mix(style_hash, u64(node.kind))
		style_hash = editor_row_trace_style_node(style_hash, node)
		geometry_hash = editor_wrap_fingerprint_mix(geometry_hash, u64(node.kind))
		geometry_hash = editor_row_trace_mix_rect(geometry_hash, node.bounds)
		geometry_hash = editor_row_trace_mix_rect(geometry_hash, node.hit_bounds)
		geometry_hash = editor_row_trace_mix_rect(geometry_hash, node.clip)
		paint_hash = editor_wrap_fingerprint_mix(paint_hash, u64(node.kind))
		paint_hash = editor_wrap_fingerprint_mix(paint_hash, node.paint_hash)
		paint_hash = editor_wrap_fingerprint_bool(paint_hash, node.paint_background)
		paint_hash = editor_row_trace_mix_color(paint_hash, node.color)
		paint_hash = editor_wrap_fingerprint_bool(paint_hash, node.active)
		paint_hash = editor_wrap_fingerprint_bool(paint_hash, node.selected)
		paint_hash = editor_wrap_fingerprint_bool(paint_hash, node.hovered)
		paint_hash = editor_wrap_fingerprint_bool(paint_hash, node.pressed)
		paint_hash = editor_wrap_fingerprint_bool(paint_hash, node.text_interaction_show_caret)
		paint_hash = editor_wrap_fingerprint_mix(paint_hash, u64(len(node.text_paint_spans)))
		for span in node.text_paint_spans { paint_hash = editor_row_trace_mix_text_paint_span(paint_hash, span) }
		geometry_hash = editor_row_trace_mix_f32(geometry_hash, node.text_run.width if node.text_run_valid else 0)
		geometry_hash = editor_row_trace_mix_f32(geometry_hash, node.text_run.height if node.text_run_valid else 0)
	}
	for command in rt.display {
		if editor_row_trace_node_in_subtree(rt, command.owner, row_node) {
			paint_hash = editor_row_trace_paint_command(paint_hash, command)
		}
	}
	fingerprints.style = style_hash
	fingerprints.geometry = geometry_hash
	fingerprints.paint = paint_hash
	return
}

editor_row_trace_changed :: proc(previous, current: Editor_Row_Trace_Fingerprints) -> Editor_Row_Trace_Changes {
	changes: Editor_Row_Trace_Changes
	if previous.text != current.text { changes += {.Text} }
	if previous.style != current.style { changes += {.Style} }
	if previous.geometry != current.geometry { changes += {.Geometry} }
	if previous.paint != current.paint { changes += {.Paint} }
	return changes
}

editor_row_trace_capture :: proc(
	trace: ^Editor_Row_Trace_State,
	rt: ^alicorn.Runtime,
	rows: []Editor_Row_Target,
	document_id: string,
	editor_revision, presentation_revision: u64,
) {
	if trace == nil || trace.path == "" || rt == nil { return }
	if trace.build_count >= EDITOR_ROW_TRACE_MAX_BUILDS || len(trace.records) >= EDITOR_ROW_TRACE_MAX_RECORDS {
		trace.limit_reached = true
		return
	}
	trace.build_count += 1
	build := u64(trace.build_count)
	document_hash := editor_wrap_fingerprint_bytes(u64(14695981039346656037), document_id)
	clear(&trace.next)
	for target, row_index in rows {
		if row_index >= EDITOR_ROW_TRACE_MAX_ROWS_PER_BUILD || len(trace.records) >= EDITOR_ROW_TRACE_MAX_RECORDS {
			trace.dropped_rows += 1
			trace.limit_reached = true
			continue
		}
		fingerprints, row_node, found := editor_row_trace_fingerprints(rt, target)
		if !found { continue }
		previous_fingerprints: Editor_Row_Trace_Fingerprints
		previous_found := false
		for previous in trace.previous {
			if previous.document_hash == document_hash && previous.row_node == row_node &&
			   previous.text_node == target.node && previous.logical_line == target.logical_line &&
			   previous.cell_index == target.cell_index {
				previous_fingerprints = previous.fingerprints
				previous_found = true
				break
			}
		}
		changes: Editor_Row_Trace_Changes
		if previous_found { changes = editor_row_trace_changed(previous_fingerprints, fingerprints) }
		append(&trace.records, Editor_Row_Trace_Record{
			build=build,
			document_hash=document_hash,
			editor_revision=editor_revision,
			presentation_revision=presentation_revision,
			logical_line=target.logical_line,
			row_node=row_node,
			text_node=target.node,
			cell_index=target.cell_index,
			compared_previous=previous_found,
			fingerprints=fingerprints,
			changes=changes,
		})
		append(&trace.next, Editor_Row_Trace_Previous{
			document_hash=document_hash,
			row_node=row_node,
			text_node=target.node,
			logical_line=target.logical_line,
			cell_index=target.cell_index,
			fingerprints=fingerprints,
		})
	}
	trace.previous, trace.next = trace.next, trace.previous
	clear(&trace.next)
}

editor_row_trace_finish :: proc(trace: ^Editor_Row_Trace_State) {
	if trace == nil || trace.path == "" { return }
	sb := strings.builder_make(0, max(1024, len(trace.records)*160), context.temp_allocator)
	fmt.sbprintf(&sb,
		"# scratchpad-editor-row-trace-v1 builds=%d rows=%d dropped_rows=%d limit_reached=%t\n",
		trace.build_count, len(trace.records), trace.dropped_rows, trace.limit_reached)
	fmt.sbprintf(&sb, "# Records compare retained row inputs after app description builds; compared_previous=false marks a baseline/new row. This is not a GPU-presented-frame or pixel capture.\n")
	fmt.sbprintf(&sb,
		"build\tdocument_hash\teditor_revision\tpresentation_revision\tlogical_line\trow_node\ttext_node\tcell_index\tcompared_previous\ttext_fp\tstyle_fp\tgeometry_fp\tpaint_fp\ttext_changed\tstyle_changed\tgeometry_changed\tpaint_changed\n")
	for record in trace.records {
		fmt.sbprintf(&sb,
			"%d\t%016x\t%d\t%d\t%d\t%d\t%d\t%d\t%t\t%016x\t%016x\t%016x\t%016x\t%t\t%t\t%t\t%t\n",
			record.build, record.document_hash, record.editor_revision, record.presentation_revision,
			record.logical_line, u64(record.row_node), u64(record.text_node), record.cell_index, record.compared_previous,
			record.fingerprints.text, record.fingerprints.style, record.fingerprints.geometry,
			record.fingerprints.paint, Editor_Row_Trace_Change.Text in record.changes,
			Editor_Row_Trace_Change.Style in record.changes, Editor_Row_Trace_Change.Geometry in record.changes,
			Editor_Row_Trace_Change.Paint in record.changes)
	}
	contents := strings.to_string(sb)
	if write_error := os.write_entire_file_from_string(trace.path, contents); write_error != nil {
		fmt.eprintln("Scratchpad editor row trace write failed:", write_error)
	} else {
		fmt.eprintln("Scratchpad editor row trace:", trace.path, "builds", trace.build_count, "rows", len(trace.records), "dropped", trace.dropped_rows)
	}
	editor_row_trace_release(trace)
}

editor_row_trace_release :: proc(trace: ^Editor_Row_Trace_State) {
	if trace == nil { return }
	delete(trace.previous)
	delete(trace.next)
	delete(trace.records)
	if trace.path != "" { delete(trace.path, trace.allocator) }
	trace^ = {}
}
