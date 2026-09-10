package ui

import (
	"strings"
	"testing"
	"unicode/utf8"

	"scratchpad/document"
	"scratchpad/editor"
	"scratchpad/language/markdown"

	. "go.hasen.dev/shirei"
	. "go.hasen.dev/shirei/widgets"
)

func TestVisualLineKeepsDocumentMappingLocal(t *testing.T) {
	b := editor.NewBuffer([]byte("prefix\nabc אבג 👩‍💻 suffix"))
	visual, ok := BuildVisualLine(&b, 1, DefaultTextStyle())
	if !ok {
		t.Fatal("BuildVisualLine failed")
	}
	if visual.DocStart != len("prefix\n") {
		t.Fatalf("DocStart = %d", visual.DocStart)
	}
	if visual.DocEnd != visual.DocStart+len(visual.Text) {
		t.Fatalf("DocEnd = %d, want %d", visual.DocEnd, visual.DocStart+len(visual.Text))
	}
	for runeIndex := range visual.Runes {
		byteOffset := visual.LocalRuneToByte(runeIndex)
		if got := visual.LocalByteToRune(byteOffset); got != runeIndex {
			t.Fatalf("rune/byte round trip at %d = %d", runeIndex, got)
		}
	}
	if got := visual.DocStart + visual.LocalRuneToByte(len(visual.Runes)); got != visual.DocEnd {
		t.Fatalf("end mapping = %d, want %d", got, visual.DocEnd)
	}
}

func TestVisualLinePreservesInvalidBytesWithExplicitMapping(t *testing.T) {
	b := editor.NewBuffer([]byte{'a', 0xff, 'b'})
	visual, ok := BuildVisualLine(&b, 0, DefaultTextStyle())
	if !ok {
		t.Fatal("BuildVisualLine failed")
	}
	if visual.Text != `a\xFFb` {
		t.Fatalf("display text = %q", visual.Text)
	}
	if got := visual.LocalRuneToByte(1); got != 1 {
		t.Fatalf("escape start maps to %d, want 1", got)
	}
	if got := visual.LocalRuneToByte(5); got != 2 {
		t.Fatalf("after escape maps to %d, want 2", got)
	}
	if got := visual.LocalByteToRune(1); got != 1 {
		t.Fatalf("invalid byte maps to display rune %d, want 1", got)
	}
	if got := visual.LocalByteToRune(2); got != 5 {
		t.Fatalf("following byte maps to display rune %d, want 5", got)
	}
}

func TestDisplayTextExpandsTabsToNextStop(t *testing.T) {
	tests := []struct {
		name      string
		source    string
		wantText  string
		wantBytes []int
	}{
		{name: "tab at start", source: "\tX", wantText: "    X", wantBytes: []int{0, 0, 0, 0, 1, 2}},
		{name: "tab after one column", source: "a\tX", wantText: "a   X", wantBytes: []int{0, 1, 1, 1, 2, 3}},
		{name: "tab after three columns", source: "abc\tX", wantText: "abc X", wantBytes: []int{0, 1, 2, 3, 4, 5}},
		{name: "tab at stop", source: "abcd\tX", wantText: "abcd    X", wantBytes: []int{0, 1, 2, 3, 4, 4, 4, 4, 5, 6}},
		{name: "wide CJK rune", source: "界\tX", wantText: "界  X", wantBytes: []int{0, 3, 3, 4, 5}},
		{name: "combining mark", source: "a\u0301\tX", wantText: "a\u0301   X", wantBytes: []int{0, 1, 3, 3, 3, 4, 5}},
		{name: "joined emoji", source: "👩‍💻\tX", wantText: "👩‍💻  X", wantBytes: []int{0, 4, 7, 11, 11, 12, 13}},
		{name: "regional flag", source: "🇺🇸\tX", wantText: "🇺🇸  X", wantBytes: []int{0, 4, 8, 8, 9, 10}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			gotText, gotRunes, gotBytes := displayText([]byte(test.source))
			if gotText != test.wantText {
				t.Fatalf("display text = %q, want %q", gotText, test.wantText)
			}
			if string(gotRunes) != test.wantText {
				t.Fatalf("display runes = %q, want %q", string(gotRunes), test.wantText)
			}
			if len(gotBytes) != len(test.wantBytes) {
				t.Fatalf("source mapping length = %d, want %d (%v)", len(gotBytes), len(test.wantBytes), gotBytes)
			}
			for i, want := range test.wantBytes {
				if gotBytes[i] != want {
					t.Fatalf("source mapping[%d] = %d, want %d (%v)", i, gotBytes[i], want, gotBytes)
				}
			}
		})
	}
}

func TestVisualLineTabMappingKeepsCaretAndHitTestGeometry(t *testing.T) {
	source := []byte("a\tX")
	b := editor.NewBuffer(source)
	visual, ok := BuildVisualLine(&b, 0, DefaultTextStyle())
	if !ok {
		t.Fatal("BuildVisualLine failed")
	}
	if visual.Text != "a   X" {
		t.Fatalf("display text = %q, want %q", visual.Text, "a   X")
	}
	if got := visual.LocalByteToRune(1); got != 1 {
		t.Fatalf("caret before tab maps to display rune %d, want 1", got)
	}
	if got := visual.LocalByteToRune(2); got != 4 {
		t.Fatalf("caret after tab maps to display rune %d, want 4", got)
	}
	if got := visual.LocalRuneToByte(4); got != 2 {
		t.Fatalf("display caret after tab maps to source byte %d, want 2", got)
	}
	if got := visual.LocalRuneToByte(2); got != 1 {
		t.Fatalf("display caret inside tab maps to source byte %d, want 1", got)
	}
	if len(visual.Layout.Lines) == 0 {
		t.Skip("Shirei has no loaded font in this headless unit-test context")
	}
	beforeTab := visual.CaretX(visual.LocalByteToRune(1), editor.AffinityLeading)
	afterTab := visual.CaretX(visual.LocalByteToRune(2), editor.AffinityLeading)
	if afterTab <= beforeTab {
		t.Fatalf("tab did not advance caret: before=%v after=%v", beforeTab, afterTab)
	}
	insideTab, _ := visual.HitTest((beforeTab + afterTab) / 2)
	if got := visual.LocalRuneToByte(insideTab); got != 1 {
		t.Fatalf("hit inside tab maps to source byte %d, want 1", got)
	}
	end := visual.CaretX(len(visual.Runes), editor.AffinityTrailing)
	after, _ := visual.HitTest(afterTab + (end-afterTab)*0.1)
	if got := visual.LocalRuneToByte(after); got != 2 {
		t.Fatalf("hit after tab maps to source byte %d, want 2", got)
	}
}

func TestVisualLineBoundsPathologicalLineShaping(t *testing.T) {
	b := editor.NewBuffer([]byte(strings.Repeat("x", 2<<20)))
	visual, ok := BuildVisualLineAround(&b, 0, 1<<20, DefaultTextStyle())
	if !ok {
		t.Fatal("BuildVisualLineAround failed")
	}
	if got := len(visual.Text); got > maxShapingBytes+utf8.UTFMax {
		t.Fatalf("shaped window = %d bytes, want at most %d plus boundary slack", got, maxShapingBytes)
	}
	if !visual.TruncatedBefore || !visual.TruncatedAfter {
		t.Fatalf("long line truncation = before:%v after:%v", visual.TruncatedBefore, visual.TruncatedAfter)
	}
	if visual.LogicalStart != 0 || visual.LogicalEnd != b.ByteLen() {
		t.Fatalf("logical range = %d:%d", visual.LogicalStart, visual.LogicalEnd)
	}
}

func TestLongLineUsesDeterministicBoundedChunks(t *testing.T) {
	source := []byte(strings.Repeat("x", maxShapingBytes*3+17))
	b := editor.NewBuffer(source)
	anchors := []int{0, maxShapingBytes - 1, maxShapingBytes, maxShapingBytes*2 + 1, len(source)}
	wantCount := (len(source) + longLineChunkBytes - 1) / longLineChunkBytes
	for _, anchor := range anchors {
		visual, ok := BuildVisualLineAround(&b, 0, anchor, DefaultTextStyle())
		if !ok {
			t.Fatalf("BuildVisualLineAround(%d) failed", anchor)
		}
		wantIndex := anchor / longLineChunkBytes
		if wantIndex >= wantCount {
			wantIndex = wantCount - 1
		}
		if visual.ChunkIndex != wantIndex || visual.ChunkCount != wantCount {
			t.Fatalf("anchor %d chunk = %d/%d, want %d/%d", anchor, visual.ChunkIndex, visual.ChunkCount, wantIndex, wantCount)
		}
		if anchor < visual.DocStart || anchor > visual.DocEnd {
			t.Fatalf("anchor %d outside bounded window %d:%d", anchor, visual.DocStart, visual.DocEnd)
		}
		if len(visual.Text) > maxShapingBytes+utf8.UTFMax {
			t.Fatalf("anchor %d shaped %d bytes, want at most %d plus boundary slack", anchor, len(visual.Text), maxShapingBytes)
		}
	}
}

func TestLongLineChunkNavigationTraversesWholeLine(t *testing.T) {
	source := []byte(strings.Repeat("x", maxShapingBytes*3+17))
	e := editor.NewScratchEditor(source)
	steps := 0
	for {
		if !MoveLongLineChunk(e, true, false) {
			break
		}
		steps++
		visual, ok := BuildVisualLineAround(&e.Buffer, 0, e.Cursor, DefaultTextStyle())
		if !ok || e.Cursor < visual.DocStart || e.Cursor > visual.DocEnd {
			t.Fatalf("forward step %d cursor %d is not represented by its chunk", steps, e.Cursor)
		}
	}
	if e.Cursor != len(source) {
		t.Fatalf("forward navigation stopped at %d, want %d", e.Cursor, len(source))
	}
	wantSteps := (len(source) + longLineChunkBytes - 1) / longLineChunkBytes
	if steps != wantSteps {
		t.Fatalf("forward chunk steps = %d, want %d", steps, wantSteps)
	}
	for range steps {
		if !MoveLongLineChunk(e, false, false) {
			t.Fatal("backward chunk navigation stopped early")
		}
	}
	if e.Cursor != 0 {
		t.Fatalf("backward navigation stopped at %d, want 0", e.Cursor)
	}
}

func TestLongLineChunksDoNotSplitCommonGraphemeBoundaries(t *testing.T) {
	source := append([]byte(strings.Repeat("x", maxShapingBytes-1)), []byte("a\u0301👩‍💻אבג 123 ")...)
	source = append(source, []byte(strings.Repeat("y", maxShapingBytes+32))...)
	b := editor.NewBuffer(source)
	for _, anchor := range []int{maxShapingBytes, maxShapingBytes + len("a\u0301👩‍💻"), len(source)} {
		visual, ok := BuildVisualLineAround(&b, 0, anchor, DefaultTextStyle())
		if !ok {
			t.Fatalf("BuildVisualLineAround(%d) failed", anchor)
		}
		if !isEditorClusterBoundary(&b, visual.DocStart) || !isEditorClusterBoundary(&b, visual.DocEnd) {
			t.Fatalf("chunk %d has grapheme-splitting range %d:%d", visual.ChunkIndex, visual.DocStart, visual.DocEnd)
		}
		if anchor < visual.DocStart || anchor > visual.DocEnd {
			t.Fatalf("anchor %d outside chunk %d:%d", anchor, visual.DocStart, visual.DocEnd)
		}
		if len(visual.Text) > maxShapingBytes+maxChunkBoundaryBytes {
			t.Fatalf("chunk %d shaped %d bytes, want bounded expansion", visual.ChunkIndex, len(visual.Text))
		}
	}
	e := editor.NewScratchEditor(source)
	e.SetSelection(maxShapingBytes-1, maxShapingBytes+len("a\u0301👩‍💻"))
	visual, ok := BuildVisualLineAround(&e.Buffer, 0, e.Cursor, DefaultTextStyle())
	if !ok {
		t.Fatal("BuildVisualLineAround for cross-chunk selection failed")
	}
	from, to := visibleSelection(visual, e)
	if to <= from {
		t.Fatalf("cross-chunk selection = %d:%d, want visible selection", from, to)
	}
}

func TestWrappedVisualLineKeepsSourceByteMapping(t *testing.T) {
	source := []byte("one two three four five six seven eight nine ten")
	b := editor.NewBuffer(source)
	visual, ok := BuildVisualLineMax(&b, 0, 0, DefaultTextStyle(), 70)
	if !ok {
		t.Fatal("BuildVisualLineMax failed")
	}
	if len(visual.Layout.Lines) < 2 {
		t.Skip("Shirei has no usable font or the fixture did not wrap")
	}
	if got := visual.Height(20); got <= 20 {
		t.Fatalf("wrapped height = %v, want more than one row", got)
	}
	previousEnd := -1
	for i := range visual.Layout.Lines {
		start, end := visual.shapedLineRange(i)
		if start < previousEnd || end < start {
			t.Fatalf("wrapped source range %d = %d:%d after %d", i, start, end, previousEnd)
		}
		previousEnd = end
	}
	if previousEnd != len(visual.Runes) {
		t.Fatalf("wrapped source ended at rune %d, want %d", previousEnd, len(visual.Runes))
	}
}

func TestWrappedVisualLineHitTestingUsesVerticalRow(t *testing.T) {
	b := editor.NewBuffer([]byte("one two three four five six seven eight nine ten"))
	visual, ok := BuildVisualLineMax(&b, 0, 0, DefaultTextStyle(), 70)
	if !ok || len(visual.Layout.Lines) < 2 {
		t.Skip("Shirei has no usable font or the fixture did not wrap")
	}
	firstStart, firstEnd := visual.shapedLineRange(0)
	secondStart, _ := visual.shapedLineRange(1)
	if secondStart <= firstStart || firstEnd <= firstStart {
		t.Fatalf("unexpected wrapped ranges: first=%d:%d second=%d", firstStart, firstEnd, secondStart)
	}
	lineHeight := lineHeight(visual.Layout.Lines[0])
	got, _ := visual.HitTestAt(lineHeight+1, 0)
	if got < secondStart {
		t.Fatalf("second-row hit-test = %d, want at least %d", got, secondStart)
	}
}

func TestWrappedVisualLineHitTestUsesShireiBlockOrigin(t *testing.T) {
	b := editor.NewBuffer([]byte("one two three four five six seven eight nine ten"))
	style := DefaultTextStyle()
	visual, ok := BuildVisualLineMax(&b, 0, 0, style, 70)
	if !ok || len(visual.Layout.Lines) < 2 {
		t.Skip("Shirei has no usable font or the fixture did not wrap")
	}
	// ShapedTextLayout adds the same top padding above its first line that
	// CaretPosition now reports. Compare each row against Shirei's own public
	// cursor oracle after translating into its unpadded text coordinates.
	pad := visual.textBlockPaddingTop()
	for i, line := range visual.Layout.Lines {
		start, end := visual.shapedLineRange(i)
		if end <= start || line.Width <= 0 {
			continue
		}
		x := line.Width * 0.4
		y := pad + visual.lineTop(i) + lineHeight(line)/2
		want := ComputeCursorIndex(Rect{Size: Vec2{1000, visual.Height(20)}}, Vec2{x, y - pad}, Vec2{}, visual.Layout)
		got, _ := visual.HitTestAt(y, x)
		if got != want {
			t.Fatalf("wrapped row %d hit at (%v,%v) = %d, Shirei reference = %d", i, x, y, got, want)
		}
	}
}

func TestVisualLineAtYUsesConfiguredHeightForBlankRows(t *testing.T) {
	e := editor.NewScratchEditor([]byte("\nfilled"))
	style := DefaultTextStyle()
	cache := &visualLineCache{}
	rows := editor.IdentityRowMap(e.Buffer.LineCount())
	line, localY, visual, ok := visualLineAtY(e, rows, 19.9, style, 20, 0, cache, nil, nil, nil, 0, nil)
	if !ok || line != 0 || localY < 19 {
		t.Fatalf("blank row hit = line %d local y %v ok %v, want first 20px row", line, localY, ok)
	}
	line, localY, _, ok = visualLineAtY(e, rows, 20.1, style, 20, 0, cache, nil, nil, nil, 0, nil)
	if !ok || line != 1 || localY <= 0 {
		t.Fatalf("row after blank hit = line %d local y %v ok %v, want second row", line, localY, ok)
	}
	if got := visual.Height(20); got != 20 {
		t.Fatalf("blank visual height = %v, want configured row height 20", got)
	}
}

func TestEditorVerticalNavigationUsesWrappedRows(t *testing.T) {
	if shaped := ShapeText("probe", DefaultTextStyle()); len(shaped.Lines) == 0 {
		t.Skip("Shirei has no usable font in this headless unit-test context")
	}
	e := editor.NewScratchEditor([]byte("one two three four five six seven eight nine ten\nnext line"))
	style := DefaultTextStyle()
	cache := &visualLineCache{}
	rows := editor.IdentityRowMap(e.Buffer.LineCount())
	visual, ok := BuildVisualLineMax(&e.Buffer, 0, 0, style, 70)
	if !ok || len(visual.Layout.Lines) < 2 {
		t.Skip("fixture did not wrap")
	}
	e.SetCursor(1)
	if !moveEditorVerticalLayout(e, style, rows, 1, false, true, 70, cache, nil, nil, nil, 0) {
		t.Fatal("down within wrapped logical line did not move")
	}
	if line, ok := e.Buffer.LineAt(e.Cursor); !ok || line != 0 {
		t.Fatalf("wrapped down landed on logical line %d, want continuation row on line 0", line)
	}
	secondStart, _ := visual.shapedLineRange(1)
	if e.Cursor < visual.LocalRuneToByte(secondStart) {
		t.Fatalf("wrapped down cursor = %d, before continuation start %d", e.Cursor, visual.LocalRuneToByte(secondStart))
	}
	for i := 0; i < len(visual.Layout.Lines); i++ {
		if line, ok := e.Buffer.LineAt(e.Cursor); !ok || line != 0 {
			break
		}
		if !moveEditorVerticalLayout(e, style, rows, 1, false, true, 70, cache, nil, nil, nil, 0) {
			break
		}
	}
	if line, ok := e.Buffer.LineAt(e.Cursor); !ok || line != 1 {
		t.Fatalf("down through wrapped continuation landed on logical line %d, want line 1", line)
	}
}

func isEditorClusterBoundary(buffer *editor.Buffer, offset int) bool {
	if offset == 0 || offset == buffer.ByteLen() {
		return true
	}
	previous := buffer.PreviousCluster(offset)
	return buffer.NextCluster(previous) == offset
}

func TestVisualLineHitTestMatchesShireiReference(t *testing.T) {
	b := editor.NewBuffer([]byte("abc אבג def"))
	visual, ok := BuildVisualLine(&b, 0, DefaultTextStyle())
	if !ok {
		t.Fatal("BuildVisualLine failed")
	}
	if len(visual.Layout.Lines) == 0 {
		t.Skip("Shirei has no loaded font in this headless unit-test context")
	}
	content := Rect{Size: Vec2{1000, 32}}
	for x := float32(-1); x < visual.Layout.Lines[0].Width+2; x += 0.5 {
		want := ComputeCursorIndex(content, Vec2{x, 8}, Vec2{}, visual.Layout)
		got, _ := visual.HitTest(x)
		if got != want {
			t.Fatalf("hit-test x=%v = %d, Shirei reference = %d", x, got, want)
		}
	}
}

func TestVisualLineCaretAffinityRoundTrip(t *testing.T) {
	b := editor.NewBuffer([]byte("abc אבג def"))
	visual, ok := BuildVisualLine(&b, 0, DefaultTextStyle())
	if !ok || len(visual.Layout.Lines) == 0 {
		t.Skip("Shirei has no usable font in this headless unit-test context")
	}

	// Every hit-test result must be paintable at the same visual caret side.
	// This checks the custom byte/rune bridge without asserting a particular
	// font's advance widths.
	lineWidth := visual.Layout.Lines[0].Width
	for x := float32(0); x <= lineWidth; x += 0.75 {
		runeIndex, affinity := visual.HitTest(x)
		if got := visual.CaretX(runeIndex, affinity); got < -0.01 || got > lineWidth+0.01 {
			t.Fatalf("caret x=%v for hit x=%v outside line width %v", got, x, lineWidth)
		}
	}
}

func TestEditableViewPublishesKeyboardAndIMEGeometry(t *testing.T) {
	ResetInputSession()
	GetHost().HeadlessRender = true
	GetHost().WindowFocused = true
	GetHost().WindowSize = Vec2{400, 160}

	e := editor.NewScratchEditor([]byte("hello\nשלום"))
	scope := new(int)
	frame := func() {
		RunFrameFn(func() {
			ContainerWithKey(scope, Attrs(Viewport), func() {
				EditableView(scope, e, EditorViewOptions{
					Style:     DefaultTextStyle(),
					RowHeight: 20,
				})
			})
		})
	}

	frame()
	frame()
	GetInputState().Composition = "か"
	GetInputState().CompositionSel = [2]int{1, 1}
	frame()

	if !GetHost().WantsKeyboard {
		t.Fatal("editable view did not request native keyboard/text input")
	}
	if GetHost().CaretHeight <= 0 {
		t.Fatalf("caret height = %v, want positive geometry", GetHost().CaretHeight)
	}
	if GetHost().CompositionPos[1] <= 0 {
		t.Fatalf("composition position = %v, want screen-space IME anchor", GetHost().CompositionPos)
	}
}

func TestEditableViewScrollsVisibleRows(t *testing.T) {
	ResetInputSession()
	GetHost().HeadlessRender = true
	GetHost().WindowFocused = true
	GetHost().WindowSize = Vec2{500, 160}
	e := editor.NewScratchEditor([]byte(strings.Repeat("line\n", 200)))
	scope := new(int)
	var scrollY float32
	frame := func(scroll Vec2) {
		GetInputState().MousePoint = Vec2{250, 80}
		GetFrameInput().Mouse = 0
		GetFrameInput().Scroll = scroll
		GetFrameInput().Motion = Vec2{}
		GetFrameInput().Key = KeyCodeNone
		GetFrameInput().Text = ""
		RunFrameFn(func() {
			ContainerWithKey(scope, Attrs(Viewport), func() {
				EditableView(scope, e, EditorViewOptions{
					Style: DefaultTextStyle(), RowHeight: 20, ScrollY: &scrollY,
				})
			})
		})
	}
	for range 3 {
		frame(Vec2{})
	}
	before := scrollY
	frame(Vec2{0, 100})
	if scrollY <= before {
		t.Fatalf("editor did not scroll: before=%v after=%v", before, scrollY)
	}
	for range 3 {
		frame(Vec2{})
	}
	if scrollY <= before {
		t.Fatalf("editor scroll did not persist: before=%v after=%v", before, scrollY)
	}
}

func TestEditableViewScrolledClickUsesRenderedRowGeometry(t *testing.T) {
	ResetInputSession()
	GetHost().HeadlessRender = true
	GetHost().WindowFocused = true
	GetHost().WindowSize = Vec2{500, 120}
	e := editor.NewScratchEditor([]byte(strings.Repeat("row\n", 40)))
	scope := new(int)
	var scrollY float32
	var pendingScroll Vec2
	frame := func(mouse Vec2, action MouseAction) {
		GetInputState().MousePoint = mouse
		GetFrameInput().Mouse = action
		GetFrameInput().Scroll = pendingScroll
		pendingScroll = Vec2{}
		GetFrameInput().Motion = Vec2{}
		GetFrameInput().Key = KeyCodeNone
		GetFrameInput().Text = ""
		RunFrameFn(func() {
			ContainerWithKey(scope, Attrs(Viewport), func() {
				EditableView(scope, e, EditorViewOptions{
					Style: DefaultTextStyle(), RowHeight: 20, ScrollY: &scrollY, ScrollInitialized: true,
				})
			})
		})
	}
	for range 3 {
		frame(Vec2{250, 10}, 0)
	}
	// One row is scrolled offscreen. A click in the first painted row must
	// resolve against the row after the scroll offset, using the same 20px
	// geometry used by the virtual list.
	pendingScroll = Vec2{0, 20}
	frame(Vec2{250, 80}, 0)
	for range 2 {
		frame(Vec2{250, 80}, 0)
	}
	frame(Vec2{10, 10}, MouseClick)
	line, ok := e.Buffer.LineAt(e.Cursor)
	if !ok || line != 1 {
		t.Fatalf("scrolled click cursor=%d landed on line %d, want line 1", e.Cursor, line)
	}
	frame(Vec2{10, 10}, MouseRelease)
}

func TestEditorMouseSelectionUsesWordAndLineGranularity(t *testing.T) {
	e := editor.NewScratchEditor([]byte("hello world\nsecond line"))
	selection := &editorMouseSelectionState{}
	world := len([]byte("hello "))
	applyEditorClickSelection(e, selection, 0, world+2, 2, false)
	if anchor, cursor := e.Selection(); anchor != world || cursor != len([]byte("hello world")) {
		t.Fatalf("double-click selection = %d:%d, want %d:%d", anchor, cursor, world, len([]byte("hello world")))
	}
	if !selection.WordDrag {
		t.Fatal("double-click did not arm word-wise drag")
	}
	selectDraggedWord(e, selection, len([]byte("hello world\nsecon")))
	if anchor, cursor := e.Selection(); anchor != world || cursor != len([]byte("hello world\nsecond")) {
		t.Fatalf("word drag selection = %d:%d, want %d:%d", anchor, cursor, world, len([]byte("hello world\nsecond")))
	}
	applyEditorClickSelection(e, selection, 1, len([]byte("hello world\nsecond")), 3, false)
	if anchor, cursor := e.Selection(); anchor != len([]byte("hello world\n")) || cursor != len([]byte("hello world\nsecond line")) {
		t.Fatalf("triple-click selection = %d:%d, want %d:%d", anchor, cursor, len([]byte("hello world\n")), len([]byte("hello world\nsecond line")))
	}
	if selection.WordDrag {
		t.Fatal("triple-click left word-wise drag armed")
	}
}

func TestEditableViewTextParityWithTextArea(t *testing.T) {
	if shaped := ShapeText("probe", DefaultTextStyle()); len(shaped.Lines) == 0 {
		t.Skip("Shirei has no usable font in this headless unit-test context")
	}

	type operation struct {
		text string
		key  KeyCode
		mods Modifiers
	}
	operations := []operation{
		{text: "A\u0301👩‍💻\nאבג"},
		{key: KeyDeleteBackward},
		{key: KeyA, mods: PrimaryMod()},
		{key: KeyDeleteBackward},
		{text: "xy"},
		{key: KeyZ, mods: PrimaryMod()},
		{key: KeyZ, mods: PrimaryMod() | ModShift},
	}

	run := func(useTextArea bool) []string {
		ResetInputSession()
		GetHost().HeadlessRender = true
		GetHost().WindowFocused = true
		GetHost().WindowSize = Vec2{500, 220}
		scope := new(int)
		text := "seed\nשלום"
		custom := editor.NewScratchEditor([]byte(text))
		frame := func() {
			RunFrameFn(func() {
				ContainerWithKey(scope, Attrs(Viewport), func() {
					if useTextArea {
						attrs := DefaultMultilineTextInputAttrs()
						attrs.FixedWidth = true
						TextInputExt(&text, attrs)
					} else {
						EditableView(scope, custom, EditorViewOptions{
							Style:     DefaultTextStyle(),
							RowHeight: 20,
						})
					}
				})
			})
		}
		for i := 0; i < 3; i++ {
			frame()
		}
		values := []string{currentText(useTextArea, &text, custom)}
		for _, op := range operations {
			GetInputState().Modifiers = op.mods
			GetFrameInput().Text = op.text
			GetFrameInput().Key = op.key
			frame()
			GetInputState().Modifiers = 0
			frame()
			values = append(values, currentText(useTextArea, &text, custom))
		}
		return values
	}

	textArea := run(true)
	custom := run(false)
	if len(textArea) != len(custom) {
		t.Fatalf("parity fixture lengths differ: TextArea=%d custom=%d", len(textArea), len(custom))
	}
	for i := range textArea {
		if textArea[i] != custom[i] {
			t.Fatalf("operation %d: TextArea text %q, custom text %q", i, textArea[i], custom[i])
		}
	}
}

func TestEditorLineBoundaryNavigationExtendsSelection(t *testing.T) {
	e := editor.NewScratchEditor([]byte("abcd\nxy"))
	e.SetCursor(2)
	if !moveEditorLineBoundary(e, false, false) || e.Cursor != 0 || e.Anchor != 0 {
		t.Fatalf("home = cursor %d anchor %d, want 0:0", e.Cursor, e.Anchor)
	}
	if !moveEditorLineBoundary(e, true, true) || e.Cursor != 4 || e.Anchor != 0 {
		t.Fatalf("shift-end = cursor %d anchor %d, want 4:0", e.Cursor, e.Anchor)
	}
	if !moveEditorLineBoundary(e, false, true) || e.Cursor != 0 || e.Anchor != 0 {
		t.Fatalf("shift-home = cursor %d anchor %d, want 0:0", e.Cursor, e.Anchor)
	}
}

func TestEditorVerticalNavigationUsesVisibleRows(t *testing.T) {
	if shaped := ShapeText("probe", DefaultTextStyle()); len(shaped.Lines) == 0 {
		t.Skip("Shirei has no usable font in this headless unit-test context")
	}
	e := editor.NewScratchEditor([]byte("abcd\nh\nlong"))
	e.SetCursor(2)
	rows := editor.NewRowMap(e.Buffer.LineCount(), []editor.HiddenLineRange{{Start: 1, End: 2}})
	if !moveEditorVertical(e, DefaultTextStyle(), rows, 1, false) {
		t.Fatal("down did not move")
	}
	line, ok := e.Buffer.LineAt(e.Cursor)
	if !ok || line != 2 {
		t.Fatalf("down landed on logical line %d, want 2", line)
	}
	if targetLine, ok := e.Buffer.LineAt(e.Cursor); !ok || targetLine != 2 {
		t.Fatalf("down cursor = %d, outside target line", e.Cursor)
	}
	anchor := e.Cursor
	if !moveEditorVertical(e, DefaultTextStyle(), rows, -1, true) {
		t.Fatal("shift-up did not move")
	}
	if e.Anchor != anchor {
		t.Fatalf("shift-up selection = %d:%d, want anchor %d on visible target", e.Anchor, e.Cursor, anchor)
	}
	if targetLine, ok := e.Buffer.LineAt(e.Cursor); !ok || targetLine != 0 {
		t.Fatalf("shift-up cursor = %d, landed on line %d", e.Cursor, targetLine)
	}

	e = editor.NewScratchEditor([]byte("abcdef\nx\nabcdef"))
	e.SetCursor(5)
	rows = editor.IdentityRowMap(e.Buffer.LineCount())
	if !moveEditorVertical(e, DefaultTextStyle(), rows, 1, false) || !moveEditorVertical(e, DefaultTextStyle(), rows, 1, false) {
		t.Fatal("consecutive down did not move through short line")
	}
	if line, ok := e.Buffer.LineAt(e.Cursor); !ok || line != 2 || e.Cursor != 14 {
		t.Fatalf("preferred column lost after short line: cursor=%d line=%d", e.Cursor, line)
	}
	e.MoveLeft(false)
	if _, ok := e.PreferredVerticalX(); ok {
		t.Fatal("horizontal movement retained preferred vertical X")
	}
}

func TestEditableViewDispatchesLineNavigationKeys(t *testing.T) {
	if shaped := ShapeText("probe", DefaultTextStyle()); len(shaped.Lines) == 0 {
		t.Skip("Shirei has no usable font in this headless unit-test context")
	}
	ResetInputSession()
	GetHost().HeadlessRender = true
	GetHost().WindowFocused = true
	GetHost().WindowSize = Vec2{500, 160}
	e := editor.NewScratchEditor([]byte("abcd\nxy\nlong"))
	scope := new(int)
	runKey := func(key KeyCode, mods Modifiers) {
		GetInputState().Modifiers = mods
		GetFrameInput().Key = key
		GetFrameInput().Text = ""
		GetFrameInput().Mouse = 0
		RunFrameFn(func() {
			ContainerWithKey(scope, Attrs(Viewport), func() {
				EditableView(scope, e, EditorViewOptions{Style: DefaultTextStyle(), RowHeight: 20})
			})
		})
		GetInputState().Modifiers = 0
		GetFrameInput().Key = KeyCodeNone
	}
	for range 2 {
		runKey(KeyCodeNone, 0)
	}
	e.SetCursor(2)
	runKey(KeyEnd, 0)
	if e.Cursor != 4 {
		t.Fatalf("end dispatch = %d, want 4", e.Cursor)
	}
	runKey(KeyHome, ModShift)
	if e.Cursor != 0 || e.Anchor != 4 {
		t.Fatalf("shift-home dispatch = %d:%d, want 0:4", e.Anchor, e.Cursor)
	}
	e.SetCursor(2)
	runKey(KeyDown, 0)
	if line, ok := e.Buffer.LineAt(e.Cursor); !ok || line != 1 {
		t.Fatalf("down dispatch landed at %d, want line 1", e.Cursor)
	}
	runKey(KeyUp, ModShift)
	if line, ok := e.Buffer.LineAt(e.Cursor); !ok || line != 0 || e.Anchor == e.Cursor {
		t.Fatalf("shift-up dispatch = %d:%d, want extended selection on line 0", e.Anchor, e.Cursor)
	}
}

func TestEditableViewDispatchesCRLFEnterAndDuplicate(t *testing.T) {
	if shaped := ShapeText("probe", DefaultTextStyle()); len(shaped.Lines) == 0 {
		t.Skip("Shirei has no usable font in this headless unit-test context")
	}
	setup := func(e *editor.ScratchEditor, scope *int) func(KeyCode, Modifiers) {
		ResetInputSession()
		GetHost().HeadlessRender = true
		GetHost().WindowFocused = true
		GetHost().WindowSize = Vec2{500, 160}
		runKey := func(key KeyCode, mods Modifiers) {
			GetInputState().Modifiers = mods
			GetFrameInput().Key = key
			GetFrameInput().Text = ""
			GetFrameInput().Mouse = 0
			RunFrameFn(func() {
				ContainerWithKey(scope, Attrs(Viewport), func() {
					EditableView(scope, e, EditorViewOptions{Style: DefaultTextStyle(), RowHeight: 20})
				})
			})
			GetInputState().Modifiers = 0
			GetFrameInput().Key = KeyCodeNone
		}
		for range 2 {
			runKey(KeyCodeNone, 0)
		}
		return runKey
	}

	e := editor.NewScratchEditor([]byte("  a\r\n  b\r\n"))
	e.SetCursor(len([]byte("  a")))
	runKey := setup(e, new(int))
	runKey(KeyEnter, 0)
	if got := string(e.Buffer.Text()); got != "  a\r\n  \r\n  b\r\n" {
		t.Fatalf("keyboard CRLF Enter = %q", got)
	}

	e = editor.NewScratchEditor([]byte("a\r\nb\r\n"))
	e.SetCursor(len([]byte("a\r\nb")))
	runKey = setup(e, new(int))
	runKey(KeyDown, ModAlt|ModShift)
	if got := string(e.Buffer.Text()); got != "a\r\nb\r\nb\r\n" {
		t.Fatalf("keyboard CRLF duplicate down = %q", got)
	}
}

func currentText(useTextArea bool, text *string, custom *editor.ScratchEditor) string {
	if useTextArea {
		return *text
	}
	return string(custom.Buffer.Text())
}

// TestVisualLineCacheRebuildsWhenPresentationArrivesAtSameRevision reproduces
// the async Markdown race: the first frame at an editor revision caches an
// unstyled layout while projections are pending, and the later frame at the
// same revision must rebuild with styled spans instead of hitting the stale
// entry.
func TestVisualLineCacheRebuildsWhenPresentationArrivesAtSameRevision(t *testing.T) {
	buffer := editor.NewBuffer([]byte("# hello"))
	style := DefaultTextStyle()
	cache := &visualLineCache{}
	const revision uint64 = 7
	const width float32 = 500

	// First frame: derived projections pending, no presentation source.
	cache.prepare(revision, width, true, 0)
	plain, ok := cachedVisualLine(cache, &buffer, 0, 0, style, width, nil, nil, nil)
	if !ok {
		t.Fatal("unstyled visual line failed")
	}
	if len(plain.layoutSpans) != 0 {
		t.Fatalf("unstyled layout spans = %d, want 0", len(plain.layoutSpans))
	}

	// Same editor revision, async worker publishes: presentation appears.
	presentation := func(startByte, endByte int) []document.PresentationSpan {
		return []document.PresentationSpan{{StartByte: 0, EndByte: 7, Kind: document.PresentationHeading}}
	}
	cache.prepare(revision, width, true, 1)
	styled, ok := cachedVisualLine(cache, &buffer, 0, 0, style, width, presentation, MarkdownPresentationStyle, MarkdownPresentationSpanStyle)
	if !ok {
		t.Fatal("styled visual line failed")
	}
	if len(styled.layoutSpans) == 0 {
		t.Fatal("same-revision presentation arrival reused the unstyled cache entry")
	}

	// Same presentation key must keep the cache (no rebuild churn).
	cached, ok := cachedVisualLine(cache, &buffer, 0, 0, style, width, presentation, MarkdownPresentationStyle, MarkdownPresentationSpanStyle)
	if !ok || len(cached.layoutSpans) == 0 {
		t.Fatal("same-key lookup lost the styled entry")
	}
	if len(cache.Order) != 1 {
		t.Fatalf("same-key lookups grew cache order to %d, want 1", len(cache.Order))
	}

	// Presentation disappearing at the same revision must also invalidate.
	cache.prepare(revision, width, true, 0)
	again, ok := cachedVisualLine(cache, &buffer, 0, 0, style, width, nil, nil, nil)
	if !ok {
		t.Fatal("unstyled rebuild failed")
	}
	if len(again.layoutSpans) != 0 {
		t.Fatalf("presentation removal kept styled spans = %d, want 0", len(again.layoutSpans))
	}
}

func TestDocumentPresentationKeySeparatesPendingFromPublished(t *testing.T) {
	doc := document.New("notes.md", []byte("# hello"), "markdown")
	revision := doc.Revision()

	if got := documentPresentationKey(doc, false); got != 0 {
		t.Fatalf("nil presentation key = %d, want 0", got)
	}
	stale := documentPresentationKey(doc, true)
	if stale == 0 {
		t.Fatal("stale presentation key must be non-zero when presentation is present")
	}
	projections := document.Projections{
		Revision: revision,
		Markdown: document.NewMarkdownPresentation(revision, []document.PresentationSpan{
			{StartByte: 0, EndByte: 7, Kind: document.PresentationHeading},
		}),
		Code: document.NewCodeProjection(revision, "markdown", nil, nil, nil),
	}
	if !doc.SetDerived(nil, projections) {
		t.Fatal("SetDerived rejected the current-revision projections")
	}
	fresh := documentPresentationKey(doc, true)
	if fresh == 0 {
		t.Fatal("published presentation key must be non-zero")
	}
	if fresh == stale {
		t.Fatal("presentation key did not change when projections arrived at the same editor revision")
	}

	var nilOptions EditorViewOptions
	if got := effectivePresentationKey(nilOptions); got != 0 {
		t.Fatalf("nil presentation effective key = %d, want 0", got)
	}
	unversioned := EditorViewOptions{
		Presentation: func(startByte, endByte int) []document.PresentationSpan { return nil },
	}
	if got := effectivePresentationKey(unversioned); got == 0 {
		t.Fatal("non-nil presentation with zero key must map to a non-zero effective key")
	}
	light := ScratchpadLightTheme()
	dark := ScratchpadDarkTheme()
	if got := effectivePresentationKey(EditorViewOptions{Theme: light}); got == 0 {
		t.Fatal("theme generation must version an otherwise unstyled cache")
	} else if got == effectivePresentationKey(EditorViewOptions{Theme: dark}) {
		t.Fatal("light and dark themes must not share a presentation cache key")
	}
	if got := effectivePresentationKey(EditorViewOptions{Presentation: unversioned.Presentation, Theme: light}); got == effectivePresentationKey(EditorViewOptions{Presentation: unversioned.Presentation, Theme: dark}) {
		t.Fatal("theme generation must invalidate styled rows")
	}
}

func BenchmarkWrappedVisualLine(b *testing.B) {
	for _, size := range []int{1 << 20, 10 << 20} {
		b.Run(wrappedSizeName(size), func(b *testing.B) {
			line := "A calm sentence with enough words to wrap across the available paper surface.\n"
			source := []byte(strings.Repeat(line, size/len(line)+1))
			buffer := editor.NewBuffer(source[:size])
			style := DefaultTextStyle()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				_, _ = BuildVisualLineMax(&buffer, i%buffer.LineCount(), 0, style, 640)
			}
		})
	}
}

func wrappedSizeName(size int) string {
	if size >= 10<<20 {
		return "10MiB"
	}
	return "1MiB"
}

// TestTableLinesOptOutOfSoftWrap pins the source-visible table policy: table
// lines intersect a BlockTable projection and shape unwrapped (width 0) while
// surrounding prose keeps the shared wrap width. Stale projections exempt
// nothing, and non-wrapping documents resolve every line to 0.
func TestTableLinesOptOutOfSoftWrap(t *testing.T) {
	source := []byte("A comfortable paragraph with enough words to wrap across rows.\n\n| name | value |\n| :--- | ---: |\n| one | two |\n\nTrailing prose.\n")
	doc := document.New("notes.md", source, "markdown")
	if !doc.SetDerived(nil, markdown.Project(source, doc.Revision())) {
		t.Fatal("SetDerived rejected the current-revision projections")
	}
	// Lines 0 and 6 are prose, 1 and 5 are blank, 2-4 are the table.
	for _, line := range []int{2, 3, 4} {
		if !isTableLine(doc, line) {
			t.Errorf("line %d is not a table line (blocks=%+v)", line, doc.Projections.Blocks)
		}
	}
	for _, line := range []int{0, 1, 5, 6} {
		if isTableLine(doc, line) {
			t.Errorf("line %d is a table line, want the shared prose policy", line)
		}
	}
	options := EditorViewOptions{Wrap: true, NoWrapLine: func(logical int) bool { return isTableLine(doc, logical) }}
	const fullWidth float32 = 200
	for _, line := range []int{2, 3, 4} {
		if got := wrapWidthForLine(options, line, fullWidth); got != 0 {
			t.Errorf("table line %d width = %v, want 0 (unwrapped with horizontal overflow)", line, got)
		}
	}
	for _, line := range []int{0, 6} {
		if got := wrapWidthForLine(options, line, fullWidth); got != fullWidth {
			t.Errorf("prose line %d width = %v, want %v", line, got, fullWidth)
		}
	}
	if got := wrapWidthForLine(EditorViewOptions{Wrap: true}, 2, fullWidth); got != fullWidth {
		t.Errorf("nil NoWrapLine width = %v, want shared %v", got, fullWidth)
	}
	if got := wrapWidthForLine(EditorViewOptions{}, 0, fullWidth); got != 0 {
		t.Errorf("unwrapped document width = %v, want 0", got)
	}
	if isTableLine(nil, 0) {
		t.Error("nil document is a table line, want false")
	}
	plain := document.New("main.go", []byte("package main\n"), "go")
	if isTableLine(plain, 0) {
		t.Error("non-Markdown document is a table line, want false")
	}
	doc.InvalidateDerived()
	for line := 0; line < 7; line++ {
		if isTableLine(doc, line) {
			t.Fatalf("stale line %d is still a table line, want no exemption", line)
		}
	}
}

func TestOverflowLaneHelpers(t *testing.T) {
	if got := overflowXOffset(120, false); got != 0 {
		t.Fatalf("wrapped offset = %v, want 0", got)
	}
	if got := overflowXOffset(120, true); got != -120 {
		t.Fatalf("overflow offset = %v, want -120", got)
	}
	if got := overflowHitX(40, 120, true); got != 160 {
		t.Fatalf("overflow hit x = %v, want 160", got)
	}
	if got := overflowHitX(40, 120, false); got != 40 {
		t.Fatalf("wrapped hit x = %v, want 40", got)
	}
	if got := adjustScrollXForCaret(0, 12, 200, true); got != 0 {
		t.Fatalf("initial caret adjustment = %v, want 0", got)
	}
	if got := adjustScrollXForCaret(0, 300, 200, true); got != 116 {
		t.Fatalf("right caret adjustment = %v, want 116", got)
	}
	if got := adjustScrollXForCaret(200, 80, 200, true); got != 64 {
		t.Fatalf("left caret adjustment = %v, want 64", got)
	}
	if got := adjustScrollXForCaret(200, 300, 200, false); got != 0 {
		t.Fatalf("wrapped caret adjustment = %v, want 0", got)
	}
}

func TestCurrentEditorLineBackground(t *testing.T) {
	theme := DefaultTheme()
	if got := currentEditorLineBackground(theme, Vec4{}, false); got != (Vec4{}) {
		t.Fatalf("inactive background = %v, want zero", got)
	}
	got := currentEditorLineBackground(theme, Vec4{}, true)
	if got == (Vec4{}) || got[3] != currentLineHighlightAlpha {
		t.Fatalf("active background = %v, want highlight alpha %v", got, currentLineHighlightAlpha)
	}

	decoration := theme.ChromeRaised
	decoration[3] = 0.16
	got = currentEditorLineBackground(theme, decoration, true)
	if got[3] <= decoration[3] || got[3] > 1 {
		t.Fatalf("active decorated background alpha = %v, want greater than %v and at most 1", got[3], decoration[3])
	}
	decoration[3] = 0.96
	if got := currentEditorLineBackground(theme, decoration, true); got[3] != 1 {
		t.Fatalf("active decorated background alpha = %v, want clamped 1", got[3])
	}
}

func TestMarkdownTableLayoutPolicyCoversHitTestingAndVerticalNavigation(t *testing.T) {
	source := []byte("A comfortable paragraph with enough words to wrap across several visual rows.\n\n| name | value | another column | a final wide column |\n| :--- | ---: | :--- | :--- |\n| one | two | three | four five six seven eight nine ten eleven |\nTrailing paragraph follows the table and should be reachable by the next visual row.\n")
	doc := document.New("notes.md", source, "markdown")
	if !doc.SetDerived(nil, markdown.Project(source, doc.Revision())) {
		t.Fatal("SetDerived rejected the current-revision projections")
	}
	firstTable := -1
	lastTable := -1
	for line := 0; line < doc.Editor.Buffer.LineCount(); line++ {
		if isTableLine(doc, line) {
			if firstTable < 0 {
				firstTable = line
			}
			lastTable = line
		}
	}
	if firstTable < 0 || lastTable+1 >= doc.Editor.Buffer.LineCount() {
		t.Fatalf("table projection did not leave a following paragraph: first=%d last=%d lines=%d", firstTable, lastTable, doc.Editor.Buffer.LineCount())
	}

	style := DefaultTextStyle()
	const width float32 = 100
	const rowHeight float32 = 20
	options := EditorViewOptions{Wrap: true, NoWrapLine: func(line int) bool { return isTableLine(doc, line) }}
	lineWidthFor := func(line int) float32 { return wrapWidthForLine(options, line, width) }
	rows := editor.IdentityRowMap(doc.Editor.Buffer.LineCount())
	cache := &visualLineCache{}

	globalTable, ok := BuildVisualLineMax(&doc.Editor.Buffer, firstTable, 0, style, width)
	if !ok || len(globalTable.Layout.Lines) < 2 {
		t.Fatalf("wide table layout rows = %d, want at least two with the shared width", len(globalTable.Layout.Lines))
	}
	table, ok := BuildVisualLineMax(&doc.Editor.Buffer, firstTable, 0, style, lineWidthFor(firstTable))
	if !ok || len(table.Layout.Lines) != 1 {
		t.Fatalf("table layout rows = %d, want one unwrapped row", len(table.Layout.Lines))
	}

	top := float32(0)
	for line := 0; line < firstTable; line++ {
		visual, ok := BuildVisualLineMax(&doc.Editor.Buffer, line, 0, style, lineWidthFor(line))
		if !ok {
			t.Fatalf("line %d shaping failed", line)
		}
		top += visual.Height(rowHeight)
	}
	tableHeight := table.Height(rowHeight)
	insideLine, insideY, insideVisual, ok := visualLineAtYWithWrapPolicy(doc.Editor, rows, top+tableHeight/2, style, rowHeight, width, lineWidthFor, cache, nil, nil, nil, 0, nil)
	if !ok || insideLine != firstTable || insideY <= 0 || insideY >= tableHeight {
		t.Fatalf("click inside table mapped to line %d local y %v, want table line %d within height %v", insideLine, insideY, firstTable, tableHeight)
	}
	if insideVisual.WrapWidth != 0 || len(insideVisual.Layout.Lines) != 1 {
		t.Fatalf("click inside table returned wrap width %v with %d visual rows, want unwrapped single-row layout", insideVisual.WrapWidth, len(insideVisual.Layout.Lines))
	}

	following := lastTable + 1
	followingVisual, ok := BuildVisualLineMax(&doc.Editor.Buffer, following, 0, style, lineWidthFor(following))
	if !ok {
		t.Fatal("following paragraph shaping failed")
	}
	followingTop := top + tableHeight
	for line := firstTable + 1; line < following; line++ {
		visual, ok := BuildVisualLineMax(&doc.Editor.Buffer, line, 0, style, lineWidthFor(line))
		if !ok {
			t.Fatalf("line %d shaping failed", line)
		}
		followingTop += visual.Height(rowHeight)
	}
	belowLine, _, _, ok := visualLineAtYWithWrapPolicy(doc.Editor, rows, followingTop+followingVisual.Height(rowHeight)/2, style, rowHeight, width, lineWidthFor, cache, nil, nil, nil, 0, nil)
	if !ok || belowLine != following {
		t.Fatalf("click below table mapped to line %d, want following paragraph line %d", belowLine, following)
	}

	start, end, ok := doc.Editor.Buffer.LineRange(lastTable)
	if !ok {
		t.Fatal("table line range unavailable")
	}
	doc.Editor.SetCursor(start + minInt(8, end-start))
	if !moveEditorVerticalLayoutWithWrapPolicy(doc.Editor, style, rows, 1, false, true, width, lineWidthFor, cache, nil, nil, nil, 0) {
		t.Fatal("down from table did not move")
	}
	if line, ok := doc.Editor.Buffer.LineAt(doc.Editor.Cursor); !ok || line != following {
		t.Fatalf("down from table landed on line %d, want following paragraph line %d", line, following)
	}
}
