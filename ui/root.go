package ui

import (
	"path/filepath"

	"scratchpad/application"

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
		FuzzyPathFinderExt(file, FuzzyPathFinderAttrs{Title: "Open File", Files: true, Root: state.Workspace.Root, ShowHidden: true, MinWidth: 220})
		if Button(NoIcon, "Open File") && *file != "" {
			_ = state.OpenPath(*file)
		}
	})
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
