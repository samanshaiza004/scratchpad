package application

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"scratchpad/workspace"
)

const (
	recentWorkspacesVersion  = 1
	maxRecentWorkspacesBytes = 1 << 20
)

// recentWorkspacesFile is independent from Session so workspace history
// remains available when session restoration is disabled or the session is
// damaged. It contains paths only, never document contents or runtime IDs.
type recentWorkspacesFile struct {
	Version int      `json:"version"`
	Paths   []string `json:"paths"`
}

// LoadRecentWorkspaces reads the bounded, versioned workspace history file.
// Missing paths are retained so the UI can surface an error if the user tries
// to reopen one; transiently unavailable network workspaces are not discarded.
func LoadRecentWorkspaces(path string) ([]string, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, maxRecentWorkspacesBytes+1))
	if err != nil {
		return nil, err
	}
	if len(data) > maxRecentWorkspacesBytes {
		return nil, errors.New("recent workspace history exceeds the 1 MiB limit")
	}
	var history recentWorkspacesFile
	if err := json.Unmarshal(data, &history); err != nil {
		return nil, fmt.Errorf("decode recent workspace history: %w", err)
	}
	if history.Version != recentWorkspacesVersion {
		return nil, fmt.Errorf("recent workspace history has unsupported version %d", history.Version)
	}
	if history.Paths == nil || len(history.Paths) > maxRecentWorkspaces {
		return nil, errors.New("recent workspace history has an invalid path list")
	}
	for _, recentPath := range history.Paths {
		if recentPath == "" || len(recentPath) > 32*1024 {
			return nil, errors.New("recent workspace history contains an invalid path")
		}
	}
	return normalizeRecentWorkspacePaths(history.Paths), nil
}

// SaveRecentWorkspaces atomically replaces the recent-workspace history file.
// The list is normalized, deduplicated, and bounded before it reaches disk.
func SaveRecentWorkspaces(path string, paths []string) error {
	if path == "" {
		return errors.New("recent workspace history path is empty")
	}
	normalized := normalizeRecentWorkspacePaths(paths)
	if normalized == nil {
		normalized = []string{}
	}
	data, err := json.MarshalIndent(recentWorkspacesFile{
		Version: recentWorkspacesVersion,
		Paths:   normalized,
	}, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	return workspace.AtomicWriteFile(path, append(data, '\n'), 0o600)
}
