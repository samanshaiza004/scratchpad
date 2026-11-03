package application

import (
	"errors"
	"fmt"
	"sort"
	"strings"
	"unicode/utf8"

	"scratchpad/document"
	"scratchpad/language"
)

// StructuralProjectionKind selects an existing parser projection to expose as
// a bounded, source-connected working view. These values are view queries, not
// new document models or parser-owned structures.
type StructuralProjectionKind string

const (
	StructuralProjectionTasks   StructuralProjectionKind = "tasks"
	StructuralProjectionSymbols StructuralProjectionKind = "symbols"
	StructuralProjectionLinks   StructuralProjectionKind = "links"
)

var ErrInvalidStructuralProjectionKind = errors.New("invalid structural projection kind")

// QueryStructuralView lowers current provider output into the same ephemeral
// Projection used by other source-connected views. The initial UI is scoped to
// one open document; parser ownership and the segment contract remain reusable
// for future multi-document views. Result windows and copied excerpts are
// bounded independently of document or projection size.
func (a *Application) QueryStructuralView(id DocumentID, kind StructuralProjectionKind, first, limit int) (ViewWindow, error) {
	if a == nil {
		return ViewWindow{}, errors.New("nil application")
	}
	if kind != StructuralProjectionTasks && kind != StructuralProjectionSymbols && kind != StructuralProjectionLinks {
		return ViewWindow{}, ErrInvalidStructuralProjectionKind
	}
	if first < 0 || limit <= 0 || limit > MaxProjectionWindow {
		return ViewWindow{}, errors.New("invalid structural view window")
	}
	doc := a.Documents[id]
	if doc == nil || doc.Editor == nil {
		return ViewWindow{}, errors.New("unknown document")
	}
	if _, readOnly := a.FileViews[id]; readOnly {
		return ViewWindow{}, ErrReadOnlyFileView
	}

	window := ViewWindow{DocumentID: id, Mode: ViewDensity(kind), Revision: doc.Revision(), Ready: true, Supported: true, First: first}
	markdown := doc.RootLanguage == string(language.Markdown)
	if (!markdown && kind != StructuralProjectionSymbols) ||
		(kind == StructuralProjectionSymbols && !markdown && !AnalysisSupported(language.ID(doc.RootLanguage))) {
		window.Supported = false
		return window, nil
	}
	if !doc.DerivedCurrent() {
		window.Ready = false
		return window, nil
	}

	cacheMode := ViewDensity(kind)
	cache, ok := a.semanticViews[id]
	if !ok || cache.revision != doc.Revision() || cache.mode != cacheMode || cache.projection == nil {
		segments := structuralProjectionSegments(doc, id, kind)
		projection, err := a.NewProjection("structural-view", string(kind), segments)
		if err != nil {
			return ViewWindow{}, err
		}
		cache = semanticViewCache{revision: doc.Revision(), mode: cacheMode, projection: projection}
		a.semanticViews[id] = cache
	}
	projectionWindow, err := a.QueryProjection(cache.projection, first, limit)
	if err != nil {
		return ViewWindow{}, err
	}
	window.Generation = projectionWindow.Generation
	window.Total = projectionWindow.Total
	window.Segments = make([]ViewSegment, len(projectionWindow.Segments))
	for i, segment := range projectionWindow.Segments {
		readEnd := min(segment.EndByte, segment.StartByte+MaxViewExcerptBytes+utf8.UTFMax)
		textBytes, err := doc.Editor.Buffer.Bytes(segment.StartByte, readEnd)
		if err != nil {
			return ViewWindow{}, fmt.Errorf("read projected source range: %w", err)
		}
		truncated := segment.EndByte-segment.StartByte > MaxViewExcerptBytes
		textBytes = utf8Prefix(textBytes, MaxViewExcerptBytes)
		text := strings.TrimRight(string(textBytes), "\r\n")
		startLine, _ := doc.Editor.Buffer.LineAt(segment.StartByte)
		endLine, _ := doc.Editor.Buffer.LineAt(max(segment.StartByte, segment.EndByte-1))
		window.Segments[i] = ViewSegment{
			ProjectionSegmentView: segment,
			Text:                  text,
			Truncated:             truncated,
			SourceStartLine:       startLine + 1,
			SourceEndLine:         endLine + 1,
		}
	}
	return window, nil
}

func structuralProjectionSegments(doc *document.Document, id DocumentID, kind StructuralProjectionKind) []ProjectionSegment {
	if doc == nil || doc.Editor == nil {
		return nil
	}
	revision := doc.Revision()
	segments := make([]ProjectionSegment, 0)
	add := func(start, end int, label, context string, depth int) {
		if start < 0 || end <= start || end > doc.Editor.Buffer.ByteLen() {
			return
		}
		segments = append(segments, ProjectionSegment{
			DocumentID: id, SourceRevision: revision, StartByte: start, EndByte: end,
			Label: label, Context: context, Depth: max(depth, 0),
		})
	}

	switch kind {
	case StructuralProjectionTasks:
		for _, task := range doc.Projections.Tasks {
			state := "open"
			if task.Checked {
				state = "complete"
			}
			add(task.StartByte, task.EndByte, "task", state, 0)
		}
	case StructuralProjectionSymbols:
		if doc.RootLanguage == string(language.Markdown) {
			for _, heading := range doc.Projections.Headings {
				add(heading.StartByte, heading.EndByte, "heading", heading.Text, heading.Level-1)
			}
		} else {
			for _, symbol := range doc.Projections.Code.Symbols {
				label := symbol.Kind
				if label == "" {
					label = "symbol"
				}
				add(symbol.StartByte, symbol.EndByte, label, symbol.Name, 0)
			}
		}
	case StructuralProjectionLinks:
		for _, link := range doc.Projections.Links {
			add(link.StartByte, link.EndByte, "link", link.Target, 0)
		}
	}

	sort.SliceStable(segments, func(i, j int) bool {
		if segments[i].StartByte != segments[j].StartByte {
			return segments[i].StartByte < segments[j].StartByte
		}
		if segments[i].EndByte != segments[j].EndByte {
			return segments[i].EndByte < segments[j].EndByte
		}
		return segments[i].Label < segments[j].Label
	})
	return segments
}
