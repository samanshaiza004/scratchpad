#+build windows
package main

import "core:mem"
import "core:fmt"
import "core:strings"
import win "core:sys/windows"

foreign import dwrite "system:Dwrite.lib"

@(default_calling_convention="system")
foreign dwrite {
	DWriteCreateFactory :: proc(factory_type: u32, iid: ^win.IID, factory: ^rawptr) -> win.HRESULT ---
}

Windows_Com_VTable :: struct { slots: [32]rawptr }
Windows_Com_Object :: struct { vtable: ^Windows_Com_VTable }
Windows_DWrite_Guid :: struct {
	data1: u32,
	data2: u16,
	data3: u16,
	data4: [8]u8,
}

WINDOWS_DWRITE_FACTORY_IID := win.IID{0xB859EE5A, 0xD838, 0x4B5B, {0xA2, 0xE8, 0x1A, 0xDC, 0x7D, 0x93, 0xDB, 0x48}}
WINDOWS_DWRITE_FONT1_IID := Windows_DWrite_Guid{0xACD16696, 0x8C14, 0x4F5D, {0x87, 0x7E, 0xFE, 0x3F, 0xC1, 0xD3, 0x27, 0x38}}

windows_dwrite_trace_enabled: bool
windows_dwrite_trace_family: int = -1
windows_dwrite_trace_font: int = -1
windows_dwrite_trace_name: string
windows_dwrite_trace_weight: int = -1
windows_dwrite_trace_style: int = -1
windows_dwrite_trace_stretch: int = -1

windows_dwrite_trace :: proc(stage: string) {
	if windows_dwrite_trace_enabled {
		fmt.println("[DWRITE-TRACE]", windows_dwrite_trace_family, windows_dwrite_trace_font, windows_dwrite_trace_name, windows_dwrite_trace_weight, windows_dwrite_trace_style, windows_dwrite_trace_stretch, stage)
	}
}

windows_system_fonts_discover :: proc(allocator := context.allocator) -> (families: [dynamic]System_Font_Family, error: string) {
	families = make([dynamic]System_Font_Family, 0, allocator=allocator)
	windows_dwrite_trace("factory create begin")
	factory: rawptr
	if DWriteCreateFactory(0, &WINDOWS_DWRITE_FACTORY_IID, &factory) < 0 || factory == nil {
		error = system_font_clone_string("DirectWrite could not create its shared factory.", allocator)
		return
	}
	defer windows_com_release(factory)
	windows_dwrite_trace("factory create complete")
	collection: rawptr
	get_system_collection := cast(proc "system" (rawptr, ^rawptr, win.BOOL) -> win.HRESULT) windows_com_method(factory, 3)
	if get_system_collection(factory, &collection, false) < 0 || collection == nil {
		error = system_font_clone_string("DirectWrite could not read the installed system font collection.", allocator)
		return
	}
	defer windows_com_release(collection)
	windows_dwrite_trace("system collection complete")
	get_family_count := cast(proc "system" (rawptr) -> u32) windows_com_method(collection, 3)
	get_family := cast(proc "system" (rawptr, u32, ^rawptr) -> win.HRESULT) windows_com_method(collection, 4)
	family_count := get_family_count(collection)
	windows_dwrite_trace("family count complete")
	if family_count > 100_000 { error = system_font_clone_string("DirectWrite returned an unreasonable font family count.", allocator); return }
	for family_index in 0..<family_count {
		windows_dwrite_trace_family = int(family_index)
		windows_dwrite_trace_font = -1
		windows_dwrite_trace_name = ""
		windows_dwrite_trace_weight = -1
		windows_dwrite_trace_style = -1
		windows_dwrite_trace_stretch = -1
		windows_dwrite_trace("family begin")
		family_interface: rawptr
		if get_family(collection, family_index, &family_interface) < 0 || family_interface == nil { continue }
		family_name := windows_dwrite_family_name(family_interface, allocator)
		windows_dwrite_trace_name = family_name
		windows_dwrite_trace("family name complete")
		if family_name == "" { windows_com_release(family_interface); continue }
		family := System_Font_Family{family=family_name}
		font_count_call := cast(proc "system" (rawptr) -> u32) windows_com_method(family_interface, 4)
		get_font := cast(proc "system" (rawptr, u32, ^rawptr) -> win.HRESULT) windows_com_method(family_interface, 5)
		font_count := font_count_call(family_interface)
		windows_dwrite_trace("font count complete")
		if font_count > 4096 {
			family.unsupported_reason = system_font_clone_string("DirectWrite returned an unreasonable number of faces for this family.", allocator)
			windows_com_release(family_interface)
			append(&families, family)
			continue
		}
		best_regular: rawptr
		best_italic: rawptr
		regular_delta := max(u32)
		italic_delta := max(u32)
		for font_index in 0..<font_count {
			windows_dwrite_trace_font = int(font_index)
			windows_dwrite_trace("font properties begin")
			font: rawptr
			if get_font(family_interface, font_index, &font) < 0 || font == nil { continue }
			font_weight_call := cast(proc "system" (rawptr) -> u32) windows_com_method(font, 4)
			font_stretch_call := cast(proc "system" (rawptr) -> u32) windows_com_method(font, 5)
			font_style_call := cast(proc "system" (rawptr) -> u32) windows_com_method(font, 6)
			font_simulations_call := cast(proc "system" (rawptr) -> u32) windows_com_method(font, 10)
			weight := font_weight_call(font)
			style := font_style_call(font)
			stretch := font_stretch_call(font)
			if font_simulations_call(font) == 0 && stretch == 5 && (style == 0 || style == 1 || style == 2) {
				delta := weight-400 if weight >= 400 else 400-weight
				if style == 0 && delta < regular_delta {
					if best_regular != nil { windows_com_release(best_regular) }
					best_regular = font
					regular_delta = delta
					windows_dwrite_trace_weight = int(weight)
					windows_dwrite_trace_style = int(style)
					windows_dwrite_trace_stretch = int(stretch)
					font = nil
				} else if style != 0 && delta < italic_delta {
					if best_italic != nil { windows_com_release(best_italic) }
					best_italic = font
					italic_delta = delta
					font = nil
				}
			}
			if font != nil { windows_com_release(font) }
			windows_dwrite_trace("font properties complete")
		}
		windows_dwrite_trace_font = -1
		windows_dwrite_trace("font selection complete")
		if best_regular != nil {
			windows_dwrite_trace("regular location begin")
			family.regular_path, family.regular_face_index, family.unsupported_reason = windows_dwrite_font_location(best_regular, allocator)
			windows_dwrite_trace("regular location complete")
			font1: rawptr
			query := cast(proc "system" (rawptr, ^Windows_DWrite_Guid, ^rawptr) -> win.HRESULT) windows_com_method(best_regular, 0)
			if query(best_regular, &WINDOWS_DWRITE_FONT1_IID, &font1) >= 0 && font1 != nil {
				is_mono := cast(proc "system" (rawptr) -> win.BOOL) windows_com_method(font1, 17)
				family.monospaced = is_mono(font1) != win.FALSE
				windows_com_release(font1)
			}
			windows_dwrite_trace("monospace query complete")
			windows_com_release(best_regular)
		} else {
			family.unsupported_reason = system_font_clone_string("DirectWrite found no regular upright face that Runa can select.", allocator)
		}
		if best_italic != nil {
			windows_dwrite_trace("italic location begin")
			italic_path, italic_index, italic_error := windows_dwrite_font_location(best_italic, allocator)
			windows_dwrite_trace("italic location complete")
			family.italic_path = italic_path
			family.italic_face_index = italic_index
			delete(italic_error, allocator)
			windows_com_release(best_italic)
		}
		windows_com_release(family_interface)
		append(&families, family)
		windows_dwrite_trace("family append complete")
	}
	windows_dwrite_trace_family = -1
	windows_dwrite_trace("sort begin")
	windows_font_catalog_sort(families)
	windows_dwrite_trace("sort complete")
	return
}

windows_dwrite_family_name :: proc(family: rawptr, allocator: mem.Allocator) -> string {
	get_names := cast(proc "system" (rawptr, ^rawptr) -> win.HRESULT) windows_com_method(family, 6)
	names: rawptr
	if get_names(family, &names) < 0 || names == nil { return "" }
	defer windows_com_release(names)
	find_locale := cast(proc "system" (rawptr, ^u16, ^u32, ^win.BOOL) -> win.HRESULT) windows_com_method(names, 4)
	get_string := cast(proc "system" (rawptr, u32, ^u16, u32) -> win.HRESULT) windows_com_method(names, 8)
	get_length := cast(proc "system" (rawptr, u32, ^u32) -> win.HRESULT) windows_com_method(names, 7)
	name_count := cast(proc "system" (rawptr) -> u32) windows_com_method(names, 3)
	count := name_count(names)
	if count == 0 { return "" }
	// Prefer English (United States) when present; otherwise index zero gives
	// a deterministic fallback without relying on a machine-specific locale.
	locale := [6]u16{'e', 'n', '-', 'u', 's', 0}
	name_index: u32
	name_exists: win.BOOL
	if find_locale(names, &locale[0], &name_index, &name_exists) < 0 || name_exists == win.FALSE {
		name_index = 0
	}
	length: u32
	if get_length(names, name_index, &length) < 0 || length == 0 || length > 4096 { return "" }
	buffer := make([]u16, int(length)+1, context.temp_allocator)
	defer delete(buffer, context.temp_allocator)
	if get_string(names, name_index, raw_data(buffer), length+1) < 0 { return "" }
	name, conversion_error := win.utf16_to_utf8_alloc(buffer[:length], allocator)
	if conversion_error != nil { return "" }
	return name
}

windows_dwrite_font_location :: proc(font: rawptr, allocator: mem.Allocator) -> (path: string, face_index: u32, unsupported_reason: string) {
	windows_dwrite_trace("create font face begin")
	create_face_method := windows_com_method(font, 13)
	windows_dwrite_trace("create font face method retrieved")
	create_face := cast(proc "system" (rawptr, ^rawptr) -> win.HRESULT) create_face_method
	face: rawptr
	if create_face(font, &face) < 0 || face == nil {
		return "", 0, system_font_clone_string("DirectWrite could not open this font face.", allocator)
	}
	defer windows_com_release(face)
	windows_dwrite_trace("create font face complete")
	get_face_index := cast(proc "system" (rawptr) -> u32) windows_com_method(face, 5)
	face_index = get_face_index(face)
	get_files := cast(proc "system" (rawptr, ^u32, rawptr) -> win.HRESULT) windows_com_method(face, 4)
	file_count: u32
	if get_files(face, &file_count, nil) < 0 || file_count != 1 {
		return "", face_index, system_font_clone_string("This font face does not resolve to one local font file.", allocator)
	}
	windows_dwrite_trace("font file count complete")
	font_file: rawptr
	file_count = 1
	if get_files(face, &file_count, rawptr(&font_file)) < 0 || font_file == nil {
		return "", face_index, system_font_clone_string("DirectWrite could not resolve the font file for this face.", allocator)
	}
	defer windows_com_release(font_file)
	windows_dwrite_trace("font file retrieval complete")
	key: rawptr
	key_size: u32
	get_reference_key := cast(proc "system" (rawptr, ^rawptr, ^u32) -> win.HRESULT) windows_com_method(font_file, 3)
	if get_reference_key(font_file, &key, &key_size) < 0 || key == nil || key_size == 0 {
		return "", face_index, system_font_clone_string("DirectWrite did not provide a font-file reference key.", allocator)
	}
	windows_dwrite_trace("reference key complete")
	loader: rawptr
	get_loader := cast(proc "system" (rawptr, ^rawptr) -> win.HRESULT) windows_com_method(font_file, 4)
	if get_loader(font_file, &loader) < 0 || loader == nil {
		return "", face_index, system_font_clone_string("DirectWrite did not provide a font-file loader.", allocator)
	}
	defer windows_com_release(loader)
	windows_dwrite_trace("loader retrieval complete")
	local_loader_iid := Windows_DWrite_Guid{0xB2D9F3EC, 0xC9FE, 0x4A11, {0xA2, 0xEC, 0xD8, 0x62, 0x08, 0xF7, 0xC0, 0xA2}}
	local_loader: rawptr
	query := cast(proc "system" (rawptr, ^Windows_DWrite_Guid, ^rawptr) -> win.HRESULT) windows_com_method(loader, 0)
	if query(loader, &local_loader_iid, &local_loader) < 0 || local_loader == nil {
		return "", face_index, system_font_clone_string("DirectWrite reports a non-local or unsupported font-file loader.", allocator)
	}
	defer windows_com_release(local_loader)
	windows_dwrite_trace("local loader query complete")
	get_path_length := cast(proc "system" (rawptr, rawptr, u32, ^u32) -> win.HRESULT) windows_com_method(local_loader, 4)
	path_length: u32
	if get_path_length(local_loader, key, key_size, &path_length) < 0 || path_length == 0 || path_length > 32767 {
		return "", face_index, system_font_clone_string("DirectWrite could not resolve an absolute local font path.", allocator)
	}
	windows_dwrite_trace("path length complete")
	path_buffer := make([]u16, int(path_length)+1, context.temp_allocator)
	defer delete(path_buffer, context.temp_allocator)
	get_path := cast(proc "system" (rawptr, rawptr, u32, ^u16, u32) -> win.HRESULT) windows_com_method(local_loader, 5)
	if get_path(local_loader, key, key_size, raw_data(path_buffer), path_length+1) < 0 {
		return "", face_index, system_font_clone_string("DirectWrite could not read the absolute local font path.", allocator)
	}
	windows_dwrite_trace("path read complete")
	converted_path, conversion_error := win.utf16_to_utf8_alloc(path_buffer[:path_length], allocator)
	if conversion_error != nil {
		return "", face_index, system_font_clone_string("The DirectWrite font path could not be converted to UTF-8.", allocator)
	}
	path = converted_path
	return
}

windows_com_method :: proc(object: rawptr, slot: int) -> rawptr {
	com := cast(^Windows_Com_Object)object
	return com.vtable.slots[slot]
}

windows_com_release :: proc(object: rawptr) {
	if object == nil { return }
	release := cast(proc "system" (rawptr) -> u32) windows_com_method(object, 2)
	_ = release(object)
}

windows_font_catalog_sort :: proc(families: [dynamic]System_Font_Family) {
	for i in 1..<len(families) {
		j := i
		for j > 0 {
			left, right := families[j-1], families[j]
			if left.monospaced && !right.monospaced { break }
			if left.monospaced == right.monospaced && strings.compare(left.family, right.family) <= 0 { break }
			families[j-1], families[j] = families[j], families[j-1]
			j -= 1
		}
	}
}
