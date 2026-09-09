package editor

import (
	"bytes"
	"testing"
)

func TestEditorDocumentBoundaryAndPageSelection(t *testing.T) {
	e := NewScratchEditor([]byte("zero\none\ntwo\nthree"))
	documentEnd := len([]byte("zero\none\ntwo\nthree"))
	e.SetCursor(documentEnd)
	e.MoveDocumentStart(true)
	if e.Cursor != 0 || e.Anchor != documentEnd {
		t.Fatalf("document-start selection = %d:%d", e.Anchor, e.Cursor)
	}
	e.SetCursor(documentEnd)
	e.PageUp(2, true)
	wantCursor := len([]byte("zero\none"))
	if e.Cursor != wantCursor || e.Anchor != documentEnd {
		t.Fatalf("page-up selection = %d:%d, want %d:%d", e.Anchor, e.Cursor, documentEnd, wantCursor)
	}
	e.PageDown(1, true)
	if e.Cursor != len([]byte("zero\none\ntwo")) || e.Anchor != documentEnd {
		t.Fatalf("shift page-down selection = %d:%d", e.Anchor, e.Cursor)
	}
	e.MoveDocumentEnd(false)
	if e.Cursor != e.Buffer.ByteLen() || e.Anchor != e.Cursor {
		t.Fatalf("document-end caret = %d:%d", e.Anchor, e.Cursor)
	}
}

func TestEditorEnterPreservesIndentAndUndo(t *testing.T) {
	e := NewScratchEditor([]byte("  αβ"))
	e.SetCursor(e.Buffer.ByteLen())
	if err := e.Insert([]byte{'\n'}); err != nil {
		t.Fatal(err)
	}
	if got := e.Buffer.Text(); !bytes.Equal(got, []byte("  αβ\n  ")) {
		t.Fatalf("indented Enter = %q", got)
	}
	if e.Cursor != e.Buffer.ByteLen() {
		t.Fatalf("Enter cursor = %d, want %d", e.Cursor, e.Buffer.ByteLen())
	}
	if err := e.Undo(); err != nil || string(e.Buffer.Text()) != "  αβ" {
		t.Fatalf("undo Enter = %q, err=%v", e.Buffer.Text(), err)
	}
}

func TestEditorLineIndentOutdentAndWholeLineClipboard(t *testing.T) {
	e := NewScratchEditor([]byte("one\n\ttwo\nthree"))
	e.SetSelection(0, len([]byte("one\n\ttwo\n")))
	if err := e.Indent("  "); err != nil {
		t.Fatal(err)
	}
	if got := string(e.Buffer.Text()); got != "  one\n  \ttwo\nthree" {
		t.Fatalf("indent = %q", got)
	}
	if err := e.Outdent("  "); err != nil {
		t.Fatal(err)
	}
	if got := string(e.Buffer.Text()); got != "one\n\ttwo\nthree" {
		t.Fatalf("outdent = %q", got)
	}
	e.SetCursor(len([]byte("one\n")))
	if got := e.Copy(); got != "\ttwo\n" {
		t.Fatalf("whole-line copy = %q", got)
	}
	cut, err := e.Cut()
	if err != nil || cut != "\ttwo\n" || string(e.Buffer.Text()) != "one\nthree" {
		t.Fatalf("whole-line cut = %q, text=%q, err=%v", cut, e.Buffer.Text(), err)
	}
	if err := e.Undo(); err != nil || string(e.Buffer.Text()) != "one\n\ttwo\nthree" {
		t.Fatalf("undo whole-line cut = %q, err=%v", e.Buffer.Text(), err)
	}
}

func TestEditorDeleteInsertMoveAndDuplicateLines(t *testing.T) {
	e := NewScratchEditor([]byte("a\nbb\nc"))
	e.SetCursor(3)
	if err := e.MoveLineUp(); err != nil || string(e.Buffer.Text()) != "bb\na\nc" || e.Cursor != 1 {
		t.Fatalf("move line up = %q at %d, err=%v", e.Buffer.Text(), e.Cursor, err)
	}
	if err := e.MoveLineDown(); err != nil || string(e.Buffer.Text()) != "a\nbb\nc" || e.Cursor != 3 {
		t.Fatalf("move line down = %q at %d, err=%v", e.Buffer.Text(), e.Cursor, err)
	}
	if err := e.DuplicateLineDown(); err != nil || string(e.Buffer.Text()) != "a\nbb\nbb\nc" {
		t.Fatalf("duplicate line down = %q, err=%v", e.Buffer.Text(), err)
	}
	if err := e.InsertLineAbove(); err != nil || string(e.Buffer.Text()) != "a\nbb\n\nbb\nc" {
		t.Fatalf("insert line above = %q, err=%v", e.Buffer.Text(), err)
	}
	e = NewScratchEditor([]byte("a\nbb\nc"))
	e.SetCursor(3)
	if err := e.DeleteLine(); err != nil || string(e.Buffer.Text()) != "a\nc" {
		t.Fatalf("delete line = %q, err=%v", e.Buffer.Text(), err)
	}
}

func TestEditorJoinLinesAndSelection(t *testing.T) {
	e := NewScratchEditor([]byte("one\n  two\nthree"))
	e.SetCursor(1)
	if err := e.JoinLines(); err != nil || string(e.Buffer.Text()) != "one two\nthree" || e.Cursor != 4 {
		t.Fatalf("join current line = %q at %d, err=%v", e.Buffer.Text(), e.Cursor, err)
	}
	e.SetSelection(0, len([]byte("one two\n")))
	if err := e.JoinLines(); err != nil || string(e.Buffer.Text()) != "one two three" {
		t.Fatalf("join selected lines = %q, err=%v", e.Buffer.Text(), err)
	}
	if err := e.Undo(); err != nil || string(e.Buffer.Text()) != "one two\nthree" {
		t.Fatalf("undo join = %q, err=%v", e.Buffer.Text(), err)
	}
}
