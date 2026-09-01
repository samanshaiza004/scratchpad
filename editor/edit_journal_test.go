package editor

import "testing"

func TestSourceEditRecordsUTF8BytePoints(t *testing.T) {
	e := NewScratchEditor([]byte("ab\ncd"))
	e.SetCursor(1)
	if err := e.Insert([]byte("X\né")); err != nil {
		t.Fatal(err)
	}
	if len(e.editJournal) != 1 {
		t.Fatalf("journal length = %d, want 1", len(e.editJournal))
	}
	edit := e.editJournal[0]
	if edit.BeforeRevision != 0 || edit.AfterRevision != 1 {
		t.Fatalf("revisions = %d -> %d, want 0 -> 1", edit.BeforeRevision, edit.AfterRevision)
	}
	if edit.StartByte != 1 || edit.OldEndByte != 1 || edit.NewEndByte != 5 {
		t.Fatalf("byte range = %d..%d -> %d, want 1..1 -> 5", edit.StartByte, edit.OldEndByte, edit.NewEndByte)
	}
	if edit.StartPoint != (BytePoint{Row: 0, Column: 1}) || edit.OldEndPoint != edit.StartPoint {
		t.Fatalf("old points = %#v..%#v", edit.StartPoint, edit.OldEndPoint)
	}
	if edit.NewEndPoint != (BytePoint{Row: 1, Column: 2}) {
		t.Fatalf("new end point = %#v, want row 1 byte column 2", edit.NewEndPoint)
	}
}

func TestEditsSinceTracksUndoRedoAndDivergence(t *testing.T) {
	e := NewScratchEditor([]byte("abc"))
	e.SetCursor(1)
	if err := e.Insert([]byte("X")); err != nil {
		t.Fatal(err)
	}
	if err := e.Undo(); err != nil {
		t.Fatal(err)
	}
	if err := e.Redo(); err != nil {
		t.Fatal(err)
	}
	chain, ok := e.EditsSince(0)
	if ok {
		t.Fatalf("revisited revision should require a fresh parse, got %#v", chain)
	}
	if len(e.editJournal) != 3 {
		t.Fatalf("journal length = %d, want 3 after insert/undo/redo", len(e.editJournal))
	}

	if err := e.Undo(); err != nil {
		t.Fatal(err)
	}
	e.SetCursor(1)
	if err := e.Insert([]byte("Y")); err != nil {
		t.Fatal(err)
	}
	chain, ok = e.EditsSince(0)
	if ok {
		t.Fatalf("divergent history should require a fresh parse, got %#v", chain)
	}
	if len(e.editJournal) != 5 {
		t.Fatalf("journal length = %d, want 5 after divergent edit", len(e.editJournal))
	}
}

func TestEditJournalFallsBackAfterEviction(t *testing.T) {
	e := NewScratchEditor(nil)
	for i := 0; i < editJournalCapacity+1; i++ {
		e.SetCursor(e.Buffer.ByteLen())
		if err := e.Insert([]byte("x")); err != nil {
			t.Fatal(err)
		}
	}
	if _, ok := e.EditsSince(0); ok {
		t.Fatal("evicted edit chain should require a fresh parse")
	}
}
