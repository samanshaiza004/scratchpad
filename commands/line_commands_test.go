package commands

import (
	"strings"
	"testing"
)

func executeLineCommand(t *testing.T, id ID, source string, cursor, anchor int) (string, Outcome) {
	t.Helper()
	request := Request{
		ID: id, Source: []byte(source), Cursor: cursor, Anchor: anchor,
		RootLanguage: "markdown",
	}
	out := Execute(request)
	if out.Status != ResultExecuted {
		t.Fatalf("%s outcome = %#v; want executed", id, out)
	}
	result := source[:out.Start] + string(out.Replacement) + source[out.End:]
	return result, out
}

func TestLineIndentAndOutdentOperateOnTouchedLines(t *testing.T) {
	source := "one\n  two\nthree"
	got, out := executeLineCommand(t, EditIndentLines, source, len("one\n  two"), 0)
	if got != "\tone\n\t  two\nthree" {
		t.Fatalf("indented source = %q", got)
	}
	if out.Start != 0 || out.End != len("one\n  two\n") {
		t.Fatalf("indent replacement range = %#v", out)
	}

	got, _ = executeLineCommand(t, EditOutdentLines, "\tone\n    two\nthree", len("\tone\n    two"), 0)
	if got != "one\ntwo\nthree" {
		t.Fatalf("outdented source = %q", got)
	}
}

func TestDeleteLinePreservesSingleReplacementLineSemantics(t *testing.T) {
	got, out := executeLineCommand(t, EditDeleteLine, "a\nb\nc", 2, 2)
	if got != "a\nc" || out.Start != 2 || out.End != 4 || len(out.Replacement) != 0 {
		t.Fatalf("middle-line deletion = %q, %#v", got, out)
	}
	got, _ = executeLineCommand(t, EditDeleteLine, "a\nb", len("a\nb"), len("a\nb"))
	if got != "a\n" {
		t.Fatalf("final-line deletion = %q; want trailing blank line", got)
	}
}

func TestInsertLineAboveAndBelowUseDocumentNewline(t *testing.T) {
	got, out := executeLineCommand(t, EditInsertLineAbove, "a\nb", 2, 2)
	if got != "a\n\nb" || out.Cursor != 2 || out.Anchor != 2 {
		t.Fatalf("insert above = %q, %#v", got, out)
	}
	got, out = executeLineCommand(t, EditInsertLineBelow, "a\nb", 0, 0)
	if got != "a\n\nb" || out.Cursor != 2 || out.Anchor != 2 {
		t.Fatalf("insert below = %q, %#v", got, out)
	}
	got, _ = executeLineCommand(t, EditInsertLineBelow, "a\r\nb", 0, 0)
	if got != "a\r\n\r\nb" {
		t.Fatalf("CRLF insert below = %q", got)
	}
}

func TestMoveAndDuplicateLinesKeepTheSelectionWithTheLine(t *testing.T) {
	source := "a\nb\nc"
	got, out := executeLineCommand(t, EditMoveLineUp, source, 3, 2)
	if got != "b\na\nc" || out.Cursor != 1 || out.Anchor != 0 {
		t.Fatalf("move up = %q, %#v", got, out)
	}
	got, out = executeLineCommand(t, EditMoveLineDown, source, 3, 2)
	if got != "a\nc\nb" || out.Cursor != 5 || out.Anchor != 4 {
		t.Fatalf("move down = %q, %#v", got, out)
	}
	got, out = executeLineCommand(t, EditDuplicateLine, source, 3, 2)
	if got != "a\nb\nb\nc" || out.Cursor != 5 || out.Anchor != 4 {
		t.Fatalf("duplicate = %q, %#v", got, out)
	}
}

func TestJoinLinesTrimsOnlyJoinWhitespace(t *testing.T) {
	source := "left  \n\t right\nlast"
	got, out := executeLineCommand(t, EditJoinLines, source, 2, 2)
	if got != "left right\nlast" {
		t.Fatalf("joined source = %q", got)
	}
	if out.Start != 0 || out.End != len("left  \n\t right\n") {
		t.Fatalf("join replacement range = %#v", out)
	}

	// A selected block is joined as a block, rather than implicitly consuming
	// the following line.
	selectedEnd := strings.Index(source, "last")
	got, _ = executeLineCommand(t, EditJoinLines, source, selectedEnd, 0)
	if got != "left right\nlast" {
		t.Fatalf("selected join changed following line = %q", got)
	}
}

func TestLineCommandsAreRegisteredForFocusedCodeAndFenceContexts(t *testing.T) {
	registry := DefaultRegistry()
	code := CommandContext{ActiveDocument: true, Code: true, RootLanguage: "go", EditorFocused: true}
	for _, id := range []ID{EditIndentLines, EditOutdentLines, EditDeleteLine, EditInsertLineAbove, EditInsertLineBelow, EditMoveLineUp, EditMoveLineDown, EditDuplicateLine, EditJoinLines} {
		descriptor, ok := registry.Lookup(id)
		if !ok || !descriptor.IsEnabled(code) {
			t.Fatalf("%s is not enabled in code context", id)
		}
	}
	if got := Execute(Request{ID: EditIndentLines, RootLanguage: "go", Source: []byte("x"), Cursor: 1, Anchor: 1}); got.Status != ResultExecuted {
		t.Fatalf("code indent = %#v; want executed", got)
	}
	if got := Execute(Request{ID: EditIndentLines, RootLanguage: "markdown", InFence: true, Source: []byte("x"), Cursor: 1, Anchor: 1}); got.Status != ResultExecuted {
		t.Fatalf("fenced indent = %#v; want executed", got)
	}
}
