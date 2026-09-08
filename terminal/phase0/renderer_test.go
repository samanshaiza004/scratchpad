package phase0

import (
	"math"
	"testing"

	shirei "go.hasen.dev/shirei"
)

func TestCellOriginUsesOnlyGridCoordinates(t *testing.T) {
	origin := shirei.Vec2{11, 17}
	metrics := GridMetrics{CellWidth: 9.25, CellHeight: 19, FontSize: 14}
	for _, test := range []struct {
		row, column int
		want        shirei.Vec2
	}{
		{row: 0, column: 0, want: shirei.Vec2{11, 17}},
		{row: 0, column: 1, want: shirei.Vec2{20.25, 17}},
		{row: 1, column: 0, want: shirei.Vec2{11, 36}},
		{row: 23, column: 79, want: shirei.Vec2{11 + 79*9.25, 17 + 23*19}},
	} {
		if got := CellOrigin(origin, test.row, test.column, metrics); got != test.want {
			t.Errorf("CellOrigin(%d,%d) = %v, want %v", test.row, test.column, got, test.want)
		}
	}
}

func TestShireiFixedCellRendererKeepsColumnsStable(t *testing.T) {
	const (
		cols = 80
		rows = 1
	)
	origin := shirei.Vec2{11, 17}
	metrics := GridMetrics{CellWidth: 9.25, CellHeight: 19, FontSize: 14}
	snapshot := Snapshot{
		Cols:       cols,
		Rows:       rows,
		Cells:      make([]Cell, cols*rows),
		Foreground: RGB{255, 255, 255},
		Background: RGB{0, 0, 0},
	}
	snapshot.Cells[0] = Cell{Text: "M"}
	snapshot.Cells[1] = Cell{Text: "界", Wide: CellWideGlyph}
	snapshot.Cells[2] = Cell{Wide: CellSpacerTail}
	snapshot.Cells[4] = Cell{Text: "🙂", Wide: CellWideGlyph}
	snapshot.Cells[5] = Cell{Wide: CellSpacerTail}
	snapshot.Cells[79] = Cell{Text: "X"}

	shirei.ResetInputSession()
	shirei.GetHost().HeadlessRender = true
	shirei.GetHost().WindowFocused = true
	shirei.GetHost().WindowSize = shirei.Vec2{800, 100}
	scope := new(int)
	var placements []CellPlacement
	for range 3 {
		shirei.RunFrameFn(func() {
			shirei.ContainerWithKey(scope, shirei.Attrs(shirei.FixSize(800, 100), shirei.NoClip), func() {
				placements = RenderSnapshot(snapshot, origin, metrics)
			})
		})
	}

	if len(placements) != cols-2 {
		t.Fatalf("placements = %d, want %d after omitting two wide spacer tails", len(placements), cols-2)
	}
	for _, placement := range placements {
		rect := shirei.GetResolvedRectOf(placement.ID)
		wantOrigin := CellOrigin(origin, placement.Row, placement.Column, metrics)
		if rect.Origin != wantOrigin {
			t.Errorf("cell (%d,%d) origin = %v, want %v", placement.Row, placement.Column, rect.Origin, wantOrigin)
		}
		wantWidth := metrics.CellWidth * float32(placement.Span)
		if math.Abs(float64(rect.Size[0]-wantWidth)) > 0.001 || math.Abs(float64(rect.Size[1]-metrics.CellHeight)) > 0.001 {
			t.Errorf("cell (%d,%d) size = %v, want [%v %v]", placement.Row, placement.Column, rect.Size, wantWidth, metrics.CellHeight)
		}
	}
	var wide CellPlacement
	for _, placement := range placements {
		if placement.Column == 1 {
			wide = placement
		}
	}
	if wide.Span != 2 {
		t.Fatalf("wide cell span = %d, want 2", wide.Span)
	}
}
