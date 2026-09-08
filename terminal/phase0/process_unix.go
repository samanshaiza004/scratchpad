//go:build darwin || dragonfly || freebsd || linux || netbsd || openbsd || solaris

package phase0

import (
	"errors"
	"os"
	"syscall"

	pty "github.com/aymanbagabas/go-pty"
)

func terminateProcess(cmd *pty.Cmd) error {
	if cmd == nil || cmd.Process == nil {
		return nil
	}
	// go-pty starts Unix children in a new session. Signal the process group
	// so a shell cannot leave a foreground child behind during Phase 0 cleanup.
	err := syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
	if errors.Is(err, os.ErrProcessDone) || errors.Is(err, syscall.ESRCH) {
		return nil
	}
	return err
}
