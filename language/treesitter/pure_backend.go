package treesitter

import (
	"fmt"
	"time"

	gotreesitter "github.com/odvcencio/gotreesitter"
	"github.com/odvcencio/gotreesitter/grammars"
)

func runPure(source []byte) (BenchmarkResult, error) {
	lang := grammars.GoLanguage()
	highlightQuery, err := gotreesitter.NewQuery(GoHighlightsQuery, lang)
	if err != nil {
		return BenchmarkResult{}, err
	}
	tagsQuery, err := gotreesitter.NewQuery(PureTagsQuery(), lang)
	if err != nil {
		return BenchmarkResult{}, err
	}
	parser := gotreesitter.NewParser(lang)

	var fullTree *gotreesitter.Tree
	fullElapsed, heapDelta, mallocDelta, err := Measure(func() error {
		var parseErr error
		fullTree, parseErr = parser.Parse(source)
		return parseErr
	})
	if err != nil {
		return BenchmarkResult{}, err
	}
	if fullTree == nil || fullTree.RootNode() == nil {
		return BenchmarkResult{}, errNoTree
	}
	defer fullTree.Release()
	fullHighlights, highlightDigest := pureCaptureSummary(highlightQuery, fullTree)
	fullTags, tagsDigest := pureCaptureSummary(tagsQuery, fullTree)
	next, edit := editFixture(source)
	fullTree.Edit(gotreesitter.InputEdit{
		StartByte:   uint32(edit.StartByte),
		OldEndByte:  uint32(edit.OldEndByte),
		NewEndByte:  uint32(edit.NewEndByte),
		StartPoint:  gotreesitter.Point{Row: uint32(edit.StartPoint.Row), Column: uint32(edit.StartPoint.Column)},
		OldEndPoint: gotreesitter.Point{Row: uint32(edit.OldEndPoint.Row), Column: uint32(edit.OldEndPoint.Column)},
		NewEndPoint: gotreesitter.Point{Row: uint32(edit.NewEndPoint.Row), Column: uint32(edit.NewEndPoint.Column)},
	})
	var nextTree *gotreesitter.Tree
	incrementalElapsed := time.Duration(0)
	incrementalElapsed, _, _, err = Measure(func() error {
		var parseErr error
		nextTree, parseErr = parser.ParseIncremental(next, fullTree)
		return parseErr
	})
	if err != nil {
		return BenchmarkResult{}, err
	}
	if nextTree != nil {
		defer nextTree.Release()
	}
	root := nextTree.RootNode()
	return BenchmarkResult{
		Backend:            "pure",
		Bytes:              len(source),
		EditedBytes:        len(next),
		QueryCompatibility: "Go upstream queries; #set-adjacent! removed for gotreesitter compatibility",
		FullParseNS:        fullElapsed.Nanoseconds(),
		IncrementalParseNS: incrementalElapsed.Nanoseconds(),
		FullHighlights:     fullHighlights,
		FullTags:           fullTags,
		HighlightDigest:    highlightDigest,
		TagsDigest:         tagsDigest,
		RootType:           root.Type(lang),
		RootEnd:            int(root.EndByte()),
		RootHasError:       root.HasError(),
		TreeDigest:         digest(root.Type(lang), fmt.Sprintf("%d:%t", root.EndByte(), root.HasError())),
		HeapDelta:          heapDelta,
		MallocDelta:        mallocDelta,
	}, nil
}

func pureCaptureSummary(query *gotreesitter.Query, tree *gotreesitter.Tree) (int, string) {
	parts := make([]string, 0)
	for _, match := range query.Execute(tree) {
		for _, capture := range match.Captures {
			parts = append(parts, fmt.Sprintf("%s:%d:%d", capture.Name, capture.Node.StartByte(), capture.Node.EndByte()))
		}
	}
	return len(parts), captureDigest(parts)
}
