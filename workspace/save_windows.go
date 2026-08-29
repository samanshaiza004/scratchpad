//go:build windows

package workspace

import "golang.org/x/sys/windows"

func atomicReplace(source, target string) error {
	return windows.MoveFileEx(windows.StringToUTF16Ptr(source), windows.StringToUTF16Ptr(target), windows.MOVEFILE_REPLACE_EXISTING|windows.MOVEFILE_WRITE_THROUGH)
}

func syncParentDirectory(string) error {
	// Windows has no portable directory-handle equivalent to POSIX fsync.
	// MOVEFILE_WRITE_THROUGH is the platform-specific replacement request.
	return nil
}
