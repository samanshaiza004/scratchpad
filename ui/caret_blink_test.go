package ui

import (
	"testing"
	"time"

	. "go.hasen.dev/shirei"
)

func TestCaretBlinkPhasesAndTransition(t *testing.T) {
	start := time.Unix(100, 0)
	state := caretBlinkState{
		startedAt: start,
		interval:  500 * time.Millisecond,
		eligible:  true,
	}
	cases := []struct {
		name string
		now  time.Time
		want bool
	}{
		{"initial focus", start, true},
		{"before first interval", start.Add(499 * time.Millisecond), true},
		{"after one interval", start.Add(500 * time.Millisecond), false},
		{"after two intervals", start.Add(time.Second), true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := caretVisible(tc.now, state); got != tc.want {
				t.Fatalf("caretVisible(%v) = %v, want %v", tc.now.Sub(start), got, tc.want)
			}
		})
	}
	if got := nextCaretTransition(start.Add(125*time.Millisecond), state); got != 375*time.Millisecond {
		t.Fatalf("nextCaretTransition = %v, want 375ms", got)
	}
}

func TestCaretBlinkEligibilityAndReset(t *testing.T) {
	start := time.Unix(200, 0)
	state := caretBlinkState{}
	// No callback keeps this model-only test free of real timers.
	var requestFrame func()

	if !state.sync(start, true, false, false, requestFrame) {
		t.Fatal("initial focus should show the caret")
	}
	if state.startedAt != start {
		t.Fatalf("initial blink epoch = %v, want %v", state.startedAt, start)
	}

	hidden := start.Add(caretBlinkIntervalFallback)
	if got := state.sync(hidden, true, false, false, requestFrame); got {
		t.Fatal("caret should be hidden after one interval")
	}
	inputAt := hidden.Add(10 * time.Millisecond)
	if got := state.sync(inputAt, true, true, false, requestFrame); !got {
		t.Fatal("input should immediately show the caret")
	}
	if state.startedAt != inputAt {
		t.Fatalf("input reset epoch = %v, want %v", state.startedAt, inputAt)
	}

	if state.sync(inputAt, false, false, false, requestFrame) {
		t.Fatal("selection/composition/focus ineligible state should hide caret")
	}
	if state.eligible {
		t.Fatal("ineligible caret should not remain blink-eligible")
	}
	regainedAt := inputAt.Add(time.Second)
	if got := state.sync(regainedAt, true, false, false, requestFrame); !got {
		t.Fatal("selection collapse or focus regain should restart visibly")
	}
	if state.startedAt != regainedAt {
		t.Fatalf("regain reset epoch = %v, want %v", state.startedAt, regainedAt)
	}
}

func TestCaretGeometryUsesTextHeightAndCentersInRow(t *testing.T) {
	for _, tc := range []struct {
		name        string
		row, height float32
	}{
		{"normal row", 20, 12},
		{"larger font", 28, 18},
		{"empty row", 20, 10},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := caretGeometryForTextHeight(tc.row, tc.height)
			if got.Width != 1 {
				t.Fatalf("caret width = %v, want 1", got.Width)
			}
			if got.Height != tc.height {
				t.Fatalf("caret height = %v, want %v", got.Height, tc.height)
			}
			if got.Y != (tc.row-tc.height)/2 {
				t.Fatalf("caret y = %v, want %v", got.Y, (tc.row-tc.height)/2)
			}
		})
	}
}

func TestEditorCaretGeometryUsesShireiTextMetric(t *testing.T) {
	style := DefaultTextStyle()
	style.FontSize = 14
	got := editorCaretGeometry(24, style)
	wantHeight := float32(CaretHeightForStyle(style))
	if wantHeight <= 0 {
		wantHeight = style.FontSize
	}
	if got.Width != 1 || got.Height != wantHeight {
		t.Fatalf("caret geometry = %+v, want width 1 and height %v", got, wantHeight)
	}
	if got.Y != (24-wantHeight)/2 {
		t.Fatalf("caret y = %v, want %v", got.Y, (24-wantHeight)/2)
	}
}
