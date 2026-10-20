package application

import (
	"bytes"
	"path/filepath"
	"testing"
	"time"
	"unicode/utf8"

	"scratchpad/language"
	"scratchpad/workspace"
)

func TestChangingDocumentViewDensityPreservesSourceRevisionAndSelection(t *testing.T) {
	path := filepath.Join(t.TempDir(), "notes.md")
	source := []byte("# Notes\n\nKeep this source authoritative.\n")
	if err := writeTestFile(path, source); err != nil {
		t.Fatal(err)
	}

	app := New(workspace.NewOSFileStore())
	t.Cleanup(app.CloseDerived)
	if err := app.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	doc := app.ActiveDocument()
	doc.Editor.SetSelection(8, 18)
	before := doc.Snapshot()
	beforeBytes := before.Buffer.Materialize()
	beforeAnchor, beforeCursor := doc.Editor.Selection()

	for _, mode := range []ViewDensity{ViewDensitySkim, ViewDensityOutline, ViewDensityFull} {
		if err := app.SetViewDensity(app.Active, mode); err != nil {
			t.Fatalf("set %q density: %v", mode, err)
		}
		if got := app.ViewDensity(app.Active); got != mode {
			t.Fatalf("view density = %q, want %q", got, mode)
		}
		after := doc.Snapshot()
		if after.Revision != before.Revision {
			t.Fatalf("view change mutated source revision: got %d, want %d", after.Revision, before.Revision)
		}
		if got := after.Buffer.Materialize(); !bytes.Equal(got, beforeBytes) {
			t.Fatalf("view change mutated source bytes: got %q, want %q", got, beforeBytes)
		}
		anchor, cursor := doc.Editor.Selection()
		if anchor != beforeAnchor || cursor != beforeCursor {
			t.Fatalf("view change moved source selection: got %d:%d, want %d:%d", anchor, cursor, beforeAnchor, beforeCursor)
		}
	}
}

func TestOutlineViewReturnsCurrentSourceMappedHeadings(t *testing.T) {
	path := filepath.Join(t.TempDir(), "outline.md")
	source := []byte("# Introduction\n\nOpening paragraph.\n\n## Details\n\nMore text.\n")
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
	if err := app.SetViewDensity(app.Active, ViewDensityOutline); err != nil {
		t.Fatal(err)
	}

	window, err := app.QueryView(app.Active, 0, 8)
	if err != nil {
		t.Fatal(err)
	}
	if !window.Ready || !window.Supported || window.Mode != ViewDensityOutline || window.Revision != doc.Revision() {
		t.Fatalf("outline window state = %+v", window)
	}
	if window.Total != 2 || len(window.Segments) != 2 {
		t.Fatalf("outline segments = %d of %d, want both headings", len(window.Segments), window.Total)
	}
	for i, want := range []string{"# Introduction", "## Details"} {
		segment := window.Segments[i]
		if segment.Text != want || segment.Status != ProjectionCurrent || segment.StartByte < 0 || segment.EndByte <= segment.StartByte {
			t.Errorf("outline segment %d = %+v, want current source range %q", i, segment, want)
		}
	}
	if doc.Revision() != window.Revision || !bytes.Equal(doc.Editor.Buffer.Text(), source) {
		t.Fatal("building an outline changed the authoritative source")
	}
}

func TestSkimViewKeepsStructuralLandmarksAndOneParagraphOpeningPerSection(t *testing.T) {
	path := filepath.Join(t.TempDir(), "skim.md")
	source := []byte("# Project\n\nIntro opening with supporting detail.\nStill the same paragraph.\n\nIgnored second paragraph.\n\n- [ ] Ship the first slice\n\n## Design\n\nA design opening with more context.\n\n```go\nfunc main() {}\n```\n")
	if err := writeTestFile(path, source); err != nil {
		t.Fatal(err)
	}

	app := New(workspace.NewOSFileStore())
	t.Cleanup(app.CloseDerived)
	if err := app.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	waitForDerived(t, app, app.ActiveDocument(), time.Second)
	if err := app.SetViewDensity(app.Active, ViewDensitySkim); err != nil {
		t.Fatal(err)
	}

	window, err := app.QueryView(app.Active, 0, 16)
	if err != nil {
		t.Fatal(err)
	}
	want := []struct{ label, text string }{
		{"heading", "# Project"},
		{"paragraph opening", "Intro opening with supporting detail.\nStill the same paragraph."},
		{"task", "- [ ] Ship the first slice"},
		{"heading", "## Design"},
		{"paragraph opening", "A design opening with more context."},
		{"code", "```go"},
	}
	if !window.Ready || !window.Supported || len(window.Segments) != len(want) {
		t.Fatalf("skim window = %+v, want %d structural excerpts", window, len(want))
	}
	for i, expected := range want {
		segment := window.Segments[i]
		if segment.Label != expected.label || segment.Text != expected.text || segment.Status != ProjectionCurrent {
			t.Errorf("skim segment %d = (%q, %q, %q), want (%q, %q, current)", i, segment.Label, segment.Text, segment.Status, expected.label, expected.text)
		}
		if segment.SourceStartLine == 0 || segment.SourceEndLine < segment.SourceStartLine {
			t.Errorf("skim segment %d has invalid source line mapping: %d-%d", i, segment.SourceStartLine, segment.SourceEndLine)
		}
	}
	if !window.Segments[1].OmittedBefore || !window.Segments[len(window.Segments)-1].OmittedAfter {
		t.Fatalf("skim must visibly identify omitted boundaries: first paragraph=%+v final code=%+v", window.Segments[1], window.Segments[len(window.Segments)-1])
	}
}

func TestUnsupportedPlainTextKeepsAValidFullFallback(t *testing.T) {
	path := filepath.Join(t.TempDir(), "plain.txt")
	if err := writeTestFile(path, []byte("plain source stays readable")); err != nil {
		t.Fatal(err)
	}
	app := New(workspace.NewOSFileStore())
	t.Cleanup(app.CloseDerived)
	if err := app.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	if err := app.SetViewDensity(app.Active, ViewDensityOutline); err != nil {
		t.Fatal(err)
	}
	window, err := app.QueryView(app.Active, 0, 8)
	if err != nil {
		t.Fatal(err)
	}
	if window.Mode != ViewDensityOutline || !window.Ready || window.Supported || window.Total != 0 || len(window.Segments) != 0 {
		t.Fatalf("unsupported source should request ordinary full-editor fallback: %+v", window)
	}
}

func TestCodeSkimShowsABoundedOpeningBeyondOutlineSignatures(t *testing.T) {
	if !AnalysisSupported(language.Go) {
		t.Skip("Go analysis adapter is not enabled in this build")
	}
	path := filepath.Join(t.TempDir(), "sample.go")
	source := []byte("package sample\n\nfunc Start() {\n\tprepare()\n\tcontinueWork()\n}\n\nfunc Stop() {\n\tcleanup()\n}\n")
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

	if err := app.SetViewDensity(app.Active, ViewDensityOutline); err != nil {
		t.Fatal(err)
	}
	outline, err := app.QueryView(app.Active, 0, 8)
	if err != nil {
		t.Fatal(err)
	}
	if len(outline.Segments) < 2 || outline.Segments[0].Text != "func Start() {" {
		t.Fatalf("code outline should show declaration signatures only: %+v", outline.Segments)
	}

	if err := app.SetViewDensity(app.Active, ViewDensitySkim); err != nil {
		t.Fatal(err)
	}
	skim, err := app.QueryView(app.Active, 0, 8)
	if err != nil {
		t.Fatal(err)
	}
	if len(skim.Segments) < 2 || skim.Segments[0].Text != "func Start() {\n\tprepare()" {
		t.Fatalf("code skim should add only the first body line: %+v", skim.Segments)
	}
	if skim.Generation <= outline.Generation {
		t.Fatalf("density changes should produce distinct projection generations: outline=%d skim=%d", outline.Generation, skim.Generation)
	}
	if len(skim.Segments[0].Text) > MaxViewExcerptBytes || skim.Segments[0].EndByte <= skim.Segments[0].StartByte {
		t.Fatalf("code skim excerpt must remain bounded and source-mapped: %+v", skim.Segments[0])
	}
}

func TestSemanticViewRefreshesItsProjectionAfterSourceRevisionChanges(t *testing.T) {
	path := filepath.Join(t.TempDir(), "refresh.md")
	if err := writeTestFile(path, []byte("# Before\n\nFirst paragraph.\n")); err != nil {
		t.Fatal(err)
	}
	app := New(workspace.NewOSFileStore())
	t.Cleanup(app.CloseDerived)
	if err := app.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	doc := app.ActiveDocument()
	waitForDerived(t, app, doc, time.Second)
	if err := app.SetViewDensity(app.Active, ViewDensityOutline); err != nil {
		t.Fatal(err)
	}
	before, err := app.QueryView(app.Active, 0, 8)
	if err != nil || len(before.Segments) != 1 {
		t.Fatalf("initial outline = %+v, err=%v", before, err)
	}
	if err := doc.ReplaceText([]byte("# After\n\nSecond paragraph.\n\n## Detail\n")); err != nil {
		t.Fatal(err)
	}
	waitForDerived(t, app, doc, time.Second)
	after, err := app.QueryView(app.Active, 0, 8)
	if err != nil || len(after.Segments) != 2 {
		t.Fatalf("updated outline = %+v, err=%v", after, err)
	}
	if after.Revision != doc.Revision() || after.Segments[0].SourceRevision != doc.Revision() ||
		after.Generation <= before.Generation || after.Segments[0].Text != "# After" {
		t.Fatalf("source edit must refresh the revision-tagged projection: before=%+v after=%+v", before, after)
	}
}

func TestLargeSemanticExcerptReturnsOnlyBoundedText(t *testing.T) {
	path := filepath.Join(t.TempDir(), "large.md")
	paragraph := bytes.Repeat([]byte("word "), MaxViewExcerptBytes)
	source := append([]byte("# Large\n\n"), paragraph...)
	source = append(source, '\n')
	if err := writeTestFile(path, source); err != nil {
		t.Fatal(err)
	}
	app := New(workspace.NewOSFileStore())
	t.Cleanup(app.CloseDerived)
	if err := app.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	waitForDerived(t, app, app.ActiveDocument(), time.Second)
	if err := app.SetViewDensity(app.Active, ViewDensitySkim); err != nil {
		t.Fatal(err)
	}
	window, err := app.QueryView(app.Active, 0, 8)
	if err != nil {
		t.Fatal(err)
	}
	if len(window.Segments) != 2 {
		t.Fatalf("large skim excerpt count = %d, want heading + paragraph", len(window.Segments))
	}
	paragraphView := window.Segments[1]
	if !paragraphView.Truncated || len(paragraphView.Text) > MaxViewExcerptBytes || paragraphView.EndByte-paragraphView.StartByte <= MaxViewExcerptBytes {
		t.Fatalf("large excerpt should expose bounded text while retaining its full source range: %+v", paragraphView)
	}
}

func TestSemanticExcerptTruncationPreservesUTF8(t *testing.T) {
	path := filepath.Join(t.TempDir(), "unicode.md")
	paragraph := bytes.Repeat([]byte("é"), MaxViewExcerptBytes)
	source := append([]byte("# Unicode\n\n"), paragraph...)
	if err := writeTestFile(path, source); err != nil {
		t.Fatal(err)
	}
	app := New(workspace.NewOSFileStore())
	t.Cleanup(app.CloseDerived)
	if err := app.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	waitForDerived(t, app, app.ActiveDocument(), time.Second)
	if err := app.SetViewDensity(app.Active, ViewDensitySkim); err != nil {
		t.Fatal(err)
	}
	window, err := app.QueryView(app.Active, 0, 8)
	if err != nil {
		t.Fatal(err)
	}
	if len(window.Segments) != 2 || !window.Segments[1].Truncated || !utf8.ValidString(window.Segments[1].Text) || len(window.Segments[1].Text) > MaxViewExcerptBytes {
		t.Fatalf("truncated Unicode excerpt should remain valid UTF-8 and bounded: %+v", window.Segments)
	}
}

func TestSessionViewportUpdatePreservesSelectedViewDensity(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session-mode.md")
	if err := writeTestFile(path, []byte("# Session mode\n")); err != nil {
		t.Fatal(err)
	}
	app := New(workspace.NewOSFileStore())
	t.Cleanup(app.CloseDerived)
	if err := app.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	id := app.Active
	if err := app.SetViewDensity(id, ViewDensitySkim); err != nil {
		t.Fatal(err)
	}
	app.ApplySessionView(SessionView{Documents: []SessionViewDocument{{ID: id, Anchor: 2, Cursor: 3, ScrollY: 12}}})
	if got := app.ViewDensity(id); got != ViewDensitySkim {
		t.Fatalf("session viewport update reset selected density to %q", got)
	}
}

func TestSessionRoundTripRestoresSemanticViewDensity(t *testing.T) {
	path := filepath.Join(t.TempDir(), "saved-mode.md")
	if err := writeTestFile(path, []byte("# Saved mode\n")); err != nil {
		t.Fatal(err)
	}
	app := New(workspace.NewOSFileStore())
	t.Cleanup(app.CloseDerived)
	if err := app.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	if err := app.SetViewDensity(app.Active, ViewDensityOutline); err != nil {
		t.Fatal(err)
	}
	sessionPath := filepath.Join(t.TempDir(), "session.json")
	if err := app.SaveSession(sessionPath); err != nil {
		t.Fatal(err)
	}
	restored := New(workspace.NewOSFileStore())
	t.Cleanup(restored.CloseDerived)
	if err := restored.RestoreSession(sessionPath); err != nil {
		t.Fatal(err)
	}
	if got := restored.ViewDensity(restored.Active); got != ViewDensityOutline {
		t.Fatalf("restored semantic view density = %q, want outline", got)
	}
}
