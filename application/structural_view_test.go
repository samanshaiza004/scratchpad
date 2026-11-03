package application

import (
	"bytes"
	"path/filepath"
	"testing"
	"time"

	"scratchpad/workspace"
)

func TestStructuralViewsReuseSourceMappedProjections(t *testing.T) {
	path := filepath.Join(t.TempDir(), "structure.md")
	source := []byte("# Intro\n\n- [ ] Ship one\n- [x] Ship two\n\nRead [the guide](docs/guide.md).\n## Follow up\n")
	if err := writeTestFile(path, source); err != nil {
		t.Fatal(err)
	}
	app := New(workspace.NewOSFileStore())
	t.Cleanup(app.CloseDerived)
	if err := app.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	doc := app.ActiveDocument()
	waitForDerived(t, app, doc, time.Second)
	before := doc.Snapshot()

	tasks, err := app.QueryStructuralView(app.Active, StructuralProjectionTasks, 0, 1)
	if err != nil {
		t.Fatal(err)
	}
	if !tasks.Ready || !tasks.Supported || tasks.Total != 2 || len(tasks.Segments) != 1 {
		t.Fatalf("task window = %+v", tasks)
	}
	if tasks.Segments[0].Text != "- [ ] Ship one" || tasks.Segments[0].Context != "open" ||
		tasks.Segments[0].Status != ProjectionCurrent || tasks.Segments[0].StartByte != bytes.Index(source, []byte("- [ ] Ship one")) {
		t.Fatalf("first task segment lost source identity or task context: %+v", tasks.Segments[0])
	}
	taskPage, err := app.QueryStructuralView(app.Active, StructuralProjectionTasks, 1, 1)
	if err != nil || len(taskPage.Segments) != 1 || taskPage.Segments[0].Context != "complete" {
		t.Fatalf("second task page = %+v, err=%v", taskPage, err)
	}

	symbols, err := app.QueryStructuralView(app.Active, StructuralProjectionSymbols, 0, 8)
	if err != nil {
		t.Fatal(err)
	}
	if !symbols.Ready || !symbols.Supported || symbols.Total != 2 || len(symbols.Segments) != 2 {
		t.Fatalf("symbol view = %+v", symbols)
	}
	if symbols.Segments[0].Context != "Intro" || symbols.Segments[0].Depth != 0 ||
		symbols.Segments[1].Context != "Follow up" || symbols.Segments[1].Depth != 1 {
		t.Fatalf("symbols should retain heading names and nesting depth: %+v", symbols.Segments)
	}

	links, err := app.QueryStructuralView(app.Active, StructuralProjectionLinks, 0, 8)
	if err != nil {
		t.Fatal(err)
	}
	if !links.Ready || !links.Supported || links.Total != 1 || len(links.Segments) != 1 {
		t.Fatalf("link view = %+v", links)
	}
	if links.Segments[0].Text != "[the guide](docs/guide.md)" ||
		links.Segments[0].Context != "docs/guide.md" ||
		links.Segments[0].StartByte != bytes.Index(source, []byte("[the guide](docs/guide.md)")) {
		t.Fatalf("link segment should expose provider target metadata and exact source range: %+v", links.Segments[0])
	}
	if doc.Revision() != before.Revision || !bytes.Equal(doc.Editor.Buffer.Text(), source) {
		t.Fatal("building structural views changed authoritative source")
	}
}

func TestStructuralSymbolsExposeCodeProviderRanges(t *testing.T) {
	path := filepath.Join(t.TempDir(), "symbols.go")
	source := []byte("package sample\n\ntype Record struct{}\n\nfunc OpenRecord() {}\n")
	if err := writeTestFile(path, source); err != nil {
		t.Fatal(err)
	}
	app := New(workspace.NewOSFileStore())
	t.Cleanup(app.CloseDerived)
	if err := app.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	doc := app.ActiveDocument()
	waitForDerived(t, app, doc, time.Second)

	window, err := app.QueryStructuralView(app.Active, StructuralProjectionSymbols, 0, 8)
	if err != nil {
		t.Fatal(err)
	}
	if !window.Ready || !window.Supported || window.Total < 2 {
		t.Fatalf("code symbols = %+v", window)
	}
	names := make(map[string]bool, len(window.Segments))
	for _, segment := range window.Segments {
		if segment.Status != ProjectionCurrent || segment.SourceRevision != doc.Revision() ||
			segment.StartByte < 0 || segment.EndByte <= segment.StartByte || segment.Text == "" {
			t.Fatalf("code symbol lost source mapping: %+v", segment)
		}
		names[segment.Context] = true
	}
	if !names["Record"] || !names["OpenRecord"] {
		t.Fatalf("code provider symbol metadata missing: %v", names)
	}
}

func TestStructuralViewRebuildsAfterSourceRevisionAndUsesCurrentProviderData(t *testing.T) {
	path := filepath.Join(t.TempDir(), "refresh-structure.md")
	if err := writeTestFile(path, []byte("# Before\n\n- [ ] old task\n")); err != nil {
		t.Fatal(err)
	}
	app := New(workspace.NewOSFileStore())
	t.Cleanup(app.CloseDerived)
	if err := app.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	doc := app.ActiveDocument()
	waitForDerived(t, app, doc, time.Second)

	before, err := app.QueryStructuralView(app.Active, StructuralProjectionSymbols, 0, 8)
	if err != nil || before.Total != 1 {
		t.Fatalf("initial symbols = %+v, err=%v", before, err)
	}
	if err := doc.ReplaceText([]byte("# After\n\n- [x] new task\n")); err != nil {
		t.Fatal(err)
	}
	pending, err := app.QueryStructuralView(app.Active, StructuralProjectionTasks, 0, 8)
	if err != nil {
		t.Fatal(err)
	}
	if pending.Ready || len(pending.Segments) != 0 {
		t.Fatalf("stale derived ranges must not be exposed after an edit: %+v", pending)
	}
	waitForDerived(t, app, doc, time.Second)
	after, err := app.QueryStructuralView(app.Active, StructuralProjectionSymbols, 0, 8)
	if err != nil || after.Total != 1 {
		t.Fatalf("updated symbols = %+v, err=%v", after, err)
	}
	if after.Generation <= before.Generation || after.Segments[0].Text != "# After" ||
		after.Segments[0].SourceRevision != doc.Revision() {
		t.Fatalf("source edit should rebuild the revision-scoped projection: before=%+v after=%+v", before, after)
	}
}

func TestStructuralViewUnsupportedDocumentFallsBackWithoutChangingEditability(t *testing.T) {
	path := filepath.Join(t.TempDir(), "plain.txt")
	if err := writeTestFile(path, []byte("ordinary editable text")); err != nil {
		t.Fatal(err)
	}
	app := New(workspace.NewOSFileStore())
	t.Cleanup(app.CloseDerived)
	if err := app.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	window, err := app.QueryStructuralView(app.Active, StructuralProjectionLinks, 0, 16)
	if err != nil {
		t.Fatal(err)
	}
	if window.Ready != true || window.Supported || window.Total != 0 || len(window.Segments) != 0 {
		t.Fatalf("unsupported projection should request a full-source fallback: %+v", window)
	}
	if app.ActiveDocument().Editor == nil {
		t.Fatal("unsupported projections must leave the ordinary source editor available")
	}
	if _, err := app.QueryStructuralView(app.Active, StructuralProjectionKind("backlinks"), 0, 16); err != ErrInvalidStructuralProjectionKind {
		t.Fatalf("unknown structural projection kind error = %v", err)
	}
}
