package ui

import (
	"testing"

	"scratchpad/application"
	"scratchpad/document"

	. "go.hasen.dev/shirei"
)

func TestOutlineSymbolKindLabels(t *testing.T) {
	cases := map[string]string{
		"function":  "ƒ function",
		"method":    "ƒ method",
		"struct":    "◇ struct",
		"interface": "◇ interface",
		"variable":  "· variable",
		"constant":  "· constant",
		"field":     "field",
		"":          "symbol",
	}
	for kind, want := range cases {
		if got := outlineSymbolKind(kind); got != want {
			t.Errorf("outlineSymbolKind(%q) = %q, want %q", kind, got, want)
		}
	}
}

func TestOutlinePanelRendersCodeSymbols(t *testing.T) {
	ResetInputSession()
	t.Cleanup(ResetInputSession)
	GetHost().HeadlessRender = true
	GetHost().WindowSize = Vec2{420, 260}
	state := application.New(nil)
	doc := document.New("main.go", []byte("package main\nfunc main() {}\n"), "go")
	projection := document.Projections{
		Revision: doc.Revision(),
		Code:     document.NewCodeProjection(doc.Revision(), "go", nil, []document.Symbol{{Name: "main", Kind: "function", StartByte: 13, EndByte: 27}}, nil),
	}
	if !doc.SetDerived(nil, projection) {
		t.Fatal("failed to install code projection")
	}
	state.Documents["main.go"] = doc
	state.Order = []application.DocumentID{"main.go"}
	state.Active = "main.go"
	shell := &workbenchState{SidebarMode: SidebarOutline}
	scope := new(int)
	RunFrameFn(func() {
		ContainerWithKey(scope, Attrs(Viewport, FixSize(420, 260)), func() {
			outlinePanel(state, shell, DefaultTheme())
		})
	})
}
