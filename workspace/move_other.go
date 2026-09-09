//go:build !linux && !darwin && !windows

package workspace

import "os"

func moveNoReplace(root *os.Root, source, destination string) error {
	return ErrNoReplaceSupport
}
