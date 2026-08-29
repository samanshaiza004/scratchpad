package workspace

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestListShowsFilesAndFoldersButSkipsInternalMetadata(t *testing.T) {
	dir := t.TempDir()
	for _, name := range []string{".hidden", "note.md", ".git", ".scratchpad"} {
		path := filepath.Join(dir, name)
		if name == ".git" || name == ".scratchpad" {
			if err := os.Mkdir(path, 0o755); err != nil {
				t.Fatal(err)
			}
		} else if err := os.WriteFile(path, nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	ws, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	entries, err := ws.List("")
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 2 || entries[0].Name != ".hidden" || entries[1].Name != "note.md" {
		t.Fatalf("entries = %+v", entries)
	}
}

func TestSearchStreamsRawByteMatchesAndHonorsCancellation(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "note.txt")
	if err := os.WriteFile(path, []byte("one needle\ntwo\nneedle three\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	ws, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	var results []SearchResult
	if err := ws.Search(context.Background(), []byte("needle"), func(result SearchResult) bool {
		results = append(results, result)
		return true
	}); err != nil {
		t.Fatal(err)
	}
	if len(results) != 2 || results[0].Line != 0 || results[1].Line != 2 || results[1].Column != 0 {
		t.Fatalf("results = %+v", results)
	}
	if err := ws.Search(context.Background(), []byte("needle"), func(SearchResult) bool { return false }); !errors.Is(err, errSearchStopped) {
		t.Fatalf("stop error = %v", err)
	}
	cancelled, cancel := context.WithCancel(context.Background())
	cancel()
	if err := ws.Search(cancelled, []byte("needle"), func(SearchResult) bool { return true }); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancel error = %v", err)
	}
}

func TestFilesWalksVisibleFilesRecursively(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "nested"), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{
		filepath.Join(dir, ".hidden.txt"),
		filepath.Join(dir, "root.txt"),
		filepath.Join(dir, "nested", "child.txt"),
	} {
		if err := os.WriteFile(path, nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Mkdir(filepath.Join(dir, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, ".git", "ignored"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	ws, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	var files []string
	if err := ws.Files(context.Background(), func(path string) bool {
		files = append(files, path)
		return true
	}); err != nil {
		t.Fatal(err)
	}
	want := []string{filepath.Join(dir, ".hidden.txt"), filepath.Join(dir, "nested", "child.txt"), filepath.Join(dir, "root.txt")}
	if len(files) != len(want) {
		t.Fatalf("files = %v, want %v", files, want)
	}
	for i := range want {
		if files[i] != want[i] {
			t.Fatalf("files = %v, want %v", files, want)
		}
	}
}
