package ui

import (
	"scratchpad/document"

	. "go.hasen.dev/shirei"
)

// SyntaxTheme keeps parser categories independent from their presentation
// values. Shirei Vec4 values are HSLA (hue 0..360, saturation/lightness
// 0..100), not normalized RGB.
type SyntaxTheme struct {
	Comment  Vec4
	Keyword  Vec4
	String   Vec4
	Number   Vec4
	Type     Vec4
	Function Vec4
}

func DefaultSyntaxTheme() SyntaxTheme {
	return SyntaxTheme{
		Comment:  Vec4{150, 22, 42, 1},
		Keyword:  Vec4{278, 62, 38, 1},
		String:   Vec4{28, 75, 38, 1},
		Number:   Vec4{215, 70, 42, 1},
		Type:     Vec4{185, 68, 35, 1},
		Function: Vec4{205, 72, 40, 1},
	}
}

// MarkdownPresentationStyle is the UI-owned mapping from semantic source
// spans to Shirei text modifiers. Markdown keeps its prose base style; code
// fragments opt into the same preferred programming face as code documents.
func MarkdownPresentationStyle(kind document.PresentationKind, _ TextStyleAttrs) []TextStyleFn {
	theme := DefaultTheme()
	syntax := DefaultSyntaxTheme()
	switch kind {
	case document.PresentationHeading, document.PresentationStrong:
		return []TextStyleFn{FontWeight(WeightBold)}
	case document.PresentationEmphasis:
		return []TextStyleFn{FontStyle(StyleItalic)}
	case document.PresentationInlineCode:
		return []TextStyleFn{Fonts(codeFontFamilies()...), TextBackgroundVec(theme.Highlight)}
	case document.PresentationLink:
		return []TextStyleFn{TextColorVec(theme.Focus), TextUnderline(true)}
	case document.PresentationStrike:
		return []TextStyleFn{TextStrike(true)}
	case document.PresentationCodeBlock:
		return []TextStyleFn{Fonts(codeFontFamilies()...), TextBackgroundVec(theme.ChromeInset)}
	case document.PresentationBlockquote, document.PresentationListMarker, document.PresentationSyntax, document.PresentationThematicBreak:
		return []TextStyleFn{TextColorVec(theme.Muted)}
	case document.PresentationTaskMarker:
		return []TextStyleFn{TextColorVec(theme.Focus), FontWeight(WeightBold)}
	// Source-visible tables keep raw pipes with no rendered-table model, so
	// the full-block table span takes the programming face: pipe columns
	// align under the prose face. The BlockTable row background stays owned
	// by the line decoration; no text background is set here.
	case document.PresentationTable:
		return []TextStyleFn{Fonts(codeFontFamilies()...)}
	case document.PresentationCodeComment:
		return []TextStyleFn{TextColorVec(syntax.Comment)}
	case document.PresentationCodeKeyword:
		return []TextStyleFn{TextColorVec(syntax.Keyword)}
	case document.PresentationCodeString:
		return []TextStyleFn{TextColorVec(syntax.String)}
	case document.PresentationCodeNumber:
		return []TextStyleFn{TextColorVec(syntax.Number)}
	case document.PresentationCodeType:
		return []TextStyleFn{TextColorVec(syntax.Type)}
	case document.PresentationCodeFunction, document.PresentationCodeMethod:
		return []TextStyleFn{TextColorVec(syntax.Function)}
	case document.PresentationCodeVariable,
		document.PresentationCodeConstant, document.PresentationCodeProperty,
		document.PresentationCodeOperator, document.PresentationCodePunctuation,
		document.PresentationCodeBuiltin, document.PresentationCodeParameter,
		document.PresentationCodeTag, document.PresentationCodeAttribute:
		return nil
	default:
		return nil
	}
}

// MarkdownPresentationSpanStyle is the richer Markdown presentation hook.
// Heading hierarchy changes only Markdown's visual scale; source ranges and
// editor metrics remain owned by the existing visible-row path.
func MarkdownPresentationSpanStyle(span document.PresentationSpan, base TextStyleAttrs) []TextStyleFn {
	if span.Kind != document.PresentationHeading {
		return MarkdownPresentationStyle(span.Kind, base)
	}
	size := base.FontSize
	if size <= 0 {
		size = DefaultTextStyle().FontSize
	}
	switch span.Level {
	case 1:
		size *= 1.35
	case 2:
		size *= 1.20
	case 3:
		size *= 1.10
	default:
		size *= 1.03
	}
	return []TextStyleFn{FontSize(size), FontWeight(WeightBold)}
}
