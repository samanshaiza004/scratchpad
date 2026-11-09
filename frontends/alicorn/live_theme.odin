package main

// Scratchpad's live editor theme is a development-only dogfood hook. It is
// disabled unless SCRATCHPAD_LIVE_EDITOR_THEME_PATH names an opted-in file.
// The worker only watches, compiles and publishes immutable candidates; all
// Runtime mutation stays on the application thread.

import odin_runtime "base:runtime"
import "core:fmt"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"
import alicorn "alicorn:runtime"
import theme "alicorn:theme"
import gui "alicorn:ui"
import host "alicorn:native/sdl_gpu"

SCRATCHPAD_LIVE_EDITOR_THEME_ENV :: "SCRATCHPAD_LIVE_EDITOR_THEME_PATH"
SCRATCHPAD_LIVE_THEME_POLL_INTERVAL :: 80 * time.Millisecond
SCRATCHPAD_LIVE_THEME_DEBOUNCE :: 240 * time.Millisecond
SCRATCHPAD_LIVE_THEME_MAX_SOURCE_BYTES :: i64(1024 * 1024)

Scratchpad_Live_Theme_File_Stamp :: struct {
	size: i64,
	modified_ns: i64,
}

Scratchpad_Live_Theme_Candidate :: struct {
	style: alicorn.Style_Theme,
	has_style: bool,
	diagnostic: string,
	signature: u64,
	source_bytes: i64,
	change_detected_unix_ns: i64,
	compile_duration: time.Duration,
	compiled_at_unix_ns: i64,
}

Scratchpad_Live_Theme :: struct {
	path: string,
	worker: ^thread.Thread,
	waker: host.Application_Waker,
	mutex: sync.Mutex,
	stop_requested: bool,
	candidate_ready: bool,
	candidate: Scratchpad_Live_Theme_Candidate,
	active_style: alicorn.Style_Theme,
	active_style_ready: bool,
	active_signature: u64,
}

scratchpad_live_theme_file_stamp_read :: proc(
	path: string,
	allocator: odin_runtime.Allocator,
) -> (stamp: Scratchpad_Live_Theme_File_Stamp, ok: bool) {
	info, err := os.stat(path, allocator)
	if err != nil { return {}, false }
	defer os.file_info_delete(info, allocator)
	return Scratchpad_Live_Theme_File_Stamp{
		size=info.size,
		modified_ns=time.to_unix_nanoseconds(info.modification_time),
	}, true
}

scratchpad_live_theme_file_stamp_equal :: proc(
	a, b: Scratchpad_Live_Theme_File_Stamp,
) -> bool {
	return a.size == b.size && a.modified_ns == b.modified_ns
}

scratchpad_live_theme_candidate_destroy :: proc(
	candidate: ^Scratchpad_Live_Theme_Candidate,
	allocator: odin_runtime.Allocator,
) {
	if candidate == nil { return }
	if candidate.has_style { theme.theme_runtime_style_theme_destroy(&candidate.style, allocator) }
	delete(candidate.diagnostic, allocator)
	candidate^ = {}
}

scratchpad_live_theme_candidate_error :: proc(
	path: string,
	line, column: u32,
	message: string,
	allocator: odin_runtime.Allocator,
) -> Scratchpad_Live_Theme_Candidate {
	return Scratchpad_Live_Theme_Candidate{
		diagnostic=fmt.aprintf("%s:%d:%d: %s", path, line, column, message, allocator=allocator),
	}
}

scratchpad_live_theme_compile :: proc(
	path: string,
	allocator: odin_runtime.Allocator,
) -> Scratchpad_Live_Theme_Candidate {
	data, read_error := os.read_entire_file(path, allocator)
	if read_error != nil {
		return scratchpad_live_theme_candidate_error(path, 1, 1, "could not read theme source", allocator)
	}
	defer delete(data, allocator)

	parsed := theme.theme_json_parse(string(data), path, allocator)
	defer theme.theme_json_output_destroy(&parsed, allocator)
	if !parsed.ok {
		if len(parsed.diagnostics) > 0 {
			diagnostic := parsed.diagnostics[0]
			return scratchpad_live_theme_candidate_error(
				path, diagnostic.span.line, diagnostic.span.column, diagnostic.message, allocator,
			)
		}
		return scratchpad_live_theme_candidate_error(path, 1, 1, "theme JSON is invalid", allocator)
	}
	if parsed.extends != "" && parsed.extends != "alicorn.base" {
		span := parsed.source.metadata.span
		return scratchpad_live_theme_candidate_error(
			path, span.line, span.column, "only extends = alicorn.base is supported", allocator,
		)
	}

	base := theme.theme_builtin_base_source_create(allocator)
	defer theme.theme_builtin_base_source_destroy(&base, allocator)
	compiled := theme.theme_compile(
		{base.model, parsed.source}, support=theme.THEME_COMPILER_SUPPORT, allocator=allocator,
	)
	defer theme.theme_output_destroy(&compiled, allocator)
	if !compiled.ok {
		if len(compiled.diagnostics) > 0 {
			diagnostic := compiled.diagnostics[0]
			message := fmt.aprintf("theme compiler rejected candidate (%v)", diagnostic.code, allocator=allocator)
			result := scratchpad_live_theme_candidate_error(
				diagnostic.path, diagnostic.span.line, diagnostic.span.column, message, allocator,
			)
			delete(message, allocator)
			return result
		}
		return scratchpad_live_theme_candidate_error(path, 1, 1, "theme compiler rejected candidate", allocator)
	}

	style, style_ok := theme.theme_runtime_style_theme(compiled, allocator)
	if !style_ok {
		return scratchpad_live_theme_candidate_error(
			path, 1, 1, "compiled theme does not fit Alicorn's runtime style contract", allocator,
		)
	}
	materials, materials_ok := theme.theme_runtime_style_materials(compiled, allocator)
	theme.theme_runtime_style_materials_destroy(&materials, allocator)
	if !materials_ok {
		theme.theme_runtime_style_theme_destroy(&style, allocator)
		return scratchpad_live_theme_candidate_error(
			path, 1, 1, "compiled materials do not fit Alicorn's runtime style contract", allocator,
		)
	}
	return Scratchpad_Live_Theme_Candidate{
		style=style,
		has_style=true,
		signature=compiled.theme.content_signature,
	}
}

scratchpad_live_theme_publish :: proc(
	live: ^Scratchpad_Live_Theme,
	candidate: Scratchpad_Live_Theme_Candidate,
) {
	sync.mutex_lock(&live.mutex)
	if live.stop_requested {
		sync.mutex_unlock(&live.mutex)
		discarded := candidate
		scratchpad_live_theme_candidate_destroy(&discarded, odin_runtime.heap_allocator())
		return
	}
	if live.candidate_ready {
		scratchpad_live_theme_candidate_destroy(&live.candidate, odin_runtime.heap_allocator())
	}
	live.candidate = candidate
	live.candidate_ready = true
	sync.mutex_unlock(&live.mutex)
	gui.wake(live.waker)
}

scratchpad_live_theme_watch :: proc(data: rawptr) {
	context.allocator = odin_runtime.heap_allocator()
	live := cast(^Scratchpad_Live_Theme)data
	allocator := odin_runtime.heap_allocator()
	observed: Scratchpad_Live_Theme_File_Stamp
	attempted: Scratchpad_Live_Theme_File_Stamp
	change_detected_unix_ns: i64
	stable_since := time.now()
	for {
		sync.mutex_lock(&live.mutex)
		stopping := live.stop_requested
		sync.mutex_unlock(&live.mutex)
		if stopping { break }

		stamp, exists := scratchpad_live_theme_file_stamp_read(live.path, allocator)
		if !exists {
			observed, attempted = {}, {}
		} else {
			if !scratchpad_live_theme_file_stamp_equal(stamp, observed) {
				observed = stamp
				stable_since = time.now()
				change_detected_unix_ns = time.to_unix_nanoseconds(stable_since)
			}
			if !scratchpad_live_theme_file_stamp_equal(stamp, attempted) &&
				time.diff(stable_since, time.now()) >= SCRATCHPAD_LIVE_THEME_DEBOUNCE {
				compile_started := time.now()
				candidate: Scratchpad_Live_Theme_Candidate
				if stamp.size > SCRATCHPAD_LIVE_THEME_MAX_SOURCE_BYTES {
					candidate = scratchpad_live_theme_candidate_error(
						live.path, 1, 1, "theme source exceeds the 1 MiB development limit", allocator,
					)
				} else {
					candidate = scratchpad_live_theme_compile(live.path, allocator)
				}
				candidate.source_bytes = stamp.size
				candidate.change_detected_unix_ns = change_detected_unix_ns
				candidate.compile_duration = time.diff(compile_started, time.now())
				candidate.compiled_at_unix_ns = time.to_unix_nanoseconds(time.now())
				latest, still_exists := scratchpad_live_theme_file_stamp_read(live.path, allocator)
				if still_exists && scratchpad_live_theme_file_stamp_equal(stamp, latest) {
					attempted = stamp
					scratchpad_live_theme_publish(live, candidate)
				} else {
					scratchpad_live_theme_candidate_destroy(&candidate, allocator)
					observed = latest
					stable_since = time.now()
				}
			}
		}
		time.sleep(SCRATCHPAD_LIVE_THEME_POLL_INTERVAL)
	}
}

scratchpad_live_theme_start :: proc(
	live: ^Scratchpad_Live_Theme,
	waker: host.Application_Waker,
) {
	if live == nil || live.path == "" || live.worker != nil { return }
	live.waker = waker
	live.worker = thread.create_and_start_with_data(
		rawptr(live), scratchpad_live_theme_watch, name="scratchpad-live-editor-theme",
	)
	if live.worker == nil {
		fmt.eprintln("[scratchpad-live-theme] could not start opted-in theme watcher")
	}
}

scratchpad_live_theme_adopt :: proc(live: ^Scratchpad_Live_Theme) {
	if live == nil { return }
	sync.mutex_lock(&live.mutex)
	if !live.candidate_ready {
		sync.mutex_unlock(&live.mutex)
		return
	}
	candidate := live.candidate
	live.candidate = {}
	live.candidate_ready = false
	sync.mutex_unlock(&live.mutex)

	if candidate.has_style {
		if live.active_style_ready && candidate.signature == live.active_signature {
			fmt.println("[scratchpad-live-theme] valid theme unchanged; source_bytes=", candidate.source_bytes,
				" compile=", candidate.compile_duration)
			scratchpad_live_theme_candidate_destroy(&candidate, odin_runtime.heap_allocator())
			return
		}
		if live.active_style_ready {
			theme.theme_runtime_style_theme_destroy(&live.active_style, odin_runtime.heap_allocator())
		}
		live.active_style = candidate.style
		live.active_style_ready = true
		live.active_signature = candidate.signature
		candidate.style = {}
		candidate.has_style = false
		now_ns := time.to_unix_nanoseconds(time.now())
		fmt.println("[scratchpad-live-theme] candidate ready signature=", candidate.signature,
			" source_bytes=", candidate.source_bytes, " compile=", candidate.compile_duration,
			" change_detected_to_adoption_ns=", now_ns-candidate.change_detected_unix_ns)
	} else {
		fmt.println("[scratchpad-live-theme] rejected; last-good theme retained: ", candidate.diagnostic)
	}
	scratchpad_live_theme_candidate_destroy(&candidate, odin_runtime.heap_allocator())
}

scratchpad_live_theme_apply :: proc(
	app: ^App,
	rt: ^alicorn.Runtime,
	applied_theme_id: ^alicorn.Style_Theme_ID,
	applied_signature: ^u64,
	window_name: string,
) -> bool {
	if app == nil || rt == nil || applied_theme_id == nil || applied_signature == nil ||
		!app.live_theme.active_style_ready {
		return false
	}
	if app.style_theme_runtime != rt || app.editor_theme == 0 {
		if !scratchpad_styles_ensure(app, rt) { return false }
	}
	target := app.editor_theme
	if target == 0 || (applied_theme_id^ == target && applied_signature^ == app.live_theme.active_signature) {
		return false
	}
	replacement := alicorn.style_theme_replace(rt, target, app.live_theme.active_style)
	switch replacement {
	case .Replaced:
		applied_theme_id^ = target
		applied_signature^ = app.live_theme.active_signature
		alicorn.invalidate_root(rt, "Scratchpad live editor theme replaced")
		fmt.println("[scratchpad-live-theme] applied window=", window_name,
			" signature=", app.live_theme.active_signature)
		return true
	case .Unchanged:
		applied_theme_id^ = target
		applied_signature^ = app.live_theme.active_signature
		fmt.println("[scratchpad-live-theme] valid theme already active window=", window_name,
			" signature=", app.live_theme.active_signature)
	case .Rejected:
		fmt.eprintln("[scratchpad-live-theme] runtime rejected candidate window=", window_name,
			"; previous theme remains active")
	}
	return false
}

scratchpad_live_theme_stop :: proc(live: ^Scratchpad_Live_Theme) {
	if live == nil { return }
	if live.worker != nil {
		sync.mutex_lock(&live.mutex)
		live.stop_requested = true
		sync.mutex_unlock(&live.mutex)
		thread.join(live.worker)
		thread.destroy(live.worker)
		live.worker = nil
	}
	if live.candidate_ready {
		scratchpad_live_theme_candidate_destroy(&live.candidate, odin_runtime.heap_allocator())
		live.candidate_ready = false
	}
	if live.active_style_ready {
		theme.theme_runtime_style_theme_destroy(&live.active_style, odin_runtime.heap_allocator())
		live.active_style_ready = false
	}
	if live.path != "" { delete(live.path, context.allocator) }
	live.path = ""
}
