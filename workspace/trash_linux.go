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
		if err := os.Rename(path, destination); err != nil {
			if errors.Is(err, os.ErrExist) {
				continue
			}
			return err
		}
		info := fmt.Sprintf("[Trash Info]\nPath=%s\nDeletionDate=%s\n", url.PathEscape(filepath.Clean(path)), time.Now().Format("2006-01-02T15:04:05"))
		if err := os.WriteFile(filepath.Join(root, "info", candidate+".trashinfo"), []byte(info), 0o600); err != nil {
			return fmt.Errorf("write trash metadata: %w", err)
		}
		return nil
	}
	return errors.New("could not choose a unique trash name")
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
