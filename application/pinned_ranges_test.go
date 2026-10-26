package application_test

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"scratchpad/application"
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
