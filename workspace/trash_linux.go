//go:build linux

package workspace

import (
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

type linuxTrasher struct{}

func (linuxTrasher) Trash(path string) error {
	root, err := linuxTrashRoot()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Join(root, "files"), 0o700); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Join(root, "info"), 0o700); err != nil {
		return err
	}
	name := filepath.Base(filepath.Clean(path))
	for attempt := 0; attempt < 100; attempt++ {
		candidate := name
		if attempt > 0 {
			candidate = fmt.Sprintf("%s.%d", name, attempt)
		}
		destination := filepath.Join(root, "files", candidate)
		if _, err := os.Lstat(destination); err == nil {
			continue
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}

		infoPath := filepath.Join(root, "info", candidate+".trashinfo")
		info := fmt.Sprintf("[Trash Info]\nPath=%s\nDeletionDate=%s\n", url.PathEscape(filepath.Clean(path)), time.Now().Format("2006-01-02T15:04:05"))
		if err := writeTrashInfo(infoPath, []byte(info)); err != nil {
			if errors.Is(err, os.ErrExist) {
				continue
			}
			return err
		}
		if err := renameTrashEntry(path, destination); err != nil {
			_ = os.Remove(infoPath)
			if errors.Is(err, unix.EEXIST) {
				continue
			}
			return fmt.Errorf("move to trash: %w", err)
		}
		return nil
	}
	return errors.New("could not choose a unique trash name")
}

// writeTrashInfo reserves the candidate name before the source is moved.
// O_EXCL prevents concurrent trash operations from claiming one metadata
// entry or overwriting an existing reservation.
func writeTrashInfo(path string, data []byte) error {
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	if _, err := file.Write(data); err != nil {
		_ = file.Close()
		_ = os.Remove(path)
		return fmt.Errorf("write trash metadata: %w", err)
	}
	if err := file.Sync(); err != nil {
		_ = file.Close()
		_ = os.Remove(path)
		return fmt.Errorf("sync trash metadata: %w", err)
	}
	if err := file.Close(); err != nil {
		_ = os.Remove(path)
		return fmt.Errorf("close trash metadata: %w", err)
	}
	return nil
}

// renameTrashEntry uses Linux's atomic no-replace primitive. Refusing when
// the kernel/filesystem cannot provide it is safer than check-then-rename.
func renameTrashEntry(source, destination string) error {
	err := unix.Renameat2(unix.AT_FDCWD, source, unix.AT_FDCWD, destination, unix.RENAME_NOREPLACE)
	if errors.Is(err, unix.ENOSYS) || errors.Is(err, unix.EINVAL) {
		return fmt.Errorf("%w: renameat2 unavailable: %v", ErrNoReplaceSupport, err)
	}
	return err
}

func linuxTrashRoot() (string, error) {
	if dataHome := strings.TrimSpace(os.Getenv("XDG_DATA_HOME")); dataHome != "" {
		return filepath.Join(dataHome, "Trash"), nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".local", "share", "Trash"), nil
}
