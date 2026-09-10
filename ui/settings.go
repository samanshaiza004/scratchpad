package ui

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"scratchpad/application"
	"scratchpad/document"
	"scratchpad/workspace"

	. "go.hasen.dev/shirei"
	. "go.hasen.dev/shirei/widgets"
)

// persistedUserSettings is deliberately separate from workbenchState. The
// latter contains transient widget state; this small file is the user-owned
// preference surface and never carries document contents or document edits.
type persistedUserSettings struct {
	EditorFontSize float32         `json:"editor_font_size,omitempty"`
	LineNumbers    *bool           `json:"line_numbers,omitempty"`
	WrapOverrides  map[string]bool `json:"wrap_overrides,omitempty"`
}

type userSettings struct {
	EditorFontSize float32
	LineNumbers    bool
	WrapOverrides  map[application.DocumentID]bool
}

func userSettingsPath() (string, error) {
	root, err := application.DefaultStateDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(root, "settings.json"), nil
}

func loadUserSettingsFile(path string) (userSettings, error) {
	settings := userSettings{EditorFontSize: defaultEditorFontSize, LineNumbers: true}
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return settings, nil
		}
		return settings, err
	}
	var persisted persistedUserSettings
	if err := json.Unmarshal(data, &persisted); err != nil {
		return settings, err
	}
	if persisted.EditorFontSize > 0 {
		settings.EditorFontSize = clampEditorFontSize(persisted.EditorFontSize)
	}
	if persisted.LineNumbers != nil {
		settings.LineNumbers = *persisted.LineNumbers
	}
	if len(persisted.WrapOverrides) > 0 {
		settings.WrapOverrides = make(map[application.DocumentID]bool, len(persisted.WrapOverrides))
		for path, enabled := range persisted.WrapOverrides {
			if path != "" {
				settings.WrapOverrides[application.DocumentID(path)] = enabled
			}
		}
	}
	return settings, nil
}

func saveUserSettingsFile(path string, shell *workbenchState) error {
	if shell == nil || path == "" {
		return nil
	}
	persisted := persistedUserSettings{
		EditorFontSize: editorFontSize(shell),
		LineNumbers:    boolPtr(lineNumbersEnabled(shell)),
	}
	if len(shell.WrapOverrides) > 0 {
		persisted.WrapOverrides = make(map[string]bool, len(shell.WrapOverrides))
		for path, enabled := range shell.WrapOverrides {
			if path != "" {
				persisted.WrapOverrides[string(path)] = enabled
			}
		}
	}
	data, err := json.MarshalIndent(persisted, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	return workspace.AtomicWriteFile(path, append(data, '\n'), 0o600)
}

func boolPtr(value bool) *bool { return &value }

func loadUserSettings(shell *workbenchState) {
	if shell == nil || shell.UserSettingsLoaded {
		return
	}
	shell.UserSettingsLoaded = true
	path, err := userSettingsPath()
	if err != nil {
		applyDefaultUserSettings(shell)
		shell.UserSettingsError = err.Error()
		return
	}
	shell.UserSettingsPath = path
	settings, err := loadUserSettingsFile(path)
	if err != nil {
		// A malformed preference file must never prevent the editor from
		// starting. Keep defaults and replace it only after a user change.
		applyDefaultUserSettings(shell)
		shell.UserSettingsError = err.Error()
		return
	}
	shell.EditorFontSize = settings.EditorFontSize
	shell.LineNumbers = settings.LineNumbers
	shell.LineNumbersSet = true
	shell.WrapOverrides = settings.WrapOverrides
}

func applyDefaultUserSettings(shell *workbenchState) {
	if shell == nil {
		return
	}
	shell.EditorFontSize = defaultEditorFontSize
	shell.LineNumbers = true
	shell.LineNumbersSet = true
	shell.WrapOverrides = nil
}

func persistUserSettings(shell *workbenchState) {
	if shell == nil || shell.UserSettingsPath == "" {
		return
	}
	if err := saveUserSettingsFile(shell.UserSettingsPath, shell); err != nil {
		shell.UserSettingsError = err.Error()
		return
	}
	shell.UserSettingsError = ""
}

type settingsWrapChoice uint8

const (
	settingsWrapDefault settingsWrapChoice = iota
	settingsWrapOn
	settingsWrapOff
)

func settingsWrapChoiceFor(shell *workbenchState, doc *document.Document) settingsWrapChoice {
	if doc == nil || shell == nil {
		return settingsWrapDefault
	}
	if enabled, ok := shell.WrapOverrides[stateDocumentID(doc)]; ok {
		if enabled {
			return settingsWrapOn
		}
		return settingsWrapOff
	}
	return settingsWrapDefault
}

func setSettingsWrapChoice(shell *workbenchState, doc *document.Document, choice settingsWrapChoice) {
	if shell == nil || doc == nil {
		return
	}
	if choice == settingsWrapDefault {
		delete(shell.WrapOverrides, stateDocumentID(doc))
		if len(shell.WrapOverrides) == 0 {
			shell.WrapOverrides = nil
		}
	} else {
		if shell.WrapOverrides == nil {
			shell.WrapOverrides = make(map[application.DocumentID]bool)
		}
		shell.WrapOverrides[stateDocumentID(doc)] = choice == settingsWrapOn
	}
	persistUserSettings(shell)
}

func settingsSurface(state *application.Application, shell *workbenchState, theme Theme) {
	Container(Attrs(Viewport, Grow(1), Expand, Clip, BackgroundVec(theme.Paper), Pad(24)), func() {
		Container(Attrs(Row, Grow(1), Expand, Gap(24)), func() {
			Container(Attrs(FixWidth(140), Expand, Gap(4)), func() {
				Label("Categories", FontWeight(WeightBold), FontSize(11), TextColorVec(theme.Muted))
				Container(Attrs(Row, Expand, FixHeight(28), Pad2(0, 8), BackgroundVec(theme.Selection)), func() {
					Label("Editor", FontWeight(WeightBold), FontSize(11), TextColorVec(theme.Ink))
				})
				Label("Files", FontSize(11), TextColorVec(theme.Muted))
				Label("Workspace", FontSize(11), TextColorVec(theme.Muted))
			})
			Container(Attrs(Grow(1), Expand), func() {
				Label("Settings", FontWeight(WeightBold), FontSize(18), TextColorVec(theme.Ink))
				Label("Changes apply immediately and are saved for your next session.", FontSize(11), TextColorVec(theme.Muted))
				if shell.UserSettingsError != "" {
					Label("Preferences warning: "+shell.UserSettingsError, FontSize(10), TextColorVec(theme.Warning))
				}
				EtchedDivider(theme, dividerHorizontal)
				Label("Editor", FontWeight(WeightBold), FontSize(12), TextColorVec(theme.Ink))
				settingsRow(theme, "Editor font size", fmt.Sprintf("%g px", editorFontSize(shell)), func() {
					if WorkstationToolButton(theme, "−", true) {
						setEditorFontSize(state, shell, adjustEditorFontSize(editorFontSize(shell), -1))
					}
					if WorkstationToolButton(theme, "+", true) {
						setEditorFontSize(state, shell, adjustEditorFontSize(editorFontSize(shell), 1))
					}
					if WorkstationToolButton(theme, "Reset", true) {
						setEditorFontSize(state, shell, defaultEditorFontSize)
					}
				})
				settingsRow(theme, "Line numbers", "", func() {
					lineNumbersEnabled(shell)
					if WorkstationSegmentedControl(theme, &shell.LineNumbers,
						Cell("On", true), Cell("Off", false)) {
						persistUserSettings(shell)
					}
				})
				doc := state.ActiveDocument()
				if doc == nil {
					Label("Word wrap overrides are available when a document is open.", FontSize(11), TextColorVec(theme.Muted))
					return
				}
				settingsRow(theme, "Word wrap for current document", "", func() {
					choice := settingsWrapChoiceFor(shell, doc)
					if WorkstationSegmentedControl(theme, &choice,
						Cell("Default", settingsWrapDefault), Cell("On", settingsWrapOn), Cell("Off", settingsWrapOff)) {
						setSettingsWrapChoice(shell, doc, choice)
					}
				})
			})
		})
	})
}

func settingsRow(theme Theme, title, value string, controls func()) {
	Container(Attrs(Row, CrossMid, Expand, FixHeight(42), Gap(10)), func() {
		Container(Attrs(Grow(1)), func() {
			Label(title, FontSize(11), TextColorVec(theme.Ink))
			if value != "" {
				Label(value, FontSize(10), TextColorVec(theme.Muted))
			}
		})
		Container(Attrs(Row, CrossMid, Gap(4)), controls)
	})
}
