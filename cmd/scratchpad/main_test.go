package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"scratchpad/application"
)

func TestRestoreStartupFallsBackToSessionWhenRecoveryFails(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "note.txt")
	if err := os.WriteFile(path, []byte("disk"), 0o644); err != nil {
		t.Fatal(err)
	}
	sessionPath := filepath.Join(dir, "session.json")
	source := application.New(nil)
	if err := source.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	if err := source.SaveSession(sessionPath); err != nil {
		t.Fatal(err)
	}

	recoveryDir := filepath.Join(dir, "recovery")
	if err := os.MkdirAll(recoveryDir, 0o700); err != nil {
		t.Fatal(err)
	}
	manifest, err := json.Marshal(map[string]any{
		"documents": []map[string]string{{
			"id": "missing", "path": path, "bytes_file": "missing.bytes",
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(recoveryDir, "manifest.json"), manifest, 0o600); err != nil {
		t.Fatal(err)
	}

	state := application.New(nil)
	t.Cleanup(func() {
		if err := state.FlushRecovery(recoveryDir); err != nil {
			t.Errorf("recovery cleanup flush failed: %v", err)
		}
	})
	restoreStartup(state, recoveryDir, sessionPath, "")
	if state.Active == "" {
		t.Fatal("startup did not fall back to the saved session")
	}
	if got := string(state.ActiveDocument().Editor.Buffer.Text()); got != "disk" {
		t.Fatalf("startup restored %q, want session bytes", got)
	}
	failedDirs, err := filepath.Glob(filepath.Join(dir, "recovery.failed.*"))
	if err != nil || len(failedDirs) != 1 {
		t.Fatalf("quarantined recovery dirs = %v (err=%v), want one", failedDirs, err)
	}
	if _, err := os.Stat(filepath.Join(failedDirs[0], "manifest.json")); err != nil {
		t.Fatalf("failed recovery manifest was not preserved: %v", err)
	}

	doc := state.ActiveDocument()
	doc.Editor.SetCursor(doc.Editor.Buffer.ByteLen())
	if err := doc.Insert([]byte("-new-edit")); err != nil {
		t.Fatal(err)
	}
	state.MaybeWriteRecovery(recoveryDir)
	if err := state.FlushRecovery(recoveryDir); err != nil {
		t.Fatalf("fresh recovery flush failed: %v", err)
	}
	if _, err := os.Stat(filepath.Join(recoveryDir, "manifest.json")); err != nil {
		t.Fatalf("fresh recovery was not written after quarantine: %v", err)
	}
}

func TestRestoreStartupRecoversBeforeOpeningExplicitPath(t *testing.T) {
	dir := t.TempDir()
	recoveredPath := filepath.Join(dir, "recovered.txt")
	explicitPath := filepath.Join(dir, "requested.txt")
	if err := os.WriteFile(recoveredPath, []byte("base"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(explicitPath, []byte("requested"), 0o644); err != nil {
		t.Fatal(err)
	}
	recoveryDir := filepath.Join(dir, "recovery")
	source := application.New(nil)
	if err := source.OpenPath(recoveredPath); err != nil {
		t.Fatal(err)
	}
	doc := source.ActiveDocument()
	doc.Editor.SetCursor(doc.Editor.Buffer.ByteLen())
	if err := doc.Insert([]byte("-local")); err != nil {
		t.Fatal(err)
	}
	if err := source.WriteRecovery(recoveryDir); err != nil {
		t.Fatal(err)
	}

	state := application.New(nil)
	t.Cleanup(func() {
		if err := state.FlushRecovery(recoveryDir); err != nil {
			t.Errorf("recovery cleanup flush failed: %v", err)
		}
	})
	restoreStartup(state, recoveryDir, filepath.Join(dir, "missing-session.json"), explicitPath)
	if state.ActiveDocument() == nil || state.ActiveDocument().Path != explicitPath {
		t.Fatalf("active document = %#v, want explicit path %q", state.ActiveDocument(), explicitPath)
	}
	foundRecovery := false
	for _, candidate := range state.Documents {
		if candidate.Path == recoveredPath {
			foundRecovery = true
			if got := string(candidate.Editor.Buffer.Text()); got != "base-local" {
				t.Fatalf("recovered text = %q, want base-local", got)
			}
			if !candidate.Dirty() {
				t.Fatal("recovered document became clean")
			}
		}
	}
	if !foundRecovery {
		t.Fatalf("recovered document missing from registry: %#v", state.Documents)
	}
	state.MaybeWriteRecovery(recoveryDir)
	if _, err := os.Stat(filepath.Join(recoveryDir, "manifest.json")); err != nil {
		t.Fatalf("recovery was cleared after opening explicit path: %v", err)
	}
}
