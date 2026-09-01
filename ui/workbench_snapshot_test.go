package ui

import (
	"os"
	"path/filepath"
	"testing"

	"scratchpad/application"
	"scratchpad/language/markdown"

	. "go.hasen.dev/shirei"
)

func requireVisualSnapshots(t *testing.T) {
	t.Helper()
	if os.Getenv("SCRATCHPAD_VISUAL_SNAPSHOTS") == "" {
		t.Skip("set SCRATCHPAD_VISUAL_SNAPSHOTS=1 to run host-font visual snapshots")
	}
}

func checkWorkbenchSnapshot(t *testing.T, name string, width, height int, frame FrameFn) {
	t.Helper()
	requireVisualSnapshots(t)
	result := Snapshot(t.Name(), name, width, height, frame)
	switch {
	case result.Status == SnapSkip:
		t.Skip(result.Reason)
	case result.Err != nil:
		t.Fatal(result.Err)
	case result.Status == SnapMismatch:
		t.Fatalf("snapshot mismatch: %s (actual %s)", result.Golden, result.Actual)
	case result.Status == SnapCreated:
		t.Logf("created snapshot %s", result.Golden)
	}
}

func workstationFixtureRoot(t *testing.T) string {
	t.Helper()
	root, err := filepath.Abs(filepath.Join("testdata", "workstation"))
	if err != nil {
		t.Fatal(err)
	}
	return root
}

func workstationState(t *testing.T, paths ...string) *application.Application {
	t.Helper()
	root := workstationFixtureRoot(t)
	state := application.New(nil)
	if err := state.OpenWorkspace(root); err != nil {
		t.Fatal(err)
	}
	for _, relative := range paths {
		if err := state.OpenPath(filepath.Join(root, relative)); err != nil {
			t.Fatal(err)
		}
	}
	for _, doc := range state.Documents {
		if doc.RootLanguage != "markdown" {
			continue
		}
		data := doc.Snapshot().Materialize()
		doc.SetDerived(nil, markdown.Project(data, doc.Revision()))
	}
	return state
}

func workstationFrame(state *application.Application, configure func(*workbenchState)) FrameFn {
	return func() {
		shell := Use[workbenchState]("workbench")
		if configure != nil {
			configure(shell)
		}
		RootView(state)
	}
}

func filesSidebar(shell *workbenchState) {
	shell.SidebarVisible = true
	shell.SidebarInitialized = true
	shell.SidebarMode = SidebarFiles
	shell.Tree.Expanded = map[string]bool{"notes": true, "src": true}
}

func TestSnapshotWorkstationEmpty(t *testing.T) {
	checkWorkbenchSnapshot(t, "workstation_empty", 960, 640, workstationFrame(application.New(nil), nil))
}

func TestSnapshotWorkstationSingleFile(t *testing.T) {
	state := workstationState(t, "plain.txt")
	state.HasWorkspace = false
	checkWorkbenchSnapshot(t, "workstation_single_file", 960, 640, workstationFrame(state, nil))
}

func TestSnapshotWorkstationMarkdown(t *testing.T) {
	state := workstationState(t, "README.md")
	checkWorkbenchSnapshot(t, "workstation_markdown", 960, 640, workstationFrame(state, filesSidebar))
}

func TestSnapshotWorkstationSelectedTree(t *testing.T) {
	state := workstationState(t, "src/main.go")
	checkWorkbenchSnapshot(t, "workstation_selected_tree", 960, 640, workstationFrame(state, filesSidebar))
}

func TestSnapshotWorkstationMultipleTabs(t *testing.T) {
	state := workstationState(t, "README.md", "plain.txt", "src/main.go")
	checkWorkbenchSnapshot(t, "workstation_multiple_tabs", 960, 640, workstationFrame(state, filesSidebar))
}

func TestSnapshotWorkstationFilesSidebar(t *testing.T) {
	state := workstationState(t, "README.md")
	checkWorkbenchSnapshot(t, "workstation_files_sidebar", 720, 520, workstationFrame(state, filesSidebar))
}

func TestSnapshotWorkstationOutlineSidebar(t *testing.T) {
	state := workstationState(t, "README.md")
	checkWorkbenchSnapshot(t, "workstation_outline_sidebar", 720, 520, workstationFrame(state, func(shell *workbenchState) {
		shell.SidebarVisible = true
		shell.SidebarInitialized = true
		shell.SidebarMode = SidebarOutline
	}))
}

func TestSnapshotWorkstationStatusBar(t *testing.T) {
	state := workstationState(t, "README.md")
	checkWorkbenchSnapshot(t, "workstation_status_bar", 960, 80, func() {
		Container(Attrs(Viewport, BackgroundVec(DefaultTheme().Window)), func() {
			Container(Attrs(Grow(1)), func() {})
			statusBar(state, DefaultTheme())
		})
	})
}

func TestSnapshotWorkstationPopup(t *testing.T) {
	state := workstationState(t, "README.md", "plain.txt")
	checkWorkbenchSnapshot(t, "workstation_popup", 960, 640, workstationFrame(state, func(shell *workbenchState) {
		filesSidebar(shell)
		shell.ContextMenu = contextMenuState{
			Open: true, Generation: 1, Kind: contextMenuTab, ID: state.Active,
			Path: state.ActiveDocument().Path, Position: Vec2{380, 120},
		}
	}))
}

func TestSnapshotWorkstationDialog(t *testing.T) {
	state := workstationState(t, "README.md")
	checkWorkbenchSnapshot(t, "workstation_dialog", 960, 640, workstationFrame(state, func(shell *workbenchState) {
		filesSidebar(shell)
		shell.ShowSaveAs = true
		shell.SaveAsPath = "notes/scratch.md"
	}))
}
