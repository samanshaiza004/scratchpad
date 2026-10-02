package backend

import (
	"scratchpad/application"
	"scratchpad/document"
	"scratchpad/language"
)

// wirePresentationKind assigns stable transport IDs. These values are
// independent of document.PresentationKind's Go enum ordinals.
func wirePresentationKind(kind document.PresentationKind) uint32 {
	switch kind {
	case document.PresentationSyntax:
		return 1
	case document.PresentationHeading:
		return 2
	case document.PresentationStrong:
		return 3
	case document.PresentationEmphasis:
		return 4
	case document.PresentationInlineCode:
		return 5
	case document.PresentationLink:
		return 6
	case document.PresentationStrike:
		return 7
	case document.PresentationCodeBlock:
		return 8
	case document.PresentationBlockquote:
		return 9
	case document.PresentationListMarker:
		return 10
	case document.PresentationTaskMarker:
		return 11
	case document.PresentationCodeComment:
		return 12
	case document.PresentationCodeKeyword:
		return 13
	case document.PresentationCodeString:
		return 14
	case document.PresentationCodeNumber:
		return 15
	case document.PresentationCodeType:
		return 16
	case document.PresentationCodeFunction:
		return 17
	case document.PresentationCodeMethod:
		return 18
	case document.PresentationCodeVariable:
		return 19
	case document.PresentationCodeConstant:
		return 20
	case document.PresentationCodeProperty:
		return 21
	case document.PresentationCodeOperator:
		return 22
	case document.PresentationCodePunctuation:
		return 23
	case document.PresentationCodeBuiltin:
		return 24
	case document.PresentationCodeParameter:
		return 25
	case document.PresentationCodeTag:
		return 26
	case document.PresentationCodeAttribute:
		return 27
	case document.PresentationThematicBreak:
		return 28
	case document.PresentationTable:
		return 29
	case document.PresentationTableHeader:
		return 30
	case document.PresentationTableDelimiter:
		return 31
	case document.PresentationTablePipe:
		return 32
	case document.PresentationTableCell:
		return 33
	default:
		return 0
	}
}

func windowPresentation(doc *document.Document, sourceStart int, source []byte) (uint64, bool, bool, []presentationWireRecord, []presentationWireRecord) {
	if doc == nil {
		return 0, false, false, nil, nil
	}
	markdown := doc.RootLanguage == string(language.Markdown)
	code := doc.Projections.Code
	if !markdown && !application.AnalysisSupported(language.ID(doc.RootLanguage)) {
		return doc.Revision(), true, false, nil, nil
	}
	sourceEnd := sourceStart + len(source)
	revision := doc.Revision()
	ready := doc.DerivedCurrent()
	if markdown {
		ready = ready && doc.Projections.Markdown.Revision == revision
	} else {
		ready = ready && doc.Projections.Code.Revision == revision && doc.Projections.Code.Language != ""
	}
	if !ready {
		return revision, false, false, nil, nil
	}
	spanRecords := make([]presentationWireRecord, 0)
	spansTruncated := false
	if markdown {
		spans, truncated := doc.Projections.Markdown.SpansInLimit(sourceStart, sourceEnd, MaxPresentationRecords)
		spansTruncated = truncated
		spanRecords = make([]presentationWireRecord, 0, len(spans))
		for _, span := range spans {
			kind := wirePresentationKind(span.Kind)
			if kind == 0 {
				continue
			}
			start := max(span.StartByte, sourceStart)
			end := min(span.EndByte, sourceEnd)
			if start >= end {
				continue
			}
			spanRecords = append(spanRecords, presentationWireRecord{
				kind: kind, start: uint32(start - sourceStart), end: uint32(end - sourceStart),
				levelFlags: uint32(max(span.Level, 0) & 0xff),
			})
		}
	}
	remaining := MaxPresentationRecords - len(spanRecords)
	// Fenced Go is parsed as a nested language, but its byte ranges share the
	// Markdown source coordinate space and use the same bounded trailer.
	if code.Revision == revision && code.Language != "" {
		highlights, truncated := code.HighlightsInLimit(sourceStart, sourceEnd, remaining)
		spansTruncated = spansTruncated || truncated
		for _, span := range highlights {
			kind := wireHighlightKind(span.Kind)
			if kind == 0 {
				continue
			}
			start := max(span.StartByte, sourceStart)
			end := min(span.EndByte, sourceEnd)
			if start >= end {
				continue
			}
			spanRecords = append(spanRecords, presentationWireRecord{
				kind: kind, start: uint32(start - sourceStart), end: uint32(end - sourceStart),
			})
		}
	}
	remaining = MaxPresentationRecords - len(spanRecords)
	var blocks []document.BlockPresentation
	blocksTruncated := false
	if markdown {
		blocks, blocksTruncated = doc.Projections.BlocksIn(sourceStart, sourceEnd, remaining+1)
	}
	if len(blocks) > remaining {
		blocks = blocks[:remaining]
		blocksTruncated = true
	}
	blockRecords := make([]presentationWireRecord, 0, len(blocks))
	for _, block := range blocks {
		kind := wireBlockKind(block.Kind)
		if kind == 0 {
			continue
		}
		start := max(block.StartByte, sourceStart)
		end := min(block.EndByte, sourceEnd)
		if start >= end {
			continue
		}
		levelFlags := uint32(max(block.Level, 0) & 0xff)
		if block.StartByte < sourceStart {
			levelFlags |= blockClippedStartFlag
		}
		if block.EndByte > sourceEnd {
			levelFlags |= blockClippedEndFlag
		}
		blockRecords = append(blockRecords, presentationWireRecord{
			kind: kind, start: uint32(start - sourceStart), end: uint32(end - sourceStart), levelFlags: levelFlags,
		})
	}
	return revision, true, spansTruncated || blocksTruncated, spanRecords, blockRecords
}

func wireHighlightKind(kind document.HighlightKind) uint32 {
	switch kind {
	case document.HighlightComment:
		return wirePresentationKind(document.PresentationCodeComment)
	case document.HighlightKeyword:
		return wirePresentationKind(document.PresentationCodeKeyword)
	case document.HighlightString:
		return wirePresentationKind(document.PresentationCodeString)
	case document.HighlightNumber:
		return wirePresentationKind(document.PresentationCodeNumber)
	case document.HighlightType:
		return wirePresentationKind(document.PresentationCodeType)
	case document.HighlightFunction:
		return wirePresentationKind(document.PresentationCodeFunction)
	case document.HighlightMethod:
		return wirePresentationKind(document.PresentationCodeMethod)
	case document.HighlightVariable:
		return wirePresentationKind(document.PresentationCodeVariable)
	case document.HighlightConstant:
		return wirePresentationKind(document.PresentationCodeConstant)
	case document.HighlightProperty:
		return wirePresentationKind(document.PresentationCodeProperty)
	case document.HighlightOperator:
		return wirePresentationKind(document.PresentationCodeOperator)
	case document.HighlightPunctuation:
		return wirePresentationKind(document.PresentationCodePunctuation)
	case document.HighlightBuiltin:
		return wirePresentationKind(document.PresentationCodeBuiltin)
	case document.HighlightParameter:
		return wirePresentationKind(document.PresentationCodeParameter)
	case document.HighlightTag:
		return wirePresentationKind(document.PresentationCodeTag)
	case document.HighlightAttribute:
		return wirePresentationKind(document.PresentationCodeAttribute)
	default:
		return 0
	}
}

func wireBlockKind(kind document.BlockKind) uint32 {
	switch kind {
	case document.BlockCode:
		return blockWireKindBase + 1
	case document.BlockQuote:
		return blockWireKindBase + 2
	case document.BlockList:
		return blockWireKindBase + 3
	case document.BlockThematicBreak:
		return blockWireKindBase + 4
	case document.BlockTable:
		return blockWireKindBase + 5
	default:
		return 0
	}
}
