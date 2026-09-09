//go:build windows

package workspace

import (
	"fmt"
	"unicode/utf16"
	"unsafe"

	"golang.org/x/sys/windows"
)

type windowsTrasher struct{}

type shellFileOp struct {
	window             uintptr
	function           uint32
	from               *uint16
	to                 *uint16
	flags              uint16
	anyOperationsAbort int32
	nameMappings       uintptr
	progressTitle      *uint16
}

func (windowsTrasher) Trash(path string) error {
	from := append(utf16.Encode([]rune(path)), 0, 0)
	op := shellFileOp{
		function: 3, // FO_DELETE
		from:     &from[0],
		flags:    0x0004 | 0x0010 | 0x0040 | 0x0400, // silent, no confirm, allow undo, no error UI
	}
	shell32 := windows.NewLazySystemDLL("shell32.dll")
	proc := shell32.NewProc("SHFileOperationW")
	result, _, callErr := proc.Call(uintptr(unsafe.Pointer(&op)))
	if result != 0 {
		return fmt.Errorf("move to Recycle Bin: %w (code %d)", callErr, result)
	}
	if op.anyOperationsAbort != 0 {
		return fmt.Errorf("move to Recycle Bin canceled")
	}
	return nil
}
