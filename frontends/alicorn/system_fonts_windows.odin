#+build windows
package main

import "core:mem"
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
WINDOWS_DWRITE_FONT3_IID := Windows_DWrite_Guid{0x29748ED6, 0x8C9C, 0x4A6A, {0xBE, 0x0B, 0xD9, 0x12, 0xE8, 0x53, 0x89, 0x44}}

windows_system_fonts_discover :: proc(allocator := context.allocator) -> (families: [dynamic]System_Font_Family, error: string) {
	families = make([dynamic]System_Font_Family, 0, allocator=allocator)
	factory: rawptr
	if DWriteCreateFactory(0, &WINDOWS_DWRITE_FACTORY_IID, &factory) < 0 || factory == nil {
		error = system_font_clone_string("DirectWrite could not create its shared factory.", allocator)
		return
	}
	defer windows_com_release(factory)
	collection: rawptr
	get_system_collection := cast(proc "system" (rawptr, ^rawptr, win.BOOL) -> win.HRESULT) windows_com_method(factory, 3)
	if get_system_collection(factory, &collection, false) < 0 || collection == nil {
		error = system_font_clone_string("DirectWrite could not read the installed system font collection.", allocator)
		return
	}
	defer windows_com_release(collection)
	get_family_count := cast(proc "system" (rawptr) -> u32) windows_com_method(collection, 3)
	get_family := cast(proc "system" (rawptr, u32, ^rawptr) -> win.HRESULT) windows_com_method(collection, 4)
	family_count := get_family_count(collection)
	if family_count > 100_000 { error = system_font_clone_string("DirectWrite returned an unreasonable font family count.", allocator); return }
	for family_index in 0..<family_count {
		family_interface: rawptr
		if get_family(collection, family_index, &family_interface) < 0 || family_interface == nil { continue }
		family_name := windows_dwrite_family_name(family_interface, allocator)
		if family_name == "" { windows_com_release(family_interface); continue }
		family := System_Font_Family{family=family_name}
		font_count_call := cast(proc "system" (rawptr) -> u32) windows_com_method(family_interface, 4)
		get_font := cast(proc "system" (rawptr, u32, ^rawptr) -> win.HRESULT) windows_com_method(family_interface, 5)
		font_count := font_count_call(family_interface)
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
					font = nil
				} else if style != 0 && delta < italic_delta {
					if best_italic != nil { windows_com_release(best_italic) }
					best_italic = font
					italic_delta = delta
					font = nil
				}
			}
			if font != nil { windows_com_release(font) }
		}
		if best_regular != nil {
			family.regular_path, family.regular_face_index, family.unsupported_reason = windows_dwrite_font_location(best_regular, allocator)
			font1: rawptr
			query := cast(proc "system" (rawptr, ^Windows_DWrite_Guid, ^rawptr) -> win.HRESULT) windows_com_method(best_regular, 0)
			if query(best_regular, &WINDOWS_DWRITE_FONT1_IID, &font1) >= 0 && font1 != nil {
				is_mono := cast(proc "system" (rawptr) -> win.BOOL) windows_com_method(font1, 17)
				family.monospaced = is_mono(font1) != win.FALSE
				windows_com_release(font1)
			}
			windows_com_release(best_regular)
		} else {
			family.unsupported_reason = system_font_clone_string("DirectWrite found no regular upright face that Runa can select.", allocator)
		}
		if best_italic != nil {
			italic_path, italic_index, italic_error := windows_dwrite_font_location(best_italic, allocator)
			family.italic_path = italic_path
			family.italic_face_index = italic_index
			delete(italic_error, allocator)
			windows_com_release(best_italic)
		}
		windows_com_release(family_interface)
		append(&families, family)
	}
	windows_font_catalog_sort(families)
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
	// A font-face reference exposes the file and collection index without
	// materializing the face. This avoids doing unnecessary face work during
	// catalog discovery and handles fonts DirectWrite cannot instantiate.
	query_font3 := cast(proc "system" (rawptr, ^Windows_DWrite_Guid, ^rawptr) -> win.HRESULT) windows_com_method(font, 0)
	font3: rawptr
	if query_font3(font, &WINDOWS_DWRITE_FONT3_IID, &font3) < 0 || font3 == nil {
		return "", 0, system_font_clone_string("This Windows version cannot query a DirectWrite font-face reference.", allocator)
	}
	defer windows_com_release(font3)
	get_face_reference := cast(proc "system" (rawptr, ^rawptr) -> win.HRESULT) windows_com_method(font3, 21)
	face_reference: rawptr
	if get_face_reference(font3, &face_reference) < 0 || face_reference == nil {
		return "", 0, system_font_clone_string("DirectWrite could not resolve a reference to this font face.", allocator)
	}
	defer windows_com_release(face_reference)
	get_face_index := cast(proc "system" (rawptr) -> u32) windows_com_method(face_reference, 6)
	face_index = get_face_index(face_reference)
	get_font_file := cast(proc "system" (rawptr, ^rawptr) -> win.HRESULT) windows_com_method(face_reference, 8)
	font_file: rawptr
	if get_font_file(face_reference, &font_file) < 0 || font_file == nil {
		return "", face_index, system_font_clone_string("DirectWrite could not resolve the font file for this face.", allocator)
	}
	defer windows_com_release(font_file)
	key: rawptr
	key_size: u32
	get_reference_key := cast(proc "system" (rawptr, ^rawptr, ^u32) -> win.HRESULT) windows_com_method(font_file, 3)
	if get_reference_key(font_file, &key, &key_size) < 0 || key == nil || key_size == 0 {
		return "", face_index, system_font_clone_string("DirectWrite did not provide a font-file reference key.", allocator)
	}
	loader: rawptr
	get_loader := cast(proc "system" (rawptr, ^rawptr) -> win.HRESULT) windows_com_method(font_file, 4)
	if get_loader(font_file, &loader) < 0 || loader == nil {
		return "", face_index, system_font_clone_string("DirectWrite did not provide a font-file loader.", allocator)
	}
	defer windows_com_release(loader)
	local_loader_iid := Windows_DWrite_Guid{0xB2D9F3EC, 0xC9FE, 0x4A11, {0xA2, 0xEC, 0xD8, 0x62, 0x08, 0xF7, 0xC0, 0xA2}}
	local_loader: rawptr
	query := cast(proc "system" (rawptr, ^Windows_DWrite_Guid, ^rawptr) -> win.HRESULT) windows_com_method(loader, 0)
	if query(loader, &local_loader_iid, &local_loader) < 0 || local_loader == nil {
		return "", face_index, system_font_clone_string("DirectWrite reports a non-local or unsupported font-file loader.", allocator)
	}
	defer windows_com_release(local_loader)
	get_path_length := cast(proc "system" (rawptr, rawptr, u32, ^u32) -> win.HRESULT) windows_com_method(local_loader, 4)
	path_length: u32
	if get_path_length(local_loader, key, key_size, &path_length) < 0 || path_length == 0 || path_length > 32767 {
		return "", face_index, system_font_clone_string("DirectWrite could not resolve an absolute local font path.", allocator)
	}
	path_buffer := make([]u16, int(path_length)+1, context.temp_allocator)
	defer delete(path_buffer, context.temp_allocator)
	get_path := cast(proc "system" (rawptr, rawptr, u32, ^u16, u32) -> win.HRESULT) windows_com_method(local_loader, 5)
	if get_path(local_loader, key, key_size, raw_data(path_buffer), path_length+1) < 0 {
		return "", face_index, system_font_clone_string("DirectWrite could not read the absolute local font path.", allocator)
	}
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
