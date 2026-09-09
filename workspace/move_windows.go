//go:build windows

package workspace

import (
	"os"
	"path/filepath"

	"golang.org/x/sys/windows"
)

func moveNoReplace(root *os.Root, source, destination string) error {
	// Revalidate both parent directories through os.Root immediately before
	// handing the operation to MoveFileEx. MoveFileEx is the Windows primitive
	// that provides no-replace semantics; the root checks prevent ordinary
	// reparse-point traversal, while the API itself prevents replacement of a
	// destination created concurrently.
	for _, parent := range []string{filepath.Dir(source), filepath.Dir(destination)} {
		dir, err := root.Open(parent)
		if err != nil {
			return err
		}
		if err := dir.Close(); err != nil {
			return err
		}
	}
	// MOVEFILE_REPLACE_EXISTING is intentionally omitted. Windows therefore
	// fails the move when destination already exists. WRITE_THROUGH asks the
	// system to flush the move before returning.
	return windows.MoveFileEx(
		windows.StringToUTF16Ptr(filepath.Join(root.Name(), source)),
		windows.StringToUTF16Ptr(filepath.Join(root.Name(), destination)),
		windows.MOVEFILE_WRITE_THROUGH,
	)
}
