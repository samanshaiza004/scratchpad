package main

import alicorn "alicorn:runtime"
import bridge "./bridge"

Git_DAG_Node :: struct {
	lane: int,
	missing_parent_count: int,
}

Git_DAG_Edge :: struct {
	child_row, child_lane: int,
	parent_row, parent_lane: int,
}

Git_DAG_Layout :: struct {
	nodes: [dynamic]Git_DAG_Node,
	edges: [dynamic]Git_DAG_Edge,
	lane_count: int,
}

git_dag_destroy :: proc(layout: ^Git_DAG_Layout) {
	if layout == nil { return }
	delete(layout.nodes)
	delete(layout.edges)
	layout^ = {}
}

// Lane assignment follows the full history snapshot, so filtering never
// invents parent edges or changes the graph's branch topology.
git_dag_layout :: proc(commits: []bridge.Git_Commit) -> Git_DAG_Layout {
	layout := Git_DAG_Layout{}
	layout.nodes = make([dynamic]Git_DAG_Node, 0, len(commits), allocator=context.temp_allocator)
	layout.edges = make([dynamic]Git_DAG_Edge, 0, allocator=context.temp_allocator)
	for _ in commits { append(&layout.nodes, Git_DAG_Node{}) }
	if len(commits) == 0 { return layout }

	row_by_hash := make(map[string]int, allocator=context.temp_allocator)
	pending_lane_by_hash := make(map[string]int, allocator=context.temp_allocator)
	seen_parent_row := make(map[string]int, allocator=context.temp_allocator)
	lane_busy := make([dynamic]bool, 0, len(commits), allocator=context.temp_allocator)
	free_lanes := make([dynamic]int, 0, len(commits), allocator=context.temp_allocator)
	defer {
		delete(row_by_hash)
		delete(pending_lane_by_hash)
		delete(seen_parent_row)
		delete(lane_busy)
		delete(free_lanes)
	}

	for commit, row in commits {
		if _, exists := row_by_hash[commit.hash]; !exists {
			row_by_hash[commit.hash] = row
		}
	}

	for commit, row in commits {
		current_lane: int
		if lane, pending := pending_lane_by_hash[commit.hash]; pending {
			current_lane = lane
			delete_key(&pending_lane_by_hash, commit.hash)
			lane_busy[current_lane] = false
		} else if len(free_lanes) > 0 {
			current_lane = pop(&free_lanes)
			lane_busy[current_lane] = true
		} else {
			current_lane = len(lane_busy)
			append(&lane_busy, true)
		}
		layout.nodes[row].lane = current_lane
		lane_busy[current_lane] = false

		for parent_hash, parent_ordinal in commit.parents {
			if previous_row, seen := seen_parent_row[parent_hash]; seen && previous_row == row { continue }
			seen_parent_row[parent_hash] = row
			parent_row, present := row_by_hash[parent_hash]
			if !present {
				layout.nodes[row].missing_parent_count += 1
				continue
			}
			if parent_row == row { continue }

			parent_lane: int
			if parent_row < row {
				parent_lane = layout.nodes[parent_row].lane
			} else if lane, pending := pending_lane_by_hash[parent_hash]; pending {
				parent_lane = lane
			} else {
				if parent_ordinal == 0 && !lane_busy[current_lane] {
					parent_lane = current_lane
					lane_busy[parent_lane] = true
				} else if len(free_lanes) > 0 {
					parent_lane = pop(&free_lanes)
					lane_busy[parent_lane] = true
				} else {
					parent_lane = len(lane_busy)
					append(&lane_busy, true)
				}
				pending_lane_by_hash[parent_hash] = parent_lane
			}
			append(&layout.edges, Git_DAG_Edge{row, current_lane, parent_row, parent_lane})
		}
		if !lane_busy[current_lane] { append(&free_lanes, current_lane) }
	}
	layout.lane_count = len(lane_busy)
	return layout
}

git_dag_lane_color :: proc(lane: int) -> alicorn.Color {
	switch lane % 6 {
	case 0: return alicorn.Color{0.28, 0.78, 0.96, 1}
	case 1: return alicorn.Color{0.98, 0.66, 0.30, 1}
	case 2: return alicorn.Color{0.43, 0.84, 0.56, 1}
	case 3: return alicorn.Color{0.76, 0.58, 0.98, 1}
	case 4: return alicorn.Color{0.98, 0.47, 0.53, 1}
	case 5: return alicorn.Color{0.91, 0.82, 0.38, 1}
	}
	return alicorn.Color{0.65, 0.72, 0.82, 1}
}

git_dag_lane_x :: proc(lane, lane_count: int, width: f32) -> f32 {
	lanes := max(1, lane_count)
	usable := max(1, width-12)
	pitch := min(13, usable/f32(lanes))
	return 6 + f32(lane)*pitch + pitch*0.5
}

git_dag_can_append :: proc(
	segments: [dynamic]alicorn.GPU_Surface_Line_Segment,
	circles: [dynamic]alicorn.GPU_Surface_Filled_Circle,
	add_segment, add_circle: bool,
) -> bool {
	segment_count, circle_count := len(segments), len(circles)
	if add_segment { segment_count += 1 }
	if add_circle { circle_count += 1 }
	return segment_count*6 + circle_count*alicorn.GPU_SURFACE_CIRCLE_SEGMENTS*3 <= alicorn.GPU_SURFACE_MAX_VERTICES
}

git_dag_append_segment :: proc(
	segments: ^[dynamic]alicorn.GPU_Surface_Line_Segment,
	circles: [dynamic]alicorn.GPU_Surface_Filled_Circle,
	start, end: alicorn.GPU_Surface_Point,
	color: alicorn.Color,
) -> bool {
	if !git_dag_can_append(segments^, circles, true, false) { return false }
	append(segments, alicorn.GPU_Surface_Line_Segment{start=start, end=end, thickness=1.5, color=color})
	return true
}

git_dag_build_geometry :: proc(
	layout: Git_DAG_Layout,
	commits: []bridge.Git_Commit,
	visible: []int,
	first, last: int,
	row_height, width: f32,
	selected_index: int,
	filtered: bool,
	segments: ^[dynamic]alicorn.GPU_Surface_Line_Segment,
	circles: ^[dynamic]alicorn.GPU_Surface_Filled_Circle,
) {
	clear(segments)
	clear(circles)
	if row_height <= 0 || width <= 0 || first < 0 || last <= first || first >= len(visible) { return }
	visible_last := min(last, len(visible))
	if visible_last <= first { return }
	lane_count := max(layout.lane_count, 1)
	usable := max(1, width-12)
	lane_pitch := min(13, usable/f32(lane_count))
	radius := max(1.0, min(4.0, lane_pitch*0.34))

	for position := first; position < visible_last; position += 1 {
		commit_index := visible[position]
		if commit_index < 0 || commit_index >= len(commits) { continue }
		lane := 0
		if !filtered && commit_index < len(layout.nodes) { lane = layout.nodes[commit_index].lane }
		color := git_dag_lane_color(lane)
		marker_radius := radius
		if commit_index == selected_index {
			color = alicorn.Color{0.96, 0.96, 1, 1}
			marker_radius = max(radius, 4.5)
		}
		if git_dag_can_append(segments^, circles^, false, true) {
			append(circles, alicorn.GPU_Surface_Filled_Circle{
				center=alicorn.GPU_Surface_Point{
					x=git_dag_lane_x(lane, lane_count, width),
					y=f32(position-first)*row_height+row_height*0.5,
				},
				radius=marker_radius,
				color=color,
			})
		}
	}
	if filtered { return }

	for edge in layout.edges {
		if edge.child_row < 0 || edge.parent_row < 0 || edge.child_row >= len(layout.nodes) || edge.parent_row >= len(layout.nodes) { continue }
		low_row, high_row := min(edge.child_row, edge.parent_row), max(edge.child_row, edge.parent_row)
		if low_row >= visible_last || high_row < first { continue }
		child_x := git_dag_lane_x(edge.child_lane, lane_count, width)
		parent_x := git_dag_lane_x(edge.parent_lane, lane_count, width)
		child_y := f32(edge.child_row-first)*row_height+row_height*0.5
		parent_y := f32(edge.parent_row-first)*row_height+row_height*0.5
		color := git_dag_lane_color(edge.child_lane)
		if child_x == parent_x {
			_ = git_dag_append_segment(segments, circles^,
				alicorn.GPU_Surface_Point{child_x, child_y}, alicorn.GPU_Surface_Point{parent_x, parent_y}, color)
		} else {
			mid_y := (child_y+parent_y)*0.5
			_ = git_dag_append_segment(segments, circles^,
				alicorn.GPU_Surface_Point{child_x, child_y}, alicorn.GPU_Surface_Point{child_x, mid_y}, color)
			_ = git_dag_append_segment(segments, circles^,
				alicorn.GPU_Surface_Point{child_x, mid_y}, alicorn.GPU_Surface_Point{parent_x, mid_y}, color)
			_ = git_dag_append_segment(segments, circles^,
				alicorn.GPU_Surface_Point{parent_x, mid_y}, alicorn.GPU_Surface_Point{parent_x, parent_y}, color)
		}
	}
}
