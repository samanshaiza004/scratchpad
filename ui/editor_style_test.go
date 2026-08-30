package ui

import (
	"slices"
	"testing"
	"unicode/utf8"

	"scratchpad/language"

	. "go.hasen.dev/shirei"
)

func TestEditorTextStyleLanguagePolicy(t *testing.T) {
	for _, id := range []language.ID{
		language.Go,
		language.TypeScript,
		language.Rust,
		language.JSON,
		language.YAML,
	} {
		style := EditorTextStyle(id)
		if !isCodeLanguage(id) {
			t.Fatalf("%q was not classified as code", id)
		}
		if len(style.FontFamilies) == 0 || style.FontFamilies[0] != preferredCodeFontFamily {
			t.Fatalf("%q font families = %v, want %q first", id, style.FontFamilies, preferredCodeFontFamily)
		}
		if !slices.Contains(style.FontFamilies, "OCR-B") {
			t.Fatalf("%q fallback families = %v, want OCR-B", id, style.FontFamilies)
		}
	}
}

func TestEditorTextStyleKeepsProseDefault(t *testing.T) {
	prose := EditorTextStyle(language.Markdown)
	plain := EditorTextStyle(language.PlainText)
	unknown := EditorTextStyle(language.ID("future-unknown"))
	for _, style := range []struct {
		name string
		got  []string
	}{
		{"markdown", prose.FontFamilies},
		{"plain text", plain.FontFamilies},
		{"unknown", unknown.FontFamilies},
	} {
		if len(style.got) != 0 {
			t.Fatalf("%s font families = %v, want default prose families", style.name, style.got)
		}
	}
}

func TestCodeFontFamilyPolicyIsCopied(t *testing.T) {
	a := codeFontFamilies()
	a[0] = "changed"
	b := codeFontFamilies()
	if b[0] != preferredCodeFontFamily {
		t.Fatalf("code font policy was mutated through returned slice: %v", b)
	}
	if len(b) < 2 {
		t.Fatal("code font policy needs a fallback chain")
	}
}

func TestCodeStyleShapesRepresentativeUnicode(t *testing.T) {
	const material = "0 O o 1 l I | {} [] () <> <= >= => -> != == === \" ' ` _ - + * / \\ | @ # $ % ^ &\n" +
		"café naïve 日本語 العربية עברית 👩‍💻 e\u0301"
	shaped := ShapeText(material, EditorTextStyle(language.TypeScript))
	if len(shaped.Lines) == 0 {
		t.Skip("Shirei has no usable font in this headless unit-test context")
	}
	if len(shaped.Runes) != utf8.RuneCountInString(material) {
		t.Fatalf("shaped rune count = %d, want %d", len(shaped.Runes), utf8.RuneCountInString(material))
	}
	var glyphs int
	for _, line := range shaped.Lines {
		for _, segment := range line.Segments {
			glyphs += len(segment.Glyphs)
		}
	}
	if glyphs == 0 {
		t.Fatal("representative code/unicode material produced no glyphs")
	}
}
