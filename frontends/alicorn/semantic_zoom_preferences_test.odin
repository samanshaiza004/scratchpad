package main

import "core:fmt"
import "core:os"
import "core:testing"

@(test)
test_semantic_zoom_wheel_preference_roundtrips_without_changing_typography :: proc(t: ^testing.T) {
	directory, err := os.make_directory_temp("", "scratchpad-zoom-preferences-*", context.temp_allocator)
	if err != nil { testing.expect(t, false, "preference test needs a temporary directory"); return }
	defer _ = os.remove_all(directory)
	path := fmt.tprintf("%s/preferences.json", directory)
	for mode in Semantic_Zoom_Wheel {
		testing.expect(t, scratchpad_theme_preferences_save(directory, .Cool_Light, "Test Mono", 19, mode), "the configured gesture should be saved")
		preferences, loaded := scratchpad_user_preferences_load(path)
		testing.expect(t, loaded && preferences.semantic_zoom_wheel == mode && preferences.theme == "cool-light" &&
			preferences.editor_font_family == "Test Mono" && preferences.editor_font_size == 19,
			"gesture configuration must survive restart without replacing the theme/font settings")
		delete(preferences.theme)
		delete(preferences.editor_font_family)
	}
	testing.expect(t, os.write_entire_file_from_string(path, `{"version":1,"theme":"cool-light"}`) == nil, "old preferences should be writable")
	old, loaded := scratchpad_user_preferences_load(path)
	defer { delete(old.theme); delete(old.editor_font_family) }
	testing.expect(t, loaded && old.semantic_zoom_wheel == .Primary_Alt && old.theme == "cool-light", "existing preference files must get the default gesture")
}
