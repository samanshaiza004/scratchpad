package ui

import (
	"scratchpad/document"
	"scratchpad/language"

	. "go.hasen.dev/shirei"
)

const preferredCodeFontFamily = "CommitMono"

// codeFontFallbackFamilies is ordered from the preferred programming face to
// broad named monospace families. Shirei then applies its script-aware system
// fallback for glyphs absent from every named face, preserving Unicode and bidi
// shaping without inventing replacement glyphs.
var codeFontFallbackFamilies = []string{
	preferredCodeFontFamily,
	"OCR-B",
	"Noto Sans Mono",
	"SF Mono",
	"Menlo",
	"Monaco",
	"Cascadia Mono",
	"Consolas",
	"Liberation Mono",
	"DejaVu Sans Mono",
}

func isCodeLanguage(id language.ID) bool {
	switch id {
	case language.Go, language.Rust, language.JavaScript, language.TypeScript,
		language.Python, language.Shell, language.JSON, language.YAML:
		return true
	default:
		return false
	}
}

func codeFontFamilies() []string {
	return append([]string(nil), codeFontFallbackFamilies...)
}

// EditorTextStyle is a presentation policy only. It keeps one document,
// ScratchEditor, and Buffer while giving recognized code/data roots a dense
// preferred face and retaining the existing prose style for Markdown/plain
// text and unknown roots.
func EditorTextStyle(rootLanguage language.ID) TextStyleAttrs {
	style := DefaultTextStyle()
	if isCodeLanguage(rootLanguage) {
		style.FontFamilies = codeFontFamilies()
	}
	return style
}

func isDefaultEditorStyle(style TextStyleAttrs) bool {
	defaultStyle := DefaultTextStyle()
	return style.FontSize == defaultStyle.FontSize &&
		style.FontAspect == defaultStyle.FontAspect &&
		style.TextColor == defaultStyle.TextColor &&
		style.Background == defaultStyle.Background &&
		style.Underline == defaultStyle.Underline &&
		style.Strike == defaultStyle.Strike &&
		len(style.FontFamilies) == 0
}

func EditorTextStyleForDocument(doc *document.Document) TextStyleAttrs {
	if doc == nil {
		return DefaultTextStyle()
	}
	return EditorTextStyle(language.ID(doc.RootLanguage))
}
