package application

import (
	"os"
	"path/filepath"
	"testing"

	"scratchpad/commands"
)

func TestMarkdownEnterAppliesContinuationAndBreakoutAsOneEdit(t *testing.T) {
	tests := []struct {
		name   string
		source string
		cursor int
		want   string
		start  int
		end    int
	}{
		{name: "unordered continuation", source: "- first", cursor: 7, want: "- first\n- ", start: 7, end: 7},
		{name: "ordered increments", source: "09. item", cursor: 8, want: "09. item\n10. ", start: 8, end: 8},
		{name: "checked task resets", source: "- [x] done", cursor: 10, want: "- [x] done\n- [ ] ", start: 10, end: 10},
		{name: "empty item breaks out", source: "- ", cursor: 2, want: "\n", start: 0, end: 2},
		{name: "empty quote breaks out", source: "  > ", cursor: 4, want: "  \n  ", start: 2, end: 4},
		{name: "CRLF is preserved", source: "- first\r\nnext", cursor: 7, want: "- first\r\n- \r\nnext", start: 7, end: 7},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "note.md")
			if err := os.WriteFile(path, []byte(test.source), 0o644); err != nil {
				t.Fatal(err)
			}
			app := New(nil)
			if err := app.OpenPath(path); err != nil {
				t.Fatal(err)
			}
			doc := app.Documents[app.Active]
			applied, err := app.ReplaceDocument(PresentationCommand{
				Kind: PresentationReplaceDocument, ActionID: string(commands.MarkdownEnter),
				DocumentID: app.Active, EditorRevision: doc.Revision(),
				StartByte: test.start, EndByte: test.end, Replacement: []byte{'\n'},
				HasSelectionState: true,
				BeforeAnchorByte:  test.cursor, BeforeCursorByte: test.cursor,
				AfterAnchorByte: test.cursor + 1, AfterCursorByte: test.cursor + 1,
			})
			if err != nil {
				t.Fatal(err)
			}
			got, err := doc.Editor.Buffer.Bytes(0, doc.Editor.Buffer.ByteLen())
			if err != nil {
				t.Fatal(err)
			}
			if string(got) != test.want {
				t.Fatalf("source after Markdown Enter = %q, want %q", got, test.want)
			}
			if applied.SourceEdit.StartByte != test.start || applied.SourceEdit.OldEndByte != test.end {
				t.Fatalf("applied source range = [%d,%d), want [%d,%d)", applied.SourceEdit.StartByte, applied.SourceEdit.OldEndByte, test.start, test.end)
			}
			if err := app.UndoDocument(app.Active); err != nil {
				t.Fatal(err)
			}
			got, err = doc.Editor.Buffer.Bytes(0, doc.Editor.Buffer.ByteLen())
			if err != nil || string(got) != test.source {
				t.Fatalf("Undo source = %q, %v; want original %q", got, err, test.source)
			}
		})
	}
}
