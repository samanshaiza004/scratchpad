package ui

import (
	"testing"

	. "go.hasen.dev/shirei"
	. "go.hasen.dev/shirei/widgets"
)

func TestShireiDropdownAnchorRepro(t *testing.T) {
	scope := new(int)
	var triggerID, menuID ContainerId
	view := func() {
		ContainerWithKey(scope, Attrs(Viewport, FixSize(500, 300)), func() {
			Container(Attrs(Row, FixHeight(34), Pad2(0, 8)), func() {
				CtrlMenuButton(NoIcon, "File", func() {
					ContainerWithKey("repro-menu-item", Attrs(), func() {
						menuID = CurrentId()
						MenuItem(NoIcon, "Open")
					})
				})
				triggerID = GetLastId()
			})
		})
	}
	ResetInputSession()
	GetHost().HeadlessRender = true
	GetHost().WindowFocused = true
	GetHost().WindowSize = Vec2{500, 300}
	GetInputState().MousePoint = Vec2{-1000, -1000}
	GetFrameInput().Mouse = 0
	RunFrameFn(view)
	RunFrameFn(view)
	trigger := GetResolvedRectOf(triggerID)
	GetInputState().MousePoint = Vec2{trigger.Origin[0] + 8, trigger.Origin[1] + 12}
	GetInputState().MouseButton = MousePrimary
	GetFrameInput().Mouse = 0
	RunFrameFn(view)
	GetFrameInput().Mouse = MouseClick
	RunFrameFn(view)
	GetFrameInput().Mouse = MouseRelease
	RunFrameFn(view)
	if menuID == nil {
		t.Fatal("menu did not render after trigger click")
	}
	menu := GetResolvedRectOf(menuID)
	// CtrlMenuButton anchors its outer popup four pixels below the trigger;
	// the marker is six pixels inside that popup's top padding.
	wantY := trigger.Origin[1] + trigger.Size[1] + 4 + 6
	if menu.Origin[1] != wantY {
		t.Fatalf("trigger=%v menu=%v expected-marker-y=%v", trigger, menu, wantY)
	}
}
