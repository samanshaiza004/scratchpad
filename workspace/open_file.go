package workspace

import (
	"errors"
	"io/fs"
	"os"
)

// openRegularFile rejects special files before reading them. On Unix the
// platform opener also uses O_NONBLOCK so a symlink retargeted to a FIFO
// between the metadata check and open cannot stall the caller.
func openRegularFile(path string) (*os.File, fs.FileInfo, bool, error) {
	linkInfo, err := os.Lstat(path)
	if err != nil {
		return nil, nil, false, err
	}
	isSymlink := linkInfo.Mode()&os.ModeSymlink != 0
	if !linkInfo.Mode().IsRegular() && !isSymlink {
		return nil, nil, false, errors.New("path is not a regular file")
	}
	if isSymlink {
		targetInfo, err := os.Stat(path)
		if err != nil {
			return nil, nil, true, err
		}
		if !targetInfo.Mode().IsRegular() {
			return nil, nil, true, errors.New("path is not a regular file")
		}
	}
	file, err := openRegularFileHandle(path)
	if err != nil {
		return nil, nil, isSymlink, err
	}
	info, err := file.Stat()
	if err != nil {
		_ = file.Close()
		return nil, nil, isSymlink, err
	}
	if !info.Mode().IsRegular() {
		_ = file.Close()
		return nil, nil, isSymlink, errors.New("path is not a regular file")
	}
	return file, info, isSymlink, nil
}
