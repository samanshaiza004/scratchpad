// Package editor contains the smallest editor-scale storage spike. It is not
// yet the product editor and intentionally has no Shirei dependency.
package editor

import (
	"bytes"
	"errors"
	"unicode"
	"unicode/utf8"
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

// pieceNode is an implicit treap node. Its in-order position is the document
// position; subtree summaries make byte and newline lookup logarithmic in the
// expected case. Priorities are generated per Buffer so the tree is
// deterministic for a given edit stream while remaining balanced in practice.
type pieceNode struct {
	piece    piece
	priority uint64
	left     *pieceNode
	right    *pieceNode
	bytes    int
	newlines int
	pieces   int
}

// Buffer is a piece-backed byte buffer. Original file bytes remain immutable
// in original, inserted bytes append to added without rewriting prior bytes,
// and the balanced piece index is the only mutable document structure. This
// representation is deliberately replaceable behind the observable API.
type Buffer struct {
	original []byte
	added    []byte
	root     *pieceNode
	byteLen  int
	newlines int
	seed     uint64
}

// BufferSnapshot is an immutable view of the buffer's piece sequence. The
// source stores are append-only/immutable for bytes already referenced by a
// piece, so taking a snapshot copies only the piece descriptors. Materialize
// is the intentionally explicit O(document-size) operation for background
// consumers such as parsers.
type BufferSnapshot struct {
	original []byte
	added    []byte
	pieces   []piece
	byteLen  int
}

// Snapshot captures the current piece sequence in O(piece count). The
// returned value is independent of future tree edits and added-store growth.
func (b *Buffer) Snapshot() BufferSnapshot {
	snapshot := BufferSnapshot{
		original: b.original,
		added:    b.added,
		byteLen:  b.byteLen,
		pieces:   make([]piece, 0, nodePieces(b.root)),
	}
	var collect func(*pieceNode)
	collect = func(node *pieceNode) {
		if node == nil {
			return
		}
		collect(node.left)
		snapshot.pieces = append(snapshot.pieces, node.piece)
		collect(node.right)
	}
	collect(b.root)
	return snapshot
}

// Materialize returns the complete byte contents represented by the
// snapshot. It allocates proportional to the document size and should not be
// called on the interactive frame path.
func (s BufferSnapshot) Materialize() []byte {
	out := make([]byte, 0, s.byteLen)
	for _, p := range s.pieces {
		var source []byte
		if p.source == originalSource {
			source = s.original
		} else {
			source = s.added
		}
		out = append(out, source[p.start:p.start+p.length]...)
	}
	return out
}

func NewBuffer(source []byte) Buffer {
	b := Buffer{
		original: append([]byte(nil), source...),
		byteLen:  len(source),
		seed:     0x9e3779b97f4a7c15,
	}
	if len(source) > 0 {
		b.root = b.newNode(piece{
			source:   originalSource,
			length:   len(source),
			newlines: bytes.Count(source, []byte{'\n'}),
		})
		b.newlines = b.root.newlines
	}
	return b
}

func (b *Buffer) ByteLen() int {
	return b.byteLen
}

// PieceCount is exposed for fragmentation experiments, not as a product
// contract. A different balanced index can preserve the same behavior.
func (b *Buffer) PieceCount() int {
	return nodePieces(b.root)
}

func (b *Buffer) LineCount() int {
	return b.newlines + 1
}

// LineAt returns the logical line containing a byte offset. The offset may be
// the end of the buffer; an offset on a newline belongs to the line before it,
// matching LineRange's line-end convention.
func (b *Buffer) LineAt(offset int) (int, bool) {
	if offset < 0 || offset > b.byteLen {
		return 0, false
	}
	line := 0
	node := b.root
	for node != nil {
		leftBytes := nodeBytes(node.left)
		if offset < leftBytes {
			node = node.left
			continue
		}
		line += nodeNewlines(node.left)
		offset -= leftBytes
		if offset <= node.piece.length {
			if node.piece.newlines == 0 {
				return line, true
			}
			data := b.pieceBytes(node.piece)
			for _, c := range data[:offset] {
				if c == '\n' {
					line++
				}
			}
			return line, true
		}
		offset -= node.piece.length
		line += node.piece.newlines
		node = node.right
	}
	return line, true
}

func (b *Buffer) Text() []byte {
	return b.slice(0, b.byteLen)
}

func (b *Buffer) Bytes(start, end int) ([]byte, error) {
	if start < 0 || end < start || end > b.byteLen {
		return nil, errors.New("range outside buffer")
	}
	return b.slice(start, end), nil
}

func (b *Buffer) Insert(at int, text []byte) error {
	if at < 0 || at > b.byteLen {
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
	left, right := split(b.root, at, b)
	b.root = merge(merge(left, b.newNode(newPiece)), right)
	b.byteLen += len(text)
	b.newlines += newPiece.newlines
	return nil
}

func (b *Buffer) Delete(start, end int) error {
	if start < 0 || end < start || end > b.byteLen {
		return errors.New("delete range outside buffer")
	}
	if start == end {
		return nil
	}
	left, rest := split(b.root, start, b)
	_, right := split(rest, end-start, b)
	b.root = merge(left, right)
	b.byteLen -= end - start
	b.newlines = nodeNewlines(b.root)
	return nil
}

// Line returns a copy of one logical line without its terminating LF. Copying
// the visible line is intentional; the view can later add a zero-copy line
// renderer without changing the tree's lookup contract.
func (b *Buffer) Line(line int) (string, bool) {
	start, end, ok := b.LineRange(line)
	if !ok {
		return "", false
	}
	return string(b.slice(start, end)), true
}

func (b *Buffer) LineRange(line int) (start, end int, ok bool) {
	if line < 0 || line >= b.LineCount() {
		return 0, 0, false
	}
	start = b.lineStart(line)
	end = b.byteLen
	if line+1 < b.LineCount() {
		end = b.lineStart(line+1) - 1
	}
	return start, end, true
}

// BoundedLines returns one copied byte range containing at most maxLines
// logical lines and maxBytes bytes. endLine is exclusive. A byte-limited
// result may end in the middle of a line; in that case endLine still includes
// that partially returned line. The operation resolves two indexed line
// boundaries and copies the intervening pieces once.
func (b *Buffer) BoundedLines(startLine, maxLines, maxBytes int) ([]byte, int, bool, error) {
	if b == nil {
		return nil, 0, false, errors.New("nil buffer")
	}
	if startLine < 0 || startLine >= b.LineCount() {
		return nil, 0, false, errors.New("start line outside buffer")
	}
	if maxLines <= 0 {
		return nil, 0, false, errors.New("max lines must be positive")
	}
	if maxBytes <= 0 {
		return nil, 0, false, errors.New("max bytes must be positive")
	}

	lineCount := b.LineCount()
	endLine := startLine + maxLines
	if endLine > lineCount {
		endLine = lineCount
	}
	startByte := b.lineStart(startLine)
	endByte := b.lineStart(endLine)
	if endByte-startByte <= maxBytes {
		return b.slice(startByte, endByte), endLine, endLine < lineCount, nil
	}

	data := b.slice(startByte, startByte+maxBytes)
	returnedEndLine := startLine + bytes.Count(data, []byte{'\n'})
	if len(data) > 0 && data[len(data)-1] != '\n' {
		returnedEndLine++
	}
	if returnedEndLine > endLine {
		returnedEndLine = endLine
	}
	return data, returnedEndLine, true, nil
}

func (b *Buffer) ByteAt(at int) (byte, bool) {
	if at < 0 || at >= b.byteLen {
		return 0, false
	}
	node := b.root
	for node != nil {
		leftBytes := nodeBytes(node.left)
		if at < leftBytes {
			node = node.left
			continue
		}
		at -= leftBytes
		if at < node.piece.length {
			return b.pieceBytes(node.piece)[at], true
		}
		at -= node.piece.length
		node = node.right
	}
	return 0, false
}

func (b *Buffer) boundary(at int) int {
	if at <= 0 {
		return 0
	}
	if at >= b.byteLen {
		return b.byteLen
	}
	// Only snap an offset backwards when it is inside a valid UTF-8 rune.
	// Invalid bytes are editable one-byte units, so a malformed continuation
	// sequence must not make the preceding valid rune unreachable.
	for start := max(0, at-(utf8.UTFMax-1)); start < at; start++ {
		width, ok := b.validRuneAt(start)
		if ok && start+width > at {
			return start
		}
	}
	return at
}

func (b *Buffer) runeAt(at int) (rune, int, bool) {
	if at < 0 || at >= b.byteLen {
		return 0, 0, false
	}
	var encoded [utf8.UTFMax]byte
	size := min(utf8.UTFMax, b.byteLen-at)
	for i := 0; i < size; i++ {
		encoded[i], _ = b.ByteAt(at + i)
	}
	r, width := utf8.DecodeRune(encoded[:size])
	return r, width, true
}

func (b *Buffer) runeStartBefore(at int) (int, bool) {
	if at <= 0 || at > b.byteLen {
		return 0, false
	}
	// Search only for a valid rune that ends exactly at at. A bare
	// continuation byte, truncated lead byte, or malformed sequence is one
	// deletion unit of its own.
	for start := at - 1; start >= max(0, at-utf8.UTFMax); start-- {
		width, ok := b.validRuneAt(start)
		if ok && start+width == at {
			return start, true
		}
	}
	return at - 1, true
}

// validRuneAt reports the width of the valid UTF-8 rune beginning at start.
// It intentionally rejects DecodeRune's one-byte RuneError result for
// malformed input, allowing callers to edit malformed bytes independently.
func (b *Buffer) validRuneAt(start int) (int, bool) {
	if start < 0 || start >= b.byteLen {
		return 0, false
	}
	size := min(utf8.UTFMax, b.byteLen-start)
	var encoded [utf8.UTFMax]byte
	for i := 0; i < size; i++ {
		encoded[i], _ = b.ByteAt(start + i)
	}
	_, width := utf8.DecodeRune(encoded[:size])
	if width <= 0 || width > size || !utf8.Valid(encoded[:width]) {
		return 0, false
	}
	return width, true
}

// PreviousCluster and NextCluster provide the first local grapheme behavior
// needed by the parity spike. They avoid flattening the complete buffer. The
// rules cover combining marks, variation selectors, emoji modifiers, and ZWJ
// sequences; full Unicode grapheme conformance remains a parity test gate.
func (b *Buffer) PreviousCluster(at int) int {
	start, ok := b.runeStartBefore(at)
	if !ok {
		return 0
	}
	for start > 0 {
		r, _, _ := b.runeAt(start)
		if !isClusterExtend(r) {
			break
		}
		previous, ok := b.runeStartBefore(start)
		if !ok {
			break
		}
		if _, valid := b.validRuneAt(previous); !valid {
			break
		}
		start = previous
	}
	for start > 0 {
		zwjStart, _ := b.runeStartBefore(start)
		zwj, _, _ := b.runeAt(zwjStart)
		if zwj != '\u200d' {
			break
		}
		baseStart, ok := b.runeStartBefore(zwjStart)
		if !ok {
			break
		}
		if _, valid := b.validRuneAt(baseStart); !valid {
			break
		}
		start = zwjStart
		start = baseStart
		for start > 0 {
			r, _, _ := b.runeAt(start)
			if !isClusterExtend(r) {
				break
			}
			previous, ok := b.runeStartBefore(start)
			if !ok {
				break
			}
			if _, valid := b.validRuneAt(previous); !valid {
				break
			}
			start = previous
		}
	}
	return start
}

func (b *Buffer) NextCluster(at int) int {
	if at >= b.byteLen {
		return b.byteLen
	}
	pos := at
	for pos < b.byteLen {
		_, width, ok := b.runeAt(pos)
		if !ok {
			return b.byteLen
		}
		if _, valid := b.validRuneAt(pos); !valid {
			return pos + 1
		}
		pos += width
		for pos < b.byteLen {
			next, nextWidth, _ := b.runeAt(pos)
			if !isClusterExtend(next) {
				break
			}
			pos += nextWidth
		}
		if pos >= b.byteLen {
			break
		}
		next, nextWidth, _ := b.runeAt(pos)
		if next != '\u200d' {
			break
		}
		pos += nextWidth
	}
	return pos
}

func isClusterExtend(r rune) bool {
	return unicode.Is(unicode.Mn, r) || unicode.Is(unicode.Mc, r) ||
		unicode.Is(unicode.Me, r) || (r >= 0xfe00 && r <= 0xfe0f) ||
		(r >= 0x1f3fb && r <= 0x1f3ff)
}

// Word motion follows Shirei's class-run rule. It skips whitespace in the
// direction of travel and then crosses one maximal run of the same class.
// Punctuation is a class of its own, while the common Japanese scripts are
// split so a script transition is a word boundary. These methods scan bytes
// through the piece tree and never flatten the complete buffer.
func (b *Buffer) PreviousWord(at int) int {
	i := b.boundary(at)
	for i > 0 {
		start, ok := b.runeStartBefore(i)
		if !ok {
			return i
		}
		class, _ := b.wordRuneClass(start)
		i = start
		if class != wordClassSpace {
			for i > 0 {
				previous, ok := b.runeStartBefore(i)
				if !ok {
					break
				}
				previousClass, _ := b.wordRuneClass(previous)
				if previousClass != class {
					break
				}
				i = previous
			}
			break
		}
	}
	return b.snapWordLeft(i)
}

func (b *Buffer) NextWord(at int) int {
	i := b.boundary(at)
	for i < b.byteLen {
		class, width := b.wordRuneClass(i)
		if width <= 0 {
			return i
		}
		i += width
		if class != wordClassSpace {
			for i < b.byteLen {
				nextClass, nextWidth := b.wordRuneClass(i)
				if nextWidth <= 0 || nextClass != class {
					break
				}
				i += nextWidth
			}
			break
		}
	}
	return b.snapWordRight(i)
}

// WordRangeAt returns the maximal word-motion class run containing the rune at
// at. It deliberately shares wordRuneClass with PreviousWord and NextWord so
// double-click selection and Ctrl/Alt word motion agree on punctuation,
// whitespace, and script boundaries. An end-of-buffer offset selects the last
// run, matching the usual text-editor hit-testing behavior.
func (b *Buffer) WordRangeAt(at int) (start, end int, ok bool) {
	if b == nil || b.byteLen == 0 {
		return 0, 0, false
	}
	at = b.boundary(at)
	if at >= b.byteLen {
		at = b.PreviousCluster(b.byteLen)
	}
	class, width := b.wordRuneClass(at)
	if width <= 0 {
		return at, at, false
	}
	start, end = at, at+width
	for start > 0 {
		previous := b.PreviousCluster(start)
		previousClass, previousWidth := b.wordRuneClass(previous)
		if previousWidth <= 0 || previousClass != class {
			break
		}
		start = previous
	}
	for end < b.byteLen {
		nextClass, nextWidth := b.wordRuneClass(end)
		if nextWidth <= 0 || nextClass != class {
			break
		}
		end += nextWidth
	}
	return start, end, true
}

// Class boundaries can occur between a base rune and an extending mark when
// the mark belongs to the Inherited script. Keep word motion on the same
// grapheme-like caret stops used by ordinary horizontal motion.
func (b *Buffer) snapWordLeft(at int) int {
	at = b.boundary(at)
	if at <= 0 {
		return at
	}
	start := b.PreviousCluster(at)
	if b.NextCluster(start) > at {
		return start
	}
	return at
}

func (b *Buffer) snapWordRight(at int) int {
	at = b.boundary(at)
	if at >= b.byteLen {
		return at
	}
	start := b.PreviousCluster(at)
	end := b.NextCluster(start)
	if end > at {
		return end
	}
	return at
}

type wordClass uint8

const (
	wordClassSpace wordClass = iota
	wordClassPunct
	wordClassWord
	wordClassHan
	wordClassHiragana
	wordClassKatakana
)

func (b *Buffer) wordRuneClass(at int) (wordClass, int) {
	r, width, ok := b.runeAt(at)
	if !ok || width <= 0 {
		return wordClassPunct, 0
	}
	// DecodeRune represents malformed input as RuneError with width one. Keep
	// that byte as a punctuation unit instead of allowing it to be mistaken
	// for a valid replacement-character rune or a part of a larger unit.
	if _, valid := b.validRuneAt(at); !valid {
		return wordClassPunct, 1
	}
	switch {
	case unicode.IsSpace(r):
		return wordClassSpace, width
	case unicode.Is(unicode.Han, r):
		return wordClassHan, width
	case unicode.Is(unicode.Hiragana, r):
		return wordClassHiragana, width
	case unicode.Is(unicode.Katakana, r):
		return wordClassKatakana, width
	case r == '_' || unicode.IsLetter(r) || unicode.IsDigit(r) || unicode.IsMark(r):
		return wordClassWord, width
	default:
		return wordClassPunct, width
	}
}

// lineStart returns the byte after the requested preceding newline. The
// newline ordinal is selected using subtree newline counts, then scanned only
// inside its containing piece.
func (b *Buffer) lineStart(line int) int {
	if line <= 0 {
		return 0
	}
	if line >= b.LineCount() {
		return b.byteLen
	}
	return b.newlineOffset(line-1) + 1
}

func (b *Buffer) newlineOffset(want int) int {
	node := b.root
	base := 0
	for node != nil {
		leftBytes := nodeBytes(node.left)
		leftNewlines := nodeNewlines(node.left)
		if want < leftNewlines {
			node = node.left
			continue
		}
		want -= leftNewlines
		if want < node.piece.newlines {
			seen := 0
			for i, c := range b.pieceBytes(node.piece) {
				if c == '\n' {
					if seen == want {
						return base + leftBytes + i
					}
					seen++
				}
			}
		}
		want -= node.piece.newlines
		base += leftBytes + node.piece.length
		node = node.right
	}
	return b.byteLen - 1
}

// LineCursor walks neighboring lines without restarting a tree search for
// every row. The first line is found by the indexed newline lookup; following
// lines advance through the leaf sequence.
type LineCursor struct {
	buffer *Buffer
	pieces pieceCursor
	line   int
	start  int
	end    int
	valid  bool
}

func (b *Buffer) NewLineCursor(line int) (LineCursor, bool) {
	start, end, ok := b.LineRange(line)
	if !ok {
		return LineCursor{}, false
	}
	var pieces pieceCursor
	pieces.buffer = b
	pieces.seek(start)
	c := LineCursor{buffer: b, pieces: pieces, line: line, start: start, end: end, valid: true}
	c.end = c.scanEnd()
	return c, true
}

func (c *LineCursor) Line() (string, bool) {
	if !c.valid {
		return "", false
	}
	return string(c.buffer.slice(c.start, c.end)), true
}

func (c *LineCursor) Range() (start, end int, ok bool) {
	if !c.valid {
		return 0, 0, false
	}
	return c.start, c.end, true
}

func (c *LineCursor) Next() bool {
	if !c.valid || c.line+1 >= c.buffer.LineCount() {
		return false
	}
	c.line++
	c.start = c.end + 1
	c.end = c.scanEnd()
	return true
}

func (c *LineCursor) scanEnd() int {
	for c.pieces.node != nil {
		data := c.buffer.pieceBytes(c.pieces.node.piece)
		for i := c.pieces.index; i < len(data); i++ {
			if data[i] == '\n' {
				end := c.pieces.pieceStart + i
				c.pieces.index = i
				c.pieces.advance()
				return end
			}
		}
		c.pieces.index = len(data)
		c.pieces.advance()
	}
	return c.buffer.byteLen
}

type pieceFrame struct {
	node  *pieceNode
	start int
}

type pieceCursor struct {
	buffer     *Buffer
	node       *pieceNode
	stack      []pieceFrame
	pieceStart int
	index      int
}

func (c *pieceCursor) seek(at int) {
	c.node = nil
	c.stack = c.stack[:0]
	c.index = 0
	base := 0
	node := c.buffer.root
	for node != nil {
		leftBytes := nodeBytes(node.left)
		start := base + leftBytes
		if at < start {
			c.stack = append(c.stack, pieceFrame{node: node, start: start})
			node = node.left
			continue
		}
		if at >= start+node.piece.length {
			base = start + node.piece.length
			node = node.right
			continue
		}
		c.node = node
		c.pieceStart = start
		c.index = at - start
		return
	}
}

func (c *pieceCursor) advance() {
	if c.node == nil {
		return
	}
	current := c.node
	if c.index+1 < current.piece.length {
		c.index++
		return
	}

	if current.right != nil {
		base := c.pieceStart + current.piece.length
		node := current.right
		c.stack = append(c.stack, pieceFrame{node: current, start: c.pieceStart})
		for node.left != nil {
			c.stack = append(c.stack, pieceFrame{node: node, start: base + nodeBytes(node.left)})
			node = node.left
		}
		c.node = node
		c.pieceStart = base
		c.index = 0
		return
	}

	child := current
	for len(c.stack) > 0 {
		last := len(c.stack) - 1
		frame := c.stack[last]
		c.stack = c.stack[:last]
		if frame.node.left == child {
			c.node = frame.node
			c.pieceStart = frame.start
			c.index = 0
			return
		}
		child = frame.node
	}
	c.node = nil
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
	if end > b.byteLen {
		end = b.byteLen
	}
	if start >= end {
		return nil
	}
	out := make([]byte, 0, end-start)
	return b.appendRange(b.root, 0, start, end, out)
}

func (b *Buffer) appendRange(node *pieceNode, base, start, end int, out []byte) []byte {
	if node == nil {
		return out
	}
	leftEnd := base + nodeBytes(node.left)
	if start < leftEnd {
		out = b.appendRange(node.left, base, start, end, out)
	}

	pieceEnd := leftEnd + node.piece.length
	if start < pieceEnd && end > leftEnd {
		from := 0
		if start > leftEnd {
			from = start - leftEnd
		}
		to := node.piece.length
		if end < pieceEnd {
			to = end - leftEnd
		}
		out = append(out, b.pieceBytes(node.piece)[from:to]...)
	}
	if end > pieceEnd {
		out = b.appendRange(node.right, pieceEnd, start, end, out)
	}
	return out
}

func (b *Buffer) newNode(p piece) *pieceNode {
	// xorshift64* gives deterministic, inexpensive priorities with no global
	// state shared between documents.
	b.seed ^= b.seed >> 12
	b.seed ^= b.seed << 25
	b.seed ^= b.seed >> 27
	priority := b.seed * 2685821657736338717
	n := &pieceNode{piece: p, priority: priority}
	n.recompute()
	return n
}

func (n *pieceNode) recompute() {
	if n == nil {
		return
	}
	n.bytes = nodeBytes(n.left) + n.piece.length + nodeBytes(n.right)
	n.newlines = nodeNewlines(n.left) + n.piece.newlines + nodeNewlines(n.right)
	n.pieces = nodePieces(n.left) + 1 + nodePieces(n.right)
}

func nodeBytes(n *pieceNode) int {
	if n == nil {
		return 0
	}
	return n.bytes
}

func nodeNewlines(n *pieceNode) int {
	if n == nil {
		return 0
	}
	return n.newlines
}

func nodePieces(n *pieceNode) int {
	if n == nil {
		return 0
	}
	return n.pieces
}

func merge(left, right *pieceNode) *pieceNode {
	if left == nil {
		return right
	}
	if right == nil {
		return left
	}
	if left.priority > right.priority {
		left.right = merge(left.right, right)
		left.recompute()
		return left
	}
	right.left = merge(left, right.left)
	right.recompute()
	return right
}

// split divides root after at bytes and returns the prefix and suffix. A
// piece that straddles the boundary is replaced by two new nodes; all other
// nodes are reused and re-summarized on the return path.
func split(root *pieceNode, at int, b *Buffer) (left, right *pieceNode) {
	if root == nil {
		return nil, nil
	}
	leftBytes := nodeBytes(root.left)
	if at < leftBytes {
		left, rightSubtree := split(root.left, at, b)
		root.left = nil
		root.recompute()
		return left, merge(rightSubtree, root)
	}
	if at > leftBytes+root.piece.length {
		leftSubtree, rightSubtree := split(root.right, at-leftBytes-root.piece.length, b)
		root.right = nil
		root.recompute()
		return merge(root, leftSubtree), rightSubtree
	}
	if at == leftBytes {
		left = root.left
		root.left = nil
		root.recompute()
		return left, root
	}
	if at == leftBytes+root.piece.length {
		right = root.right
		root.right = nil
		root.recompute()
		return root, right
	}

	leftPiece := root.piece
	leftPiece.length = at - leftBytes
	leftPiece.newlines = bytes.Count(b.pieceBytes(root.piece)[:leftPiece.length], []byte{'\n'})
	rightPiece := root.piece
	rightPiece.start += leftPiece.length
	rightPiece.length -= leftPiece.length
	rightPiece.newlines -= leftPiece.newlines
	left = merge(root.left, b.newNode(leftPiece))
	right = merge(b.newNode(rightPiece), root.right)
	return left, right
}
