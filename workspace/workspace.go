// Package workspace owns filesystem policy. It is intentionally separate from
// document state so file authority and in-memory editing can evolve
// independently.
package workspace

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

type Workspace struct {
	Root string
}

// ErrParentDirSync reports that a file replacement completed but the parent
// directory entry could not be flushed. The new bytes are on disk; only the
// durability of the directory entry is weakened. Callers can distinguish it
// with errors.Is and must adopt the verified post-write version so a later
// save does not report their own bytes as an external change.
var ErrParentDirSync = errors.New("replacement completed but parent directory was not flushed")
var ErrVersionChanged = errors.New("file changed during conditional replacement")

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

// AtomicWriteFile writes a replacement beside path, flushes the file, closes
// it, and atomically replaces path. On Unix it also flushes the parent
// directory entry. On Windows the platform implementation requests
// MOVEFILE_WRITE_THROUGH. A successful return is the strongest durability
// contract this package can establish through the host OS; it is not a power-
// loss proof for hardware or filesystems that misreport flush completion.
// When only the parent-directory flush fails, the replacement has already
// completed and AtomicWriteFile returns an error wrapping ErrParentDirSync so
// callers can verify and adopt the new bytes instead of treating the file as
// unwritten.
func AtomicWriteFile(path string, data []byte, mode fs.FileMode) error {
	return atomicWriteFile(path, data, mode, nil, nil)
}

// AtomicWriteFileIfVersion performs the same atomic replacement as
// AtomicWriteFile, but checks the destination's verified content identity
// immediately before replacing it. The replacement is refused if the
// destination was created, removed, or changed since expected was observed.
func AtomicWriteFileIfVersion(path string, data []byte, mode fs.FileMode, expected DiskVersion) error {
	return atomicWriteFile(path, data, mode, &expected, nil)
}

func atomicWriteFile(path string, data []byte, mode fs.FileMode, expected *DiskVersion, beforeReplace func(string)) error {
	targetPath, err := replacementTarget(path)
	if err != nil {
		return err
	}
	targetMode, err := replacementMode(targetPath, mode)
	if err != nil {
		return err
	}
	dir := filepath.Dir(targetPath)
	tmp, err := os.CreateTemp(dir, ".scratchpad-save-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)

	if err := tmp.Chmod(targetMode.Perm()); err != nil {
		_ = tmp.Close()
		return err
	}
	for written := 0; written < len(data); {
		n, err := tmp.Write(data[written:])
		if err != nil {
			_ = tmp.Close()
			return err
		}
		if n == 0 {
			_ = tmp.Close()
			return io.ErrShortWrite
		}
		written += n
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if beforeReplace != nil && expected != nil {
		beforeReplace(filepath.Clean(path))
	}
	if targetPath != filepath.Clean(path) {
		currentTarget, err := filepath.EvalSymlinks(path)
		if err != nil || filepath.Clean(currentTarget) != filepath.Clean(targetPath) {
			return fmt.Errorf("%w: symlink target changed during save", ErrVersionChanged)
		}
	}
	if expected != nil {
		current, err := versionForPath(path)
		if err != nil {
			return err
		}
		if !current.EqualForReplacement(*expected) {
			return ErrVersionChanged
		}
	}
	if err := atomicReplace(tmpName, targetPath); err != nil {
		return err
	}
	if err := syncParentDirectory(dir); err != nil {
		return fmt.Errorf("%w: %w", ErrParentDirSync, err)
	}
	return nil
}

func versionForPath(path string) (DiskVersion, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return DiskVersion{}, nil
		}
		return DiskVersion{}, err
	}
	return verifiedVersion(path, data)
}

func replacementTarget(path string) (string, error) {
	clean := filepath.Clean(path)
	info, err := os.Lstat(clean)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return clean, nil
		}
		return "", err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		target, err := filepath.EvalSymlinks(clean)
		if err != nil {
			return "", fmt.Errorf("resolve symlink %q: %w", path, err)
		}
		targetInfo, err := os.Stat(target)
		if err != nil {
			return "", err
		}
		if !targetInfo.Mode().IsRegular() {
			return "", fmt.Errorf("symlink target %q is not a regular file", target)
		}
		if links := linkCount(target, targetInfo); links > 1 {
			return "", fmt.Errorf("refusing to replace hard-linked file %q", target)
		}
		return filepath.Clean(target), nil
	}
	if !info.Mode().IsRegular() {
		return "", fmt.Errorf("refusing to replace non-regular file %q", path)
	}
	if links := linkCount(clean, info); links > 1 {
		return "", fmt.Errorf("refusing to replace hard-linked file %q", path)
	}
	return clean, nil
}

func replacementMode(path string, requested fs.FileMode) (fs.FileMode, error) {
	info, err := os.Lstat(path)
	if err == nil {
		if !info.Mode().IsRegular() {
			return 0, fmt.Errorf("refusing to replace non-regular file %q", path)
		}
		return info.Mode(), nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return 0, err
	}
	if requested == 0 {
		requested = 0o644
	}
	return requested, nil
}
