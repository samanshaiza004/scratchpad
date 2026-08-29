//go:build windows

package workspace

import (
	"io/fs"
	"os"

	"golang.org/x/sys/windows"
)

func fileID(path string, _ fs.FileInfo) FileID {
	file, err := os.Open(path)
	if err != nil {
		return FileID{}
	}
	defer file.Close()
	var data windows.ByHandleFileInformation
	if err := windows.GetFileInformationByHandle(windows.Handle(file.Fd()), &data); err != nil {
		return FileID{}
	}
	return FileID{A: uint64(data.VolumeSerialNumber), B: uint64(data.FileIndexHigh)<<32 | uint64(data.FileIndexLow), Valid: true}
}

func linkCount(fs.FileInfo) uint64 { return 0 }
