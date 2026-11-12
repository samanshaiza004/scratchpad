package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import odin_runtime "base:runtime"
import "core:sync"
import "core:thread"
import alicorn "alicorn:runtime"
import theme "alicorn:theme"
import gui "alicorn:ui"
import host "alicorn:native/sdl_gpu"

SCRATCHPAD_THEME_SOURCE_LIMIT :: 1024 * 1024
SCRATCHPAD_THEME_CATALOG_LIMIT :: 64
SCRATCHPAD_THEME_BUILTIN_WARM :: "builtin:warm"
SCRATCHPAD_THEME_BUILTIN_COOL :: "builtin:cool-light"
SCRATCHPAD_THEME_BUILTIN_CHARCOAL :: "builtin:charcoal-ink"
SCRATCHPAD_THEME_BUILTIN_MOCHA :: "builtin:catppuccin-mocha"

Scratchpad_Surface_Treatment :: enum u8 { Standard, Flat, Workbench_Relief }

Scratchpad_Installed_Theme :: struct {
	id: string,
	name: string,
	path: string,
}

Scratchpad_Theme_Candidate :: struct {
	id: string,
	name: string,
	source: []u8,
	style: alicorn.Style_Theme,
	signature: u64,
	diagnostic: string,
	valid: bool,
	generation: u64,
	install: bool,
	install_filename: string,
}

Scratchpad_Theme_Compile_Request :: struct {
	generation: u64,
	id, name, source_path, install_filename: string,
	source: []u8,
	install: bool,
}

// A single sleeping worker serializes theme compilation. New selections
// replace the queued request and advance the generation; stale work is dropped
// before it reaches a Runtime. The condition variable is idle without polling.
Scratchpad_Theme_Compiler :: struct {
	worker: ^thread.Thread,
	waker: host.Application_Waker,
	mutex: sync.Mutex,
	condition: sync.Cond,
	stopping, request_ready, candidate_ready: bool,
	generation: u64,
	request: Scratchpad_Theme_Compile_Request,
	candidate: Scratchpad_Theme_Candidate,
}

scratchpad_surface_treatment_name :: proc(treatment: Scratchpad_Surface_Treatment) -> string {
	switch treatment {
	case .Standard: return "standard"
	case .Flat: return "flat"
	case .Workbench_Relief: return "workbench-relief"
	}
	return "standard"
}

scratchpad_surface_treatment_parse :: proc(value: string) -> (treatment: Scratchpad_Surface_Treatment, valid: bool) {
	switch value {
	case "standard": return .Standard, true
	case "flat": return .Flat, true
	case "workbench-relief": return .Workbench_Relief, true
	}
	return .Standard, false
}

scratchpad_theme_id_for_choice :: proc(choice: Scratchpad_Theme_Choice) -> string {
	switch choice {
	case .Cool_Light: return SCRATCHPAD_THEME_BUILTIN_COOL
	case .Charcoal_Ink: return SCRATCHPAD_THEME_BUILTIN_CHARCOAL
	case .Warm, .Flat, .Workbench_Relief: return SCRATCHPAD_THEME_BUILTIN_WARM
	}
	return SCRATCHPAD_THEME_BUILTIN_WARM
}

scratchpad_app_theme_id :: proc(app: ^App) -> string {
	if app == nil { return SCRATCHPAD_THEME_BUILTIN_WARM }
	if app.selected_theme_id != "" { return app.selected_theme_id }
	return scratchpad_theme_id_for_choice(app.theme_choice)
}

scratchpad_theme_selection_set :: proc(app: ^App, id, name: string) -> bool {
	if app == nil || id == "" || name == "" { return false }
	new_id, id_error := strings.clone(id, context.allocator)
	if id_error != nil { return false }
	new_name, name_error := strings.clone(name, context.allocator)
	if name_error != nil { delete(new_id, context.allocator); return false }
	delete(app.selected_theme_id, context.allocator)
	delete(app.selected_theme_name, context.allocator)
	app.selected_theme_id, app.selected_theme_name = new_id, new_name
	return true
}

scratchpad_theme_preference_fallback :: proc(app: ^App, message: string) {
	if app == nil { return }
	app.theme_choice = .Warm
	_ = scratchpad_theme_selection_set(app, SCRATCHPAD_THEME_BUILTIN_WARM, "Warm")
	if app.theme_preferences_directory != "" { scratchpad_preferences_save(app) }
	if message != "" {
		set_error(app, message)
		scratchpad_theme_compile_error_set(app, message)
	}
}

scratchpad_theme_compile_error_set :: proc(app: ^App, message: string) {
	if app == nil { return }
	delete(app.theme_compile_error, context.allocator)
	app.theme_compile_error = ""
	if message != "" { app.theme_compile_error, _ = strings.clone(message, context.allocator) }
}

scratchpad_theme_pending_set :: proc(app: ^App, id: string) -> bool {
	if app == nil || id == "" { return false }
	copy, err := strings.clone(id, context.allocator)
	if err != nil { return false }
	delete(app.theme_compile_requested_id, context.allocator)
	app.theme_compile_requested_id = copy
	app.theme_compile_pending = true
	return true
}

scratchpad_theme_preview_begin :: proc(app: ^App) -> bool {
	if app == nil { return false }
	if app.theme_preview_active { return true }
	original_id, id_error := strings.clone(scratchpad_app_theme_id(app), context.allocator)
	name := app.selected_theme_name
	if name == "" { name = "Warm" }
	original_name, name_error := strings.clone(name, context.allocator)
	if id_error != nil || name_error != nil {
		delete(original_id, context.allocator)
		delete(original_name, context.allocator)
		return false
	}
	app.theme_preview_original_treatment = app.surface_treatment
	app.theme_preview_original_id, app.theme_preview_original_name = original_id, original_name
	app.theme_preview_active = true
	return true
}

scratchpad_theme_preview_accept :: proc(app: ^App) {
	if app == nil || !app.theme_preview_active { return }
	app.theme_preview_active = false
	delete(app.theme_preview_original_id, context.allocator)
	delete(app.theme_preview_original_name, context.allocator)
	app.theme_preview_original_id = ""
	app.theme_preview_original_name = ""
	scratchpad_preferences_save(app)
}

scratchpad_theme_preview_cancel :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil || !app.theme_preview_active { return }
	original_id := app.theme_preview_original_id
	if original_id == "" { original_id = SCRATCHPAD_THEME_BUILTIN_WARM }
	if original_id == SCRATCHPAD_THEME_BUILTIN_MOCHA || strings.has_prefix(original_id, "user:") {
		app.theme_preview_restore_pending = true
		_ = scratchpad_surface_treatment_select(app, rt, app.theme_preview_original_treatment, false)
		if original_id == SCRATCHPAD_THEME_BUILTIN_MOCHA {
			if scratchpad_theme_compiler_request(&app.theme_compiler, original_id, "Catppuccin Mocha", SCRATCHPAD_CATPPUCCIN_MOCHA_THEME_JSON) && scratchpad_theme_pending_set(app, original_id) {
				return
			}
		} else if scratchpad_theme_compile_installed_request(app, original_id) {
			if scratchpad_theme_pending_set(app, original_id) { return }
		}
		scratchpad_theme_compiler_invalidate(&app.theme_compiler)
		app.theme_compile_pending = false
		app.theme_preview_restore_pending = false
		set_error(app, "The previous installed theme could not be found; Scratchpad kept the last valid appearance.")
		return
	}
	if original_id == SCRATCHPAD_THEME_BUILTIN_COOL { _ = scratchpad_theme_select(app, rt, .Cool_Light, false)
	} else if original_id == SCRATCHPAD_THEME_BUILTIN_CHARCOAL { _ = scratchpad_theme_select(app, rt, .Charcoal_Ink, false)
	} else { _ = scratchpad_theme_select(app, rt, .Warm, false) }
	_ = scratchpad_surface_treatment_select(app, rt, app.theme_preview_original_treatment, false)
	app.theme_preview_active = false
	delete(app.theme_preview_original_id, context.allocator)
	delete(app.theme_preview_original_name, context.allocator)
	app.theme_preview_original_id, app.theme_preview_original_name = "", ""
	app.theme_preview_restore_pending = false
}

scratchpad_installed_theme_destroy :: proc(entry: ^Scratchpad_Installed_Theme, allocator := context.allocator) {
	if entry == nil { return }
	delete(entry.id, allocator)
	delete(entry.name, allocator)
	delete(entry.path, allocator)
	entry^ = {}
}

scratchpad_theme_candidate_destroy :: proc(candidate: ^Scratchpad_Theme_Candidate, allocator := context.allocator) {
	if candidate == nil { return }
	delete(candidate.id, allocator)
	delete(candidate.name, allocator)
	delete(candidate.source, allocator)
	delete(candidate.diagnostic, allocator)
	delete(candidate.install_filename, allocator)
	theme.theme_runtime_style_theme_destroy(&candidate.style, allocator)
	candidate^ = {}
}

scratchpad_theme_compile_request_destroy :: proc(request: ^Scratchpad_Theme_Compile_Request, allocator: mem.Allocator) {
	if request == nil { return }
	delete(request.id, allocator)
	delete(request.name, allocator)
	delete(request.source_path, allocator)
	delete(request.install_filename, allocator)
	delete(request.source, allocator)
	request^ = {}
}

scratchpad_theme_slug :: proc(value: string, allocator := context.allocator) -> string {
	bytes := make([dynamic]u8, 0, len(value), allocator)
	separator_pending := false
	for index in 0..<len(value) {
		byte := value[index]
		lower := byte
		if lower >= 'A' && lower <= 'Z' { lower += 'a'-'A' }
		if (lower >= 'a' && lower <= 'z') || (lower >= '0' && lower <= '9') {
			if separator_pending && len(bytes) > 0 { append(&bytes, '-') }
			append(&bytes, lower)
			separator_pending = false
		} else {
			separator_pending = true
		}
	}
	if len(bytes) == 0 { append(&bytes, 't', 'h', 'e', 'm', 'e') }
	return string(bytes[:])
}

scratchpad_theme_display_name :: proc(filename: string, allocator := context.allocator) -> string {
	stem := filename
	if strings.has_suffix(stem, ".json") { stem = stem[:len(stem)-5] }
	name := make([dynamic]u8, 0, len(stem), allocator)
	capitalize := true
	for index in 0..<len(stem) {
		byte := stem[index]
		if byte == '-' || byte == '_' {
			append(&name, ' ')
			capitalize = true
			continue
		}
		if capitalize && byte >= 'a' && byte <= 'z' { byte -= 'a'-'A' }
		append(&name, byte)
		capitalize = false
	}
	return string(name[:])
}

scratchpad_theme_source_read :: proc(path: string, allocator := context.allocator) -> (source: []u8, too_large: bool, ok: bool) {
	file, open_error := os.open(path)
	if open_error != nil { return nil, false, false }
	defer _ = os.close(file)
	buffer := make([]u8, SCRATCHPAD_THEME_SOURCE_LIMIT+1, allocator)
	if buffer == nil { return nil, false, false }
	used := 0
	for used < len(buffer) {
		count, read_error := os.read(file, buffer[used:])
		used += count
		if read_error != nil {
			if read_error == .EOF { break }
			delete(buffer, allocator)
			return nil, false, false
		}
		if count == 0 { break }
	}
	if used > SCRATCHPAD_THEME_SOURCE_LIMIT {
		delete(buffer, allocator)
		return nil, true, false
	}
	return buffer[:used], false, true
}

scratchpad_theme_catalog_clear :: proc(app: ^App) {
	if app == nil { return }
	for &entry in app.installed_themes { scratchpad_installed_theme_destroy(&entry, context.allocator) }
	delete(app.installed_themes)
	app.installed_themes = make([dynamic]Scratchpad_Installed_Theme, 0, allocator=context.allocator)
}

scratchpad_theme_catalog_reload :: proc(app: ^App) -> bool {
	if app == nil || app.theme_directory == "" { return false }
	entries, read_error := os.read_all_directory_by_path(app.theme_directory, context.temp_allocator)
	if read_error != nil {
		if os.mkdir_all(app.theme_directory) != nil && !os.is_directory(app.theme_directory) { return false }
		entries, read_error = os.read_all_directory_by_path(app.theme_directory, context.temp_allocator)
		if read_error != nil { return false }
	}
	defer os.file_info_slice_delete(entries, context.temp_allocator)
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool { return a.name < b.name })
	scratchpad_theme_catalog_clear(app)
	for entry in entries {
		if entry.type != .Regular || !strings.has_suffix(entry.name, ".json") { continue }
		if len(app.installed_themes) >= SCRATCHPAD_THEME_CATALOG_LIMIT { break }
		stem := entry.name[:len(entry.name)-5]
		// Use the installed filename stem as the opaque stable identity. Slugging
		// here would alias distinct files such as "my_theme.json" and
		// "my-theme.json".
		id := fmt.aprintf("user:%s", stem, allocator=context.allocator)
		name := scratchpad_theme_display_name(entry.name, context.allocator)
		path, path_error := strings.clone(entry.fullpath, context.allocator)
		if path_error != nil { delete(id, context.allocator); delete(name, context.allocator); continue }
		append(&app.installed_themes, Scratchpad_Installed_Theme{id=id, name=name, path=path})
	}
	return true
}

scratchpad_theme_compile_source :: proc(
	id, name: string,
	source: []u8,
	allocator := context.allocator,
) -> Scratchpad_Theme_Candidate {
	candidate := Scratchpad_Theme_Candidate{}
	id_copy, id_error := strings.clone(id, allocator)
	name_copy, name_error := strings.clone(name, allocator)
	candidate.id, candidate.name = id_copy, name_copy
	if id_error != nil || name_error != nil {
		candidate.diagnostic = fmt.aprintf("%s: could not allocate theme identity", name, allocator=allocator)
		return candidate
	}
	candidate.source = make([]u8, len(source), allocator)
	if candidate.source == nil {
		candidate.diagnostic = fmt.aprintf("%s: could not allocate theme source", name, allocator=allocator)
		return candidate
	}
	copy(candidate.source, source)
	path := name
	user := theme.theme_json_parse(string(source), path, allocator)
	defer theme.theme_json_output_destroy(&user, allocator)
	if !user.ok {
		if len(user.diagnostics) > 0 {
			diagnostic := user.diagnostics[0]
			candidate.diagnostic = fmt.aprintf("%s:%d:%d: %s", name, diagnostic.span.line, diagnostic.span.column, diagnostic.message, allocator=allocator)
		} else {
			candidate.diagnostic = fmt.aprintf("%s: invalid theme JSON", name, allocator=allocator)
		}
		return candidate
	}
	if user.extends != "" && user.extends != "alicorn.base" {
		candidate.diagnostic = fmt.aprintf("%s: only the alicorn.base theme contract is supported", name, allocator=allocator)
		return candidate
	}
	if len(user.source.materials) > 0 {
		candidate.diagnostic = fmt.aprintf("%s: color themes cannot define surface materials; choose a Scratchpad surface treatment separately", name, allocator=allocator)
		return candidate
	}
	for token in user.source.tokens {
		if token.kind != .Color {
			candidate.diagnostic = fmt.aprintf("%s: installable color themes may define color tokens only", name, allocator=allocator)
			return candidate
		}
	}
	for role in user.source.extension_roles {
		if role.kind != .Color {
			candidate.diagnostic = fmt.aprintf("%s: installable color themes may bind color roles only", name, allocator=allocator)
			return candidate
		}
	}
	if len(user.source.button_recipes) > 0 {
		candidate.diagnostic = fmt.aprintf("%s: installable color themes cannot change component behavior", name, allocator=allocator)
		return candidate
	}
	base := theme.theme_builtin_base_source_create(allocator)
	defer theme.theme_builtin_base_source_destroy(&base, allocator)
	workbench := theme.theme_json_parse(SCRATCHPAD_DEFAULT_WORKBENCH_THEME_JSON, "Scratchpad defaults: workbench", allocator)
	defer theme.theme_json_output_destroy(&workbench, allocator)
	paper := theme.theme_json_parse(SCRATCHPAD_DEFAULT_PAPER_THEME_JSON, "Scratchpad defaults: paper", allocator)
	defer theme.theme_json_output_destroy(&paper, allocator)
	if !workbench.ok || !paper.ok || len(base.tokens) == 0 {
		candidate.diagnostic = fmt.aprintf("%s: Scratchpad's built-in theme defaults could not be loaded", name, allocator=allocator)
		return candidate
	}
	compiled := theme.theme_compile(
		{base.model, workbench.source, paper.source, user.source},
		support=theme.THEME_COMPILER_SUPPORT,
		allocator=allocator,
	)
	defer theme.theme_output_destroy(&compiled, allocator)
	if !compiled.ok {
		if len(compiled.diagnostics) > 0 {
			diagnostic := compiled.diagnostics[0]
			candidate.diagnostic = fmt.aprintf("%s:%d:%d: theme rejected (%v)", diagnostic.path, diagnostic.span.line, diagnostic.span.column, diagnostic.code, allocator=allocator)
		} else {
			candidate.diagnostic = fmt.aprintf("%s: theme compiler rejected the source", name, allocator=allocator)
		}
		return candidate
	}
	style, style_ok := theme.theme_runtime_style_theme(compiled, allocator)
	if !style_ok {
		candidate.diagnostic = fmt.aprintf("%s: theme is incompatible with the Scratchpad style contract", name, allocator=allocator)
		return candidate
	}
	candidate.style = style
	candidate.signature = compiled.theme.content_signature
	candidate.valid = true
	return candidate
}

scratchpad_theme_compile_worker :: proc(data: rawptr) {
	context.allocator = odin_runtime.heap_allocator()
	compiler := cast(^Scratchpad_Theme_Compiler)data
	allocator := odin_runtime.heap_allocator()
	for {
		sync.mutex_lock(&compiler.mutex)
		for !compiler.stopping && !compiler.request_ready {
			sync.cond_wait(&compiler.condition, &compiler.mutex)
		}
		if compiler.stopping {
			sync.mutex_unlock(&compiler.mutex)
			break
		}
		request := compiler.request
		compiler.request = {}
		compiler.request_ready = false
		sync.mutex_unlock(&compiler.mutex)

		source := request.source
		if request.source_path != "" {
			read_source, too_large, read_ok := scratchpad_theme_source_read(request.source_path, allocator)
			if !read_ok {
				message := "theme file is larger than 1 MiB" if too_large else "could not read theme file"
				candidate := Scratchpad_Theme_Candidate{
					id=request.id, name=request.name,
					diagnostic=fmt.aprintf("%s: %s", request.source_path, message, allocator=allocator),
					generation=request.generation,
					install=request.install,
					install_filename=request.install_filename,
				}
				request.id, request.name, request.install_filename = "", "", ""
				request.source_path = ""
				scratchpad_theme_compile_request_destroy(&request, allocator)
				scratchpad_theme_compile_worker_publish(compiler, candidate, allocator)
				continue
			}
			source = read_source
		}
		candidate := scratchpad_theme_compile_source(request.id, request.name, source, allocator)
		candidate.generation = request.generation
		candidate.install = request.install
		filename_copy, filename_error := strings.clone(request.install_filename, allocator)
		candidate.install_filename = filename_copy
		if request.install && filename_error != nil {
			if candidate.valid { theme.theme_runtime_style_theme_destroy(&candidate.style, allocator) }
			candidate.valid = false
			candidate.diagnostic = fmt.aprintf("%s: could not allocate the local theme filename", request.name, allocator=allocator)
		}
		if request.source_path != "" || request.source == nil { delete(source, allocator) }
		scratchpad_theme_compile_request_destroy(&request, allocator)
		scratchpad_theme_compile_worker_publish(compiler, candidate, allocator)
	}
}

scratchpad_theme_compile_worker_publish :: proc(
	compiler: ^Scratchpad_Theme_Compiler,
	candidate: Scratchpad_Theme_Candidate,
	allocator: mem.Allocator,
) {
	sync.mutex_lock(&compiler.mutex)
	if compiler.stopping || candidate.generation != compiler.generation {
		sync.mutex_unlock(&compiler.mutex)
		discarded := candidate
		scratchpad_theme_candidate_destroy(&discarded, allocator)
		return
	}
	if compiler.candidate_ready { scratchpad_theme_candidate_destroy(&compiler.candidate, allocator) }
	compiler.candidate = candidate
	compiler.candidate_ready = true
	sync.mutex_unlock(&compiler.mutex)
	gui.wake(compiler.waker)
}

scratchpad_theme_compiler_start :: proc(compiler: ^Scratchpad_Theme_Compiler, waker: host.Application_Waker) {
	if compiler == nil || compiler.worker != nil { return }
	compiler.waker = waker
	compiler.worker = thread.create_and_start_with_data(
		rawptr(compiler), scratchpad_theme_compile_worker, name="scratchpad-theme-compiler",
	)
}

scratchpad_theme_compiler_request :: proc(
	compiler: ^Scratchpad_Theme_Compiler,
	id, name: string,
	source: string = "",
	source_path := "",
	install_filename := "",
	install := false,
) -> bool {
	if compiler == nil || (source == "" && source_path == "") { return false }
	if compiler.worker == nil { scratchpad_theme_compiler_start(compiler, compiler.waker) }
	if compiler.worker == nil { return false }
	allocator := odin_runtime.heap_allocator()
	request := Scratchpad_Theme_Compile_Request{install=install}
	id_copy, id_error := strings.clone(id, allocator)
	name_copy, name_error := strings.clone(name, allocator)
	path_copy, path_error := strings.clone(source_path, allocator)
	filename_copy, filename_error := strings.clone(install_filename, allocator)
	request.id, request.name = id_copy, name_copy
	request.source_path, request.install_filename = path_copy, filename_copy
	if source != "" {
		request.source = make([]u8, len(source), allocator)
		if request.source == nil { scratchpad_theme_compile_request_destroy(&request, allocator); return false }
		for index in 0..<len(source) { request.source[index] = source[index] }
	}
	if id_error != nil || name_error != nil || path_error != nil || filename_error != nil ||
		request.id == "" || request.name == "" || (source_path != "" && request.source_path == "") ||
		(install && request.install_filename == "") {
		scratchpad_theme_compile_request_destroy(&request, allocator)
		return false
	}
	sync.mutex_lock(&compiler.mutex)
	if compiler.stopping {
		sync.mutex_unlock(&compiler.mutex)
		scratchpad_theme_compile_request_destroy(&request, allocator)
		return false
	}
	if compiler.request_ready { scratchpad_theme_compile_request_destroy(&compiler.request, allocator) }
	compiler.generation += 1
	request.generation = compiler.generation
	if compiler.candidate_ready {
		scratchpad_theme_candidate_destroy(&compiler.candidate, allocator)
		compiler.candidate_ready = false
	}
	compiler.generation = request.generation
	compiler.request = request
	compiler.request_ready = true
	sync.cond_signal(&compiler.condition)
	sync.mutex_unlock(&compiler.mutex)
	return true
}

scratchpad_theme_compiler_invalidate :: proc(compiler: ^Scratchpad_Theme_Compiler) {
	if compiler == nil { return }
	sync.mutex_lock(&compiler.mutex)
	compiler.generation += 1
	if compiler.request_ready { scratchpad_theme_compile_request_destroy(&compiler.request, odin_runtime.heap_allocator()) }
	if compiler.candidate_ready { scratchpad_theme_candidate_destroy(&compiler.candidate, odin_runtime.heap_allocator()) }
	compiler.request_ready = false
	compiler.candidate_ready = false
	sync.mutex_unlock(&compiler.mutex)
}

scratchpad_theme_compiler_take :: proc(compiler: ^Scratchpad_Theme_Compiler) -> (candidate: Scratchpad_Theme_Candidate, found: bool) {
	if compiler == nil { return }
	sync.mutex_lock(&compiler.mutex)
	if compiler.candidate_ready {
		candidate = compiler.candidate
		compiler.candidate = {}
		compiler.candidate_ready = false
		found = true
	}
	sync.mutex_unlock(&compiler.mutex)
	return
}

scratchpad_theme_compiler_stop :: proc(compiler: ^Scratchpad_Theme_Compiler) {
	if compiler == nil { return }
	if compiler.worker != nil {
		sync.mutex_lock(&compiler.mutex)
		compiler.stopping = true
		sync.cond_broadcast(&compiler.condition)
		sync.mutex_unlock(&compiler.mutex)
		thread.join(compiler.worker)
		thread.destroy(compiler.worker)
		compiler.worker = nil
	}
	allocator := odin_runtime.heap_allocator()
	if compiler.request_ready { scratchpad_theme_compile_request_destroy(&compiler.request, allocator) }
	if compiler.candidate_ready { scratchpad_theme_candidate_destroy(&compiler.candidate, allocator) }
	compiler.request_ready = false
	compiler.candidate_ready = false
}

scratchpad_theme_load_installed :: proc(app: ^App, id: string) -> (candidate: Scratchpad_Theme_Candidate, found: bool) {
	if app == nil { return }
	for entry in app.installed_themes {
		if entry.id != id { continue }
		source, too_large, read_ok := scratchpad_theme_source_read(entry.path, context.temp_allocator)
		if !read_ok {
			message := "theme file is larger than 1 MiB" if too_large else "could not read theme file"
			candidate = Scratchpad_Theme_Candidate{
				id=fmt.aprintf("%s", entry.id, allocator=context.allocator),
				name=fmt.aprintf("%s", entry.name, allocator=context.allocator),
				diagnostic=fmt.aprintf("%s: %s", entry.path, message, allocator=context.allocator),
			}
			return candidate, true
		}
		defer delete(source, context.temp_allocator)
		candidate = scratchpad_theme_compile_source(entry.id, entry.name, source, context.allocator)
		return candidate, true
	}
	return {}, false
}

scratchpad_theme_candidate_apply :: proc(app: ^App, rt: ^alicorn.Runtime, candidate: ^Scratchpad_Theme_Candidate) -> bool {
	if app == nil || rt == nil || candidate == nil || !candidate.valid { return false }
	new_id, id_error := strings.clone(candidate.id, context.allocator)
	new_name, name_error := strings.clone(candidate.name, context.allocator)
	if id_error != nil || name_error != nil {
		delete(new_id, context.allocator)
		delete(new_name, context.allocator)
		return false
	}
	keep_selection_copies := false
	defer {
		if !keep_selection_copies {
			delete(new_id, context.allocator)
			delete(new_name, context.allocator)
		}
	}
	if !scratchpad_styles_ensure(app, rt) { return false }
	primary_id := app.custom_theme_id
	if primary_id == 0 {
		primary_id = alicorn.style_theme_register(rt, candidate.style)
		if primary_id == 0 { return false }
		// Reserve the Runtime-local slot immediately. If preparing another
		// Runtime fails, the next attempt replaces this hidden slot instead of
		// leaking another permanent theme registration.
		app.custom_theme_id = primary_id
	}
	primary_prepared: alicorn.Style_Theme_Prepared_Replacement
	primary_prepared_valid := false
	if app.custom_theme_id != 0 {
		prepared, preparation := alicorn.style_theme_replace_prepare(rt, primary_id, candidate.style)
		switch preparation {
		case .Rejected: return false
		case .Unchanged:
		case .Prepared: primary_prepared, primary_prepared_valid = prepared, true
		}
	}
	floating: ^Floating_Window_State
	floating_id := alicorn.Style_Theme_ID(0)
	floating_prepared: alicorn.Style_Theme_Prepared_Replacement
	floating_prepared_valid := false
	if app.floating_window != nil && app.floating_window.runtime != nil && rt == app.primary_runtime {
		floating = app.floating_window
		floating_app, scope := floating_editor_scope_enter(floating, floating.runtime)
		if floating_app == nil {
			if primary_prepared_valid { alicorn.style_theme_replace_abort(&primary_prepared) }
			return false
		}
		if !scratchpad_styles_ensure(floating_app, floating.runtime) {
			floating_editor_scope_leave(floating, floating_app, &scope)
			if primary_prepared_valid { alicorn.style_theme_replace_abort(&primary_prepared) }
			return false
		}
		if floating_app.custom_theme_id == 0 {
			floating_id = alicorn.style_theme_register(floating.runtime, candidate.style)
			if floating_id == 0 {
				floating_editor_scope_leave(floating, floating_app, &scope)
				if primary_prepared_valid { alicorn.style_theme_replace_abort(&primary_prepared) }
				return false
			}
			floating_app.custom_theme_id = floating_id
		} else {
			floating_id = floating_app.custom_theme_id
			prepared, preparation := alicorn.style_theme_replace_prepare(floating.runtime, floating_id, candidate.style)
			switch preparation {
			case .Rejected:
				floating_editor_scope_leave(floating, floating_app, &scope)
				if primary_prepared_valid { alicorn.style_theme_replace_abort(&primary_prepared) }
				return false
			case .Unchanged:
			case .Prepared:
				floating_prepared, floating_prepared_valid = prepared, true
			}
		}
		floating_editor_scope_leave(floating, floating_app, &scope)
	}
	// The candidate is fully copied and validated for every Runtime before
	// either visible theme changes. Commit is allocation-free and both windows
	// are serialized on this host callback while between frames.
	if floating_prepared_valid && alicorn.style_theme_replace_commit(floating.runtime, &floating_prepared) == .Rejected {
		if primary_prepared_valid { alicorn.style_theme_replace_abort(&primary_prepared) }
		return false
	}
	if primary_prepared_valid && alicorn.style_theme_replace_commit(rt, &primary_prepared) == .Rejected { return false }
	if app.custom_theme_ready {
		theme.theme_runtime_style_theme_destroy(&app.custom_theme_style, odin_runtime.heap_allocator())
	}
	app.custom_theme_id = primary_id
	app.custom_theme_style = candidate.style
	app.custom_theme_ready = true
	candidate.style = {}
	candidate.valid = false
	app.workbench_theme, app.editor_theme = app.custom_theme_id, app.custom_theme_id
	if floating != nil && floating_id != 0 {
		floating_app, scope := floating_editor_scope_enter(floating, floating.runtime)
		if floating_app != nil {
			floating_app.custom_theme_id = floating_id
			floating_app.workbench_theme, floating_app.editor_theme = floating_id, floating_id
			floating_editor_scope_leave(floating, floating_app, &scope)
		}
		alicorn.invalidate_root(floating.runtime, "Scratchpad user theme preview changed")
	}
	app.theme_choice = .Warm
	if len(app.selected_theme_id) > 0 { delete(app.selected_theme_id, context.allocator) }
	if len(app.selected_theme_name) > 0 { delete(app.selected_theme_name, context.allocator) }
	app.selected_theme_id, app.selected_theme_name = new_id, new_name
	keep_selection_copies = true
	alicorn.invalidate_root(rt, "Scratchpad user theme preview changed")
	return true
}

scratchpad_theme_compile_installed_request :: proc(app: ^App, id: string) -> bool {
	if app == nil { return false }
	for entry in app.installed_themes {
		if entry.id == id {
			return scratchpad_theme_compiler_request(
				&app.theme_compiler, entry.id, entry.name, source_path=entry.path,
			)
		}
	}
	return false
}

scratchpad_theme_compile_mocha_request :: proc(app: ^App) -> bool {
	if app == nil { return false }
	return scratchpad_theme_compiler_request(
		&app.theme_compiler, SCRATCHPAD_THEME_BUILTIN_MOCHA, "Catppuccin Mocha",
		SCRATCHPAD_CATPPUCCIN_MOCHA_THEME_JSON,
	)
}

scratchpad_theme_request_select :: proc(app: ^App, rt: ^alicorn.Runtime, id: string, persist := true) -> bool {
	if app == nil || rt == nil || id == "" { return false }
	scratchpad_theme_compile_error_set(app, "")
	if id == SCRATCHPAD_THEME_BUILTIN_WARM {
		scratchpad_theme_compiler_invalidate(&app.theme_compiler)
		app.theme_compile_pending = false
		delete(app.theme_compile_requested_id, context.allocator)
		app.theme_compile_requested_id = ""
		return scratchpad_theme_select(app, rt, .Warm, persist)
	}
	if id == SCRATCHPAD_THEME_BUILTIN_COOL {
		scratchpad_theme_compiler_invalidate(&app.theme_compiler)
		app.theme_compile_pending = false
		delete(app.theme_compile_requested_id, context.allocator)
		app.theme_compile_requested_id = ""
		return scratchpad_theme_select(app, rt, .Cool_Light, persist)
	}
	if id == SCRATCHPAD_THEME_BUILTIN_CHARCOAL {
		scratchpad_theme_compiler_invalidate(&app.theme_compiler)
		app.theme_compile_pending = false
		delete(app.theme_compile_requested_id, context.allocator)
		app.theme_compile_requested_id = ""
		return scratchpad_theme_select(app, rt, .Charcoal_Ink, persist)
	}
	queued := false
	if id == SCRATCHPAD_THEME_BUILTIN_MOCHA {
		queued = scratchpad_theme_compile_mocha_request(app)
	} else {
		queued = scratchpad_theme_compile_installed_request(app, id)
	}
	if !queued {
		scratchpad_theme_compile_error_set(app, "Could not queue the selected theme for validation.")
		return false
	}
	if !scratchpad_theme_pending_set(app, id) {
		scratchpad_theme_compiler_invalidate(&app.theme_compiler)
		scratchpad_theme_compile_error_set(app, "Could not retain the selected theme identity.")
		return false
	}
	if !app.theme_preview_active && persist {
		// Keep the old selected ID until the compiled candidate has been
		// validated and adopted by all live runtimes.
	}
	alicorn.invalidate_root(rt, "Scratchpad theme preview queued")
	return true
}

scratchpad_theme_path_basename :: proc(path: string) -> string {
	start := 0
	for index in 0..<len(path) {
		if path[index] == '/' || path[index] == '\\' { start = index+1 }
	}
	return path[start:]
}

scratchpad_theme_request_import :: proc(app: ^App, path: string) -> bool {
	if app == nil || path == "" || app.theme_directory == "" || len(app.installed_themes) >= SCRATCHPAD_THEME_CATALOG_LIMIT {
		scratchpad_theme_compile_error_set(app, "The local theme folder is full or unavailable.")
		return false
	}
	base := scratchpad_theme_path_basename(path)
	name := scratchpad_theme_display_name(base, context.allocator)
	stem := base
	if strings.has_suffix(stem, ".json") { stem = stem[:len(stem)-5] }
	slug := scratchpad_theme_slug(stem, context.allocator)
	collision := 1
	filename := fmt.aprintf("%s.json", slug, allocator=context.allocator)
	id := fmt.aprintf("user:%s", slug, allocator=context.allocator)
	for {
		parts := [2]string{app.theme_directory, filename}
		target, target_error := os.join_path(parts[:], context.temp_allocator)
		exists := target_error == nil && os.exists(target)
		delete(target, context.temp_allocator)
		if !exists { break }
		collision += 1
		if collision > 1000 {
			delete(filename, context.allocator)
			delete(id, context.allocator)
			delete(name, context.allocator)
			delete(slug, context.allocator)
			return false
		}
		delete(filename, context.allocator)
		delete(id, context.allocator)
		filename = fmt.aprintf("%s-%d.json", slug, collision, allocator=context.allocator)
		id = fmt.aprintf("user:%s-%d", slug, collision, allocator=context.allocator)
	}
	queued := scratchpad_theme_compiler_request(
		&app.theme_compiler, id, name, source_path=path,
		install_filename=filename, install=true,
	)
	if queued {
		scratchpad_theme_compile_error_set(app, "")
		if !scratchpad_theme_pending_set(app, id) {
			scratchpad_theme_compiler_invalidate(&app.theme_compiler)
			queued = false
			scratchpad_theme_compile_error_set(app, "Could not retain the imported theme identity.")
		}
	} else {
		scratchpad_theme_compile_error_set(app, "Could not queue this theme for validation. Check its size and the local theme limit.")
	}
	delete(filename, context.allocator)
	delete(id, context.allocator)
	delete(name, context.allocator)
	delete(slug, context.allocator)
	return queued
}

scratchpad_theme_install_candidate :: proc(app: ^App, candidate: ^Scratchpad_Theme_Candidate) -> bool {
	if app == nil || candidate == nil || !candidate.valid || !candidate.install ||
		candidate.install_filename == "" || app.theme_directory == "" {
		return false
	}
	if len(app.installed_themes) >= SCRATCHPAD_THEME_CATALOG_LIMIT { return false }
	parts := [2]string{app.theme_directory, candidate.install_filename}
	path, path_error := os.join_path(parts[:], context.temp_allocator)
	if path_error != nil { return false }
	defer delete(path, context.temp_allocator)
	if os.exists(path) { return false }
	if err := os.mkdir_all(app.theme_directory); err != nil && !(err == .Exist && os.is_directory(app.theme_directory)) { return false }
	temporary_directory, temporary_error := os.make_directory_temp(app.theme_directory, ".theme-import-*", context.temp_allocator)
	if temporary_error != nil { return false }
	defer _ = os.remove_all(temporary_directory)
	temporary_parts := [2]string{temporary_directory, "theme.json"}
	temporary_path, temporary_path_error := os.join_path(temporary_parts[:], context.temp_allocator)
	if temporary_path_error != nil { return false }
	defer delete(temporary_path, context.temp_allocator)
	defer _ = os.remove(temporary_path)
	if os.write_entire_file(temporary_path, candidate.source) != nil { return false }
	// Hard-link publication is atomic and fails if another Scratchpad instance
	// already installed the same name; rename would overwrite on POSIX hosts.
	if os.link(temporary_path, path) != nil { return false }
	return scratchpad_theme_catalog_reload(app)
}

Scratchpad_Theme_Customize_Role :: enum u8 { Paper, Accent, Keyword, Surface }
SCRATCHPAD_THEME_CUSTOMIZE_ROLE_LABELS :: [4]string{"Editor paper", "Accent", "Syntax keyword", "Workbench surface"}
SCRATCHPAD_THEME_CUSTOMIZE_ROLE_KEYS :: [4]string{"paper", "accent", "keyword", "surface"}

scratchpad_theme_json_space :: proc(value: u8) -> bool {
	return value == ' ' || value == '\t' || value == '\r' || value == '\n'
}

scratchpad_theme_json_string_end :: proc(source: string, start, limit: int) -> int {
	if start < 0 || start >= limit || source[start] != '"' { return -1 }
	index := start+1
	for index < limit {
		if source[index] == '\\' { index += 2; continue }
		if source[index] == '"' { return index+1 }
		index += 1
	}
	return -1
}

scratchpad_theme_json_value_end :: proc(source: string, start, limit: int) -> int {
	if start < 0 || start >= limit { return -1 }
	if source[start] == '"' { return scratchpad_theme_json_string_end(source, start, limit) }
	if source[start] == '{' || source[start] == '[' {
		depth_object, depth_array := 0, 0
		in_string, escaped := false, false
		for index in start..<limit {
			byte := source[index]
			if in_string {
				if escaped { escaped = false }
				else if byte == '\\' { escaped = true }
				else if byte == '"' { in_string = false }
				continue
			}
			if byte == '"' { in_string = true; continue }
			if byte == '{' { depth_object += 1 }
			if byte == '}' { depth_object -= 1 }
			if byte == '[' { depth_array += 1 }
			if byte == ']' { depth_array -= 1 }
			if depth_object == 0 && depth_array == 0 { return index+1 }
		}
		return -1
	}
	index := start
	for index < limit && source[index] != ',' && source[index] != '}' && source[index] != ']' { index += 1 }
	for index > start && scratchpad_theme_json_space(source[index-1]) { index -= 1 }
	return index
}

scratchpad_theme_json_object_member :: proc(source: string, object_start, object_end: int, key: string) -> (value_start, value_end: int, found: bool) {
	if object_start < 0 || object_end > len(source) || object_start >= object_end || source[object_start] != '{' { return }
	index := object_start+1
	for index < object_end-1 {
		for index < object_end-1 && (scratchpad_theme_json_space(source[index]) || source[index] == ',') { index += 1 }
		if index >= object_end-1 || source[index] != '"' { return }
		key_start := index
		key_end := scratchpad_theme_json_string_end(source, index, object_end)
		if key_end < 0 { return }
		index = key_end
		for index < object_end && scratchpad_theme_json_space(source[index]) { index += 1 }
		if index >= object_end || source[index] != ':' { return }
		index += 1
		for index < object_end && scratchpad_theme_json_space(source[index]) { index += 1 }
		value_start = index
		value_end = scratchpad_theme_json_value_end(source, value_start, object_end)
		if value_end < 0 { return 0, 0, false }
		if source[key_start+1:key_end-1] == key { return value_start, value_end, true }
		index = value_end
	}
	return 0, 0, false
}

scratchpad_theme_json_object_set :: proc(source: string, object_start, object_end: int, key, value: string, allocator := context.allocator) -> (updated: string, ok: bool) {
	if object_start < 0 || object_end > len(source) || object_start >= object_end || source[object_start] != '{' || source[object_end-1] != '}' { return "", false }
	value_start, value_end, found := scratchpad_theme_json_object_member(source, object_start, object_end, key)
	if found {
		parts := [3]string{source[:value_start], value, source[value_end:]}
		combined, err := strings.concatenate(parts[:], allocator)
		return combined, err == nil
	}
	insert := object_end-1
	content := object_start+1
	for content < insert && scratchpad_theme_json_space(source[content]) { content += 1 }
	separator := ","
	if content == insert { separator = "" }
	property := fmt.aprintf("%s\"%s\":%s", separator, key, value, allocator=allocator)
	defer delete(property, allocator)
	parts := [3]string{source[:insert], property, source[insert:]}
	combined, err := strings.concatenate(parts[:], allocator)
	return combined, err == nil
}

scratchpad_theme_json_set_role :: proc(source: string, core: bool, key, value: string, allocator := context.allocator) -> (updated: string, ok: bool) {
	root_start, root_end := 0, len(source)
	roles_start, roles_end, roles_found := scratchpad_theme_json_object_member(source, root_start, root_end, "roles")
	if !roles_found {
		kind := "extensions"
		if core { kind = "core" }
		roles := fmt.aprintf("{\"%s\":{\"%s\":%s}}", kind, key, value, allocator=allocator)
		defer delete(roles, allocator)
		return scratchpad_theme_json_object_set(source, root_start, root_end, "roles", roles, allocator)
	}
	category := "extensions"
	if core { category = "core" }
	category_start, category_end, category_found := scratchpad_theme_json_object_member(source, roles_start, roles_end, category)
	if !category_found {
		category_source := fmt.aprintf("{\"%s\":%s}", key, value, allocator=allocator)
		defer delete(category_source, allocator)
		new_roles, set_ok := scratchpad_theme_json_object_set(source, roles_start, roles_end, category, category_source, allocator)
		return new_roles, set_ok
	}
	return scratchpad_theme_json_object_set(source, category_start, category_end, key, value, allocator)
}

scratchpad_theme_color_hex :: proc(value: string) -> (r, g, b: f32, ok: bool) {
	if len(value) != 7 || value[0] != '#' { return 0, 0, 0, false }
	parse := proc(first, second: u8) -> (u32, bool) {
		digit := proc(character: u8) -> (u32, bool) {
			if character >= '0' && character <= '9' { return u32(character-'0'), true }
			if character >= 'a' && character <= 'f' { return u32(character-'a'+10), true }
			if character >= 'A' && character <= 'F' { return u32(character-'A'+10), true }
			return 0, false
		}
		a, a_ok := digit(first); c, c_ok := digit(second)
		return a*16+c, a_ok && c_ok
	}
	red, red_ok := parse(value[1], value[2])
	green, green_ok := parse(value[3], value[4])
	blue, blue_ok := parse(value[5], value[6])
	if !red_ok || !green_ok || !blue_ok { return 0, 0, 0, false }
	return f32(red)/255, f32(green)/255, f32(blue)/255, true
}

scratchpad_theme_color_override_source :: proc(
	source: []u8,
	role: Scratchpad_Theme_Customize_Role,
	hex: string,
	allocator := context.allocator,
) -> (updated: []u8, ok: bool) {
	if role < .Paper || role > .Surface { return nil, false }
	r, g, b, color_ok := scratchpad_theme_color_hex(hex)
	if !color_ok { return nil, false }
	role_keys := SCRATCHPAD_THEME_CUSTOMIZE_ROLE_KEYS
	key := role_keys[int(role)]
	token := fmt.aprintf("scratchpad.custom.%s", key, allocator=allocator)
	defer delete(token, allocator)
	token_value := fmt.aprintf(
		"{\"$type\":\"color\",\"$value\":{\"colorSpace\":\"srgb\",\"components\":[%.6f,%.6f,%.6f],\"alpha\":1}}",
		r, g, b, allocator=allocator,
	)
	defer delete(token_value, allocator)
	text := string(source)
	tokens_start, tokens_end, tokens_found := scratchpad_theme_json_object_member(text, 0, len(text), "tokens")
	if !tokens_found { return nil, false }
	with_token, token_ok := scratchpad_theme_json_object_set(text, tokens_start, tokens_end, token, token_value, allocator)
	if !token_ok { return nil, false }
	defer delete(with_token, allocator)
	alias := fmt.aprintf("{%s}", token, allocator=allocator)
	defer delete(alias, allocator)
	with_role: string
	role_ok := false
	if role == .Accent || role == .Surface {
		quoted_alias := fmt.aprintf("\"%s\"", alias, allocator=allocator)
		defer delete(quoted_alias, allocator)
		with_role, role_ok = scratchpad_theme_json_set_role(with_token, true, "accent" if role == .Accent else "surface", quoted_alias, allocator)
	} else {
		role_name := "app.scratchpad.editor.paper_surface" if role == .Paper else "app.scratchpad.syntax.keyword"
		extension_value := fmt.aprintf("{\"$type\":\"color\",\"$value\":\"%s\"}", alias, allocator=allocator)
		defer delete(extension_value, allocator)
		with_role, role_ok = scratchpad_theme_json_set_role(with_token, false, role_name, extension_value, allocator)
	}
	if !role_ok { return nil, false }
	defer delete(with_role, allocator)
	updated = make([]u8, len(with_role), allocator)
	if updated == nil { return nil, false }
	copy(updated, with_role)
	return updated, true
}

scratchpad_theme_customize_source :: proc(app: ^App, id: string, allocator := context.allocator) -> (source: []u8, ok: bool) {
	if app == nil { return }
	switch id {
	case SCRATCHPAD_THEME_BUILTIN_WARM:
		source = make([]u8, len(SCRATCHPAD_DEFAULT_WORKBENCH_THEME_JSON), allocator)
		if source != nil { copy(source, SCRATCHPAD_DEFAULT_WORKBENCH_THEME_JSON); return source, true }
	case SCRATCHPAD_THEME_BUILTIN_COOL:
		source = make([]u8, len(SCRATCHPAD_COOL_LIGHT_THEME_JSON), allocator)
		if source != nil { copy(source, SCRATCHPAD_COOL_LIGHT_THEME_JSON); return source, true }
	case SCRATCHPAD_THEME_BUILTIN_CHARCOAL:
		source = make([]u8, len(SCRATCHPAD_CHARCOAL_INK_THEME_JSON), allocator)
		if source != nil { copy(source, SCRATCHPAD_CHARCOAL_INK_THEME_JSON); return source, true }
	case SCRATCHPAD_THEME_BUILTIN_MOCHA:
		source = make([]u8, len(SCRATCHPAD_CATPPUCCIN_MOCHA_THEME_JSON), allocator)
		if source != nil { copy(source, SCRATCHPAD_CATPPUCCIN_MOCHA_THEME_JSON); return source, true }
	}
	for entry in app.installed_themes {
		if entry.id != id { continue }
		data, _, read_ok := scratchpad_theme_source_read(entry.path, allocator)
		return data, read_ok
	}
	return nil, false
}

settings_theme_customize_open :: proc(app: ^App) {
	if app == nil || app.selected_theme_id == "" { return }
	alicorn.text_field_buffer_destroy(&app.theme_customize_name)
	alicorn.text_field_buffer_destroy(&app.theme_customize_hex)
	default_name := fmt.aprintf("%s Copy", app.selected_theme_name, allocator=context.temp_allocator)
	app.theme_customize_name, _ = alicorn.text_field_buffer_init(default_name, context.allocator)
	app.theme_customize_hex, _ = alicorn.text_field_buffer_init("#D08770", context.allocator)
	app.theme_customize_role = u64(Scratchpad_Theme_Customize_Role.Paper)+1
	app.theme_customize_open = app.theme_customize_name.initialized && app.theme_customize_hex.initialized
}

scratchpad_theme_customize_submit :: proc(app: ^App, rt: ^alicorn.Runtime) -> bool {
	if app == nil || rt == nil || !app.theme_customize_open || !app.theme_customize_name.initialized || !app.theme_customize_hex.initialized { return false }
	name := strings.trim_space(app.theme_customize_name.text)
	if name == "" || name == "Copy" {
		message := "Enter a name for the duplicated theme."
		set_error(app, message)
		scratchpad_theme_compile_error_set(app, message)
		return false
	}
	role := Scratchpad_Theme_Customize_Role(clamp(app.theme_customize_role-1, u64(0), u64(3)))
	if _, _, _, valid_hex := scratchpad_theme_color_hex(app.theme_customize_hex.text); !valid_hex {
		message := "Enter a color in #RRGGBB format."
		set_error(app, message)
		scratchpad_theme_compile_error_set(app, message)
		return false
	}
	source, source_ok := scratchpad_theme_customize_source(app, app.selected_theme_id, context.allocator)
	if !source_ok {
		message := "Could not read the selected theme for duplication."
		set_error(app, message)
		scratchpad_theme_compile_error_set(app, message)
		return false
	}
	defer delete(source, context.allocator)
	custom_source, custom_ok := scratchpad_theme_color_override_source(source, role, app.theme_customize_hex.text, context.allocator)
	if !custom_ok {
		message := "Could not preserve the selected theme's declarations while adding this color."
		set_error(app, message)
		scratchpad_theme_compile_error_set(app, message)
		return false
	}
	defer delete(custom_source, context.allocator)
	slug := scratchpad_theme_slug(name, context.allocator)
	filename := fmt.aprintf("%s.json", slug, allocator=context.allocator)
	id := fmt.aprintf("user:%s", slug, allocator=context.allocator)
	for collision := 1; ; collision += 1 {
		parts := [2]string{app.theme_directory, filename}
		path, path_error := os.join_path(parts[:], context.temp_allocator)
		exists := path_error == nil && os.exists(path)
		delete(path, context.temp_allocator)
		if !exists { break }
		delete(filename, context.allocator); delete(id, context.allocator)
		filename = fmt.aprintf("%s-%d.json", slug, collision+1, allocator=context.allocator)
		id = fmt.aprintf("user:%s-%d", slug, collision+1, allocator=context.allocator)
		if collision >= 1000 {
			delete(filename, context.allocator); delete(id, context.allocator); delete(slug, context.allocator)
			message := "Could not choose a unique local theme filename."
			set_error(app, message)
			scratchpad_theme_compile_error_set(app, message)
			return false
		}
	}
	queued := scratchpad_theme_compiler_request(&app.theme_compiler, id, name, string(custom_source), install_filename=filename, install=true)
	if queued {
		scratchpad_theme_compile_error_set(app, "")
		if !scratchpad_theme_pending_set(app, id) {
			scratchpad_theme_compiler_invalidate(&app.theme_compiler)
			queued = false
		}
	}
	if queued {
		app.theme_customize_open = false
		set_error(app, "")
		alicorn.invalidate_root(rt, "Scratchpad duplicated theme queued for validation")
	} else {
		message := "Could not queue the duplicated theme for validation."
		set_error(app, message)
		scratchpad_theme_compile_error_set(app, message)
	}
	delete(filename, context.allocator)
	delete(id, context.allocator)
	delete(slug, context.allocator)
	return queued
}

settings_theme_customize_dialog_build :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime, control_height: f32) {
	if app == nil || ui == nil || rt == nil { return }
	alicorn.modal_overlay_begin(ui, alicorn.key_string("theme-customize-overlay"), style=alicorn.layout_style(.Column, grow=1, align=.Center, justify=.Center), backdrop_color=scratchpad_modal_overlay_color(app, rt))
	panel_width := min(600, max(alicorn.viewport_bounds(rt).w-48, 1))
	alicorn.surface_begin(ui, alicorn.surface_core_color_role(.Surface), key=alicorn.key_string("theme-customize-dialog"), label="theme-customize-dialog", style=alicorn.layout_style(.Column, width=panel_width, height=360, padding=20, gap=12), shape=scratchpad_surface_shape(app, 6), material=scratchpad_surface_material(app, app.floating_surface_material), physical_height=scratchpad_surface_height(app, 1), fill=scratchpad_modal_panel_fill(app, rt), backdrop_effect=scratchpad_modal_backdrop_effect(app, rt))
	gui.text(ui, "Duplicate and customize", key="theme-customize-heading", text_style=alicorn.Text_Style{font_size=22, font_weight=alicorn.FONT_WEIGHT_SEMIBOLD})
	gui.text(ui, "The source theme's valid declarations are preserved in the new Alicorn JSON file.")
	if app.theme_compile_error != "" { gui.text(ui, app.theme_compile_error, key="theme-customize-error") }
	gui.text_field(ui, "Theme name", &app.theme_customize_name, key=alicorn.key_string("theme-customize-name"), style=alicorn.layout_style(.Row, width=-1, height=control_height), text_style=SCRATCHPAD_PROMINENT_INPUT_TEXT_STYLE)
	options: [4]alicorn.Select_Option
	role_labels := SCRATCHPAD_THEME_CUSTOMIZE_ROLE_LABELS
	for role in Scratchpad_Theme_Customize_Role { options[int(role)] = {key=u64(role)+1, label=role_labels[int(role)]} }
	choice := alicorn.select_control(ui, alicorn.key_string("theme-customize-role"), "Color to customize", options[:], app.theme_customize_role, style=alicorn.layout_style(.Row, width=-1, height=control_height))
	if choice.changed { app.theme_customize_role = choice.selected_key }
	gui.text_field(ui, "Hex color (#RRGGBB)", &app.theme_customize_hex, key=alicorn.key_string("theme-customize-hex"), style=alicorn.layout_style(.Row, width=-1, height=control_height), text_style=SCRATCHPAD_PROMINENT_INPUT_TEXT_STYLE)
	if gui.row(ui, label="theme-customize-actions", height=control_height, gap=10, align=.End) {
		if gui.button(ui, "Cancel", key="theme-customize-cancel", width=100, height=control_height, variant=.Quiet) { app.theme_customize_open = false }
		if gui.button(ui, "Duplicate", key="theme-customize-submit", width=130, height=control_height, variant=.Primary) { _ = scratchpad_theme_customize_submit(app, rt) }
	}
	alicorn.surface_end(ui)
	alicorn.modal_overlay_end(ui)
}
