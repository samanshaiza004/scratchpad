package main

import "core:mem"
import "core:os"
import "core:strings"
import runa "alicorn:third_party/Runa"

System_Font_Family :: struct {
	family: string,
	regular_path: string,
	italic_path: string,
	regular_postscript_name: string,
	italic_postscript_name: string,
	regular_face_index: u32,
	italic_face_index: u32,
	monospaced: bool,
	unsupported_reason: string,
}

system_fonts_discover :: proc(allocator := context.allocator) -> (families: [dynamic]System_Font_Family, error: string) {
	when ODIN_OS == .Windows {
		return windows_system_fonts_discover(allocator)
	} else when ODIN_OS == .Darwin {
		return darwin_system_fonts_discover(allocator)
	} else {
		families = make([dynamic]System_Font_Family, 0, allocator=allocator)
		error = system_font_clone_string("System font discovery is supported on Windows and macOS.", allocator)
		return
	}
}

// Reads a font face without allowing a hostile or accidental huge file to
// allocate without bound. TTC data is unpacked into a standalone SFNT with
// offsets rebased, because Runa's public loader accepts one SFNT face.
system_font_read :: proc(path: string, face_index: u32, allocator := context.allocator) -> (bytes: []u8, error: string) {
	file, open_error := os.open(path)
	if open_error != nil { return nil, system_font_error("Could not open the font file.", allocator) }
	defer os.close(file)
	size, size_error := os.file_size(file)
	if size_error != nil || size <= 0 { return nil, system_font_error("Could not read the font file size.", allocator) }
	if size > 64*1024*1024 { return nil, system_font_error("Font file exceeds the 64 MiB safety limit.", allocator) }
	raw := make([]u8, int(size), allocator)
	read, read_error := os.read_at(file, raw, 0)
	if read_error != nil || read != len(raw) {
		delete(raw, allocator)
		return nil, system_font_error("Could not read the complete font file.", allocator)
	}
	if len(raw) < 4 {
		delete(raw, allocator)
		return nil, system_font_error("Font file is too short to contain an SFNT header.", allocator)
	}
	if string(raw[:4]) == "ttcf" {
		bytes, error = system_font_extract_ttc_face(raw, face_index, allocator)
		delete(raw, allocator)
		if error != "" { return nil, error }
	} else {
		if face_index != 0 {
			delete(raw, allocator)
			return nil, system_font_error("The requested face index is unavailable in this single-face font file.", allocator)
		}
		bytes = raw
	}
	font, load_error := runa.font_load(bytes, allocator)
	if load_error != .None {
		delete(bytes, allocator)
		bytes = nil
		return nil, system_font_error("Runa cannot load this font format.", allocator)
	}
	runa.font_destroy(&font)
	return
}

system_font_extract_ttc_face :: proc(raw: []u8, face_index: u32, allocator: mem.Allocator) -> (bytes: []u8, error: string) {
	if len(raw) < 12 { return nil, system_font_error("The TrueType collection header is truncated.", allocator) }
	count := system_font_u32_be(raw, 8)
	if count == 0 || count > 4096 || face_index >= count { return nil, system_font_error("The requested face index is outside the collection.", allocator) }
	if u64(12) + u64(count)*4 > u64(len(raw)) { return nil, system_font_error("The TrueType collection face directory is truncated.", allocator) }
	face_offset := system_font_u32_be(raw, 12+int(face_index)*4)
	if face_offset > u32(len(raw)-12) { return nil, system_font_error("The selected collection face points outside the file.", allocator) }
	face_offset_i := int(face_offset)
	if face_offset_i+12 > len(raw) { return nil, system_font_error("The selected collection face header is truncated.", allocator) }
	table_count := system_font_u16_be(raw, face_offset_i+4)
	if table_count == 0 || table_count > 4096 { return nil, system_font_error("The selected face has an invalid table count.", allocator) }
	directory_end := face_offset_i+12+int(table_count)*16
	if directory_end > len(raw) { return nil, system_font_error("The selected face table directory is truncated.", allocator) }
	data_start := 12+int(table_count)*16
	total := data_start
	for i in 0..<int(table_count) {
		record := face_offset_i+12+i*16
		offset := system_font_u32_be(raw, record+8)
		length := system_font_u32_be(raw, record+12)
		if u64(offset)+u64(length) > u64(len(raw)) { return nil, system_font_error("A selected font table points outside the collection.", allocator) }
		aligned, ok := system_font_align4(total)
		if !ok || u64(aligned)+u64(length) > 64*1024*1024 { return nil, system_font_error("The selected font face exceeds the 64 MiB safety limit.", allocator) }
		total = aligned+int(length)
	}
	if total > 64*1024*1024 { return nil, system_font_error("The selected font face exceeds the 64 MiB safety limit.", allocator) }
	bytes = make([]u8, total, allocator)
	copy(bytes[:4], raw[face_offset_i:face_offset_i+4])
	copy(bytes[4:12], raw[face_offset_i+4:face_offset_i+12])
	copy(bytes[12:data_start], raw[face_offset_i+12:directory_end])
	cursor := data_start
	for i in 0..<int(table_count) {
		record := 12+i*16
		source_record := face_offset_i+12+i*16
		source_offset := system_font_u32_be(raw, source_record+8)
		length := system_font_u32_be(raw, source_record+12)
		aligned, _ := system_font_align4(cursor)
		cursor = aligned
		copy(bytes[cursor:cursor+int(length)], raw[int(source_offset):int(source_offset+length)])
		system_font_write_u32_be(bytes, record+8, u32(cursor))
		cursor += int(length)
	}
	// TTC table records retain their original per-table checksums, while the
	// standalone SFNT needs a new head.checkSumAdjustment after rebasing.
	head_offset := -1
	for i in 0..<int(table_count) {
		record := 12+i*16
		if bytes[record] == 'h' && bytes[record+1] == 'e' && bytes[record+2] == 'a' && bytes[record+3] == 'd' {
			head_offset = int(system_font_u32_be(bytes, record+8))
			break
		}
	}
	if head_offset < 0 || head_offset+12 > len(bytes) {
		delete(bytes, allocator)
		return nil, system_font_error("The selected collection face is missing its required head table.", allocator)
	}
	for i in 0..<4 { bytes[head_offset+8+i] = 0 }
	checksum_sum: u32
	for offset := 0; offset < len(bytes); offset += 4 {
		word: u32
		for byte_index in 0..<4 {
			word <<= 8
			if offset+byte_index < len(bytes) { word |= u32(bytes[offset+byte_index]) }
		}
		checksum_sum += word
	}
	system_font_write_u32_be(bytes, head_offset+8, 0xB1B0AFBA-checksum_sum)
	return
}

system_font_align4 :: proc(n: int) -> (int, bool) {
	if n < 0 || n > max(int)-3 { return 0, false }
	return (n+3)&~3, true
}

system_font_u16_be :: proc(bytes: []u8, offset: int) -> u16 {
	return u16(bytes[offset])<<8 | u16(bytes[offset+1])
}

system_font_u32_be :: proc(bytes: []u8, offset: int) -> u32 {
	return u32(bytes[offset])<<24 | u32(bytes[offset+1])<<16 | u32(bytes[offset+2])<<8 | u32(bytes[offset+3])
}

system_font_write_u32_be :: proc(bytes: []u8, offset: int, value: u32) {
	bytes[offset] = u8(value>>24)
	bytes[offset+1] = u8(value>>16)
	bytes[offset+2] = u8(value>>8)
	bytes[offset+3] = u8(value)
}

system_fonts_destroy :: proc(families: ^[dynamic]System_Font_Family, allocator := context.allocator) {
	if families == nil { return }
	for &family in families {
		delete(family.family, allocator)
		delete(family.regular_path, allocator)
		delete(family.italic_path, allocator)
		delete(family.regular_postscript_name, allocator)
		delete(family.italic_postscript_name, allocator)
		delete(family.unsupported_reason, allocator)
	}
	delete(families^)
	families^ = {}
}

system_font_clone_string :: proc(value: string, allocator: mem.Allocator) -> string {
	if value == "" { return "" }
	copy, err := strings.clone(value, allocator)
	if err != nil { return "" }
	return copy
}

system_font_error :: proc(message: string, allocator: mem.Allocator) -> string {
	return system_font_clone_string(message, allocator)
}
