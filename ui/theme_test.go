package ui

import (
	"testing"

	"scratchpad/document"
	"scratchpad/language"

	. "go.hasen.dev/shirei"
)

func TestBuiltInThemesHaveDistinctSemanticPalettes(t *testing.T) {
	light := ScratchpadLightTheme()
	dark := ScratchpadDarkTheme()
	if light.ID != ThemeScratchpadLight || light.Appearance != AppearanceLight {
		t.Fatalf("light identity = %q/%q", light.ID, light.Appearance)
	}
	if dark.ID != ThemeScratchpadDark || dark.Appearance != AppearanceDark {
		t.Fatalf("dark identity = %q/%q", dark.ID, dark.Appearance)
	}
	if light.Paper == light.Chrome || dark.Paper == dark.Chrome {
		t.Fatal("paper and machinery must remain distinct in both themes")
	}
	if dark.Ink[2] <= dark.Paper[2] {
		t.Fatalf("dark ink lightness = %v, paper lightness = %v; ink should read on dark paper", dark.Ink[2], dark.Paper[2])
	}
	if dark.Syntax.Comment == light.Syntax.Comment || dark.Syntax.Keyword == light.Syntax.Keyword {
		t.Fatal("dark theme must provide its own syntax palette")
	}
}

func TestConfigureActiveThemeRefreshesFrameworkSelection(t *testing.T) {
	configureActiveTheme(ScratchpadDarkTheme())
	want := ScratchpadDarkTheme().Selection
	want[3] = 0.58
	if SelectionColor != want {
		t.Fatalf("selection color = %v, want %v", SelectionColor, want)
	}
	configureActiveTheme(ScratchpadLightTheme())
}

func TestThemeReachesEditorAndPresentationStyles(t *testing.T) {
	dark := ScratchpadDarkTheme()
	style := EditorTextStyleWithTheme(language.TypeScript, dark)
	if style.TextColor != dark.Ink {
		t.Fatalf("editor text color = %v, want %v", style.TextColor, dark.Ink)
	}
	mods := MarkdownPresentationStyleForTheme(dark)(document.PresentationLink, style)
	styled := TextStyleWith(style, mods...)
	if styled.TextColor != dark.Focus {
		t.Fatalf("link color = %v, want %v", styled.TextColor, dark.Focus)
	}
}

func TestResolveThemeSpecInheritsAndOverrides(t *testing.T) {
	base := darkThemeSpec()
	child := ThemeSpec{
		SchemaVersion: 1,
		Name:          "Test Child",
		ID:            "test-child",
		Extends:       base.ID,
		Colors:        map[string]string{"paper": "#123456"},
		Syntax:        map[string]string{"keyword": "#ABCDEF"},
	}
	resolved, err := ResolveThemeSpec(child, func(id string) (ThemeSpec, bool) {
		if id == base.ID {
			return base, true
		}
		return ThemeSpec{}, false
	})
	if err != nil {
		t.Fatal(err)
	}
	if resolved.ID != ThemeID(child.ID) || resolved.Appearance != AppearanceDark {
		t.Fatalf("resolved identity = %q/%q", resolved.ID, resolved.Appearance)
	}
	if resolved.Paper == ScratchpadDarkTheme().Paper || resolved.Chrome != ScratchpadDarkTheme().Chrome {
		t.Fatal("child should override paper while inheriting chrome")
	}
	if resolved.Syntax.Keyword == ScratchpadDarkTheme().Syntax.Keyword || resolved.Syntax.Comment != ScratchpadDarkTheme().Syntax.Comment {
		t.Fatal("child should override keyword while inheriting comment")
	}
}

func TestResolveThemeSpecRejectsInvalidInput(t *testing.T) {
	if _, err := ResolveThemeSpec(ThemeSpec{SchemaVersion: 2}, nil); err == nil {
		t.Fatal("unsupported schema version was accepted")
	}
	if _, err := ResolveThemeSpec(ThemeSpec{SchemaVersion: 1, Colors: map[string]string{"unknown": "#000000"}}, nil); err == nil {
		t.Fatal("unknown semantic color was accepted")
	}
	cycle := func(id string) (ThemeSpec, bool) {
		return ThemeSpec{SchemaVersion: 1, Name: id, ID: id, Extends: map[string]string{"a": "b", "b": "a"}[id]}, true
	}
	if _, err := ResolveThemeSpec(ThemeSpec{SchemaVersion: 1, ID: "a", Extends: "b"}, cycle); err == nil {
		t.Fatal("cyclic theme inheritance was accepted")
	}
}

func TestParseThemeHex(t *testing.T) {
	color, err := parseThemeHex("#0f8c")
	if err != nil {
		t.Fatal(err)
	}
	if color[3] < 0.79 || color[3] > 0.81 {
		t.Fatalf("alpha = %v, want approximately 0.8", color[3])
	}
	if _, err := parseThemeHex("#xyz"); err == nil {
		t.Fatal("invalid hex color was accepted")
	}
}

func TestParseThemeSpec(t *testing.T) {
	spec, err := ParseThemeSpec([]byte(`{"name":"Example","appearance":"dark","colors":{"paper":"#123456"}}`))
	if err != nil {
		t.Fatal(err)
	}
	if spec.SchemaVersion != 1 || spec.Name != "Example" || spec.Colors["paper"] != "#123456" {
		t.Fatalf("parsed spec = %#v", spec)
	}
	if _, err := ParseThemeSpec([]byte(`{"appearance":"dark"}`)); err == nil {
		t.Fatal("unnamed theme was accepted")
	}
}
