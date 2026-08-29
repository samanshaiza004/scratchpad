package document

import (
	"testing"
)

func TestDocumentRevisionAndOwnership(t *testing.T) {
	source := []byte("hello")
	doc := New("notes/today.md", source, "markdown")
	source[0] = 'X'

	if got := string(doc.Editor.Buffer.Text()); got != "hello" {
		t.Fatalf("New editor text = %q", got)
	}
	if doc.Dirty() {
		t.Fatal("new document should be clean")
	}

	if err := doc.ReplaceText([]byte("changed")); err != nil {
		t.Fatal(err)
	}
	if !doc.Dirty() || doc.Revision() != 1 {
		t.Fatalf("unexpected revision state: revision=%d saved=%d dirty=%v", doc.Revision(), doc.SavedRevision, doc.Dirty())
	}
	doc.MarkSaved()
	if doc.Dirty() {
		t.Fatal("saved document should be clean")
	}
	if got := string(doc.Editor.Buffer.Text()); got != "changed" {
		t.Fatalf("unexpected editor text: %q", got)
	}
}

func TestDocumentEditorRevisionAndDerivedState(t *testing.T) {
	doc := New("notes/today.md", []byte("one\ntwo"), "text")
	doc.Projections = Projections{Revision: doc.Revision(), Valid: true}
	doc.DerivedRevision = doc.Revision()
	if !doc.DerivedCurrent() {
		t.Fatal("initial projections should be current")
	}

	if err := doc.Insert([]byte("!")); err != nil {
		t.Fatal(err)
	}
	if !doc.Dirty() || doc.DerivedCurrent() {
		t.Fatalf("after edit: dirty=%v derivedCurrent=%v", doc.Dirty(), doc.DerivedCurrent())
	}
	if len(doc.Injected) != 0 || doc.Projections.Valid {
		t.Fatal("edit did not invalidate derived state")
	}

	if err := doc.Editor.Undo(); err != nil {
		t.Fatal(err)
	}
	if doc.Dirty() {
		t.Fatal("undo back to the original saved revision should be clean")
	}
	if err := doc.Editor.Redo(); err != nil {
		t.Fatal(err)
	}
	if !doc.Dirty() {
		t.Fatal("redo to unsaved revision should be dirty")
	}
	doc.MarkSaved()
	if doc.Dirty() {
		t.Fatal("current revision should be clean after save")
	}
	if err := doc.Editor.Undo(); err != nil {
		t.Fatal(err)
	}
	if !doc.Dirty() {
		t.Fatal("undo away from a newer saved revision should be dirty")
	}
}

func TestDocumentMetadataDoesNotOwnText(t *testing.T) {
	doc := New("notes/old.md", []byte("authoritative"), "text")
	doc.Path = "notes/new.md"
	doc.RootLanguage = "markdown"
	doc.DiskVersion = DiskVersion{Exists: true, Size: 42}
	if got := string(doc.Editor.Buffer.Text()); got != "authoritative" {
		t.Fatalf("metadata change replaced text: %q", got)
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
