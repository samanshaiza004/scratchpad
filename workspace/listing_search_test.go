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

func TestSearchPreservesByteOffsetsForRawMatchesAcrossLines(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "raw.bin")
	data := []byte{'x', '\n', 0xff, 'a', '\n', 0xff, 'b'}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
	ws, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	var results []SearchResult
	if err := ws.Search(context.Background(), []byte{0xff}, func(result SearchResult) bool {
		results = append(results, result)
		return true
	}); err != nil {
		t.Fatal(err)
	}
	if len(results) != 2 || results[0].Line != 1 || results[0].Column != 0 || results[1].Line != 2 || results[1].Column != 0 {
		t.Fatalf("results = %+v", results)
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

func TestWorkspaceTraversalHonorsRootAndNestedGitignoreRules(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, ".gitignore"), []byte("node_modules/\n*.generated\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(dir, "node_modules", "pkg"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(dir, "src", "generated", "nested"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "src", ".gitignore"), []byte("generated/\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	files := map[string]string{
		"visible.txt":                     "needle",
		"node_modules/pkg/index.js":       "needle",
		"generated.generated":             "needle",
		"src/keep.txt":                    "needle",
		"src/generated/nested/hidden.txt": "needle",
		".scratchpad/recovery.txt":        "needle",
		".git/internal":                   "needle",
	}
	for relative, contents := range files {
		path := filepath.Join(dir, filepath.FromSlash(relative))
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(contents), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	ws, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}

	var listed []string
	if err := ws.Files(context.Background(), func(path string) bool {
		relative, err := filepath.Rel(dir, path)
		if err != nil {
			t.Fatal(err)
		}
		listed = append(listed, filepath.ToSlash(relative))
		return true
	}); err != nil {
		t.Fatal(err)
	}
	wantListed := []string{".gitignore", "src/.gitignore", "src/keep.txt", "visible.txt"}
	if !equalStrings(listed, wantListed) {
		t.Fatalf("Files = %v, want %v", listed, wantListed)
	}

	rootEntries, err := ws.List("")
	if err != nil {
		t.Fatal(err)
	}
	if len(rootEntries) != 3 || rootEntries[0].Name != "src" || rootEntries[1].Name != ".gitignore" || rootEntries[2].Name != "visible.txt" {
		t.Fatalf("root entries = %+v, want visible ignored-aware entries", rootEntries)
	}
	srcEntries, err := ws.List("src")
	if err != nil {
		t.Fatal(err)
	}
	if len(srcEntries) != 2 || srcEntries[0].Name != ".gitignore" || srcEntries[1].Name != "keep.txt" {
		t.Fatalf("src entries = %+v, want nested ignore applied", srcEntries)
	}

	var searched []string
	if err := ws.Search(context.Background(), []byte("needle"), func(result SearchResult) bool {
		relative, err := filepath.Rel(dir, result.Path)
		if err != nil {
			t.Fatal(err)
		}
		searched = append(searched, filepath.ToSlash(relative))
		return true
	}); err != nil {
		t.Fatal(err)
	}
	wantSearched := []string{"src/keep.txt", "visible.txt"}
	if !equalStrings(searched, wantSearched) {
		t.Fatalf("Search = %v, want %v", searched, wantSearched)
	}
}

func TestListRefreshesChangedRootAndNestedGitignoreRules(t *testing.T) {
	dir := t.TempDir()
	rootTarget := filepath.Join(dir, "target.txt")
	rootOther := filepath.Join(dir, "other.txt")
	nestedDir := filepath.Join(dir, "nested")
	nestedTarget := filepath.Join(nestedDir, "target.txt")
	for _, path := range []string{rootTarget, rootOther, nestedTarget} {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	ws, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	contains := func(entries []Entry, name string) bool {
		for _, entry := range entries {
			if entry.Name == name {
				return true
			}
		}
		return false
	}
	listRoot := func() []Entry {
		entries, err := ws.List("")
		if err != nil {
			t.Fatal(err)
		}
		return entries
	}
	listNested := func() []Entry {
		entries, err := ws.List("nested")
		if err != nil {
			t.Fatal(err)
		}
		return entries
	}

	if !contains(listRoot(), "target.txt") {
		t.Fatal("initial root listing omitted target.txt")
	}
	if err := os.WriteFile(filepath.Join(dir, ".gitignore"), []byte("target.txt\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if contains(listRoot(), "target.txt") || !contains(listRoot(), "other.txt") {
		t.Fatal("root listing did not refresh after adding .gitignore")
	}
	if err := os.WriteFile(filepath.Join(dir, ".gitignore"), []byte("other.txt\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if !contains(listRoot(), "target.txt") || contains(listRoot(), "other.txt") {
		t.Fatal("root listing did not refresh after editing .gitignore")
	}
	if err := os.Remove(filepath.Join(dir, ".gitignore")); err != nil {
		t.Fatal(err)
	}
	if !contains(listRoot(), "target.txt") || !contains(listRoot(), "other.txt") {
		t.Fatal("root listing did not refresh after removing .gitignore")
	}

	if !contains(listNested(), "target.txt") {
		t.Fatal("initial nested listing omitted target.txt")
	}
	if err := os.WriteFile(filepath.Join(nestedDir, ".gitignore"), []byte("target.txt\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if contains(listNested(), "target.txt") {
		t.Fatal("nested listing did not refresh after adding .gitignore")
	}
	if err := os.Remove(filepath.Join(nestedDir, ".gitignore")); err != nil {
		t.Fatal(err)
	}
	if !contains(listNested(), "target.txt") {
		t.Fatal("nested listing did not refresh after removing .gitignore")
	}
}

func equalStrings(got, want []string) bool {
	if len(got) != len(want) {
		return false
	}
	for index := range want {
		if got[index] != want[index] {
			return false
		}
	}
	return true
}
