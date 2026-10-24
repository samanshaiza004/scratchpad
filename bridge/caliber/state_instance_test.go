package backend

import (
	"bytes"
	"encoding/json"
	"path/filepath"
	"testing"

	"scratchpad/application"
)

func TestStateDocumentInstanceIDWireField(t *testing.T) {
	for _, instanceID := range []uint64{0, 1, ^uint64(0)} {
		encoded, err := json.Marshal(StateDocument{ID: "doc", InstanceID: instanceID})
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Contains(encoded, []byte(`"instance_id":`)) {
			t.Fatalf("state omitted additive instance_id field: %s", encoded)
		}
		var decoded StateDocument
		if err := json.Unmarshal(encoded, &decoded); err != nil {
			t.Fatal(err)
		}
		if decoded.InstanceID != instanceID {
			t.Fatalf("instance_id lost uint64 precision: got %d, want %d", decoded.InstanceID, instanceID)
		}
	}
}

func TestStateConversionCarriesInstanceIDWithoutPresentationOptIn(t *testing.T) {
	const instanceID uint64 = 42
	snapshot := application.PresentationState{Documents: []application.PresentationDocument{{ID: "doc", InstanceID: instanceID}}}
	for _, includePresentation := range []bool{false, true} {
		state := stateFromApplication(1, snapshot, includePresentation)
		if len(state.Documents) != 1 || state.Documents[0].InstanceID != instanceID {
			t.Fatalf("state conversion lost instance identity with presentation=%v: %+v", includePresentation, state.Documents)
		}
	}
}

func TestPublishedStateInstanceChangesForTextBinaryTextAtRevisionZero(t *testing.T) {
	path := filepath.Join(t.TempDir(), "same-path.txt")
	const originalText = "Opening.\nDetail one.\n"
	// Identical byte length and line count, but the opening sentence now spans
	// both lines. Applying the old fold would hide part of that sentence.
	const replacementText = "Changed \nDetail two.\n"
	writeFile(t, path, originalText)

	// Use real Caliber publication with no filesystem watcher. Reconciliation
	// is advanced explicitly, so all three instances are observed in order.
	caliber, err := loadCaliber()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(caliber.close)
	app := application.New(nil)
	t.Cleanup(app.CloseDerived)
	if err := app.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	runtime := &Runtime{app: app, caliber: caliber, lifecycle: lifecycleRunning}
	id := app.Active
	publish := func(wantKind application.FileViewKind) StateEnvelope {
		t.Helper()
		if err := runtime.publishApplicationState(); err != nil {
			t.Fatal(err)
		}
		state := latestStateForTest(t, runtime)
		if len(state.Documents) != 1 {
			t.Fatalf("published document count = %d", len(state.Documents))
		}
		doc := state.Documents[0]
		if doc.ID != string(id) || doc.EditorRevision != 0 || doc.InstanceID == 0 || doc.InstanceID != app.Documents[id].InstanceID() || doc.ViewKind != string(wantKind) {
			t.Fatalf("published document identity/kind = %+v, want %s at revision zero", doc, wantKind)
		}
		return state
	}
	reconcile := func() {
		t.Helper()
		if _, err := app.Reconcile(id); err != nil {
			t.Fatal(err)
		}
	}
	original := publish(application.FileViewText)
	oldPlan := semanticZoomBridgeRead(t, runtime, string(id), 0, application.SemanticZoomSkim, 0).SemanticZoom
	if oldPlan == nil || oldPlan.InstanceID != original.Documents[0].InstanceID || len(oldPlan.Folds) != 1 {
		t.Fatalf("original folding plan = %+v", oldPlan)
	}
	unchanged := publish(application.FileViewText)
	if unchanged.Documents[0].InstanceID != original.Documents[0].InstanceID || !samePublishedDocuments(original, unchanged) || !samePresentationReadiness(original, unchanged) {
		t.Fatal("republishing unchanged source changed its instance identity")
	}

	writeFile(t, path, "binary\x00replacement\x01")
	reconcile()
	binary := publish(application.FileViewUnsupported)
	if binary.Documents[0].InstanceID == original.Documents[0].InstanceID {
		t.Fatal("text-to-binary replacement reused the original state instance_id")
	}

	writeFile(t, path, replacementText)
	reconcile()
	replacement := publish(application.FileViewText)
	current := replacement.Documents[0]
	if current.InstanceID == original.Documents[0].InstanceID || current.InstanceID == binary.Documents[0].InstanceID {
		t.Fatal("binary-to-text replacement reused a previous state instance_id")
	}
	if current.ByteLength != original.Documents[0].ByteLength || current.LineCount != original.Documents[0].LineCount || string(app.Documents[id].Editor.Buffer.Text()) != replacementText {
		t.Fatalf("regression requires different text at identical revision/size/lines: %+v -> %+v", original.Documents[0], current)
	}
	if samePublishedDocuments(original, replacement) || samePresentationReadiness(original, replacement) {
		t.Fatal("publication/readiness comparison missed replacement at the same path and revision")
	}
	identityOnly := replacement
	identityOnly.Documents = append([]StateDocument(nil), replacement.Documents...)
	identityOnly.Documents[0].InstanceID = original.Documents[0].InstanceID
	if !samePublishedDocuments(original, identityOnly) || !samePresentationReadiness(original, identityOnly) {
		t.Fatal("regression requires instance_id to be the distinguishing state document field")
	}
	newPlan := semanticZoomBridgeRead(t, runtime, string(id), 0, application.SemanticZoomSkim, 0).SemanticZoom
	if newPlan == nil || newPlan.InstanceID != current.InstanceID || newPlan.InstanceID == oldPlan.InstanceID || len(newPlan.Folds) != 0 {
		t.Fatalf("replacement folding plan = %+v; previous = %+v", newPlan, oldPlan)
	}
}
