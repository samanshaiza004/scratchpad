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

// ViewDensity selects how much derived source structure is presented without
// changing the authoritative document or its editor state.
type ViewDensity string

const (
	ViewDensityFull    ViewDensity = "full"
	ViewDensitySkim    ViewDensity = "skim"
	ViewDensityOutline ViewDensity = "outline"
)

var ErrInvalidViewDensity = errors.New("invalid document view density")

// MaxViewExcerptBytes bounds the source text returned for one projected row.
const MaxViewExcerptBytes = 256

// ViewSegment is one bounded presentation occurrence with copied source text.
// Text is display-only; edits continue to target the authoritative document.
type ViewSegment struct {
	ProjectionSegmentView
	Text            string
	Truncated       bool
	SourceStartLine int
	SourceEndLine   int
	OmittedBefore   bool
	OmittedAfter    bool
}

// ViewWindow is a bounded snapshot for one reduced document view. A supported
// window may be not-ready while current language analysis is being refreshed.
// Unsupported source types report Supported=false so the frontend can retain
// the ordinary Full editor instead of inventing a parser requirement.
type ViewWindow struct {
	DocumentID DocumentID
	Mode       ViewDensity
	Revision   uint64
	Ready      bool
	Supported  bool
	Generation uint64
	Total      int
	First      int
	Segments   []ViewSegment
}

type semanticViewCache struct {
	revision   uint64
	mode       ViewDensity
	projection *Projection
}

// SetViewDensity changes only the presentation mode for an open text document.
// Source bytes, revision, selection, and dirty state remain untouched.
func (a *Application) SetViewDensity(id DocumentID, density ViewDensity) error {
	if a == nil {
		return errors.New("nil application")
	}
	if density != ViewDensityFull && density != ViewDensitySkim && density != ViewDensityOutline {
		return ErrInvalidViewDensity
	}
	doc := a.Documents[id]
	if doc == nil || doc.Editor == nil {
		return errors.New("unknown document")
	}
	if _, readOnly := a.FileViews[id]; readOnly {
		return ErrReadOnlyFileView
	}
	view := a.Views[id]
	if view.Density == density || (view.Density == "" && density == ViewDensityFull) {
		return nil
	}
	view.Density = density
	a.Views[id] = view
	delete(a.semanticViews, id)
	a.touchPresentation()
	return nil
}

// ViewDensity returns the selected mode. Documents opened before a saved mode
// exists default to Full, preserving the ordinary editable source view.
func (a *Application) ViewDensity(id DocumentID) ViewDensity {
	if a == nil {
		return ViewDensityFull
	}
	if view, ok := a.Views[id]; ok && (view.Density == ViewDensitySkim || view.Density == ViewDensityOutline) {
		return view.Density
	}
	return ViewDensityFull
}

// QueryView returns at most MaxProjectionWindow source-derived excerpts. The
// projection is built once per document revision and density; subsequent
// windows do work proportional to the requested occurrences. Full mode uses
// the ordinary editor and returns no projected rows.
func (a *Application) QueryView(id DocumentID, first, limit int) (ViewWindow, error) {
	if a == nil {
		return ViewWindow{}, errors.New("nil application")
	}
	if first < 0 || limit <= 0 || limit > MaxProjectionWindow {
		return ViewWindow{}, errors.New("invalid view window")
	}
	doc := a.Documents[id]
	if doc == nil || doc.Editor == nil {
		return ViewWindow{}, errors.New("unknown document")
	}
	mode := a.ViewDensity(id)
	window := ViewWindow{DocumentID: id, Mode: mode, Revision: doc.Revision(), Ready: true, Supported: true, First: first}
	if mode == ViewDensityFull {
		return window, nil
	}
	if doc.RootLanguage != string(language.Markdown) && !AnalysisSupported(language.ID(doc.RootLanguage)) {
		window.Supported = false
		return window, nil
	}
	if !doc.DerivedCurrent() {
		window.Ready = false
		return window, nil
	}

	cache, ok := a.semanticViews[id]
	if !ok || cache.revision != doc.Revision() || cache.mode != mode || cache.projection == nil {
		segments := semanticViewSegments(doc, id, mode)
		projection, err := a.NewProjection("document-view", string(mode), segments)
		if err != nil {
			return ViewWindow{}, err
		}
		cache = semanticViewCache{revision: doc.Revision(), mode: mode, projection: projection}
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
		ordinal := projectionWindow.First + i
		previousEnd := 0
		if ordinal > 0 {
			previousEnd = cache.projection.segments[ordinal-1].source.EndByte
		}
		omittedBefore := segment.StartByte > previousEnd
		omittedAfter := ordinal == projectionWindow.Total-1 && segment.EndByte < doc.Editor.Buffer.ByteLen()
		window.Segments[i] = ViewSegment{
			ProjectionSegmentView: segment,
			Text:                  text,
			Truncated:             truncated,
			SourceStartLine:       startLine + 1,
			SourceEndLine:         endLine + 1,
			OmittedBefore:         omittedBefore,
			OmittedAfter:          omittedAfter,
		}
	}
	return window, nil
}

func semanticViewSegments(doc *document.Document, id DocumentID, mode ViewDensity) []ProjectionSegment {
	if doc == nil || mode == ViewDensityFull {
		return nil
	}
	revision := doc.Revision()
	segments := make([]ProjectionSegment, 0)
	add := func(start, end int, label, context string) {
		if start < 0 || end <= start || end > doc.Editor.Buffer.ByteLen() {
			return
		}
		segments = append(segments, ProjectionSegment{
			DocumentID: id, SourceRevision: revision,
			StartByte: start, EndByte: end, Label: label, Context: context,
		})
	}
	if doc.RootLanguage == string(language.Markdown) {
		for _, heading := range doc.Projections.Headings {
			add(heading.StartByte, heading.EndByte, "heading", fmt.Sprintf("level %d", heading.Level))
		}
		if mode == ViewDensitySkim {
			headingIndex := 0
			seenParagraphInSection := false
			for _, paragraph := range doc.Projections.Paragraphs {
				for headingIndex < len(doc.Projections.Headings) && doc.Projections.Headings[headingIndex].StartByte < paragraph.StartByte {
					headingIndex++
					seenParagraphInSection = false
				}
				if seenParagraphInSection {
					continue
				}
				add(paragraph.StartByte, paragraph.EndByte, "paragraph opening", "first paragraph in section")
				seenParagraphInSection = true
			}
			for _, task := range doc.Projections.Tasks {
				add(task.StartByte, task.EndByte, "task", "task item")
			}
			for _, block := range doc.Projections.Blocks {
				if block.Kind != document.BlockCode {
					continue
				}
				start, end := firstSourceLines(&doc.Editor.Buffer, block.StartByte, block.EndByte, 1)
				add(start, end, "code", "fenced-code opening")
			}
		}
	} else {
		for _, symbol := range doc.Projections.Code.Symbols {
			lines := 1
			if mode == ViewDensitySkim {
				lines = 2
			}
			start, end := firstSourceLines(&doc.Editor.Buffer, symbol.StartByte, symbol.EndByte, lines)
			label := symbol.Kind
			if label == "" {
				label = "symbol"
			}
			add(start, end, label, symbol.Name)
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

func firstSourceLines(buffer interface {
	LineAt(int) (int, bool)
	LineRange(int) (int, int, bool)
}, start, end, maxLines int) (int, int) {
	if buffer == nil || start < 0 || end <= start || maxLines <= 0 {
		return 0, 0
	}
	line, ok := buffer.LineAt(start)
	if !ok {
		return 0, 0
	}
	lineStart, lineEnd, ok := buffer.LineRange(line)
	if !ok {
		return 0, 0
	}
	excerptStart, excerptEnd := max(start, lineStart), min(end, lineEnd)
	for count := 1; count < maxLines && excerptEnd < end; count++ {
		nextStart, nextEnd, exists := buffer.LineRange(line + count)
		if !exists || nextStart >= end {
			break
		}
		excerptEnd = min(end, nextEnd)
	}
	return excerptStart, excerptEnd
}

func utf8Prefix(value []byte, limit int) []byte {
	if len(value) <= limit {
		return value
	}
	end := limit
	for end > 0 && !utf8.RuneStart(value[end]) {
		end--
	}
	return value[:end]
}
