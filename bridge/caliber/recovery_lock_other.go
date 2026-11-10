//go:build !unix && !windows

package backend

import (
	"errors"
	"os"
)

var errRecoveryLockUnsupported = errors.New("recovery profile locking is unsupported on this platform")

func lockRecoveryFile(*os.File) error { return errRecoveryLockUnsupported }

func unlockRecoveryFile(*os.File) error { return nil }
