package application

import (
	"os"
	"path/filepath"
	"testing"
)

func TestPresentationContractKeepsLifecycleSemantic(t *testing.T) {
	dir := t.TempDir()
	first := filepath.Join(dir, "first.md")
	second := filepath.Join(dir, "second.txt")
	if err := os.WriteFile(first, []byte("first"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(second, []byte("second"), 0o644); err != nil {
		t.Fatal(err)
	}

	app := New(nil)
	var client PresentationClient = app
	if err := client.Dispatch(PresentationCommand{Kind: PresentationOpenPath, Path: first}); err != nil {
		t.Fatal(err)
	}
	state := client.Snapshot()
	if state.Revision == 0 || state.Active == "" || len(state.Documents) != 1 {
		t.Fatalf("initial presentation state = %+v", state)
	}
	if state.Documents[0].Path != first || state.Documents[0].Status != StatusSynced || state.Documents[0].Language != "markdown" {
		t.Fatalf("initial document state = %+v", state.Documents[0])
	}

	firstID := state.Documents[0].ID
	if err := client.Dispatch(PresentationCommand{Kind: PresentationOpenPath, Path: second}); err != nil {
		t.Fatal(err)
	}
	secondID := client.Snapshot().Active
	if err := client.Dispatch(PresentationCommand{Kind: PresentationSelectDocument, DocumentID: firstID}); err != nil {
		t.Fatal(err)
	}
	if got := client.Snapshot().Active; got != firstID {
		t.Fatalf("active document = %q, want %q", got, firstID)
	}

	doc := app.Documents[firstID]
	doc.Editor.SetCursor(doc.Editor.Buffer.ByteLen())
	if err := doc.Insert([]byte(" changed")); err != nil {
		t.Fatal(err)
	}
	state = client.Snapshot()
	if !state.Documents[0].Dirty || state.Documents[0].EditorRevision == 0 {
		t.Fatalf("edited document state = %+v", state.Documents[0])
	}
	if err := client.Dispatch(PresentationCommand{Kind: PresentationSaveDocument, DocumentID: firstID}); err != nil {
		t.Fatal(err)
	}
	if got := client.Snapshot().Documents[0].Status; got != StatusSynced {
		t.Fatalf("saved document status = %v, want synced", got)
	}
	if err := client.Dispatch(PresentationCommand{Kind: PresentationCloseDocument, DocumentID: secondID, Discard: true}); err != nil {
		t.Fatal(err)
	}
	if len(client.Snapshot().Documents) != 1 {
		t.Fatalf("documents after close = %+v", client.Snapshot().Documents)
	}
}

func TestPresentationContractRejectsUnknownCommandsAndDocuments(t *testing.T) {
	app := New(nil)
	var client PresentationClient = app
	if err := client.Dispatch(PresentationCommand{}); err == nil {
		t.Fatal("unknown command was accepted")
	}
	if err := client.Dispatch(PresentationCommand{Kind: PresentationSelectDocument, DocumentID: "missing"}); err == nil {
		t.Fatal("unknown document was selected")
	}
}

func BenchmarkPresentationDispatchSelect(b *testing.B) {
	app, id := benchmarkPresentationApplication(b)
	var client PresentationClient = app
	command := PresentationCommand{Kind: PresentationSelectDocument, DocumentID: id}
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		if err := client.Dispatch(command); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkDirectActivate(b *testing.B) {
	app, id := benchmarkPresentationApplication(b)
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		if !app.Activate(id) {
			b.Fatal("document disappeared")
		}
	}
}

func BenchmarkPresentationSnapshot(b *testing.B) {
	app, _ := benchmarkPresentationApplication(b)
	var client PresentationClient = app
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		state := client.Snapshot()
		if len(state.Documents) != 1 {
			b.Fatal("document disappeared")
		}
	}
}

func benchmarkPresentationApplication(b *testing.B) (*Application, DocumentID) {
	b.Helper()
	path := filepath.Join(b.TempDir(), "benchmark.txt")
	if err := os.WriteFile(path, []byte("benchmark"), 0o644); err != nil {
		b.Fatal(err)
	}
	app := New(nil)
	if err := app.OpenPath(path); err != nil {
		b.Fatal(err)
	}
	return app, app.Active
}
