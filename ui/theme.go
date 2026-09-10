package ui

import (
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	. "go.hasen.dev/shirei"
)

type ThemeID string

const (
	ThemeScratchpadLight ThemeID = "scratchpad-light"
	ThemeScratchpadDark  ThemeID = "scratchpad-dark"
)

type Appearance string

const (
	AppearanceLight Appearance = "light"
	AppearanceDark  Appearance = "dark"
)

// Theme is the complete runtime palette. Values are Shirei HSLA; user-facing
// theme files use hex colors and are converted at the boundary in
// ResolveThemeSpec. Generation versions paint-only caches when a theme is
// changed without changing document bytes.
type Theme struct {
	ID         ThemeID
	Appearance Appearance
	Generation uint64

	Window       Vec4
	Chrome       Vec4
	ChromeRaised Vec4
	ChromeInset  Vec4
	Paper        Vec4
	Sidebar      Vec4
	Popup        Vec4

	Ink   Vec4
	Muted Vec4

	Light      Vec4
	Highlight  Vec4
	Shadow     Vec4
	DarkShadow Vec4
	Border     Vec4

	Selection          Vec4
	SelectionHighlight Vec4
	SelectionShadow    Vec4

	Focus       Vec4
	Warning     Vec4
	WarningWell Vec4
	Syntax      SyntaxTheme
}

// ThemeSpec is the small, versioned, human-editable theme format. Layout and
// widget metrics intentionally do not belong here: Scratchpad owns its
// material grammar while a spec supplies semantic colors.
type ThemeSpec struct {
	SchemaVersion int               `json:"schema_version"`
	Name          string            `json:"name"`
	ID            string            `json:"id,omitempty"`
	Appearance    Appearance        `json:"appearance"`
	Extends       string            `json:"extends,omitempty"`
	Colors        map[string]string `json:"colors"`
	Syntax        map[string]string `json:"syntax"`
}

// ParseThemeSpec decodes the versioned, hex-based theme boundary. Resolution
// is deliberately separate so callers can validate a file before supplying a
// lookup function for its optional inheritance chain.
func ParseThemeSpec(data []byte) (ThemeSpec, error) {
	var spec ThemeSpec
	if err := json.Unmarshal(data, &spec); err != nil {
		return ThemeSpec{}, err
	}
	if spec.SchemaVersion == 0 {
		spec.SchemaVersion = 1
	}
	if spec.Name == "" && spec.ID == "" {
		return ThemeSpec{}, errors.New("theme must provide a name or id")
	}
	return spec, nil
}

var activeRuntimeTheme = ScratchpadLightTheme()

// normalizeTheme makes the zero value useful for compatibility callers while
// keeping rendering code independent from the built-in theme constructor.
func normalizeTheme(theme Theme) Theme {
	if theme.ID == "" {
		return ScratchpadLightTheme()
	}
	return theme
}

func activeTheme() Theme { return activeRuntimeTheme }

// configureActiveTheme updates framework-global paint hooks that cannot carry
// a Theme argument (for example Shirei's selection color). The application
// invokes this once per frame after loading the persisted selection.
func configureActiveTheme(theme Theme) {
	theme = normalizeTheme(theme)
	activeRuntimeTheme = theme
	selection := theme.Selection
	selection[3] = 0.58
	SelectionColor = selection
}

func ScratchpadLightTheme() Theme {
	theme, err := ResolveThemeSpec(lightThemeSpec(), nil)
	if err != nil {
		panic(err)
	}
	theme.Generation = 1
	return theme
}

func ScratchpadDarkTheme() Theme {
	theme, err := ResolveThemeSpec(darkThemeSpec(), nil)
	if err != nil {
		panic(err)
	}
	theme.Generation = 2
	return theme
}

// DefaultTheme remains the compatibility constructor for tests and callers
// that need a built-in palette. Rendering code should resolve the selected
// theme once at the root and pass it down instead.
func DefaultTheme() Theme { return ScratchpadLightTheme() }

func ThemeForID(id ThemeID) Theme {
	switch id {
	case ThemeScratchpadDark:
		return ScratchpadDarkTheme()
	case ThemeScratchpadLight, "":
		return ScratchpadLightTheme()
	default:
		return ScratchpadLightTheme()
	}
}

func isKnownThemeID(id ThemeID) bool {
	return id == ThemeScratchpadLight || id == ThemeScratchpadDark
}

func resolveWorkbenchTheme(shell *workbenchState) Theme {
	if shell == nil {
		return ScratchpadLightTheme()
	}
	if !isKnownThemeID(shell.ThemeID) {
		shell.ThemeID = ThemeScratchpadLight
	}
	theme := ThemeForID(shell.ThemeID)
	if shell.ThemeGeneration == 0 {
		shell.ThemeGeneration = theme.Generation
	}
	theme.Generation = shell.ThemeGeneration
	return theme
}

func ThemeIDs() []ThemeID {
	return []ThemeID{ThemeScratchpadLight, ThemeScratchpadDark}
}

func themeDisplayName(id ThemeID) string {
	switch id {
	case ThemeScratchpadDark:
		return "Scratchpad Dark"
	case ThemeScratchpadLight:
		return "Scratchpad Light"
	default:
		return string(id)
	}
}

// ResolveThemeSpec resolves one spec and its optional inheritance chain. The
// lookup callback is intentionally tiny so a future themes-directory loader
// can own discovery without making that package part of the rendering model.
func ResolveThemeSpec(spec ThemeSpec, lookup func(string) (ThemeSpec, bool)) (Theme, error) {
	return resolveThemeSpec(spec, lookup, make(map[string]bool))
}

func resolveThemeSpec(spec ThemeSpec, lookup func(string) (ThemeSpec, bool), resolving map[string]bool) (Theme, error) {
	if spec.SchemaVersion == 0 {
		spec.SchemaVersion = 1
	}
	if spec.SchemaVersion != 1 {
		return Theme{}, fmt.Errorf("unsupported theme schema version %d", spec.SchemaVersion)
	}
	var base Theme
	if spec.Extends != "" {
		if lookup == nil {
			return Theme{}, fmt.Errorf("theme %q extends %q but no theme lookup is available", spec.Name, spec.Extends)
		}
		parent, ok := lookup(spec.Extends)
		if !ok {
			return Theme{}, fmt.Errorf("theme %q extends unknown theme %q", spec.Name, spec.Extends)
		}
		if resolving[spec.Extends] {
			return Theme{}, fmt.Errorf("theme %q has cyclic inheritance through %q", spec.Name, spec.Extends)
		}
		resolving[spec.Extends] = true
		resolved, err := resolveThemeSpec(parent, lookup, resolving)
		delete(resolving, spec.Extends)
		if err != nil {
			return Theme{}, err
		}
		base = resolved
	}
	if spec.ID != "" {
		base.ID = ThemeID(spec.ID)
	} else if spec.Name != "" {
		base.ID = ThemeID(strings.ToLower(strings.ReplaceAll(spec.Name, " ", "-")))
	}
	if spec.Appearance != "" {
		if spec.Appearance != AppearanceLight && spec.Appearance != AppearanceDark {
			return Theme{}, fmt.Errorf("theme %q has invalid appearance %q", spec.Name, spec.Appearance)
		}
		base.Appearance = spec.Appearance
	} else if base.Appearance == "" {
		base.Appearance = AppearanceLight
	}
	if err := applyThemeColors(&base, spec.Colors, false); err != nil {
		return Theme{}, err
	}
	if err := applyThemeColors(&base, spec.Syntax, true); err != nil {
		return Theme{}, err
	}
	return base, nil
}

func applyThemeColors(theme *Theme, values map[string]string, syntax bool) error {
	for name, value := range values {
		color, err := parseThemeHex(value)
		if err != nil {
			return fmt.Errorf("theme color %q: %w", name, err)
		}
		if syntax {
			switch name {
			case "comment":
				theme.Syntax.Comment = color
			case "keyword":
				theme.Syntax.Keyword = color
			case "string":
				theme.Syntax.String = color
			case "number":
				theme.Syntax.Number = color
			case "type":
				theme.Syntax.Type = color
			case "function":
				theme.Syntax.Function = color
			default:
				return fmt.Errorf("unknown syntax color %q", name)
			}
			continue
		}
		switch name {
		case "window":
			theme.Window = color
		case "chrome":
			theme.Chrome = color
		case "chrome_raised":
			theme.ChromeRaised = color
		case "chrome_inset":
			theme.ChromeInset = color
		case "paper":
			theme.Paper = color
		case "sidebar":
			theme.Sidebar = color
		case "popup":
			theme.Popup = color
		case "ink":
			theme.Ink = color
		case "muted":
			theme.Muted = color
		case "light":
			theme.Light = color
		case "highlight":
			theme.Highlight = color
		case "shadow":
			theme.Shadow = color
		case "dark_shadow":
			theme.DarkShadow = color
		case "border":
			theme.Border = color
		case "selection":
			theme.Selection = color
		case "selection_highlight":
			theme.SelectionHighlight = color
		case "selection_shadow":
			theme.SelectionShadow = color
		case "focus":
			theme.Focus = color
		case "warning":
			theme.Warning = color
		case "warning_well":
			theme.WarningWell = color
		default:
			return fmt.Errorf("unknown theme color %q", name)
		}
	}
	return nil
}

func parseThemeHex(value string) (Vec4, error) {
	value = strings.TrimPrefix(strings.TrimSpace(value), "#")
	if len(value) != 3 && len(value) != 4 && len(value) != 6 && len(value) != 8 {
		return Vec4{}, errors.New("want #RGB, #RGBA, #RRGGBB, or #RRGGBBAA")
	}
	if len(value) == 3 || len(value) == 4 {
		expanded := make([]byte, 0, len(value)*2)
		for _, digit := range []byte(value) {
			expanded = append(expanded, digit, digit)
		}
		value = string(expanded)
	}
	decoded, err := hex.DecodeString(value)
	if err != nil {
		return Vec4{}, errors.New("contains non-hex digits")
	}
	alpha := byte(255)
	if len(decoded) == 4 {
		alpha = decoded[3]
	}
	return rgbToHSLA(decoded[0], decoded[1], decoded[2], alpha), nil
}

func rgbToHSLA(red, green, blue, alpha byte) Vec4 {
	r := float32(red) / 255
	g := float32(green) / 255
	b := float32(blue) / 255
	max, min := r, r
	if g > max {
		max = g
	}
	if b > max {
		max = b
	}
	if g < min {
		min = g
	}
	if b < min {
		min = b
	}
	l := (max + min) / 2
	var h, s float32
	if max != min {
		delta := max - min
		if l > 0.5 {
			s = delta / (2 - max - min)
		} else {
			s = delta / (max + min)
		}
		switch max {
		case r:
			h = (g - b) / delta
			if g < b {
				h += 6
			}
		case g:
			h = (b-r)/delta + 2
		case b:
			h = (r-g)/delta + 4
		}
		h /= 6
	}
	return Vec4{h * 360, s * 100, l * 100, float32(alpha) / 255}
}

func lightThemeSpec() ThemeSpec {
	return ThemeSpec{
		SchemaVersion: 1,
		Name:          "Scratchpad Light",
		ID:            string(ThemeScratchpadLight),
		Appearance:    AppearanceLight,
		Colors: map[string]string{
			"window": "#D2D8DB", "chrome": "#D9DEE0", "chrome_raised": "#E5E8E9", "chrome_inset": "#C0C9CD",
			"paper": "#F0EEE8", "sidebar": "#D7DCDE", "popup": "#F5F3EF", "ink": "#25282A", "muted": "#646B6D",
			"light": "#F8F9F9", "highlight": "#E4E8E9", "shadow": "#8B979C", "dark_shadow": "#76858B", "border": "#AAB5BA",
			"selection": "#6B99BA", "selection_highlight": "#97B5CA", "selection_shadow": "#4D738F", "focus": "#527A99",
			"warning": "#AD7B38", "warning_well": "#DBCAA9",
		},
		Syntax: map[string]string{
			"comment": "#718278", "keyword": "#8E5B82", "string": "#A66C28", "number": "#586DB0", "type": "#2D8B88", "function": "#387CA6",
		},
	}
}

func darkThemeSpec() ThemeSpec {
	return ThemeSpec{
		SchemaVersion: 1,
		Name:          "Scratchpad Dark",
		ID:            string(ThemeScratchpadDark),
		Appearance:    AppearanceDark,
		Colors: map[string]string{
			"paper": "#2C2A24", "window": "#22282B", "chrome": "#2A3034", "chrome_raised": "#353C40", "chrome_inset": "#202629",
			"sidebar": "#2D3335", "popup": "#323639", "ink": "#E7E2D8", "muted": "#A7A49B", "light": "#50595D",
			"highlight": "#394246", "border": "#566066", "shadow": "#171C1F", "dark_shadow": "#101416",
			"selection": "#4E7696", "selection_highlight": "#6589A5", "selection_shadow": "#34536B", "focus": "#76A6CA",
			"warning": "#C59A5B", "warning_well": "#4B3E29",
		},
		Syntax: map[string]string{
			"comment": "#879486", "keyword": "#C18CA4", "string": "#A9B37A", "number": "#9B98C6", "type": "#76AAA8", "function": "#7EA7BD",
		},
	}
}
