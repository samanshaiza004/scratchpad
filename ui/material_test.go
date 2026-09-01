package ui

import (
	"testing"

	. "go.hasen.dev/shirei"
	. "go.hasen.dev/shirei/widgets"
)

func TestRaisedFrameUsesDirectionalEdgesAndGradient(t *testing.T) {
	theme := DefaultTheme()
	scope := new(int)
	var outer, face ContainerId
	GetHost().HeadlessRender = true
	GetHost().WindowSize = Vec2{240, 100}
	RunFrameFn(func() {
		ContainerWithKey(scope, Attrs(Viewport), func() {
			outer = RaisedFrame(theme, Attrs(FixSize(180, 44)), Attrs(Row, Pad2(4, 8)), func() {
				face = CurrentId()
				Label("Raised")
			})
		})
	})

	outerData := GetRenderDataOf(outer)
	if outerData.Background != theme.DarkShadow {
		t.Fatalf("outer background = %v, want dark shadow %v", outerData.Background, theme.DarkShadow)
	}
	if outerData.Padding != (Vec4{0, 1, 1, 0}) {
		t.Fatalf("outer padding = %v, want bottom/right edge", outerData.Padding)
	}
	faceData := GetRenderDataOf(face)
	if faceData.Background != theme.ChromeRaised || faceData.Gradient[2] >= 0 {
		t.Fatalf("raised face background/gradient = %v/%v", faceData.Background, faceData.Gradient)
	}
}

func TestInsetFrameReversesDirectionalEdges(t *testing.T) {
	theme := DefaultTheme()
	scope := new(int)
	var outer, well ContainerId
	GetHost().HeadlessRender = true
	GetHost().WindowSize = Vec2{240, 100}
	RunFrameFn(func() {
		ContainerWithKey(scope, Attrs(Viewport), func() {
			outer = InsetFrame(theme, Attrs(FixSize(180, 44)), Attrs(Row, Pad2(4, 8)), func() {
				well = CurrentId()
				Label("Inset")
			})
		})
	})

	outerData := GetRenderDataOf(outer)
	if outerData.Background != theme.Light {
		t.Fatalf("outer background = %v, want light edge %v", outerData.Background, theme.Light)
	}
	if outerData.Padding != (Vec4{0, 1, 1, 0}) {
		t.Fatalf("outer padding = %v, want bottom/right edge", outerData.Padding)
	}
	if got := GetRenderDataOf(well).Background; got != theme.ChromeInset {
		t.Fatalf("well background = %v, want %v", got, theme.ChromeInset)
	}
}

func TestThemeSeparatesMachineryFromPaper(t *testing.T) {
	theme := DefaultTheme()
	if theme.Paper == theme.Chrome || theme.Paper == theme.Sidebar {
		t.Fatal("paper must remain materially distinct from machinery")
	}
	if theme.Selection == theme.Focus {
		t.Fatal("selection and focus must have separate semantic roles")
	}
	if theme.Light[2] <= theme.ChromeRaised[2] || theme.DarkShadow[2] >= theme.Shadow[2] {
		t.Fatalf("edge lightness order is inconsistent: light=%v raised=%v shadow=%v dark=%v", theme.Light, theme.ChromeRaised, theme.Shadow, theme.DarkShadow)
	}
}

func TestWorkstationSegmentedControlSwitchesSelection(t *testing.T) {
	theme := DefaultTheme()
	scope := new(int)
	selected := SidebarFiles
	cellIDs := make(map[SidebarMode]ContainerId)
	GetHost().HeadlessRender = true
	GetHost().WindowFocused = true
	GetHost().WindowSize = Vec2{240, 80}
	ResetInputSession()
	frame := func() {
		RunFrameFn(func() {
			ContainerWithKey(scope, Attrs(Viewport), func() {
				workstationSegmentedControl(theme, &selected, cellIDs, Cell("Files", SidebarFiles), Cell("Outline", SidebarOutline))
			})
		})
	}
	frame()
	frame()
	rect := GetResolvedRectOf(cellIDs[SidebarOutline])
	GetInputState().MousePoint = Vec2{rect.Origin[0] + rect.Size[0]/2, rect.Origin[1] + rect.Size[1]/2}
	GetInputState().MouseButton = MousePrimary
	GetFrameInput().Mouse = MouseClick
	frame()
	GetFrameInput().Mouse = MouseRelease
	frame()
	if selected != SidebarOutline {
		t.Fatalf("selected = %v, want Outline", selected)
	}
}

func TestWorkstationButtonClickBehavior(t *testing.T) {
	theme := DefaultTheme()
	scope := new(int)
	clicked := false
	var buttonID ContainerId
	GetHost().HeadlessRender = true
	GetHost().WindowFocused = true
	GetHost().WindowSize = Vec2{240, 80}
	ResetInputSession()
	frame := func() {
		RunFrameFn(func() {
			ContainerWithKey(scope, Attrs(Viewport), func() {
				pressed, id := workstationButton(theme, "Open", true, workstationButtonCommand)
				clicked = pressed || clicked
				buttonID = id
			})
		})
	}
	frame()
	frame()
	rect := GetResolvedRectOf(buttonID)
	GetInputState().MousePoint = Vec2{rect.Origin[0] + rect.Size[0]/2, rect.Origin[1] + rect.Size[1]/2}
	GetInputState().MouseButton = MousePrimary
	GetFrameInput().Mouse = MouseClick
	frame()
	GetFrameInput().Mouse = MouseRelease
	frame()
	if !clicked {
		t.Fatal("workstation button did not preserve Shirei click behavior")
	}
}
