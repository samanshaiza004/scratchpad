//go:build windows

package workspace

import "os"

func openRegularFileHandle(path string) (*os.File, error) { return os.Open(path) }
