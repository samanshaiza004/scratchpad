// Package treesitter contains the isolated Gate E parser experiments and the
// parser-neutral result types used by the eventual language seam.
package treesitter

import (
	"bytes"
	"crypto/sha256"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"runtime"
	"strings"
	"time"

	"scratchpad/editor"
)

type BenchmarkConfig struct {
	Backend string
	Size    int
}

type BenchmarkResult struct {
	Backend            string `json:"backend"`
	Bytes              int    `json:"bytes"`
	EditedBytes        int    `json:"edited_bytes"`
	QueryCompatibility string `json:"query_compatibility"`
	FullParseNS        int64  `json:"full_parse_ns"`
	IncrementalParseNS int64  `json:"incremental_parse_ns"`
	FullHighlights     int    `json:"full_highlights"`
	FullTags           int    `json:"full_tags"`
	HighlightDigest    string `json:"highlight_digest"`
	TagsDigest         string `json:"tags_digest"`
	RootType           string `json:"root_type"`
	RootEnd            int    `json:"root_end"`
	RootHasError       bool   `json:"root_has_error"`
	TreeDigest         string `json:"tree_digest"`
	HeapDelta          uint64 `json:"heap_delta"`
	MallocDelta        uint64 `json:"malloc_delta"`
}

// QueryFiles are embedded so the benchmark always uses the exact committed
// grammar assets rather than files from an ambient checkout.
//
//go:embed queries/go/highlights.scm
var GoHighlightsQuery string

//go:embed queries/go/tags.scm
var GoTagsQuery string

// PureTagsQuery removes only the optional documentation adjacency directive
// that gotreesitter does not implement yet. Definition captures remain the
// upstream query's captures; the bake-off records this runtime limitation.
func PureTagsQuery() string {
	query := GoTagsQuery
	query = strings.ReplaceAll(query, "  (#set-adjacent! @doc @definition.function)\n", "")
	query = strings.ReplaceAll(query, "  (#set-adjacent! @doc @definition.method)\n", "")
	return query
}

func GenerateSource(size int) []byte {
	if size <= 0 {
		return nil
	}
	var out bytes.Buffer
	out.Grow(size)
	out.WriteString("package fixture\n\n")
	for i := 0; out.Len()+96 < size; i++ {
		fmt.Fprintf(&out, "// generated declaration %d\nfunc Function%d(value int) int {\n\treturn value + %d\n}\n\n", i, i, i%17)
	}
	if out.Len() < size {
		out.Write(bytes.Repeat([]byte{'/'}, size-out.Len()))
	}
	return out.Bytes()[:size]
}

func Run(config BenchmarkConfig) (BenchmarkResult, error) {
	source := GenerateSource(config.Size)
	switch config.Backend {
	case "", "pure":
		return runPure(source)
	case "official":
		return runOfficial(source)
	default:
		return BenchmarkResult{}, fmt.Errorf("unknown backend %q", config.Backend)
	}
}

func Measure(fn func() error) (elapsed time.Duration, heapDelta, mallocDelta uint64, err error) {
	var before, after runtime.MemStats
	runtime.GC()
	runtime.ReadMemStats(&before)
	started := time.Now()
	err = fn()
	elapsed = time.Since(started)
	runtime.ReadMemStats(&after)
	heapDelta = after.HeapAlloc - before.HeapAlloc
	mallocDelta = after.Mallocs - before.Mallocs
	return
}

func editFixture(source []byte) ([]byte, editor.SourceEdit) {
	start := len(source) / 2
	for start > 0 && source[start] != '\n' {
		start--
	}
	if start < len(source) {
		start++
	}
	replacement := []byte("// incremental edit\n")
	point := pointAt(source, start)
	next := make([]byte, 0, len(source)+len(replacement))
	next = append(next, source[:start]...)
	next = append(next, replacement...)
	next = append(next, source[start:]...)
	edit := editor.SourceEdit{
		StartByte:   start,
		OldEndByte:  start,
		NewEndByte:  start + len(replacement),
		StartPoint:  point,
		OldEndPoint: point,
		NewEndPoint: advancePoint(point, replacement),
	}
	return next, edit
}

func pointAt(source []byte, offset int) editor.BytePoint {
	point := editor.BytePoint{}
	for _, c := range source[:offset] {
		if c == '\n' {
			point.Row++
			point.Column = 0
		} else {
			point.Column++
		}
	}
	return point
}

func advancePoint(start editor.BytePoint, source []byte) editor.BytePoint {
	point := start
	for _, c := range source {
		if c == '\n' {
			point.Row++
			point.Column = 0
		} else {
			point.Column++
		}
	}
	return point
}

func bytesContainNewline(source []byte) bool {
	return bytes.IndexByte(source, '\n') >= 0
}

func digest(parts ...string) string {
	h := sha256.New()
	for _, part := range parts {
		_, _ = h.Write([]byte(part))
	}
	return fmt.Sprintf("%x", h.Sum(nil))
}

func captureDigest(parts []string) string {
	return digest(parts...)
}

func MarshalResult(result BenchmarkResult) ([]byte, error) {
	if result.Backend == "" {
		return nil, errors.New("benchmark result has no backend")
	}
	return json.Marshal(result)
}
