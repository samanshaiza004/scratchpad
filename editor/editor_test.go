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

func TestBufferSnapshotSurvivesLaterEditsAndAddedStoreGrowth(t *testing.T) {
	b := NewBuffer([]byte("alpha\nbeta\n"))
	if err := b.Insert(b.ByteLen(), []byte("first")); err != nil {
		t.Fatal(err)
	}
	snapshot := b.Snapshot()
	if err := b.Insert(0, []byte("prefix ")); err != nil {
		t.Fatal(err)
	}
	if err := b.Insert(b.ByteLen(), []byte(" tail")); err != nil {
		t.Fatal(err)
	}
	if got := string(snapshot.Materialize()); got != "alpha\nbeta\nfirst" {
		t.Fatalf("snapshot changed after edits: %q", got)
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

func TestEditorWordNavigationMatchesShireiClassRuns(t *testing.T) {
	cases := []struct {
		text      string
		from      int
		wantLeft  int
		wantRight int
	}{
		{"hello world", 0, 0, 5},
		{"hello world", 5, 0, 11},
		{"hello world", 8, 6, 11},
		{"/opt/brew", 1, 0, 4},
		{"/opt/brew", 4, 1, 5},
		{"foo, bar", 3, 0, 4},
		{"foo, bar", 4, 3, 8},
		{"a_b2 c", 0, 0, 4},
		{"   ", 1, 0, 3},
		{"", 0, 0, 0},
	}
	for _, tc := range cases {
		b := NewBuffer([]byte(tc.text))
		if got := b.PreviousWord(tc.from); got != tc.wantLeft {
			t.Errorf("PreviousWord(%q, %d) = %d, want %d", tc.text, tc.from, got, tc.wantLeft)
		}
		if got := b.NextWord(tc.from); got != tc.wantRight {
			t.Errorf("NextWord(%q, %d) = %d, want %d", tc.text, tc.from, got, tc.wantRight)
		}
	}

	// Japanese script transitions are word boundaries, and combining marks
	// remain part of the surrounding word run.
	b := NewBuffer([]byte("漢字かなカナab"))
	for _, tc := range []struct{ at, left, right int }{
		{0, 0, 6}, {6, 0, 12}, {12, 6, 18}, {18, 12, 20}, {20, 18, 20},
	} {
		if got := b.PreviousWord(tc.at); got != tc.left {
			t.Errorf("PreviousWord(Japanese, %d) = %d, want %d", tc.at, got, tc.left)
		}
		if got := b.NextWord(tc.at); got != tc.right {
			t.Errorf("NextWord(Japanese, %d) = %d, want %d", tc.at, got, tc.right)
		}
	}
	b = NewBuffer([]byte("cafe\u0301s x"))
	if got := b.NextWord(0); got != len([]byte("cafe\u0301s")) {
		t.Fatalf("NextWord(combining word) = %d, want %d", got, len([]byte("cafe\u0301s")))
	}
	// An inherited combining mark after a Han base has a different script
	// class, but word motion must still stop only at a grapheme boundary.
	b = NewBuffer([]byte("漢\u0301字"))
	if got := b.NextWord(0); got != len([]byte("漢\u0301")) {
		t.Fatalf("NextWord(Han plus inherited mark) = %d, want %d", got, len([]byte("漢\u0301")))
	}
	if got := b.PreviousWord(len([]byte("漢\u0301"))); got != 0 {
		t.Fatalf("PreviousWord(Han plus inherited mark) = %d, want 0", got)
	}
}

func TestEditorWordNavigationPreservesSelectionAndInvalidByteSafety(t *testing.T) {
	e := NewScratchEditor([]byte("hello world"))
	e.SetCursor(0)
	e.MoveWordRight(true)
	if e.Cursor != 5 || e.Anchor != 0 {
		t.Fatalf("shift-word-right selection = %d:%d, want 0:5", e.Anchor, e.Cursor)
	}
	e.MoveWordRight(true)
	if e.Cursor != 11 || e.Anchor != 0 {
		t.Fatalf("second shift-word-right selection = %d:%d, want 0:11", e.Anchor, e.Cursor)
	}
	e.MoveWordLeft(false)
	if e.Cursor != 6 || e.Anchor != 6 {
		t.Fatalf("word-left collapse = %d:%d, want 6:6", e.Anchor, e.Cursor)
	}

	// Malformed bytes remain one-byte navigation units and never cause a
	// result inside the valid UTF-8 rune on either side.
	b := NewBuffer([]byte{'a', ' ', 0xff, 'b', 0xc3})
	for _, tc := range []struct {
		name      string
		got, want int
	}{
		{"next through invalid", b.NextWord(1), 3},
		{"previous before invalid", b.PreviousWord(3), 2},
		{"previous trailing invalid", b.PreviousWord(5), 4},
	} {
		if tc.got != tc.want {
			t.Errorf("%s = %d, want %d", tc.name, tc.got, tc.want)
		}
	}

	b = NewBuffer(append([]byte("é"), 0x80))
	if got := b.PreviousWord(b.ByteLen()); got != len([]byte("é")) {
		t.Fatalf("PreviousWord after malformed continuation = %d, want %d", got, len([]byte("é")))
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

func TestResetAdvancesRevisionIdentity(t *testing.T) {
	e := NewScratchEditor([]byte("before"))
	if err := e.Insert([]byte(" edit")); err != nil {
		t.Fatal(err)
	}
	oldRevision := e.Revision()
	e.SetPreferredVerticalX(42)
	e.Reset([]byte("after"))
	if e.Revision() == oldRevision {
		t.Fatalf("reset reused revision %d", e.Revision())
	}
	if got := string(e.Buffer.Text()); got != "after" {
		t.Fatalf("reset text = %q", got)
	}
	if _, ok := e.EditsSince(oldRevision); ok {
		t.Fatal("reset should discard the old edit journal")
	}
	if _, ok := e.PreferredVerticalX(); ok {
		t.Fatal("reset retained preferred vertical X")
	}
}

func TestEditorBackspaceTreatsMalformedUTF8AsByteUnits(t *testing.T) {
	tests := []struct {
		name   string
		source []byte
		at     int
		want   []byte
	}{
		{name: "isolated continuation", source: []byte{'a', 0x80, 'b'}, at: 2, want: []byte{'a', 'b'}},
		{name: "truncated lead", source: []byte{'a', 0xe2, 0x82}, at: 3, want: []byte{'a', 0xe2}},
		{name: "malformed lead before ascii", source: []byte{0xc3, 'x'}, at: 2, want: []byte{0xc3}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			e := NewScratchEditor(test.source)
			e.SetCursor(test.at)
			if err := e.Backspace(); err != nil {
				t.Fatal(err)
			}
			if got := e.Buffer.Text(); !bytes.Equal(got, test.want) {
				t.Fatalf("after backspace = %x, want %x", got, test.want)
			}
			if err := e.Undo(); err != nil {
				t.Fatal(err)
			}
			if got := e.Buffer.Text(); !bytes.Equal(got, test.source) {
				t.Fatalf("after undo = %x, want %x", got, test.source)
			}
			if err := e.Redo(); err != nil {
				t.Fatal(err)
			}
			if got := e.Buffer.Text(); !bytes.Equal(got, test.want) {
				t.Fatalf("after redo = %x, want %x", got, test.want)
			}
		})
	}
}

func TestEditorMalformedUTF8OffsetsRemainEditable(t *testing.T) {
	e := NewScratchEditor([]byte{0xe2, 0x82, 'x'})
	e.SetCursor(1)
	if e.Cursor != 1 {
		t.Fatalf("cursor in malformed sequence = %d, want 1", e.Cursor)
	}
	if err := e.Backspace(); err != nil {
		t.Fatal(err)
	}
	if got := e.Buffer.Text(); !bytes.Equal(got, []byte{0x82, 'x'}) {
		t.Fatalf("deleting malformed lead = %x, want 82 78", got)
	}
	e.SetCursor(1)
	if err := e.Backspace(); err != nil {
		t.Fatal(err)
	}
	if got := e.Buffer.Text(); !bytes.Equal(got, []byte{'x'}) {
		t.Fatalf("deleting malformed continuation = %x, want 78", got)
	}
	if err := e.Undo(); err != nil {
		t.Fatal(err)
	}
	if got := e.Buffer.Text(); !bytes.Equal(got, []byte{0x82, 'x'}) {
		t.Fatalf("undo malformed continuation = %x, want 82 78", got)
	}
	if err := e.Undo(); err != nil {
		t.Fatal(err)
	}
	if got := e.Buffer.Text(); !bytes.Equal(got, []byte{0xe2, 0x82, 'x'}) {
		t.Fatalf("undo malformed lead = %x, want e2 82 78", got)
	}
}

func TestMalformedUTF8StaysSeparateFromCombiningMarks(t *testing.T) {
	source := []byte{0xff, 0xcc, 0x81, 'x'} // malformed byte, then U+0301.
	e := NewScratchEditor(source)
	e.SetCursor(0)
	if err := e.DeleteForward(); err != nil {
		t.Fatal(err)
	}
	if got := e.Buffer.Text(); !bytes.Equal(got, []byte{0xcc, 0x81, 'x'}) {
		t.Fatalf("forward deletion = %x, want cc 81 78", got)
	}

	e = NewScratchEditor([]byte{0xff, 0xcc, 0x81})
	e.SetCursor(e.Buffer.ByteLen())
	if err := e.Backspace(); err != nil {
		t.Fatal(err)
	}
	if got := e.Buffer.Text(); !bytes.Equal(got, []byte{0xff}) {
		t.Fatalf("backspace deletion = %x, want ff", got)
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
