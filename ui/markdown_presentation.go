package ui

import (
	"scratchpad/document"

	. "go.hasen.dev/shirei"
)

// MarkdownPresentationStyle is the UI-owned mapping from semantic source
// spans to Shirei text modifiers. Markdown keeps its prose base style; code
// fragments opt into the same preferred programming face as code documents.
func MarkdownPresentationStyle(kind document.PresentationKind, _ TextStyleAttrs) []TextStyleFn {
	theme := DefaultTheme()
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
		return []TextStyleFn{TextColorVec(Vec4{0.38, 0.48, 0.42, 1})}
	case document.PresentationCodeKeyword:
		return []TextStyleFn{TextColorVec(Vec4{0.72, 0.32, 0.62, 1}), FontWeight(WeightBold)}
	case document.PresentationCodeString:
		return []TextStyleFn{TextColorVec(Vec4{0.58, 0.32, 0.16, 1})}
	case document.PresentationCodeNumber:
		return []TextStyleFn{TextColorVec(Vec4{0.22, 0.42, 0.68, 1})}
	case document.PresentationCodeType:
		return []TextStyleFn{TextColorVec(Vec4{0.22, 0.45, 0.58, 1})}
	case document.PresentationCodeFunction, document.PresentationCodeMethod:
		return []TextStyleFn{TextColorVec(Vec4{0.12, 0.38, 0.62, 1})}
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
