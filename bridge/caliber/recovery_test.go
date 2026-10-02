package backend

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"scratchpad/application"
)

func TestRuntimeRecoveryRestoresDirtyBytesAndSurfacesDiskConflict(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "notes.txt")
	if err := os.WriteFile(path, []byte("base\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	source := application.New(nil)
	if err := source.OpenDocument(path); err != nil {
		t.Fatal(err)
	}
	if err := source.Documents[source.Active].ReplaceText([]byte("local unsaved\n")); err != nil {
		t.Fatal(err)
	}
	recoveryDir := filepath.Join(root, "state", "recovery")
	if err := source.WriteRecovery(recoveryDir); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("external version\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	restored := application.New(nil)
	notice := restoreRuntimeRecovery(restored, recoveryDir)
	if !strings.Contains(notice, "Recovered unsaved changes in 1 document") {
		t.Fatalf("recovery notice = %q", notice)
	}
	if got := restored.Status(restored.Active); got != application.StatusConflict {
		t.Fatalf("restored status = %v, want conflict", got)
	}
	if got := string(restored.Documents[restored.Active].Editor.Buffer.Text()); got != "local unsaved\n" {
		t.Fatalf("recovered bytes = %q", got)
	}
	if _, ok := restored.Conflict(restored.Active); !ok {
		t.Fatal("recovery did not retain the changed disk version as a conflict")
	}
}

func TestRuntimeRecoveryFailurePreservesSnapshotForRetry(t *testing.T) {
	recoveryDir := filepath.Join(t.TempDir(), "recovery")
	if err := os.MkdirAll(recoveryDir, 0o700); err != nil {
		t.Fatal(err)
	}
	manifest := []byte("{not valid json")
	manifestPath := filepath.Join(recoveryDir, "manifest.json")
	if err := os.WriteFile(manifestPath, manifest, 0o600); err != nil {
		t.Fatal(err)
	}

	app := application.New(nil)
	notice := restoreRuntimeRecovery(app, recoveryDir)
	if !strings.Contains(notice, "Existing recovery files were preserved") {
		t.Fatalf("restore failure notice = %q", notice)
	}
	app.MaybeWriteRecovery(recoveryDir)
	if err := app.FlushRecovery(recoveryDir); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(manifestPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(manifest) {
		t.Fatalf("failed recovery manifest was overwritten: %q", got)
	}
}

func TestRuntimeRecoveryConflictActionsUseCurrentAuthoritativeState(t *testing.T) {
	for _, action := range []struct {
		name string
		want string
	}{
		{name: "reload_conflict", want: "external version\n"},
		{name: "keep_mine_conflict", want: "local unsaved\n"},
	} {
		t.Run(action.name, func(t *testing.T) {
			root := t.TempDir()
			path := filepath.Join(root, "notes.txt")
			if err := os.WriteFile(path, []byte("base\n"), 0o600); err != nil {
				t.Fatal(err)
			}
			source := application.New(nil)
			if err := source.OpenDocument(path); err != nil {
				t.Fatal(err)
			}
			if err := source.Documents[source.Active].ReplaceText([]byte("local unsaved\n")); err != nil {
				t.Fatal(err)
			}
			stateDir := filepath.Join(root, "state")
			recoveryDir := filepath.Join(stateDir, "recovery")
			if err := source.WriteRecovery(recoveryDir); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(path, []byte("external version\n"), 0o600); err != nil {
				t.Fatal(err)
			}

			runtime := NewRuntime()
			runtime.stateDirOverride = stateDir
			started := decodeResponse(t, runtime.Start(mustJSON(t, StartRequest{
				Version: ProtocolVersion, RequestID: 1, WorkspacePath: root,
			})))
			if !started.OK {
				t.Fatalf("start response = %+v", started)
			}
			t.Cleanup(func() {
				if runtime.lifecycle == lifecycleRunning {
					stopRuntime(t, runtime)
				}
			})

			state := latestStateForTest(t, runtime)
			if !strings.Contains(state.StartupNotice, "Recovered unsaved changes") {
				t.Fatalf("startup notice = %q", state.StartupNotice)
			}
			if len(state.Documents) != 1 || state.Documents[0].Status != "conflict" {
				t.Fatalf("recovered documents = %+v", state.Documents)
			}

			request := CommandRequest{
				Version: ProtocolVersion, RequestID: 2,
				BasedOnRevision: state.ApplicationRev,
				Command:         action.name, DocumentID: state.Documents[0].ID,
			}
			encoded, err := json.Marshal(request)
			if err != nil {
				t.Fatal(err)
			}
			dispatchForTest(t, runtime, encoded)
			response := decodeResponse(t, runtime.Pump())
			if !response.OK {
				t.Fatalf("%s response = %+v", action.name, response)
			}
			if got, err := os.ReadFile(path); err != nil {
				t.Fatal(err)
			} else if string(got) != action.want {
				t.Fatalf("disk after %s = %q, want %q", action.name, got, action.want)
			}
			state = latestStateForTest(t, runtime)
			if len(state.Documents) != 1 || state.Documents[0].Status == "conflict" || state.Documents[0].Dirty {
				t.Fatalf("document state after %s = %+v", action.name, state.Documents)
			}
			manifestPath := filepath.Join(recoveryDir, "manifest.json")
			manifestBytes, err := os.ReadFile(manifestPath)
			if err == nil {
				var manifest struct {
					Documents []json.RawMessage `json:"documents"`
				}
				if err := json.Unmarshal(manifestBytes, &manifest); err != nil {
					t.Fatal(err)
				}
				if len(manifest.Documents) != 0 {
					t.Fatalf("resolved conflict left stale recovery documents: %+v", manifest.Documents)
				}
			} else if !os.IsNotExist(err) {
				t.Fatal(err)
			}
		})
	}
}

func TestRuntimeWatcherPublishesExternalConflict(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "notes.txt")
	if err := os.WriteFile(path, []byte("base\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	runtime := newStartedRuntime(t, root)
	defer stopRuntime(t, runtime)

	state := latestStateForTest(t, runtime)
	dispatchForTest(t, runtime, mustJSON(t, CommandRequest{
		Version: ProtocolVersion, RequestID: 20, BasedOnRevision: state.ApplicationRev,
		Command: "open_path", Path: path,
	}))
	opened := decodeResponse(t, runtime.Pump())
	if !opened.OK {
		t.Fatalf("open response = %+v", opened)
	}
	state = latestStateForTest(t, runtime)
	doc := state.Documents[0]
	dispatchForTest(t, runtime, mustJSON(t, CommandRequest{
		Version: ProtocolVersion, RequestID: 21, BasedOnRevision: state.ApplicationRev,
		Command: "replace_document", DocumentID: doc.ID, EditorRevision: doc.EditorRevision,
		StartByte: 4, EndByte: 4, Replacement: []int{'!', '!', '!'},
	}))
	edited := decodeResponse(t, runtime.Pump())
	if !edited.OK {
		t.Fatalf("edit response = %+v", edited)
	}
	if err := os.WriteFile(path, []byte("external\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		state = latestStateForTest(t, runtime)
		if len(state.Documents) == 1 && state.Documents[0].Status == "conflict" {
			runtime.mu.Lock()
			if got := string(runtime.app.Documents[application.DocumentID(doc.ID)].Editor.Buffer.Text()); got != "base!!!\n" {
				runtime.mu.Unlock()
				t.Fatalf("external change replaced local dirty bytes: %q", got)
			}
			runtime.mu.Unlock()
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("workspace watcher did not publish conflict state: %+v", state.Documents)
}
