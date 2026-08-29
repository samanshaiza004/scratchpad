package ui

import (
	"context"
	"fmt"
	"path/filepath"

	"scratchpad/application"
	"scratchpad/workspace"

	. "go.hasen.dev/shirei"
	. "go.hasen.dev/shirei/widgets"
)

// RootView is intentionally a small proof that Scratchpad is a normal Shirei
// application. Product state and the editor are added only after the research
// gates establish their ownership and scale requirements.
func RootView(state *application.Application) {
	if state == nil {
		return
	}
	Container(Attrs(Viewport, Background(220, 12, 96, 1), Pad(28), Gap(18)), func() {
		Container(Attrs(Row, CrossMid, Gap(12)), func() {
			Label("Scratchpad", FontWeight(WeightBold), FontSize(24))
			if state.HasWorkspace {
				Label(state.Workspace.Root, FontSize(12), TextColor(220, 12, 35, 1))
			}
		})
		openControls(state)
		workspaceTree(state)
		searchPanel(state)
		if len(state.Order) == 0 {
			Container(Attrs(Pad(16), Gap(8), Background(220, 12, 91, 1), Corners(10)), func() {
				Label("Open a folder or file to begin", FontWeight(WeightBold), FontSize(15))
				Label("Plain text is authoritative; language services remain replaceable.", FontSize(13))
			})
			return
		}
		tabs(state)
		if doc := state.ActiveDocument(); doc != nil {
			id := state.Active
			view := state.Views[id]
			EditableDocumentView(id, doc, EditorViewOptions{
				Style: DefaultTextStyle(), RowHeight: 20, ScrollY: &view.ScrollY,
			})
			state.Views[id] = view
		}
	})
}

func openControls(state *application.Application) {
	folder := Use[string]("open-folder-path")
	file := Use[string]("open-file-path")
	Container(Attrs(Row, CrossMid, Gap(8)), func() {
		DirectoryBrowseExt(folder, FileBrowserAttrs{Title: "Open Folder", Dirs: true, Start: state.Workspace.Root, ShowHidden: true, MinWidth: 220})
		if Button(NoIcon, "Open Folder") && *folder != "" {
			_ = state.OpenPath(*folder)
		}
		FuzzyPathFinderExt(file, FuzzyPathFinderAttrs{Title: "Quick Open File", Files: true, Root: state.Workspace.Root, ShowHidden: true, MinWidth: 220})
		if Button(NoIcon, "Open File") && *file != "" {
			_ = state.OpenPath(*file)
		}
	})
}

func workspaceTree(state *application.Application) {
	if !state.HasWorkspace {
		return
	}
	stateForTree := Use[treeState]("workspace-tree")
	if stateForTree.Expanded == nil {
		stateForTree.Expanded = make(map[string]bool)
	}
	Container(Attrs(Gap(2)), func() {
		Label("Workspace", FontWeight(WeightBold), FontSize(12))
		renderTree(state, stateForTree, "", 0)
	})
}

type treeState struct {
	Expanded map[string]bool
}

func renderTree(state *application.Application, tree *treeState, relative string, depth int) {
	entries, err := state.Workspace.List(relative)
	if err != nil {
		Label("Workspace unavailable: "+err.Error(), FontSize(12))
		return
	}
	for _, entry := range entries {
		entry := entry
		ContainerWithKey(entry.Path, Attrs(Row, Gap(4)), func() {
			if entry.Dir {
				label := "▸ " + entry.Name
				if tree.Expanded[entry.Path] {
					label = "▾ " + entry.Name
				}
				if Button(NoIcon, label) {
					tree.Expanded[entry.Path] = !tree.Expanded[entry.Path]
				}
				if tree.Expanded[entry.Path] {
					renderTree(state, tree, entry.Path, depth+1)
				}
				return
			}
			label := "  " + entry.Name
			if Button(NoIcon, label) {
				_ = state.OpenPath(filepath.Join(state.Workspace.Root, entry.Path))
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

func searchPanel(state *application.Application) {
	search := Use[searchState]("workspace-search")
	Container(Attrs(Row, CrossMid, Gap(8)), func() {
		input := DefaultTextInputAttrs()
		input.MinWidth = 220
		TextInputExt(&search.Query, input)
		if Button(NoIcon, "Find") {
			if search.Cancel != nil {
				search.Cancel()
			}
			search.Results = nil
			ctx, cancel := context.WithCancel(context.Background())
			search.Cancel = cancel
			search.Pending = state.SearchWorkspace(ctx, []byte(search.Query))
		}
		if search.Cancel != nil && Button(NoIcon, "Cancel") {
			search.Cancel()
			search.Cancel = nil
			search.Pending = nil
		}
	})
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
	if state.Active != "" && search.Query != "" {
		Label(fmt.Sprintf("Current file matches: %d", len(state.FindCurrent(state.Active, []byte(search.Query)))), FontSize(12))
	}
	for _, result := range search.Results {
		Label(fmt.Sprintf("%s:%d:%d", filepath.Base(result.Path), result.Line+1, result.Column+1), FontSize(11))
	}
}

func tabs(state *application.Application) {
	Container(Attrs(Row, CrossMid, Gap(4)), func() {
		for _, id := range state.Order {
			doc := state.Documents[id]
			label := filepathBase(doc.Path)
			if doc.Dirty() {
				label = "• " + label
			}
			if Button(NoIcon, label) {
				state.Activate(id)
			}
		}
	})
}

func filepathBase(path string) string {
	if path == "" {
		return "untitled"
	}
	return filepath.Base(path)
}
