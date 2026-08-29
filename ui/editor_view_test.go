package ui

import (
	"strings"
	"testing"
	"unicode/utf8"

	"scratchpad/editor"

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

func currentText(useTextArea bool, text *string, custom *editor.ScratchEditor) string {
	if useTextArea {
		return *text
	}
	return string(custom.Buffer.Text())
}
