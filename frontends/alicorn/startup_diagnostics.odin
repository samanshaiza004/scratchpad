package main

import odin_runtime "base:runtime"
import "core:debug/trace"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

SCRATCHPAD_CONSUMER_BUILD :: #config(SCRATCHPAD_CONSUMER_BUILD, false)
SCRATCHPAD_BUILD_REVISION :: #config(SCRATCHPAD_BUILD_REVISION, "unknown")
SCRATCHPAD_DIAGNOSTIC_SESSIONS :: 8

consumer_diagnostic_file: ^os.File
consumer_previous_stdout: ^os.File
consumer_previous_stderr: ^os.File

// One file per process, opened before SDL/backend initialization. Plain writes
// survive process termination without a shutdown callback or a polling timer.
// Breadcrumbs contain event names and IDs, never source text or query strings.
// Odin passes context by value: the caller must install the returned handler.
scratchpad_consumer_diagnostics_begin :: proc() -> (handler: odin_runtime.Assertion_Failure_Proc) {
	handler = context.assertion_failure_proc
	directory, overridden := os.lookup_env("SCRATCHPAD_DIAGNOSTICS_DIR", context.allocator)
	if !overridden {
		config_root, config_error := os.user_config_dir(context.allocator)
		if config_error != nil { return }
		defer delete(config_root, context.allocator)
		directory, _ = os.join_path({config_root, "Scratchpad", "logs"}, context.allocator)
	}
	defer delete(directory, context.allocator)
	if directory == "" { return }
	directory_error := os.mkdir_all(directory)
	if directory_error != nil && !(directory_error == .Exist && os.is_directory(directory)) { return }
	scratchpad_diagnostic_prune(directory)
	path := fmt.tprintf("%s/session-%d-%d.log", directory, time.to_unix_nanoseconds(time.now()), os.get_pid())
	file, open_error := os.open(path, {.Write, .Create, .Excl}, {.Read_User, .Write_User})
	if open_error != nil { return }
	consumer_previous_stdout, consumer_previous_stderr = os.stdout, os.stderr
	consumer_diagnostic_file = file
	fmt.fprintln(file, "Scratchpad session", SCRATCHPAD_BUILD_REVISION, ODIN_OS, ODIN_ARCH, "pid", os.get_pid())
	fmt.fprintln(consumer_previous_stdout, "Scratchpad diagnostic log:", path)
	os.stderr = file
	when SCRATCHPAD_CONSUMER_BUILD { os.stdout = file }
	handler = scratchpad_diagnostic_assertion
	scratchpad_diagnostic_platform_begin(file)
	scratchpad_diagnostic_event("session.started")
	return
}

scratchpad_diagnostic_prune :: proc(directory: string) {
	entries, err := os.read_all_directory_by_path(directory, context.temp_allocator)
	if err != nil { return }
	defer os.file_info_slice_delete(entries, context.temp_allocator)
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool { return a.name > b.name })
	count := 0
	for entry in entries {
		if entry.type != .Regular || !strings.has_prefix(entry.name, "session-") || !strings.has_suffix(entry.name, ".log") { continue }
		count += 1
		if count >= SCRATCHPAD_DIAGNOSTIC_SESSIONS { _ = os.remove(entry.fullpath) }
	}
}

scratchpad_diagnostic_event :: proc(event: string, projection_key: u64 = 0) {
	if consumer_diagnostic_file == nil { return }
	fmt.fprintln(consumer_diagnostic_file, time.to_unix_nanoseconds(time.now()), event, projection_key)
}

scratchpad_diagnostic_assertion :: proc(prefix, message: string, loc: odin_runtime.Source_Code_Location) -> ! {
	// A secondary failure during symbol lookup must use the normal fatal path.
	context.assertion_failure_proc = odin_runtime.default_assertion_failure_proc
	if file := consumer_diagnostic_file; file != nil {
		fmt.fprintln(file, "FATAL", prefix, message, loc)
		_ = os.sync(file)
		locations, err := trace.resolve(trace.capture(skip=1), context.allocator, context.temp_allocator)
		if err == nil {
			for location in locations { fmt.fprintln(file, location) }
			trace.locations_destroy(locations, context.allocator)
		} else { fmt.fprintln(file, "stack resolution:", trace.resolve_err_string(err)) }
		_ = os.sync(file)
	}
	odin_runtime.default_assertion_failure_proc(prefix, message, loc)
}

scratchpad_consumer_diagnostics_end :: proc() {
	if consumer_diagnostic_file == nil { return }
	scratchpad_diagnostic_event("session.clean_exit")
	_ = os.sync(consumer_diagnostic_file)
	scratchpad_diagnostic_platform_end()
	os.stdout, os.stderr = consumer_previous_stdout, consumer_previous_stderr
	_ = os.close(consumer_diagnostic_file)
	consumer_diagnostic_file = nil
	consumer_previous_stdout, consumer_previous_stderr = nil, nil
}

scratchpad_consumer_startup_error :: proc(message: string) {
	if consumer_diagnostic_file != nil && message != "" {
		fmt.fprintln(consumer_diagnostic_file, "Scratchpad backend startup error:", message)
	}
}
