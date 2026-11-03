package application

import (
	"os"
	"path/filepath"
	"testing"

	"scratchpad/commands"
)

func TestTaskMarkerCutPasteUndoRedo(t *testing.T) {
	const source = "- [x] Task\nordinary text\n"
	for _, selection := range [][2]int{{2, 5}, {2, 3}, {4, 5}, {3, 4}, {0, 6}, {2, 18}} {
		app := New(nil)
		defer app.CloseDerived()
		path := filepath.Join(t.TempDir(), "task.md")
		if err := os.WriteFile(path, []byte(source), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := app.OpenPath(path); err != nil {
			t.Fatal(err)
		}
		doc := app.Documents[app.Active]
		start, end := selection[0], selection[1]
		_, err := app.ReplaceDocument(PresentationCommand{
			Kind: PresentationReplaceDocument, DocumentID: app.Active, EditorRevision: doc.Revision(),
			StartByte: start, EndByte: end, HasSelectionState: true,
			BeforeAnchorByte: start, BeforeCursorByte: end, AfterAnchorByte: start, AfterCursorByte: start,
		})
		if err != nil {
			t.Fatal(err)
		}
		cut := source[:start] + source[end:]
		request, err := commands.NewRequest(doc, commands.ItemToggle)
		if err != nil {
			t.Fatal(err)
		}
		if string(doc.Editor.Buffer.Text()) != cut || len(request.Projections.Tasks) != 0 {
			t.Fatalf("cut %v retained invalid task syntax: %q %+v", selection, doc.Editor.Buffer.Text(), request.Projections.Tasks)
		}
		if err := app.UndoDocument(app.Active); err != nil {
			t.Fatal(err)
		}
		if string(doc.Editor.Buffer.Text()) != source {
			t.Fatal("undo did not restore exact task source")
		}
		if err := app.RedoDocument(app.Active); err != nil {
			t.Fatal(err)
		}
		if string(doc.Editor.Buffer.Text()) != cut {
			t.Fatal("redo did not restore exact cut source")
		}
		if _, err := app.PasteDocument(app.Active, doc.Revision(), start, start, []byte(source[start:end]), start, start); err != nil {
			t.Fatal(err)
		}
		request, err = commands.NewRequest(doc, commands.ItemToggle)
		if err != nil {
			t.Fatal(err)
		}
		if string(doc.Editor.Buffer.Text()) != source || len(request.Projections.Tasks) != 1 {
			t.Fatalf("paste %v did not restore ordinary task source", selection)
		}
	}
}
