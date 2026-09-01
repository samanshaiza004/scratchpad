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
		Window:       Vec4{210, 4, 68, 1},
		Chrome:       Vec4{55, 5, 77, 1},
		ChromeRaised: Vec4{55, 7, 82, 1},
		ChromeInset:  Vec4{210, 4, 69, 1},
		Paper:        Vec4{46, 18, 87, 1},
		Sidebar:      Vec4{205, 5, 76, 1},
		Popup:        Vec4{52, 9, 84, 1},

		Ink:   Vec4{210, 10, 14, 1},
		Muted: Vec4{210, 5, 38, 1},

		Light:      Vec4{48, 18, 94, 1},
		Highlight:  Vec4{48, 15, 88, 1},
		Shadow:     Vec4{210, 5, 52, 1},
		DarkShadow: Vec4{210, 8, 34, 1},
		Border:     Vec4{210, 6, 42, 1},

		Selection:          Vec4{211, 28, 62, 1},
		SelectionHighlight: Vec4{210, 34, 73, 1},
		SelectionShadow:    Vec4{212, 31, 45, 1},

		Focus:       Vec4{210, 55, 47, 1},
		Warning:     Vec4{37, 50, 55, 1},
		WarningWell: Vec4{40, 30, 79, 1},
	}
}
