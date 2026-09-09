package workspace

import (
	"bytes"
	"context"
	"io/fs"
	"os"
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
	return w.Walker().Walk(func(path string, entry fs.DirEntry) error {
		if err := ctx.Err(); err != nil {
			return err
		}
		if entry.IsDir() || entry.Type()&fs.ModeSymlink != 0 {
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return nil
		}
		line, lineStart := 0, 0
		consumed := 0
		for offset := 0; offset <= len(data)-len(query); {
			at := bytes.Index(data[offset:], query)
			if at < 0 {
				break
			}
			at += offset
			for i := consumed; i < at; i++ {
				if data[i] == '\n' {
					line++
					lineStart = i + 1
				}
			}
			if !emit(SearchResult{Path: path, Line: line, Column: at - lineStart, Text: lineText(data, lineStart)}) {
				return errSearchStopped
			}
			consumed = at + len(query)
			for i := at; i < consumed; i++ {
				if data[i] == '\n' {
					line++
					lineStart = i + 1
				}
			}
			offset = consumed
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
