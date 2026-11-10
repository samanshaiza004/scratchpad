package backend

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

var ErrRecoveryProfileInUse = errors.New("recovery profile is already in use")
var errRecoveryLockBusy = errors.New("recovery profile lock is held")

type recoveryProfileLock struct {
	file *os.File
}

func acquireRecoveryProfileLock(stateDir string) (*recoveryProfileLock, error) {
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		return nil, fmt.Errorf("create recovery profile directory: %w", err)
	}
	file, err := os.OpenFile(filepath.Join(stateDir, "recovery.lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, fmt.Errorf("open recovery profile lock: %w", err)
	}
	if err := lockRecoveryFile(file); err != nil {
		_ = file.Close()
		if errors.Is(err, errRecoveryLockBusy) {
			return nil, ErrRecoveryProfileInUse
		}
		return nil, fmt.Errorf("lock recovery profile: %w", err)
	}
	return &recoveryProfileLock{file: file}, nil
}

func (lock *recoveryProfileLock) Close() error {
	if lock == nil || lock.file == nil {
		return nil
	}
	file := lock.file
	lock.file = nil
	unlockErr := unlockRecoveryFile(file)
	closeErr := file.Close()
	return errors.Join(unlockErr, closeErr)
}
