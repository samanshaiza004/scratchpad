#+build !windows
package main

import "core:os"
import "core:sys/posix"

diagnostic_previous_error_fd := posix.FD(-1)

scratchpad_diagnostic_platform_begin :: proc(file: ^os.File) {
	diagnostic_previous_error_fd = posix.dup(2)
	if diagnostic_previous_error_fd >= 0 { _ = posix.dup2(posix.FD(os.fd(file)), 2) }
}

scratchpad_diagnostic_platform_end :: proc() {
	if diagnostic_previous_error_fd < 0 { return }
	_ = posix.dup2(diagnostic_previous_error_fd, 2)
	_ = posix.close(diagnostic_previous_error_fd)
	diagnostic_previous_error_fd = -1
}
