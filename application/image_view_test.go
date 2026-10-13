package application

import (
	"bytes"
	"errors"
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"testing"

	"scratchpad/workspace"
)

func writePNGFixture(t *testing.T, path string, width, height int) []byte {
	t.Helper()
	canvas := image.NewRGBA(image.Rect(0, 0, width, height))
	for y := 0; y < height; y++ {
		for x := 0; x < width; x++ {
			canvas.Set(x, y, color.RGBA{R: uint8(x * 40), G: uint8(y * 60), B: 180, A: 255})
		}
	}
	var encoded bytes.Buffer
	if err := png.Encode(&encoded, canvas); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, encoded.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
	return append([]byte(nil), encoded.Bytes()...)
}

func TestImagePreviewUsesReadOnlyDocumentLifecycle(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "sample.png")
	encoded := writePNGFixture(t, path, 3, 2)
	app := New(nil)
	if err := app.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	id := app.Active
	view := app.FileViews[id]
	if view.Kind != FileViewImage || view.Format != "PNG" || view.Width != 3 || view.Height != 2 || view.Revision == 0 {
		t.Fatalf("image view metadata = %+v", view)
	}
	state := app.Snapshot()
	if len(state.Documents) != 1 || state.Documents[0].ViewKind != FileViewImage || state.Documents[0].ImageFormat != "PNG" {
		t.Fatalf("image document snapshot = %+v", state.Documents)
	}
	read, err := app.ImagePreviewBytes(id, view.Revision)
	if err != nil || !bytes.Equal(read, encoded) {
		t.Fatalf("read image bytes: err=%v bytes-match=%v", err, bytes.Equal(read, encoded))
	}
	if _, err := app.ImagePreviewBytes(id, view.Revision+1); err == nil {
		t.Fatal("stale image revision should be rejected")
	}
	if err := app.SaveDocument(id); !errors.Is(err, ErrReadOnlyFileView) {
		t.Fatalf("SaveDocument error = %v", err)
	}
	if err := app.SaveAs(id, filepath.Join(dir, "copy.txt")); !errors.Is(err, ErrReadOnlyFileView) {
		t.Fatalf("SaveAs error = %v", err)
	}
	if _, err := app.ReplaceDocument(PresentationCommand{Kind: PresentationReplaceDocument, DocumentID: id}); !errors.Is(err, ErrReadOnlyFileView) {
		t.Fatalf("ReplaceDocument error = %v", err)
	}
	if _, err := app.PasteDocument(id, app.Documents[id].Revision(), 0, 0, []byte("x"), 0, 0); !errors.Is(err, ErrReadOnlyFileView) {
		t.Fatalf("PasteDocument error = %v", err)
	}
	if err := app.UndoDocument(id); !errors.Is(err, ErrReadOnlyFileView) {
		t.Fatalf("UndoDocument error = %v", err)
	}

	sessionPath := filepath.Join(t.TempDir(), "session.json")
	if err := app.SaveSession(sessionPath); err != nil {
		t.Fatal(err)
	}
	restored := New(nil)
	if err := restored.RestoreSession(sessionPath); err != nil {
		t.Fatal(err)
	}
	if got := restored.FileViews[restored.Active]; got.Kind != FileViewImage || got.Width != 3 || got.Height != 2 {
		t.Fatalf("restored image view = %+v", got)
	}
	if err := restored.CloseDocument(restored.Active, false); err != nil {
		t.Fatal(err)
	}
	if err := restored.ReopenClosed(); err != nil {
		t.Fatal(err)
	}
	if got := restored.FileViews[restored.Active]; got.Kind != FileViewImage {
		t.Fatalf("reopened file view = %+v", got)
	}
}

func TestImagePreviewReloadsExternalChangesAndUnsupportedFilesOpenInTabs(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "changing.png")
	writePNGFixture(t, path, 2, 2)
	app := New(nil)
	if err := app.OpenDocument(path); err != nil {
		t.Fatal(err)
	}
	id := app.Active
	firstRevision := app.FileViews[id].Revision
	writePNGFixture(t, path, 4, 3)
	app.HandleWatchEvent(workspace.WatchEvent{Name: path})
	app.ReconcileStale()
	if got := app.FileViews[id]; got.Kind != FileViewImage || got.Width != 4 || got.Height != 3 || got.Revision <= firstRevision {
		t.Fatalf("reloaded external image = %+v (old revision %d)", got, firstRevision)
	}

	unsupported := filepath.Join(dir, "archive.bin")
	if err := os.WriteFile(unsupported, []byte{'P', 'K', 3, 4, 0, 1}, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := app.OpenPath(unsupported); err != nil {
		t.Fatalf("open unsupported file: %v", err)
	}
	if got := app.FileViews[app.Active]; got.Kind != FileViewUnsupported || got.Error == "" {
		t.Fatalf("unsupported view = %+v", got)
	}
}

func TestImagePreviewRenameKeepsReadOnlyIdentity(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "image.png")
	encoded := writePNGFixture(t, path, 2, 3)
	app := New(nil)
	if err := app.OpenWorkspace(root); err != nil {
		t.Fatal(err)
	}
	if err := app.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	oldID := app.Active
	if err := app.MovePath("image.png", "renamed.go"); err != nil {
		t.Fatal(err)
	}
	if app.Active == oldID || app.FileViews[app.Active].Kind != FileViewImage || app.Documents[app.Active].RootLanguage != "" {
		t.Fatalf("renamed image lost readonly metadata: id=%s views=%+v", app.Active, app.FileViews)
	}
	if _, stale := app.FileViews[oldID]; stale {
		t.Fatal("old image identity was retained after rename")
	}
	if err := app.SaveActive(); !errors.Is(err, ErrReadOnlyFileView) {
		t.Fatalf("save renamed image = %v", err)
	}
	data, err := app.ImagePreviewBytes(app.Active, app.FileViews[app.Active].Revision)
	if err != nil || !bytes.Equal(data, encoded) {
		t.Fatalf("read renamed image: %v", err)
	}
}

func TestImagePreviewMissingRecreatedAndReclassifiedInBothDirections(t *testing.T) {
	path := filepath.Join(t.TempDir(), "changing.png")
	encoded := writePNGFixture(t, path, 2, 2)
	app := New(nil)
	if err := app.OpenDocument(path); err != nil {
		t.Fatal(err)
	}
	id := app.Active
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if status, err := app.Reconcile(id); err != nil || status != StatusMissing {
		t.Fatalf("missing image: %v %v", status, err)
	}
	missingRevision := app.FileViews[id].Revision
	if app.FileViews[id].Error == "" {
		t.Fatal("missing image should have an inline error")
	}
	if err := os.WriteFile(path, encoded, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := app.Reconcile(id); err != nil {
		t.Fatal(err)
	}
	if view := app.FileViews[id]; view.Error != "" || view.Revision <= missingRevision {
		t.Fatalf("recreated image = %+v", view)
	}
	if err := os.WriteFile(path, []byte("now text"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := app.Reconcile(id); err != nil {
		t.Fatal(err)
	}
	if _, readOnly := app.FileViews[id]; readOnly {
		t.Fatal("external image-to-text replacement should become editable")
	}
	if err := os.WriteFile(path, encoded, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := app.Reconcile(id); err != nil {
		t.Fatal(err)
	}
	if app.FileViews[id].Kind != FileViewImage {
		t.Fatal("external text-to-image replacement should redispatch to the viewer")
	}
}

func TestImagePreviewRejectsInvalidHugeAndChangedImageInput(t *testing.T) {
	path := filepath.Join(t.TempDir(), "invalid.png")
	data := writePNGFixture(t, path, 2, 2)
	app := New(nil)
	if err := app.OpenDocument(path); err != nil {
		t.Fatal(err)
	}
	revision := app.FileViews[app.Active].Revision
	writePNGFixture(t, path, 3, 3)
	if _, err := app.ImagePreviewBytes(app.Active, revision); err == nil {
		t.Fatal("file replacement between snapshot and read should be rejected")
	}
	for _, invalid := range [][]byte{data[:24], append([]byte(nil), data...)} {
		if len(invalid) > 24 {
			invalid[16] = 0x7f
		}
		if err := os.WriteFile(path, invalid, 0o644); err != nil {
			t.Fatal(err)
		}
		if _, err := app.Reconcile(app.Active); err != nil {
			t.Fatal(err)
		}
		if app.FileViews[app.Active].Error == "" {
			t.Fatal("truncated or huge image should have an inline error")
		}
	}
}

func TestExternalImageReplacementDoesNotDiscardUnsavedText(t *testing.T) {
	path := filepath.Join(t.TempDir(), "changing.txt")
	if err := os.WriteFile(path, []byte("text"), 0o644); err != nil {
		t.Fatal(err)
	}
	app := New(nil)
	if err := app.OpenDocument(path); err != nil {
		t.Fatal(err)
	}
	id := app.Active
	if _, err := app.ReplaceDocument(PresentationCommand{Kind: PresentationReplaceDocument, DocumentID: id, EditorRevision: app.Documents[id].Revision(), StartByte: 0, EndByte: 4, Replacement: []byte("unsaved text")}); err != nil {
		t.Fatal(err)
	}
	encoded := writePNGFixture(t, path, 2, 2)
	app.HandleWatchEvent(workspace.WatchEvent{Name: path})
	if status, err := app.Reconcile(id); status != StatusDirty || !errors.Is(err, workspace.ErrUnsupportedTextFile) {
		t.Fatalf("dirty external replacement: %v %v", status, err)
	}
	if got := app.Documents[id].Editor.Buffer.Text(); string(got) != "unsaved text" {
		t.Fatalf("unsaved bytes changed: %q", got)
	}
	if app.Stale[id] {
		t.Fatal("one invalid-file event must not produce repeated idle reads")
	}
	if err := app.SaveActive(); !errors.Is(err, workspace.ErrUnsupportedTextFile) {
		t.Fatalf("save should fail closed: %v", err)
	}
	if got, err := os.ReadFile(path); err != nil || !bytes.Equal(got, encoded) {
		t.Fatalf("external image was overwritten: %v", err)
	}
}

type imageViewFailingStore struct {
	workspace.OSFileStore
	fail     bool
	attempts int
}

func (s *imageViewFailingStore) Load(path string) (workspace.FileSnapshot, error) {
	s.attempts++
	if s.fail {
		return workspace.FileSnapshot{}, errors.New("access denied")
	}
	return s.OSFileStore.Load(path)
}

func TestImagePreviewReloadFailureConsumesHintAndRecovers(t *testing.T) {
	path := filepath.Join(t.TempDir(), "image.png")
	writePNGFixture(t, path, 2, 2)
	store := &imageViewFailingStore{}
	app := New(store)
	if err := app.OpenDocument(path); err != nil {
		t.Fatal(err)
	}
	id := app.Active
	revision := app.FileViews[id].Revision
	store.fail = true
	before := store.attempts
	app.HandleWatchEvent(workspace.WatchEvent{Name: path})
	app.ReconcileStale()
	app.ReconcileStale()
	if store.attempts != before+1 || app.Stale[id] {
		t.Fatal("failed reload must not cause repeated idle reads")
	}
	if view := app.FileViews[id]; view.Error == "" || view.Revision <= revision {
		t.Fatalf("failed reload should publish an inline error: %+v", view)
	}
	store.fail = false
	app.HandleWatchEvent(workspace.WatchEvent{Name: path})
	app.ReconcileStale()
	if view := app.FileViews[id]; view.Error != "" || view.Kind != FileViewImage {
		t.Fatalf("next event should recover the image: %+v", view)
	}
}
