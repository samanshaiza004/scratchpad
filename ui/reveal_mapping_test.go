package ui

import (
	"bytes"
	"strings"
	"testing"

	"scratchpad/application"
	"scratchpad/commands"
	"scratchpad/document"
	"scratchpad/editor"
	"scratchpad/language/markdown"

	. "go.hasen.dev/shirei"
)

// TestRevealMappingUsesCompactVisibleIndices pins the coordinate conversion
// required by the editor virtual list. The list index is the compact visible
// index, while its item key remains the logical source line.
func TestRevealMappingUsesCompactVisibleIndices(t *testing.T) {
	source := []byte("# Intro\nintro\n\n## Hidden\nhidden target\n\n## Visible\nvisible target\n")
	doc := document.New("notes.md", source, "markdown")
	if !doc.SetDerived(nil, markdown.Project(source, doc.Revision())) {
		t.Fatal("SetDerived rejected current Markdown projection")
	}

	view := application.ViewState{
		CollapsedHeadings: map[int]bool{doc.Projections.Headings[1].StartByte: true},
	}
	rows := rowMapForDocument(doc, view)

	hiddenOffset := bytes.Index(source, []byte("hidden target"))
	hiddenLine, ok := doc.Editor.Buffer.LineAt(hiddenOffset)
	if !ok {
		t.Fatal("hidden target did not map to a logical line")
	}
	if _, ok := rows.Visible(hiddenLine); ok {
		t.Fatalf("folded logical line %d was reported visible", hiddenLine)
	}

	visibleOffset := bytes.Index(source, []byte("visible target"))
	visibleLine, ok := doc.Editor.Buffer.LineAt(visibleOffset)
	if !ok {
		t.Fatal("visible target did not map to a logical line")
	}
	visibleIndex, ok := rows.Visible(visibleLine)
	if !ok {
		t.Fatalf("visible logical line %d was reported hidden", visibleLine)
	}
	if visibleIndex == visibleLine {
		t.Fatalf("visible index %d equals logical line %d; test fixture did not exercise compaction", visibleIndex, visibleLine)
	}
	if got, ok := rows.Logical(visibleIndex); !ok || got != visibleLine {
		t.Fatalf("visible index %d mapped back to logical line %d,%v; want %d,true", visibleIndex, got, ok, visibleLine)
	}
}

func TestRevealMappingKeepsByteRangeOnLogicalLine(t *testing.T) {
	source := []byte("first\nA long prose line containing the target near its wrapped continuation.\nlast")
	b := editor.NewBuffer(source)
	target := bytes.Index(source, []byte("target"))
	line, ok := b.LineAt(target)
	if !ok || line != 1 {
		t.Fatalf("target byte %d mapped to line %d,%v; want line 1,true", target, line, ok)
	}
	start, end, ok := b.LineRange(line)
	if !ok || target < start || target >= end {
		t.Fatalf("target byte %d is outside line range %d:%d", target, start, end)
	}

	visual, ok := BuildVisualLineMax(&b, line, target, DefaultTextStyle(), 90)
	if !ok {
		t.Fatal("BuildVisualLineMax failed for wrapped navigation target")
	}
	if visual.DocStart > target || target > visual.DocEnd {
		t.Fatalf("visual range %d:%d does not contain target byte %d", visual.DocStart, visual.DocEnd, target)
	}
	if len(visual.Layout.Lines) < 2 {
		t.Skip("Shirei did not wrap the prose fixture in this font context")
	}
	localRune := visual.LocalByteToRune(target)
	if got := visual.LocalRuneToByte(localRune); got != target {
		t.Fatalf("wrapped target byte round trip = %d, want %d", got, target)
	}
}

func TestRowMapForDocumentDoesNotFoldHeadingItself(t *testing.T) {
	source := []byte("# Parent\nparent body\n\n## Child\nchild body\n\nTail\n")
	doc := document.New("notes.md", source, "markdown")
	if !doc.SetDerived(nil, markdown.Project(source, doc.Revision())) {
		t.Fatal("SetDerived rejected current Markdown projection")
	}
	if len(doc.Projections.Headings) < 2 {
		t.Fatal("fixture did not produce nested headings")
	}
	view := application.ViewState{CollapsedHeadings: map[int]bool{doc.Projections.Headings[0].StartByte: true}}
	rows := rowMapForDocument(doc, view)
	parentLine, ok := doc.Editor.Buffer.LineAt(doc.Projections.Headings[0].StartByte)
	if !ok {
		t.Fatal("parent heading did not map to a logical line")
	}
	if _, ok := rows.Visible(parentLine); !ok {
		t.Fatal("collapsed heading itself is hidden; only its body should be folded")
	}
	childLine, ok := doc.Editor.Buffer.LineAt(doc.Projections.Headings[1].StartByte)
	if !ok {
		t.Fatal("child heading did not map to a logical line")
	}
	if _, ok := rows.Visible(childLine); ok {
		t.Fatal("child heading remained visible inside collapsed parent")
	}
}

func TestExpandFoldsForRevealOpensOnlyContainingFold(t *testing.T) {
	source := []byte("# Parent\nparent body\n\n## Child\nchild body\n\nTail\n")
	doc := document.New("notes.md", source, "markdown")
	if !doc.SetDerived(nil, markdown.Project(source, doc.Revision())) {
		t.Fatal("SetDerived rejected current Markdown projection")
	}
	if len(doc.Projections.Headings) < 2 || len(doc.Projections.Folds) < 2 {
		t.Fatal("fixture did not produce nested heading folds")
	}
	target := bytes.Index(source, []byte("parent body"))
	parentHeading := doc.Projections.Headings[0].StartByte
	childHeading := doc.Projections.Headings[1].StartByte
	view := &application.ViewState{CollapsedHeadings: map[int]bool{
		parentHeading: true,
		childHeading:  true,
	}}
	if !expandFoldsForReveal(doc, view, target) {
		t.Fatal("hidden target did not expand its containing fold")
	}
	if view.CollapsedHeadings[parentHeading] {
		t.Fatal("containing parent fold remained collapsed")
	}
	if !view.CollapsedHeadings[childHeading] {
		t.Fatal("unrelated child fold was expanded; target is in parent body")
	}
}

func TestNavigateToSelectionQueuesCurrentRevisionReveal(t *testing.T) {
	doc := document.New("notes.txt", []byte("before\nneedle\nafter"), "text")
	shell := &workbenchState{}
	id := application.DocumentID("notes.txt")
	navigateToSelection(shell, id, doc, 7, 13, RevealCenterIfOutside)
	anchor, cursor := doc.Editor.Selection()
	if anchor != 7 || cursor != 13 {
		t.Fatalf("selection = %d:%d, want 7:13", anchor, cursor)
	}
	request, ok := shell.RevealRequests[id]
	if !ok {
		t.Fatal("navigation did not queue an editor reveal request")
	}
	if request.StartByte != 7 || request.EndByte != 13 || request.Policy != RevealCenterIfOutside || !request.Horizontal {
		t.Fatalf("reveal request = %+v", request)
	}
	if request.Generation != doc.Revision() {
		t.Fatalf("reveal generation = %d, want current revision %d", request.Generation, doc.Revision())
	}
}

func TestOutlineNavigationQueuesNearTopReveal(t *testing.T) {
	doc := document.New("main.go", []byte("package main\n\nfunc main() {}\n"), "go")
	shell := &workbenchState{}
	id := application.DocumentID(doc.Path)
	navigateToCursor(shell, id, doc, bytes.Index(doc.Editor.Buffer.Text(), []byte("func")), RevealNearTop)
	request, ok := shell.RevealRequests[id]
	if !ok {
		t.Fatal("outline navigation did not queue an editor reveal request")
	}
	if request.Policy != RevealNearTop || request.StartByte != request.EndByte {
		t.Fatalf("outline reveal request = %+v", request)
	}
}

func TestFindRevealKeepsKeyboardFocusInFindField(t *testing.T) {
	ResetInputSession()
	t.Cleanup(ResetInputSession)
	GetHost().HeadlessRender = true
	GetHost().WindowFocused = true
	GetHost().WindowSize = Vec2{500, 160}

	doc := document.New("notes.txt", []byte("first needle\nsecond needle\nthird needle"), "text")
	state := application.New(nil)
	state.Documents[application.DocumentID(doc.Path)] = doc
	state.Order = []application.DocumentID{application.DocumentID(doc.Path)}
	state.Active = application.DocumentID(doc.Path)
	shell := &workbenchState{ShowFind: true, FindQuery: "needle"}
	scope := new(int)

	render := func(key KeyCode) bool {
		GetInputState().MousePoint = Vec2{-1000, -1000}
		GetInputState().Modifiers = 0
		GetFrameInput().Mouse = 0
		GetFrameInput().Scroll = Vec2{}
		GetFrameInput().Key = key
		GetFrameInput().Text = ""
		focused := false
		RunFrameFn(func() {
			ContainerWithKey(scope, Attrs(Viewport), func() {
				findBar(state, shell, DefaultTheme())
				focused = HasFocusWithin()
			})
		})
		return focused
	}

	if !render(KeyCodeNone) {
		t.Fatal("Find field did not receive keyboard focus")
	}
	doc.Editor.SetCursor(0)
	if !render(KeyEnter) {
		t.Fatal("Find Next moved focus away from the Find field")
	}
	if anchor, cursor := doc.Editor.Selection(); anchor != 6 || cursor != 12 {
		t.Fatalf("first Find selection = %d:%d, want 6:12", anchor, cursor)
	}
}

func TestEditableViewRevealsOffscreenLogicalLine(t *testing.T) {
	ResetInputSession()
	t.Cleanup(ResetInputSession)
	GetHost().HeadlessRender = true
	GetHost().WindowFocused = true
	GetHost().WindowSize = Vec2{500, 120}

	source := []byte(strings.Repeat("line\n", 100))
	e := editor.NewScratchEditor(source)
	target := bytes.Index(source, []byte("line"))
	for line := 0; line < 80; line++ {
		target = bytes.Index(source[target+1:], []byte("line")) + target + 1
	}
	if logical, ok := e.Buffer.LineAt(target); !ok || logical != 80 {
		t.Fatalf("target byte mapped to line %d,%v; want line 80,true", logical, ok)
	}

	scope := new(int)
	var scrollY float32
	request := &EditorRevealRequest{
		StartByte: target, EndByte: target + len("line"),
		Policy: RevealCenterIfOutside, Generation: e.Revision(),
	}
	frame := func(reveal *EditorRevealRequest) {
		GetInputState().MousePoint = Vec2{-1000, -1000}
		GetFrameInput().Mouse = 0
		GetFrameInput().Scroll = Vec2{}
		GetFrameInput().Key = KeyCodeNone
		GetFrameInput().Text = ""
		RunFrameFn(func() {
			ContainerWithKey(scope, Attrs(Viewport), func() {
				EditableView(scope, e, EditorViewOptions{
					Style: DefaultTextStyle(), RowHeight: 20,
					ScrollY: &scrollY, ScrollInitialized: true,
					VirtualListKey: editorListKey{Document: "notes.txt"}, Reveal: reveal,
				})
			})
		})
	}
	for i := 0; i < 3; i++ {
		frame(request)
	}
	frame(nil)
	if scrollY <= 0 {
		t.Fatalf("offscreen reveal left scroll at %v", scrollY)
	}
}

func TestEditableViewRevealsHorizontalOverflowWithoutEditorFocus(t *testing.T) {
	ResetInputSession()
	t.Cleanup(ResetInputSession)
	GetHost().HeadlessRender = true
	GetHost().WindowFocused = true
	GetHost().WindowSize = Vec2{180, 120}

	source := []byte(strings.Repeat("x", 300))
	e := editor.NewScratchEditor(source)
	e.SetCursor(len(source))
	scope := new(int)
	var scrollX float32
	request := &EditorRevealRequest{
		StartByte: len(source), EndByte: len(source), Policy: RevealCenterIfOutside,
		Horizontal: true, Generation: e.Revision(),
	}
	RunFrameFn(func() {
		ContainerWithKey(scope, Attrs(Viewport), func() {
			EditableView(scope, e, EditorViewOptions{
				Style: DefaultTextStyle(), RowHeight: 20, Wrap: false,
				ScrollX: &scrollX, ScrollXInitialized: true, Reveal: request,
			})
		})
	})
	if scrollX <= 0 {
		t.Fatalf("horizontal reveal left overflow scroll at %v", scrollX)
	}
}

func TestFindNavigationQueuesCenterReveal(t *testing.T) {
	doc := document.New("notes.txt", []byte("first needle\nsecond needle\nthird needle"), "text")
	state := application.New(nil)
	id := application.DocumentID(doc.Path)
	state.Documents[id] = doc
	state.Order = []application.DocumentID{id}
	state.Active = id
	shell := &workbenchState{FindQuery: "needle"}
	doc.Editor.SetCursor(0)
	findCurrent(state, shell, false)
	request, ok := shell.RevealRequests[id]
	if !ok {
		t.Fatal("Find Next did not queue an editor reveal request")
	}
	if request.Policy != RevealCenterIfOutside || request.StartByte != 6 || request.EndByte != 12 {
		t.Fatalf("Find reveal request = %+v", request)
	}
}

func TestGoToLineQueuesCenterReveal(t *testing.T) {
	doc := document.New("notes.txt", []byte("first\nsecond\nthird"), "text")
	state := application.New(nil)
	id := application.DocumentID(doc.Path)
	state.Documents[id] = doc
	state.Order = []application.DocumentID{id}
	state.Active = id
	shell := &workbenchState{}
	executeCommand(state, shell, commands.DocumentGoToLine, "3:2")
	request, ok := shell.RevealRequests[id]
	if !ok {
		t.Fatal("go-to-line did not queue an editor reveal request")
	}
	if request.Policy != RevealCenterIfOutside || request.StartByte != len("first\nsecond\n")+1 || request.EndByte != request.StartByte {
		t.Fatalf("go-to-line reveal request = %+v", request)
	}
}
