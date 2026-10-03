//go:build !scratchpad_static

package backend

/*
#cgo darwin LDFLAGS: -lcaliber_ffi -Wl,-rpath,@loader_path -Wl,-rpath,@executable_path
#cgo linux LDFLAGS: -lcaliber_ffi -Wl,-rpath,$ORIGIN
// Select the DLL explicitly: -lcaliber_ffi can pick Rust's MSVC static .lib.
#cgo windows LDFLAGS: -l:caliber_ffi.dll
*/
import "C"