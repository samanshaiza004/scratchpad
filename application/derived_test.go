package application

import (
	"os"
	"testing"
	"time"

	"scratchpad/workspace"
)

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
	if len(doc.Projections.Code.Highlights) == 0 || len(doc.Projections.Code.Symbols) == 0 {
		t.Fatalf("Go projection lacks analysis: %+v", doc.Projections.Code)
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
