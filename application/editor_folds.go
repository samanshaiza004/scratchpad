package application

import (
	"errors"
	"fmt"
	"sort"

	"scratchpad/document"
	"scratchpad/language"
)

const MaxEditorFolds = 4096

// EditorFold describes one parser-derived fold in authoritative source
// coordinates. The header and opening-delimiter line remain visible; folding
// replaces only the following body lines. These coordinates are valid only
// for the tagged document instance and revision.
type EditorFold struct {
	StartLine     int
	BodyStartLine int
	EndLine       int
	StartByte     int
	BodyStartByte int
	EndByte       int
	Label         string
}

// EditorFoldPlan is detached parser metadata. It never owns source bytes or
// mutates editor state. A not-ready plan asks the caller to retry after the
// existing derived-analysis lane publishes the current revision.
type EditorFoldPlan struct {
	DocumentID DocumentID
	Revision   uint64
	InstanceID uint64
	Ready      bool
	Supported  bool
	Reason     string
	LineCount  int
	Folds      []EditorFold
}

// QueryEditorFolds returns the current Markdown or code fold candidates. It
// runs on the application goroutine and consumes only the already-published
// disposable syntax projection; it never parses or changes source state.
func (a *Application) QueryEditorFolds(id DocumentID, revision uint64) (EditorFoldPlan, error) {
	if a == nil {
		return EditorFoldPlan{}, errors.New("nil application")
	}
	doc := a.Documents[id]
	if doc == nil || doc.Editor == nil {
		return EditorFoldPlan{}, errors.New("unknown document")
	}
	if _, readOnly := a.FileViews[id]; readOnly {
		return EditorFoldPlan{}, ErrReadOnlyFileView
	}
	if revision != doc.Revision() {
		return EditorFoldPlan{}, fmt.Errorf("%w: expected %d, current %d", ErrStaleEditorRevision, revision, doc.Revision())
	}
	plan := EditorFoldPlan{DocumentID: id, Revision: revision, InstanceID: doc.InstanceID(),
		Ready: true, Supported: true, LineCount: doc.Editor.Buffer.LineCount(), Folds: make([]EditorFold, 0)}
	markdown := doc.RootLanguage == string(language.Markdown)
	plain := doc.RootLanguage == "" || doc.RootLanguage == string(language.PlainText)
	if !markdown && !plain && !AnalysisSupported(language.ID(doc.RootLanguage)) {
		plan.Supported, plan.Reason = false, "unsupported_language"
		return plan, nil
	}
	if plain {
		return plan, nil
	}
	if !doc.DerivedCurrent() || (!markdown &&
		(doc.Projections.Code.Revision != revision || doc.Projections.Code.Language != doc.RootLanguage)) {
		plan.Ready, plan.Reason = false, "derived_not_current"
		return plan, nil
	}
	buffer := &doc.Editor.Buffer
	appendRange := func(start, bodyStart, end int, label string) {
		if start < 0 || end <= start || end > buffer.ByteLen() {
			return
		}
		// Older or synthetic projections may not carry an opening-delimiter
		// offset. Retain the declaration/header line as the conservative fallback.
		if bodyStart < start || bodyStart >= end {
			bodyStart = start
		}
		startLine, startOK := buffer.LineAt(start)
		bodyDelimiterLine, bodyOK := buffer.LineAt(bodyStart)
		endLine, endOK := buffer.LineAt(end - 1)
		if !startOK || !bodyOK || !endOK {
			return
		}
		bodyLine := bodyDelimiterLine + 1
		hiddenStartByte, _, hiddenStartOK := buffer.LineRange(bodyLine)
		endLine++
		if !hiddenStartOK || bodyLine >= endLine {
			return
		}
		if label == "" {
			label = fmt.Sprintf("%d lines", endLine-bodyLine)
		}
		plan.Folds = append(plan.Folds, EditorFold{StartLine: startLine, BodyStartLine: bodyLine, EndLine: endLine,
			StartByte: start, BodyStartByte: hiddenStartByte, EndByte: end, Label: label})
	}
	if markdown {
		for _, fold := range doc.Projections.Folds {
			if fold.HeadingStart < 0 || fold.StartByte < 0 || fold.EndByte <= fold.StartByte || fold.EndByte > buffer.ByteLen() {
				continue
			}
			label := ""
			for _, heading := range doc.Projections.Headings {
				if heading.StartByte == fold.HeadingStart {
					label = heading.Text
					break
				}
			}
			// Markdown's fold range already starts at the first body byte, so
			// its first body line is not a delimiter line to preserve.
			startLine, startOK := buffer.LineAt(fold.HeadingStart)
			bodyLine, bodyOK := buffer.LineAt(fold.StartByte)
			endLine, endOK := buffer.LineAt(fold.EndByte - 1)
			hiddenStartByte, _, hiddenStartOK := buffer.LineRange(bodyLine)
			if !startOK || !bodyOK || !endOK || !hiddenStartOK {
				continue
			}
			endLine++
			if bodyLine >= endLine {
				continue
			}
			if label == "" {
				label = fmt.Sprintf("%d lines", endLine-bodyLine)
			}
			plan.Folds = append(plan.Folds, EditorFold{StartLine: startLine, BodyStartLine: bodyLine,
				EndLine: endLine, StartByte: fold.HeadingStart, BodyStartByte: hiddenStartByte,
				EndByte: fold.EndByte, Label: label})
		}
	}
	if len(doc.Projections.Code.Folds) > 0 && doc.Projections.Code.Revision == revision {
		for _, fold := range doc.Projections.Code.Folds {
			label := ""
			labelWidth := int(^uint(0) >> 1)
			for _, symbol := range doc.Projections.Code.Symbols {
				if symbol.StartByte <= fold.StartByte && symbol.EndByte >= fold.EndByte && symbol.EndByte-symbol.StartByte < labelWidth {
					labelWidth = symbol.EndByte - symbol.StartByte
					label = symbol.Kind + " " + symbol.Name
				}
			}
			appendRange(fold.StartByte, fold.BodyStartByte, fold.EndByte, label)
		}
	}
	if len(plan.Folds) > MaxEditorFolds {
		plan.Folds = nil
		plan.Supported, plan.Reason = false, "fold_limit_exceeded"
		return plan, nil
	}
	sort.SliceStable(plan.Folds, func(i, j int) bool {
		if plan.Folds[i].BodyStartLine == plan.Folds[j].BodyStartLine {
			return plan.Folds[i].EndLine > plan.Folds[j].EndLine
		}
		return plan.Folds[i].BodyStartLine < plan.Folds[j].BodyStartLine
	})
	// Parser wrappers and Markdown/code composition can yield equivalent or
	// crossing ranges. Keep one control for each visible row range, preserve
	// properly nested candidates, and drop crossings that the disjoint row map
	// cannot represent without hiding unrelated source.
	unique := plan.Folds[:0]
	stack := make([]EditorFold, 0, len(plan.Folds))
	for _, fold := range plan.Folds {
		for len(stack) > 0 && fold.BodyStartLine >= stack[len(stack)-1].EndLine {
			stack = stack[:len(stack)-1]
		}
		if len(stack) > 0 && fold.EndLine > stack[len(stack)-1].EndLine {
			continue
		}
		if len(unique) > 0 {
			previous := unique[len(unique)-1]
			if previous.BodyStartLine == fold.BodyStartLine && previous.EndLine == fold.EndLine {
				continue
			}
		}
		unique = append(unique, fold)
		stack = append(stack, fold)
	}
	plan.Folds = unique
	return plan, nil
}
