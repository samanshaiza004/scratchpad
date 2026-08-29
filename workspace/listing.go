package workspace

import (
	"context"
	"os"
	"path/filepath"
	"sort"
)

type Entry struct {
	Name string
	Path string
	Dir  bool
}

// List returns one visible directory level. User dotfiles remain visible;
// repository metadata is omitted from the product tree.
func (w Workspace) List(relative string) ([]Entry, error) {
	dir := w.Root
	if relative != "" {
		var err error
		dir, err = w.containedPath(relative)
		if err != nil {
			return nil, err
		}
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	result := make([]Entry, 0, len(entries))
	for _, entry := range entries {
		if entry.Name() == ".git" || entry.Name() == ".scratchpad" {
			continue
		}
		result = append(result, Entry{Name: entry.Name(), Path: filepath.Join(relative, entry.Name()), Dir: entry.IsDir()})
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
	return filepath.WalkDir(w.Root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		if path != w.Root && (entry.Name() == ".git" || entry.Name() == ".scratchpad") {
			if entry.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if path == w.Root || entry.IsDir() || entry.Type()&os.ModeSymlink != 0 {
			return nil
		}
		if !emit(path) {
			return nil
		}
		return nil
	})
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
