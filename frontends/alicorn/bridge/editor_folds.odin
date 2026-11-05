package alicorn_scratchpad_bridge

import "core:mem"
import "core:strings"

Editor_Fold :: struct {
	start_line: u64 `json:"start_line"`,
	body_start_line: u64 `json:"body_start_line"`,
	end_line: u64 `json:"end_line"`,
	start_byte: u64 `json:"start_byte"`,
	body_start_byte: u64 `json:"body_start_byte"`,
	end_byte: u64 `json:"end_byte"`,
	label: string `json:"label"`,
}

Editor_Fold_Plan :: struct {
	document_id: string `json:"document_id"`,
	revision: u64 `json:"revision"`,
	instance_id: u64 `json:"instance_id"`,
	ready: bool `json:"ready"`,
	supported: bool `json:"supported"`,
	reason: string `json:"reason"`,
	line_count: u64 `json:"line_count"`,
	folds: []Editor_Fold `json:"folds"`,
}

editor_fold_plan_destroy :: proc(plan: ^Editor_Fold_Plan, allocator := context.allocator) {
	if plan == nil { return }
	delete(plan.document_id, allocator)
	delete(plan.reason, allocator)
	for fold in plan.folds { delete(fold.label, allocator) }
	delete(plan.folds, allocator)
	plan^ = {}
}

Editor_Fold_Plan_Destroy :: editor_fold_plan_destroy

editor_fold_plan_clone :: proc(source: Editor_Fold_Plan, allocator: mem.Allocator) -> (copy: Editor_Fold_Plan, ok: bool) {
	if len(source.folds) > 4096 { return {}, false }
	copy = source
	copy.document_id, copy.reason, copy.folds = "", "", nil
	var err: mem.Allocator_Error
	copy.document_id, err = strings.clone(source.document_id, allocator)
	if err != nil { return {}, false }
	copy.reason, err = strings.clone(source.reason, allocator)
	if err != nil { editor_fold_plan_destroy(&copy, allocator); return {}, false }
	copy.folds = make([]Editor_Fold, len(source.folds), allocator=allocator)
	for fold, i in source.folds {
		copy.folds[i] = fold
		copy.folds[i].label, err = strings.clone(fold.label, allocator)
		if err != nil { editor_fold_plan_destroy(&copy, allocator); return {}, false }
	}
	return copy, true
}
