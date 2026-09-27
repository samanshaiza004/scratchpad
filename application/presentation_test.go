package application

import (
	"errors"
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

func TestPreviewTabsReplaceCleanPreviewAndPinOnEdit(t *testing.T) {
	dir := t.TempDir()
	first := filepath.Join(dir, "first.md")
	second := filepath.Join(dir, "second.md")
	third := filepath.Join(dir, "third.md")
	for path, body := range map[string]string{first: "first", second: "second", third: "third"} {
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	app := New(nil)
	if err := app.Dispatch(PresentationCommand{Kind: PresentationOpenPath, Path: first, Preview: true}); err != nil {
		t.Fatal(err)
	}
	firstID := app.Active
	if state := app.Snapshot(); len(state.Documents) != 1 || !state.Documents[0].Preview {
		t.Fatalf("first tree-open state = %+v, want one preview", state)
	}
	if err := app.Dispatch(PresentationCommand{Kind: PresentationOpenPath, Path: second, Preview: true}); err != nil {
		t.Fatal(err)
	}
	secondID := app.Active
	if _, open := app.Documents[firstID]; open || len(app.Order) != 1 || app.Preview != secondID {
		t.Fatalf("clean preview was not replaced: order=%v preview=%q", app.Order, app.Preview)
	}

	doc := app.Documents[secondID]
	doc.Editor.SetCursor(doc.Editor.Buffer.ByteLen())
	if err := doc.Insert([]byte(" edited")); err != nil {
		t.Fatal(err)
	}
	state := app.Snapshot()
	if !state.Documents[0].Dirty || state.Documents[0].Preview {
		t.Fatalf("application replacement edit did not pin preview: %+v", state.Documents[0])
	}

	if err := app.Dispatch(PresentationCommand{Kind: PresentationOpenPath, Path: third, Preview: true}); err != nil {
		t.Fatal(err)
	}
	thirdID := app.Active
	if len(app.Order) != 2 || app.Documents[secondID] == nil || app.Preview != app.Active {
		t.Fatalf("dirty preview should remain pinned beside the new preview: order=%v preview=%q active=%q", app.Order, app.Preview, app.Active)
	}
	if err := app.OpenPath(first); err != nil {
		t.Fatal(err)
	}
	if app.Preview != thirdID || app.Active == thirdID || len(app.Order) != 3 {
		t.Fatalf("explicit open should add a pinned tab without replacing preview: order=%v preview=%q active=%q", app.Order, app.Preview, app.Active)
	}
}

func TestDirtyDirectEditPinsPreviewAndCloseClearsIt(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "preview.txt")
	if err := os.WriteFile(path, []byte("hello"), 0o644); err != nil {
		t.Fatal(err)
	}
	app := New(nil)
	if err := app.OpenPreviewPath(path); err != nil {
		t.Fatal(err)
	}
	id := app.Active
	doc := app.Documents[id]
	doc.Editor.SetCursor(doc.Editor.Buffer.ByteLen())
	if err := doc.Insert([]byte("!")); err != nil {
		t.Fatal(err)
	}
	if !app.PinDirtyPreview() || app.Preview != "" {
		t.Fatal("direct application edit should promote the dirty preview")
	}
	if err := app.CloseDocument(id, true); err != nil {
		t.Fatal(err)
	}
	if app.Preview != "" {
		t.Fatalf("closing preview left stale preview identity %q", app.Preview)
	}
}

func TestPresentationContractAppliesRevisionedReplacement(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "edit.txt")
	if err := os.WriteFile(path, []byte("hello\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	app := New(nil)
	var client PresentationClient = app
	if err := client.Dispatch(PresentationCommand{Kind: PresentationOpenPath, Path: path}); err != nil {
		t.Fatal(err)
	}
	state := client.Snapshot()
	id := state.Active
	if err := client.Dispatch(PresentationCommand{
		Kind:           PresentationReplaceDocument,
		DocumentID:     id,
		EditorRevision: state.Documents[0].EditorRevision,
		StartByte:      5,
		EndByte:        5,
		Replacement:    []byte(" world"),
	}); err != nil {
		t.Fatal(err)
	}

	updated := client.Snapshot()
	if got := string(app.Documents[id].Editor.Buffer.Text()); got != "hello world\n" {
		t.Fatalf("edited bytes = %q", got)
	}
	if updated.Documents[0].EditorRevision == state.Documents[0].EditorRevision || !updated.Documents[0].Dirty {
		t.Fatalf("edited state = %+v", updated.Documents[0])
	}

	err := client.Dispatch(PresentationCommand{
		Kind:           PresentationReplaceDocument,
		DocumentID:     id,
		EditorRevision: state.Documents[0].EditorRevision,
		StartByte:      0,
		EndByte:        0,
		Replacement:    []byte("stale "),
	})
	if !errors.Is(err, ErrStaleEditorRevision) {
		t.Fatalf("stale edit error = %v, want ErrStaleEditorRevision", err)
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
