package alicorn_scratchpad_bridge

import "core:mem"
import "core:strings"
import "core:sync"

Pin_ID :: distinct u64

Pinned_Range :: struct {
	id: Pin_ID `json:"id"`,
	document_id: string `json:"document_id"`,
	instance_id: u64 `json:"instance_id"`,
	source_revision: u64 `json:"source_revision"`,
	start_byte: int `json:"start_byte"`,
	end_byte: int `json:"end_byte"`,
	path: string `json:"path"`,
	relative_path: string `json:"relative_path"`,
	first_line: int `json:"first_line"`,
	line_count: int `json:"line_count"`,
	first_row: int `json:"first_row"`,
	status: string `json:"status"`,
}

Pinned_Snapshot :: struct {
	epoch: u64 `json:"epoch"`,
	revision: u64 `json:"revision"`,
	generation: u64 `json:"generation"`,
	total_rows: int `json:"total_rows"`,
	source_invalidations: u64 `json:"source_invalidations"`,
	ranges: []Pinned_Range `json:"ranges"`,
}

Pinned_Row :: struct {
	row: int `json:"row"`,
	pin_id: Pin_ID `json:"pin_id"`,
	kind: string `json:"kind"`,
	source_line: int `json:"source_line"`,
	start_byte: int `json:"start_byte"`,
	end_byte: int `json:"end_byte"`,
	offset: int `json:"offset"`,
	length: int `json:"length"`,
	has_before: bool `json:"has_before"`,
	has_more: bool `json:"has_more"`,
}

Pinned_Window :: struct {
	epoch: u64 `json:"epoch"`,
	revision: u64 `json:"revision"`,
	first: int `json:"first"`,
	total_rows: int `json:"total_rows"`,
	rows: []Pinned_Row `json:"rows"`,
}

pinned_snapshot_destroy :: proc(value: ^Pinned_Snapshot, allocator := context.allocator) {
	if value == nil { return }
	for pin in value.ranges { delete(pin.document_id, allocator); delete(pin.path, allocator); delete(pin.relative_path, allocator); delete(pin.status, allocator) }
	delete(value.ranges, allocator); value^ = {}
}
Pinned_Snapshot_Destroy :: pinned_snapshot_destroy

pinned_snapshot_clone :: proc(value: Pinned_Snapshot, allocator: mem.Allocator) -> (result: Pinned_Snapshot, ok: bool) {
	if len(value.ranges)>256 { return }
	result=value; result.ranges=make([]Pinned_Range,len(value.ranges),allocator=allocator)
	for pin,i in value.ranges {
		result.ranges[i]=pin
		err: mem.Allocator_Error
		result.ranges[i].document_id,err=strings.clone(pin.document_id,allocator)
		if err!=nil {pinned_snapshot_destroy(&result,allocator);return {},false}
		result.ranges[i].path,err=strings.clone(pin.path,allocator)
		if err!=nil {pinned_snapshot_destroy(&result,allocator);return {},false}
		result.ranges[i].relative_path,err=strings.clone(pin.relative_path,allocator)
		if err!=nil {pinned_snapshot_destroy(&result,allocator);return {},false}
		result.ranges[i].status,err=strings.clone(pin.status,allocator)
		if err!=nil {pinned_snapshot_destroy(&result,allocator);return {},false}
	}
	return result,true
}

pinned_window_destroy :: proc(value: ^Pinned_Window, allocator := context.allocator) {
	if value==nil { return }; for row in value.rows { delete(row.kind,allocator) }; delete(value.rows,allocator); value^={}
}
Pinned_Window_Destroy :: pinned_window_destroy

pinned_window_clone :: proc(value: Pinned_Window, allocator: mem.Allocator) -> (result: Pinned_Window, ok: bool) {
	if len(value.rows)>256 { return }
	result=value; result.rows=make([]Pinned_Row,len(value.rows),allocator=allocator)
	for row,i in value.rows {
		result.rows[i]=row
		copy,err:=strings.clone(row.kind,allocator)
		if err!=nil {pinned_window_destroy(&result,allocator);return {},false}
		result.rows[i].kind=copy
	}
	return result,true
}

backend_copy_pinned_resource :: proc(backend: ^Backend, descriptor: Resource_Descriptor, allocator: mem.Allocator) -> (data: []u8, ok: bool) {
	if descriptor.byte_len==0 { return nil,descriptor.resource_id==0 }
	if descriptor.byte_len>64*1024 || descriptor.resource_id==0 || descriptor.generation==0 { return }
	map_resource:=transmute(Caliber_Map_Resource_Proc)(backend.api.context_map_resource)
	view: Caliber_Resource_View
	if map_resource(backend.caliber_context,descriptor.resource_id,descriptor.generation,&view) != .OK { return }
	if backend.resource_lease_acquired_fn()!=0 {
		if view.lease!=nil { release:=transmute(Caliber_Release_Resource_Proc)(backend.api.resource_release); release(&view) }
		release:=transmute(Caliber_Release_Context_Resource_Proc)(backend.api.context_release_resource); _=release(backend.caliber_context,descriptor.resource_id,descriptor.generation)
		return
	}
	sync.atomic_add(&backend.resource_leases,1)
	defer backend_release_resource_view(backend,&view,descriptor.resource_id,descriptor.generation)
	if view.resource_id!=descriptor.resource_id || view.generation!=descriptor.generation || view.len!=uintptr(descriptor.byte_len) || view.data==nil { return }
	err: mem.Allocator_Error
	data,err=make([]u8,int(view.len),allocator=allocator); if err!=nil { return }
	mem.copy(rawptr(&data[0]),rawptr(view.data),len(data)); return data,true
}
