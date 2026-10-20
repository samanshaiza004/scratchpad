#+build darwin

package main

import "core:testing"

@(test)
system_fonts_darwin_ttc_postscript_match_test :: proc(t: ^testing.T) {
	postscript_name := "Menlo-Regular"
	name_table := make([]u8, 18+len(postscript_name)*2)
	defer delete(name_table)
	// Format 0 table with one Windows Unicode PostScript-name record.
	name_table[2] = 0
	name_table[3] = 1
	name_table[4] = 0
	name_table[5] = 18
	name_table[6] = 0
	name_table[7] = 3
	name_table[8] = 0
	name_table[9] = 1
	name_table[10] = 4
	name_table[11] = 9
	name_table[12] = 0
	name_table[13] = 6
	name_table[14] = u8((len(postscript_name)*2)>>8)
	name_table[15] = u8(len(postscript_name) * 2)
	for i in 0..<len(postscript_name) { name_table[18+i*2+1] = postscript_name[i] }
	testing.expect(t, darwin_ttc_name_table_matches(name_table, 0, len(name_table), postscript_name), "TTC matcher should find an exact UTF-16 PostScript name")
	testing.expect(t, !darwin_ttc_name_table_matches(name_table, 0, len(name_table), "Menlo-Bold"), "TTC matcher should not choose a different collection face")
}

@(test)
system_fonts_darwin_discovery_smoke_test :: proc(t: ^testing.T) {
	families, error := darwin_system_fonts_discover()
	defer system_fonts_destroy(&families)
	defer delete(error)
	testing.expect(t, error == "", "CoreText should enumerate installed font descriptors")
	if error != "" { return }
	testing.expect(t, len(families) > 0, "the host should expose at least one installed font family")
	for family in families {
		testing.expect(t, family.family != "", "enumerated font families should have display names")
		if family.regular_path != "" {
			testing.expect(t, family.regular_face_index == 0, "single-face font files should use face index zero")
		}
		if family.italic_path != "" {
			testing.expect(t, family.italic_face_index == 0, "single-face font files should use face index zero")
		}
	}
}
