//go:build aix || darwin || dragonfly || freebsd || linux || netbsd || openbsd || solaris

package workspace

import (
	"fmt"
	"os"
)

func openMoveDirectory(root *os.Root, relative string) (*os.File, error) {
	if relative == "" {
		relative = "."
	}
	dir, err := root.Open(relative)
	if err != nil {
		return nil, err
	}
	info, err := dir.Stat()
	if err != nil {
		dir.Close()
		return nil, err
	}
	if !info.IsDir() {
		dir.Close()
		return nil, fmt.Errorf("%q: not a directory", relative)
	}
	return dir, nil
}
