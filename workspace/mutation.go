package workspace

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

var (
	// ErrPathNotRelative reports a mutation path that is not a non-empty path
	// relative to the workspace root.
	ErrPathNotRelative = errors.New("workspace path must be relative")
	// ErrReservedPath reports an attempt to change Scratchpad or repository
	// metadata through the workspace API.
	ErrReservedPath = errors.New("workspace path is reserved")
	// ErrDestinationExists reports a create or move whose destination already
	// has a directory entry, including a dangling symbolic link.
	ErrDestinationExists = errors.New("workspace destination already exists")
	// ErrMoveIntoSelf reports a move to the source itself or one of its
	// descendants.
	ErrMoveIntoSelf = errors.New("cannot move a path into itself")
	// ErrNoReplaceSupport reports a platform where this package cannot provide
	// an atomic, no-replace move. Refusing the operation is safer than falling
	// back to a check-then-rename race that could overwrite another entry.
	ErrNoReplaceSupport = errors.New("atomic no-replace move is unavailable")
)

// CreateFile exclusively creates an empty regular file at relative. Parents
// must already exist. relative is always interpreted from the workspace root;
// absolute paths, traversal, and .git/.scratchpad are rejected.
func (w Workspace) CreateFile(relative string) error {
	path, err := w.mutationPath(relative)
	if err != nil {
		return err
	}
	root, err := os.OpenRoot(w.Root)
	if err != nil {
		return err
	}
	defer root.Close()

	file, err := root.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		return mutationDestinationError(relative, err)
	}
	return file.Close()
}

// CreateDirectory exclusively creates one directory at relative. Parents must
// already exist. It never creates a hierarchy implicitly.
func (w Workspace) CreateDirectory(relative string) error {
	path, err := w.mutationPath(relative)
	if err != nil {
		return err
	}
	root, err := os.OpenRoot(w.Root)
	if err != nil {
		return err
	}
	defer root.Close()

	if err := root.Mkdir(path, 0o755); err != nil {
		return mutationDestinationError(relative, err)
	}
	return nil
}

// Move changes the name of source to destination without overwriting an
// existing destination. Both paths are workspace-relative. A symbolic-link
// source is moved as a link entry, rather than moving or reading its target.
//
// Linux uses renameat2(RENAME_NOREPLACE); macOS uses renameatx_np(RENAME_EXCL)
// and Windows uses MoveFileEx without MOVEFILE_REPLACE_EXISTING. Other
// platforms return ErrNoReplaceSupport rather than risk a check-then-rename
// race that could overwrite a concurrently-created destination.
func (w Workspace) Move(source, destination string) error {
	sourcePath, err := w.mutationPath(source)
	if err != nil {
		return err
	}
	destinationPath, err := w.mutationPath(destination)
	if err != nil {
		return err
	}
	if sourcePath == destinationPath || isDescendant(destinationPath, sourcePath) {
		return fmt.Errorf("move %q to %q: %w", source, destination, ErrMoveIntoSelf)
	}

	root, err := os.OpenRoot(w.Root)
	if err != nil {
		return err
	}
	defer root.Close()

	// Root methods provide the Go 1.25 containment guarantee for all path
	// inspection. They also reject symlinked intermediate components, while
	// still allowing the source itself to be a symlink entry.
	if _, err := root.Lstat(sourcePath); err != nil {
		return err
	}
	if _, err := root.Lstat(destinationPath); err == nil {
		return fmt.Errorf("move %q to %q: %w", source, destination, ErrDestinationExists)
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}

	if err := moveNoReplace(root, sourcePath, destinationPath); err != nil {
		return mutationDestinationError(destination, err)
	}
	return nil
}

// Lstat returns information for one workspace-relative entry without
// following its final symbolic link. It is a validation primitive for higher
// layers; it never exposes an absolute path outside the workspace.
func (w Workspace) Lstat(relative string) (os.FileInfo, error) {
	path, err := w.inspectionPath(relative)
	if err != nil {
		return nil, err
	}
	root, err := os.OpenRoot(w.Root)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	return root.Lstat(path)
}

// Stat returns information for one workspace-relative entry, following its
// final symbolic link only when the target remains contained by the root.
func (w Workspace) Stat(relative string) (os.FileInfo, error) {
	path, err := w.inspectionPath(relative)
	if err != nil {
		return nil, err
	}
	root, err := os.OpenRoot(w.Root)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	return root.Stat(path)
}

func (w Workspace) inspectionPath(relative string) (string, error) {
	if relative == "" {
		return ".", nil
	}
	return w.mutationPath(relative)
}

func (w Workspace) mutationPath(relative string) (string, error) {
	if relative == "" || filepath.IsAbs(relative) || filepath.VolumeName(relative) != "" {
		return "", fmt.Errorf("%q: %w", relative, ErrPathNotRelative)
	}
	clean := filepath.Clean(relative)
	if clean == "." || clean == ".." || strings.HasPrefix(clean, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("%q: %w", relative, ErrPathNotRelative)
	}
	for _, part := range strings.Split(clean, string(filepath.Separator)) {
		if reservedMutationName(part) {
			return "", fmt.Errorf("%q: %w", relative, ErrReservedPath)
		}
	}
	return clean, nil
}

func reservedMutationName(name string) bool {
	if runtime.GOOS == "windows" {
		return strings.EqualFold(name, ".git") || strings.EqualFold(name, ".scratchpad")
	}
	return name == ".git" || name == ".scratchpad"
}

func mutationDestinationError(path string, err error) error {
	if errors.Is(err, os.ErrExist) {
		return fmt.Errorf("%q: %w", path, ErrDestinationExists)
	}
	return err
}

func isDescendant(path, ancestor string) bool {
	return strings.HasPrefix(path, ancestor+string(filepath.Separator))
}
