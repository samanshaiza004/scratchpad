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
