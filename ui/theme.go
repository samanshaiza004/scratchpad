package ui

import . "go.hasen.dev/shirei"

// Theme is Scratchpad's compact material palette. Machinery uses the chrome,
// edge, selection, and focus roles; document content uses Paper and Ink. The
// palette intentionally belongs to the product rather than pretending to be a
// general Shirei theming layer.
type Theme struct {
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
}

func DefaultTheme() Theme {
	return Theme{
		// Aero Paper palette: cool silver-blue machinery around a warm ivory
		// writing surface. Values are HSLA, as required by Shirei.
		Window:       Vec4{195, 5, 81, 1},
		Chrome:       Vec4{210, 5, 85, 1},
		ChromeRaised: Vec4{180, 5, 90, 1},
		ChromeInset:  Vec4{200, 6, 80, 1},
		Paper:        Vec4{48, 21, 91, 1},
		Sidebar:      Vec4{150, 5, 88, 1},
		Popup:        Vec4{48, 13, 94, 1},

		Ink:   Vec4{200, 8, 15, 1},
		Muted: Vec4{198, 6, 37, 1},

		Light:      Vec4{150, 8, 97, 1},
		Highlight:  Vec4{198, 12, 93, 1},
		Shadow:     Vec4{202, 6, 52, 1},
		DarkShadow: Vec4{202, 7, 44, 1},
		Border:     Vec4{197, 5, 64, 1},

		Selection:          Vec4{206, 44, 69, 1},
		SelectionHighlight: Vec4{205, 40, 80, 1},
		SelectionShadow:    Vec4{207, 31, 54, 1},

		Focus:       Vec4{208, 38, 50, 1},
		Warning:     Vec4{37, 46, 53, 1},
		WarningWell: Vec4{40, 27, 82, 1},
	}
}
