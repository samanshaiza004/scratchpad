package main

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"scratchpad/application"
	"scratchpad/editor"
)

const (
	sessionSmokeSidebarWidth = 328
	sessionSmokePinnedWidth  = 416
)

type sessionSmokeFixture struct {
	workspace  string
	firstPath  string
	secondPath string
	firstID    application.DocumentID
	secondID   application.DocumentID
	stateDir   string
	recovered  []byte
}

// runNativeSessionRestartSmoke exercises the actual native frontend/backend
// startup and stop paths in separate processes, while isolating all user state.
func runNativeSessionRestartSmoke(root, exe string, baseEnv []string) error {
	smokeRoot, err := os.MkdirTemp("", "scratchpad-session-smoke-")
	if err != nil {
		return fmt.Errorf("create isolated native session smoke directory: %w", err)
	}
	defer os.RemoveAll(smokeRoot)

	profile := filepath.Join(smokeRoot, "profile")
	launchEnv := isolatedProfileEnv(baseEnv, profile)
	fixture, err := createSessionSmokeFixture(smokeRoot, profile)
	if err != nil {
		return err
	}
	launchEnv = unsetEnv(launchEnv, "SCRATCHPAD_ALICORN_WORKSPACE")
	launchEnv = unsetEnv(launchEnv, "SCRATCHPAD_ALICORN_SMOKE_SESSION_MODE")
	launchEnv = unsetEnv(launchEnv, "SCRATCHPAD_DISABLE_SESSION")
	launchEnv = unsetEnv(launchEnv, "SCRATCHPAD_DISABLE_RECOVERY")
	launchEnv = unsetEnv(launchEnv, "SCRATCHPAD_APPEARANCE_FIXTURE")
	launchEnv = unsetEnv(launchEnv, "SCRATCHPAD_PINNED_FIXTURE")
	launchEnv = setEnv(launchEnv, "SCRATCHPAD_ALICORN_SMOKE", "1")
	launchEnv = setEnv(launchEnv, "SCRATCHPAD_ALICORN_SMOKE_EXPECT_WORKSPACE", fixture.workspace)
	launchEnv = setEnv(launchEnv, "SCRATCHPAD_ALICORN_SMOKE_EXPECT_FIRST", string(fixture.secondID))
	launchEnv = setEnv(launchEnv, "SCRATCHPAD_ALICORN_SMOKE_EXPECT_SECOND", string(fixture.firstID))
	launchEnv = setEnv(launchEnv, "SCRATCHPAD_ALICORN_SMOKE_EXPECT_PREVIEW", string(fixture.firstID))

	cleanEnv := setEnv(launchEnv, "SCRATCHPAD_ALICORN_SMOKE_SESSION_MODE", "clean")
	cleanEnv = setEnv(cleanEnv, "SCRATCHPAD_ALICORN_SMOKE_EXPECT_ACTIVE", string(fixture.secondID))
	fmt.Println("native session smoke: clean two-document quit/relaunch")
	if err := runCommandWithTimeout(root, cleanEnv, 20*time.Second, exe); err != nil {
		return fmt.Errorf("clean-session native relaunch: %w", err)
	}
	if err := verifyCleanSessionAfterNativeLaunch(fixture); err != nil {
		return err
	}

	recovered, err := createSessionSmokeRecovery(fixture)
	if err != nil {
		return err
	}
	fixture.recovered = recovered
	recoveryEnv := setEnv(launchEnv, "SCRATCHPAD_ALICORN_SMOKE_SESSION_MODE", "recovery")
	recoveryEnv = setEnv(recoveryEnv, "SCRATCHPAD_ALICORN_SMOKE_EXPECT_ACTIVE", string(fixture.secondID))
	fmt.Println("native session smoke: unsaved recovery restart")
	if err := runCommandWithTimeout(root, recoveryEnv, 20*time.Second, exe); err != nil {
		return fmt.Errorf("recovery native relaunch: %w", err)
	}
	if err := verifyRecoveredSessionAfterNativeLaunch(fixture); err != nil {
		return err
	}
	return nil
}

func createSessionSmokeFixture(smokeRoot, profile string) (sessionSmokeFixture, error) {
	fixture := sessionSmokeFixture{
		workspace:  filepath.Join(smokeRoot, "workspace"),
		firstPath:  filepath.Join(smokeRoot, "workspace", "first.txt"),
		secondPath: filepath.Join(smokeRoot, "workspace", "second.txt"),
	}
	if err := os.MkdirAll(fixture.workspace, 0o755); err != nil {
		return fixture, fmt.Errorf("create session smoke workspace: %w", err)
	}
	first := []byte("first document\nsecond line\nthird line\n")
	var second strings.Builder
	for line := 1; line <= 96; line++ {
		fmt.Fprintf(&second, "second document line %02d\n", line)
	}
	if err := os.WriteFile(fixture.firstPath, first, 0o644); err != nil {
		return fixture, fmt.Errorf("write first session smoke document: %w", err)
	}
	if err := os.WriteFile(fixture.secondPath, []byte(second.String()), 0o644); err != nil {
		return fixture, fmt.Errorf("write second session smoke document: %w", err)
	}

	app := application.New(nil)
	defer app.CloseDerived()
	if err := app.OpenWorkspace(fixture.workspace); err != nil {
		return fixture, fmt.Errorf("open session smoke workspace: %w", err)
	}
	if err := app.OpenDocument(fixture.firstPath); err != nil {
		return fixture, fmt.Errorf("open first session smoke document: %w", err)
	}
	fixture.firstID = app.Active
	if err := app.OpenDocument(fixture.secondPath); err != nil {
		return fixture, fmt.Errorf("open second session smoke document: %w", err)
	}
	fixture.secondID = app.Active
	if err := app.Reorder([]application.DocumentID{fixture.secondID, fixture.firstID}); err != nil {
		return fixture, fmt.Errorf("reorder session smoke documents: %w", err)
	}
	app.Active = fixture.secondID
	app.Preview = fixture.firstID
	app.SidebarWidth = sessionSmokeSidebarWidth
	app.PinnedPaneWidth = sessionSmokePinnedWidth
	app.SessionUI = application.SessionUI{Focus: "editor"}
	app.SetRecentWorkspaces([]string{fixture.workspace})

	firstDoc := app.Documents[fixture.firstID]
	firstDoc.Editor.SetSelection(1, 8)
	firstDoc.Editor.Affinity = editor.AffinityTrailing
	app.Views[fixture.firstID] = application.ViewState{
		ScrollX: 12, ScrollXInitialized: true,
		ScrollY: 36, ScrollInitialized: true,
	}
	secondDoc := app.Documents[fixture.secondID]
	secondDoc.Editor.SetSelection(6, 11)
	app.Views[fixture.secondID] = application.ViewState{
		ScrollX: 8, ScrollXInitialized: true,
		ScrollY: 240, ScrollInitialized: true,
	}

	fixture.stateDir = profileStateDir(profile)
	if err := app.SaveSession(filepath.Join(fixture.stateDir, "session.json")); err != nil {
		return fixture, fmt.Errorf("write seeded session smoke state: %w", err)
	}
	return fixture, nil
}

func createSessionSmokeRecovery(fixture sessionSmokeFixture) ([]byte, error) {
	app := application.New(nil)
	defer app.CloseDerived()
	if err := app.OpenDocument(fixture.secondPath); err != nil {
		return nil, fmt.Errorf("open recovery smoke document: %w", err)
	}
	doc := app.Documents[fixture.secondID]
	if doc == nil || doc.Editor == nil {
		return nil, errors.New("recovery smoke document has no editor")
	}
	doc.Editor.SetCursor(len(doc.Editor.Buffer.Text()))
	if err := doc.Editor.Insert([]byte("unsaved recovery marker\n")); err != nil {
		return nil, fmt.Errorf("edit recovery smoke document: %w", err)
	}
	doc.Editor.SetAffinity(editor.AffinityTrailing)
	recovered := append([]byte(nil), doc.Editor.Buffer.Text()...)
	if err := app.WriteRecovery(filepath.Join(fixture.stateDir, "recovery")); err != nil {
		return nil, fmt.Errorf("write recovery smoke snapshot: %w", err)
	}
	return recovered, nil
}

func verifyCleanSessionAfterNativeLaunch(fixture sessionSmokeFixture) error {
	session, err := application.LoadSession(filepath.Join(fixture.stateDir, "session.json"))
	if err != nil {
		return fmt.Errorf("read session after clean native quit: %w", err)
	}
	if session.Workspace != fixture.workspace || session.Active != fixture.secondID || len(session.Documents) != 2 ||
		session.Documents[0].ID != fixture.secondID || session.Documents[1].ID != fixture.firstID ||
		!session.Documents[1].Preview || session.SidebarWidth != sessionSmokeSidebarWidth ||
		session.PinnedPaneWidth != sessionSmokePinnedWidth {
		return fmt.Errorf("clean native quit did not retain workspace, active/order/preview tabs, and split widths: %+v", session)
	}
	return nil
}

func verifyRecoveredSessionAfterNativeLaunch(fixture sessionSmokeFixture) error {
	app := application.New(nil)
	defer app.CloseDerived()
	if err := app.RestoreSession(filepath.Join(fixture.stateDir, "session.json")); err != nil {
		return fmt.Errorf("reload session after recovery native quit: %w", err)
	}
	if err := app.RestoreRecovery(filepath.Join(fixture.stateDir, "recovery")); err != nil {
		return fmt.Errorf("reload recovery after recovery native quit: %w", err)
	}
	doc := app.Documents[fixture.secondID]
	if doc == nil || !doc.Dirty() || !bytes.Equal(doc.Editor.Buffer.Text(), fixture.recovered) {
		return errors.New("native recovery restart did not preserve the exact unsaved document bytes")
	}
	if app.Active != fixture.secondID {
		return fmt.Errorf("recovery restart active document = %q, want %q", app.Active, fixture.secondID)
	}
	return nil
}

func isolatedProfileEnv(base []string, profile string) []string {
	env := base
	if runtime.GOOS == "windows" {
		appData := filepath.Join(profile, "Roaming")
		localAppData := filepath.Join(profile, "Local")
		_ = os.MkdirAll(appData, 0o755)
		_ = os.MkdirAll(localAppData, 0o755)
		env = setEnv(env, "APPDATA", appData)
		env = setEnv(env, "LOCALAPPDATA", localAppData)
		env = setEnv(env, "USERPROFILE", profile)
	} else {
		_ = os.MkdirAll(profile, 0o755)
		env = setEnv(env, "HOME", profile)
		if runtime.GOOS == "linux" {
			xdg := filepath.Join(profile, ".config")
			_ = os.MkdirAll(xdg, 0o755)
			env = setEnv(env, "XDG_CONFIG_HOME", xdg)
		}
	}
	return env
}

func profileStateDir(profile string) string {
	switch runtime.GOOS {
	case "windows":
		return filepath.Join(profile, "Roaming", "scratchpad")
	case "darwin":
		return filepath.Join(profile, "Library", "Application Support", "scratchpad")
	default:
		return filepath.Join(profile, ".config", "scratchpad")
	}
}
