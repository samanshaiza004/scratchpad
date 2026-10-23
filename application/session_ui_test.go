package application

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestStaleSessionUIFallsBackWithoutDiscardingOtherSessionValues(t *testing.T) {
	for _, ui := range []SessionUI{
		{Focus: "retired-panel", TreePath: "notes.txt"},
		{Focus: "tree", TreeScrollY: -10},
		{Focus: "tree", TreePath: strings.Repeat("x", 32*1024+1)},
	} {
		path := filepath.Join(t.TempDir(), "session.json")
		data, err := json.Marshal(Session{Version: 1, SidebarWidth: 344, UI: ui})
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, data, 0o600); err != nil {
			t.Fatal(err)
		}
		app := &Application{}
		if err := app.RestoreSession(path); err != nil {
			t.Fatal(err)
		}
		if app.SessionUI != (SessionUI{}) || app.SidebarWidth != 344 {
			t.Fatalf("stale UI must fall back independently: ui=%+v sidebar=%v", app.SessionUI, app.SidebarWidth)
		}
	}
}
