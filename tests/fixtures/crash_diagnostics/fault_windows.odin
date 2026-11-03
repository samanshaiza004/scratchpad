#+build windows
package crash_diagnostics_probe

import win "core:sys/windows"
foreign import kernel32 "system:Kernel32.lib"
foreign kernel32 { SetErrorMode :: proc "system" (mode: u32) -> u32 --- }

probe_prepare :: proc() { _ = SetErrorMode(0x0002) } // SEM_NOGPFAULTERRORBOX
probe_native_fault :: proc() { win.RaiseException(0xE0000001, 1, 0, nil) }
