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
