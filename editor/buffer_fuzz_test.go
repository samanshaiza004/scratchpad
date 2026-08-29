package editor

import (
	"bytes"
	"testing"
)

// FuzzBufferDifferential checks the balanced index against the former linear
// piece oracle. The input controls a small deterministic edit stream; this is
// correctness fuzzing only, not a performance target.
func FuzzBufferDifferential(f *testing.F) {
	f.Add([]byte("insert-delete-newline"))
	f.Add([]byte{0, 1, 2, 3, 4, 5, 6, 7, 8, 9})
	f.Add([]byte("\xff\x00\n\xc3\xa9"))
	f.Fuzz(func(t *testing.T, stream []byte) {
		seed := []byte("one\ntwo\nthree\n")
		b := NewBuffer(seed)
		o := newSliceOracle(seed)
		insertions := [][]byte{[]byte("x"), []byte("\n"), []byte("ab\n"), []byte("é")}

		for step, value := range stream {
			at := int(value) % (o.bytes + 1)
			if value&1 == 0 || o.bytes == 0 {
				text := insertions[int(value>>1)%len(insertions)]
				if err := b.Insert(at, text); err != nil {
					t.Fatal(err)
				}
				o.insert(at, text)
			} else {
				end := at + int(value>>2)%8
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
			checkTreeInvariants(t, b.root)
		}
	})
}
