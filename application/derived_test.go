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

func writeTestFile(path string, data []byte) error {
	return os.WriteFile(path, data, 0o644)
}
