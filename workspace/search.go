package workspace

import (
	"bytes"
	"context"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"unicode/utf8"
)

const SearchContextMaxBytes = 512

// MaxSearchFileBytes keeps workspace search bounded per file and matches the
// text editor's maximum openable file size.
const MaxSearchFileBytes = maxTextFileBytes

type SearchResult struct {
	Path             string
	Line             int
	Column           int
	StartByte        int
	EndByte          int
	ContextStartByte int
	ContextEndByte   int
	SourceDocumentID string
	SourceInstanceID uint64
	SourceRevision   uint64
	Editable         bool
	Text             string
	TextTruncated    bool
}

// SearchSource overlays an immutable open-document snapshot on its disk path.
// It lets workspace search reflect unsaved edits without copying source bytes
// on the application thread or retaining a second document authority.
type SearchSource struct {
	Path       string
	Data       []byte
	Load       func() []byte
	DocumentID string
	InstanceID uint64
	Revision   uint64
}

// Search walks ordinary workspace files and emits raw-byte substring matches.
// It is intentionally stateless and cancellable; callers decide how results
// are presented or retained. Text is a bounded context line, while byte
// offsets always address the original file contents.
func (w Workspace) Search(ctx context.Context, query []byte, emit func(SearchResult) bool) error {
	return w.SearchWithSources(ctx, query, nil, emit)
}

// SearchWithSources searches ordinary workspace files while preferring the
// captured bytes of open documents. Context ranges are exact source-byte
// intervals, independent of the bounded preview string.
func (w Workspace) SearchWithSources(ctx context.Context, query []byte, sources []SearchSource, emit func(SearchResult) bool) error {
	if len(query) == 0 {
		return nil
	}
	byPath := make(map[string]SearchSource, len(sources))
	for _, source := range sources {
		if source.Path != "" {
			byPath[searchPathKey(source.Path)] = source
		}
	}
	visitedSources := make(map[string]bool, len(byPath))
	err := w.Walker().Walk(func(path string, entry fs.DirEntry) error {
		if err := ctx.Err(); err != nil {
			return err
		}
		if entry.IsDir() || entry.Type()&fs.ModeSymlink != 0 {
			return nil
		}
		key := searchPathKey(path)
		if source, found := byPath[key]; found {
			visitedSources[key] = true
			return searchData(ctx, source, query, emit)
		}
		data, searchable, err := readSearchableFile(ctx, path)
		if err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			return nil
		}
		if !searchable {
			return nil
		}
		return searchData(ctx, SearchSource{Path: path, Data: data}, query, emit)
	})
	if err != nil {
		return err
	}
	for _, source := range sources {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if visitedSources[searchPathKey(source.Path)] {
			continue
		}
		if err := searchData(ctx, source, query, emit); err != nil {
			return err
		}
	}
	return nil
}

func searchPathKey(path string) string {
	clean := filepath.Clean(path)
	if runtime.GOOS == "windows" {
		clean = strings.ToLower(clean)
	}
	return clean
}

func searchData(ctx context.Context, source SearchSource, query []byte, emit func(SearchResult) bool) error {
	data := source.Data
	if source.Load != nil {
		data = source.Load()
	}
	if int64(len(data)) > MaxSearchFileBytes || binaryTextProbeReason(data[:min(len(data), textProbeBytes)]) != "" {
		return nil
	}
	line, lineStart := 0, 0
	lineEnd := bytes.IndexByte(data, '\n')
	if lineEnd < 0 {
		lineEnd = len(data)
	}
	consumed := 0
	for offset := 0; offset <= len(data)-len(query); {
		if err := ctx.Err(); err != nil {
			return err
		}
		at := bytes.Index(data[offset:], query)
		if at < 0 {
			break
		}
		at += offset
		for i := consumed; i < at; i++ {
			if data[i] == '\n' {
				line++
				lineStart = i + 1
				lineEnd = len(data)
				if next := bytes.IndexByte(data[lineStart:], '\n'); next >= 0 {
					lineEnd = lineStart + next
				}
			}
		}
		text, truncated, contextStart, contextEnd := searchContextLine(data, lineStart, lineEnd, at, at+len(query))
		if !emit(SearchResult{
			Path: source.Path, Line: line, Column: at - lineStart,
			StartByte: at, EndByte: at + len(query),
			ContextStartByte: contextStart, ContextEndByte: contextEnd,
			SourceDocumentID: source.DocumentID, SourceInstanceID: source.InstanceID,
			SourceRevision: source.Revision,
			Editable:       contextStart <= at && at+len(query) <= contextEnd && validEditableContext(data[contextStart:contextEnd]),
			Text:           text,
			TextTruncated:  truncated,
		}) {
			return errSearchStopped
		}
		consumed = at + len(query)
		for i := at; i < consumed; i++ {
			if data[i] == '\n' {
				line++
				lineStart = i + 1
				lineEnd = len(data)
				if next := bytes.IndexByte(data[lineStart:], '\n'); next >= 0 {
					lineEnd = lineStart + next
				}
			}
		}
		offset = consumed
	}
	return nil
}

func validEditableContext(data []byte) bool {
	if !utf8.Valid(data) {
		return false
	}
	for _, value := range data {
		if value == '\n' || value == '\r' {
			return false
		}
	}
	return true
}

func readSearchableFile(ctx context.Context, path string) ([]byte, bool, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, false, err
	}
	defer file.Close()

	info, err := file.Stat()
	if err != nil {
		return nil, false, err
	}
	if !info.Mode().IsRegular() || info.Size() > MaxSearchFileBytes {
		return nil, false, nil
	}

	probeLength := min(info.Size(), int64(textProbeBytes))
	probe := make([]byte, int(probeLength))
	if probeLength > 0 {
		if _, err := io.ReadFull(file, probe); err != nil {
			return nil, false, err
		}
	}
	if binaryTextProbeReason(probe) != "" {
		return nil, false, nil
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return nil, false, err
	}

	data := make([]byte, 0, int(min(info.Size(), 64<<10)))
	chunk := make([]byte, 64<<10)
	for {
		if err := ctx.Err(); err != nil {
			return nil, false, err
		}
		count, readErr := file.Read(chunk)
		if count > 0 {
			if int64(len(data))+int64(count) > MaxSearchFileBytes {
				return nil, false, nil
			}
			data = append(data, chunk[:count]...)
		}
		if readErr == io.EOF {
			break
		}
		if readErr != nil {
			return nil, false, readErr
		}
	}
	if binaryTextProbeReason(data[:min(len(data), textProbeBytes)]) != "" {
		return nil, false, nil
	}
	return data, true, nil
}

func searchContextLine(data []byte, lineStart, lineEnd, matchStart, matchEnd int) (string, bool, int, int) {
	if lineEnd > lineStart && data[lineEnd-1] == '\r' {
		lineEnd--
	}
	if lineEnd-lineStart <= SearchContextMaxBytes {
		return string(data[lineStart:lineEnd]), false, lineStart, lineEnd
	}

	visibleMatchEnd := min(matchEnd, lineEnd)
	matchLength := visibleMatchEnd - matchStart
	if matchLength > SearchContextMaxBytes {
		matchLength = SearchContextMaxBytes
	}
	remaining := SearchContextMaxBytes - matchLength
	start := matchStart - remaining/2
	if start < lineStart {
		start = lineStart
	}
	end := start + SearchContextMaxBytes
	if end > lineEnd {
		end = lineEnd
		start = end - SearchContextMaxBytes
		if start < lineStart {
			start = lineStart
		}
	}
	return string(data[start:end]), true, start, end
}

var errSearchStopped = &searchStoppedError{}

type searchStoppedError struct{}

func (*searchStoppedError) Error() string { return "search stopped" }
