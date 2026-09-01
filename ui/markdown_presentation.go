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
		return []TextStyleFn{Fonts(codeFontFamilies()...), TextBackgroundVec(Vec4{50, 18, 87, 1})}
	case document.PresentationLink:
		return []TextStyleFn{TextColorVec(theme.Focus), TextUnderline(true)}
	case document.PresentationStrike:
		return []TextStyleFn{TextStrike(true)}
	case document.PresentationCodeBlock:
		return []TextStyleFn{Fonts(codeFontFamilies()...), TextBackgroundVec(Vec4{50, 12, 78, 1})}
	case document.PresentationBlockquote, document.PresentationListMarker, document.PresentationSyntax:
		return []TextStyleFn{TextColorVec(theme.Muted)}
	case document.PresentationTaskMarker:
		return []TextStyleFn{TextColorVec(theme.Focus), FontWeight(WeightBold)}
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
