//go:build !aix && !darwin && !dragonfly && !freebsd && !linux && !netbsd && !openbsd && !solaris && !windows

package workspace

import "os"

func atomicReplace(source, target string) error {
	return os.Rename(source, target)
}

func syncParentDirectory(string) error { return nil }
