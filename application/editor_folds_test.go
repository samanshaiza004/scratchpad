package application

import (
	"errors"
	"strings"
	"testing"

	"scratchpad/language"
)

func TestQueryEditorFoldsMarkdownUsesSourceLinesAndKeepsHeadingVisible(t *testing.T) {
	source := "# Parent\nintro\n\n## Child\nchild body\n\n# Next\nnext body"
	app, id := zoomTestDocument(t, source, string(language.Markdown))
	doc := app.Documents[id]
	doc.Editor.SetSelection(strings.Index(source, "intro"), strings.Index(source, "child body"))
	beforeText := string(doc.Editor.Buffer.Text())
	beforeRevision := doc.Revision()
	anchor, caret := doc.Editor.Selection()

	plan, err := app.QueryEditorFolds(id, beforeRevision)
	if err != nil {
		t.Fatal(err)
	}
	if !plan.Ready || !plan.Supported || plan.DocumentID != id || plan.Revision != beforeRevision ||
		plan.InstanceID != doc.InstanceID() || plan.LineCount != doc.Editor.Buffer.LineCount() {
		t.Fatalf("unexpected fold plan: %+v", plan)
	}
	parentStart := strings.Index(source, "# Parent")
	parentBody := strings.Index(source, "intro")
	nextHeading := strings.Index(source, "# Next")
	parent, found := editorFoldAtLine(plan, 0)
	if !found || parent.StartByte != parentStart || parent.BodyStartByte != parentBody ||
		parent.BodyStartLine != 1 || parent.EndByte != nextHeading || parent.EndLine != 6 || parent.Label == "" {
		t.Fatalf("parent fold does not preserve heading/source coordinates: %+v", parent)
	}
	childLine := strings.Count(source[:strings.Index(source, "## Child")], "\n")
	child, found := editorFoldAtLine(plan, childLine)
	if !found || child.BodyStartByte != strings.Index(source, "child body") || child.BodyStartLine != childLine+1 ||
		child.EndByte != nextHeading {
		t.Fatalf("nested Markdown fold has incorrect body coordinates: %+v", child)
	}
	if string(doc.Editor.Buffer.Text()) != beforeText || doc.Revision() != beforeRevision || doc.CanUndo() {
		t.Fatal("querying folds changed source or undo history")
	}
	gotAnchor, gotCaret := doc.Editor.Selection()
	if gotAnchor != anchor || gotCaret != caret {
		t.Fatal("querying folds changed the source selection")
	}
}

func TestQueryEditorFoldsGoPreservesOpeningDelimiterLine(t *testing.T) {
	if !AnalysisSupported(language.Go) {
		t.Skip("Go analysis adapter unavailable")
	}
	source := "package demo\n\nfunc Run() {\n\tfirst()\n\tsecond()\n}\n"
	app, id := zoomTestDocument(t, source, string(language.Go))
	doc := app.Documents[id]
	plan, err := app.QueryEditorFolds(id, doc.Revision())
	if err != nil {
		t.Fatal(err)
	}
	if !plan.Ready || !plan.Supported || len(plan.Folds) == 0 {
		t.Fatalf("Go fold plan unavailable: %+v", plan)
	}
	functionLine := strings.Count(source[:strings.Index(source, "func Run")], "\n")
	bodyByte := strings.Index(source, "\tfirst()")
	bodyLine := strings.Count(source[:bodyByte], "\n")
	var found bool
	for _, fold := range plan.Folds {
		if fold.StartLine == functionLine && fold.BodyStartLine == bodyLine && fold.BodyStartByte == bodyByte {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("Go fold must retain the declaration/opening-delimiter line and begin at the first body line: %+v", plan.Folds)
	}

	oldRevision := doc.Revision()
	if err := doc.Insert([]byte("// prefix\n")); err != nil {
		t.Fatal(err)
	}
	if _, err := app.QueryEditorFolds(id, oldRevision); !errors.Is(err, ErrStaleEditorRevision) {
		t.Fatalf("stale fold query error = %v, want ErrStaleEditorRevision", err)
	}
}

func editorFoldAtLine(plan EditorFoldPlan, line int) (EditorFold, bool) {
	for _, fold := range plan.Folds {
		if fold.StartLine == line {
			return fold, true
		}
	}
	return EditorFold{}, false
}
