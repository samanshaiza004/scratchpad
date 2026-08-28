// Package editor contains the smallest editor-scale storage spike. It is not
// yet the product editor and intentionally has no Shirei dependency.
package editor

import (
	"bytes"
	"errors"
)

type sourceKind uint8

const (
	originalSource sourceKind = iota
	addedSource
)

type piece struct {
	source   sourceKind
	start    int
	length   int
	newlines int
}

// Buffer is a deliberately small piece-backed byte buffer. Insertions append
// to the add store and split only the piece at the edit point. This is a Gate B
// proof object, not a final piece tree or undo representation.
type Buffer struct {
	original []byte
	added    []byte
	pieces   []piece
	bytes    int
	newlines int
}

func NewBuffer(source []byte) Buffer {
	b := Buffer{original: append([]byte(nil), source...), bytes: len(source)}
	if len(source) > 0 {
		b.pieces = []piece{{source: originalSource, length: len(source), newlines: bytes.Count(source, []byte{'\n'})}}
		b.newlines = b.pieces[0].newlines
	}
	return b
}

func (b *Buffer) ByteLen() int {
	return b.bytes
}

func (b *Buffer) LineCount() int {
	return b.newlines + 1
}

func (b *Buffer) Text() []byte {
	return b.slice(0, b.bytes)
}

func (b *Buffer) Insert(at int, text []byte) error {
	if at < 0 || at > b.bytes {
		return errors.New("insert offset outside buffer")
	}
	if len(text) == 0 {
		return nil
	}

	start := len(b.added)
	b.added = append(b.added, text...)
	newPiece := piece{
		source:   addedSource,
		start:    start,
		length:   len(text),
		newlines: bytes.Count(text, []byte{'\n'}),
	}
	index := b.splitAt(at)
	b.pieces = append(b.pieces, piece{})
	copy(b.pieces[index+1:], b.pieces[index:])
	b.pieces[index] = newPiece
	b.bytes += len(text)
	b.newlines += newPiece.newlines
	return nil
}

func (b *Buffer) Delete(start, end int) error {
	if start < 0 || end < start || end > b.bytes {
		return errors.New("delete range outside buffer")
	}
	if start == end {
		return nil
	}
	from := b.splitAt(start)
	to := b.splitAt(end)
	removedBytes := 0
	removedNewlines := 0
	for _, p := range b.pieces[from:to] {
		removedBytes += p.length
		removedNewlines += p.newlines
	}
	b.pieces = append(b.pieces[:from], b.pieces[to:]...)
	b.bytes -= removedBytes
	b.newlines -= removedNewlines
	return nil
}

// Line returns a copy of one logical line without its terminating LF. Copying
// the visible line is intentional; the eventual view can replace this with a
// slice/iterator if profiling shows long visible lines need it.
func (b *Buffer) Line(line int) (string, bool) {
	if line < 0 || line >= b.LineCount() {
		return "", false
	}
	start := b.lineStart(line)
	end := b.bytes
	if line+1 < b.LineCount() {
		end = b.lineStart(line+1) - 1
	}
	return string(b.slice(start, end)), true
}

func (b *Buffer) lineStart(line int) int {
	if line <= 0 {
		return 0
	}
	if line >= b.LineCount() {
		return b.bytes
	}
	wantNewline := line - 1
	offset := 0
	for _, p := range b.pieces {
		if wantNewline >= p.newlines {
			wantNewline -= p.newlines
			offset += p.length
			continue
		}
		data := b.pieceBytes(p)
		seen := 0
		for i, c := range data {
			if c == '\n' {
				if seen == wantNewline {
					return offset + i + 1
				}
				seen++
			}
		}
	}
	return b.bytes
}

func (b *Buffer) splitAt(at int) int {
	if at <= 0 {
		return 0
	}
	if at >= b.bytes {
		return len(b.pieces)
	}
	offset := 0
	for i, p := range b.pieces {
		if at == offset {
			return i
		}
		if at < offset+p.length {
			leftLength := at - offset
			rightLength := p.length - leftLength
			left := p
			left.length = leftLength
			left.newlines = bytes.Count(b.pieceBytes(p)[:leftLength], []byte{'\n'})
			right := p
			right.start += leftLength
			right.length = rightLength
			right.newlines = p.newlines - left.newlines
			b.pieces = append(b.pieces, piece{})
			copy(b.pieces[i+2:], b.pieces[i+1:])
			b.pieces[i] = left
			b.pieces[i+1] = right
			return i + 1
		}
		offset += p.length
	}
	return len(b.pieces)
}

func (b *Buffer) pieceBytes(p piece) []byte {
	if p.source == originalSource {
		return b.original[p.start : p.start+p.length]
	}
	return b.added[p.start : p.start+p.length]
}

func (b *Buffer) slice(start, end int) []byte {
	if start < 0 {
		start = 0
	}
	if end > b.bytes {
		end = b.bytes
	}
	if start >= end {
		return nil
	}
	out := make([]byte, 0, end-start)
	offset := 0
	for _, p := range b.pieces {
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
		out = append(out, b.pieceBytes(p)[from:to]...)
		offset = pieceEnd
	}
	return out
}
