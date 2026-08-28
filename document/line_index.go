package document

import "sort"

// LineIndex stores byte offsets for the beginning of each logical line. Newline
// bytes are not part of a line range; carriage returns remain content so a
// later file-policy layer can preserve or normalize them deliberately.
type LineIndex struct {
	starts []int
}

// BuildLineIndex builds a byte-oriented index. The implementation is simple on
// purpose: it is a baseline for the Gate B benchmark, not a claim about the
// eventual mutable-buffer strategy.
func BuildLineIndex(source []byte) LineIndex {
	starts := []int{0}
	for i, b := range source {
		if b == '\n' {
			starts = append(starts, i+1)
		}
	}
	return LineIndex{starts: starts}
}

func (l LineIndex) Len() int {
	return len(l.starts)
}

func (l LineIndex) Start(line int) (int, bool) {
	if line < 0 || line >= len(l.starts) {
		return 0, false
	}
	return l.starts[line], true
}

// Range returns the byte range of a line without its terminating LF.
func (l LineIndex) Range(line, sourceLen int) (start, end int, ok bool) {
	start, ok = l.Start(line)
	if !ok || sourceLen < start {
		return 0, 0, false
	}
	end = sourceLen
	if line+1 < len(l.starts) {
		end = l.starts[line+1] - 1
	}
	return start, end, true
}

// LineForByte returns the line containing offset. Offsets at EOF map to the
// final logical line, which is useful for caret and append operations.
func (l LineIndex) LineForByte(offset int) (int, bool) {
	if len(l.starts) == 0 || offset < 0 {
		return 0, false
	}
	if offset >= l.starts[len(l.starts)-1] {
		return len(l.starts) - 1, true
	}
	line := sort.Search(len(l.starts), func(i int) bool { return l.starts[i] > offset })
	return line - 1, true
}
