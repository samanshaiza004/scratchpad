package commands

import (
	"bytes"
	"strings"
	"testing"

	"github.com/rivo/uniseg"
	"scratchpad/document"
	"scratchpad/language/treesitter"
)

func TestSelectionExpandPlainTextLadderAndManualReset(t *testing.T) {
	source := []byte("alpha beta. Another sentence.\n\nSecond paragraph.")
	request := Request{ID: SelectionExpand, Source: source, Cursor: 8, Anchor: 8}
	for _, want := range []string{"beta", "alpha beta.", "alpha beta. Another sentence.", string(source)} {
		out := Execute(request)
		if out.Status != ResultExecuted || out.Changed() || string(source[out.Anchor:out.Cursor]) != want {
			t.Fatalf("expand %+v = %+v, selected %q, want %q", request, out, source[out.Anchor:out.Cursor], want)
		}
		request.Anchor, request.Cursor = out.Anchor, out.Cursor
	}
	if out := Execute(request); out.Status != ResultNoOp {
		t.Fatalf("document expansion = %+v", out)
	}
	request.Anchor, request.Cursor = 1, 1
	out := Execute(request)
	if string(source[out.Anchor:out.Cursor]) != "alpha" {
		t.Fatalf("manual caret reset = %+v", out)
	}
}

func TestSelectionExpandPreservesReverseDirectionAndSource(t *testing.T) {
	source := []byte("alpha beta.\r\n\r\nnext")
	before := bytes.Clone(source)
	out := Execute(Request{ID: SelectionExpand, Source: source, Anchor: 10, Cursor: 6})
	if out.Status != ResultExecuted || out.Anchor != 11 || out.Cursor != 0 || !bytes.Equal(source, before) {
		t.Fatalf("reverse expansion = %+v; source %q", out, source)
	}
}

func TestSelectionExpandRejectsStaleAndSplitClusterRanges(t *testing.T) {
	source := []byte("before changed")
	request := Request{ID: SelectionExpand, Source: source, SourceRevision: 3, Anchor: 7, Cursor: len(source), ProjectionsCurrent: true,
		Projections: document.Projections{Revision: 2, SelectionRanges: []document.SelectionRange{{StartByte: 6, EndByte: len(source)}}}}
	out := Execute(request)
	if out.Anchor != 0 || out.Cursor != len(source) {
		t.Fatalf("stale range used: %+v", out)
	}
	request.Projections.Revision = 3
	out = Execute(request)
	if out.Anchor != 6 || out.Cursor != len(source) {
		t.Fatalf("current range ignored: %+v", out)
	}

	source = []byte("e\u0301 👩‍👩‍👧‍👦 tail")
	boundaries := map[int]bool{0: true}
	g := uniseg.NewGraphemes(string(source))
	for g.Next() {
		_, end := g.Positions()
		boundaries[end] = true
	}
	for caret := range len(source) + 1 {
		request = Request{ID: SelectionExpand, Source: source, Anchor: caret, Cursor: caret, SourceRevision: 5, ProjectionsCurrent: true,
			Projections: document.Projections{Revision: 5, SelectionRanges: []document.SelectionRange{{StartByte: 1, EndByte: 2}}}}
		out = Execute(request)
		if out.Status == ResultExecuted && (!boundaries[out.Anchor] || !boundaries[out.Cursor]) {
			t.Fatalf("caret %d splits a cluster: %+v", caret, out)
		}
	}
}

func TestSelectionExpandRepairsPartialClusterAtDocumentEdge(t *testing.T) {
	source := []byte("a e\u0301")
	for _, selection := range [][2]int{{0, 3}, {3, 0}, {3, 3}} {
		out := Execute(Request{ID: SelectionExpand, Source: source, Anchor: selection[0], Cursor: selection[1]})
		if out.Status != ResultExecuted || out.Changed() {
			t.Fatalf("partial cluster %v = %+v", selection, out)
		}
		start, end := out.Anchor, out.Cursor
		if start > end {
			start, end = end, start
		}
		wantStart := 0
		if selection[0] == selection[1] {
			wantStart = 2
		}
		if start != wantStart || end != len(source) {
			t.Fatalf("partial cluster %v = %+v", selection, out)
		}
		if selection[0] > selection[1] && out.Anchor < out.Cursor {
			t.Fatal("reverse direction lost")
		}
	}
}

func TestSelectionExpandMarkdownLadderAndFreshRevision(t *testing.T) {
	source := []byte("# Project\n\nThis is a **very important** idea.\n\n## Next\n\nmore\n")
	doc := document.New("note.md", source, "markdown")
	caret := strings.Index(string(source), "important") + 3
	doc.Editor.SetSelection(caret, caret)
	var selected []string
	for i := 0; i < 12; i++ {
		request, err := NewRequest(doc, SelectionExpand)
		if err != nil {
			t.Fatal(err)
		}
		out := Execute(request)
		if out.Status == ResultNoOp {
			break
		}
		if out.Status != ResultExecuted || out.Changed() {
			t.Fatalf("expand = %+v", out)
		}
		selected = append(selected, string(source[out.Anchor:out.Cursor]))
		doc.Editor.SetSelection(out.Anchor, out.Cursor)
	}
	for _, want := range []string{"important", "**very important**", "This is a **very important** idea.", string(source)} {
		found := false
		for _, got := range selected {
			if got == want {
				found = true
			}
		}
		if !found {
			t.Fatalf("ladder %q missing %q", selected, want)
		}
	}
	if doc.Revision() != 0 || doc.Dirty() || !bytes.Equal(doc.Editor.Buffer.Text(), source) {
		t.Fatal("selection changed document authority")
	}
}

func TestSelectionExpandSentenceCannotBypassEnclosingMarkdown(t *testing.T) {
	source := []byte("Before **First. Second. Third. Fourth.** after.")
	doc := document.New("note.md", source, "markdown")
	caret := strings.Index(string(source), "First") + 1
	doc.Editor.SetSelection(caret, caret)
	for _, want := range []string{"First", "**First. Second. Third. Fourth.**", string(source)} {
		request, err := NewRequest(doc, SelectionExpand)
		if err != nil {
			t.Fatal(err)
		}
		out := Execute(request)
		if out.Status != ResultExecuted || string(source[out.Anchor:out.Cursor]) != want {
			t.Fatalf("expand = %+v, want %q", out, want)
		}
		doc.Editor.SetSelection(out.Anchor, out.Cursor)
	}
}

func TestSelectionExpandUsesCurrentCodeRangesAndPortableBinding(t *testing.T) {
	source := []byte("return add(one, two)")
	r := Request{ID: SelectionExpand, Source: source, SourceRevision: 7, Anchor: 11, Cursor: 14, RootLanguage: "go", ProjectionsCurrent: true,
		Projections: document.Projections{Revision: 7, Code: document.CodeProjection{Revision: 7, SelectionRanges: []document.SelectionRange{{StartByte: 7, EndByte: len(source)}}}}}
	out := Execute(r)
	if out.Anchor != 7 || out.Cursor != len(source) {
		t.Fatalf("code expression expansion = %+v", out)
	}
	r.Projections.Code.Revision = 6
	out = Execute(r)
	if out.Anchor != 0 || out.Cursor != len(source) {
		t.Fatalf("stale code expression = %+v", out)
	}
	registry := DefaultRegistry()
	if id, ok := registry.Match("primary+alt+e", CommandContext{ActiveDocument: true, EditorFocused: true}); !ok || id != SelectionExpand {
		t.Fatalf("binding = %q %v", id, ok)
	}
}

func TestSelectionExpandWalksParsedCodeParents(t *testing.T) {
	if !treesitter.Capabilities().Go {
		t.Skip("Go parser is disabled in this build")
	}
	source := []byte("package demo\n\nfunc sum(one, two int) int {\n\treturn add(one, two)\n}\n")
	doc := document.New("note.go", source, "go")
	adapter, err := treesitter.NewGoAdapter()
	if err != nil {
		t.Fatal(err)
	}
	defer adapter.Close()
	code, err := adapter.Analyze(source, doc.Revision(), nil)
	if err != nil {
		t.Fatal(err)
	}
	doc.SetDerived(nil, document.Projections{Revision: doc.Revision(), Code: code})
	caret := strings.LastIndex(string(source), "one") + 1
	doc.Editor.SetSelection(caret, caret)
	var selected []string
	for i := 0; i < 16; i++ {
		request, err := NewRequest(doc, SelectionExpand)
		if err != nil {
			t.Fatal(err)
		}
		out := Execute(request)
		if out.Status == ResultNoOp {
			break
		}
		if out.Status != ResultExecuted {
			t.Fatalf("code expansion = %+v", out)
		}
		selected = append(selected, string(source[out.Anchor:out.Cursor]))
		doc.Editor.SetSelection(out.Anchor, out.Cursor)
	}
	for _, want := range []string{"one", "add(one, two)", "return add(one, two)", string(source)} {
		found := false
		for _, got := range selected {
			if got == want {
				found = true
			}
		}
		if !found {
			t.Fatalf("code ladder %q missing %q", selected, want)
		}
	}
}
