package editor

import "testing"

func TestRowMapNormalizesIntervalsAndMapsBothDirections(t *testing.T) {
	m := NewRowMap(12, []HiddenLineRange{{Start: 4, End: 7}, {Start: 6, End: 9}, {Start: -2, End: 1}})
	if m.Count() != 6 {
		t.Fatalf("visible rows=%d, want 6", m.Count())
	}
	wantLogical := []int{1, 2, 3, 9, 10, 11}
	if len(wantLogical) != m.Count() {
		t.Fatalf("test setup has %d expected rows, map has %d", len(wantLogical), m.Count())
	}
	for visible, want := range wantLogical {
		got, ok := m.Logical(visible)
		if !ok || got != want {
			t.Fatalf("Logical(%d)=%d,%v, want %d,true", visible, got, ok, want)
		}
		back, ok := m.Visible(want)
		if !ok || back != visible {
			t.Fatalf("Visible(%d)=%d,%v, want %d,true", want, back, ok, visible)
		}
	}
	if _, ok := m.Visible(5); ok {
		t.Fatal("hidden logical line was reported visible")
	}
}
