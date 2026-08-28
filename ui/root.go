package ui

import (
	. "go.hasen.dev/shirei"
)

// RootView is intentionally a small proof that Scratchpad is a normal Shirei
// application. Product state and the editor are added only after the research
// gates establish their ownership and scale requirements.
func RootView() {
	Container(Attrs(Viewport, Background(220, 12, 96, 1), Pad(28), Gap(18)), func() {
		Label("Scratchpad", FontWeight(WeightBold), FontSize(30))
		Label("One continuous writing surface for notes, prose, tasks, and code.", FontSize(16))

		Container(Attrs(Pad(16), Gap(8), Background(220, 12, 91, 1), Corners(10)), func() {
			Label("Research scaffold ready", FontWeight(WeightBold), FontSize(15))
			Label("The first implementation gate is a measured editor-scale experiment.", FontSize(13))
			Label("Plain text is a complete starting point; language services remain replaceable.", FontSize(13))
		})

		Label("Filesystem-first. Local-only. No sync service or proprietary note database.", FontSize(13), TextColor(220, 12, 35, 1))
	})
}
