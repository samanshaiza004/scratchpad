package ui

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"scratchpad/application"
	"scratchpad/workspace"

	. "go.hasen.dev/shirei"
	. "go.hasen.dev/shirei/widgets"
)

// RootView is the small workbench shell around the file-native application.
// The sidebar and editor are siblings: tree recursion never changes the
// layout axis of the workbench itself.
func RootView(state *application.Application) {
	if state == nil {
		return
	}
	state.PollWatcher()
	state.ReconcileStale()
	state.MaybeWriteRecovery(state.RecoveryDir)

	shell := Use[workbenchState]("workbench")
	handleGlobalInput(state, shell)

	Container(Attrs(Viewport, Expand, Background(220, 14, 96, 1), Pad2(18, 20), Gap(10)), func() {
		header(state, shell)
		Container(Attrs(Row, Grow(1), Expand, Gap(12)), func() {
			sidebar(state)
			Container(Attrs(Grow(1), Expand, Gap(8), Clip), func() {
				if len(state.Order) == 0 {
					emptyState(shell)
					return
				}
				tabs(state, shell)
				if shell.ShowFind || shell.ShowSearch {
					searchPanel(state, shell)
				}
				conflictPanel(state, shell)
				closePanel(state, shell)
				if doc := state.ActiveDocument(); doc != nil {
					id := state.Active
					view := state.Views[id]
					EditableDocumentView(id, doc, EditorViewOptions{
						Style: DefaultTextStyle(), RowHeight: 20, ScrollY: &view.ScrollY,
						ScrollInitialized: view.ScrollInitialized,
					})
					view.ScrollInitialized = true
					state.Views[id] = view
				}
			})
		})
	})
	openControls(state, shell)
}

type workbenchState struct {
	ShowFolder    bool
	ShowQuickOpen bool
	FilePath      string
	ShowFind      bool
	ShowSearch    bool
	ClosePending  application.DocumentID
	ShowCompare   bool
	FolderPicker  folderPickerState
}

type folderPickerState struct {
	Cwd      string
	Filter   string
	Selected int
	Result   string
}

func header(state *application.Application, shell *workbenchState) {
	Container(Attrs(Row, CrossMid, Gap(12)), func() {
		Label("Scratchpad", FontWeight(WeightBold), FontSize(24), TextColor(220, 18, 15, 1))
		if state.HasWorkspace {
			Label(filepath.Base(state.Workspace.Root), FontSize(13), TextColor(220, 12, 35, 1))
		}
		Container(Attrs(Grow(1)), func() {})
		if Button(NoIcon, "Open folder") {
			openFolderPicker(state, shell)
		}
		if Button(NoIcon, "Quick open") {
			shell.ShowQuickOpen = true
		}
		if state.ActiveDocument() != nil && Button(NoIcon, "Save") {
			_ = state.SaveActive()
		}
	})
}

func sidebar(state *application.Application) {
	Container(Attrs(FixWidth(250), Expand, Clip, Gap(8), Pad(10), Background(220, 12, 91, 1), Corners(8)), func() {
		tree := Use[treeState]("workspace-tree")
		if tree.Expanded == nil {
			tree.Expanded = make(map[string]bool)
		}
		Container(Attrs(Row, CrossMid), func() {
			Label("Workspace", FontWeight(WeightBold), FontSize(12))
			Container(Attrs(Grow(1)), func() {})
			if Button(NoIcon, "Refresh") {
				tree.Expanded = make(map[string]bool)
			}
		})
		if !state.HasWorkspace {
			Label("Open a folder to browse files.", FontSize(12), TextColor(220, 12, 35, 1))
			return
		}
		Container(Attrs(Viewport, Grow(1), Expand, Clip), func() {
			ScrollOnInput()
			renderTree(state, tree, "", 0)
			ScrollBars()
		})
	})
}

type treeState struct {
	Expanded map[string]bool
}

func renderTree(state *application.Application, tree *treeState, relative string, depth int) {
	if tree.Expanded == nil {
		tree.Expanded = make(map[string]bool)
	}
	entries, err := state.Workspace.List(relative)
	if err != nil {
		Label("Workspace unavailable: "+err.Error(), FontSize(12))
		return
	}
	for _, entry := range entries {
		entry := entry
		ContainerWithKey(entry.Path, Attrs(Gap(2)), func() {
			indent := strings.Repeat("  ", depth)
			if entry.Dir {
				label := indent + "▸ " + entry.Name
				if tree.Expanded[entry.Path] {
					label = indent + "▾ " + entry.Name
				}
				if Button(NoIcon, label) {
					tree.Expanded[entry.Path] = !tree.Expanded[entry.Path]
				}
				if tree.Expanded[entry.Path] {
					renderTree(state, tree, entry.Path, depth+1)
				}
				return
			}
			active := isActivePath(state, filepath.Join(state.Workspace.Root, entry.Path))
			label := indent + "  " + entry.Name
			if active {
				label = indent + "● " + entry.Name
			}
			Container(Attrs(Row, Gap(2), Pad2(2, 4), BackgroundIf(active, Vec4{210, 70, 48, 1}), Corners(4)), func() {
				if Button(NoIcon, label) {
					_ = state.OpenPath(filepath.Join(state.Workspace.Root, entry.Path))
				}
			})
		})
	}
}

func BackgroundIf(active bool, color Vec4) AttrsFn {
	if !active {
		return func(*AttrSet) {}
	}
	return BackgroundVec(color)
}

func isActivePath(state *application.Application, path string) bool {
	active := state.ActiveDocument()
	if active == nil {
		return false
	}
	a, _ := filepath.Abs(active.Path)
	b, _ := filepath.Abs(path)
	return filepath.Clean(a) == filepath.Clean(b)
}

func emptyState(shell *workbenchState) {
	Container(Attrs(Grow(1), Expand, Gap(10), Pad(28), Background(220, 12, 92, 1), Corners(10)), func() {
		Label("A quiet place for files, notes, and code.", FontWeight(WeightBold), FontSize(20))
		Label("Open a folder or a file to begin. Your files remain ordinary files on disk.", FontSize(13), TextColor(220, 12, 35, 1))
		Container(Attrs(Row, Gap(8)), func() {
			if Button(NoIcon, "Open folder") {
				openFolderPicker(nil, shell)
			}
			if Button(NoIcon, "Open file") {
				shell.ShowQuickOpen = true
			}
		})
	})
}

func openControls(state *application.Application, shell *workbenchState) {
	if shell.ShowFolder {
		Modal(560, func() { shell.ShowFolder = false }, func() {
			Label("Open folder", FontWeight(WeightBold), FontSize(14))
			if folderPickerPanel(shell) {
				if state.OpenPath(filepath.Clean(shell.FolderPicker.Result)) == nil {
					shell.ShowFolder = false
				}
			}
		})
	}
	if shell.ShowQuickOpen {
		Modal(560, func() { shell.ShowQuickOpen = false }, func() {
			Label("Quick open", FontWeight(WeightBold), FontSize(14))
			root := state.Workspace.Root
			if root == "" {
				root = "."
			}
			FuzzyPathFinderExt(&shell.FilePath, FuzzyPathFinderAttrs{Title: "Choose a file", Files: true, Root: root, ShowHidden: true, MinWidth: 360})
			if Button(NoIcon, "Open selected file") && shell.FilePath != "" {
				if state.OpenPath(shell.FilePath) == nil {
					shell.ShowQuickOpen = false
				}
			}
		})
	}
}

func openFolderPicker(state *application.Application, shell *workbenchState) {
	start := ""
	if state != nil && state.HasWorkspace {
		start = state.Workspace.Root
	}
	if start == "" {
		start, _ = os.UserHomeDir()
	}
	if start == "" {
		start = "."
	}
	if abs, err := filepath.Abs(start); err == nil {
		start = filepath.Clean(abs)
	}
	shell.FolderPicker = folderPickerState{Cwd: start, Selected: -1}
	shell.ShowFolder = true
}

func folderPickerPanel(shell *workbenchState) bool {
	return FileBrowserPanel(
		&shell.FolderPicker.Cwd,
		&shell.FolderPicker.Filter,
		&shell.FolderPicker.Selected,
		&shell.FolderPicker.Result,
		FileBrowserAttrs{Title: "Open folder", Dirs: true, Width: 520, ShowHidden: true},
	)
}

func conflictPanel(state *application.Application, shell *workbenchState) {
	conflict, ok := state.Conflict(state.Active)
	if !ok {
		shell.ShowCompare = false
		return
	}
	Container(Attrs(Row, CrossMid, Gap(8), Background(220, 58, 86, 1), Pad(8), Corners(5)), func() {
		Label("Conflict — file changed on disk", FontWeight(WeightBold), FontSize(12))
		Label(fmt.Sprintf("base %d B · disk %d B", len(conflict.Base), len(conflict.Disk)), FontSize(11))
		if Button(NoIcon, "Compare") {
			shell.ShowCompare = true
		}
		if Button(NoIcon, "Reload disk") {
			_ = state.ReloadDisk(state.Active)
		}
		if Button(NoIcon, "Keep editing") {
			_ = state.KeepEditing(state.Active)
		}
		if Button(NoIcon, "Overwrite disk") {
			_ = state.OverwriteDisk(state.Active)
		}
	})
	if shell.ShowCompare {
		doc := state.ActiveDocument()
		localBytes := 0
		if doc != nil {
			localBytes = len(doc.Editor.Buffer.Text())
		}
		Container(Attrs(Row, CrossMid, Gap(8), Background(220, 12, 92, 1), Pad(6), Corners(5)), func() {
			Label(fmt.Sprintf("Compare snapshots · base %d B · local %d B · disk %d B", len(conflict.Base), localBytes, len(conflict.Disk)), FontSize(11))
			if Button(NoIcon, "Close compare") {
				shell.ShowCompare = false
			}
		})
	}
}

type searchState struct {
	Query   string
	Results []workspace.SearchResult
	Pending <-chan workspace.SearchResult
	Cancel  context.CancelFunc
}

func searchPanel(state *application.Application, shell *workbenchState) {
	search := Use[searchState]("workspace-search")
	Container(Attrs(Row, CrossMid, Gap(8), Pad2(5, 8), Background(220, 10, 92, 1), Corners(5)), func() {
		Label("Find", FontWeight(WeightBold), FontSize(12))
		input := DefaultTextInputAttrs()
		input.MinWidth = 260
		TextInputExt(&search.Query, input)
		if Button(NoIcon, "Search") && shell.ShowSearch {
			if search.Cancel != nil {
				search.Cancel()
			}
			search.Results = nil
			ctx, cancel := context.WithCancel(context.Background())
			search.Cancel = cancel
			search.Pending = state.SearchWorkspace(ctx, []byte(search.Query))
		}
		if Button(NoIcon, "Close") {
			shell.ShowFind = false
			shell.ShowSearch = false
		}
		if state.Active != "" && search.Query != "" {
			Label(fmt.Sprintf("%d current-file matches", len(state.FindCurrent(state.Active, []byte(search.Query)))), FontSize(11))
		}
	})
	if shell.ShowSearch {
		for i := 0; i < 64 && search.Pending != nil; i++ {
			select {
			case result, ok := <-search.Pending:
				if !ok {
					search.Pending = nil
					search.Cancel = nil
					break
				}
				search.Results = append(search.Results, result)
			default:
				i = 64
			}
		}
		for _, result := range search.Results {
			Label(fmt.Sprintf("%s:%d:%d", filepath.Base(result.Path), result.Line+1, result.Column+1), FontSize(11))
		}
	}
}

func tabs(state *application.Application, shell *workbenchState) {
	Container(Attrs(Row, CrossMid, Gap(4)), func() {
		for _, id := range state.Order {
			doc := state.Documents[id]
			id, doc := id, doc
			active := id == state.Active
			label := filepathBase(doc.Path)
			if doc.Dirty() {
				label = "• " + label
			}
			ContainerWithKey(id, Attrs(Row, CrossMid, Gap(2), Pad2(3, 5), BackgroundIf(active, Vec4{210, 55, 45, 1}), Corners(5)), func() {
				if Button(NoIcon, label) {
					state.Activate(id)
				}
				if Button(NoIcon, "×") {
					requestClose(state, shell, id)
				}
			})
		}
	})
}

func requestClose(state *application.Application, shell *workbenchState, id application.DocumentID) {
	if state.Status(id) == application.StatusSynced {
		_ = state.CloseDocument(id, false)
		return
	}
	shell.ClosePending = id
}

func closePanel(state *application.Application, shell *workbenchState) {
	if shell.ClosePending == "" {
		return
	}
	doc := state.Documents[shell.ClosePending]
	if doc == nil {
		shell.ClosePending = ""
		return
	}
	Container(Attrs(Row, CrossMid, Gap(8), Background(220, 42, 90, 1), Pad(8), Corners(5)), func() {
		Label("Unsaved changes", FontWeight(WeightBold), FontSize(12))
		Label(filepathBase(doc.Path)+" has not been saved.", FontSize(11))
		if Button(NoIcon, "Save and close") {
			if state.SaveDocument(shell.ClosePending) == nil {
				_ = state.CloseDocument(shell.ClosePending, false)
				shell.ClosePending = ""
			}
		}
		if Button(NoIcon, "Discard") {
			_ = state.CloseDocument(shell.ClosePending, true)
			shell.ClosePending = ""
		}
		if Button(NoIcon, "Cancel") {
			shell.ClosePending = ""
		}
	})
}

func handleGlobalInput(state *application.Application, shell *workbenchState) {
	frame := GetFrameInput()
	mods := GetInputState().Modifiers
	primary := PrimaryMod()
	if frame.Key == KeyCodeNone {
		return
	}
	if mods == primary {
		switch frame.Key {
		case KeyS:
			_ = state.SaveActive()
			frame.Key = KeyCodeNone
		case KeyF:
			shell.ShowFind = true
			shell.ShowSearch = false
			frame.Key = KeyCodeNone
		case KeyP:
			shell.ShowQuickOpen = true
			frame.Key = KeyCodeNone
		case KeyW:
			if state.Active != "" {
				requestClose(state, shell, state.Active)
			}
			frame.Key = KeyCodeNone
		case KeyTab:
			state.Cycle(1)
			frame.Key = KeyCodeNone
		}
	} else if mods == primary|ModShift && frame.Key == KeyF {
		shell.ShowSearch = true
		shell.ShowFind = false
		frame.Key = KeyCodeNone
	} else if mods == primary|ModShift && frame.Key == KeyTab {
		state.Cycle(-1)
		frame.Key = KeyCodeNone
	}
}

func filepathBase(path string) string {
	if path == "" {
		return "untitled"
	}
	return filepath.Base(path)
}
