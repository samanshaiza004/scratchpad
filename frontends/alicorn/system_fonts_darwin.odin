#+build darwin

package main

import "core:c"
import "core:mem"
import "core:os"
import "core:strings"
import CF "core:sys/darwin/CoreFoundation"
import NS "core:sys/darwin/Foundation"

foreign import coretext "system:CoreText.framework"
foreign import CoreFoundation_Darwin_Fonts "system:CoreFoundation.framework"

Darwin_CF_Ref :: distinct rawptr
Darwin_CF_Index :: distinct c.long
Darwin_CT_Symbolic_Traits :: distinct u32

foreign coretext {
	CTFontCollectionCreateFromAvailableFonts :: proc(options: Darwin_CF_Ref) -> Darwin_CF_Ref ---
	CTFontCollectionCreateMatchingFontDescriptors :: proc(collection: Darwin_CF_Ref) -> Darwin_CF_Ref ---
	CTFontDescriptorCopyAttribute :: proc(descriptor, attribute: Darwin_CF_Ref) -> Darwin_CF_Ref ---
	CTFontCreateWithFontDescriptor :: proc(descriptor: Darwin_CF_Ref, size: f64, transform: rawptr) -> Darwin_CF_Ref ---
	CTFontGetSymbolicTraits :: proc(font: Darwin_CF_Ref) -> Darwin_CT_Symbolic_Traits ---
	CTFontCopyFamilyName :: proc(font: Darwin_CF_Ref) -> Darwin_CF_Ref ---
	CTFontCopyPostScriptName :: proc(font: Darwin_CF_Ref) -> Darwin_CF_Ref ---

	@(link_name = "kCTFontURLAttribute") kCTFontURLAttribute: Darwin_CF_Ref
	@(link_name = "kCTFontTraitsAttribute") kCTFontTraitsAttribute: Darwin_CF_Ref
	@(link_name = "kCTFontWeightTrait") kCTFontWeightTrait: Darwin_CF_Ref
	@(link_name = "kCTFontStyleNameAttribute") kCTFontStyleNameAttribute: Darwin_CF_Ref
}

foreign CoreFoundation_Darwin_Fonts {
	CFArrayGetCount :: proc(array: Darwin_CF_Ref) -> Darwin_CF_Index ---
	CFArrayGetValueAtIndex :: proc(array: Darwin_CF_Ref, index: Darwin_CF_Index) -> Darwin_CF_Ref ---
	CFDictionaryGetValue :: proc(dictionary, key: Darwin_CF_Ref) -> Darwin_CF_Ref ---
	CFNumberGetValue :: proc(number: Darwin_CF_Ref, number_type: Darwin_CF_Index, value: rawptr) -> b8 ---
	CFRelease :: proc(value: Darwin_CF_Ref) ---
}

DARWIN_CT_FONT_TRAIT_ITALIC :: Darwin_CT_Symbolic_Traits(1 << 0)
DARWIN_CT_FONT_TRAIT_BOLD :: Darwin_CT_Symbolic_Traits(1 << 1)
DARWIN_CT_FONT_TRAIT_MONOSPACE :: Darwin_CT_Symbolic_Traits(1 << 10)
DARWIN_CF_NUMBER_DOUBLE_TYPE :: Darwin_CF_Index(13)

darwin_cf_release :: proc(value: Darwin_CF_Ref) {
	if value != nil { CFRelease(value) }
}

darwin_cf_string_to_string :: proc(value: Darwin_CF_Ref, allocator: mem.Allocator) -> string {
	if value == nil { return "" }
	result, ok := CF.StringCopyToOdinString(CF.String(value), allocator)
	if !ok { return "" }
	return result
}

darwin_font_set_unsupported_reason :: proc(entry: ^System_Font_Family, reason: string, allocator: mem.Allocator) {
	if entry.unsupported_reason == "" { entry.unsupported_reason = system_font_clone_string(reason, allocator) }
}

darwin_font_path_is_collection :: proc(path: string) -> bool {
	if len(path) < 4 { return false }
	suffix := path[len(path)-4:]
	return darwin_ascii_suffix_equal(suffix, ".ttc") || darwin_ascii_suffix_equal(suffix, ".otc")
}

darwin_ascii_suffix_equal :: proc(actual, expected: string) -> bool {
	if len(actual) != len(expected) { return false }
	for i in 0..<len(expected) {
		value := actual[i]
		if value >= 'A' && value <= 'Z' { value += 'a' - 'A' }
		if value != expected[i] { return false }
	}
	return true
}

darwin_descriptor_weight_score :: proc(descriptor: Darwin_CF_Ref, allocator: mem.Allocator) -> f64 {
	weight := f64(2)
	traits := CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute)
	if traits != nil {
		number := CFDictionaryGetValue(traits, kCTFontWeightTrait)
		if number != nil {
			measured: f64
			if CFNumberGetValue(number, DARWIN_CF_NUMBER_DOUBLE_TYPE, rawptr(&measured)) { weight = measured }
		}
		darwin_cf_release(traits)
	}
	if weight < 0 { weight = -weight }

	// CoreText reports zero for regular/medium. When weights tie, prefer the
	// conventional Regular/Normal/Book/Roman style names over nearby alternates.
	style_cf := CTFontDescriptorCopyAttribute(descriptor, kCTFontStyleNameAttribute)
	if style_cf == nil { return weight*10+0.03 }
	style_name := darwin_cf_string_to_string(style_cf, allocator)
	darwin_cf_release(style_cf)
	defer delete(style_name, allocator)
	style_rank := f64(3)
	if darwin_ascii_suffix_equal(style_name, "regular") || darwin_ascii_suffix_equal(style_name, "normal") ||
		darwin_ascii_suffix_equal(style_name, "book") || darwin_ascii_suffix_equal(style_name, "roman") {
		style_rank = 0
	} else if darwin_ascii_suffix_equal(style_name, "medium") {
		style_rank = 1
	} else if darwin_ascii_suffix_equal(style_name, "light") || darwin_ascii_suffix_equal(style_name, "thin") {
		style_rank = 2
	}
	return weight*10+style_rank*0.01
}

darwin_font_descriptor_path :: proc(descriptor: Darwin_CF_Ref, allocator: mem.Allocator) -> string {
	url := CTFontDescriptorCopyAttribute(descriptor, kCTFontURLAttribute)
	if url == nil { return "" }
	defer darwin_cf_release(url)
	// CoreText returns a CFURL here. NSURL is toll-free bridged with CFURL,
	// so Foundation's fileSystemRepresentation provides a native path without
	// depending on private font database paths or URL string decoding.
	path_c := NS.URL_fileSystemRepresentation(cast(^NS.URL)url)
	if path_c == nil { return "" }
	path, err := strings.clone_from_cstring(path_c, allocator)
	if err != nil { return "" }
	return path
}

darwin_font_postscript_name :: proc(font: Darwin_CF_Ref, allocator: mem.Allocator) -> string {
	postscript_cf := CTFontCopyPostScriptName(font)
	if postscript_cf == nil { return "" }
	defer darwin_cf_release(postscript_cf)
	return darwin_cf_string_to_string(postscript_cf, allocator)
}

// CoreText exposes the PostScript face name but not the TTC face index. Match
// that name against each collection face's name table so the shared reader can
// extract the same face that CoreText enumerated.
darwin_ttc_face_index_for_postscript_name :: proc(path, postscript_name: string, allocator: mem.Allocator) -> (face_index: u32, ok: bool) {
	file, open_error := os.open(path)
	if open_error != nil { return 0, false }
	defer os.close(file)
	size, size_error := os.file_size(file)
	if size_error != nil || size < 12 || size > 64*1024*1024 { return 0, false }
	raw := make([]u8, int(size), allocator)
	read, read_error := os.read_at(file, raw, 0)
	if read_error != nil || read != len(raw) {
		delete(raw, allocator)
		return 0, false
	}
	defer delete(raw, allocator)
	if string(raw[:4]) != "ttcf" { return 0, false }
	font_count := system_font_u32_be(raw, 8)
	if font_count == 0 || font_count > 4096 || u64(12)+u64(font_count)*4 > u64(len(raw)) { return 0, false }
	match_index: u32
	match_count := 0
	for index in 0..<int(font_count) {
		face_offset_u32 := system_font_u32_be(raw, 12+index*4)
		if u64(face_offset_u32)+12 > u64(len(raw)) { continue }
		face_offset := int(face_offset_u32)
		table_count := int(system_font_u16_be(raw, face_offset+4))
		if table_count == 0 || table_count > 4096 || u64(face_offset)+12+u64(table_count)*16 > u64(len(raw)) { continue }
		for table_index in 0..<table_count {
			record := face_offset+12+table_index*16
			if string(raw[record:record+4]) != "name" { continue }
			table_offset_u32 := system_font_u32_be(raw, record+8)
			table_length_u32 := system_font_u32_be(raw, record+12)
			if u64(table_offset_u32)+u64(table_length_u32) > u64(len(raw)) || table_length_u32 < 6 { continue }
			table_offset, table_length := int(table_offset_u32), int(table_length_u32)
			if darwin_ttc_name_table_matches(raw, table_offset, table_length, postscript_name) {
				match_index = u32(index)
				match_count += 1
				break
			}
		}
	}
	return match_index, match_count == 1
}

darwin_ttc_name_table_matches :: proc(raw: []u8, table_offset, table_length: int, postscript_name: string) -> bool {
	if table_offset < 0 || table_length < 6 || table_offset+table_length > len(raw) { return false }
	format := system_font_u16_be(raw, table_offset)
	if format > 1 { return false }
	count := int(system_font_u16_be(raw, table_offset+2))
	strings_offset := int(system_font_u16_be(raw, table_offset+4))
	if count > 4096 || strings_offset > table_length || 6+count*12 > table_length { return false }
	for record_index in 0..<count {
		record := table_offset+6+record_index*12
		platform := system_font_u16_be(raw, record)
		name_id := system_font_u16_be(raw, record+6)
		if name_id != 6 { continue }
		name_length := int(system_font_u16_be(raw, record+8))
		name_offset := int(system_font_u16_be(raw, record+10))
		if name_offset > table_length-strings_offset || name_length > table_length-strings_offset-name_offset { continue }
		bytes_offset := table_offset+strings_offset+name_offset
		if platform == 0 || platform == 3 {
			if name_length != len(postscript_name)*2 { continue }
			matches := true
			for i in 0..<len(postscript_name) {
				if raw[bytes_offset+i*2] != 0 || raw[bytes_offset+i*2+1] != postscript_name[i] { matches = false; break }
			}
			if matches { return true }
		} else if platform == 1 {
			if name_length != len(postscript_name) { continue }
			if string(raw[bytes_offset:bytes_offset+name_length]) == postscript_name { return true }
		}
	}
	return false
}

darwin_system_fonts_discover :: proc(allocator := context.allocator) -> (families: [dynamic]System_Font_Family, error: string) {
	collection := CTFontCollectionCreateFromAvailableFonts(nil)
	if collection == nil { return nil, system_font_error("CoreText could not create the available-font collection", allocator) }
	defer darwin_cf_release(collection)

	descriptors := CTFontCollectionCreateMatchingFontDescriptors(collection)
	if descriptors == nil { return nil, system_font_error("CoreText could not enumerate available font descriptors", allocator) }
	defer darwin_cf_release(descriptors)

	families = make([dynamic]System_Font_Family, 0, allocator=allocator)
	regular_scores := make([dynamic]f64, 0, allocator=allocator)
	italic_scores := make([dynamic]f64, 0, allocator=allocator)
	defer { delete(regular_scores); delete(italic_scores) }
	count := CFArrayGetCount(descriptors)
	for index: Darwin_CF_Index = 0; index < count; index += 1 {
		descriptor := CFArrayGetValueAtIndex(descriptors, index)
		if descriptor == nil { continue }

		font := CTFontCreateWithFontDescriptor(descriptor, 0, nil)
		if font == nil { continue }
		defer darwin_cf_release(font)

		family_cf := CTFontCopyFamilyName(font)
		if family_cf == nil { continue }
		family_name := darwin_cf_string_to_string(family_cf, allocator)
		darwin_cf_release(family_cf)
		if family_name == "" { continue }

		family_index := -1
		for i in 0..<len(families) {
			if families[i].family == family_name { family_index = i; break }
		}
		if family_index < 0 {
			append(&families, System_Font_Family{family=family_name})
			append(&regular_scores, 1e30)
			append(&italic_scores, 1e30)
			family_index = len(families) - 1
		} else {
			delete(family_name, allocator)
		}

		entry := &families[family_index]
		traits := CTFontGetSymbolicTraits(font)
		is_italic := (traits & DARWIN_CT_FONT_TRAIT_ITALIC) != 0
		is_bold := (traits & DARWIN_CT_FONT_TRAIT_BOLD) != 0
		if (traits & DARWIN_CT_FONT_TRAIT_MONOSPACE) != 0 { entry.monospaced = true }

		path := darwin_font_descriptor_path(descriptor, allocator)
		if path == "" {
			if !is_italic && !is_bold && entry.regular_path == "" {
				darwin_font_set_unsupported_reason(entry, "CoreText did not provide a readable file URL for an upright regular face", allocator)
			}
			continue
		}
		postscript_name: string
		if darwin_font_path_is_collection(path) {
			postscript_name = darwin_font_postscript_name(font, allocator)
			if postscript_name == "" {
				if !is_italic && !is_bold && entry.regular_path == "" {
					darwin_font_set_unsupported_reason(entry, "CoreText did not provide a PostScript face name for the font collection", allocator)
				}
				delete(path, allocator)
				continue
			}
		}

		if is_italic {
			candidate_score := darwin_descriptor_weight_score(descriptor, allocator)
			if !is_bold && candidate_score < italic_scores[family_index] {
				delete(entry.italic_path, allocator)
				delete(entry.italic_postscript_name, allocator)
				entry.italic_path = path
				entry.italic_postscript_name = postscript_name
				italic_scores[family_index] = candidate_score
			} else {
				delete(path, allocator)
				delete(postscript_name, allocator)
			}
		} else if !is_bold {
			candidate_score := darwin_descriptor_weight_score(descriptor, allocator)
			if candidate_score < regular_scores[family_index] {
				delete(entry.regular_path, allocator)
				delete(entry.regular_postscript_name, allocator)
				entry.regular_path = path
				entry.regular_postscript_name = postscript_name
				regular_scores[family_index] = candidate_score
			} else {
				delete(path, allocator)
				delete(postscript_name, allocator)
			}
		} else {
			delete(path, allocator)
			delete(postscript_name, allocator)
		}
	}

	for i in 0..<len(families) {
		if families[i].regular_path == "" {
			darwin_font_set_unsupported_reason(&families[i], "No accessible upright regular face was found", allocator)
		} else {
			delete(families[i].unsupported_reason, allocator)
			families[i].unsupported_reason = ""
		}
	}
	return families, ""
}
