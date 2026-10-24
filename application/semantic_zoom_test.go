package application

import (
	"bytes"
	"errors"
	"fmt"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"scratchpad/document"
	"scratchpad/language"
	"scratchpad/language/markdown"
	"scratchpad/language/treesitter"
)

func zoomTestDocument(t *testing.T, source, lang string) (*Application, DocumentID) {
	t.Helper()
	app := New(nil)
	id := DocumentID("zoom-source")
	doc := document.New("", []byte(source), lang)
	app.Documents[id], app.Active = doc, id
	if lang == string(language.Markdown) {
		doc.SetDerived(nil, markdown.Project([]byte(source), doc.Revision()))
	} else if AnalysisSupported(language.ID(lang)) {
		if lang != string(language.Go) {
			t.Fatalf("test helper needs an adapter for %s", lang)
		}
		adapter, err := treesitter.NewGoAdapter()
		if err != nil {
			t.Fatal(err)
		}
		defer adapter.Close()
		code, err := adapter.Analyze([]byte(source), doc.Revision(), nil)
		if err != nil {
			t.Fatal(err)
		}
		doc.SetDerived(nil, document.Projections{Revision: doc.Revision(), Code: code})
	}
	return app, id
}

func queryZoom(t *testing.T, app *Application, id DocumentID, depth, anchor int) SemanticZoomPlan {
	t.Helper()
	plan, err := app.QuerySemanticZoom(id, app.Documents[id].Revision(), depth, anchor)
	if err != nil {
		t.Fatal(err)
	}
	if !plan.Ready || !plan.Supported || plan.Reason != "" {
		t.Fatalf("unexpected unavailable plan: %+v", plan)
	}
	assertZoomMapping(t, plan, app.Documents[id].Editor.Buffer.Text())
	return plan
}

func assertZoomMapping(t *testing.T, plan SemanticZoomPlan, source []byte) {
	t.Helper()
	starts := []int{0}
	for i, c := range source {
		if c == '\n' {
			starts = append(starts, i+1)
		}
	}
	if plan.LineCount != len(starts) || len(plan.Folds) > MaxSemanticZoomFolds {
		t.Fatalf("invalid count metadata: %+v", plan)
	}
	boundary := func(line int) int {
		if line == len(starts) {
			return len(source)
		}
		return starts[line]
	}
	endLine, endByte := -1, -1
	for _, fold := range plan.Folds {
		if fold.StartLine < 0 || fold.EndLine <= fold.StartLine || fold.EndLine > len(starts) ||
			fold.StartLine <= endLine || fold.StartByte <= endByte || fold.EndByte <= fold.StartByte || fold.EndByte > len(source) ||
			fold.StartByte != boundary(fold.StartLine) || fold.EndByte != boundary(fold.EndLine) || fold.Label == "" {
			t.Fatalf("invalid/unmerged source fold: %+v after line=%d byte=%d", fold, endLine, endByte)
		}
		endLine, endByte = fold.EndLine, fold.EndByte
	}
}

func assertZoomTextVisible(t *testing.T, plan SemanticZoomPlan, source, needle string, want bool) {
	t.Helper()
	at := strings.Index(source, needle)
	if at < 0 {
		t.Fatalf("fixture has no %q", needle)
	}
	visible := true
	for _, fold := range plan.Folds {
		if fold.StartByte <= at && at < fold.EndByte {
			visible = false
		}
	}
	if visible != want {
		t.Fatalf("depth %d: %q visible=%v, want %v; folds=%+v", plan.Depth, needle, visible, want, plan.Folds)
	}
}

func TestSemanticZoomMarkdownDepthsAndAnchoredHierarchy(t *testing.T) {
	source := "# Alpha\n\nOpening sentence spans\nseveral source lines.\nSupporting detail should fold.\n\nA second paragraph.\n\n- [ ] Keep this task\n\n```go\nfunc hidden() {}\n```\n\n## Child\n\nChild opening.\nChild detail.\n\n# Beta\n\nBeta opening.\nBeta detail.\n"
	app, id := zoomTestDocument(t, source, string(language.Markdown))
	anchor := strings.Index(source, "Beta detail")
	for depth := SemanticZoomFull; depth <= SemanticZoomOverview; depth++ {
		plan := queryZoom(t, app, id, depth, anchor)
		for _, heading := range []string{"# Alpha", "## Child", "# Beta"} {
			assertZoomTextVisible(t, plan, source, heading, true)
		}
		assertZoomTextVisible(t, plan, source, "Opening sentence", depth == SemanticZoomFull || depth == SemanticZoomSkim)
		assertZoomTextVisible(t, plan, source, "several source lines.", depth == SemanticZoomFull || depth == SemanticZoomSkim)
		assertZoomTextVisible(t, plan, source, "Supporting detail", depth == SemanticZoomFull)
		assertZoomTextVisible(t, plan, source, "A second paragraph", depth == SemanticZoomFull)
		assertZoomTextVisible(t, plan, source, "Keep this task", depth == SemanticZoomFull || depth == SemanticZoomSkim)
		assertZoomTextVisible(t, plan, source, "```go", depth == SemanticZoomFull || depth == SemanticZoomSkim)
		assertZoomTextVisible(t, plan, source, "func hidden", depth == SemanticZoomFull)
		assertZoomTextVisible(t, plan, source, "Child opening", depth == SemanticZoomFull || depth == SemanticZoomSkim)
		assertZoomTextVisible(t, plan, source, "Beta detail", depth == SemanticZoomFull || depth == SemanticZoomFocus)
	}
	child := queryZoom(t, app, id, SemanticZoomFocus, strings.Index(source, "Child detail"))
	assertZoomTextVisible(t, child, source, "Child detail", true)
	assertZoomTextVisible(t, child, source, "Supporting detail", false)
	assertZoomTextVisible(t, child, source, "Beta detail", false)
	parent := queryZoom(t, app, id, SemanticZoomFocus, 0)
	assertZoomTextVisible(t, parent, source, "Child detail", true)
}

func TestSemanticZoomSetextCRLFAndUnterminatedLastLine(t *testing.T) {
	source := "Preamble.\r\nExtra preamble.\r\n\r\nTitle\r\n=====\r\n\r\nBody.\r\nDetail.\r\n\r\nOther\r\n-----\r\n\r\nLast body without newline"
	app, id := zoomTestDocument(t, source, string(language.Markdown))
	plan := queryZoom(t, app, id, SemanticZoomOverview, len(source))
	for _, needle := range []string{"Title", "=====", "Other", "-----"} {
		assertZoomTextVisible(t, plan, source, needle, true)
	}
	assertZoomTextVisible(t, plan, source, "Last body", false)
	if plan.Folds[len(plan.Folds)-1].EndByte != len(source) || plan.Folds[len(plan.Folds)-1].EndLine != plan.LineCount {
		t.Fatalf("unterminated EOF not folded: %+v", plan)
	}
	focus := queryZoom(t, app, id, SemanticZoomFocus, 0)
	assertZoomTextVisible(t, focus, source, "Extra preamble", true)
	assertZoomTextVisible(t, focus, source, "Detail.", false)
}

func TestSemanticZoomParserFreeProseAndHeadinglessMarkdown(t *testing.T) {
	source := "First sentence crosses\nthis line. More on the same line.\nHidden detail.\n\nSecond opening!\nSecond supporting line.\n\nFinal opening without punctuation\ncontinues to EOF"
	for _, lang := range []string{string(language.PlainText), "", string(language.Markdown)} {
		t.Run(lang, func(t *testing.T) {
			app, id := zoomTestDocument(t, source, lang)
			for _, depth := range []int{SemanticZoomSkim, SemanticZoomOverview} {
				plan := queryZoom(t, app, id, depth, 0)
				for _, needle := range []string{"First sentence", "this line.", "Second opening", "Final opening", "continues to EOF"} {
					assertZoomTextVisible(t, plan, source, needle, true)
				}
				assertZoomTextVisible(t, plan, source, "Hidden detail", false)
				assertZoomTextVisible(t, plan, source, "Second supporting", false)
			}
			focus := queryZoom(t, app, id, SemanticZoomFocus, strings.Index(source, "Second supporting"))
			assertZoomTextVisible(t, focus, source, "Hidden detail", false)
			assertZoomTextVisible(t, focus, source, "Second supporting", true)
		})
	}
}

func TestSemanticZoomCompleteLongSentencesAndUnicode(t *testing.T) {
	// The sentence exceeds both the old 256-byte excerpt cap and the bounded
	// scanner chunk, and crosses several source lines before its terminator.
	source := strings.Repeat("long clause ", 4000) + "\ncontinues here\nand ends here.”\nHide this detail.\n"
	for _, lang := range []string{string(language.PlainText), string(language.Markdown)} {
		app, id := zoomTestDocument(t, source, lang)
		plan := queryZoom(t, app, id, SemanticZoomSkim, 0)
		assertZoomTextVisible(t, plan, source, "continues here", true)
		assertZoomTextVisible(t, plan, source, "and ends here", true)
		assertZoomTextVisible(t, plan, source, "Hide this detail", false)
	}
	for _, source := range []string{"Hello world！\nHidden.\n", "A question?”\nHidden.\n", "A decimal 3.14 remains\npart of this sentence.\nHidden.\n"} {
		app, id := zoomTestDocument(t, source, string(language.PlainText))
		plan := queryZoom(t, app, id, SemanticZoomOverview, 0)
		assertZoomTextVisible(t, plan, source, "Hidden.", false)
	}
}

func TestSemanticZoomGoBodiesSignaturesDocCommentsAndDeclarations(t *testing.T) {
	if !AnalysisSupported(language.Go) {
		t.Skip("Go analysis adapter unavailable")
	}
	source := "package demo\n\nimport \"fmt\"\n\nconst Important = 42\n\n// Item documents a declaration.\ntype Item struct {\n\tName string\n}\n\n// Run documents this function.\nfunc Run(\n\titem Item,\n) string {\n\tfmt.Println(item.Name)\n\treturn item.Name\n}\n\n// Stop documents another function.\nfunc Stop() {\n\tcleanup()\n}\n"
	app, id := zoomTestDocument(t, source, string(language.Go))
	for depth := SemanticZoomFull; depth <= SemanticZoomOverview; depth++ {
		plan := queryZoom(t, app, id, depth, strings.Index(source, "fmt.Println"))
		assertZoomTextVisible(t, plan, source, "func Run(", true)
		assertZoomTextVisible(t, plan, source, "item Item,", true)
		assertZoomTextVisible(t, plan, source, ") string {", true)
		assertZoomTextVisible(t, plan, source, "func Stop()", true)
		assertZoomTextVisible(t, plan, source, "cleanup()", depth == SemanticZoomFull)
		assertZoomTextVisible(t, plan, source, "fmt.Println", depth == SemanticZoomFull || depth == SemanticZoomFocus)
		assertZoomTextVisible(t, plan, source, "Run documents", depth != SemanticZoomOverview)
		assertZoomTextVisible(t, plan, source, "const Important", depth != SemanticZoomOverview)
		assertZoomTextVisible(t, plan, source, "Name string", depth == SemanticZoomFull || depth == SemanticZoomSkim)
	}
	commentFocus := queryZoom(t, app, id, SemanticZoomFocus, strings.Index(source, "Run documents"))
	assertZoomTextVisible(t, commentFocus, source, "fmt.Println", true)
	stop := queryZoom(t, app, id, SemanticZoomFocus, strings.Index(source, "cleanup"))
	assertZoomTextVisible(t, stop, source, "cleanup()", true)
	assertZoomTextVisible(t, stop, source, "fmt.Println", false)
}

func TestSemanticZoomStaleParserRevisionValidationAndUnsupported(t *testing.T) {
	app, id := zoomTestDocument(t, "# Heading\n\nOpening.\nDetail.\n", string(language.Markdown))
	doc := app.Documents[id]
	if err := doc.Insert([]byte("prefix\n")); err != nil {
		t.Fatal(err)
	}
	plan, err := app.QuerySemanticZoom(id, doc.Revision(), SemanticZoomOverview, 0)
	if err != nil || plan.Ready || !plan.Supported || len(plan.Folds) != 0 || plan.Reason != "derived_not_current" {
		t.Fatalf("stale parser plan=%+v err=%v", plan, err)
	}
	queryZoom(t, app, id, SemanticZoomFull, 0)
	for _, tc := range []struct {
		revision      uint64
		depth, anchor int
		want          error
	}{
		{doc.Revision() - 1, 0, 0, ErrStaleEditorRevision},
		{doc.Revision(), -1, 0, ErrInvalidSemanticZoomDepth},
		{doc.Revision(), 4, 0, ErrInvalidSemanticZoomDepth},
		{doc.Revision(), 0, -1, ErrInvalidSemanticZoomAnchor},
		{doc.Revision(), 0, doc.Editor.Buffer.ByteLen() + 1, ErrInvalidSemanticZoomAnchor},
	} {
		if _, err := app.QuerySemanticZoom(id, tc.revision, tc.depth, tc.anchor); !errors.Is(err, tc.want) {
			t.Fatalf("query %+v: %v", tc, err)
		}
	}
	doc.RootLanguage = string(language.Rust)
	plan, err = app.QuerySemanticZoom(id, doc.Revision(), SemanticZoomSkim, 0)
	if err != nil || !plan.Ready || plan.Supported || plan.Reason != "unsupported_language" || len(plan.Folds) != 0 {
		t.Fatalf("unsupported plan=%+v err=%v", plan, err)
	}
	queryZoom(t, app, id, SemanticZoomFull, 0)
	var absent *Application
	if _, err := absent.QuerySemanticZoom(id, 0, 0, 0); err == nil {
		t.Fatal("nil application accepted")
	}
	if _, err := app.QuerySemanticZoom("missing", 0, 0, 0); err == nil {
		t.Fatal("unknown document accepted")
	}
}

func TestSemanticZoomDoesNotUseStaleCodePaintCache(t *testing.T) {
	if !AnalysisSupported(language.Go) {
		t.Skip("Go analysis unavailable")
	}
	app, id := zoomTestDocument(t, "package p\nfunc F() {\n work()\n}\n", string(language.Go))
	doc := app.Documents[id]
	code := doc.Projections.Code
	if err := doc.Insert([]byte("// changed\n")); err != nil {
		t.Fatal(err)
	}
	doc.DisplayCode = code
	plan, err := app.QuerySemanticZoom(id, doc.Revision(), SemanticZoomSkim, 0)
	if err != nil || plan.Ready || len(plan.Folds) != 0 {
		t.Fatalf("stale code used: %+v, %v", plan, err)
	}
	// A nominally current outer projection cannot legitimize old code ranges.
	doc.SetDerived(nil, document.Projections{Revision: doc.Revision(), Code: code})
	plan, err = app.QuerySemanticZoom(id, doc.Revision(), SemanticZoomSkim, 0)
	if err != nil || plan.Ready || len(plan.Folds) != 0 {
		t.Fatalf("old inner code used: %+v, %v", plan, err)
	}
}

func TestSemanticZoomDetachedPlansPreserveEditorAndUndoSave(t *testing.T) {
	app, id := zoomTestDocument(t, "Opening.\nDetail.\n\nOther opening.\nOther detail.\n", string(language.PlainText))
	doc := app.Documents[id]
	if err := doc.Insert([]byte("Edited.\n")); err != nil {
		t.Fatal(err)
	}
	doc.MarkSaved()
	doc.Editor.SetSelection(2, 9)
	before := doc.Editor.Buffer.Text()
	revision, saved, instance := doc.Revision(), doc.SavedRevision, doc.InstanceID()
	undo, redo, dirty, snapshot := doc.CanUndo(), doc.CanRedo(), doc.Dirty(), app.Snapshot()
	original := queryZoom(t, app, id, SemanticZoomSkim, 0)
	captured := append([]SemanticZoomFold(nil), original.Folds...)
	mutated := queryZoom(t, app, id, SemanticZoomSkim, 0)
	mutated.Folds[0].StartByte = 999
	for depth := 0; depth <= 3; depth++ {
		queryZoom(t, app, id, depth, len(before))
	}
	if !reflect.DeepEqual(original.Folds, captured) || !reflect.DeepEqual(app.Snapshot(), snapshot) || !bytes.Equal(doc.Editor.Buffer.Text(), before) ||
		doc.Revision() != revision || doc.InstanceID() != instance || doc.SavedRevision != saved || doc.CanUndo() != undo || doc.CanRedo() != redo || doc.Dirty() != dirty {
		t.Fatal("zoom mutated source, saved/editor state or existing plans")
	}
	if anchor, cursor := doc.Editor.Selection(); anchor != 2 || cursor != 9 {
		t.Fatal("zoom moved selection")
	}
	if err := doc.Undo(); err != nil {
		t.Fatal(err)
	}
	if doc.Revision() == revision || !reflect.DeepEqual(original.Folds, captured) {
		t.Fatal("undo mutated detached plan")
	}
}

func TestSemanticZoomCloseReopenInstanceIdentity(t *testing.T) {
	path := filepath.Join(t.TempDir(), "source.txt")
	if err := writeTestFile(path, []byte("Opening.\nDetail.\n")); err != nil {
		t.Fatal(err)
	}
	app := New(nil)
	if err := app.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	id := app.Active
	old := queryZoom(t, app, id, SemanticZoomSkim, 0)
	if err := app.CloseDocument(id, true); err != nil {
		t.Fatal(err)
	}
	if _, err := app.QuerySemanticZoom(id, old.Revision, old.Depth, old.AnchorByte); err == nil {
		t.Fatal("closed source accepted")
	}
	if err := app.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	current := queryZoom(t, app, id, SemanticZoomSkim, 0)
	if current.Revision != old.Revision || current.InstanceID == old.InstanceID || current.InstanceID == 0 {
		t.Fatalf("reopened identities: %+v -> %+v", old, current)
	}
}

func TestSemanticZoomLargeWorkloadsAndExplicitFoldLimit(t *testing.T) {
	for _, count := range []int{MaxSemanticZoomFolds, MaxSemanticZoomFolds + 1, 20000} {
		source := strings.Repeat("Opening.\nSupporting line.\n\n", count)
		app, id := zoomTestDocument(t, source, string(language.PlainText))
		plan, err := app.QuerySemanticZoom(id, 0, SemanticZoomOverview, 0)
		if err != nil {
			t.Fatal(err)
		}
		if count <= MaxSemanticZoomFolds {
			if !plan.Supported || len(plan.Folds) != count {
				t.Fatalf("limit boundary: supported=%v folds=%d", plan.Supported, len(plan.Folds))
			}
			assertZoomMapping(t, plan, []byte(source))
		} else if plan.Supported || !plan.Ready || plan.Reason != "fold_limit_exceeded" || len(plan.Folds) != 0 {
			t.Fatalf("silent truncation for %d: %+v", count, plan)
		}
	}
	// Many lines in one original piece exercises the linear line index instead
	// of repeated LineAt/LineRange scans from the start of a large piece.
	source := strings.Repeat("continuing without a terminator\n", 100000) + "finally ends.\nHidden.\n"
	app, id := zoomTestDocument(t, source, string(language.PlainText))
	plan := queryZoom(t, app, id, SemanticZoomSkim, 0)
	if len(plan.Folds) != 1 || plan.Folds[0].StartLine != 100001 {
		t.Fatalf("large sentence mapping: %+v", plan.Folds)
	}
}

func TestSemanticZoomEmptyWhitespaceAndFragmentedSource(t *testing.T) {
	for _, source := range []string{"", "\n", " \r\n\t\n", "single line", "no punctuation\ncontinued"} {
		app, id := zoomTestDocument(t, source, string(language.PlainText))
		for depth := 0; depth <= 3; depth++ {
			queryZoom(t, app, id, depth, len(source))
		}
	}
	app, id := zoomTestDocument(t, "", string(language.PlainText))
	doc := app.Documents[id]
	for i := 0; i < 2000; i++ {
		if err := doc.Editor.Buffer.Insert(doc.Editor.Buffer.ByteLen(), []byte(fmt.Sprintf("P%d.\nDetail.\n\n", i))); err != nil {
			t.Fatal(err)
		}
	}
	plan := queryZoom(t, app, id, SemanticZoomSkim, 0)
	if len(plan.Folds) != 2000 {
		t.Fatalf("fragmented fold count=%d", len(plan.Folds))
	}
}

func TestSemanticZoomWhitespaceFoldsDoNotClaimUsefulContext(t *testing.T) {
	source := "First paragraph.\n\nSecond paragraph.\nSupporting detail.\n"
	app, id := zoomTestDocument(t, source, string(language.PlainText))
	plan := queryZoom(t, app, id, SemanticZoomFocus, 0)
	if len(plan.Folds) != 2 {
		t.Fatalf("focus folds=%+v, want one blank separator and one hidden detail line", plan.Folds)
	}
	if fold := plan.Folds[0]; fold.StartLine != 1 || fold.EndLine != 2 || !fold.Silent {
		t.Fatalf("blank separator fold=%+v, want a silent one-line fold", fold)
	}
	if fold := plan.Folds[1]; fold.StartLine != 3 || fold.EndLine != 4 || fold.Silent {
		t.Fatalf("meaningful detail fold=%+v, want an expandable marker", fold)
	}
}

func TestSemanticZoomLargeCurrentStructureAndNestedSymbols(t *testing.T) {
	for _, lang := range []string{string(language.Markdown), string(language.Go)} {
		if lang == string(language.Go) && !AnalysisSupported(language.Go) {
			continue
		}
		var source strings.Builder
		projection := document.Projections{}
		for i := 0; i <= MaxSemanticZoomFolds; i++ {
			start := source.Len()
			if lang == string(language.Markdown) {
				source.WriteString(fmt.Sprintf("# Section %d\nBody.\nDetail.\n", i))
				projection.Headings = append(projection.Headings, document.Heading{Level: 1, StartByte: start, EndByte: start + len(fmt.Sprintf("# Section %d", i))})
			} else {
				source.WriteString(fmt.Sprintf("func F%d() {\n work()\n}\n", i))
				projection.Code.Symbols = append(projection.Code.Symbols, document.Symbol{Kind: "function", StartByte: start, EndByte: source.Len() - 1})
				projection.Code.Folds = append(projection.Code.Folds, document.LanguageFold{StartByte: start + len(fmt.Sprintf("func F%d() ", i)), EndByte: source.Len() - 1})
			}
		}
		app := New(nil)
		id := DocumentID("large-structure")
		doc := document.New("", []byte(source.String()), lang)
		app.Documents[id] = doc
		projection.Code.Language = lang
		doc.SetDerived(nil, projection)
		plan, err := app.QuerySemanticZoom(id, 0, SemanticZoomOverview, 0)
		if err != nil || plan.Supported || plan.Reason != "fold_limit_exceeded" || len(plan.Folds) != 0 {
			t.Fatalf("%s large structure: %+v %v", lang, plan, err)
		}
	}
	if !AnalysisSupported(language.Go) {
		return
	}
	// Nested ranges model supported languages with symbols inside a container.
	// An expanded child must survive its parent's body fold, without overlap.
	source := "container {\n child {\n  anchored body\n }\n other {\n  hidden body\n }\n}"
	app := New(nil)
	id := DocumentID("nested")
	doc := document.New("", []byte(source), string(language.Go))
	app.Documents[id] = doc
	childStart, childEnd := strings.Index(source, "child"), strings.Index(source, " other")
	otherStart := strings.Index(source, "other")
	projection := document.CodeProjection{Language: string(language.Go), Symbols: []document.Symbol{
		{StartByte: 0, EndByte: len(source), Kind: "type"},
		{StartByte: childStart, EndByte: childEnd - 1, Kind: "method"},
		{StartByte: otherStart, EndByte: len(source) - 2, Kind: "method"},
	}, Folds: []document.LanguageFold{
		{StartByte: strings.Index(source, "{"), EndByte: len(source)},
		{StartByte: strings.Index(source[childStart:], "{") + childStart, EndByte: childEnd - 1},
		{StartByte: strings.Index(source[otherStart:], "{") + otherStart, EndByte: len(source) - 2},
	}}
	doc.SetDerived(nil, document.Projections{Code: projection})
	plan := queryZoom(t, app, id, SemanticZoomFocus, strings.Index(source, "anchored body"))
	assertZoomTextVisible(t, plan, source, "anchored body", true)
	assertZoomTextVisible(t, plan, source, "hidden body", false)
	assertZoomTextVisible(t, plan, source, "other {", true)
}

// These benchmarks measure explicit transitions, not frontend cache hits or
// parser work. Fixtures and current projections are built before ResetTimer.
// Structural fixtures repeat offset copies of one real parser-produced template
// projection, avoiding a full-document parse in benchmark setup. The large
// original source is one buffer piece, which makes repeated LineAt/LineRange
// scans especially expensive if they accidentally reappear in the query path.
var semanticZoomBenchmarkPlan SemanticZoomPlan

type semanticZoomBenchmarkFixture struct {
	app        *Application
	id         DocumentID
	anchor     int
	structures int
}

func benchmarkSemanticZoomTransition(b *testing.B, fixture semanticZoomBenchmarkFixture, depth, wantFolds int, wantSupported bool) {
	b.Helper()
	doc := fixture.app.Documents[fixture.id]
	revision := doc.Revision()
	check := func(plan SemanticZoomPlan, err error) {
		if err != nil || !plan.Ready || plan.Supported != wantSupported || len(plan.Folds) != wantFolds || plan.LineCount != doc.Editor.Buffer.LineCount() {
			b.Fatalf("unexpected transition result: ready=%v supported=%v reason=%q folds=%d lines=%d err=%v", plan.Ready, plan.Supported, plan.Reason, len(plan.Folds), plan.LineCount, err)
		}
		if !wantSupported && plan.Reason != "fold_limit_exceeded" || wantSupported && plan.Reason != "" {
			b.Fatalf("unexpected transition reason: %q", plan.Reason)
		}
	}
	// Validate workload/plan counts outside the timed region. Inside it, the
	// sink retains the last result so the whole plan remains observable.
	plan, err := fixture.app.QuerySemanticZoom(fixture.id, revision, depth, fixture.anchor)
	check(plan, err)
	b.SetBytes(int64(doc.Editor.Buffer.ByteLen()))
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		plan, err = fixture.app.QuerySemanticZoom(fixture.id, revision, depth, fixture.anchor)
		if err != nil {
			b.Fatal(err)
		}
		semanticZoomBenchmarkPlan = plan
	}
	b.StopTimer()
	check(plan, err)
	hiddenLines := 0
	for _, fold := range plan.Folds {
		hiddenLines += fold.EndLine - fold.StartLine
	}
	b.ReportMetric(float64(len(plan.Folds)), "folds/plan")
	b.ReportMetric(float64(hiddenLines), "hidden-lines/plan")
	b.ReportMetric(float64(plan.LineCount), "lines/plan")
	b.ReportMetric(float64(fixture.structures), "structures/plan")
	supported := 0
	if plan.Supported {
		supported = 1
	}
	b.ReportMetric(float64(supported), "supported/plan")
}

func newSemanticZoomBenchmarkFixture(source []byte, lang language.ID, projection document.Projections, anchor, structures int) semanticZoomBenchmarkFixture {
	app := New(nil)
	id := DocumentID("zoom-benchmark")
	doc := document.New("", source, string(lang))
	app.Documents[id] = doc
	if lang != language.PlainText {
		doc.SetDerived(nil, projection)
	}
	return semanticZoomBenchmarkFixture{app: app, id: id, anchor: anchor, structures: structures}
}

func BenchmarkSemanticZoomProseTransition(b *testing.B) {
	for _, sourceLines := range []int{100_000, 1_000_000} {
		b.Run(fmt.Sprintf("Paragraphs/lines=%d", sourceLines), func(b *testing.B) {
			// One thousand source lines per paragraph keeps both sizes within
			// the fold budget while exercising paragraph and sentence queries.
			const paragraphLines = 1000
			paragraph := "Opening sentence.\n" + strings.Repeat("Supporting detail.\n", paragraphLines-2) + "\n"
			count := sourceLines / paragraphLines
			source := []byte(strings.Repeat(paragraph, count))
			fixture := newSemanticZoomBenchmarkFixture(source, language.PlainText, document.Projections{}, len(source)/2+len("Opening sentence.\n"), count)
			for _, mode := range []struct {
				name  string
				depth int
			}{{"Focus", SemanticZoomFocus}, {"Skim", SemanticZoomSkim}, {"Overview", SemanticZoomOverview}} {
				b.Run(mode.name, func(b *testing.B) {
					// Focus still folds the blank separator following the expanded
					// paragraph, so all three depths return one fold per paragraph.
					benchmarkSemanticZoomTransition(b, fixture, mode.depth, count, true)
				})
			}
		})
		b.Run(fmt.Sprintf("LongSentence/lines=%d/Skim", sourceLines), func(b *testing.B) {
			// The first sentence spans almost the entire source. This measures
			// the extra bounded sentence scan instead of a short opening only.
			source := []byte(strings.Repeat("This clause continues across source lines\n", sourceLines-2) + "until this first sentence finishes.\nHidden detail.\n")
			fixture := newSemanticZoomBenchmarkFixture(source, language.PlainText, document.Projections{}, len(source)/2, 1)
			benchmarkSemanticZoomTransition(b, fixture, SemanticZoomSkim, 1, true)
		})
	}
}

func semanticZoomBenchmarkMarkdown(sourceLines, sectionLines int) semanticZoomBenchmarkFixture {
	lines := make([]string, sectionLines)
	lines[0], lines[2], lines[3] = "# Section", "Opening sentence spans", "two lines."
	for line := 4; line < sectionLines-10; line++ {
		lines[line] = "Supporting detail."
	}
	lines[sectionLines-9] = "- [ ] Keep this task"
	lines[sectionLines-7], lines[sectionLines-6], lines[sectionLines-5] = "```go", "x++", "```"
	lines[sectionLines-3], lines[sectionLines-2] = "Another paragraph.", "More detail."
	template := strings.Join(lines, "\n") + "\n"
	parsed := markdown.Project([]byte(template), 0)
	count := sourceLines / sectionLines
	projection := document.Projections{
		Headings:   make([]document.Heading, 0, len(parsed.Headings)*count),
		Paragraphs: make([]document.ParagraphRange, 0, len(parsed.Paragraphs)*count),
		Tasks:      make([]document.Task, 0, len(parsed.Tasks)*count),
		Blocks:     make([]document.BlockPresentation, 0, len(parsed.Blocks)*count),
	}
	for section := 0; section < count; section++ {
		offset := section * len(template)
		for _, heading := range parsed.Headings {
			heading.StartByte, heading.EndByte = heading.StartByte+offset, heading.EndByte+offset
			projection.Headings = append(projection.Headings, heading)
		}
		for _, paragraph := range parsed.Paragraphs {
			paragraph.StartByte, paragraph.EndByte = paragraph.StartByte+offset, paragraph.EndByte+offset
			projection.Paragraphs = append(projection.Paragraphs, paragraph)
		}
		for _, task := range parsed.Tasks {
			task.StartByte, task.EndByte = task.StartByte+offset, task.EndByte+offset
			task.MarkerStart, task.MarkerEnd = task.MarkerStart+offset, task.MarkerEnd+offset
			projection.Tasks = append(projection.Tasks, task)
		}
		for _, block := range parsed.Blocks {
			block.StartByte, block.EndByte = block.StartByte+offset, block.EndByte+offset
			projection.Blocks = append(projection.Blocks, block)
		}
	}
	source := []byte(strings.Repeat(template, count))
	return newSemanticZoomBenchmarkFixture(source, language.Markdown, projection, count/2*len(template)+len(template)/2, count)
}

func semanticZoomBenchmarkGo(b *testing.B, sourceLines, symbolLines int) semanticZoomBenchmarkFixture {
	b.Helper()
	if !AnalysisSupported(language.Go) {
		b.Skip("Go analysis adapter unavailable")
	}
	const prefix = "package bench\n\n"
	lines := make([]string, symbolLines)
	lines[0], lines[1], lines[2], lines[3] = "// Work documents a multiline signature.", "func Work(", "\tx int,", ") int {"
	for line := 4; line < symbolLines-2; line++ {
		lines[line] = "\tx++"
	}
	lines[symbolLines-2], lines[symbolLines-1] = "\treturn x", "}"
	template := strings.Join(lines, "\n") + "\n"
	adapter, err := treesitter.NewGoAdapter()
	if err != nil {
		b.Fatal(err)
	}
	parsed, err := adapter.Analyze([]byte(prefix+template), 0, nil)
	adapter.Close()
	if err != nil {
		b.Fatal(err)
	}
	count := sourceLines / symbolLines
	code := document.CodeProjection{
		Language:   string(language.Go),
		Symbols:    make([]document.Symbol, 0, len(parsed.Symbols)*count),
		Folds:      make([]document.LanguageFold, 0, len(parsed.Folds)*count),
		Highlights: make([]document.HighlightSpan, 0, len(parsed.Highlights)*count),
	}
	for symbol := 0; symbol < count; symbol++ {
		offset := symbol * len(template)
		for _, span := range parsed.Highlights {
			if span.StartByte < len(prefix) {
				continue
			}
			span.StartByte, span.EndByte = span.StartByte+offset, span.EndByte+offset
			code.Highlights = append(code.Highlights, span)
		}
		for _, entry := range parsed.Symbols {
			entry.StartByte, entry.EndByte = entry.StartByte+offset, entry.EndByte+offset
			code.Symbols = append(code.Symbols, entry)
		}
		for _, fold := range parsed.Folds {
			fold.StartByte, fold.EndByte = fold.StartByte+offset, fold.EndByte+offset
			code.Folds = append(code.Folds, fold)
		}
	}
	source := []byte(prefix + strings.Repeat(template, count))
	return newSemanticZoomBenchmarkFixture(source, language.Go, document.Projections{Code: code}, len(prefix)+count/2*len(template)+len(template)/2, count)
}

func BenchmarkSemanticZoomStructuralTransition(b *testing.B) {
	for _, lang := range []language.ID{language.Markdown, language.Go} {
		for _, sourceLines := range []int{100_000, 1_000_000} {
			b.Run(fmt.Sprintf("%s/lines=%d", lang, sourceLines), func(b *testing.B) {
				var fixture semanticZoomBenchmarkFixture
				if lang == language.Markdown {
					fixture = semanticZoomBenchmarkMarkdown(sourceLines, 1000)
				} else {
					fixture = semanticZoomBenchmarkGo(b, sourceLines, 1000)
				}
				for _, mode := range []struct {
					name  string
					depth int
				}{{"Focus", SemanticZoomFocus}, {"Skim", SemanticZoomSkim}, {"Overview", SemanticZoomOverview}} {
					b.Run(mode.name, func(b *testing.B) {
						folds := fixture.structures
						if mode.depth == SemanticZoomFocus {
							folds--
						}
						if lang == language.Markdown && mode.depth == SemanticZoomSkim {
							folds *= 4
						}
						if lang == language.Go && mode.depth == SemanticZoomOverview {
							folds++
						}
						benchmarkSemanticZoomTransition(b, fixture, mode.depth, folds, true)
					})
				}
			})
			b.Run(fmt.Sprintf("%s/DenseOverBudget/lines=%d/Overview", lang, sourceLines), func(b *testing.B) {
				var fixture semanticZoomBenchmarkFixture
				if lang == language.Markdown {
					fixture = semanticZoomBenchmarkMarkdown(sourceLines, 20)
				} else {
					fixture = semanticZoomBenchmarkGo(b, sourceLines, 20)
				}
				// With 5k/50k structures this must explicitly reject the plan,
				// rather than return the first 4096 folds as if complete.
				benchmarkSemanticZoomTransition(b, fixture, SemanticZoomOverview, 0, false)
			})
		}
	}
}
