package application

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"sort"
	"unicode"

	"scratchpad/document"
	"scratchpad/editor"
	"scratchpad/language"
)

const (
	SemanticZoomFull = iota
	SemanticZoomFocus
	SemanticZoomSkim
	SemanticZoomOverview
)

const MaxSemanticZoomFolds = 4096
const semanticZoomScanBytes = 32 * 1024
const semanticZoomBackgroundBytes = 64 * 1024
const semanticZoomBackgroundLines = 2048

var ErrInvalidSemanticZoomDepth = errors.New("semantic zoom depth must be between 0 and 3")
var ErrInvalidSemanticZoomAnchor = errors.New("semantic zoom anchor outside source")
var ErrSemanticZoomCanceled = errors.New("semantic zoom construction canceled")

// SemanticZoomFold hides complete logical source lines, including their LF or
// CRLF terminators. Both line and byte coordinates are zero-based, half-open.
// EndByte may equal the source length for a final unterminated line. Label is
// presentation metadata, never a copied source excerpt.
type SemanticZoomFold struct {
	StartLine int
	EndLine   int
	StartByte int
	EndByte   int
	Label     string
	Silent    bool
}

// SemanticZoomPlan is detached metadata for one document instance and revision.
// Its folds are sorted and disjoint. The caller owns the returned slice; later
// edits, queries, or reopening the same path cannot change an existing plan.
// A frontend must discard it when its instance or source revision changes.
// Ready=false requires retrying after current derived projections are published;
// Supported=false requires the Full editor. Neither state carries partial folds.
// LineCount includes the editor's final empty logical line after a trailing LF.
type SemanticZoomPlan struct {
	DocumentID DocumentID
	Revision   uint64
	InstanceID uint64
	Generation uint64
	Depth      int
	AnchorByte int
	Ready      bool
	Supported  bool
	Reason     string
	LineCount  int
	Folds      []SemanticZoomFold
}

// SemanticZoomSnapshot is an immutable, detached input for plan construction.
// Capture it on the application goroutine, then pass it to BuildSemanticZoom
// from a bounded worker so whole-source scans never hold the application lock.
type SemanticZoomSnapshot struct {
	plan         SemanticZoomPlan
	buffer       editor.BufferSnapshot
	projections  document.Projections
	rootLanguage string
	lineCount    int
}

// RequiresBackground reports whether the captured input exceeds the small
// bound kept on the serialized command path.
func (s SemanticZoomSnapshot) RequiresBackground() bool {
	return s.buffer.ByteLen() > semanticZoomBackgroundBytes || s.lineCount > semanticZoomBackgroundLines ||
		len(s.projections.Headings)+len(s.projections.Paragraphs)+len(s.projections.Tasks)+len(s.projections.Blocks)+
			len(s.projections.Code.Highlights)+len(s.projections.Code.Symbols)+len(s.projections.Code.Folds) > 2048
}

// CaptureSemanticZoom validates the request and captures immutable source and
// derived metadata without scanning source bytes. The returned plan is already
// complete for Full, unsupported, and not-yet-derived requests; a non-nil
// snapshot requires BuildSemanticZoom to produce its folds.
func (a *Application) CaptureSemanticZoom(id DocumentID, revision uint64, depth int, anchorByte int) (plan SemanticZoomPlan, snapshot *SemanticZoomSnapshot, err error) {
	if a == nil {
		return SemanticZoomPlan{}, nil, errors.New("nil application")
	}
	if depth < SemanticZoomFull || depth > SemanticZoomOverview {
		return SemanticZoomPlan{}, nil, ErrInvalidSemanticZoomDepth
	}
	doc := a.Documents[id]
	if doc == nil || doc.Editor == nil {
		return SemanticZoomPlan{}, nil, errors.New("unknown document")
	}
	if _, readOnly := a.FileViews[id]; readOnly {
		return SemanticZoomPlan{}, nil, ErrReadOnlyFileView
	}
	if revision != doc.Revision() {
		return SemanticZoomPlan{}, nil, fmt.Errorf("%w: expected %d, current %d", ErrStaleEditorRevision, revision, doc.Revision())
	}
	buffer := &doc.Editor.Buffer
	if anchorByte < 0 || anchorByte > buffer.ByteLen() {
		return SemanticZoomPlan{}, nil, ErrInvalidSemanticZoomAnchor
	}
	plan = SemanticZoomPlan{DocumentID: id, Revision: revision, InstanceID: doc.InstanceID(),
		Depth: depth, AnchorByte: anchorByte, Ready: true, Supported: true, LineCount: buffer.LineCount(),
		Folds: make([]SemanticZoomFold, 0)}
	if depth == SemanticZoomFull {
		return plan, nil, nil
	}
	plain := doc.RootLanguage == "" || doc.RootLanguage == string(language.PlainText)
	markdown := doc.RootLanguage == string(language.Markdown)
	if !plain && !markdown && !AnalysisSupported(language.ID(doc.RootLanguage)) {
		plan.Supported, plan.Reason = false, "unsupported_language"
		return plan, nil, nil
	}
	if !plain && (!doc.DerivedCurrent() || (!markdown &&
		(doc.Projections.Code.Revision != revision || doc.Projections.Code.Language != doc.RootLanguage))) {
		plan.Ready, plan.Reason = false, "derived_not_current"
		return plan, nil, nil
	}
	// Source descriptors are captured because the live piece tree can change.
	// Published projection arrays are immutable after SetDerived, so capture
	// their slice headers instead of copying potentially large derived tables
	// while the serialized application command is running.
	snapshot = &SemanticZoomSnapshot{
		plan: plan, buffer: buffer.Snapshot(), projections: doc.Projections,
		rootLanguage: doc.RootLanguage, lineCount: buffer.LineCount(),
	}
	return plan, snapshot, nil
}

// BuildSemanticZoom constructs a plan solely from an immutable snapshot. It
// checks cancellation throughout long source scans and structural walks.
func BuildSemanticZoom(ctx context.Context, snapshot SemanticZoomSnapshot) (SemanticZoomPlan, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	plan := snapshot.plan
	if err := ctx.Err(); err != nil {
		return SemanticZoomPlan{}, ErrSemanticZoomCanceled
	}
	source, err := newSemanticZoomSource(ctx, snapshot.buffer, snapshot.lineCount)
	if err != nil {
		if errors.Is(err, ErrSemanticZoomCanceled) || ctx.Err() != nil {
			return SemanticZoomPlan{}, ErrSemanticZoomCanceled
		}
		return SemanticZoomPlan{}, err
	}
	var hidden []semanticZoomLines
	switch {
	case snapshot.rootLanguage == "" || snapshot.rootLanguage == string(language.PlainText):
		paragraphs, canceled := source.paragraphs()
		if canceled {
			return SemanticZoomPlan{}, ErrSemanticZoomCanceled
		}
		visible := source.proseVisible(paragraphs, plan.Depth, plan.AnchorByte)
		hidden = subtractSemanticZoomLines([]semanticZoomLines{{0, source.contentLines()}}, visible)
	case snapshot.rootLanguage == string(language.Markdown):
		visible := source.markdownVisible(snapshot.projections, plan.Depth, plan.AnchorByte)
		hidden = subtractSemanticZoomLines([]semanticZoomLines{{0, source.contentLines()}}, visible)
	default:
		hidden = source.codeHidden(snapshot.projections.Code, plan.Depth, plan.AnchorByte)
	}
	if ctx.Err() != nil {
		return SemanticZoomPlan{}, ErrSemanticZoomCanceled
	}
	if len(hidden) > MaxSemanticZoomFolds {
		plan.Supported, plan.Reason = false, "fold_limit_exceeded"
		return plan, nil
	}
	for i, lines := range hidden {
		if i%128 == 0 && ctx.Err() != nil {
			return SemanticZoomPlan{}, ErrSemanticZoomCanceled
		}
		if start, end := source.lineStart(lines.start), source.lineStart(lines.end); end > start {
			silent, canceled := source.whitespaceOnly(lines)
			if canceled {
				return SemanticZoomPlan{}, ErrSemanticZoomCanceled
			}
			plan.Folds = append(plan.Folds, SemanticZoomFold{StartLine: lines.start, EndLine: lines.end,
				StartByte: start, EndByte: end, Label: fmt.Sprintf("%d lines", lines.end-lines.start),
				Silent: silent})
		}
	}
	if ctx.Err() != nil {
		return SemanticZoomPlan{}, ErrSemanticZoomCanceled
	}
	return plan, nil
}

// QuerySemanticZoom is the synchronous compatibility API used by small local
// callers and benchmarks. The bridge uses CaptureSemanticZoom plus a worker
// for large plans.
func (a *Application) QuerySemanticZoom(id DocumentID, revision uint64, depth int, anchorByte int) (SemanticZoomPlan, error) {
	plan, snapshot, err := a.CaptureSemanticZoom(id, revision, depth, anchorByte)
	if err != nil || snapshot == nil {
		return plan, err
	}
	return BuildSemanticZoom(context.Background(), *snapshot)
}

type semanticZoomLines struct{ start, end int }

type semanticZoomBuffer interface {
	ByteLen() int
	ReadAt([]byte, int64) (int, error)
}

type semanticZoomSource struct {
	ctx    context.Context
	buffer semanticZoomBuffer
	starts []int
	blank  []bool
}

// Only metadata survives this scan. Each temporary source read is at most 32KiB;
// no complete source, oversized logical line, or paragraph is materialized.
func newSemanticZoomSource(ctx context.Context, buffer semanticZoomBuffer, lineCount int) (semanticZoomSource, error) {
	s := semanticZoomSource{ctx: ctx, buffer: buffer, starts: make([]int, 1, lineCount), blank: make([]bool, 1, lineCount)}
	s.blank[0] = true
	storage := make([]byte, min(semanticZoomScanBytes, buffer.ByteLen()))
	for at := 0; at < buffer.ByteLen(); {
		if ctx.Err() != nil {
			return semanticZoomSource{}, ErrSemanticZoomCanceled
		}
		end := at + min(semanticZoomScanBytes, buffer.ByteLen()-at)
		count, err := buffer.ReadAt(storage[:end-at], int64(at))
		if err != nil && err != io.EOF || count != end-at {
			return semanticZoomSource{}, errors.New("could not read immutable semantic zoom source")
		}
		data := storage[:count]
		for i, c := range data {
			if c == '\n' {
				s.starts = append(s.starts, at+i+1)
				s.blank = append(s.blank, true)
			} else if c != ' ' && c != '\t' && c != '\r' && c != '\v' && c != '\f' {
				s.blank[len(s.blank)-1] = false
			}
		}
		at = end
	}
	return s, nil
}

func (s semanticZoomSource) lineStart(line int) int {
	if line >= len(s.starts) {
		return s.buffer.ByteLen()
	}
	return s.starts[line]
}

func (s semanticZoomSource) lineAt(at int) int {
	return max(0, sort.Search(len(s.starts), func(i int) bool { return s.starts[i] > at })-1)
}

func (s semanticZoomSource) contentLines() int {
	count := len(s.starts)
	if s.starts[count-1] == s.buffer.ByteLen() {
		count-- // The empty EOF caret line has no bytes to collapse.
	}
	return count
}

func (s semanticZoomSource) whitespaceOnly(lines semanticZoomLines) (only, canceled bool) {
	if lines.start < 0 || lines.end <= lines.start || lines.end > len(s.blank) {
		return false, false
	}
	for line := lines.start; line < lines.end; line++ {
		if line%1024 == 0 && s.ctx.Err() != nil {
			return false, true
		}
		if !s.blank[line] {
			return false, false
		}
	}
	return true, false
}

func (s semanticZoomSource) lines(start, end int) semanticZoomLines {
	if start < 0 || end <= start || end > s.buffer.ByteLen() {
		return semanticZoomLines{}
	}
	return semanticZoomLines{s.lineAt(start), s.lineAt(end-1) + 1}
}

func (s semanticZoomSource) paragraphs() ([]document.ParagraphRange, bool) {
	var paragraphs []document.ParagraphRange
	for line := 0; line < s.contentLines(); {
		if line%1024 == 0 && s.ctx.Err() != nil {
			return nil, true
		}
		if s.blank[line] {
			line++
			continue
		}
		start := line
		for line < s.contentLines() && !s.blank[line] {
			if line%1024 == 0 && s.ctx.Err() != nil {
				return nil, true
			}
			line++
		}
		paragraphs = append(paragraphs, document.ParagraphRange{StartByte: s.lineStart(start), EndByte: s.lineStart(line)})
	}
	return paragraphs, false
}

// A bounded reader permits full opening sentences of any length, including
// UTF-8 punctuation and sentences spanning source lines/chunk boundaries.
type semanticZoomReader struct {
	buffer  semanticZoomBuffer
	at, end int
}

func (r *semanticZoomReader) Read(p []byte) (int, error) {
	if r.at >= r.end {
		return 0, io.EOF
	}
	end := r.at + min(len(p), r.end-r.at)
	count, err := r.buffer.ReadAt(p[:end-r.at], int64(r.at))
	if err != nil {
		r.at += count
		return count, err
	}
	r.at += count
	return count, nil
}

func (s semanticZoomSource) opening(start, end int) semanticZoomLines {
	if end <= start || start < 0 || end > s.buffer.ByteLen() {
		return semanticZoomLines{}
	}
	reader := bufio.NewReaderSize(&semanticZoomReader{buffer: s.buffer, at: start, end: end}, min(1024, end-start))
	at, sentenceEnd, terminal := start, end, false
	readBytes, nextCancelCheck := 0, semanticZoomScanBytes
	for at < end {
		if readBytes >= nextCancelCheck {
			if s.ctx.Err() != nil {
				return semanticZoomLines{}
			}
			nextCancelCheck += semanticZoomScanBytes
		}
		r, size, err := reader.ReadRune()
		if err != nil {
			break
		}
		readBytes += size
		if terminal && unicode.IsSpace(r) {
			return s.lines(start, sentenceEnd)
		}
		at += size
		switch r {
		case '.', '!', '?', '。', '！', '？':
			terminal, sentenceEnd = true, at
		case '"', '\'', ')', ']', '}', '”', '’', '»':
			if terminal {
				sentenceEnd = at
			}
		default:
			terminal = false
		}
	}
	return s.lines(start, end)
}

func (s semanticZoomSource) proseVisible(paragraphs []document.ParagraphRange, depth, anchor int) []semanticZoomLines {
	var visible []semanticZoomLines
	// On a separating blank line, focus the preceding paragraph; before the
	// first paragraph, focus the first. EOF therefore has a stable target too.
	focused := sort.Search(len(paragraphs), func(i int) bool { return paragraphs[i].StartByte > anchor }) - 1
	if focused < 0 && len(paragraphs) > 0 {
		focused = 0
	}
	for i, p := range paragraphs {
		if i%128 == 0 && s.ctx.Err() != nil {
			return nil
		}
		if depth == SemanticZoomFocus && i == focused {
			visible = append(visible, s.lines(p.StartByte, p.EndByte))
		} else {
			visible = append(visible, s.opening(p.StartByte, p.EndByte))
		}
	}
	return visible
}

// Current heading projections can end before a CRLF Setext underline. Keep
// that source syntax with its already-projected heading; this bounded check
// never discovers headings or reparses Markdown.
func (s semanticZoomSource) headingLines(heading document.Heading) semanticZoomLines {
	lines := s.lines(heading.StartByte, heading.EndByte)
	if lines.end <= lines.start || lines.end >= s.contentLines() || heading.Level > 2 {
		return lines
	}
	prefixStart := s.lineStart(lines.start)
	var prefix [4]byte
	prefixLen := min(len(prefix), s.buffer.ByteLen()-prefixStart)
	read, _ := s.buffer.ReadAt(prefix[:prefixLen], int64(prefixStart))
	for _, c := range prefix[:read] {
		if c == '#' {
			return lines
		}
		if c != ' ' && c != '\t' {
			break
		}
	}
	marker := rune('=')
	if heading.Level == 2 {
		marker = '-'
	}
	reader := bufio.NewReaderSize(&semanticZoomReader{buffer: s.buffer, at: s.lineStart(lines.end), end: s.lineStart(lines.end + 1)}, 256)
	seen, scanned := false, 0
	for {
		if scanned >= semanticZoomScanBytes {
			if s.ctx.Err() != nil {
				return semanticZoomLines{}
			}
			scanned = 0
		}
		r, size, err := reader.ReadRune()
		if err != nil {
			break
		}
		scanned += size
		if r == marker {
			seen = true
		} else if r != ' ' && r != '\t' && r != '\r' && r != '\n' {
			return lines
		}
	}
	if seen {
		lines.end++
	}
	return lines
}

func (s semanticZoomSource) markdownVisible(p document.Projections, depth, anchor int) []semanticZoomLines {
	headings := append([]document.Heading(nil), p.Headings...)
	sort.SliceStable(headings, func(i, j int) bool { return headings[i].StartByte < headings[j].StartByte })
	paragraphs := append([]document.ParagraphRange(nil), p.Paragraphs...)
	sort.SliceStable(paragraphs, func(i, j int) bool { return paragraphs[i].StartByte < paragraphs[j].StartByte })
	var visible []semanticZoomLines
	if len(headings) == 0 {
		visible = s.proseVisible(paragraphs, depth, anchor)
	} else {
		for i, heading := range headings {
			if i%128 == 0 && s.ctx.Err() != nil {
				return nil
			}
			visible = append(visible, s.headingLines(heading))
		}
		if depth == SemanticZoomFocus {
			index := sort.Search(len(headings), func(i int) bool { return headings[i].StartByte > anchor }) - 1
			start, end := 0, s.buffer.ByteLen()
			if index < 0 {
				end = headings[0].StartByte
			} else {
				start = headings[index].StartByte
				for next := index + 1; next < len(headings); next++ {
					if headings[next].Level <= headings[index].Level {
						end = headings[next].StartByte
						break
					}
				}
			}
			visible = append(visible, s.lines(start, end))
		}
		if depth == SemanticZoomSkim {
			headingIndex, previousSection := 0, -1
			for i, paragraph := range paragraphs {
				if i%128 == 0 && s.ctx.Err() != nil {
					return nil
				}
				for headingIndex < len(headings) && headings[headingIndex].StartByte <= paragraph.StartByte {
					headingIndex++
				}
				if previousSection != headingIndex {
					visible = append(visible, s.opening(paragraph.StartByte, paragraph.EndByte))
					previousSection = headingIndex
				}
			}
		}
	}
	if depth == SemanticZoomSkim {
		for i, task := range p.Tasks {
			if i%128 == 0 && s.ctx.Err() != nil {
				return nil
			}
			visible = append(visible, s.lines(task.StartByte, task.EndByte))
		}
	}
	if depth == SemanticZoomSkim || len(headings) == 0 {
		for i, block := range p.Blocks {
			if i%128 == 0 && s.ctx.Err() != nil {
				return nil
			}
			if block.Kind == document.BlockCode {
				line := s.lines(block.StartByte, block.EndByte)
				line.end = min(line.end, line.start+1)
				visible = append(visible, line)
			}
		}
	}
	return visible
}

func (s semanticZoomSource) codeHidden(p document.CodeProjection, depth, anchor int) []semanticZoomLines {
	// Parser body folds end at their containing symbol's end. Taking the latest
	// start at that end selects the body instead of the declaration fold, without
	// rescanning every fold for every symbol. A first-line fallback handles
	// projections (e.g. type_spec) which expose only a declaration fold.
	bodyStarts := make(map[int]int, len(p.Folds))
	for i, fold := range p.Folds {
		if i%256 == 0 && s.ctx.Err() != nil {
			return nil
		}
		bodyStarts[fold.EndByte] = max(bodyStarts[fold.EndByte], fold.StartByte)
	}
	var comments []semanticZoomLines
	if depth == SemanticZoomFocus {
		for i, span := range p.Highlights {
			if i%256 == 0 && s.ctx.Err() != nil {
				return nil
			}
			if span.Kind == document.HighlightComment {
				comments = append(comments, s.lines(span.StartByte, span.EndByte))
			}
		}
		comments = mergeSemanticZoomLines(comments)
	}
	var hidden, headers []semanticZoomLines
	var focused semanticZoomLines
	focusedBytes := s.buffer.ByteLen() + 1
	for i, symbol := range p.Symbols {
		if i%256 == 0 && s.ctx.Err() != nil {
			return nil
		}
		lines := s.lines(symbol.StartByte, symbol.EndByte)
		if lines.end <= lines.start {
			continue
		}
		header := semanticZoomLines{lines.start, lines.start + 1}
		if start, ok := bodyStarts[symbol.EndByte]; ok && start > symbol.StartByte {
			header.end = s.lineAt(start) + 1
		} else if depth != SemanticZoomOverview && symbol.Kind != "type" {
			// Without a parser body range, preserve a potentially multiline
			// signature/declaration in full rather than guessing where it ends.
			header.end = lines.end
		}
		if depth == SemanticZoomSkim && symbol.Kind == "type" {
			header.end = lines.end // Important declarations, including struct fields.
		}
		headers = append(headers, header)
		hidden = append(hidden, semanticZoomLines{header.end, lines.end})
		focusStart := s.lineStart(lines.start)
		comment := sort.Search(len(comments), func(i int) bool { return comments[i].end >= lines.start })
		if comment < len(comments) && comments[comment].end == lines.start {
			focusStart = s.lineStart(comments[comment].start)
		}
		if focusStart <= anchor && (anchor < s.lineStart(lines.end) || anchor == s.buffer.ByteLen() && anchor == symbol.EndByte) && symbol.EndByte-symbol.StartByte < focusedBytes {
			focused, focusedBytes = lines, symbol.EndByte-symbol.StartByte
		}
	}
	if depth == SemanticZoomFocus {
		headers = append(headers, focused)
	}
	if depth == SemanticZoomOverview && len(headers) > 0 {
		return subtractSemanticZoomLines([]semanticZoomLines{{0, s.contentLines()}}, headers)
	}
	// Focus/Skim preserve imports, doc comments and declarations which are not
	// represented as symbols. Header and anchor exceptions also handle nesting.
	return subtractSemanticZoomLines(hidden, headers)
}

func mergeSemanticZoomLines(ranges []semanticZoomLines) []semanticZoomLines {
	sort.Slice(ranges, func(i, j int) bool {
		if ranges[i].start == ranges[j].start {
			return ranges[i].end < ranges[j].end
		}
		return ranges[i].start < ranges[j].start
	})
	merged := ranges[:0]
	for _, r := range ranges {
		if r.end <= r.start {
			continue
		}
		if len(merged) > 0 && r.start <= merged[len(merged)-1].end {
			merged[len(merged)-1].end = max(merged[len(merged)-1].end, r.end)
		} else {
			merged = append(merged, r)
		}
	}
	return merged
}

func subtractSemanticZoomLines(hidden, visible []semanticZoomLines) []semanticZoomLines {
	hidden, visible = mergeSemanticZoomLines(hidden), mergeSemanticZoomLines(visible)
	var result []semanticZoomLines
	v := 0
	for _, h := range hidden {
		start := h.start
		for v < len(visible) && visible[v].end <= start {
			v++
		}
		for j := v; j < len(visible) && visible[j].start < h.end; j++ {
			if visible[j].start > start {
				result = append(result, semanticZoomLines{start, visible[j].start})
			}
			start = max(start, visible[j].end)
		}
		if start < h.end {
			result = append(result, semanticZoomLines{start, h.end})
		}
	}
	return result
}
