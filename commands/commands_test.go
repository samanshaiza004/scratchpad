package commands

import (
	"testing"

	"scratchpad/document"
	"scratchpad/language/markdown"
)

func TestInitialVocabularyIsStableAndUnified(t *testing.T) {
	if len(InitialVocabulary) != 58 {
		t.Fatalf("got %d commands, want 58", len(InitialVocabulary))
	}
	seen := map[ID]bool{}
	for _, id := range InitialVocabulary {
		if seen[id] {
			t.Fatalf("duplicate command %q", id)
		}
		seen[id] = true
	}
}

func TestDefaultRegistryUsesExplicitContexts(t *testing.T) {
	registry := DefaultRegistry()
	markdown := CommandContext{ActiveDocument: true, Markdown: true, EditorFocused: true}
	if id, ok := registry.Match("primary+b", markdown); !ok || id != MarkdownToggleStrong {
		t.Fatalf("primary+b = %q, %v; want %q", id, ok, MarkdownToggleStrong)
	}
	code := CommandContext{ActiveDocument: true, Code: true, RootLanguage: "go", EditorFocused: true}
	if _, ok := registry.Match("primary+b", code); ok {
		t.Fatal("Markdown strong binding enabled in code context")
	}
	if id, ok := registry.Match("primary+/", code); !ok || id != CommentToggle {
		t.Fatalf("primary+/ = %q, %v; want comment.toggle", id, ok)
	}
	unsupported := CommandContext{ActiveDocument: true, Code: true, RootLanguage: "rust", EditorFocused: true}
	if _, ok := registry.Match("primary+/", unsupported); ok {
		t.Fatal("comment toggle enabled for unsupported language")
	}
	if descriptor, ok := registry.Lookup(DocumentFormat); !ok || descriptor.IsEnabled(markdown) {
		t.Fatal("format table enabled without table context")
	}
	markdown.InTable = true
	if descriptor, ok := registry.Lookup(DocumentFormat); !ok || !descriptor.IsEnabled(markdown) {
		t.Fatal("format table disabled inside table context")
	}
}

func TestMarkdownTransformsAreOneReplacement(t *testing.T) {
	req := Request{ID: MarkdownToggleStrong, Source: []byte("hello world"), Cursor: 11, Anchor: 6, RootLanguage: "markdown", ProjectionsCurrent: true}
	out := Execute(req)
	if out.Status != ResultExecuted || string(out.Replacement) != "**world**" {
		t.Fatalf("strong outcome = %#v", out)
	}
	if out.Start != 6 || out.End != 11 || out.Cursor != 15 || out.Anchor != 8 {
		t.Fatalf("strong range/caret = %#v", out)
	}

	req.ID = MarkdownHeading2
	req.Source = []byte("title\nbody")
	req.Cursor, req.Anchor = 2, 2
	out = Execute(req)
	if out.Status != ResultExecuted || string(out.Replacement) != "## title" || out.Start != 0 || out.End != 5 {
		t.Fatalf("heading outcome = %#v", out)
	}
	req.Source = []byte("## title")
	req.Cursor, req.Anchor = 4, 4
	req.ID = MarkdownHeading1
	out = Execute(req)
	if out.Status != ResultExecuted || string(out.Replacement) != "# title" {
		t.Fatalf("heading level conversion = %#v", out)
	}
}

func TestSmartPasteTurnsURLIntoLinkForSelection(t *testing.T) {
	req := Request{ID: MarkdownSmartPaste, RootLanguage: "markdown", Source: []byte("Scratchpad"), Cursor: 10, Anchor: 0, Argument: "https://example.test"}
	out := Execute(req)
	if out.Status != ResultExecuted || string(out.Replacement) != "[Scratchpad](https://example.test)" {
		t.Fatalf("smart paste outcome = %#v", out)
	}
}

func TestSlashInvocationReplacesOnlyTheQuery(t *testing.T) {
	req := Request{ID: MarkdownToggleStrong, RootLanguage: "markdown", Source: []byte("  /bold"), Cursor: 7, Anchor: 7, RangeStart: 2, RangeEnd: 7, RangeOverride: true, SlashTrigger: true}
	out := Execute(req)
	if out.Status != ResultExecuted || out.Start != 2 || string(out.Replacement) != "****" || out.Cursor != 4 {
		t.Fatalf("slash outcome = %#v", out)
	}
}

func TestFenceLanguageCommandRewritesOpeningInfoString(t *testing.T) {
	source := []byte("```\nbody\n```")
	req := Request{ID: MarkdownSetFenceLanguage, RootLanguage: "markdown", Source: source, Cursor: len("```\nbo"), Anchor: len("```\nbo"), Argument: "go"}
	out := Execute(req)
	if out.Status != ResultExecuted || string(out.Replacement) != "```go" || out.Start != 0 || out.End != 3 {
		t.Fatalf("fence language outcome = %#v", out)
	}
}

func TestExplicitCommandRefreshesStaleMarkdownProjection(t *testing.T) {
	source := []byte("| a | b |\n| --- | --- |\n| one | two |\n")
	doc := document.New("notes.md", source, "markdown")
	if !doc.SetDerived(nil, markdown.Project(source, doc.Revision())) {
		t.Fatal("projection rejected")
	}
	doc.Editor.SetCursor(len(source) - 5)
	if err := doc.Insert([]byte("!")); err != nil {
		t.Fatal(err)
	}
	if doc.DerivedCurrent() {
		t.Fatal("projection unexpectedly current")
	}
	request, err := NewRequest(doc, DocumentFormat)
	if err != nil {
		t.Fatal(err)
	}
	if !request.ProjectionsCurrent || len(request.Projections.Tables) != 1 {
		t.Fatalf("stale request projection = %#v", request)
	}
}

func TestCommentToggleAllCommentedLinesUncomments(t *testing.T) {
	req := Request{ID: CommentToggle, RootLanguage: "go", Source: []byte("  // one\n  // two"), Cursor: 14, Anchor: 0}
	out := Execute(req)
	if out.Status != ResultExecuted || string(out.Replacement) != "  one\n  two" {
		t.Fatalf("comment outcome = %#v", out)
	}
}

func TestItemToggleUsesParserTaskProjection(t *testing.T) {
	source := []byte("plain [ ] text\n- [ ] task\n")
	doc := document.New("notes.md", source, "markdown")
	projection := markdown.Project(source, doc.Revision())
	request, err := NewRequest(doc, ItemToggle)
	if err != nil {
		t.Fatal(err)
	}
	request.Projections = projection
	request.ProjectionsCurrent = true
	request.Cursor = len("plain [ ] text\n- [")
	out := Execute(request)
	if out.Status != ResultExecuted || string(out.Replacement) != "[x]" {
		t.Fatalf("task outcome = %#v", out)
	}
	request.Cursor = len("plain [ ]")
	request.Anchor = request.Cursor
	out = Execute(request)
	if out.Status == ResultExecuted {
		t.Fatalf("plain text task-looking marker toggled: %#v", out)
	}
}

func TestTableNavigationReturnsOneReplacementAndCaret(t *testing.T) {
	source := []byte("| a | b |\n| --- | --- |\n| one | two |\n")
	doc := document.New("notes.md", source, "markdown")
	if !doc.SetDerived(nil, markdown.Project(source, doc.Revision())) {
		t.Fatal("projection rejected")
	}
	doc.Editor.SetCursor(len("| a | b |\n| --- | --- |\n| one"))
	request, err := NewRequest(doc, MarkdownTableNext)
	if err != nil {
		t.Fatal(err)
	}
	out := Execute(request)
	if out.Status != ResultExecuted || out.Start != 0 || out.End != len(source) || out.Cursor <= doc.Editor.Cursor {
		t.Fatalf("table navigation outcome = %#v", out)
	}
	if string(out.Replacement) == string(source) {
		t.Fatal("navigation should format this unaligned table in the same edit")
	}
}

func BenchmarkCommandDispatch(b *testing.B) {
	doc := document.New("notes.md", []byte("A paragraph with a selection."), "markdown")
	doc.Editor.SetSelection(2, 11)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		request, _ := NewRequest(doc, MarkdownToggleStrong)
		_ = Execute(request)
	}
}

func BenchmarkStaleMarkdownCommandRefresh(b *testing.B) {
	doc := document.New("notes.md", []byte("| a | b |\n| --- | --- |\n| one | two |\n"), "markdown")
	doc.Editor.SetCursor(3)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		request, _ := NewRequest(doc, DocumentFormat)
		_ = Execute(request)
	}
}
