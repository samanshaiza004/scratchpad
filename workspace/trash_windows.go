//go:build windows

package workspace

import (
	"errors"
	"fmt"
	"runtime"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

type windowsTrasher struct{}

const (
	coInitApartmentThreaded = 0x2
	clsctxInprocServer      = 0x1

	fofSilent           = 0x0004
	fofNoConfirmation   = 0x0010
	fofNoErrorUI        = 0x0400
	fofxRecycleOnDelete = 0x00080000
	fofxEarlyFailure    = 0x00100000

	iFileOperationSetOperationFlags       = 5
	iFileOperationDeleteItem              = 18
	iFileOperationPerformOperations       = 21
	iFileOperationGetAnyOperationsAborted = 22
	iUnknownRelease                       = 2
)

var (
	clsidFileOperation = windows.GUID{
		Data1: 0x3ad05575, Data2: 0x8857, Data3: 0x4850,
		Data4: [8]byte{0x92, 0x77, 0x11, 0xb8, 0x5b, 0xdb, 0x8e, 0x09},
	}
	iidFileOperation = windows.GUID{
		Data1: 0x947aab5f, Data2: 0x0a5c, Data3: 0x4c13,
		Data4: [8]byte{0xb4, 0xd6, 0x4b, 0xf7, 0x83, 0x6f, 0xc9, 0xf8},
	}
	iidShellItem = windows.GUID{
		Data1: 0x43826d1e, Data2: 0xe718, Data3: 0x42ee,
		Data4: [8]byte{0xbc, 0x55, 0xa1, 0xe2, 0x61, 0xc3, 0x7b, 0xfe},
	}
)

func (windowsTrasher) Trash(path string) error {
	major, minor, _ := windows.RtlGetNtVersionNumbers()
	if major < 6 || (major == 6 && minor < 2) {
		return errors.New("Recycle Bin operations require Windows 8 or newer")
	}

	itemPath, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return fmt.Errorf("prepare Recycle Bin path: %w", err)
	}

	// IFileOperation is only supported in a single-threaded apartment.
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	ole32 := windows.NewLazySystemDLL("ole32.dll")
	coInitializeEx := ole32.NewProc("CoInitializeEx")
	result, _, _ := coInitializeEx.Call(0, coInitApartmentThreaded)
	if hresultFailed(result) {
		return hresultError("initialize Windows shell apartment", result)
	}
	defer windows.CoUninitialize()

	var operation unsafe.Pointer
	coCreateInstance := ole32.NewProc("CoCreateInstance")
	result, _, _ = coCreateInstance.Call(
		uintptr(unsafe.Pointer(&clsidFileOperation)),
		0,
		clsctxInprocServer,
		uintptr(unsafe.Pointer(&iidFileOperation)),
		uintptr(unsafe.Pointer(&operation)),
	)
	if hresultFailed(result) {
		return hresultError("create Windows file operation", result)
	}
	if operation == nil {
		return errors.New("create Windows file operation: COM returned a nil interface")
	}
	defer releaseCOM(operation)

	shell32 := windows.NewLazySystemDLL("shell32.dll")
	var item unsafe.Pointer
	createItem := shell32.NewProc("SHCreateItemFromParsingName")
	result, _, _ = createItem.Call(
		uintptr(unsafe.Pointer(itemPath)),
		0,
		uintptr(unsafe.Pointer(&iidShellItem)),
		uintptr(unsafe.Pointer(&item)),
	)
	if hresultFailed(result) {
		return hresultError("resolve Recycle Bin item", result)
	}
	if item == nil {
		return errors.New("resolve Recycle Bin item: shell returned a nil item")
	}
	defer releaseCOM(item)

	// FOFX_RECYCLEONDELETE explicitly requests recycling; FOF_ALLOWUNDO alone
	// only preserves undo information when possible and can fall back to delete.
	flags := fofSilent | fofNoConfirmation | fofNoErrorUI | fofxRecycleOnDelete | fofxEarlyFailure
	result = callCOM(operation, iFileOperationSetOperationFlags, uintptr(flags))
	if hresultFailed(result) {
		return hresultError("configure Recycle Bin operation", result)
	}
	result = callCOM(operation, iFileOperationDeleteItem, uintptr(item), 0)
	if hresultFailed(result) {
		return hresultError("queue Recycle Bin operation", result)
	}

	performResult := callCOM(operation, iFileOperationPerformOperations)
	var aborted uint32
	checkResult := getAnyOperationsAborted(operation, &aborted)
	if hresultFailed(checkResult) {
		return hresultError("check Recycle Bin operation result", checkResult)
	}
	if hresultFailed(performResult) {
		return hresultError("move to Recycle Bin", performResult)
	}
	if aborted != 0 {
		return errors.New("move to Recycle Bin was aborted")
	}
	return nil
}

func callCOM(iface unsafe.Pointer, method uintptr, args ...uintptr) uintptr {
	address := comMethodAddress(iface, method)
	callArgs := make([]uintptr, 1, len(args)+1)
	callArgs[0] = uintptr(iface)
	callArgs = append(callArgs, args...)
	result, _, _ := syscall.SyscallN(address, callArgs...)
	return result
}

func getAnyOperationsAborted(iface unsafe.Pointer, aborted *uint32) uintptr {
	address := comMethodAddress(iface, iFileOperationGetAnyOperationsAborted)
	result, _, _ := syscall.SyscallN(address, uintptr(iface), uintptr(unsafe.Pointer(aborted)))
	runtime.KeepAlive(aborted)
	return result
}

func comMethodAddress(iface unsafe.Pointer, method uintptr) uintptr {
	vtable := *(*unsafe.Pointer)(iface)
	entry := (*uintptr)(unsafe.Add(vtable, method*unsafe.Sizeof(uintptr(0))))
	return *entry
}

func releaseCOM(iface unsafe.Pointer) {
	callCOM(iface, iUnknownRelease)
}

func hresultFailed(result uintptr) bool {
	return int32(uint32(result)) < 0
}

func hresultError(action string, result uintptr) error {
	return fmt.Errorf("%s: HRESULT 0x%08X", action, uint32(result))
}
