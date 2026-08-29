package workspace

import (
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
