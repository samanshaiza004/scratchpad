//go:build !aix && !darwin && !dragonfly && !freebsd && !linux && !netbsd && !openbsd && !solaris && !windows

package workspace

import "io/fs"

func fileID(string, fs.FileInfo) FileID    { return FileID{} }
func linkCount(string, fs.FileInfo) uint64 { return 0 }
