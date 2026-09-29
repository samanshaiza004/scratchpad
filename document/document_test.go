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

func TestDocumentUndoRedoRestoresSelectionRevisionAndInvalidatesDerivedState(t *testing.T) {
	doc := New("notes/today.md", []byte("abcdef"), "text")
	doc.Editor.SetSelection(5, 2)
	if !doc.SetDerived(nil, Projections{Revision: doc.Revision()}) {
		t.Fatal("could not seed derived state for initial revision")
	}

	if err := doc.ReplaceWithSelection(2, 5, []byte("X"), 2, 3); err != nil {
		t.Fatal(err)
	}
	if got := string(doc.Editor.Buffer.Text()); got != "abXf" || doc.Revision() != 1 || !doc.Dirty() {
		t.Fatalf("edited state = %q revision=%d dirty=%v", got, doc.Revision(), doc.Dirty())
	}
	if !doc.SetDerived(nil, Projections{Revision: doc.Revision()}) {
		t.Fatal("could not seed derived state for edited revision")
	}

	if err := doc.Undo(); err != nil {
		t.Fatal(err)
	}
	if got := string(doc.Editor.Buffer.Text()); got != "abcdef" {
		t.Fatalf("undo text = %q, want original bytes", got)
	}
	if anchor, cursor := doc.Editor.Selection(); anchor != 5 || cursor != 2 {
		t.Fatalf("undo selection = %d:%d, want directional 5:2", anchor, cursor)
	}
	if doc.Revision() != 0 || doc.Dirty() || doc.DerivedCurrent() {
		t.Fatalf("undo state = revision %d dirty=%v derived_current=%v", doc.Revision(), doc.Dirty(), doc.DerivedCurrent())
	}
	if doc.CanUndo() || !doc.CanRedo() {
		t.Fatalf("undo availability = can_undo %v can_redo %v", doc.CanUndo(), doc.CanRedo())
	}

	if !doc.SetDerived(nil, Projections{Revision: doc.Revision()}) {
		t.Fatal("could not seed derived state after undo")
	}
	if err := doc.Redo(); err != nil {
		t.Fatal(err)
	}
	if got := string(doc.Editor.Buffer.Text()); got != "abXf" {
		t.Fatalf("redo text = %q, want edited bytes", got)
	}
	if anchor, cursor := doc.Editor.Selection(); anchor != 2 || cursor != 3 {
		t.Fatalf("redo selection = %d:%d, want 2:3", anchor, cursor)
	}
	if doc.Revision() != 1 || !doc.Dirty() || doc.DerivedCurrent() {
		t.Fatalf("redo state = revision %d dirty=%v derived_current=%v", doc.Revision(), doc.Dirty(), doc.DerivedCurrent())
	}
	if !doc.CanUndo() || doc.CanRedo() {
		t.Fatalf("redo availability = can_undo %v can_redo %v", doc.CanUndo(), doc.CanRedo())
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
