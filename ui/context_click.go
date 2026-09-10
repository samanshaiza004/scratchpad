package ui

import . "go.hasen.dev/shirei"

// contextMenuButton recognizes the native secondary button and macOS's
// Control-primary-click convention. Command-click remains a primary gesture.
func contextMenuButton() bool {
	input := GetInputState()
	return input.MouseButton == MouseSecondary ||
		(input.MouseButton == MousePrimary && PrimaryMod() == ModCmd && input.Modifiers&ModCtrl != 0)
}

// contextMenuGesture latches the gesture through release, even if Control is
// released first. Call inside the row/tab that owns the pointer interaction so
// opening a menu cannot also activate, close, expand, or drag that item.
func contextMenuGesture() (pressed, secondary bool) {
	held := Use[bool]("context-menu-gesture")
	action := GetFrameInput().Mouse
	if action == MouseClick {
		*held = IsHovered() && contextMenuButton()
	}
	secondary = *held
	pressed = secondary && action == MouseClick
	if action == MouseRelease {
		*held = false
	}
	return
}
