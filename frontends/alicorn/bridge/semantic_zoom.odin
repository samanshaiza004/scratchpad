package alicorn_scratchpad_bridge

import "core:mem"
import "core:strings"

Semantic_Zoom_Fold :: struct {
	start_line: u64 `json:"start_line"`,
	end_line: u64 `json:"end_line"`,
	start_byte: u64 `json:"start_byte"`,
	end_byte: u64 `json:"end_byte"`,
	label: string `json:"label"`,
}

Semantic_Zoom_Plan :: struct {
	document_id: string `json:"document_id"`,
	revision: u64 `json:"revision"`,
	instance_id: u64 `json:"instance_id"`,
	depth: int `json:"depth"`,
	anchor_byte: u64 `json:"anchor_byte"`,
	line_count: u64 `json:"line_count"`,
	ready: bool `json:"ready"`,
	supported: bool `json:"supported"`,
	reason: string `json:"reason"`,
	folds: []Semantic_Zoom_Fold `json:"folds"`,
}

semantic_zoom_plan_destroy :: proc(plan: ^Semantic_Zoom_Plan, allocator := context.allocator) {
	if plan == nil { return }
	delete(plan.document_id, allocator)
	delete(plan.reason, allocator)
	for fold in plan.folds { delete(fold.label, allocator) }
	delete(plan.folds, allocator)
	plan^ = {}
}

Semantic_Zoom_Plan_Destroy :: semantic_zoom_plan_destroy

semantic_zoom_plan_clone :: proc(source: Semantic_Zoom_Plan, allocator: mem.Allocator) -> (copy: Semantic_Zoom_Plan, ok: bool) {
	copy = source
	copy.document_id, copy.reason, copy.folds = "", "", nil
	err: mem.Allocator_Error
	copy.document_id, err = strings.clone(source.document_id, allocator)
	if err != nil { return {}, false }
	copy.reason, err = strings.clone(source.reason, allocator)
	if err != nil { semantic_zoom_plan_destroy(&copy, allocator); return {}, false }
	if len(source.folds) > 4096 { semantic_zoom_plan_destroy(&copy, allocator); return {}, false }
	copy.folds = make([]Semantic_Zoom_Fold, len(source.folds), allocator=allocator)
	for fold, i in source.folds {
		copy.folds[i] = fold
		copy.folds[i].label, err = strings.clone(fold.label, allocator)
		if err != nil { semantic_zoom_plan_destroy(&copy, allocator); return {}, false }
	}
	return copy, true
}
