package main

/*
#include <stdint.h>
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"
	"runtime"
	"unsafe"

	backend "scratchpad-gpui-backend"
)

var singleton = backend.NewRuntime()

func main() {}

//export scratchpad_gpui_backend_start
func scratchpad_gpui_backend_start(input unsafe.Pointer, inputLen C.size_t, out *unsafe.Pointer, outLen *C.size_t) C.int {
	return safeOutput(out, outLen, func() []byte { return singleton.Start(copyInput(input, inputLen)) })
}

//export scratchpad_gpui_backend_caliber_api
func scratchpad_gpui_backend_caliber_api() (ptr unsafe.Pointer) {
	defer func() {
		if recover() != nil {
			ptr = nil
		}
	}()
	return singleton.CaliberAPIPointer()
}

//export scratchpad_gpui_backend_caliber_context
func scratchpad_gpui_backend_caliber_context() (ptr unsafe.Pointer) {
	defer func() {
		if recover() != nil {
			ptr = nil
		}
	}()
	return singleton.CaliberContextPointer()
}

//export scratchpad_gpui_backend_pump
func scratchpad_gpui_backend_pump(out *unsafe.Pointer, outLen *C.size_t) C.int {
	return safeOutput(out, outLen, singleton.Pump)
}

//export scratchpad_gpui_backend_stop
func scratchpad_gpui_backend_stop(input unsafe.Pointer, inputLen C.size_t, out *unsafe.Pointer, outLen *C.size_t) C.int {
	return safeOutput(out, outLen, func() []byte { return singleton.Stop(copyInput(input, inputLen)) })
}

//export scratchpad_gpui_backend_state_lease_acquired
func scratchpad_gpui_backend_state_lease_acquired() (status C.int) {
	return safeStatus(func() error { return singleton.NoteStateLeaseAcquired() })
}

//export scratchpad_gpui_backend_state_lease_released
func scratchpad_gpui_backend_state_lease_released() (status C.int) {
	return safeStatus(func() error { return singleton.NoteStateLeaseReleased() })
}

//export scratchpad_gpui_backend_resource_lease_acquired
func scratchpad_gpui_backend_resource_lease_acquired() (status C.int) {
	return safeStatus(func() error { return singleton.NoteResourceLeaseAcquired() })
}

//export scratchpad_gpui_backend_resource_lease_released
func scratchpad_gpui_backend_resource_lease_released() (status C.int) {
	return safeStatus(func() error { return singleton.NoteResourceLeaseReleased() })
}

//export scratchpad_gpui_backend_free
func scratchpad_gpui_backend_free(ptr unsafe.Pointer) {
	defer func() { _ = recover() }()
	if ptr != nil {
		C.free(ptr)
	}
}

func writeOutput(data []byte, out *unsafe.Pointer, outLen *C.size_t) C.int {
	if out == nil || outLen == nil {
		return 1
	}
	*out = nil
	*outLen = 0
	if len(data) == 0 {
		return 0
	}
	ptr := C.malloc(C.size_t(len(data)))
	if ptr == nil {
		return 2
	}
	copy(unsafe.Slice((*byte)(ptr), len(data)), data)
	*out = ptr
	*outLen = C.size_t(len(data))
	return 0
}

func safeOutput(out *unsafe.Pointer, outLen *C.size_t, fn func() []byte) (status C.int) {
	defer func() {
		if recovered := recover(); recovered != nil {
			status = writeOutput(panicResponse(recovered), out, outLen)
		}
	}()
	return writeOutput(fn(), out, outLen)
}

func safeStatus(fn func() error) (status C.int) {
	defer func() {
		if recover() != nil {
			status = 2
		}
	}()
	if err := fn(); err != nil {
		return 1
	}
	return 0
}

func panicResponse(value any) []byte {
	data, _ := json.Marshal(backend.Response{
		Version:   backend.ProtocolVersion,
		Lifecycle: "running",
		OK:        false,
		Outcome: backend.Outcome{
			Code:    "internal_panic",
			Message: runtimeError(value),
		},
	})
	return append(data, '\n')
}

func runtimeError(value any) string {
	if err, ok := value.(error); ok {
		return err.Error()
	}
	return "backend panic"
}

func copyInput(input unsafe.Pointer, inputLen C.size_t) []byte {
	if input == nil || inputLen == 0 {
		return nil
	}
	if uint64(inputLen) > uint64(^uint(0)>>1) {
		return nil
	}
	data := make([]byte, int(inputLen))
	copy(data, unsafe.Slice((*byte)(input), int(inputLen)))
	runtime.KeepAlive(input)
	return data
}
