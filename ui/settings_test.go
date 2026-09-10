package ui

import (
	"os"
	"path/filepath"
	"testing"

	"scratchpad/application"
	"scratchpad/commands"
	"scratchpad/document"

	. "go.hasen.dev/shirei"
)

func TestLoadUserSettingsMissingUsesDefaults(t *testing.T) {
	settings, err := loadUserSettingsFile(filepath.Join(t.TempDir(), "settings.json"))
	if err != nil {
		t.Fatal(err)
	}
	if settings.EditorFontSize != defaultEditorFontSize || !settings.LineNumbers || len(settings.WrapOverrides) != 0 {
		t.Fatalf("missing settings = %#v, want defaults", settings)
	}
}

func TestLoadUserSettingsMalformedUsesDefaults(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	if err := os.WriteFile(path, []byte("{malformed"), 0o600); err != nil {
		t.Fatal(err)
	}
	settings, err := loadUserSettingsFile(path)
	if err == nil {
		t.Fatal("malformed settings did not return an error")
	}
	if settings.EditorFontSize != defaultEditorFontSize || !settings.LineNumbers {
		t.Fatalf("malformed settings = %#v, want defaults", settings)
	}
}

func TestUserSettingsPersistAndReload(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nested", "settings.json")
	shell := &workbenchState{
		EditorFontSize:     24,
		LineNumbers:        false,
		LineNumbersSet:     true,
		WrapOverrides:      map[application.DocumentID]bool{"/tmp/notes.md": false},
		UserSettingsPath:   path,
		UserSettingsLoaded: true,
	}
	if err := saveUserSettingsFile(path, shell); err != nil {
		t.Fatal(err)
	}
	settings, err := loadUserSettingsFile(path)
	if err != nil {
		t.Fatal(err)
	}
	wrap, exists := settings.WrapOverrides["/tmp/notes.md"]
	if settings.EditorFontSize != 24 || settings.LineNumbers || !exists || wrap {
		t.Fatalf("reloaded settings = %#v, want persisted values", settings)
	}
}

func TestPrimaryCommaOpensSettingsWithoutDocument(t *testing.T) {
	state := application.New(nil)
	shell := &workbenchState{UserSettingsLoaded: true}
	ResetInputSession()
	GetInputState().Modifiers = PrimaryMod()
	GetFrameInput().Key = KeyCode(',')
	handleGlobalInput(state, shell)
	if !shell.ShowSettings {
		t.Fatal("primary-comma did not open settings")
	}
	if GetFrameInput().Key != KeyCodeNone {
		t.Fatal("primary-comma was not consumed")
	}
	GetFrameInput().Key = KeyEscape
	handleGlobalInput(state, shell)
	if shell.ShowSettings {
		t.Fatal("escape did not close settings")
	}
	if GetFrameInput().Key != KeyCodeNone {
		t.Fatal("escape was not consumed")
	}
}

func TestSettingsSurfaceRendersInEditorRegion(t *testing.T) {
	state := application.New(nil)
	ResetInputSession()
	GetHost().HeadlessRender = true
	var open bool
	RunFrameFn(func() {
		shell := Use[workbenchState]("workbench")
		shell.UserSettingsLoaded = true
		shell.ShowSettings = true
		RootView(state)
		open = shell.ShowSettings
		shell.ShowSettings = false
	})
	if !open {
		t.Fatal("settings surface closed during render")
	}
}

func TestSettingsChangesApplyImmediatelyAndPersist(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	state := application.New(nil)
	doc := document.New("notes.md", []byte("one\ntwo"), "markdown")
	state.Documents["notes"] = doc
	state.Order = []application.DocumentID{"notes"}
	state.Active = "notes"
	shell := &workbenchState{EditorFontSize: 16, LineNumbers: true, LineNumbersSet: true, UserSettingsLoaded: true, UserSettingsPath: path}
	if !executeCommand(state, shell, commands.ViewIncreaseFontSize) {
		t.Fatal("font size command was not handled")
	}
	if shell.EditorFontSize != 17 {
		t.Fatalf("font size = %v, want 17", shell.EditorFontSize)
	}
	if !executeCommand(state, shell, viewToggleLineNumbers) || shell.LineNumbers {
		t.Fatal("line number toggle was not applied immediately")
	}
	if !executeCommand(state, shell, viewToggleWrap) || wrapEnabled(shell, doc) {
		t.Fatal("wrap toggle was not applied immediately")
	}
	settings, err := loadUserSettingsFile(path)
	if err != nil {
		t.Fatal(err)
	}
	wrap, exists := settings.WrapOverrides[stateDocumentID(doc)]
	if settings.EditorFontSize != 17 || settings.LineNumbers || !exists || wrap {
		t.Fatalf("persisted immediate changes = %#v", settings)
	}
}
