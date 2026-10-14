package main

import "core:os"
import "core:testing"

@(test)
test_editor_font_preferences_migrate_and_keep_theme_and_typography_together :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("", "scratchpad-font-preferences-*", context.temp_allocator)
	if err != nil { testing.expect(t, false, "font preferences fixture should have an isolated directory"); return }
	defer _ = os.remove_all(root)
	directory, path, found := scratchpad_theme_preferences_location(root, context.temp_allocator)
	if !found { testing.expect(t, false, "preference path should resolve"); return }
	defer { delete(directory, context.temp_allocator); delete(path, context.temp_allocator) }
	_ = os.mkdir_all(directory)
	_ = os.write_entire_file(path, `{"version":1,"theme":"cool-light"}`)
	legacy, loaded := scratchpad_user_preferences_load(path, context.temp_allocator)
	testing.expect(t, loaded && legacy.theme == "cool-light" && legacy.editor_font_family == "" && legacy.editor_font_size == 16,
		"a theme-only preference should keep its theme and gain bundled 16px typography")
	delete(legacy.theme, context.temp_allocator)
	delete(legacy.editor_font_family, context.temp_allocator)

	app := App{theme_choice=.Cool_Light, theme_preferences_directory=directory, editor_font_family="Consolas", editor_text_scale=1.25}
	scratchpad_preferences_save(&app)
	custom, custom_loaded := scratchpad_user_preferences_load(path, context.temp_allocator)
	testing.expect(t, custom_loaded && custom.theme == "cool-light" && custom.editor_font_family == "Consolas" && custom.editor_font_size == 20,
		"font family and size should survive atomic persistence alongside the theme")
	delete(custom.theme, context.temp_allocator)
	delete(custom.editor_font_family, context.temp_allocator)
	app.theme_choice = .Warm
	scratchpad_preferences_save(&app)
	custom, custom_loaded = scratchpad_user_preferences_load(path, context.temp_allocator)
	testing.expect(t, custom_loaded && custom.theme == "warm" && custom.editor_font_family == "Consolas" && custom.editor_font_size == 20,
		"switching theme must not erase the selected editor font or size")
	delete(custom.theme, context.temp_allocator)
	delete(custom.editor_font_family, context.temp_allocator)

	_ = os.write_entire_file(path, `{"version":1,"theme":"cool-light","editor_font_family":"Removed Font","editor_font_size":-500}`)
	invalid, invalid_loaded := scratchpad_user_preferences_load(path, context.temp_allocator)
	testing.expect(t, invalid_loaded && invalid.theme == "cool-light" && invalid.editor_font_size == 16,
		"an invalid font size should fall back independently without changing the valid theme")
	delete(invalid.theme, context.temp_allocator)
	delete(invalid.editor_font_family, context.temp_allocator)
}
