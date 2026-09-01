//go:build treesitter_cgo

package treesitter

import (
	"errors"
	"fmt"
	"time"

	ts "github.com/tree-sitter/go-tree-sitter"
	treeSitterGo "github.com/tree-sitter/tree-sitter-go/bindings/go"
)

var errNoTree = errors.New("parser returned no tree")

func runOfficial(source []byte) (BenchmarkResult, error) {
	lang := ts.NewLanguage(treeSitterGo.Language())
	parser := ts.NewParser()
	defer parser.Close()
	if err := parser.SetLanguage(lang); err != nil {
		return BenchmarkResult{}, err
	}
	highlightQuery, err := ts.NewQuery(lang, GoHighlightsQuery)
	if err != nil {
		return BenchmarkResult{}, err
	}
	defer highlightQuery.Close()
	tagsQuery, err := ts.NewQuery(lang, GoTagsQuery)
	if err != nil {
		return BenchmarkResult{}, err
	}
	defer tagsQuery.Close()

	var tree *ts.Tree
	fullElapsed, heapDelta, mallocDelta, measureErr := Measure(func() error {
		tree = parser.Parse(source, nil)
		if tree == nil {
			return errNoTree
		}
		return nil
	})
	if measureErr != nil {
		return BenchmarkResult{}, measureErr
	}
	defer tree.Close()
	if tree.RootNode() == nil {
		return BenchmarkResult{}, errNoTree
	}
	fullHighlights, highlightDigest := captureSummary(highlightQuery, tree.RootNode(), source)
	fullTags, tagsDigest := captureSummary(tagsQuery, tree.RootNode(), source)
	next, edit := editFixture(source)
	tree.Edit(&ts.InputEdit{
		StartByte:      uint(edit.StartByte),
		OldEndByte:     uint(edit.OldEndByte),
		NewEndByte:     uint(edit.NewEndByte),
		StartPosition:  ts.Point{Row: uint(edit.StartPoint.Row), Column: uint(edit.StartPoint.Column)},
		OldEndPosition: ts.Point{Row: uint(edit.OldEndPoint.Row), Column: uint(edit.OldEndPoint.Column)},
		NewEndPosition: ts.Point{Row: uint(edit.NewEndPoint.Row), Column: uint(edit.NewEndPoint.Column)},
	})
	var nextTree *ts.Tree
	incrementalElapsed := time.Duration(0)
	incrementalElapsed, _, _, measureErr = Measure(func() error {
		nextTree = parser.Parse(next, tree)
		if nextTree == nil {
			return errNoTree
		}
		return nil
	})
	if measureErr != nil {
		return BenchmarkResult{}, measureErr
	}
	defer nextTree.Close()
	root := nextTree.RootNode()
	return BenchmarkResult{
		Backend:            "official-cgo",
		Bytes:              len(source),
		EditedBytes:        len(next),
		QueryCompatibility: "Go upstream queries",
		FullParseNS:        fullElapsed.Nanoseconds(),
		IncrementalParseNS: incrementalElapsed.Nanoseconds(),
		FullHighlights:     fullHighlights,
		FullTags:           fullTags,
		HighlightDigest:    highlightDigest,
		TagsDigest:         tagsDigest,
		RootType:           root.Kind(),
		RootEnd:            int(root.EndByte()),
		RootHasError:       root.HasError(),
		TreeDigest:         digest(root.Kind(), fmt.Sprintf("%d:%t", root.EndByte(), root.HasError())),
		HeapDelta:          heapDelta,
		MallocDelta:        mallocDelta,
	}, nil
}

func captureSummary(query *ts.Query, root *ts.Node, source []byte) (int, string) {
	cursor := ts.NewQueryCursor()
	defer cursor.Close()
	captures := cursor.Captures(query, root, source)
	count := 0
	parts := make([]string, 0)
	for {
		match, index := captures.Next()
		if match == nil {
			return count, captureDigest(parts)
		}
		count++
		capture := match.Captures[index]
		parts = append(parts, fmt.Sprintf("%s:%d:%d", query.CaptureNames()[capture.Index], capture.Node.StartByte(), capture.Node.EndByte()))
	}
}
