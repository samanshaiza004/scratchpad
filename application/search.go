package application

import (
	"bytes"
	"context"

	"scratchpad/workspace"
)

type CurrentMatch struct {
	Start  int
	End    int
	Line   int
	Column int
}

func (a *Application) FindCurrent(id DocumentID, query []byte) []CurrentMatch {
	doc := a.Documents[id]
	if doc == nil || len(query) == 0 {
		return nil
	}
	data := doc.Editor.Buffer.Text()
	var matches []CurrentMatch
	for offset := 0; offset <= len(data)-len(query); {
		at := bytes.Index(data[offset:], query)
		if at < 0 {
			break
		}
		at += offset
		lineStart := bytes.LastIndexByte(data[:at], '\n') + 1
		matches = append(matches, CurrentMatch{
			Start: at, End: at + len(query),
			Line: bytes.Count(data[:at], []byte{'\n'}), Column: at - lineStart,
		})
		offset = at + len(query)
	}
	return matches
}

func (a *Application) SearchWorkspace(ctx context.Context, query []byte) <-chan workspace.SearchResult {
	results := make(chan workspace.SearchResult)
	if a == nil || !a.HasWorkspace {
		close(results)
		return results
	}
	go func() {
		defer close(results)
		_ = a.Workspace.Search(ctx, query, func(result workspace.SearchResult) bool {
			select {
			case results <- result:
				return true
			case <-ctx.Done():
				return false
			}
		})
	}()
	return results
}
