package editor

import "testing"

func TestPieceBufferInsertDeleteAndLines(t *testing.T) {
	e := NewScratchEditor([]byte("one\ntwo\nthree"))
	e.SetCursor(4)
	if err := e.Insert([]byte("X\n")); err != nil {
		t.Fatal(err)
	}
	if got := string(e.Buffer.Text()); got != "one\nX\ntwo\nthree" {
		t.Fatalf("text = %q", got)
	}
	if e.Buffer.LineCount() != 4 {
		t.Fatalf("line count = %d, want 4", e.Buffer.LineCount())
	}
	if got, _ := e.Buffer.Line(1); got != "X" {
		t.Fatalf("line 1 = %q", got)
	}

	e.SetSelection(4, 6)
	if err := e.Insert([]byte("Y")); err != nil {
		t.Fatal(err)
	}
	if got := string(e.Buffer.Text()); got != "one\nYtwo\nthree" {
		t.Fatalf("selection replace = %q", got)
	}
}

func TestLargeInsertDoesNotFlattenOriginal(t *testing.T) {
	source := make([]byte, 1<<20)
	for i := range source {
		source[i] = 'a'
	}
	b := NewBuffer(source)
	if err := b.Insert(900<<10, []byte("x")); err != nil {
		t.Fatal(err)
	}
	if b.ByteLen() != (1<<20)+1 {
		t.Fatalf("byte length = %d", b.ByteLen())
	}
	if len(b.pieces) != 3 {
		t.Fatalf("pieces = %d, want 3", len(b.pieces))
	}
}

func TestEditorClipboardUndoRedoAndClusters(t *testing.T) {
	e := NewScratchEditor([]byte("a\u0301 👩‍💻 שלום"))
	e.SetCursor(len([]byte("a\u0301")))
	e.MoveLeft(false)
	if got := e.Cursor; got != 0 {
		t.Fatalf("combining cluster moved to byte %d, want 0", got)
	}
	e.MoveRight(false)
	if got := e.Cursor; got != len([]byte("a\u0301")) {
		t.Fatalf("combining cluster moved to byte %d, want %d", got, len([]byte("a\u0301")))
	}

	e.SetSelection(0, len([]byte("a\u0301")))
	if got := e.Copy(); got != "a\u0301" {
		t.Fatalf("copy = %q", got)
	}
	cut, err := e.Cut()
	if err != nil || cut != "a\u0301" {
		t.Fatalf("cut = %q, %v", cut, err)
	}
	if err := e.Paste("x"); err != nil {
		t.Fatal(err)
	}
	if err := e.Undo(); err != nil || string(e.Buffer.Text()) != " 👩‍💻 שלום" {
		t.Fatalf("undo text = %q, err=%v", e.Buffer.Text(), err)
	}
	if err := e.Redo(); err != nil || string(e.Buffer.Text()) != "x 👩‍💻 שלום" {
		t.Fatalf("redo text = %q, err=%v", e.Buffer.Text(), err)
	}

	e = NewScratchEditor([]byte("a\u0301 👩‍💻"))
	e.SetCursor(len([]byte("a\u0301 👩‍💻")))
	if err := e.Backspace(); err != nil || string(e.Buffer.Text()) != "a\u0301 " {
		t.Fatalf("cluster backspace = %q, err=%v", e.Buffer.Text(), err)
	}
}

func TestEditorCompositionAndBidiAffinity(t *testing.T) {
	e := NewScratchEditor([]byte("שלום"))
	e.SetCursor(0)
	e.BeginComposition("かな", [2]int{1, 2})
	if got := e.Composition(); got.Text != "かな" || got.Sel != [2]int{1, 2} {
		t.Fatalf("composition = %+v", got)
	}
	if err := e.CommitComposition(); err != nil {
		t.Fatal(err)
	}
	if string(e.Buffer.Text()) != "かなשלום" {
		t.Fatalf("composition commit = %q", e.Buffer.Text())
	}
	e.SetAffinity(AffinityTrailing)
	if e.DirectionAt() != DirectionRTL {
		t.Fatalf("direction at RTL text = %v", e.DirectionAt())
	}
	if e.Affinity != AffinityTrailing {
		t.Fatalf("affinity = %v", e.Affinity)
	}
}

func TestEditorSelectionDeletionHitTestingAndCompositionCancel(t *testing.T) {
	e := NewScratchEditor([]byte("one\ntwo"))
	e.SetSelection(4, 1)
	if from, to := e.selection(); from != 1 || to != 4 {
		t.Fatalf("selection = %d:%d, want 1:4", from, to)
	}
	if got := e.Copy(); got != "ne\n" {
		t.Fatalf("copy = %q", got)
	}
	if err := e.DeleteForward(); err != nil {
		t.Fatal(err)
	}
	if got := string(e.Buffer.Text()); got != "otwo" {
		t.Fatalf("selection delete = %q", got)
	}
	if err := e.Undo(); err != nil || string(e.Buffer.Text()) != "one\ntwo" {
		t.Fatalf("undo deletion = %q, err=%v", e.Buffer.Text(), err)
	}

	e.SetCursor(0)
	if at, ok := e.HitTest(1, 2, AffinityTrailing); !ok || at != len("one\n")+2 {
		t.Fatalf("hit test = %d, %v", at, ok)
	}
	if e.Affinity != AffinityTrailing {
		t.Fatalf("hit-test affinity = %v", e.Affinity)
	}
	e.BeginComposition("仮", [2]int{0, 1})
	e.CancelComposition()
	if got := e.Composition(); got != (Composition{}) {
		t.Fatalf("cancelled composition = %+v", got)
	}
}

func TestEditorOffsetsSnapToUTF8Boundaries(t *testing.T) {
	e := NewScratchEditor([]byte("éx"))
	e.SetCursor(1)
	if e.Cursor != 0 {
		t.Fatalf("cursor in multibyte rune = %d, want 0", e.Cursor)
	}
	e.SetSelection(1, 3)
	if e.Anchor != 0 || e.Cursor != 3 {
		t.Fatalf("selection boundaries = %d:%d, want 0:3", e.Anchor, e.Cursor)
	}
}
