package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

SYSTEM_FONT_TEST_SFNT :: #load("../../.deps/alicorn/assets/fonts/AtkinsonHyperlegibleNext-Variable.ttf")
SYSTEM_FONT_TEST_MONO_SFNT :: #load("../../.deps/alicorn/assets/fonts/AtkinsonHyperlegibleMono-Variable.ttf")

system_font_test_num_glyphs :: proc(sfnt: []u8) -> u16 {
	if len(sfnt) < 12 { return 0 }
	table_count := int(system_font_u16_be(sfnt, 4))
	if 12+table_count*16 > len(sfnt) { return 0 }
	for table_index in 0..<table_count {
		record := 12+table_index*16
		if sfnt[record] == 'm' && sfnt[record+1] == 'a' && sfnt[record+2] == 'x' && sfnt[record+3] == 'p' {
			offset := int(system_font_u32_be(sfnt, record+8))
			length := int(system_font_u32_be(sfnt, record+12))
			if offset < 0 || length < 6 || offset+length > len(sfnt) { return 0 }
			return system_font_u16_be(sfnt, offset+4)
		}
	}
	return 0
}

@(test)
test_system_font_read_returns_caller_owned_validated_bytes :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp("", "scratchpad-font-read-*", context.temp_allocator)
	if root_error != nil { testing.expect(t, false, "font fixture directory should be created"); return }
	defer _ = os.remove_all(root)
	path := fmt.tprintf("%s/fixture.ttf", root)
	if os.write_entire_file(path, SYSTEM_FONT_TEST_SFNT) != nil {
		testing.expect(t, false, "the bundled font fixture should be written")
		return
	}

	backing_allocator := context.allocator
	tracking: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracking, backing_allocator)
	allocator := mem.tracking_allocator(&tracking)
	bytes, read_error := system_font_read(path, 0, allocator)
	testing.expect(t, read_error == "" && len(bytes) > 1_000,
		"the font reader should return an owned, Runa-validated SFNT buffer")
	delete(bytes, allocator)
	delete(read_error, allocator)
	_, face_index_error := system_font_read(path, 1, allocator)
	testing.expect(t, face_index_error != "", "a single-face font must reject nonzero face indices")
	delete(face_index_error, allocator)
	mem.tracking_allocator_destroy(&tracking)
}

@(test)
test_system_font_read_rejects_missing_file :: proc(t: ^testing.T) {
	_, missing_error := system_font_read("missing-system-font-fixture.ttf", 0, context.allocator)
	testing.expect(t, missing_error != "", "a missing font should return a useful error")
	delete(missing_error)
}

@(test)
test_system_font_reader_extracts_the_requested_collection_face :: proc(t: ^testing.T) {
	// Build a two-face TTC from distinct bundled fonts. Glyph counts confirm
	// that requesting index one returns the Mono face instead of face zero.
	face_zero_source := SYSTEM_FONT_TEST_SFNT
	face_one_source := SYSTEM_FONT_TEST_MONO_SFNT
	face_zero_tables := int(system_font_u16_be(face_zero_source, 4))
	face_one_tables := int(system_font_u16_be(face_one_source, 4))
	if len(face_zero_source) < 12 || len(face_one_source) < 12 ||
		face_zero_tables == 0 || face_one_tables == 0 ||
		12+face_zero_tables*16 > len(face_zero_source) || 12+face_one_tables*16 > len(face_one_source) {
		testing.expect(t, false, "bundled SFNT fixtures should have complete table directories")
		return
	}
	face_zero_glyphs := system_font_test_num_glyphs(face_zero_source)
	face_one_glyphs := system_font_test_num_glyphs(face_one_source)
	if face_zero_glyphs == 0 || face_one_glyphs == 0 || face_zero_glyphs == face_one_glyphs {
		testing.expect(t, false, "distinct bundled fonts should have distinguishable glyph counts")
		return
	}
	first_face := 20
	second_face, aligned := system_font_align4(first_face+len(face_zero_source))
	if !aligned { testing.expect(t, false, "font fixture size should be addressable"); return }
	collection := make([]u8, second_face+len(face_one_source), context.allocator)
	defer delete(collection)
	copy(collection[:4], []u8{'t','t','c','f'})
	system_font_write_u32_be(collection, 4, 0x00010000)
	system_font_write_u32_be(collection, 8, 2)
	system_font_write_u32_be(collection, 12, u32(first_face))
	system_font_write_u32_be(collection, 16, u32(second_face))
	copy(collection[first_face:first_face+len(face_zero_source)], face_zero_source)
	copy(collection[second_face:second_face+len(face_one_source)], face_one_source)
	face_offsets := [2]int{first_face, second_face}
	face_table_counts := [2]int{face_zero_tables, face_one_tables}
	for face_number in 0..<2 {
		face_offset := face_offsets[face_number]
		for table_index in 0..<face_table_counts[face_number] {
			record := face_offset+12+table_index*16
			relative_table_offset := system_font_u32_be(collection, record+8)
			system_font_write_u32_be(collection, record+8, u32(face_offset)+relative_table_offset)
		}
	}

	root, root_error := os.make_directory_temp("", "scratchpad-font-ttc-*", context.temp_allocator)
	if root_error != nil { testing.expect(t, false, "collection fixture directory should be created"); return }
	defer _ = os.remove_all(root)
	path := fmt.tprintf("%s/fixture.ttc", root)
	if os.write_entire_file(path, collection) != nil {
		testing.expect(t, false, "the synthetic TTC fixture should be written")
		return
	}

	face_zero, zero_error := system_font_read(path, 0, context.allocator)
	testing.expect(t, zero_error == "" && len(face_zero) > 1_000,
		"collection face zero should extract into a validated standalone SFNT")
	testing.expect(t, system_font_test_num_glyphs(face_zero) == face_zero_glyphs,
		"collection index zero should resolve to the Next face")
	delete(face_zero)
	delete(zero_error)
	face_one, one_error := system_font_read(path, 1, context.allocator)
	testing.expect(t, one_error == "" && len(face_one) > 1_000,
		"collection face one should extract into a validated standalone SFNT")
	testing.expect(t, system_font_test_num_glyphs(face_one) == face_one_glyphs,
		"collection index one should resolve to the distinct Mono face")
	delete(face_one)
	delete(one_error)
	_, out_of_range_error := system_font_read(path, 2, context.allocator)
	testing.expect(t, out_of_range_error != "", "an out-of-range collection face should fail")
	delete(out_of_range_error)

	malformed_collection := make([]u8, len(collection), context.allocator)
	defer delete(malformed_collection)
	copy(malformed_collection, collection)
	first_table_record := second_face+12
	system_font_write_u32_be(malformed_collection, first_table_record+8, u32(len(malformed_collection)+4))
	malformed_path := fmt.tprintf("%s/malformed.ttc", root)
	if os.write_entire_file(malformed_path, malformed_collection) != nil {
		testing.expect(t, false, "the malformed collection fixture should be written")
		return
	}
	_, malformed_error := system_font_read(malformed_path, 1, context.allocator)
	testing.expect(t, malformed_error != "", "a collection table outside the file bounds should fail")
	delete(malformed_error)
}

@(test)
test_windows_system_font_catalog_smoke :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		families, discovery_error := system_fonts_discover(context.allocator)
		defer system_fonts_destroy(&families, context.allocator)
		defer delete(discovery_error)
		testing.expect(t, discovery_error == "" && len(families) > 0,
			"Windows should return installed font families from DirectWrite")
		has_selectable_regular_face := false
		for i in 1..<len(families) {
			previous, current := families[i-1], families[i]
			testing.expect(t, (!current.monospaced || previous.monospaced) &&
				(previous.monospaced != current.monospaced || strings.compare(previous.family, current.family) <= 0),
				"Windows DirectWrite catalog should sort monospaced families first and names alphabetically")
		}
		for family in families {
			if family.regular_path != "" { has_selectable_regular_face = true }
		}
		testing.expect(t, has_selectable_regular_face,
			"Windows DirectWrite should resolve at least one selectable font file without creating a font face")
	}
}
