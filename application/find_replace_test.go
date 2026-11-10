package application

import (
	"bytes"
	"testing"

	"scratchpad/document"
	"scratchpad/workspace"
)

func TestReplaceAllRejectsDocumentExpansionBeforeMutation(t *testing.T) {
	app := New(nil)
	id := DocumentID("large-replace-all")
	source := bytes.Repeat([]byte("x"), 513)
	doc := document.New("large.txt", source, "text")
	app.Documents[id] = doc
	app.Order = []DocumentID{id}
	app.Active = id

	replacement := bytes.Repeat([]byte("y"), 128*1024)
	beforeRevision := doc.Revision()
	result, err := app.ReplaceAllCurrent(id, beforeRevision, []byte("x"), replacement, 0, 0)
	if err == nil || result.Changed {
		t.Fatalf("oversized expansion result = %+v, error = %v", result, err)
	}
	if got := doc.Editor.Buffer.Text(); !bytes.Equal(got, source) {
		t.Fatal("oversized expansion mutated the document")
	}
	if doc.Revision() != beforeRevision || doc.Editor.CanUndo() {
		t.Fatalf("oversized expansion changed editor history/revision: rev=%d canUndo=%v", doc.Revision(), doc.Editor.CanUndo())
	}
	if int64(len(source)*len(replacement)) <= workspace.MaxSearchFileBytes {
		t.Fatal("test fixture does not exceed the document size limit")
	}
}

func TestReplaceAllDenseMatchesUsesNonOverlappingOrder(t *testing.T) {
	app := New(nil)
	id := DocumentID("dense-replace-all")
	source := []byte("aba aba aba")
	doc := document.New("dense.txt", source, "text")
	app.Documents[id] = doc
	app.Order = []DocumentID{id}
	app.Active = id

	result, err := app.ReplaceAllCurrent(id, doc.Revision(), []byte("aba"), []byte("x"), 0, 0)
	if err != nil {
		t.Fatal(err)
	}
	if result.MatchCount != 3 || !result.Changed {
		t.Fatalf("Replace All result = %+v", result)
	}
	if got := string(doc.Editor.Buffer.Text()); got != "x x x" {
		t.Fatalf("replacement result = %q", got)
	}
	if err := doc.Undo(); err != nil || string(doc.Editor.Buffer.Text()) != string(source) {
		t.Fatal("the dense replacement was not restored by one undo")
	}
}

func BenchmarkReplaceAllDenseMatches(b *testing.B) {
	source := bytes.Repeat([]byte("x "), 1<<19)
	b.ReportAllocs()
	b.SetBytes(int64(len(source)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		app := New(nil)
		id := DocumentID("dense-replace-all")
		doc := document.New("dense.txt", source, "text")
		app.Documents[id] = doc
		app.Order = []DocumentID{id}
		app.Active = id
		if _, err := app.ReplaceAllCurrent(id, doc.Revision(), []byte("x"), []byte("y"), 0, 0); err != nil {
			b.Fatal(err)
		}
	}
}
