package treesitter

import (
	"bytes"
	"testing"

	"scratchpad/editor"
)

var goAdapterFixture = []byte(`package demo

import "fmt"

type Item struct {
	Name string
}

func Run(item Item) string {
	return fmt.Sprint(item.Name)
}
`)

func TestGoAdapterPublishesByteOrientedAnalysis(t *testing.T) {
	adapter, err := NewGoAdapter()
	if err != nil {
		t.Fatal(err)
	}
	defer adapter.Close()
	projection, err := adapter.Analyze(goAdapterFixture, 0, nil)
	if err != nil {
		t.Fatal(err)
	}
	if projection.Language != "go" || projection.Revision != 0 {
		t.Fatalf("projection identity = %q revision %d", projection.Language, projection.Revision)
	}
	if len(projection.Highlights) == 0 {
		t.Fatal("expected Go highlight spans")
	}
	if len(projection.Symbols) == 0 {
		t.Fatal("expected tags-derived Go symbols")
	}
	for _, span := range projection.Highlights {
		if span.StartByte < 0 || span.StartByte >= span.EndByte || span.EndByte > len(goAdapterFixture) {
			t.Fatalf("invalid highlight span %#v", span)
		}
	}
	if got := projection.HighlightsIn(0, 20); len(got) == 0 {
		t.Fatal("visible highlight query returned no spans")
	}
}

func TestGoAdapterIncrementalMatchesFreshProjectionShape(t *testing.T) {
	ed := editor.NewScratchEditor(goAdapterFixture)
	initial, err := NewGoAdapter()
	if err != nil {
		t.Fatal(err)
	}
	defer initial.Close()
	if _, err := initial.Analyze(goAdapterFixture, ed.Revision(), nil); err != nil {
		t.Fatal(err)
	}
	ed.SetCursor(bytes.Index(goAdapterFixture, []byte("Run")))
	if err := ed.Insert([]byte("Execute")); err != nil {
		t.Fatal(err)
	}
	edits, ok := ed.EditsSince(0)
	if !ok || len(edits) != 1 {
		t.Fatalf("edit chain ok=%v len=%d", ok, len(edits))
	}
	changed := ed.Buffer.Text()
	incremental, err := initial.Analyze(changed, ed.Revision(), edits)
	if err != nil {
		t.Fatal(err)
	}
	fresh, err := NewGoAdapter()
	if err != nil {
		t.Fatal(err)
	}
	defer fresh.Close()
	full, err := fresh.Analyze(changed, ed.Revision(), nil)
	if err != nil {
		t.Fatal(err)
	}
	if incremental.Language != full.Language || len(incremental.Highlights) != len(full.Highlights) || len(incremental.Symbols) != len(full.Symbols) {
		t.Fatalf("incremental shape differs: incremental=%d/%d fresh=%d/%d", len(incremental.Highlights), len(incremental.Symbols), len(full.Highlights), len(full.Symbols))
	}
}
