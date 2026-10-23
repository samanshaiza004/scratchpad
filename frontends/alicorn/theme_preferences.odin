package main

import "core:encoding/json"
import "core:os"
import "core:strings"

SCRATCHPAD_THEME_PREFERENCES_VERSION :: u32(1)

Scratchpad_Theme_Choice :: enum u8 {
	Warm,
	Cool_Light,
	Flat,
	Workbench_Relief,
}

Scratchpad_Theme_Preferences :: struct {
	version: u32   `json:"version"`,
	theme:   string `json:"theme"`,
	editor_font_family: string `json:"editor_font_family"`,
	editor_font_size: f32 `json:"editor_font_size"`,
}

scratchpad_theme_choice_name :: proc(choice: Scratchpad_Theme_Choice) -> string {
	switch choice {
	case .Warm: return "warm"
	case .Cool_Light: return "cool-light"
	case .Flat: return "flat"
	case .Workbench_Relief: return "workbench-relief"
	}
	return "warm"
}

scratchpad_theme_choice_parse :: proc(name: string) -> (choice: Scratchpad_Theme_Choice, valid: bool) {
	switch name {
	case "warm": return .Warm, true
	case "cool-light": return .Cool_Light, true
	case "flat": return .Flat, true
	case "workbench-relief": return .Workbench_Relief, true
	}
	return .Warm, false
}

// The standard config root is platform-owned: Local AppData on Windows,
// Application Support on macOS, and XDG config on Linux.
scratchpad_theme_preferences_location :: proc(config_root: string, allocator := context.allocator) -> (directory, path: string, ok: bool) {
	if config_root == "" { return }
	parts := [2]string{config_root, "Scratchpad"}
	joined_directory, directory_error := os.join_path(parts[:], allocator)
	if directory_error != nil { return "", "", false }
	directory = joined_directory
	file_parts := [2]string{directory, "preferences.json"}
	joined_path, path_error := os.join_path(file_parts[:], allocator)
	if path_error != nil {
		delete(directory, allocator)
		return "", "", false
	}
	path = joined_path
	return directory, path, true
}

scratchpad_theme_preferences_load :: proc(path: string) -> (choice: Scratchpad_Theme_Choice, loaded: bool) {
	preferences, found := scratchpad_user_preferences_load(path, context.temp_allocator)
	defer { delete(preferences.theme, context.temp_allocator); delete(preferences.editor_font_family, context.temp_allocator) }
	if !found { return .Warm, false }
	return scratchpad_theme_choice_parse(preferences.theme)
}

// Font fields extend the version-1 file additively. Existing theme-only files
// retain their theme and use bundled typography; bad font fields fall back alone.
scratchpad_user_preferences_load :: proc(path: string, allocator := context.allocator) -> (preferences: Scratchpad_Theme_Preferences, loaded: bool) {
	preferences.editor_font_size = EDITOR_FONT_SIZE_DEFAULT
	if path == "" { return }
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil { return }
	defer delete(data, context.temp_allocator)
	if json.unmarshal(data, &preferences, allocator=allocator) != nil || preferences.version != SCRATCHPAD_THEME_PREFERENCES_VERSION {
		delete(preferences.theme, allocator)
		delete(preferences.editor_font_family, allocator)
		return Scratchpad_Theme_Preferences{editor_font_size=EDITOR_FONT_SIZE_DEFAULT}, false
	}
	if !(preferences.editor_font_size >= EDITOR_FONT_SIZE_MIN && preferences.editor_font_size <= EDITOR_FONT_SIZE_MAX) {
		preferences.editor_font_size = EDITOR_FONT_SIZE_DEFAULT
	}
	return preferences, true
}

scratchpad_theme_preferences_save :: proc(directory: string, choice: Scratchpad_Theme_Choice, font_family := "", font_size := EDITOR_FONT_SIZE_DEFAULT) -> bool {
	if directory == "" || (choice < .Warm || choice > .Workbench_Relief) { return false }
	directory_error := os.mkdir_all(directory)
	if directory_error != nil && !(directory_error == .Exist && os.is_directory(directory)) { return false }
	parts := [2]string{directory, "preferences.json"}
	path, path_error := os.join_path(parts[:], context.temp_allocator)
	if path_error != nil { return false }
	defer delete(path, context.temp_allocator)
	preferences := Scratchpad_Theme_Preferences{
		version=SCRATCHPAD_THEME_PREFERENCES_VERSION,
		theme=scratchpad_theme_choice_name(choice),
		editor_font_family=font_family,
		editor_font_size=font_size,
	}
	encoded, encode_error := json.marshal(preferences, allocator=context.temp_allocator)
	if encode_error != nil { return false }
	defer delete(encoded, context.temp_allocator)

	// Stage the complete file beside its destination so replacement is one
	// same-directory rename on POSIX hosts and Windows. The temporary directory
	// reserves a unique sibling filename for concurrent Scratchpad instances.
	temporary_directory, temporary_error := os.make_directory_temp(directory, ".theme-preferences-*", context.temp_allocator)
	if temporary_error != nil { return false }
	defer _ = os.remove_all(temporary_directory)
	temporary_parts := [2]string{temporary_directory, ".tmp"}
	temporary_path, temporary_path_error := strings.concatenate(temporary_parts[:], context.temp_allocator)
	if temporary_path_error != nil { return false }
	defer delete(temporary_path, context.temp_allocator)
	defer _ = os.remove(temporary_path)
	if os.write_entire_file(temporary_path, encoded) != nil { return false }
	return os.rename(temporary_path, path) == nil
}

scratchpad_preferences_save :: proc(app: ^App) {
	if app != nil && app.theme_preferences_directory != "" &&
	   !scratchpad_theme_preferences_save(app.theme_preferences_directory, app.theme_choice, app.editor_font_family, scratchpad_editor_font_size(app)) {
		set_error(app, "Settings changed for this session, but Scratchpad could not save the preference.")
	}
}
