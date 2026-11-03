#+build windows
package main

import "core:os"
import win "core:sys/windows"

foreign import diagnostic_kernel32 "system:Kernel32.lib"
foreign diagnostic_kernel32 {
	SetStdHandle :: proc "system" (which: win.DWORD, handle: win.HANDLE) -> win.BOOL ---
}

diagnostic_previous_error_handle: win.HANDLE
diagnostic_error_handle: win.HANDLE
diagnostic_previous_exception_filter: win.LPTOP_LEVEL_EXCEPTION_FILTER

scratchpad_diagnostic_platform_begin :: proc(file: ^os.File) {
	diagnostic_error_handle = win.HANDLE(os.fd(file))
	diagnostic_previous_error_handle = win.GetStdHandle(win.STD_ERROR_HANDLE)
	_ = SetStdHandle(win.STD_ERROR_HANDLE, diagnostic_error_handle)
	diagnostic_previous_exception_filter = win.SetUnhandledExceptionFilter(scratchpad_diagnostic_exception)
	scratchpad_diagnostic_event("session.image_base", u64(uintptr(win.GetModuleHandleW(nil))))
}

scratchpad_diagnostic_platform_end :: proc() {
	_ = win.SetUnhandledExceptionFilter(diagnostic_previous_exception_filter)
	_ = SetStdHandle(win.STD_ERROR_HANDLE, diagnostic_previous_error_handle)
	diagnostic_error_handle = nil
}

// Faulting-thread callback: only a fixed stack buffer and OS writes, with no
// allocation, symbol lookup, application lock, or attempted recovery.
scratchpad_diagnostic_exception :: proc "system" (info: ^win.EXCEPTION_POINTERS) -> win.LONG {
	if diagnostic_error_handle != nil && info != nil && info.ExceptionRecord != nil {
		line: [100]u8
		prefix := "FATAL native exception code/address: "
		n := len(prefix)
		for byte, i in transmute([]u8)prefix { line[i] = byte }
		values := [2]u64{u64(info.ExceptionRecord.ExceptionCode), u64(uintptr(info.ExceptionRecord.ExceptionAddress))}
		hex := "0123456789abcdef"
		for value in values {
			for shift := 60; shift >= 0; shift -= 4 {
				line[n] = hex[(value >> u64(shift)) & 15]
				n += 1
			}
			line[n] = ' '
			n += 1
		}
		line[n] = '\n'
		written: win.DWORD
		_ = win.WriteFile(diagnostic_error_handle, &line[0], win.DWORD(n+1), &written, nil)
		_ = win.FlushFileBuffers(diagnostic_error_handle)
	}
	if diagnostic_previous_exception_filter != nil { return diagnostic_previous_exception_filter(info) }
	return win.EXCEPTION_CONTINUE_SEARCH
}
