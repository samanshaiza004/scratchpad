package editor

import (
	"bytes"
	"math/rand"
	"testing"
)

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

func TestBufferLineAtMatchesLineRanges(t *testing.T) {
	b := NewBuffer([]byte("one\ntwo\nthree"))
	want := []int{0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2}
	for offset, line := range want {
		got, ok := b.LineAt(offset)
		if !ok || got != line {
			t.Fatalf("LineAt(%d) = %d, %v, want %d, true", offset, got, ok, line)
		}
	}
	if _, ok := b.LineAt(-1); ok {
		t.Fatal("LineAt(-1) succeeded")
	}
	if _, ok := b.LineAt(b.ByteLen() + 1); ok {
		t.Fatal("LineAt(end+1) succeeded")
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
	if b.PieceCount() != 3 {
		t.Fatalf("pieces = %d, want 3", b.PieceCount())
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

func TestTreeBufferLineCursor(t *testing.T) {
	b := NewBuffer([]byte("one\ntwo\n\nthree"))
	cursor, ok := b.NewLineCursor(0)
	if !ok {
		t.Fatal("new line cursor failed")
	}
	for line := 0; ; line++ {
		got, ok := cursor.Line()
		if !ok {
			t.Fatalf("line cursor %d invalid", line)
		}
		want, _ := b.Line(line)
		if got != want {
			t.Fatalf("cursor line %d = %q, want %q", line, got, want)
		}
		if line+1 == b.LineCount() {
			if cursor.Next() {
				t.Fatal("cursor advanced past last line")
			}
			break
		}
		if !cursor.Next() {
			t.Fatalf("cursor stopped before line %d", line+1)
		}
	}
}

// sliceOracle retains the former linear piece sequence as test-only storage.
// It is intentionally not used by the application; it exists to differential
// test the balanced Buffer against the implementation it replaced.
type sliceOracle struct {
	original []byte
	added    []byte
	pieces   []piece
	bytes    int
	newlines int
}

func newSliceOracle(source []byte) sliceOracle {
	o := sliceOracle{original: append([]byte(nil), source...), bytes: len(source)}
	if len(source) > 0 {
		o.pieces = []piece{{source: originalSource, length: len(source), newlines: bytes.Count(source, []byte{'\n'})}}
		o.newlines = o.pieces[0].newlines
	}
	return o
}

func (o *sliceOracle) insert(at int, text []byte) {
	start := len(o.added)
	o.added = append(o.added, text...)
	index := o.splitAt(at)
	o.pieces = append(o.pieces, piece{})
	copy(o.pieces[index+1:], o.pieces[index:])
	o.pieces[index] = piece{source: addedSource, start: start, length: len(text), newlines: bytes.Count(text, []byte{'\n'})}
	o.bytes += len(text)
	o.newlines += bytes.Count(text, []byte{'\n'})
}

func (o *sliceOracle) delete(start, end int) {
	from := o.splitAt(start)
	to := o.splitAt(end)
	for _, p := range o.pieces[from:to] {
		o.newlines -= p.newlines
	}
	o.pieces = append(o.pieces[:from], o.pieces[to:]...)
	o.bytes -= end - start
}

func (o *sliceOracle) text() []byte { return o.slice(0, o.bytes) }

func (o *sliceOracle) lines() int { return o.newlines + 1 }

func (o *sliceOracle) line(line int) []byte {
	start := 0
	for i := 0; i < line; i++ {
		start += bytes.IndexByte(o.text()[start:], '\n') + 1
	}
	end := bytes.IndexByte(o.text()[start:], '\n')
	if end < 0 {
		end = o.bytes - start
	}
	return o.text()[start : start+end]
}

func (o *sliceOracle) splitAt(at int) int {
	if at <= 0 {
		return 0
	}
	if at >= o.bytes {
		return len(o.pieces)
	}
	offset := 0
	for i, p := range o.pieces {
		if at == offset {
			return i
		}
		if at < offset+p.length {
			leftLength := at - offset
			left := p
			left.length = leftLength
			left.newlines = bytes.Count(o.pieceBytes(p)[:leftLength], []byte{'\n'})
			right := p
			right.start += leftLength
			right.length -= leftLength
			right.newlines -= left.newlines
			o.pieces = append(o.pieces, piece{})
			copy(o.pieces[i+2:], o.pieces[i+1:])
			o.pieces[i] = left
			o.pieces[i+1] = right
			return i + 1
		}
		offset += p.length
	}
	return len(o.pieces)
}

func (o *sliceOracle) pieceBytes(p piece) []byte {
	if p.source == originalSource {
		return o.original[p.start : p.start+p.length]
	}
	return o.added[p.start : p.start+p.length]
}

func (o *sliceOracle) slice(start, end int) []byte {
	out := make([]byte, 0, end-start)
	offset := 0
	for _, p := range o.pieces {
		pieceEnd := offset + p.length
		if pieceEnd <= start {
			offset = pieceEnd
			continue
		}
		if offset >= end {
			break
		}
		from := 0
		if start > offset {
			from = start - offset
		}
		to := p.length
		if end < pieceEnd {
			to = end - offset
		}
		out = append(out, o.pieceBytes(p)[from:to]...)
		offset = pieceEnd
	}
	return out
}

func TestTreeBufferDifferentialAgainstSliceOracle(t *testing.T) {
	source := []byte("one\ntwo\nthree\nfour\n")
	b := NewBuffer(source)
	o := newSliceOracle(source)
	rng := rand.New(rand.NewSource(0x53435241544348))
	insertions := [][]byte{[]byte("x"), []byte("\n"), []byte("ab\n"), []byte("é")}

	for step := 0; step < 5000; step++ {
		at := rng.Intn(o.bytes + 1)
		if rng.Intn(3) == 0 || o.bytes == 0 {
			text := insertions[rng.Intn(len(insertions))]
			if err := b.Insert(at, text); err != nil {
				t.Fatal(err)
			}
			o.insert(at, text)
		} else {
			end := at + rng.Intn(8)
			if end > o.bytes {
				end = o.bytes
			}
			if err := b.Delete(at, end); err != nil {
				t.Fatal(err)
			}
			o.delete(at, end)
		}

		if !bytes.Equal(b.Text(), o.text()) {
			t.Fatalf("step %d text mismatch", step)
		}
		if b.LineCount() != o.lines() {
			t.Fatalf("step %d line count = %d, want %d", step, b.LineCount(), o.lines())
		}
		if step%17 == 0 {
			for line := 0; line < o.lines(); line++ {
				got, _ := b.Line(line)
				if !bytes.Equal([]byte(got), o.line(line)) {
					t.Fatalf("step %d line %d = %q, want %q", step, line, got, o.line(line))
				}
			}
		}
	}
	checkTreeInvariants(t, b.root)
	cursor, ok := b.NewLineCursor(0)
	if !ok {
		t.Fatal("fragmented line cursor failed")
	}
	for line := 0; ; line++ {
		got, ok := cursor.Line()
		if !ok {
			t.Fatalf("fragmented cursor line %d invalid", line)
		}
		want, _ := b.Line(line)
		if got != want {
			t.Fatalf("fragmented cursor line %d = %q, want %q", line, got, want)
		}
		if line+1 == b.LineCount() {
			break
		}
		if !cursor.Next() {
			t.Fatalf("fragmented cursor stopped before line %d", line+1)
		}
	}
}

func checkTreeInvariants(t *testing.T, n *pieceNode) (bytes, newlines, pieces int) {
	t.Helper()
	if n == nil {
		return 0, 0, 0
	}
	leftBytes, leftNewlines, leftPieces := checkTreeInvariants(t, n.left)
	rightBytes, rightNewlines, rightPieces := checkTreeInvariants(t, n.right)
	if n.left != nil && n.left.priority > n.priority {
		t.Fatalf("left heap invariant violated")
	}
	if n.right != nil && n.right.priority > n.priority {
		t.Fatalf("right heap invariant violated")
	}
	wantBytes := leftBytes + n.piece.length + rightBytes
	wantNewlines := leftNewlines + n.piece.newlines + rightNewlines
	wantPieces := leftPieces + 1 + rightPieces
	if n.bytes != wantBytes || n.newlines != wantNewlines || n.pieces != wantPieces {
		t.Fatalf("node summary = (%d,%d,%d), want (%d,%d,%d)", n.bytes, n.newlines, n.pieces, wantBytes, wantNewlines, wantPieces)
	}
	return wantBytes, wantNewlines, wantPieces
}
