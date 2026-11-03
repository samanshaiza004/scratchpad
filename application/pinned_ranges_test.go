package application_test

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"scratchpad/application"
	"scratchpad/commands"
)

func pinRange(t *testing.T, a *application.Application, id application.DocumentID, start, end int) application.PinID {
	t.Helper()
	doc := a.Documents[id]
	pin, err := a.PinSourceRange(id, doc.InstanceID(), doc.Revision(), start, end)
	if err != nil {
		t.Fatal(err)
	}
	return pin
}

func TestPinnedCapturedIdentitySurvivesStaleReordering(t *testing.T) {
	a, ids := openProjectionSources(t, "alpha beta gamma\n", "another file\n")
	first := pinRange(t, a, ids[0], 0, 5)
	second := pinRange(t, a, ids[0], 6, 10)
	duplicate := pinRange(t, a, ids[0], 0, 5)
	a.Documents[ids[0]].Editor.SetSelection(10, 2)
	before := a.Snapshot()
	original := string(a.Documents[ids[0]].Editor.Buffer.Text())
	s := a.PinnedSnapshot()
	if len(s.Ranges) != 3 || first == second || first == duplicate {
		t.Fatal(s)
	}
	if err := a.MovePinnedRange(s.Epoch, s.Revision, duplicate, -1); err != nil {
		t.Fatal(err)
	}
	if string(a.Documents[ids[0]].Editor.Buffer.Text()) != original {
		t.Fatal("reorder changed source")
	}
	anchor, caret := a.Documents[ids[0]].Editor.Selection()
	if anchor != 10 || caret != 2 || a.Snapshot().Active != before.Active {
		t.Fatal("pin/reorder changed source selection or active document")
	}
	if err := a.Dispatch(application.PresentationCommand{Kind: application.PresentationReplaceDocument, DocumentID: ids[0], StartByte: 0, EndByte: 1, Replacement: []byte("A")}); err != nil {
		t.Fatal(err)
	}
	s = a.PinnedSnapshot()
	if s.SourceInvalidations != 3 || s.Ranges[0].Status != application.ProjectionStale {
		t.Fatal(s)
	}
	if err := a.MovePinnedRange(s.Epoch, s.Revision, first, 1); err != nil {
		t.Fatal(err)
	}
	third := pinRange(t, a, ids[1], 0, 7)
	s = a.PinnedSnapshot()
	if err := a.RemovePinnedRange(s.Epoch, s.Revision, second); err != nil {
		t.Fatal(err)
	}
	s = a.PinnedSnapshot()
	for _, p := range s.Ranges {
		if p.ID != third && p.Status != application.ProjectionStale {
			t.Fatal("recomposition revived stale source", p)
		}
	}
	if _, err := a.ReadPinnedBytes(s.Epoch, s.Revision, first); !errors.Is(err, application.ErrPinnedUnavailable) {
		t.Fatal(err)
	}
	if err := a.CloseDocument(ids[0], true); err != nil {
		t.Fatal(err)
	}
	s = a.PinnedSnapshot()
	if s.Ranges[0].Status != application.ProjectionMissing {
		t.Fatal(s)
	}
	if err := a.OpenPath(string(ids[0])); err != nil {
		t.Fatal(err)
	}
	s = a.PinnedSnapshot()
	for _, p := range s.Ranges {
		if p.ID != third && p.Status != application.ProjectionStale {
			t.Fatal("reopen revived old pin", p)
		}
	}
	if _, err := a.NewProjection("invalid", "new", []application.ProjectionSegment{{DocumentID: ids[1], SourceRevision: 99, StartByte: 0, EndByte: 1}}); err == nil {
		t.Fatal("ordinary constructor accepted stale source")
	}
}

func TestPinnedReadsAreCompleteBoundedAndIndependent(t *testing.T) {
	text := "prefix🙂suffix\r\n\n" + strings.Repeat("a", 200000) + "\nlast\n"
	a, ids := openProjectionSources(t, text, strings.Repeat("other\n", 1000))
	first := pinRange(t, a, ids[0], 6, len(text)-1)
	pinRange(t, a, ids[1], 0, len(strings.Repeat("other\n", 1000)))
	s := a.PinnedSnapshot()
	w, err := a.ReadPinnedWindow(s.Epoch, s.Revision, 0, 256, 64*1024, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(w.Data) > 64*1024 || len(w.Rows) > 256 || w.TotalRows < 1000 {
		t.Fatal(w)
	}
	if !bytes.HasPrefix(w.Data, []byte("🙂suffix")) {
		t.Fatal("first line leaked bytes outside the selected interval")
	}
	var long application.PinnedRow
	for _, r := range w.Rows {
		if r.Kind == "text" && r.HasMore {
			long = r
			break
		}
	}
	if long.Length > 16*1024 || long.Length == 0 {
		t.Fatal("long line did not use bounded continuation", long)
	}
	at := long.EndByte
	read := long.Length
	for at < long.StartByte+200000 {
		page, e := a.ReadPinnedWindow(s.Epoch, s.Revision, long.Row, 1, 64*1024, at)
		if e != nil {
			t.Fatal(e)
		}
		r := page.Rows[0]
		read += r.Length
		if r.EndByte <= at {
			t.Fatal("continuation did not progress")
		}
		at = r.EndByte
		if !r.HasMore {
			break
		}
	}
	if read != 200000 {
		t.Fatal("long selection silently truncated", read)
	}
	if _, err := a.ReadPinnedBytes(s.Epoch, s.Revision, first); err == nil || !strings.Contains(err.Error(), "64 KiB") {
		t.Fatal(err)
	}
	if err := a.RemovePinnedRange(s.Epoch, s.Revision, first); err != nil {
		t.Fatal(err)
	}
	if _, err := a.ReadPinnedWindow(s.Epoch, s.Revision, 0, 10, 1024, 0); !errors.Is(err, application.ErrPinnedRevision) {
		t.Fatal("old ordering accepted", err)
	}
}

func TestPinnedValidationCopyAndWorkspaceLifetime(t *testing.T) {
	a, ids := openProjectionSources(t, "a🙂b\r\n", "last")
	doc := a.Documents[ids[0]]
	for _, bad := range [][2]int{{0, 0}, {2, 3}, {-1, 4}, {0, 100}} {
		if _, err := a.PinSourceRange(ids[0], doc.InstanceID(), 0, bad[0], bad[1]); err == nil {
			t.Fatal("invalid source accepted", bad)
		}
	}
	if _, err := a.PinSourceRange(ids[0], doc.InstanceID()+1, 0, 0, 1); err == nil {
		t.Fatal("wrong instance accepted")
	}
	for range application.MaxPinnedRanges {
		pinRange(t, a, ids[0], 1, 5)
	}
	if _, err := a.PinSourceRange(ids[0], doc.InstanceID(), 0, 0, 1); err == nil {
		t.Fatal("pin limit silently exceeded")
	}
	s := a.PinnedSnapshot()
	data, err := a.ReadPinnedBytes(s.Epoch, s.Revision, s.Ranges[0].ID)
	if err != nil || string(data) != "🙂" {
		t.Fatal(string(data), err)
	}
	root := t.TempDir()
	if err := a.OpenWorkspace(root); err != nil {
		t.Fatal(err)
	}
	cleared := a.PinnedSnapshot()
	if len(cleared.Ranges) != 0 || cleared.Epoch == s.Epoch {
		t.Fatal("workspace switch retained pins", cleared)
	}
	if _, err := a.ReadPinnedBytes(s.Epoch, s.Revision, s.Ranges[0].ID); !errors.Is(err, application.ErrPinnedRevision) {
		t.Fatal(err)
	}
	if err := a.OpenWorkspace(t.TempDir()); err != nil {
		t.Fatal(err)
	}
	if err := a.OpenWorkspace(root); err != nil {
		t.Fatal(err)
	}
	if len(a.PinnedSnapshot().Ranges) != 0 {
		t.Fatal("workspace A/B/A resurrected session pins")
	}
	if _, err := os.Stat(string(ids[0])); err != nil {
		t.Fatal("source was removed by clearing pins", err)
	}
}

func TestPinnedSnapshotKeepsWorkspaceRelativeAndFullPaths(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "internal", "buffer.go")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("package demo\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	a := application.New(nil)
	t.Cleanup(a.CloseDerived)
	if err := a.OpenWorkspace(root); err != nil {
		t.Fatal(err)
	}
	if err := a.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	doc := a.Documents[a.Active]
	if _, err := a.PinSourceRange(a.Active, doc.InstanceID(), doc.Revision(), 0, len("package demo")); err != nil {
		t.Fatal(err)
	}
	pin := a.PinnedSnapshot().Ranges[0]
	if pin.RelativePath != "internal/buffer.go" || pin.Path != path {
		t.Fatalf("pinned paths = relative %q, full %q", pin.RelativePath, pin.Path)
	}
}

func TestPinnedReplaceRefreshesOneSourceSegmentAndUndoRedo(t *testing.T) {
	a, ids := openProjectionSources(t, "before segment after\n", "untouched\n")
	first := pinRange(t, a, ids[0], 7, 14)
	other := pinRange(t, a, ids[0], 0, 6)
	separate := pinRange(t, a, ids[1], 0, 9)
	doc := a.Documents[ids[0]]
	snapshot := a.PinnedSnapshot()

	edit, err := a.ReplacePinned(application.PinnedEditRequest{Epoch: snapshot.Epoch, Revision: snapshot.Revision, ID: first,
		Command: application.PresentationCommand{Kind: application.PresentationReplaceDocument, DocumentID: ids[0], EditorRevision: doc.Revision(),
			StartByte: 7, EndByte: 14, Replacement: []byte("piece"), HasSelectionState: true,
			BeforeAnchorByte: 7, BeforeCursorByte: 14, AfterAnchorByte: 12, AfterCursorByte: 12}})
	if err != nil {
		t.Fatal(err)
	}
	if edit.SourceEdit.StartByte != 7 || edit.SourceEdit.OldEndByte != 14 || edit.SourceEdit.NewEndByte != 12 {
		t.Fatalf("exact source edit = %+v", edit.SourceEdit)
	}
	if got, _ := doc.Editor.Buffer.Bytes(0, doc.Editor.Buffer.ByteLen()); string(got) != "before piece after\n" {
		t.Fatalf("source after pinned edit = %q", got)
	}
	if _, err := a.ResolvePinnedSource(snapshot.Epoch, snapshot.Revision, first); !errors.Is(err, application.ErrPinnedRevision) {
		t.Fatalf("old pinned revision should be rejected: %v", err)
	}
	current := a.PinnedSnapshot()
	var target, stale, unaffected application.PinnedRangeView
	for _, candidate := range current.Ranges {
		switch candidate.ID {
		case first:
			target = candidate
		case other:
			stale = candidate
		case separate:
			unaffected = candidate
		}
	}
	if target.Status != application.ProjectionCurrent || target.StartByte != 7 || target.EndByte != 12 || target.SourceRevision != doc.Revision() {
		t.Fatalf("edited pin was not advanced atomically: %+v", target)
	}
	if stale.Status != application.ProjectionStale || unaffected.Status != application.ProjectionCurrent {
		t.Fatalf("unrelated pin states = stale %+v, other document %+v", stale, unaffected)
	}

	undo, err := a.PinnedHistoryStep(current.Epoch, current.Revision, first, false)
	if err != nil {
		t.Fatal(err)
	}
	if got, _ := doc.Editor.Buffer.Bytes(0, doc.Editor.Buffer.ByteLen()); string(got) != "before segment after\n" {
		t.Fatalf("source after pinned undo = %q", got)
	}
	if undo.UpdatedPin.StartByte != 7 || undo.UpdatedPin.EndByte != 14 || undo.UpdatedPin.SourceRevision != doc.Revision() {
		t.Fatalf("undo did not restore exact pin range: %+v", undo.UpdatedPin)
	}

	afterUndo := a.PinnedSnapshot()
	redo, err := a.PinnedHistoryStep(afterUndo.Epoch, afterUndo.Revision, first, true)
	if err != nil {
		t.Fatal(err)
	}
	if got, _ := doc.Editor.Buffer.Bytes(0, doc.Editor.Buffer.ByteLen()); string(got) != "before piece after\n" {
		t.Fatalf("source after pinned redo = %q", got)
	}
	if redo.UpdatedPin.EndByte != 12 || redo.UpdatedPin.SourceRevision != doc.Revision() {
		t.Fatalf("redo did not advance exact pin range: %+v", redo.UpdatedPin)
	}
}

func TestPinnedReplaceExtendsBoundariesAndRejectsEscapes(t *testing.T) {
	a, ids := openProjectionSources(t, "abcdef\n", "")
	pin := pinRange(t, a, ids[0], 2, 5)
	doc := a.Documents[ids[0]]
	apply := func(start, end int, replacement string) (application.PinnedEditResult, error) {
		s := a.PinnedSnapshot()
		return a.ReplacePinned(application.PinnedEditRequest{Epoch: s.Epoch, Revision: s.Revision, ID: pin,
			Command: application.PresentationCommand{Kind: application.PresentationReplaceDocument, DocumentID: ids[0], EditorRevision: doc.Revision(),
				StartByte: start, EndByte: end, Replacement: []byte(replacement)}})
	}
	if _, err := apply(1, 3, "X"); !errors.Is(err, application.ErrPinnedBoundary) {
		t.Fatalf("cross-boundary replacement = %v", err)
	}
	if got, _ := doc.Editor.Buffer.Bytes(0, doc.Editor.Buffer.ByteLen()); string(got) != "abcdef\n" {
		t.Fatalf("rejected edit changed source: %q", got)
	}
	unchangedRevision := doc.Revision()
	beforeSelection := a.PinnedSnapshot()
	_, err := a.ReplacePinned(application.PinnedEditRequest{Epoch: beforeSelection.Epoch, Revision: beforeSelection.Revision, ID: pin,
		Command: application.PresentationCommand{Kind: application.PresentationReplaceDocument, DocumentID: ids[0], EditorRevision: unchangedRevision,
			StartByte: 3, EndByte: 4, Replacement: []byte("X"), HasSelectionState: true,
			BeforeAnchorByte: 1, BeforeCursorByte: 3, AfterAnchorByte: 4, AfterCursorByte: 4}})
	if !errors.Is(err, application.ErrPinnedBoundary) || doc.Revision() != unchangedRevision {
		t.Fatalf("out-of-pin selection state changed source: %v, revision %d", err, doc.Revision())
	}
	start, err := apply(2, 2, "[")
	if err != nil || start.UpdatedPin.StartByte != 2 || start.UpdatedPin.EndByte != 6 {
		t.Fatalf("insertion at pin start = %+v, %v", start, err)
	}
	end, err := apply(6, 6, "]")
	if err != nil || end.UpdatedPin.StartByte != 2 || end.UpdatedPin.EndByte != 7 {
		t.Fatalf("insertion at pin end = %+v, %v", end, err)
	}
	if _, err := apply(1, 3, ""); !errors.Is(err, application.ErrPinnedBoundary) {
		t.Fatalf("cross-boundary deletion = %v", err)
	}
	empty, err := apply(2, 7, "")
	if err != nil || empty.UpdatedPin.StartByte != 2 || empty.UpdatedPin.EndByte != 2 || empty.UpdatedPin.LineCount != 1 {
		t.Fatalf("deleting the whole pin should retain an empty internal caret pin: %+v, %v", empty, err)
	}
	reinsert, err := apply(2, 2, "again")
	if err != nil || reinsert.UpdatedPin.StartByte != 2 || reinsert.UpdatedPin.EndByte != 7 {
		t.Fatalf("an empty pin should accept a new insertion at its caret: %+v, %v", reinsert, err)
	}
	if got, _ := doc.Editor.Buffer.Bytes(0, doc.Editor.Buffer.ByteLen()); string(got) != "abagainf\n" {
		t.Fatalf("source after reinserting into empty pin = %q", got)
	}
	// Read the updated excerpt, whose byte length remains bounded and complete.
	updated := a.PinnedSnapshot()
	window, err := a.ReadPinnedWindow(updated.Epoch, updated.Revision, 1, 1, 1024, 0)
	if err != nil || len(window.Rows) != 1 || window.Rows[0].Kind != "text" || window.Rows[0].Length != 5 {
		t.Fatalf("updated pin projection = %+v, %v", window, err)
	}
}

func TestPinnedPastePreservesMarkdownSmartLinkBehavior(t *testing.T) {
	path := filepath.Join(t.TempDir(), "note.md")
	if err := os.WriteFile(path, []byte("label\nnext\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	a := application.New(nil)
	t.Cleanup(a.CloseDerived)
	if err := a.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	id := a.Active
	doc := a.Documents[id]
	pin := pinRange(t, a, id, 0, len("label"))
	s := a.PinnedSnapshot()
	result, err := a.ReplacePinned(application.PinnedEditRequest{Epoch: s.Epoch, Revision: s.Revision, ID: pin,
		Command: application.PresentationCommand{Kind: application.PresentationReplaceDocument, ActionID: application.PinnedPasteActionID,
			DocumentID: id, EditorRevision: doc.Revision(), StartByte: 0, EndByte: len("label"),
			Replacement: []byte("https://example.com"), HasSelectionState: true,
			BeforeAnchorByte: 0, BeforeCursorByte: len("label"), AfterAnchorByte: len("https://example.com"), AfterCursorByte: len("https://example.com")}})
	if err != nil {
		t.Fatal(err)
	}
	got, _ := doc.Editor.Buffer.Bytes(0, doc.Editor.Buffer.ByteLen())
	if string(got) != "[label](https://example.com)\nnext\n" {
		t.Fatalf("pinned Markdown paste = %q", got)
	}
	if result.UpdatedPin.Status != application.ProjectionCurrent || result.UpdatedPin.EndByte != len("[label](https://example.com)") {
		t.Fatalf("smart-link pin range = %+v", result.UpdatedPin)
	}
}

func TestPinnedMarkdownEnterValidatesNormalizedRangeBeforeMutation(t *testing.T) {
	path := filepath.Join(t.TempDir(), "note.md")
	if err := os.WriteFile(path, []byte("- \n"), 0o644); err != nil {
		t.Fatal(err)
	}
	a := application.New(nil)
	t.Cleanup(a.CloseDerived)
	if err := a.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	id := a.Active
	pin := pinRange(t, a, id, 1, 2)
	doc := a.Documents[id]
	snapshot := a.PinnedSnapshot()
	_, err := a.ReplacePinned(application.PinnedEditRequest{Epoch: snapshot.Epoch, Revision: snapshot.Revision, ID: pin,
		Command: application.PresentationCommand{Kind: application.PresentationReplaceDocument, ActionID: string(commands.MarkdownEnter),
			DocumentID: id, EditorRevision: doc.Revision(), StartByte: 2, EndByte: 2, Replacement: []byte{'\n'},
			HasSelectionState: true, BeforeAnchorByte: 2, BeforeCursorByte: 2, AfterAnchorByte: 3, AfterCursorByte: 3}})
	if !errors.Is(err, application.ErrPinnedBoundary) {
		t.Fatalf("normalized Markdown breakout outside pin = %v", err)
	}
	if got, _ := doc.Editor.Buffer.Bytes(0, doc.Editor.Buffer.ByteLen()); string(got) != "- \n" {
		t.Fatalf("rejected Markdown breakout changed source: %q", got)
	}
}

func TestPinnedHistoryRejectsMostRecentEditOutsidePin(t *testing.T) {
	a, ids := openProjectionSources(t, "inside outside\n", "")
	pin := pinRange(t, a, ids[0], 0, 6)
	doc := a.Documents[ids[0]]
	if _, err := doc.ReplaceResult(7, 14, []byte("different")); err != nil {
		t.Fatal(err)
	}
	// Rebind only the pin under test to the new revision for this setup; the
	// source edit history remains intact and must not be mistaken for pin work.
	if err := a.RemovePinnedRange(a.PinnedSnapshot().Epoch, a.PinnedSnapshot().Revision, pin); err != nil {
		t.Fatal(err)
	}
	pin = pinRange(t, a, ids[0], 0, 6)
	s := a.PinnedSnapshot()
	before, _ := doc.Editor.Buffer.Bytes(0, doc.Editor.Buffer.ByteLen())
	if _, err := a.PinnedHistoryStep(s.Epoch, s.Revision, pin, false); !errors.Is(err, application.ErrPinnedBoundary) {
		t.Fatalf("undo outside pinned range = %v", err)
	}
	after, _ := doc.Editor.Buffer.Bytes(0, doc.Editor.Buffer.ByteLen())
	if !bytes.Equal(before, after) {
		t.Fatal("out-of-pin undo changed source")
	}
}
