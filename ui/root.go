package ui

import (
	"context"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"scratchpad/application"
	"scratchpad/commands"
	"scratchpad/document"
	"scratchpad/editor"
	"scratchpad/language/markdown"
	"scratchpad/workspace"

	"github.com/cli/browser"

	. "go.hasen.dev/shirei"
	. "go.hasen.dev/shirei/widgets"
)

// RootView is the application shell around the file-native editor. The shell
// is intentionally quiet: the document gets the largest surface, while menus
// and transient commands stay available from the keyboard.
func RootView(state *application.Application) {
	if state == nil {
		return
	}
	state.PollWatcher()
	state.ReconcileStale()
	state.PollDerived(time.Now())
	state.MaybeWriteRecovery(state.RecoveryDir)

	shell := Use[workbenchState]("workbench")
	if !shell.SidebarInitialized || (state.HasWorkspace && !shell.WorkspaceWasOpen) {
		shell.SidebarVisible = state.HasWorkspace
		shell.SidebarInitialized = true
	}
	shell.WorkspaceWasOpen = state.HasWorkspace
	if !state.HasWorkspace && shell.SidebarMode == SidebarFiles {
		shell.SidebarVisible = false
	}
	handleGlobalInput(state, shell)
	theme := DefaultTheme()

	Container(Attrs(Viewport, Expand, BackgroundVec(theme.Window), NoAnimate), func() {
		menuBar(state, shell, theme)
		Container(Attrs(Row, Grow(1), Expand, Gap(8), Pad2(0, 8)), func() {
			if shell.SidebarVisible && (state.HasWorkspace || shell.SidebarMode == SidebarOutline) {
				sidebar(state, shell, theme)
			}
			Container(Attrs(Grow(1), Expand, Gap(0), Clip), func() {
				if len(state.Order) == 0 {
					emptyState(shell, theme)
					return
				}
				if len(state.Order) > 1 {
					tabs(state, shell, theme)
				}
				findBar(state, shell, theme)
				conflictPanel(state, shell, theme)
				closePanel(state, shell, theme)
				if doc := state.ActiveDocument(); doc != nil {
					id := state.Active
					view := state.Views[id]
					if view.LastRevision != 0 && view.LastRevision != doc.Revision() {
						view.CollapsedHeadings = nil
					}
					rows := rowMapForDocument(doc, view)
					Container(Attrs(Grow(1), Expand, Clip, BackgroundVec(theme.Paper)), func() {
						EditableDocumentView(id, doc, EditorViewOptions{
							Style: DefaultTextStyle(), RowHeight: 20, ScrollY: &view.ScrollY,
							ScrollInitialized: view.ScrollInitialized,
							LineNumbers:       true,
							Rows:              &rows,
							Foldable:          func(line int) bool { return foldForLine(doc, line) != nil },
							FoldMarker: func(line int) string {
								if view.CollapsedHeadings != nil && view.CollapsedHeadings[headingAtLine(doc, line)] {
									return "▸"
								}
								return "▾"
							},
							OnFoldToggle: func(line int) { toggleFold(doc, &view, line) },
						})
					})
					view.ScrollInitialized = true
					view.LastRevision = doc.Revision()
					state.Views[id] = view
				}
			})
		})
		statusBar(state, theme)
	})
	openControls(state, shell, theme)
}

type workbenchState struct {
	ShowOpen           bool
	ShowFolder         bool // compatibility for the focused folder-picker tests
	ShowQuickOpen      bool
	ShowSaveAs         bool
	ShowFind           bool
	ShowSearch         bool
	SidebarVisible     bool
	SidebarInitialized bool
	WorkspaceWasOpen   bool
	FindEpoch          uint64
	QuickOpenEpoch     uint64
	FilePath           string
	SaveAsPath         string
	ClosePending       application.DocumentID
	ShowCompare        bool
	PathPicker         folderPickerState
	FolderPicker       folderPickerState // compatibility alias for existing tests
	SidebarMode        SidebarMode
}

type SidebarMode uint8

const (
	SidebarFiles SidebarMode = iota
	SidebarOutline
)

type folderPickerState struct {
	Cwd      string
	Filter   string
	Selected int
	Result   string
}

type quickOpenState struct {
	Query      string
	Candidates []string
	Result     string
	Cancel     context.CancelFunc
	Pending    <-chan []string
	Scanning   bool
}

type searchState struct {
	Query   string
	Current []application.CurrentMatch
	Results []workspace.SearchResult
	Pending <-chan workspace.SearchResult
	Cancel  context.CancelFunc
}

func menuBar(state *application.Application, shell *workbenchState, theme Theme) {
	if nativeMenuBar(state, shell) {
		return
	}
	Container(Attrs(Row, CrossMid, FixHeight(34), Pad2(0, 8), Gap(2), BackgroundVec(theme.Chrome), BorderWidth(1), BorderColorVec(theme.Border)), func() {
		CtrlMenuButton(NoIcon, "File", func() {
			if MenuItem(NoIcon, "Open…    "+primaryShortcut("O")) {
				executeCommand(state, shell, commands.FileOpen)
			}
			if MenuItem(NoIcon, "Quick Open…    "+primaryShortcut("P")) {
				executeCommand(state, shell, commands.QuickOpen)
			}
			MenuSeparator()
			if MenuItem(NoIcon, "Save    "+primaryShortcut("S")) {
				executeCommand(state, shell, commands.FileSave)
			}
			if MenuItem(NoIcon, "Save As…") {
				executeCommand(state, shell, commands.FileSaveAs)
			}
			if MenuItem(NoIcon, "Close    "+primaryShortcut("W")) {
				executeCommand(state, shell, commands.DocumentClose)
			}
		})
		CtrlMenuButton(NoIcon, "Edit", func() {
			if MenuItem(NoIcon, "Find…    "+primaryShortcut("F")) {
				executeCommand(state, shell, commands.DocumentFind)
			}
			if MenuItem(NoIcon, "Find in Files…    "+primaryShortcut("Shift+F")) {
				executeCommand(state, shell, commands.WorkspaceSearch)
			}
		})
		CtrlMenuButton(NoIcon, "View", func() {
			if MenuItem(NoIcon, "Outline") {
				executeCommand(state, shell, commands.OutlineToggle)
			}
			if (state.HasWorkspace || state.ActiveDocument() != nil) && MenuItem(NoIcon, "Toggle Sidebar") {
				executeCommand(state, shell, commands.ViewToggleSidebar)
			}
			if state.HasWorkspace && MenuItem(NoIcon, "Refresh Workspace") {
				executeCommand(state, shell, commands.WorkspaceRefresh)
			}
		})
		CtrlMenuButton(NoIcon, "Go", func() {
			if MenuItem(NoIcon, "Quick Open…") {
				executeCommand(state, shell, commands.QuickOpen)
			}
			if MenuItem(NoIcon, "Next Document") {
				executeCommand(state, shell, commands.TabNext)
			}
			if MenuItem(NoIcon, "Previous Document") {
				executeCommand(state, shell, commands.TabPrevious)
			}
		})
		CtrlMenuButton(NoIcon, "Help", func() { MenuItem(NoIcon, "Scratchpad") })
		Container(Attrs(Grow(1)), func() {})
		Label(documentTitle(state), FontSize(12), FontWeight(WeightBold), TextColorVec(theme.Ink))
		if state.HasWorkspace {
			Label(filepath.Base(state.Workspace.Root), FontSize(11), TextColorVec(theme.Muted))
		}
	})
}

func primaryShortcut(key string) string {
	if PrimaryMod() == ModCmd {
		return "⌘" + key
	}
	return "Ctrl+" + key
}

func documentTitle(state *application.Application) string {
	if doc := state.ActiveDocument(); doc != nil {
		return filepathBase(doc.Path) + " — Scratchpad"
	}
	return "Scratchpad"
}

func sidebar(state *application.Application, shell *workbenchState, theme Theme) {
	tree := Use[treeState]("workspace-tree")
	if tree.Expanded == nil {
		tree.Expanded = make(map[string]bool)
	}
	Container(Attrs(FixWidth(248), Expand, Clip, BackgroundVec(theme.Sidebar), BorderWidth(1), BorderColorVec(theme.Border)), func() {
		Container(Attrs(Row, CrossMid, FixHeight(34), Pad2(0, 10), BorderWidth(1), BorderColorVec(theme.Border)), func() {
			SegmentedControl(&shell.SidebarMode, Cell("Files", SidebarFiles), Cell("Outline", SidebarOutline))
			Container(Attrs(Grow(1)), func() {})
			if shell.SidebarMode == SidebarFiles && CtrlButton(NoIcon, "Refresh", true) {
				tree.Expanded = make(map[string]bool)
			}
		})
		if shell.SidebarMode == SidebarOutline {
			outlinePanel(state, theme)
			return
		}
		if shell.ShowSearch {
			workspaceSearchPanel(state, shell, theme)
		}
		Container(Attrs(Viewport, Grow(1), Expand, Clip, Pad2(6, 4)), func() {
			ScrollOnInput()
			renderTree(state, tree, "", 0, theme)
			ScrollBars()
		})
	})
}

func outlinePanel(state *application.Application, theme Theme) {
	doc := state.ActiveDocument()
	if doc == nil || doc.RootLanguage != "markdown" {
		Container(Attrs(Grow(1), Pad(10)), func() { Label("Outline is available for Markdown files.", FontSize(11), TextColorVec(theme.Muted)) })
		return
	}
	Container(Attrs(Viewport, Grow(1), Expand, Clip, Pad2(6, 4)), func() {
		ScrollOnInput()
		if !doc.Projections.Valid {
			Label("Updating outline…", FontSize(11), TextColorVec(theme.Muted))
		}
		for _, heading := range doc.Projections.Headings {
			Container(Attrs(Row, FixHeight(24), Expand, Pad2(0, float32(8+heading.Level*10))), func() {
				button := ProcessButtonEvents(doc.Projections.Valid)
				Label(heading.Text, FontSize(11), TextColorVec(theme.Ink))
				if button.Clicked && doc.Projections.Valid {
					doc.Editor.SetCursor(heading.StartByte)
				}
			})
		}
		if len(doc.Projections.Tasks) > 0 {
			Label("Tasks", FontWeight(WeightBold), FontSize(11), TextColorVec(theme.Muted))
			for _, task := range doc.Projections.Tasks {
				outlineTask(state, doc, task, doc.Projections.Valid, theme)
			}
		}
		if len(doc.Projections.Links) > 0 {
			Label("Links", FontWeight(WeightBold), FontSize(11), TextColorVec(theme.Muted))
			for _, link := range doc.Projections.Links {
				outlineLink(state, doc, link, doc.Projections.Valid, theme)
			}
		}
		ScrollBars()
	})
}

func outlineTask(state *application.Application, doc *document.Document, task document.Task, enabled bool, theme Theme) {
	Container(Attrs(Row, FixHeight(24), Expand, Pad2(0, 10), Gap(4)), func() {
		if CtrlButton(NoIcon, checkbox(task.Checked), enabled) && enabled {
			marker, err := doc.Editor.Buffer.Bytes(task.MarkerStart, task.MarkerEnd)
			if err == nil && (string(marker) == "[ ]" || string(marker) == "[x]" || string(marker) == "[X]") {
				replacement := []byte("[ ]")
				if !task.Checked {
					replacement = []byte("[x]")
				}
				_ = doc.Replace(task.MarkerStart, task.MarkerEnd, replacement)
			}
		}
		button := ProcessButtonEvents(enabled)
		Label(task.Text, FontSize(11), TextColorVec(theme.Ink))
		if button.Clicked && enabled {
			doc.Editor.SetCursor(task.StartByte)
		}
	})
}

func checkbox(checked bool) string {
	if checked {
		return "☑"
	}
	return "☐"
}

func outlineLink(state *application.Application, doc *document.Document, link document.Link, enabled bool, theme Theme) {
	Container(Attrs(Row, FixHeight(24), Expand, Pad2(0, 10), Gap(4)), func() {
		button := ProcessButtonEvents(enabled)
		Label(link.Label, FontSize(11), TextColorVec(theme.Ink))
		if button.Clicked && enabled {
			doc.Editor.SetCursor(link.StartByte)
		}
		if CtrlButton(NoIcon, "Open", enabled) && enabled {
			openLinkTarget(state, doc, link.Target)
		}
	})
}

func openLinkTarget(state *application.Application, doc *document.Document, target string) {
	kind := markdown.LinkTargetKind(target)
	if kind == "unsupported" {
		return
	}
	if kind == "http" || kind == "https" || kind == "mailto" {
		_ = browser.OpenURL(target)
		return
	}
	if state == nil {
		return
	}
	parsed, err := url.Parse(target)
	if err != nil {
		return
	}
	if parsed.Path == "" && parsed.Fragment != "" {
		jumpToHeadingID(doc, parsed.Fragment)
		return
	}
	if parsed.Path == "" {
		return
	}
	path, err := resolveLocalLinkPath(doc.Path, target)
	if err != nil {
		return
	}
	if state.OpenPath(path) == nil && parsed.Fragment != "" {
		jumpToHeadingID(state.ActiveDocument(), parsed.Fragment)
	}
}

func resolveLocalLinkPath(documentPath, target string) (string, error) {
	isWindowsPath := (len(target) >= 3 && ((target[0] >= 'a' && target[0] <= 'z') || (target[0] >= 'A' && target[0] <= 'Z')) && target[1] == ':' && (target[2] == '\\' || target[2] == '/')) || strings.HasPrefix(target, `\\`) || strings.HasPrefix(target, "//")
	if isWindowsPath {
		return filepath.Clean(target), nil
	}
	parsed, err := url.Parse(target)
	if err != nil || parsed.Path == "" {
		return "", fmt.Errorf("invalid local link path %q", target)
	}
	path, err := url.PathUnescape(parsed.EscapedPath())
	if err != nil {
		return "", err
	}
	if !filepath.IsAbs(path) {
		path = filepath.Join(filepath.Dir(documentPath), path)
	}
	return filepath.Clean(path), nil
}

func jumpToHeadingID(doc *document.Document, id string) {
	if doc == nil || !doc.DerivedCurrent() {
		return
	}
	for _, heading := range doc.Projections.Headings {
		if heading.ID == id {
			doc.Editor.SetCursor(heading.StartByte)
			return
		}
	}
}

func rowMapForDocument(doc *document.Document, view application.ViewState) editor.RowMap {
	if doc == nil || !doc.DerivedCurrent() || len(view.CollapsedHeadings) == 0 {
		return editor.IdentityRowMap(doc.Editor.Buffer.LineCount())
	}
	hidden := make([]editor.HiddenLineRange, 0, len(view.CollapsedHeadings))
	for _, fold := range doc.Projections.Folds {
		if !view.CollapsedHeadings[fold.HeadingStart] {
			continue
		}
		start, ok := doc.Editor.Buffer.LineAt(fold.StartByte)
		if !ok {
			continue
		}
		end, ok := doc.Editor.Buffer.LineAt(fold.EndByte)
		if !ok || end <= start {
			continue
		}
		hidden = append(hidden, editor.HiddenLineRange{Start: start, End: end})
	}
	return editor.NewRowMap(doc.Editor.Buffer.LineCount(), hidden)
}

func foldForLine(doc *document.Document, line int) *document.Fold {
	if doc == nil || !doc.DerivedCurrent() {
		return nil
	}
	start, _, ok := doc.Editor.Buffer.LineRange(line)
	if !ok {
		return nil
	}
	for i := range doc.Projections.Folds {
		if doc.Projections.Folds[i].HeadingStart == start {
			return &doc.Projections.Folds[i]
		}
	}
	return nil
}

func headingAtLine(doc *document.Document, line int) int {
	if doc == nil {
		return -1
	}
	start, _, ok := doc.Editor.Buffer.LineRange(line)
	if !ok {
		return -1
	}
	for _, heading := range doc.Projections.Headings {
		if heading.StartByte == start {
			return heading.StartByte
		}
	}
	return -1
}

func toggleFold(doc *document.Document, view *application.ViewState, line int) {
	if doc == nil || view == nil || !doc.DerivedCurrent() {
		return
	}
	heading := headingAtLine(doc, line)
	if heading < 0 || foldForLine(doc, line) == nil {
		return
	}
	if view.CollapsedHeadings == nil {
		view.CollapsedHeadings = make(map[int]bool)
	}
	view.CollapsedHeadings[heading] = !view.CollapsedHeadings[heading]
	if !view.CollapsedHeadings[heading] {
		delete(view.CollapsedHeadings, heading)
	}
}

type treeState struct {
	Expanded map[string]bool
	RowIDs   map[string]ContainerId // transient handles used by layout tests
}

func renderTree(state *application.Application, tree *treeState, relative string, depth int, theme Theme) {
	if tree.RowIDs == nil {
		tree.RowIDs = make(map[string]ContainerId)
	}
	entries, err := state.Workspace.List(relative)
	if err != nil {
		Label("Workspace unavailable: "+err.Error(), FontSize(11), TextColorVec(theme.Muted))
		return
	}
	for _, entry := range entries {
		entry := entry
		ContainerWithKey(entry.Path, Attrs(Expand), func() {
			// Keep the item itself horizontal. Expanded children are siblings
			// below it in this vertical subtree, never children of its row.
			rowID := Container(Attrs(Row, CrossMid, Expand, FixHeight(24), Pad4(0, 6, 0, float32(8+depth*14))), func() {
				button := ProcessButtonEvents(false)
				if button.Hovered {
					ModAttrs(BackgroundVec(theme.Highlight))
				}
				if !entry.Dir && isActivePath(state, filepath.Join(state.Workspace.Root, entry.Path)) {
					ModAttrs(BackgroundVec(theme.Selection))
				}
				if entry.Dir {
					arrow := "▸"
					if tree.Expanded[entry.Path] {
						arrow = "▾"
					}
					Label(arrow+"  "+entry.Name, FontSize(12), TextColorVec(theme.Ink))
					if button.Clicked {
						tree.Expanded[entry.Path] = !tree.Expanded[entry.Path]
					}
					return
				}
				marker := "  "
				if isActivePath(state, filepath.Join(state.Workspace.Root, entry.Path)) {
					marker = "● "
				}
				Label(marker+entry.Name, FontSize(12), TextColorVec(theme.Ink))
				if button.Clicked {
					_ = state.OpenPath(filepath.Join(state.Workspace.Root, entry.Path))
				}
			})
			tree.RowIDs[entry.Path] = rowID
			if entry.Dir && tree.Expanded[entry.Path] {
				renderTree(state, tree, entry.Path, depth+1, theme)
			}
		})
	}
}

func emptyState(shell *workbenchState, theme Theme) {
	Container(Attrs(Grow(1), Expand, Center, BackgroundVec(theme.Paper), Pad(28)), func() {
		Container(Attrs(FixWidth(560), Gap(8)), func() {
			Label("A quiet place for files, notes, and code.", FontWeight(WeightBold), FontSize(20), TextColorVec(theme.Ink))
			Label("Open a file for a focused editor, or a folder for the workspace tree.", FontSize(13), TextColorVec(theme.Muted))
			Container(Attrs(Row, Gap(8)), func() {
				if CtrlButton(NoIcon, "Open…", true) {
					openPathPicker(nil, shell)
				}
				if CtrlButton(NoIcon, "Quick open", true) {
					shell.ShowQuickOpen = true
				}
			})
		})
	})
}

func tabs(state *application.Application, shell *workbenchState, theme Theme) {
	Container(Attrs(Row, CrossMid, FixHeight(32), Gap(2), BackgroundVec(theme.Chrome), Pad2(2, 4)), func() {
		for _, id := range state.Order {
			doc := state.Documents[id]
			id, doc := id, doc
			active := id == state.Active
			ContainerWithKey(id, Attrs(Row, CrossMid, FixHeight(27), Pad2(0, 8), Gap(6), BackgroundIf(active, theme.Paper), BorderWidth(1), BorderColorVec(theme.Border)), func() {
				button := ProcessButtonEvents(false)
				if button.Hovered && !active {
					ModAttrs(BackgroundVec(theme.Highlight))
				}
				if doc.Dirty() {
					Label("●", FontSize(9), TextColorVec(theme.Warning))
				}
				Label(filepathBase(doc.Path), FontSize(12), TextColorVec(theme.Ink))
				Container(Attrs(FixWidth(16), FixHeight(18), Center), func() {
					closeButton := ProcessButtonEvents(false)
					if closeButton.Hovered {
						ModAttrs(BackgroundVec(theme.Highlight))
					}
					Label("×", FontSize(13), TextColorVec(theme.Muted))
					if closeButton.Clicked {
						requestClose(state, shell, id)
					}
				})
				if button.Clicked {
					state.Activate(id)
				}
			})
		}
		Container(Attrs(Grow(1)), func() {})
	})
}

func findBar(state *application.Application, shell *workbenchState, theme Theme) {
	if !shell.ShowFind {
		return
	}
	search := Use[searchState]("current-find")
	Container(Attrs(Row, CrossMid, Gap(6), FixHeight(34), Pad2(3, 8), BackgroundVec(theme.Raised), BorderWidth(1), BorderColorVec(theme.Border)), func() {
		Label("Find", FontWeight(WeightBold), FontSize(11), TextColorVec(theme.Ink))
		input := CtrlTextInputAttrs()
		input.MinWidth = 260
		ContainerWithKey(fmt.Sprintf("find-field-%d", shell.FindEpoch), Attrs(Grow(1)), func() {
			TextInputExt(&search.Query, input)
		})
		search.Current = nil
		if state.Active != "" && search.Query != "" {
			search.Current = state.FindCurrent(state.Active, []byte(search.Query))
			Label(fmt.Sprintf("%d matches", len(search.Current)), FontSize(10), TextColorVec(theme.Muted))
		}
		Container(Attrs(Grow(1)), func() {})
		if CtrlButton(NoIcon, "Close", true) {
			shell.ShowFind = false
		}
	})
	if len(search.Current) > 0 && GetFrameInput().Key == KeyEnter {
		match := search.Current[0]
		if doc := state.ActiveDocument(); doc != nil {
			doc.Editor.SetSelection(match.Start, match.End)
		}
		GetFrameInput().Key = KeyCodeNone
	}
}

func workspaceSearchPanel(state *application.Application, shell *workbenchState, theme Theme) {
	search := Use[searchState]("workspace-search")
	Container(Attrs(Gap(5), Pad2(6, 8), BackgroundVec(theme.Inset)), func() {
		Container(Attrs(Row, CrossMid, Gap(4)), func() {
			input := CtrlTextInputAttrs()
			input.MinWidth = 140
			TextInputExt(&search.Query, input)
			if CtrlButton(NoIcon, "Search", true) {
				if search.Cancel != nil {
					search.Cancel()
				}
				search.Results = nil
				ctx, cancel := context.WithCancel(context.Background())
				search.Cancel = cancel
				search.Pending = state.SearchWorkspace(ctx, []byte(search.Query))
			}
		})
		for i := 0; i < 64 && search.Pending != nil; i++ {
			select {
			case result, ok := <-search.Pending:
				if !ok {
					search.Pending = nil
					search.Cancel = nil
					i = 64
					continue
				}
				search.Results = append(search.Results, result)
			default:
				i = 64
			}
		}
		for _, result := range search.Results {
			Label(fmt.Sprintf("%s:%d:%d", filepath.Base(result.Path), result.Line+1, result.Column+1), FontSize(10), TextColorVec(theme.Muted))
		}
	})
}

func conflictPanel(state *application.Application, shell *workbenchState, theme Theme) {
	conflict, ok := state.Conflict(state.Active)
	if !ok {
		shell.ShowCompare = false
		return
	}
	Container(Attrs(Row, CrossMid, Gap(7), FixHeight(34), Pad2(3, 8), BackgroundVec(theme.Warning), BorderWidth(1), BorderColorVec(theme.Border)), func() {
		Label("Conflict", FontWeight(WeightBold), FontSize(11), TextColorVec(theme.Ink))
		Label(fmt.Sprintf("disk changed · base %d B · disk %d B", len(conflict.Base), len(conflict.Disk)), FontSize(10), TextColorVec(theme.Muted))
		Container(Attrs(Grow(1)), func() {})
		if CtrlButton(NoIcon, "Compare", true) {
			shell.ShowCompare = true
		}
		if CtrlButton(NoIcon, "Reload", true) {
			_ = state.ReloadDisk(state.Active)
		}
		if CtrlButton(NoIcon, "Keep editing", true) {
			_ = state.KeepEditing(state.Active)
		}
		if CtrlButton(NoIcon, "Overwrite…", true) {
			_ = state.OverwriteDisk(state.Active)
		}
	})
	if shell.ShowCompare {
		Container(Attrs(Row, CrossMid, Gap(8), FixHeight(28), Pad2(2, 8), BackgroundVec(theme.Raised)), func() {
			localBytes := 0
			if doc := state.ActiveDocument(); doc != nil {
				localBytes = len(doc.Editor.Buffer.Text())
			}
			Label(fmt.Sprintf("Compare · base %d B · local %d B · disk %d B", len(conflict.Base), localBytes, len(conflict.Disk)), FontSize(10), TextColorVec(theme.Muted))
			Container(Attrs(Grow(1)), func() {})
			if CtrlButton(NoIcon, "Close", true) {
				shell.ShowCompare = false
			}
		})
	}
}

func closePanel(state *application.Application, shell *workbenchState, theme Theme) {
	if shell.ClosePending == "" {
		return
	}
	doc := state.Documents[shell.ClosePending]
	if doc == nil {
		shell.ClosePending = ""
		return
	}
	Container(Attrs(Row, CrossMid, Gap(7), FixHeight(34), Pad2(3, 8), BackgroundVec(theme.Warning)), func() {
		Label("Unsaved changes", FontWeight(WeightBold), FontSize(11), TextColorVec(theme.Ink))
		Label(filepathBase(doc.Path)+" has not been saved.", FontSize(10), TextColorVec(theme.Muted))
		Container(Attrs(Grow(1)), func() {})
		if CtrlButton(NoIcon, "Save and close", true) && state.SaveDocument(shell.ClosePending) == nil {
			_ = state.CloseDocument(shell.ClosePending, false)
			shell.ClosePending = ""
		}
		if CtrlButton(NoIcon, "Discard", true) {
			_ = state.CloseDocument(shell.ClosePending, true)
			shell.ClosePending = ""
		}
		if CtrlButton(NoIcon, "Cancel", true) {
			shell.ClosePending = ""
		}
	})
}

func statusBar(state *application.Application, theme Theme) {
	Container(Attrs(Row, CrossMid, FixHeight(25), Gap(10), Pad2(0, 10), BackgroundVec(theme.Chrome), BorderWidth(1), BorderColorVec(theme.Border)), func() {
		doc := state.ActiveDocument()
		if doc == nil {
			Label("No document", FontSize(10), TextColorVec(theme.Muted))
			return
		}
		status := "Saved"
		if doc.Dirty() {
			status = "Modified"
		}
		if state.Status(state.Active) == application.StatusConflict {
			status = "Conflict"
		}
		Label(status, FontSize(10), TextColorVec(theme.Muted))
		Label(doc.Path, FontSize(10), TextColorVec(theme.Ink))
		Container(Attrs(Grow(1)), func() {})
		line, column := cursorPosition(doc)
		Label(fmt.Sprintf("Ln %d · Col %d", line, column), FontSize(10), TextColorVec(theme.Muted))
		encoding := strings.ToUpper(doc.Format.Encoding)
		if doc.Format.UTF8BOM {
			encoding += " BOM"
		}
		Label(encoding, FontSize(10), TextColorVec(theme.Muted))
		if doc.RootLanguage != "" {
			Label(doc.RootLanguage, FontSize(10), TextColorVec(theme.Muted))
		}
	})
}

func cursorPosition(doc *document.Document) (int, int) {
	if doc == nil || doc.Editor == nil {
		return 1, 1
	}
	line, ok := doc.Editor.Buffer.LineAt(doc.Editor.Cursor)
	if !ok {
		return 1, doc.Editor.Cursor + 1
	}
	start, _, _ := doc.Editor.Buffer.LineRange(line)
	return line + 1, doc.Editor.Cursor - start + 1
}

func openControls(state *application.Application, shell *workbenchState, themes ...Theme) {
	theme := DefaultTheme()
	if len(themes) > 0 {
		theme = themes[0]
	}
	if shell.ShowFolder && !shell.ShowOpen {
		Modal(560, func() { shell.ShowFolder = false }, func() {
			Label("Open folder", FontWeight(WeightBold), FontSize(14), TextColorVec(theme.Ink))
			if folderPickerPanel(shell) {
				if state.OpenPath(filepath.Clean(shell.FolderPicker.Result)) == nil {
					shell.ShowFolder = false
				}
			}
		})
	}
	if shell.ShowOpen {
		Modal(620, func() { shell.ShowOpen = false; shell.ShowFolder = false }, func() {
			Label("Open file or folder", FontWeight(WeightBold), FontSize(14), TextColorVec(theme.Ink))
			if FileBrowserPanel(&shell.PathPicker.Cwd, &shell.PathPicker.Filter, &shell.PathPicker.Selected, &shell.PathPicker.Result, FileBrowserAttrs{Title: "Open", Dirs: true, Files: true, Start: shell.PathPicker.Cwd, Width: 580, ShowHidden: true}) {
				if state.OpenPath(filepath.Clean(shell.PathPicker.Result)) == nil {
					shell.ShowOpen = false
					shell.ShowFolder = false
				}
			}
		})
	}
	if shell.ShowSaveAs {
		Modal(520, func() { shell.ShowSaveAs = false }, func() {
			Label("Save As", FontWeight(WeightBold), FontSize(14), TextColorVec(theme.Ink))
			field := DefaultTextInputAttrs()
			field.MinWidth = 420
			TextInputExt(&shell.SaveAsPath, field)
			Container(Attrs(Row, Gap(6)), func() {
				if Button(NoIcon, "Save As") && state.Active != "" && state.SaveAs(state.Active, shell.SaveAsPath) == nil {
					shell.ShowSaveAs = false
				}
				if Button(NoIcon, "Cancel") {
					shell.ShowSaveAs = false
				}
			})
		})
	}
	if shell.ShowQuickOpen {
		quickOpenPopup(state, shell, theme)
	}
}

func quickOpenPopup(state *application.Application, shell *workbenchState, theme Theme) {
	quick := Use[quickOpenState]("quick-open")
	if quick.Pending != nil {
		select {
		case paths := <-quick.Pending:
			quick.Candidates = paths
			quick.Pending = nil
			quick.Scanning = false
		default:
		}
	}
	if quick.Candidates == nil && state.HasWorkspace && !quick.Scanning {
		quick.Scanning = true
		ctx, cancel := context.WithCancel(context.Background())
		quick.Cancel = cancel
		ready := make(chan []string, 1)
		quick.Pending = ready
		go func() {
			paths := make([]string, 0)
			_ = state.Workspace.Files(ctx, func(path string) bool { paths = append(paths, path); return true })
			ready <- paths
			close(ready)
		}()
	}
	if !state.HasWorkspace {
		openPathPicker(state, shell)
		shell.ShowQuickOpen = false
		return
	}
	Popup(func() {
		Container(Attrs(Float(0, 42), FixWidth(620), MaxHeight(520), Pad(10), Gap(5), BackgroundVec(theme.Raised), BorderWidth(1), BorderColorVec(theme.Border), Corners(3)), func() {
			ContainerWithKey(fmt.Sprintf("quick-open-field-%d", shell.QuickOpenEpoch), Attrs(Focusable), func() {
				Focus()
				accepted := FileSelector(FileSelectorAttrs{Selection: &quick.Result, Query: &quick.Query, Candidates: quick.Candidates, Root: state.Workspace.Root, Width: 580, MaxRows: 14, Hint: func(n int) string { return fmt.Sprintf("%d files", n) }})
				if accepted && quick.Result != "" {
					if state.OpenPath(quick.Result) == nil {
						shell.ShowQuickOpen = false
						quick.Result = ""
					}
				}
			})
		})
	})
}

func openPathPicker(state *application.Application, shell *workbenchState) {
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
	shell.PathPicker = folderPickerState{Cwd: start, Selected: -1}
	shell.ShowOpen = true
}

// openFolderPicker remains a named helper for callers/tests from the original
// folder-only shell; production entry points now call the shared Open command.
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
	return FileBrowserPanel(&shell.FolderPicker.Cwd, &shell.FolderPicker.Filter, &shell.FolderPicker.Selected, &shell.FolderPicker.Result, FileBrowserAttrs{Title: "Open folder", Dirs: true, Width: 520, ShowHidden: true})
}

func requestClose(state *application.Application, shell *workbenchState, id application.DocumentID) {
	if state.Status(id) == application.StatusSynced {
		_ = state.CloseDocument(id, false)
		return
	}
	shell.ClosePending = id
}

func handleGlobalInput(state *application.Application, shell *workbenchState) {
	frame := GetFrameInput()
	mods := GetInputState().Modifiers
	primary := PrimaryMod()
	if frame.Key == KeyEscape {
		if shell.ShowFind {
			shell.ShowFind = false
			frame.Key = KeyCodeNone
			return
		}
		if shell.ShowSearch {
			shell.ShowSearch = false
			frame.Key = KeyCodeNone
			return
		}
		if shell.ShowQuickOpen {
			shell.ShowQuickOpen = false
			frame.Key = KeyCodeNone
			return
		}
	}
	if mods == primary {
		switch frame.Key {
		case KeyO:
			executeCommand(state, shell, commands.FileOpen)
		case KeyS:
			executeCommand(state, shell, commands.FileSave)
		case KeyF:
			executeCommand(state, shell, commands.DocumentFind)
		case KeyP:
			executeCommand(state, shell, commands.QuickOpen)
		case KeyW:
			executeCommand(state, shell, commands.DocumentClose)
		case KeyTab:
			executeCommand(state, shell, commands.TabNext)
		default:
			return
		}
		frame.Key = KeyCodeNone
		return
	}
	if mods == primary|ModShift {
		switch frame.Key {
		case KeyF:
			executeCommand(state, shell, commands.WorkspaceSearch)
		case KeyTab:
			executeCommand(state, shell, commands.TabPrevious)
		default:
			return
		}
		frame.Key = KeyCodeNone
	}
}

func executeCommand(state *application.Application, shell *workbenchState, id commands.ID) {
	switch id {
	case commands.FileOpen:
		openPathPicker(state, shell)
	case commands.FileSave:
		_ = state.SaveActive()
	case commands.FileSaveAs:
		if doc := state.ActiveDocument(); doc != nil {
			shell.SaveAsPath = doc.Path
			shell.ShowSaveAs = true
		}
	case commands.DocumentFind:
		if !shell.ShowFind {
			shell.FindEpoch++
		}
		shell.ShowFind = true
		shell.ShowSearch = false
	case commands.QuickOpen:
		if !shell.ShowQuickOpen {
			shell.QuickOpenEpoch++
		}
		shell.ShowQuickOpen = true
		shell.ShowFind = false
	case commands.WorkspaceSearch:
		shell.ShowSearch = true
		shell.ShowFind = false
	case commands.DocumentClose:
		if state.Active != "" {
			requestClose(state, shell, state.Active)
		}
	case commands.TabNext:
		state.Cycle(1)
	case commands.TabPrevious:
		state.Cycle(-1)
	case commands.ViewToggleSidebar:
		if state.HasWorkspace || state.ActiveDocument() != nil {
			shell.SidebarVisible = !shell.SidebarVisible
		}
	case commands.OutlineToggle:
		shell.SidebarMode = SidebarOutline
		shell.SidebarVisible = true
	case commands.WorkspaceRefresh:
		Use[treeState]("workspace-tree").Expanded = make(map[string]bool)
	case commands.EditUndo:
		if doc := state.ActiveDocument(); doc != nil {
			_ = doc.Editor.Undo()
		}
	case commands.EditRedo:
		if doc := state.ActiveDocument(); doc != nil {
			_ = doc.Editor.Redo()
		}
	case commands.EditCut:
		if doc := state.ActiveDocument(); doc != nil {
			if text, err := doc.Editor.Cut(); err == nil && text != "" {
				RequestTextCopy(text)
			}
		}
	case commands.EditCopy:
		if doc := state.ActiveDocument(); doc != nil {
			if text := doc.Editor.Copy(); text != "" {
				RequestTextCopy(text)
			}
		}
	case commands.EditPaste:
		if doc := state.ActiveDocument(); doc != nil {
			RequestPaste()
		}
	case commands.EditSelectAll:
		if doc := state.ActiveDocument(); doc != nil {
			doc.Editor.SelectAll()
		}
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

func filepathBase(path string) string {
	if path == "" {
		return "untitled"
	}
	return filepath.Base(path)
}
