package crash_diagnostics_probe

import "base:runtime"
import "core:fmt"
import "core:os"
import app "../../../frontends/alicorn"

// Odin's test runner intercepts assertions and OS faults, so the diagnostic
// tests launch this executable to exercise real fatal-error behavior.
main :: proc() {
	probe_prepare()
	context.assertion_failure_proc = app.scratchpad_consumer_diagnostics_begin()
	app.scratchpad_diagnostic_event("probe.before_failure", 42)
	fmt.eprintln("probe library stderr")
	runtime.print_string("probe runtime stderr\n")
	mode := os.args[1] if len(os.args) > 1 else "clean"
	if mode == "panic" { panic("diagnostic probe panic") }
	if mode == "native" { probe_native_fault() }
	app.scratchpad_consumer_diagnostics_end()
	runtime.print_string("probe stderr restored\n")
}
