package backend

import (
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

func workspaceRootsEqual(left, right string) bool {
	left = filepath.Clean(left)
	right = filepath.Clean(right)
	if filepath.Separator == '\\' {
		return strings.EqualFold(left, right)
	}
	return left == right
}

func resolveWorkspacePath(path, base string) (string, error) {
	if !filepath.IsAbs(path) {
		if base == "" {
			var err error
			base, err = os.Getwd()
			if err != nil {
				return "", err
			}
		}
		path = filepath.Join(base, path)
	}
	return filepath.Abs(path)
}

func browseWorkspaceDirectories(query, base string) (*WorkspaceBrowse, error) {
	trailingSeparator := strings.HasSuffix(query, "/") || strings.HasSuffix(query, "\\")
	if query == "" {
		query = base
	}
	abs, err := resolveWorkspacePath(query, base)
	if err != nil {
		return nil, err
	}
	abs = filepath.Clean(abs)

	readPath := ""
	prefix := ""
	exactPath := ""
	info, statErr := os.Stat(abs)
	switch {
	case statErr == nil && info.IsDir() && trailingSeparator:
		readPath = abs
	case statErr == nil && info.IsDir():
		exactPath = abs
		readPath = filepath.Dir(abs)
	case statErr == nil:
		readPath = filepath.Dir(abs)
		prefix = filepath.Base(abs)
	case errors.Is(statErr, fs.ErrNotExist):
		readPath = filepath.Dir(abs)
		prefix = filepath.Base(abs)
	default:
		return nil, statErr
	}

	if readPath == "" {
		readPath = string(filepath.Separator)
	}
	readPath, err = filepath.Abs(readPath)
	if err != nil {
		return nil, err
	}
	readPath = filepath.Clean(readPath)
	file, err := os.Open(readPath)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	result := &WorkspaceBrowse{
		DirectoryPath: readPath,
		ParentPath:    filepath.Dir(readPath),
		ExactPath:     exactPath,
		Entries:       make([]DirectoryEntry, 0, MaxWorkspaceBrowseDirectories),
	}
	if workspaceRootsEqual(result.ParentPath, readPath) {
		result.ParentPath = ""
	}
	lowerPrefix := strings.ToLower(prefix)
	scanned := 0
	for scanned < MaxWorkspaceBrowseEntriesScanned {
		batch, readErr := file.ReadDir(min(256, MaxWorkspaceBrowseEntriesScanned-scanned))
		scanned += len(batch)
		for _, entry := range batch {
			if !entry.IsDir() {
				continue
			}
			name := entry.Name()
			if lowerPrefix != "" && !strings.HasPrefix(strings.ToLower(name), lowerPrefix) {
				continue
			}
			if len(result.Entries) == MaxWorkspaceBrowseDirectories {
				result.Truncated = true
				break
			}
			result.Entries = append(result.Entries, DirectoryEntry{
				Name: name,
				Path: filepath.Join(readPath, name),
				Dir:  true,
			})
		}
		if result.Truncated {
			break
		}
		if errors.Is(readErr, io.EOF) {
			break
		}
		if readErr != nil {
			return nil, readErr
		}
	}
	if scanned >= MaxWorkspaceBrowseEntriesScanned {
		result.Truncated = true
	}
	sort.Slice(result.Entries, func(i, j int) bool {
		return strings.ToLower(result.Entries[i].Name) < strings.ToLower(result.Entries[j].Name)
	})
	return result, nil
}
