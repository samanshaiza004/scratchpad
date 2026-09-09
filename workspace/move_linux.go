//go:build linux

package workspace

import (
	"os"
	"path/filepath"

	"golang.org/x/sys/unix"
)

func moveNoReplace(root *os.Root, source, destination string) error {
	sourceDir, sourceName := filepath.Split(source)
	destinationDir, destinationName := filepath.Split(destination)

	oldDir, err := openMoveDirectory(root, sourceDir)
	if err != nil {
		return err
	}
	defer oldDir.Close()
	newDir, err := openMoveDirectory(root, destinationDir)
	if err != nil {
		return err
	}
	defer newDir.Close()

	return unix.Renameat2(int(oldDir.Fd()), sourceName, int(newDir.Fd()), destinationName, unix.RENAME_NOREPLACE)
}
