package main

import "core:fmt"
import "core:strings"
import alicorn "alicorn:runtime"

EDITOR_FONT_SIZE_DEFAULT :: alicorn.DEFAULT_TEXT_SIZE
EDITOR_FONT_SIZE_MIN :: EDITOR_FONT_SIZE_DEFAULT*EDITOR_TEXT_SCALE_MIN
EDITOR_FONT_SIZE_MAX :: EDITOR_FONT_SIZE_DEFAULT*EDITOR_TEXT_SCALE_MAX

scratchpad_editor_font_size :: proc(app: ^App) -> f32 {
	return EDITOR_FONT_SIZE_DEFAULT*editor_text_scale_effective(app)
}

scratchpad_editor_font_catalog_ensure :: proc(app: ^App) {
	if app == nil || app.editor_font_catalog_ready { return }
	system_fonts_destroy(&app.editor_font_catalog, context.allocator)
	families, message := system_fonts_discover(context.allocator)
	app.editor_font_catalog = families
	app.editor_font_catalog_ready = message == ""
	find_set_message(&app.editor_font_catalog_error, message)
	delete(message, context.allocator)
}

// One pending choice is applied before begin_frame, after the previous native
// presentation has completed. Typing/searching never replaces an active face.
scratchpad_editor_font_request :: proc(app: ^App, rt: ^alicorn.Runtime, family: string, size: f32) -> bool {
	if app == nil || rt == nil || !(size >= EDITOR_FONT_SIZE_MIN && size <= EDITOR_FONT_SIZE_MAX) { return false }
	next, err := strings.clone(family, context.allocator)
	if err != nil { return false }
	delete(app.editor_font_pending_family, context.allocator)
	app.editor_font_pending_family = next
	app.editor_font_pending_size = size
	app.editor_font_pending_persist = true
	app.editor_font_pending = true
	alicorn.invalidate_root(rt, "Scratchpad editor font choice queued")
	return true
}

scratchpad_editor_font_regular_bytes :: proc(app: ^App) -> []u8 {
	if app != nil && len(app.editor_font_data) > 0 { return app.editor_font_data }
	return SCRATCHPAD_MONO_FONT_DATA
}

scratchpad_editor_font_italic_bytes :: proc(app: ^App) -> []u8 {
	if app != nil && len(app.editor_font_data) > 0 { return app.editor_font_italic_data }
	return SCRATCHPAD_MONO_ITALIC_FONT_DATA
}

scratchpad_editor_font_install :: proc(rt: ^alicorn.Runtime, regular, italic: []u8) -> bool {
	if rt == nil || !alicorn.font_load_bytes(rt, .Monospace, regular) { return false }
	if len(italic) > 0 { return alicorn.font_load_italic_bytes(rt, .Monospace, italic) }
	return true
}

scratchpad_editor_font_read_face :: proc(entry: ^System_Font_Family, italic := false) -> (bytes: []u8, error: string) {
	path := entry.italic_path if italic else entry.regular_path
	face_index := entry.italic_face_index if italic else entry.regular_face_index
	when ODIN_OS == .Darwin {
		if darwin_font_path_is_collection(path) {
			name := entry.italic_postscript_name if italic else entry.regular_postscript_name
			found: bool
			face_index, found = darwin_ttc_face_index_for_postscript_name(path, name, context.temp_allocator)
			if !found { return nil, system_font_error("The exact CoreText face is unavailable in this font collection.", context.allocator) }
		}
	}
	return system_font_read(path, face_index, context.allocator)
}

scratchpad_editor_font_apply_pending :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil || !app.editor_font_pending { return }
	family := app.editor_font_pending_family
	size := app.editor_font_pending_size
	persist := app.editor_font_pending_persist
	app.editor_font_pending_family = ""
	app.editor_font_pending = false
	app.editor_font_pending_persist = false
	defer delete(family, context.allocator)
	_ = scratchpad_editor_font_select(app, rt, family, size, persist)
}

scratchpad_editor_font_select :: proc(app: ^App, rt: ^alicorn.Runtime, family: string, size: f32, persist := true) -> bool {
	if app == nil || rt == nil || !(size >= EDITOR_FONT_SIZE_MIN && size <= EDITOR_FONT_SIZE_MAX) { return false }
	face_changed := family != app.editor_font_family
	if !face_changed {
		changed := editor_typography_set(app, rt, size/EDITOR_FONT_SIZE_DEFAULT)
		if changed && persist { scratchpad_preferences_save(app) }
		return true
	}
	regular := SCRATCHPAD_MONO_FONT_DATA
	italic := SCRATCHPAD_MONO_ITALIC_FONT_DATA
	custom_regular, custom_italic: []u8
	defer { delete(custom_regular, context.allocator); delete(custom_italic, context.allocator) }
	if family != "" {
		scratchpad_editor_font_catalog_ensure(app)
		index := -1
		for entry, candidate in app.editor_font_catalog {
			if entry.family == family { index = candidate; break }
		}
		if index < 0 {
			set_error(app, fmt.tprintf("The editor font “%s” is no longer installed. The current font is still active.", family))
			return false
		}
		entry := &app.editor_font_catalog[index]
		if entry.unsupported_reason != "" {
			set_error(app, fmt.tprintf("Could not use “%s”: %s", family, entry.unsupported_reason))
			return false
		}
		message: string
		custom_regular, message = scratchpad_editor_font_read_face(entry)
		if message != "" {
			find_set_message(&entry.unsupported_reason, message)
			set_error(app, fmt.tprintf("Could not use “%s”: %s The current font is still active.", family, message))
			delete(message, context.allocator)
			return false
		}
		regular = custom_regular
		italic = nil
		if entry.italic_path != "" {
			custom_italic, message = scratchpad_editor_font_read_face(entry, italic=true)
			if message == "" { italic = custom_italic }
			else { set_error(app, fmt.tprintf("“%s” is active, but its italic face could not be loaded: %s", family, message)) }
			delete(message, context.allocator)
		}
	}
	name, name_error := strings.clone(family, context.allocator)
	if name_error != nil { return false }
	defer delete(name, context.allocator)
	old_regular := scratchpad_editor_font_regular_bytes(app)
	old_italic := scratchpad_editor_font_italic_bytes(app)
	if !scratchpad_editor_font_install(rt, regular, italic) {
		_ = scratchpad_editor_font_install(rt, old_regular, old_italic)
		set_error(app, "Could not replace the editor font. The previous font is still active.")
		return false
	}
	if floating := app.floating_window; floating != nil && floating.runtime != nil && floating.runtime != rt {
		if !scratchpad_editor_font_install(floating.runtime, regular, italic) {
			_ = scratchpad_editor_font_install(rt, old_regular, old_italic)
			_ = scratchpad_editor_font_install(floating.runtime, old_regular, old_italic)
			set_error(app, "Could not update the floating editor font. The previous font is still active.")
			return false
		}
	}
	_ = editor_typography_set(app, rt, size/EDITOR_FONT_SIZE_DEFAULT, force=true)
	delete(app.editor_font_family, context.allocator)
	delete(app.editor_font_data, context.allocator)
	delete(app.editor_font_italic_data, context.allocator)
	app.editor_font_family = name
	name = ""
	app.editor_font_data = custom_regular
	app.editor_font_italic_data = custom_italic
	custom_regular = nil
	custom_italic = nil
	if persist { scratchpad_preferences_save(app) }
	return true
}

scratchpad_editor_font_destroy :: proc(app: ^App) {
	if app == nil { return }
	delete(app.editor_font_family, context.allocator)
	delete(app.editor_font_data, context.allocator)
	delete(app.editor_font_italic_data, context.allocator)
	delete(app.editor_font_pending_family, context.allocator)
	delete(app.editor_font_catalog_error, context.allocator)
	find_set_message(&app.editor_font_picker_query, "")
	system_fonts_destroy(&app.editor_font_catalog, context.allocator)
	app.editor_font_family = ""
	app.editor_font_data = nil
	app.editor_font_italic_data = nil
	app.editor_font_pending_family = ""
	app.editor_font_catalog_error = ""
}
