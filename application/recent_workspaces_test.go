package application

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestRecentWorkspacesFileRoundTripIsNormalizedAndBounded(t *testing.T) {
	root := t.TempDir()
	paths := make([]string, maxRecentWorkspaces+2)
	for index := range paths {
		paths[index] = filepath.Join(root, "workspace", string(rune('a'+index)))
	}
	paths = append([]string{paths[1]}, paths...)
	path := filepath.Join(root, "state", "recent-workspaces.json")
	if err := SaveRecentWorkspaces(path, paths); err != nil {
		t.Fatalf("save recent workspaces: %v", err)
	}
	loaded, err := LoadRecentWorkspaces(path)
	if err != nil {
		t.Fatalf("load recent workspaces: %v", err)
	}
	want := normalizeRecentWorkspacePaths(paths)
	if len(loaded) != maxRecentWorkspaces || len(loaded) != len(want) {
		t.Fatalf("loaded recent workspace count = %d, want %d", len(loaded), len(want))
	}
	for index := range want {
		if loaded[index] != want[index] {
			t.Fatalf("loaded recent workspaces = %v, want %v", loaded, want)
		}
	}
}

func TestRecentWorkspacesFilePersistsExplicitClear(t *testing.T) {
	path := filepath.Join(t.TempDir(), "recent-workspaces.json")
	if err := SaveRecentWorkspaces(path, nil); err != nil {
		t.Fatalf("save cleared history: %v", err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read cleared history: %v", err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("decode cleared history: %v", err)
	}
	if decoded["paths"] == nil {
		t.Fatalf("cleared history must encode an empty array, got %s", data)
	}
	loaded, err := LoadRecentWorkspaces(path)
	if err != nil || len(loaded) != 0 {
		t.Fatalf("load cleared history = %v, %v", loaded, err)
	}
}

func TestLoadRecentWorkspacesRejectsCorruptAndUnsupportedFiles(t *testing.T) {
	for name, content := range map[string]string{
		"corrupt":       "{",
		"unsupported":   `{"version":2,"paths":[]}`,
		"missing paths": `{"version":1}`,
		"too many":      `{"version":1,"paths":["a","b","c","d","e","f","g","h","i","j","k"]}`,
	} {
		t.Run(name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "recent-workspaces.json")
			if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
				t.Fatal(err)
			}
			if _, err := LoadRecentWorkspaces(path); err == nil {
				t.Fatalf("LoadRecentWorkspaces(%s) unexpectedly succeeded", content)
			}
		})
	}
}

func TestLoadRecentWorkspacesRejectsOversizedFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "recent-workspaces.json")
	if err := os.WriteFile(path, make([]byte, maxRecentWorkspacesBytes+1), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadRecentWorkspaces(path); err == nil {
		t.Fatal("LoadRecentWorkspaces accepted input larger than its configured bound")
	}
}
