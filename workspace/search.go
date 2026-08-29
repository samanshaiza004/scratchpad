package workspace

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
)

type SearchResult struct {
	Path   string
	Line   int
	Column int
	Text   string
}

// Search walks ordinary workspace files and emits raw-byte substring matches.
// It is intentionally stateless and cancellable; callers decide how results
// are presented or retained.
func (w Workspace) Search(ctx context.Context, query []byte, emit func(SearchResult) bool) error {
	if len(query) == 0 {
		return nil
	}
	return filepath.WalkDir(w.Root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		if entry.IsDir() && (entry.Name() == ".git" || entry.Name() == ".scratchpad") {
			return filepath.SkipDir
		}
		if entry.IsDir() || entry.Type()&os.ModeSymlink != 0 {
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return nil
		}
		for offset := 0; offset <= len(data)-len(query); {
			at := bytes.Index(data[offset:], query)
			if at < 0 {
				break
			}
			at += offset
			line := bytes.Count(data[:at], []byte{'\n'})
			lineStart := bytes.LastIndexByte(data[:at], '\n') + 1
			if !emit(SearchResult{Path: path, Line: line, Column: at - lineStart, Text: lineText(data, lineStart)}) {
				return errSearchStopped
			}
			offset = at + len(query)
		}
		return nil
	})
}

var errSearchStopped = &searchStoppedError{}

type searchStoppedError struct{}

func (*searchStoppedError) Error() string { return "search stopped" }

func lineText(data []byte, start int) string {
	end := bytes.IndexByte(data[start:], '\n')
	if end < 0 {
		return string(data[start:])
	}
	return string(data[start : start+end])
}
