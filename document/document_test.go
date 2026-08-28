package document

import (
	"bytes"
	"testing"
)

func TestDocumentRevisionAndOwnership(t *testing.T) {
	source := []byte("hello")
	doc := New("notes/today.md", source, "markdown")
	source[0] = 'X'

	if string(doc.Source) != "hello" {
		t.Fatalf("New did not copy source: %q", doc.Source)
	}
	if doc.Dirty() {
		t.Fatal("new document should be clean")
	}

	doc.ReplaceSource([]byte("changed"))
	if !doc.Dirty() || doc.Revision != 1 {
		t.Fatalf("unexpected revision state: revision=%d saved=%d dirty=%v", doc.Revision, doc.SavedRevision, doc.Dirty())
	}
	doc.MarkSaved()
	if doc.Dirty() {
		t.Fatal("saved document should be clean")
	}
	if !bytes.Equal(doc.Source, []byte("changed")) {
		t.Fatalf("unexpected source: %q", doc.Source)
	}
}

func TestLineIndex(t *testing.T) {
	source := []byte("one\ntwo\n")
	index := BuildLineIndex(source)
	if index.Len() != 3 {
		t.Fatalf("got %d lines, want 3", index.Len())
	}

	want := [][2]int{{0, 3}, {4, 7}, {8, 8}}
	for line, pair := range want {
		start, end, ok := index.Range(line, len(source))
		if !ok || start != pair[0] || end != pair[1] {
			t.Fatalf("line %d range = (%d, %d, %v), want (%d, %d, true)", line, start, end, ok, pair[0], pair[1])
		}
	}

	for _, test := range []struct {
		offset int
		line   int
	}{
		{0, 0}, {3, 0}, {4, 1}, {8, 2},
	} {
		line, ok := index.LineForByte(test.offset)
		if !ok || line != test.line {
			t.Errorf("LineForByte(%d) = (%d, %v), want (%d, true)", test.offset, line, ok, test.line)
		}
	}
}
