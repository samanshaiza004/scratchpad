package application

import (
	"errors"
	"strings"
	"testing"

	"scratchpad/document"
)

func clipboardTestApplication(source []byte, language string) (*Application, DocumentID) {
	app := New(nil)
	id := DocumentID("clipboard-test")
	app.Documents[id] = document.New("note.md", source, language)
	app.Order = []DocumentID{id}
	app.Active = id
	return app, id
}

func TestPasteDocumentNormalizesClipboardLineEndingsToDocument(t *testing.T) {
	for _, test := range []struct {
		name         string
		source       string
		input        string
		wantText     string
		wantInserted string
	}{
		{
			name:         "LF document",
			source:       "top\nbottom",
			input:        "x\r\ny\rz\n",
			wantText:     "top\nx\ny\nz\nbottom",
			wantInserted: "x\ny\nz\n",
		},
		{
			name:         "CRLF document",
			source:       "top\r\nbottom",
			input:        "x\ny\rz\r\n",
			wantText:     "top\r\nx\r\ny\r\nz\r\nbottom",
			wantInserted: "x\r\ny\r\nz\r\n",
		},
		{
			name:         "first of mixed endings wins",
			source:       "top\nmiddle\r\nbottom",
			input:        "x\r\ny",
			wantText:     "top\nmiddle\r\nx\nybottom",
			wantInserted: "x\ny",
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			app, id := clipboardTestApplication([]byte(test.source), "text")
			doc := app.Documents[id]
			position := strings.Index(test.source, "bottom")
			applied, err := app.PasteDocument(id, doc.Revision(), position, position, []byte(test.input), position, position)
			if err != nil {
				t.Fatalf("PasteDocument: %v", err)
			}
			if got := string(doc.Editor.Buffer.Text()); got != test.wantText {
				t.Fatalf("pasted bytes = %q, want %q", got, test.wantText)
			}
			if got := string(applied.Replacement); got != test.wantInserted {
				t.Fatalf("normalized acknowledgement replacement = %q", got)
			}
		})
	}
}

func TestPasteDocumentSmartURLUsesUnsavedMarkdownAndEscapesUTF8Label(t *testing.T) {
	app, id := clipboardTestApplication([]byte("seed"), "markdown")
	doc := app.Documents[id]
	if err := doc.Replace(0, doc.Editor.Buffer.ByteLen(), []byte("unsaved Café [label] & *bold*")); err != nil {
		t.Fatalf("prepare unsaved source: %v", err)
	}
	unsaved := "unsaved Café [label] & *bold*"
	start := len("unsaved ")
	end := len(unsaved)
	doc.Editor.SetSelection(end, start) // preserve a reverse selection in Undo.
	clipboard := []byte("https://example.com/a(b)?q=caf%C3%A9")
	url := string(clipboard)
	got, err := app.PasteDocument(id, doc.Revision(), start, end, clipboard, end, start)
	if err != nil {
		t.Fatalf("PasteDocument: %v", err)
	}
	wantReplacement := "[Café \\[label\\] &amp; \\*bold\\*](<" + url + ">)"
	if string(got.Replacement) != wantReplacement {
		t.Fatalf("smart replacement = %q, want %q", got.Replacement, wantReplacement)
	}
	if source := string(doc.Editor.Buffer.Text()); source != "unsaved "+wantReplacement {
		t.Fatalf("pasted source = %q, want unsaved Markdown source plus smart link", source)
	}
	if doc.Editor.Cursor != start+len(wantReplacement) || doc.Editor.Anchor != doc.Editor.Cursor {
		t.Fatalf("post-paste selection = anchor %d cursor %d, want collapsed after link", doc.Editor.Anchor, doc.Editor.Cursor)
	}
	if err := doc.Undo(); err != nil {
		t.Fatalf("Undo: %v", err)
	}
	if source := string(doc.Editor.Buffer.Text()); source != unsaved {
		t.Fatalf("one Undo restored %q, want pre-paste unsaved bytes %q", source, unsaved)
	}
	if doc.Editor.Anchor != end || doc.Editor.Cursor != start {
		t.Fatalf("Undo selection = anchor %d cursor %d, want restored reverse selection %d:%d", doc.Editor.Anchor, doc.Editor.Cursor, end, start)
	}
}

func TestPasteDocumentUsesPlainClipboardTextOutsideMarkdownOrForNonURL(t *testing.T) {
	tests := []struct {
		name       string
		language   string
		clipboard  string
		emptyRange bool
	}{
		{name: "plain text document", language: "go", clipboard: "https://example.com"},
		{name: "unsupported scheme", language: "markdown", clipboard: "javascript:alert(1)"},
		{name: "URL with whitespace", language: "markdown", clipboard: "https://example.com/a b"},
		{name: "missing host", language: "markdown", clipboard: "https:///missing-host"},
		{name: "userinfo URL", language: "markdown", clipboard: "https://user@example.com/path"},
		{name: "malformed percent escape", language: "markdown", clipboard: "https://example.com/%zz"},
		{name: "malformed DNS host", language: "markdown", clipboard: "https://example..com/path"},
		{name: "invalid port", language: "markdown", clipboard: "https://example.com:70000/path"},
		{name: "ordinary text", language: "markdown", clipboard: "<b>clipboard text</b>"},
		{name: "empty selection", language: "markdown", clipboard: "https://example.com", emptyRange: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			app, id := clipboardTestApplication([]byte("replace me"), test.language)
			doc := app.Documents[id]
			start, end := len("replace "), len("replace me")
			if test.emptyRange {
				start, end = len("replace me"), len("replace me")
			}
			applied, err := app.PasteDocument(id, doc.Revision(), start, end, []byte(test.clipboard), end, start)
			if err != nil {
				t.Fatalf("PasteDocument: %v", err)
			}
			if string(applied.Replacement) != test.clipboard {
				t.Fatalf("plain replacement = %q, want exact clipboard text %q", applied.Replacement, test.clipboard)
			}
			want := "replace " + test.clipboard
			if test.emptyRange {
				want = "replace me" + test.clipboard
			}
			if string(doc.Editor.Buffer.Text()) != want {
				t.Fatalf("plain paste source = %q, want %q", doc.Editor.Buffer.Text(), want)
			}
		})
	}
}

func TestPasteDocumentKeepsMultilineAndInvalidUTF8SelectionsOnPlainPastePath(t *testing.T) {
	for _, selection := range [][]byte{[]byte("first\nsecond"), {0xff, 'x'}} {
		app, id := clipboardTestApplication(append([]byte(nil), selection...), "markdown")
		doc := app.Documents[id]
		url := []byte("https://example.com/path")
		applied, err := app.PasteDocument(id, doc.Revision(), 0, len(selection), url, len(selection), 0)
		if err != nil {
			t.Fatalf("PasteDocument(selection %q): %v", selection, err)
		}
		if string(applied.Replacement) != string(url) {
			t.Fatalf("selection %q unexpectedly became a Markdown link: %q", selection, applied.Replacement)
		}
	}
}

func TestPasteDocumentEmptyClipboardDoesNotDeleteSelection(t *testing.T) {
	app, id := clipboardTestApplication([]byte("keep selected bytes"), "markdown")
	doc := app.Documents[id]
	before := doc.Revision()
	applied, err := app.PasteDocument(id, before, 5, len("keep selected bytes"), nil, len("keep selected bytes"), 5)
	if err != nil {
		t.Fatalf("PasteDocument(empty clipboard): %v", err)
	}
	if got := string(doc.Editor.Buffer.Text()); got != "keep selected bytes" {
		t.Fatalf("empty clipboard paste changed source to %q", got)
	}
	if doc.Revision() != before || applied.SourceEdit.BeforeRevision != before || applied.SourceEdit.AfterRevision != before {
		t.Fatalf("empty clipboard paste should not advance revision: result=%+v revision=%d", applied, doc.Revision())
	}
}

func TestPasteDocumentSmartLinkRespects128KiBEditPayloadBoundary(t *testing.T) {
	url := []byte("https://x.io")
	exactLimitSelectionLength := (clipboardSmartLinkMaxBytes - 4 - len(url)) / 2
	if remaining := clipboardSmartLinkMaxBytes - 4 - len(url) - 2*exactLimitSelectionLength; remaining != 0 {
		t.Fatalf("fixture cannot reach exact boundary; remaining bytes = %d", remaining)
	}

	for _, test := range []struct {
		name                string
		selectionLength     int
		wantSmartLink       bool
		wantReplacementSize int
	}{
		{name: "exactly at limit", selectionLength: exactLimitSelectionLength, wantSmartLink: true, wantReplacementSize: clipboardSmartLinkMaxBytes},
		{name: "one byte over after escaping", selectionLength: exactLimitSelectionLength + 1, wantSmartLink: false, wantReplacementSize: len(url)},
	} {
		t.Run(test.name, func(t *testing.T) {
			source := []byte(strings.Repeat("*", test.selectionLength))
			app, id := clipboardTestApplication(source, "markdown")
			doc := app.Documents[id]
			applied, err := app.PasteDocument(id, doc.Revision(), 0, len(source), url, len(source), 0)
			if err != nil {
				t.Fatalf("PasteDocument: %v", err)
			}
			if len(applied.Replacement) != test.wantReplacementSize {
				t.Fatalf("replacement size = %d, want %d", len(applied.Replacement), test.wantReplacementSize)
			}
			if linked := strings.HasPrefix(string(applied.Replacement), "["); linked != test.wantSmartLink {
				t.Fatalf("smart-link conversion = %v, want %v", linked, test.wantSmartLink)
			}
			if !test.wantSmartLink && string(applied.Replacement) != string(url) {
				t.Fatalf("oversized smart link should fall back to exact clipboard URL, got %q", applied.Replacement)
			}
		})
	}
}

func TestPasteDocumentSmartURLUsesPlainMarkdownDestinationWhenUnambiguous(t *testing.T) {
	app, id := clipboardTestApplication([]byte("Alicorn"), "markdown")
	doc := app.Documents[id]
	result, err := app.PasteDocument(id, doc.Revision(), 0, len("Alicorn"), []byte("https://example.com"), len("Alicorn"), 0)
	if err != nil {
		t.Fatalf("PasteDocument: %v", err)
	}
	if got, want := string(result.Replacement), "[Alicorn](https://example.com)"; got != want {
		t.Fatalf("smart link source = %q, want %q", got, want)
	}
}

func TestPasteDocumentRejectsStaleRevisionAndInvalidRangesWithoutMutation(t *testing.T) {
	app, id := clipboardTestApplication([]byte("authoritative"), "markdown")
	doc := app.Documents[id]
	initial := string(doc.Editor.Buffer.Text())
	if _, err := app.PasteDocument(id, doc.Revision()+1, 0, 4, []byte("https://example.com"), 0, 4); !errors.Is(err, ErrStaleEditorRevision) {
		t.Fatalf("stale paste error = %v, want ErrStaleEditorRevision", err)
	}
	for _, bounds := range [][2]int{{-1, 0}, {4, 3}, {0, len(initial) + 1}} {
		if _, err := app.PasteDocument(id, doc.Revision(), bounds[0], bounds[1], []byte("text"), 0, 0); err == nil {
			t.Fatalf("invalid range %v unexpectedly succeeded", bounds)
		}
		if got := string(doc.Editor.Buffer.Text()); got != initial {
			t.Fatalf("invalid range %v mutated source to %q", bounds, got)
		}
	}
}
