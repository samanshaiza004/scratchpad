package main

import "core:fmt"
import "core:os"

SCRATCHPAD_CONSUMER_BUILD :: #config(SCRATCHPAD_CONSUMER_BUILD, false)

consumer_diagnostic_file: ^os.File
consumer_previous_stdout: ^os.File
consumer_previous_stderr: ^os.File

// Consumer builds have no console. Redirect the native host's stdout/stderr
// to a per-user log before the first SDL call so early initialization failures
// remain diagnosable even when no window can be created. Development builds
// keep the normal console behavior.
scratchpad_consumer_diagnostics_begin :: proc() {
	when SCRATCHPAD_CONSUMER_BUILD {
		config_root, config_error := os.user_config_dir(context.allocator)
		if config_error != nil { return }
		defer delete(config_root, context.allocator)
		directory, preferences_path, ok := scratchpad_theme_preferences_location(config_root, context.allocator)
		if !ok { return }
		defer delete(directory, context.allocator)
		defer delete(preferences_path, context.allocator)
		directory_error := os.mkdir_all(directory)
		if directory_error != nil && !(directory_error == .Exist && os.is_directory(directory)) { return }
		parts := [2]string{directory, "startup.log"}
		path, path_error := os.join_path(parts[:], context.temp_allocator)
		if path_error != nil { return }
		defer delete(path, context.temp_allocator)
		file, open_error := os.open(path, {.Write, .Create, .Trunc, .Sync})
		if open_error != nil { return }
		consumer_previous_stdout = os.stdout
		consumer_previous_stderr = os.stderr
		consumer_diagnostic_file = file
		os.stdout = file
		os.stderr = file
		fmt.fprintln(file, "Scratchpad consumer startup log")
	}
}

scratchpad_consumer_diagnostics_end :: proc() {
	when SCRATCHPAD_CONSUMER_BUILD {
		if consumer_diagnostic_file == nil { return }
		os.stdout = consumer_previous_stdout
		os.stderr = consumer_previous_stderr
		_ = os.close(consumer_diagnostic_file)
		consumer_diagnostic_file = nil
		consumer_previous_stdout = nil
		consumer_previous_stderr = nil
	}
}

scratchpad_consumer_startup_error :: proc(message: string) {
	when SCRATCHPAD_CONSUMER_BUILD {
		if consumer_diagnostic_file != nil && message != "" {
			fmt.fprintln(consumer_diagnostic_file, "Scratchpad backend startup error:", message)
		}
	}
}
