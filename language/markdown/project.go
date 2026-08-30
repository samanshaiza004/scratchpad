// Package markdown contains the replaceable Markdown projection adapter.
// Goldmark types deliberately do not cross this package boundary.
package markdown

import (
	"bytes"
	"net/url"
	"strings"
	"unicode/utf8"

	"github.com/yuin/goldmark/v2/ast"
	"github.com/yuin/goldmark/v2/extension"
	"github.com/yuin/goldmark/v2/parser"
	"scratchpad/document"
)

// Project lowers only structural headings. It never owns or mutates source.
func Project(source []byte, revision uint64) document.Projections {
	root := parser.New(parser.WithAutoHeadingID(), parser.WithExtensions(
		extension.NewTaskListItemParser(), extension.NewStrikethroughParser(),
	)).Parse(source)
	projection := document.Projections{Revision: revision}
	projection.Markdown = collectPresentation(root, source, revision, &projection)
	for i, heading := range projection.Headings {
		start := heading.EndByte
		if start < len(source) && source[start] == '\n' {
			start++
		}
		end := len(source)
		for j := i + 1; j < len(projection.Headings); j++ {
			if projection.Headings[j].Level <= heading.Level {
				end = projection.Headings[j].StartByte
				break
			}
		}
		if end > start {
			projection.Folds = append(projection.Folds, document.Fold{HeadingStart: heading.StartByte, StartByte: start, EndByte: end})
		}
	}
	return projection
}

func headingRange(heading *ast.Heading, source []byte) (int, int) {
	segments := heading.Source()
	if len(segments) == 0 {
		start := max(0, heading.Pos())
		return lineStart(source, start), lineEnd(source, start)
	}
	start, end := len(source), 0
	for _, segment := range segments {
		if segment.Start < start {
			start = segment.Start
		}
		if segment.Stop > end {
			end = segment.Stop
		}
	}
	start = lineStart(source, start)
	// Include the complete block. This includes a Setext underline and its
	// terminating newline when present, while remaining byte-exact.
	if heading.HeadingKind == ast.HeadingKindSetext {
		if end < len(source) && source[end] == '\n' {
			end++
		}
		end = lineEnd(source, end)
		if end < len(source) && source[end] == '\n' {
			end++
		}
	} else {
		end = lineEnd(source, end)
	}
	return start, end
}

func headingText(heading *ast.Heading, source []byte) string {
	return nodeText(heading, source)
}

func nodeText(root ast.Node, source []byte) string {
	var parts []string
	_ = ast.Walk(root, func(node ast.Node, entering bool) (ast.WalkStatus, error) {
		if !entering {
			return ast.WalkContinue, nil
		}
		text, ok := node.(*ast.Text)
		if !ok {
			return ast.WalkContinue, nil
		}
		parts = append(parts, text.Value.Value(source))
		return ast.WalkContinue, nil
	})
	if len(parts) == 0 {
		var raw []byte
		if block, ok := root.(ast.BlockNode); ok {
			for _, segment := range block.Source() {
				raw = append(raw, segment.Bytes(source)...)
			}
		}
		return displayInvalid(bytes.TrimSpace(raw))
	}
	return displayInvalid([]byte(strings.Join(parts, "")))
}

func taskRange(item *ast.ListItem, source []byte) (line, markerStart, markerEnd int, checked, ok bool) {
	position := item.Pos()
	if position < 0 && item.FirstChild() != nil {
		position = item.FirstChild().Pos()
	}
	if position < 0 {
		return 0, 0, 0, false, false
	}
	line = lineStart(source, position)
	end := lineEnd(source, line)
	for at := line; at+3 < end; at++ {
		if source[at] != '[' || (source[at+1] != ' ' && source[at+1] != 'x' && source[at+1] != 'X') || source[at+2] != ']' {
			continue
		}
		if at > line && source[at-1] != ' ' && source[at-1] != '\t' {
			continue
		}
		return line, at, at + 3, source[at+1] != ' ', true
	}
	return 0, 0, 0, false, false
}

func inlineRange(position int, source []byte, opener byte) (int, int, bool) {
	if position < 0 || position >= len(source) || source[position] != opener {
		return 0, 0, false
	}
	if opener == '<' {
		if end := bytes.IndexByte(source[position+1:], '>'); end >= 0 {
			return position, position + end + 2, true
		}
		return 0, 0, false
	}
	close := bytes.Index(source[position:], []byte("]("))
	if close < 0 {
		return 0, 0, false
	}
	close += position + 2
	if end := bytes.IndexByte(source[close:], ')'); end >= 0 {
		return position, close + end + 1, true
	}
	return 0, 0, false
}

// LinkTargetKind is kept small and policy-free in the parser package. The UI
// can use it to decide whether to dispatch an external open action.
func LinkTargetKind(target string) string {
	parsed, err := url.Parse(target)
	if err != nil || parsed.Scheme == "" {
		return "path"
	}
	if parsed.Scheme == "http" || parsed.Scheme == "https" || parsed.Scheme == "mailto" {
		return parsed.Scheme
	}
	return "unsupported"
}

func displayInvalid(source []byte) string {
	var out strings.Builder
	for at := 0; at < len(source); {
		r, size := utf8.DecodeRune(source[at:])
		if r == utf8.RuneError && size == 1 && source[at] >= utf8.RuneSelf {
			out.WriteString("\\x")
			const hex = "0123456789ABCDEF"
			out.WriteByte(hex[source[at]>>4])
			out.WriteByte(hex[source[at]&15])
			at++
			continue
		}
		out.Write(source[at : at+size])
		at += size
	}
	return out.String()
}

func lineStart(source []byte, at int) int {
	if at > len(source) {
		at = len(source)
	}
	if at < 0 {
		at = 0
	}
	if index := bytes.LastIndexByte(source[:at], '\n'); index >= 0 {
		return index + 1
	}
	return 0
}

func lineEnd(source []byte, at int) int {
	if at < 0 {
		at = 0
	}
	if at > len(source) {
		at = len(source)
	}
	if index := bytes.IndexByte(source[at:], '\n'); index >= 0 {
		return at + index
	}
	return len(source)
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}
