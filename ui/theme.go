package ui

import . "go.hasen.dev/shirei"

// Theme is the small semantic palette for the Scratchpad shell. Keeping the
// roles here makes the editor surface and the application chrome coherent
// without making Shirei's default widget appearance part of the product API.
type Theme struct {
	Window    Vec4
	Chrome    Vec4
	Raised    Vec4
	Paper     Vec4
	Sidebar   Vec4
	Inset     Vec4
	Ink       Vec4
	Muted     Vec4
	Border    Vec4
	Highlight Vec4
	Selection Vec4
	Focus     Vec4
	Warning   Vec4
}

func DefaultTheme() Theme {
	return Theme{
		Window:    Vec4{90, 3, 72, 1},
		Chrome:    Vec4{60, 5, 77, 1},
		Raised:    Vec4{60, 7, 81, 1},
		Paper:     Vec4{48, 13, 81, 1},
		Sidebar:   Vec4{60, 5, 77, 1},
		Inset:     Vec4{90, 3, 71, 1},
		Ink:       Vec4{210, 8, 15, 1},
		Muted:     Vec4{204, 4, 35, 1},
		Border:    Vec4{197, 3, 45, 1},
		Highlight: Vec4{51, 20, 92, 1},
		Selection: Vec4{213, 31, 50, 1},
		Focus:     Vec4{213, 42, 44, 1},
		Warning:   Vec4{35, 51, 54, 1},
	}
}
