package application

import (
	"os"
	"sync/atomic"
	"testing"
	"time"

	"scratchpad/document"
	"scratchpad/editor"
	"scratchpad/workspace"
)

type slowDerivedAnalyzer struct {
	started chan struct{}
	release chan struct{}
	calls   atomic.Int32
}

func (a *slowDerivedAnalyzer) Analyze(_ []byte, revision uint64, _ []editor.SourceEdit) (document.CodeProjection, error) {
	a.calls.Add(1)
	select {
	case a.started <- struct{}{}:
	default:
	}
	<-a.release
	return document.NewCodeProjection(revision, "go", nil, nil, nil), nil
}

func (*slowDerivedAnalyzer) Close() {}

func TestDerivedProjectionDoesNotReanalyzeUnchangedRunningRevision(t *testing.T) {
	dir := t.TempDir()
	path := dir + "/main.go"
	if err := writeTestFile(path, []byte("package main\n")); err != nil {
		t.Fatal(err)
	}
	a := New(workspace.NewOSFileStore())
	if err := a.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	doc := a.ActiveDocument()
	analyzer := &slowDerivedAnalyzer{started: make(chan struct{}, 1), release: make(chan struct{})}
	a.ensureDerivedState()
	a.derived[a.Active] = &projectionState{runtime: analyzer}

	a.PollDerived(time.Now())
	select {
	case <-analyzer.started:
	case <-time.After(time.Second):
		t.Fatal("slow analyzer did not start")
	}

	// Poll repeatedly while the worker is blocked. The unchanged revision is
	// already represented by runningRevision and must not be queued again.
	for i := 0; i < 5; i++ {
		a.PollDerived(time.Now())
	}
	close(analyzer.release)
	waitForDerived(t, a, doc, time.Second)
	if got := analyzer.calls.Load(); got != 1 {
		t.Fatalf("Analyze calls = %d, want 1", got)
	}
}

func TestDerivedProjectionDebouncesAndPublishesLatestRevision(t *testing.T) {
	dir := t.TempDir()
	path := dir + "/note.md"
	if err := writeTestFile(path, []byte("# One\n")); err != nil {
		t.Fatal(err)
	}
	a := New(workspace.NewOSFileStore())
	if err := a.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	doc := a.ActiveDocument()
	now := time.Now()
	if err := doc.Replace(0, 0, []byte("# Zero\n")); err != nil {
		t.Fatal(err)
	}
	a.PollDerived(now)
	if doc.Projections.Valid {
		t.Fatal("projection published before debounce")
	}
	a.PollDerived(now.Add(projectionDebounce - time.Millisecond))
	if doc.Projections.Valid {
		t.Fatal("projection published before debounce elapsed")
	}
	a.PollDerived(now.Add(projectionDebounce))
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) && !doc.DerivedCurrent() {
		time.Sleep(time.Millisecond)
		a.PollDerived(time.Now())
	}
	if !doc.DerivedCurrent() || len(doc.Projections.Headings) != 2 {
		t.Fatalf("derived=%v headings=%+v", doc.DerivedCurrent(), doc.Projections.Headings)
	}
}

func TestDerivedProjectionWakeRearmsAfterEarlyWake(t *testing.T) {
	dir := t.TempDir()
	path := dir + "/note.md"
	if err := writeTestFile(path, []byte("# One\n")); err != nil {
		t.Fatal(err)
	}
	a := New(workspace.NewOSFileStore())
	if err := a.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	a.SetWake(func() {})
	var wakeDelays []time.Duration
	var wakes []func()
	a.derivedAfterFunc = func(delay time.Duration, wake func()) {
		wakeDelays = append(wakeDelays, delay)
		wakes = append(wakes, wake)
	}

	doc := a.ActiveDocument()
	t0 := time.Unix(1000, 0)
	if err := doc.Replace(0, 0, []byte("# Zero\n")); err != nil {
		t.Fatal(err)
	}
	a.PollDerived(t0)
	if len(wakes) != 1 || wakeDelays[0] != projectionDebounce {
		t.Fatalf("initial wake delays = %+v, want one wake after %s", wakeDelays, projectionDebounce)
	}

	// Keep the coordinator occupied so this test exercises only wake
	// scheduling. The second edit moves the desired deadline to t0+250ms,
	// while the original timer is still due at t0+150ms.
	state := a.derived[a.Active]
	state.running = true
	if err := doc.Replace(0, 0, []byte("# Latest\n")); err != nil {
		t.Fatal(err)
	}
	t100 := t0.Add(100 * time.Millisecond)
	a.PollDerived(t100)
	if len(wakes) != 1 {
		t.Fatalf("wake was rescheduled before the early wake: %+v", wakeDelays)
	}

	// The old timer fires early at t0+150ms. PollDerived must observe the
	// outstanding t0+250ms deadline and install a replacement timer.
	wakes[0]()
	t150 := t0.Add(150 * time.Millisecond)
	a.PollDerived(t150)
	if len(wakes) != 2 || wakeDelays[1] != 100*time.Millisecond {
		t.Fatalf("rearmed wake delays = %+v, want a 100ms wake", wakeDelays)
	}

	wakes[1]()
	a.PollDerived(t0.Add(250 * time.Millisecond))
	if len(wakes) != 2 {
		t.Fatal("final deadline unexpectedly scheduled another wake")
	}
}

func TestDerivedProjectionAnalyzesGoThroughTheSharedCoordinator(t *testing.T) {
	dir := t.TempDir()
	path := dir + "/main.go"
	if err := writeTestFile(path, []byte("package main\n\nfunc main() {\n}\n")); err != nil {
		t.Fatal(err)
	}
	a := New(workspace.NewOSFileStore())
	if err := a.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	doc := a.ActiveDocument()
	now := time.Now()
	a.PollDerived(now)
	a.PollDerived(now.Add(projectionDebounce))
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) && !doc.DerivedCurrent() {
		time.Sleep(time.Millisecond)
		a.PollDerived(time.Now())
	}
	if !doc.DerivedCurrent() || doc.Projections.Code.Language != "go" {
		t.Fatalf("derived=%v code=%+v", doc.DerivedCurrent(), doc.Projections.Code)
	}
	if len(doc.Projections.Code.Highlights) == 0 {
		t.Fatalf("Go projection lacks analysis: %+v", doc.Projections.Code)
	}
}

func TestDerivedProjectionAnalyzesGoWithoutTypingDebounce(t *testing.T) {
	dir := t.TempDir()
	path := dir + "/main.go"
	if err := writeTestFile(path, []byte("package main\n\nfunc main() {}\n")); err != nil {
		t.Fatal(err)
	}
	a := New(workspace.NewOSFileStore())
	if err := a.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	doc := a.ActiveDocument()
	now := time.Now()
	a.PollDerived(now)
	waitForDerived(t, a, doc, 500*time.Millisecond)

	if err := doc.Replace(0, 0, []byte("// typed\n")); err != nil {
		t.Fatal(err)
	}
	now = time.Now()
	a.PollDerived(now)

	// A code projection should be eligible immediately. Keep the clock inside
	// the old Markdown debounce window so this fails if code is still delayed.
	deadline := time.Now().Add(projectionDebounce / 2)
	for time.Now().Before(deadline) && !doc.DerivedCurrent() {
		a.PollDerived(now.Add(time.Millisecond))
		time.Sleep(time.Millisecond)
	}
	if !doc.DerivedCurrent() {
		t.Fatal("Go projection remained debounced during the typing window")
	}
}

func TestDerivedProjectionReanalyzesCleanDiskReload(t *testing.T) {
	dir := t.TempDir()
	path := dir + "/note.md"
	if err := writeTestFile(path, []byte("# Before\n")); err != nil {
		t.Fatal(err)
	}
	a := New(workspace.NewOSFileStore())
	if err := a.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	doc := a.ActiveDocument()
	now := time.Now()
	a.PollDerived(now)
	a.PollDerived(now.Add(projectionDebounce))
	waitForDerived(t, a, doc, time.Second)
	oldRevision := doc.Revision()

	if err := writeTestFile(path, []byte("# After\n")); err != nil {
		t.Fatal(err)
	}
	if status, err := a.Reconcile(a.Active); err != nil || status != StatusSynced {
		t.Fatalf("reload status=%v err=%v", status, err)
	}
	if doc.Revision() == oldRevision {
		t.Fatalf("reload reused revision %d", doc.Revision())
	}
	if doc.DerivedCurrent() {
		t.Fatal("reload retained a projection for the old bytes")
	}

	a.PollDerived(time.Now().Add(projectionDebounce))
	waitForDerived(t, a, doc, time.Second)
	if len(doc.Projections.Headings) != 1 || doc.Projections.Headings[0].Text != "After" {
		t.Fatalf("reloaded headings = %+v", doc.Projections.Headings)
	}
}

func TestDerivedProjectionRejectsInFlightResultFromDiskReload(t *testing.T) {
	dir := t.TempDir()
	path := dir + "/note.md"
	if err := writeTestFile(path, []byte("# Before\n")); err != nil {
		t.Fatal(err)
	}
	a := New(workspace.NewOSFileStore())
	if err := a.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	doc := a.ActiveDocument()
	id := a.Active
	a.ensureDerivedState()
	oldRevision := doc.Revision()
	a.derived[id] = &projectionState{running: true, hasSeen: true, seenRevision: oldRevision}
	a.derivedRunning = 1

	if err := writeTestFile(path, []byte("# After\n")); err != nil {
		t.Fatal(err)
	}
	if status, err := a.Reconcile(id); err != nil || status != StatusSynced {
		t.Fatalf("reload status=%v err=%v", status, err)
	}
	a.derivedResults <- projectionResult{
		id:       id,
		revision: oldRevision,
		parsed:   oldRevision,
		projections: document.Projections{
			Revision: oldRevision,
			Headings: []document.Heading{{Text: "Before"}},
		},
	}
	a.PollDerived(time.Now())
	if doc.DerivedCurrent() || len(doc.Projections.Headings) != 0 {
		t.Fatal("in-flight projection for old bytes was published after reload")
	}

	a.PollDerived(time.Now().Add(projectionDebounce))
	waitForDerived(t, a, doc, time.Second)
	if len(doc.Projections.Headings) != 1 || doc.Projections.Headings[0].Text != "After" {
		t.Fatalf("reloaded headings = %+v", doc.Projections.Headings)
	}
}

func waitForDerived(t *testing.T, a *Application, doc *document.Document, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) && !doc.DerivedCurrent() {
		a.PollDerived(time.Now())
		time.Sleep(time.Millisecond)
	}
	if !doc.DerivedCurrent() {
		t.Fatal("derived projection did not publish")
	}
}

func TestDerivedProjectionComposesFencedGoIntoMarkdown(t *testing.T) {
	dir := t.TempDir()
	path := dir + "/README.md"
	source := []byte("# Example\n\n```go\nfunc main() {\n}\n```\n")
	if err := writeTestFile(path, source); err != nil {
		t.Fatal(err)
	}
	a := New(workspace.NewOSFileStore())
	if err := a.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	doc := a.ActiveDocument()
	now := time.Now()
	a.PollDerived(now)
	a.PollDerived(now.Add(projectionDebounce))
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) && !doc.DerivedCurrent() {
		time.Sleep(time.Millisecond)
		a.PollDerived(time.Now())
	}
	if !doc.DerivedCurrent() || len(doc.Injected) != 1 || len(doc.Projections.Code.Highlights) == 0 {
		t.Fatalf("derived=%v injected=%+v code=%+v", doc.DerivedCurrent(), doc.Injected, doc.Projections.Code)
	}
	region := doc.Injected[0]
	if doc.Projections.Code.Highlights[0].StartByte < region.StartByte {
		t.Fatalf("injected highlight was not translated: %+v region=%+v", doc.Projections.Code.Highlights[0], region)
	}
}

func writeTestFile(path string, data []byte) error {
	return os.WriteFile(path, data, 0o644)
}
