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
	restoreStartup(state, recoveryDir, sessionPath)
	if state.Active == "" {
		t.Fatal("startup did not fall back to the saved session")
	}
	if got := string(state.ActiveDocument().Editor.Buffer.Text()); got != "disk" {
		t.Fatalf("startup restored %q, want session bytes", got)
	}
}
