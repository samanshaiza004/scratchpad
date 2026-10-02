package application

import (
	"bytes"
	"context"
	"unicode"
	"unicode/utf8"

	"scratchpad/workspace"
)

type CurrentMatch struct {
	Start  int
	End    int
	Line   int
	Column int
}

// FindOptions controls literal document Find matching. MatchCase preserves
// the historic case-sensitive behavior when enabled; WholeWord uses Unicode
// letters/digits plus underscore as word characters.
type FindOptions struct {
	MatchCase bool
	WholeWord bool
}

func (a *Application) FindCurrent(id DocumentID, query []byte) []CurrentMatch {
	return a.FindCurrentWithOptions(id, query, FindOptions{MatchCase: true})
}

// FindCurrentLimited searches the authoritative open-document buffer and
// retains at most limit source-byte matches for interactive Find.
func (a *Application) FindCurrentLimited(id DocumentID, query []byte, limit int) []CurrentMatch {
	return a.FindCurrentLimitedWithOptions(id, query, limit, FindOptions{MatchCase: true})
}

// FindCurrentWithOptions searches the authoritative open-document buffer.
func (a *Application) FindCurrentWithOptions(id DocumentID, query []byte, options FindOptions) []CurrentMatch {
	return a.findCurrent(id, query, 0, options)
}

// FindCurrentLimitedWithOptions retains at most limit source-byte matches.
func (a *Application) FindCurrentLimitedWithOptions(id DocumentID, query []byte, limit int, options FindOptions) []CurrentMatch {
	if limit <= 0 {
		return nil
	}
	return a.findCurrent(id, query, limit, options)
}

func (a *Application) findCurrent(id DocumentID, query []byte, limit int, options FindOptions) []CurrentMatch {
	doc := a.Documents[id]
	if doc == nil || len(query) == 0 {
		return nil
	}
	data := doc.Editor.Buffer.Text()
	var matches []CurrentMatch
	line, lineStart := 0, 0
	consumed := 0
	for offset := 0; offset <= len(data)-len(query); {
		at, found := findNextLiteral(data, query, offset, options)
		if !found {
			break
		}
		// Advance the line state over bytes since the previous match. Each
		// byte is visited at most once, so locating matches does not repeatedly
		// rescan the document prefix.
		for i := consumed; i < at; i++ {
			if data[i] == '\n' {
				line++
				lineStart = i + 1
			}
		}
		matches = append(matches, CurrentMatch{
			Start: at, End: at + len(query),
			Line: line, Column: at - lineStart,
		})
		if limit > 0 && len(matches) >= limit {
			break
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
	return matches
}

func findNextLiteral(data, query []byte, offset int, options FindOptions) (int, bool) {
	if len(query) == 0 || offset < 0 || offset > len(data)-len(query) {
		return 0, false
	}
	if !options.MatchCase && isASCII(query) {
		return findNextASCIIFold(data, query, offset, options.WholeWord)
	}
	for offset <= len(data)-len(query) {
		start := offset
		if options.MatchCase {
			relative := bytes.Index(data[offset:], query)
			if relative < 0 {
				return 0, false
			}
			start += relative
		} else {
			matched := false
			for start <= len(data)-len(query) {
				if bytes.EqualFold(data[start:start+len(query)], query) {
					matched = true
					break
				}
				_, width := utf8.DecodeRune(data[start:])
				if width < 1 {
					width = 1
				}
				start += width
			}
			if !matched {
				return 0, false
			}
		}
		end := start + len(query)
		if !options.WholeWord || isWholeWordMatch(data, start, end) {
			return start, true
		}
		_, width := utf8.DecodeRune(data[start:])
		if width < 1 {
			width = 1
		}
		offset = start + width
	}
	return 0, false
}

func isASCII(value []byte) bool {
	for _, current := range value {
		if current >= utf8.RuneSelf {
			return false
		}
	}
	return true
}

func findNextASCIIFold(data, query []byte, offset int, wholeWord bool) (int, bool) {
	length := len(query)
	var shifts [256]int
	for index := range shifts {
		shifts[index] = length
	}
	for index := 0; index < length-1; index++ {
		shifts[asciiFold(query[index])] = length - 1 - index
	}
	for offset <= len(data)-length {
		index := length - 1
		for index >= 0 && asciiFold(data[offset+index]) == asciiFold(query[index]) {
			index--
		}
		if index < 0 {
			end := offset + length
			if !wholeWord || isWholeWordMatch(data, offset, end) {
				return offset, true
			}
			// A whole-word rejection may have an overlapping match beginning
			// inside this candidate, so continue conservatively by one byte.
			offset++
			continue
		}
		shift := shifts[asciiFold(data[offset+length-1])]
		if shift < 1 {
			shift = 1
		}
		offset += shift
	}
	return 0, false
}

func asciiFold(value byte) byte {
	if value >= 'A' && value <= 'Z' {
		return value + ('a' - 'A')
	}
	return value
}

func isWholeWordMatch(data []byte, start, end int) bool {
	if start > 0 {
		previous, _ := utf8.DecodeLastRune(data[:start])
		if isFindWordRune(previous) {
			return false
		}
	}
	if end < len(data) {
		next, _ := utf8.DecodeRune(data[end:])
		if isFindWordRune(next) {
			return false
		}
	}
	return true
}

func isFindWordRune(value rune) bool {
	return value == '_' || unicode.IsLetter(value) || unicode.IsDigit(value)
}

func (a *Application) SearchWorkspace(ctx context.Context, query []byte) <-chan workspace.SearchResult {
	results := make(chan workspace.SearchResult)
	if a == nil || !a.HasWorkspace {
		close(results)
		return results
	}
	// Capture the workspace value before starting the worker. Opening a
	// different workspace may replace Application.Workspace while this
	// cancellable search is still draining.
	workspaceSnapshot := a.Workspace
	go func() {
		defer close(results)
		_ = workspaceSnapshot.Search(ctx, query, func(result workspace.SearchResult) bool {
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
