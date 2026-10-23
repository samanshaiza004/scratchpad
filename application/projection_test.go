package application_test

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"scratchpad/application"
)

func openProjectionSources(t *testing.T, sources ...string) (*application.Application, []application.DocumentID) {
	t.Helper()
	app := application.New(nil)
	t.Cleanup(app.CloseDerived)
	dir := t.TempDir()
	ids := make([]application.DocumentID, len(sources))
	for i, source := range sources {
		path := filepath.Join(dir, string(rune('a'+i))+".txt")
		if err := os.WriteFile(path, []byte(source), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := app.OpenPath(path); err != nil {
			t.Fatal(err)
		}
		ids[i] = app.Active
	}
	return app, ids
}

func projectionWindow(t *testing.T, app *application.Application, proj *application.Projection, first, limit int) application.ProjectionWindow {
	t.Helper()
	window, err := app.QueryProjection(proj, first, limit)
	if err != nil {
		t.Fatal(err)
	}
	return window
}

func TestProjectionOrderedSourceRanges(t *testing.T) {
	app, ids := openProjectionSources(t, "alpha beta gamma", "delta epsilon")
	tests := []struct {
		name     string
		segments []application.ProjectionSegment
	}{
		{
			name: "single document",
			segments: []application.ProjectionSegment{
				{DocumentID: ids[0], StartByte: 11, EndByte: 16, Label: "last"},
				{DocumentID: ids[0], StartByte: 0, EndByte: 5, Context: "first"},
				{DocumentID: ids[0], StartByte: 6, EndByte: 10},
			},
		},
		{
			name: "multiple documents",
			segments: []application.ProjectionSegment{
				{DocumentID: ids[1], StartByte: 6, EndByte: 13, Label: "second file"},
				{DocumentID: ids[0], StartByte: 0, EndByte: 5, Context: "first file"},
				{DocumentID: ids[1], StartByte: 0, EndByte: 5},
			},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			proj, err := app.NewProjection("ordered", "caller-defined-kind", tt.segments)
			if err != nil {
				t.Fatal(err)
			}
			window := projectionWindow(t, app, proj, 0, 10)
			if window.ID != "ordered" || window.Kind != "caller-defined-kind" || window.Generation == 0 || window.Total != len(tt.segments) || window.First != 0 || len(window.Segments) != len(tt.segments) {
				t.Fatalf("window = %+v", window)
			}
			for i, view := range window.Segments {
				if view.ProjectionSegment != tt.segments[i] || view.Status != application.ProjectionCurrent {
					t.Fatalf("segment %d = %+v, want %+v current", i, view, tt.segments[i])
				}
				if view.PresentationKey != (application.ProjectionKey{Generation: window.Generation, Ordinal: i}) {
					t.Fatalf("segment %d key = %+v", i, view.PresentationKey)
				}
			}
		})
	}
}

func TestProjectionReorderAndRebuildPreserveSourceState(t *testing.T) {
	app, ids := openProjectionSources(t, "alpha beta gamma", "delta epsilon")
	app.Documents[ids[0]].Editor.SetSelection(10, 2)
	if err := app.Dispatch(application.PresentationCommand{
		Kind: application.PresentationReplaceDocument, DocumentID: ids[1],
		StartByte: 0, EndByte: 1, Replacement: []byte("D"),
		HasSelectionState: true, BeforeAnchorByte: 12, BeforeCursorByte: 1,
		AfterAnchorByte: 10, AfterCursorByte: 3,
	}); err != nil {
		t.Fatal(err)
	}
	before := app.Snapshot()
	texts := make(map[application.DocumentID]string)
	instances := make(map[application.DocumentID]uint64)
	for _, id := range ids {
		texts[id] = string(app.Documents[id].Editor.Buffer.Text())
		instances[id] = app.Documents[id].InstanceID()
	}
	segments := []application.ProjectionSegment{
		{DocumentID: ids[0], StartByte: 0, EndByte: 5},
		{DocumentID: ids[1], SourceRevision: app.Documents[ids[1]].Revision(), StartByte: 6, EndByte: 13},
		{DocumentID: ids[0], StartByte: 11, EndByte: 16},
	}
	proj, err := app.NewProjection("rebuild", "pinned", segments)
	if err != nil {
		t.Fatal(err)
	}
	original := projectionWindow(t, app, proj, 0, 10)
	segments[0], segments[2] = segments[2], segments[0]
	rebuilt, err := app.NewProjection("rebuild", "pinned", segments)
	if err != nil {
		t.Fatal(err)
	}
	reordered := projectionWindow(t, app, rebuilt, 0, 10)
	if reordered.Generation != original.Generation+1 {
		t.Fatalf("rebuilt generation = %d, previous = %d", reordered.Generation, original.Generation)
	}
	for i, segment := range reordered.Segments {
		if segment.ProjectionSegment != segments[i] || segment.Status != application.ProjectionCurrent || segment.PresentationKey == original.Segments[i].PresentationKey {
			t.Fatalf("rebuilt segment %d = %+v", i, segment)
		}
	}
	if got := projectionWindow(t, app, proj, 0, 10); !reflect.DeepEqual(got, original) {
		t.Fatalf("rebuild changed original projection: %+v", got)
	}
	proj = nil // Discarding a generation needs no application cleanup operation.
	if got := app.Snapshot(); !reflect.DeepEqual(got, before) {
		t.Fatalf("projection operations changed application/source state:\nbefore: %+v\nafter: %+v", before, got)
	}
	for _, id := range ids {
		doc := app.Documents[id]
		if string(doc.Editor.Buffer.Text()) != texts[id] || doc.InstanceID() != instances[id] {
			t.Fatalf("source %q changed", id)
		}
	}
}

func TestProjectionSourceEditCloseAndReopen(t *testing.T) {
	app, ids := openProjectionSources(t, "alpha beta", "delta epsilon")
	segments := []application.ProjectionSegment{
		{DocumentID: ids[0], StartByte: 0, EndByte: 5},
		{DocumentID: ids[1], StartByte: 6, EndByte: 13},
	}
	proj, err := app.NewProjection("lifecycle", "ranges", segments)
	if err != nil {
		t.Fatal(err)
	}
	original := projectionWindow(t, app, proj, 0, 2)
	instanceID := app.Documents[ids[0]].InstanceID()
	if instanceID == 0 || instanceID == app.Documents[ids[1]].InstanceID() {
		t.Fatal("open documents must have distinct nonzero instance identities")
	}
	assertStatus := func(want application.ProjectionStatus) {
		t.Helper()
		window := projectionWindow(t, app, proj, 0, 2)
		if window.Segments[0].Status != want || window.Segments[1].Status != application.ProjectionCurrent {
			t.Fatalf("segment statuses = %+v, want %s and current", window.Segments, want)
		}
		for i, view := range window.Segments {
			if view.ProjectionSegment != original.Segments[i].ProjectionSegment || view.PresentationKey != original.Segments[i].PresentationKey {
				t.Fatalf("lifecycle changed captured segment %d: %+v", i, view)
			}
		}
	}
	assertStatus(application.ProjectionCurrent)
	if err := app.Dispatch(application.PresentationCommand{
		Kind: application.PresentationReplaceDocument, DocumentID: ids[0],
		StartByte: 0, EndByte: 10, Replacement: []byte("x"),
	}); err != nil {
		t.Fatal(err)
	}
	assertStatus(application.ProjectionStale)
	if app.Documents[ids[0]].InstanceID() != instanceID {
		t.Fatal("editing changed document instance identity")
	}
	if err := app.CloseDocument(ids[0], true); err != nil {
		t.Fatal(err)
	}
	assertStatus(application.ProjectionMissing)
	if err := app.OpenPath(string(ids[0])); err != nil {
		t.Fatal(err)
	}
	if app.Active != ids[0] || app.Documents[ids[0]].Revision() != segments[0].SourceRevision {
		t.Fatal("test requires reopening the same path and source revision")
	}
	if got := app.Documents[ids[0]].InstanceID(); got == 0 || got == instanceID {
		t.Fatalf("reopened instance = %d, old = %d", got, instanceID)
	}
	assertStatus(application.ProjectionStale)
	rebuilt, err := app.NewProjection("lifecycle", "ranges", segments)
	if err != nil {
		t.Fatal(err)
	}
	window := projectionWindow(t, app, rebuilt, 0, 2)
	if window.Generation <= original.Generation || window.Segments[0].Status != application.ProjectionCurrent {
		t.Fatalf("rebuilt after reopen = %+v", window)
	}
	assertStatus(application.ProjectionStale)
}

func TestProjectionWindowFrontiersAndDuplicateKeys(t *testing.T) {
	app, ids := openProjectionSources(t, "abc")
	segments := make([]application.ProjectionSegment, application.MaxProjectionWindow+3)
	for i := range segments {
		segments[i] = application.ProjectionSegment{DocumentID: ids[0], StartByte: 0, EndByte: 3}
	}
	proj, err := app.NewProjection("frontier", "duplicates", segments)
	if err != nil {
		t.Fatal(err)
	}
	first := projectionWindow(t, app, proj, 0, application.MaxProjectionWindow)
	if len(first.Segments) != application.MaxProjectionWindow || first.Total != len(segments) {
		t.Fatalf("first window = %+v", first)
	}
	keys := make(map[application.ProjectionKey]bool)
	for i, view := range first.Segments {
		if keys[view.PresentationKey] || view.PresentationKey.Ordinal != i {
			t.Fatalf("duplicate or misplaced occurrence key = %+v", view.PresentationKey)
		}
		keys[view.PresentationKey] = true
	}
	overlap := projectionWindow(t, app, proj, 1, 1)
	if overlap.Segments[0] != first.Segments[1] {
		t.Fatal("overlapping windows changed occurrence identity")
	}
	maxInt := int(^uint(0) >> 1)
	for _, tt := range []struct {
		first int
		limit int
		count int
	}{
		{0, 1, 1},
		{application.MaxProjectionWindow, application.MaxProjectionWindow, 3},
		{len(segments) - 1, application.MaxProjectionWindow, 1},
		{len(segments), 1, 0},
		{len(segments) + 1, application.MaxProjectionWindow, 0},
		{maxInt, application.MaxProjectionWindow, 0},
	} {
		window := projectionWindow(t, app, proj, tt.first, tt.limit)
		if window.First != tt.first || window.Total != len(segments) || window.Generation != first.Generation || window.ID != first.ID || window.Kind != first.Kind || len(window.Segments) != tt.count {
			t.Fatalf("query first=%d limit=%d = %+v", tt.first, tt.limit, window)
		}
		for i, view := range window.Segments {
			if view.PresentationKey != (application.ProjectionKey{Generation: first.Generation, Ordinal: tt.first + i}) {
				t.Fatalf("frontier segment %d key = %+v", i, view.PresentationKey)
			}
		}
	}
	for _, tt := range []struct{ first, limit int }{
		{-1, 1}, {0, 0}, {0, -1}, {0, application.MaxProjectionWindow + 1}, {maxInt, maxInt},
	} {
		if _, err := app.QueryProjection(proj, tt.first, tt.limit); err == nil {
			t.Fatalf("accepted invalid window first=%d limit=%d", tt.first, tt.limit)
		}
	}
}

func TestProjectionMetadataDoesNotAliasCaller(t *testing.T) {
	app, ids := openProjectionSources(t, "alpha beta")
	segments := []application.ProjectionSegment{
		{DocumentID: ids[0], StartByte: 0, EndByte: 5, Label: "alpha", Context: "caller context"},
		{DocumentID: ids[0], StartByte: 6, EndByte: 10},
	}
	proj, err := app.NewProjection("copy", "ranges", segments)
	if err != nil {
		t.Fatal(err)
	}
	original := projectionWindow(t, app, proj, 0, 2)
	segments[0] = application.ProjectionSegment{DocumentID: "changed", SourceRevision: 99, StartByte: 2, EndByte: 3, Label: "changed", Context: "changed"}
	segments[1] = segments[0]
	mutated := projectionWindow(t, app, proj, 0, 2)
	if !reflect.DeepEqual(mutated, original) {
		t.Fatal("caller input mutation changed projection metadata")
	}
	mutated.ID, mutated.Kind, mutated.Generation, mutated.Total, mutated.First = "changed", "changed", 99, 99, 99
	mutated.Segments[0] = application.ProjectionSegmentView{
		ProjectionSegment: segments[0],
		PresentationKey:   application.ProjectionKey{Generation: 99, Ordinal: 99},
		Status:            application.ProjectionMissing,
	}
	mutated.Segments = append(mutated.Segments[:1], mutated.Segments[0])
	if got := projectionWindow(t, app, proj, 0, 2); !reflect.DeepEqual(got, original) {
		t.Fatalf("caller output mutation changed projection metadata: %+v", got)
	}
}

func TestProjectionConstructionValidation(t *testing.T) {
	app, ids := openProjectionSources(t, "abc", "")
	valid := application.ProjectionSegment{DocumentID: ids[0], StartByte: 0, EndByte: 3}
	for _, tt := range []struct {
		name    string
		segment application.ProjectionSegment
		stale   bool
	}{
		{"unknown document", application.ProjectionSegment{DocumentID: "missing", StartByte: 0, EndByte: 1}, false},
		{"empty document ID", application.ProjectionSegment{StartByte: 0, EndByte: 1}, false},
		{"stale revision", application.ProjectionSegment{DocumentID: ids[0], SourceRevision: 1, StartByte: 0, EndByte: 1}, true},
		{"negative start", application.ProjectionSegment{DocumentID: ids[0], StartByte: -1, EndByte: 1}, false},
		{"empty range", application.ProjectionSegment{DocumentID: ids[0], StartByte: 1, EndByte: 1}, false},
		{"reversed range", application.ProjectionSegment{DocumentID: ids[0], StartByte: 2, EndByte: 1}, false},
		{"past end", application.ProjectionSegment{DocumentID: ids[0], StartByte: 0, EndByte: 4}, false},
		{"start at end", application.ProjectionSegment{DocumentID: ids[0], StartByte: 3, EndByte: 4}, false},
		{"empty source", application.ProjectionSegment{DocumentID: ids[1], StartByte: 0, EndByte: 1}, false},
	} {
		t.Run(tt.name, func(t *testing.T) {
			proj, err := app.NewProjection("invalid", "ranges", []application.ProjectionSegment{valid, tt.segment})
			if err == nil || proj != nil {
				t.Fatalf("invalid construction = %v, %v", proj, err)
			}
			if tt.stale && !errors.Is(err, application.ErrStaleEditorRevision) {
				t.Fatalf("revision error = %v, want ErrStaleEditorRevision", err)
			}
		})
	}
	for _, header := range []struct{ id, kind string }{{"", "ranges"}, {"id", ""}} {
		if _, err := app.NewProjection(header.id, header.kind, nil); err == nil {
			t.Fatalf("accepted empty header %+v", header)
		}
	}
	proj, err := app.NewProjection("valid", "ranges", []application.ProjectionSegment{valid})
	if err != nil {
		t.Fatal(err)
	}
	if got := projectionWindow(t, app, proj, 0, 1).Generation; got != 1 {
		t.Fatalf("failed builds consumed generations: first valid generation = %d", got)
	}
}

func TestProjectionEmptyAndInvalidHandles(t *testing.T) {
	app := application.New(nil)
	proj, err := app.NewProjection("empty", "ranges", nil)
	if err != nil {
		t.Fatal(err)
	}
	for _, first := range []int{0, 1, int(^uint(0) >> 1)} {
		window := projectionWindow(t, app, proj, first, application.MaxProjectionWindow)
		if window.ID != "empty" || window.Kind != "ranges" || window.Generation == 0 || window.Total != 0 || window.First != first || len(window.Segments) != 0 {
			t.Fatalf("empty window = %+v", window)
		}
	}
	for _, invalid := range []*application.Projection{nil, {}} {
		if _, err := app.QueryProjection(invalid, 0, 1); err == nil {
			t.Fatal("accepted unconstructed projection")
		}
	}
	var absent *application.Application
	if _, err := absent.NewProjection("nil", "ranges", nil); err == nil {
		t.Fatal("nil application constructed a projection")
	}
	if _, err := absent.QueryProjection(proj, 0, 1); err == nil {
		t.Fatal("nil application queried a projection")
	}
}
