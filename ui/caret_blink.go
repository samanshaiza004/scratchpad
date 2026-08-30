package ui

import (
	"time"

	. "go.hasen.dev/shirei"
)

const caretBlinkIntervalFallback = 500 * time.Millisecond

// editorCaretBlinkInterval is a narrow seam for a future system caret-blink
// preference. The portable fallback is intentionally modest and does not
// require platform integration or change global OS settings.
func editorCaretBlinkInterval() time.Duration {
	return caretBlinkIntervalFallback
}

type caretBlinkState struct {
	startedAt      time.Time
	interval       time.Duration
	eligible       bool
	nextTransition time.Time
	timer          *time.Timer
}

// caretVisible is deliberately pure: callers decide eligibility separately so
// selection, IME composition, focus, and headless rendering can be tested
// without waiting on wall-clock scheduling.
func caretVisible(now time.Time, state caretBlinkState) bool {
	if !state.eligible {
		return false
	}
	interval := state.interval
	if interval <= 0 {
		interval = caretBlinkIntervalFallback
	}
	if state.startedAt.IsZero() || now.Before(state.startedAt) {
		return true
	}
	return now.Sub(state.startedAt)/interval%2 == 0
}

// nextCaretTransition returns the remaining time until the visible phase
// changes. It uses synthetic timestamps in tests and never sleeps.
func nextCaretTransition(now time.Time, state caretBlinkState) time.Duration {
	interval := state.interval
	if interval <= 0 {
		interval = caretBlinkIntervalFallback
	}
	if state.startedAt.IsZero() || now.Before(state.startedAt) {
		return interval
	}
	rem := now.Sub(state.startedAt) % interval
	if rem == 0 {
		return interval
	}
	return interval - rem
}

func (s *caretBlinkState) stopTimer() {
	if s.timer != nil {
		s.timer.Stop()
	}
	s.timer = nil
	s.nextTransition = time.Time{}
}

func (s *caretBlinkState) disable() {
	s.stopTimer()
	s.eligible = false
}

func (s *caretBlinkState) reset(now time.Time, interval time.Duration) {
	s.stopTimer()
	s.startedAt = now
	s.interval = interval
	s.eligible = true
}

func (s *caretBlinkState) schedule(now time.Time, requestFrame func()) {
	if s.timer != nil || requestFrame == nil {
		return
	}
	delay := nextCaretTransition(now, *s)
	if delay <= 0 {
		delay = s.interval
	}
	s.nextTransition = now.Add(delay)
	// The callback intentionally does not touch UI state: time.AfterFunc runs
	// off the UI goroutine. The next frame derives the phase and schedules the
	// following one if the caret is still eligible.
	s.timer = time.AfterFunc(delay, requestFrame)
}

// sync updates the small UI-owned state for one rendered caret. It schedules
// at most one transition wakeup and returns the phase to paint this frame.
func (s *caretBlinkState) sync(now time.Time, eligible, activity, headless bool, requestFrame func()) bool {
	if !eligible {
		s.disable()
		return false
	}
	interval := editorCaretBlinkInterval()
	if activity || !s.eligible || s.startedAt.IsZero() || s.interval != interval {
		s.reset(now, interval)
	}
	if headless {
		s.stopTimer()
		return true
	}
	if !s.nextTransition.IsZero() && !now.Before(s.nextTransition) {
		s.stopTimer()
	}
	s.schedule(now, requestFrame)
	return caretVisible(now, *s)
}

type caretGeometry struct {
	Width  float32
	Height float32
	Y      float32
}

// caretGeometryForTextHeight keeps the bar independent from hit testing and
// row virtualization. The height comes from text metrics; only its placement
// is derived from the fixed logical row.
func caretGeometryForTextHeight(rowHeight, textHeight float32) caretGeometry {
	if rowHeight < 0 {
		rowHeight = 0
	}
	if textHeight <= 0 {
		textHeight = rowHeight
	}
	return caretGeometry{
		Width:  1,
		Height: textHeight,
		Y:      (rowHeight - textHeight) / 2,
	}
}

func editorCaretGeometry(rowHeight float32, style TextStyleAttrs) caretGeometry {
	textHeight := float32(CaretHeightForStyle(style))
	if textHeight <= 0 {
		textHeight = style.FontSize
	}
	return caretGeometryForTextHeight(rowHeight, textHeight)
}
