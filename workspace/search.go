package workspace

import (
	"bytes"
	"context"
	"io"
	"io/fs"
	"os"
)

const SearchContextMaxBytes = 512

// MaxSearchFileBytes keeps workspace search bounded per file and matches the
// text editor's maximum openable file size.
const MaxSearchFileBytes = maxTextFileBytes

type SearchResult struct {
	Path          string
	Line          int
	Column        int
	StartByte     int
	EndByte       int
	Text          string
	TextTruncated bool
}

// Search walks ordinary workspace files and emits raw-byte substring matches.
// It is intentionally stateless and cancellable; callers decide how results
// are presented or retained. Text is a bounded context line, while byte
// offsets always address the original file contents.
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
					nextLineEnd := bytes.IndexByte(data[lineStart:], '\n')
					lineEnd = len(data)
					if nextLineEnd >= 0 {
						lineEnd = lineStart + nextLineEnd
					}
				}
			}
			resultText, resultTruncated := searchContextLine(data, lineStart, lineEnd, at, at+len(query))
			if !emit(SearchResult{
				Path:          path,
				Line:          line,
				Column:        at - lineStart,
				StartByte:     at,
				EndByte:       at + len(query),
				Text:          resultText,
				TextTruncated: resultTruncated,
			}) {
				return errSearchStopped
			}
			consumed = at + len(query)
			for i := at; i < consumed; i++ {
				if data[i] == '\n' {
					line++
					lineStart = i + 1
					nextLineEnd := bytes.IndexByte(data[lineStart:], '\n')
					lineEnd = len(data)
					if nextLineEnd >= 0 {
						lineEnd = lineStart + nextLineEnd
					}
				}
			}
			offset = consumed
		}
		return nil
	})
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

func searchContextLine(data []byte, lineStart, lineEnd, matchStart, matchEnd int) (string, bool) {
	if lineEnd > lineStart && data[lineEnd-1] == '\r' {
		lineEnd--
	}
	if lineEnd-lineStart <= SearchContextMaxBytes {
		return string(data[lineStart:lineEnd]), false
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
	return string(data[start:end]), true
}

var errSearchStopped = &searchStoppedError{}

type searchStoppedError struct{}

func (*searchStoppedError) Error() string { return "search stopped" }
