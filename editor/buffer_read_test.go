package editor

import (
	"bytes"
	"io"
	"testing"
)

func TestBufferReadAtMatchesSourceAcrossFragmentedPieces(t *testing.T) {
	b := NewBuffer([]byte("first\n日本語\nlast"))
	if err := b.Insert(6, []byte("inserted\n")); err != nil {
		t.Fatal(err)
	}
	if err := b.Delete(0, 2); err != nil {
		t.Fatal(err)
	}
	source := b.Text()
	for start := 0; start <= len(source)+1; start++ {
		for size := 0; size <= len(source)+1; size++ {
			storage := bytes.Repeat([]byte{0xaa}, size+2)
			n, err := b.ReadAt(storage[1:1+size], int64(start))
			want := 0
			if start < len(source) {
				want = min(size, len(source)-start)
			}
			wantEOF := start > len(source) || start == len(source) && size > 0 || want < size
			if n != want || (err == io.EOF) != wantEOF || err != nil && err != io.EOF {
				t.Fatalf("offset=%d size=%d: n=%d err=%v want n=%d EOF=%v", start, size, n, err, want, wantEOF)
			}
			if want > 0 && !bytes.Equal(storage[1:1+n], source[start:start+n]) {
				t.Fatal("read crossed a piece incorrectly")
			}
			if storage[0] != 0xaa || storage[len(storage)-1] != 0xaa {
				t.Fatal("read wrote beyond the destination")
			}
		}
	}
	if n, err := b.ReadAt(make([]byte, 3), -1); n != 0 || err == nil {
		t.Fatal("negative offsets must fail")
	}
	if n, err := b.ReadAt(make([]byte, 3), 1<<62); n != 0 || err != io.EOF {
		t.Fatal("oversized offsets must not overflow")
	}
	storage := make([]byte, 8)
	if allocations := testing.AllocsPerRun(100, func() { _, _ = b.ReadAt(storage, 2) }); allocations != 0 {
		t.Fatalf("ReadAt allocated %g times", allocations)
	}
}
