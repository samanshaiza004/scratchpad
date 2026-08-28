// Package workspace owns filesystem policy. It is intentionally separate from
// document state so file authority and in-memory editing can evolve
// independently.
package workspace

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

type Workspace struct {
	Root string
}

func Open(root string) (Workspace, error) {
	abs, err := filepath.Abs(root)
	if err != nil {
		return Workspace{}, err
	}
	info, err := os.Stat(abs)
	if err != nil {
		return Workspace{}, err
	}
	if !info.IsDir() {
		return Workspace{}, errors.New("workspace root is not a directory")
	}
	return Workspace{Root: filepath.Clean(abs)}, nil
}

// RelativePath accepts a path inside the workspace and rejects traversal. It
// does not decide hidden/ignored-file policy; that belongs above this layer.
func (w Workspace) RelativePath(path string) (string, error) {
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	rel, err := filepath.Rel(w.Root, abs)
	if err != nil {
		return "", err
	}
	if rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", errors.New("path is outside workspace")
	}
	return rel, nil
}

// AtomicWriteFile writes a replacement beside path and renames it into place.
// It is a baseline helper for the file-native gate; preserving permissions,
// metadata, Windows replacement semantics, and conflict policy still require
// platform-specific tests.
func AtomicWriteFile(path string, data []byte, mode fs.FileMode) error {
	if mode == 0 {
		mode = 0o644
	}
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".scratchpad-save-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)

	if err := tmp.Chmod(mode.Perm()); err != nil {
		_ = tmp.Close()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpName, path)
}
