//go:build aix || darwin || dragonfly || freebsd || linux || netbsd || openbsd || solaris

package workspace

import (
	"io/fs"
	"syscall"
)

func fileID(_ string, info fs.FileInfo) FileID {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return FileID{}
	}
	return FileID{A: uint64(stat.Dev), B: uint64(stat.Ino), Valid: true}
}

func linkCount(info fs.FileInfo) uint64 {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return 0
	}
	return uint64(stat.Nlink)
}
