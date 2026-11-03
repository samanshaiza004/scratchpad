package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_diagnostics_survive_fatal_subprocess_and_restore_stderr :: proc(t: ^testing.T) {
	probe, probe_found := os.lookup_env("SCRATCHPAD_DIAGNOSTIC_PROBE_EXE", context.temp_allocator)
	if !probe_found { testing.expect(t, false, "diagnostics regression requires the standalone crash probe"); return }
	root, root_error := os.make_directory_temp("", "scratchpad-diagnostics-*", context.temp_allocator)
	if root_error != nil { testing.expect(t, false, "diagnostics fixture must exist"); return }
	defer _ = os.remove_all(root)
	inherited, env_error := os.environ(context.temp_allocator)
	if env_error != nil { testing.expect(t, false, "child environment must be readable"); return }
	modes := []string{"clean", "panic"}
	when ODIN_OS == .Windows { modes = []string{"clean", "panic", "native"} }
	for mode in modes {
		directory := fmt.tprintf("%s/%s", root, mode)
		environment := make([dynamic]string, 0, allocator=context.temp_allocator)
		for variable in inherited {
			if strings.has_prefix(variable, "SCRATCHPAD_DIAGNOSTICS_DIR=") || strings.has_prefix(variable, "SCRATCHPAD_DIAGNOSTIC_PROBE=") { continue }
			append(&environment, variable)
		}
		append(&environment, fmt.tprintf("SCRATCHPAD_DIAGNOSTICS_DIR=%s", directory))
		state, stdout, stderr, err := os.process_exec(os.Process_Desc{
			command=[]string{probe, mode}, env=environment[:],
		}, context.temp_allocator)
		defer delete(stdout, context.temp_allocator)
		defer delete(stderr, context.temp_allocator)
		testing.expect(t, err == nil, "diagnostic child must launch")
		testing.expect(t, (state.exit_code == 0) == (mode == "clean"), "only a clean child should exit successfully")
		entries, read_error := os.read_all_directory_by_path(directory, context.temp_allocator)
		if read_error != nil { testing.expect(t, false, "child must leave a persistent session log"); continue }
		defer os.file_info_slice_delete(entries, context.temp_allocator)
		testing.expect(t, len(entries) == 1, "one child must create exactly one session log")
		if len(entries) != 1 { continue }
		data, data_error := os.read_entire_file(entries[0].fullpath, context.temp_allocator)
		defer delete(data, context.temp_allocator)
		text := string(data)
		testing.expect(t, data_error == nil && strings.contains(text, "Scratchpad session") &&
			strings.contains(text, "probe.before_failure 42") && strings.contains(text, "probe library stderr") &&
			strings.contains(text, "probe runtime stderr"), "metadata, breadcrumbs and both stderr paths must survive termination")
		testing.expect(t, strings.contains(text, "session.clean_exit") == (mode == "clean"), "a fatal exit must never be marked clean")
		if mode == "panic" {
			testing.expect(t, strings.contains(text, "FATAL panic diagnostic probe panic") &&
				strings.contains(text, "main.odin"), "panic log must include source and stack information")
		}
		if mode == "native" { testing.expect(t, strings.contains(text, "FATAL native exception code/address: 00000000e0000001"), "native faults must preserve their exception code") }
		if mode == "clean" { testing.expect(t, strings.contains(string(stderr), "probe stderr restored"), "clean shutdown must restore process stderr") }
	}
}
