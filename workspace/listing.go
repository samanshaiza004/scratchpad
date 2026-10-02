package workspace

import (
	"context"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

const (
	QuickOpenMaxFiles     = 5000
	QuickOpenMaxPathBytes = 128 << 10
)

var errQuickOpenLimit = errors.New("quick-open path limit reached")

type Entry struct {
	Name string
	Path string
	Dir  bool
}

// ListOptions controls which filesystem entries a one-level directory listing
// exposes. Search and recursive workspace traversal continue to honor ignore
// rules regardless of this presentation option.
type ListOptions struct {
	IncludeIgnored bool
}

// List returns one visible directory level. User dotfiles remain visible;
// repository metadata is omitted from the product tree.
func (w Workspace) List(relative string) ([]Entry, error) {
	return w.ListWithOptions(relative, ListOptions{})
}

// ListWithOptions returns one directory level using an explicit visibility
// policy. Private Scratchpad and Git metadata remain hidden in every mode.
func (w Workspace) ListWithOptions(relative string, options ListOptions) ([]Entry, error) {
	dir := w.Root
	if relative != "" {
		var err error
		dir, err = w.containedPath(relative)
		if err != nil {
			return nil, err
		}
	}
	walker := w.Walker()
	cleanRelative := filepath.Clean(relative)
	if cleanRelative != "." && cleanRelative != "" && isPrivateWorkspacePath(cleanRelative) {
		return nil, nil
	}
	if !options.IncludeIgnored && cleanRelative != "." && cleanRelative != "" && walker.matchPath(cleanRelative, true) {
		return nil, nil
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	result := make([]Entry, 0, len(entries))
	for _, entry := range entries {
		relativePath := filepath.Join(relative, entry.Name())
		if isPrivateWorkspacePath(relativePath) ||
			(!options.IncludeIgnored && walker.matchPath(relativePath, entry.IsDir())) {
			continue
		}
		result = append(result, Entry{Name: entry.Name(), Path: relativePath, Dir: entry.IsDir()})
	}
	sort.Slice(result, func(i, j int) bool {
		if result[i].Dir != result[j].Dir {
			return result[i].Dir
		}
		return result[i].Name < result[j].Name
	})
	return result, nil
}

// Files walks the workspace in deterministic order and emits ordinary files.
// It is deliberately a small filesystem primitive: callers own cancellation,
// presentation, and any asynchronous scheduling around the walk.
func (w Workspace) Files(ctx context.Context, emit func(string) bool) error {
	return w.Walker().Walk(func(path string, entry fs.DirEntry) error {
		if err := ctx.Err(); err != nil {
			return err
		}
		if entry.IsDir() || entry.Type()&fs.ModeSymlink != 0 {
			return nil
		}
		emit(path)
		return nil
	})
}

// QuickOpenFiles returns a deterministic, bounded list of workspace-relative
// paths. It shares the workspace walker's ignore and private-metadata policy,
// and never reads file contents. The truncation flag is explicit so a UI can
// tell the user when the candidate set is capped.
func (w Workspace) QuickOpenFiles(ctx context.Context) (paths []string, truncated bool, err error) {
	if ctx == nil {
		ctx = context.Background()
	}
	pathBytes := 0
	err = w.Walker().Walk(func(path string, entry fs.DirEntry) error {
		if err := ctx.Err(); err != nil {
			return err
		}
		if entry.IsDir() || entry.Type()&fs.ModeSymlink != 0 {
			return nil
		}
		if len(paths) >= QuickOpenMaxFiles {
			truncated = true
			return errQuickOpenLimit
		}
		relative, relErr := filepath.Rel(w.Root, path)
		if relErr != nil {
			return relErr
		}
		relative = filepath.ToSlash(relative)
		if pathBytes+len(relative) > QuickOpenMaxPathBytes {
			truncated = true
			return errQuickOpenLimit
		}
		paths = append(paths, relative)
		pathBytes += len(relative)
		return nil
	})
	if errors.Is(err, errQuickOpenLimit) {
		err = nil
	}
	if err != nil {
		return nil, false, err
	}
	sort.Slice(paths, func(i, j int) bool {
		left, right := strings.ToLower(paths[i]), strings.ToLower(paths[j])
		if left == right {
			return paths[i] < paths[j]
		}
		return left < right
	})
	return paths, truncated, nil
}

func (w Workspace) containedPath(relative string) (string, error) {
	abs, err := filepath.Abs(filepath.Join(w.Root, relative))
	if err != nil {
		return "", err
	}
	if _, err := w.RelativePath(abs); err != nil {
		return "", err
	}
	return abs, nil
}
