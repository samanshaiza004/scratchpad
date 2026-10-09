package main

import "core:encoding/json"
import "core:os"

SCRATCHPAD_THEME_PREFERENCES_VERSION :: u32(1)

Scratchpad_Theme_Choice :: enum u8 {
	Warm,
	Cool_Light,
}

Scratchpad_Theme_Preferences :: struct {
	version: u32   `json:"version"`,
	theme:   string `json:"theme"`,
}

scratchpad_theme_choice_name :: proc(choice: Scratchpad_Theme_Choice) -> string {
	switch choice {
	case .Warm: return "warm"
	case .Cool_Light: return "cool-light"
	}
	return "warm"
}

scratchpad_theme_choice_parse :: proc(name: string) -> (choice: Scratchpad_Theme_Choice, valid: bool) {
	switch name {
	case "warm": return .Warm, true
	case "cool-light": return .Cool_Light, true
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
	choice = .Warm
	if path == "" { return }
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil { return }
	defer delete(data, context.temp_allocator)
	preferences: Scratchpad_Theme_Preferences
	if json.unmarshal(data, &preferences, allocator=context.temp_allocator) != nil { return }
	defer delete(preferences.theme, context.temp_allocator)
	if preferences.version != SCRATCHPAD_THEME_PREFERENCES_VERSION { return }
	return scratchpad_theme_choice_parse(preferences.theme)
}

scratchpad_theme_preferences_save :: proc(directory: string, choice: Scratchpad_Theme_Choice) -> bool {
	if directory == "" || (choice != .Warm && choice != .Cool_Light) { return false }
	if os.mkdir_all(directory) != nil { return false }
	parts := [2]string{directory, "preferences.json"}
	path, path_error := os.join_path(parts[:], context.temp_allocator)
	if path_error != nil { return false }
	defer delete(path, context.temp_allocator)
	preferences := Scratchpad_Theme_Preferences{
		version=SCRATCHPAD_THEME_PREFERENCES_VERSION,
		theme=scratchpad_theme_choice_name(choice),
	}
	encoded, encode_error := json.marshal(preferences, allocator=context.temp_allocator)
	if encode_error != nil { return false }
	defer delete(encoded, context.temp_allocator)
	return os.write_entire_file(path, encoded) == nil
}
