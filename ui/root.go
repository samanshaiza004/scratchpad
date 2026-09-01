package ui

import (
	"context"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

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
					emptyState(state, shell, theme)
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
	ShowGoToLine       bool
	ShowRecent         bool
	ShowSearch         bool
	SidebarVisible     bool
	SidebarInitialized bool
	WorkspaceWasOpen   bool
	FindEpoch          uint64
	QuickOpenEpoch     uint64
	OpenEpoch          uint64
	FilePath           string
	FindQuery          string
	GoToLineText       string
	GoToLineError      string
	SaveAsPath         string
	ClosePending       application.DocumentID
	ShowCompare        bool
	PathPicker         folderPickerState
	FolderPicker       folderPickerState // compatibility alias for existing tests
	SidebarMode        SidebarMode
	Tree               treeState
	ContextMenu        contextMenuState
	CloseQueue         []application.DocumentID
	RevealPath         func(string) error
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

type contextMenuKind uint8

const (
	contextMenuTab contextMenuKind = iota
	contextMenuTree
)

type contextMenuState struct {
	Open       bool
	Generation uint64
	MenuID     ContainerId
	Kind       contextMenuKind
	ID         application.DocumentID
	Path       string
	IsDir      bool
	Position   Vec2
}

type closeDecision uint8

const (
	closePrompt closeDecision = iota
	closeSave
	closeDiscard
)

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
			if MenuItem(NoIcon, "Open Recent") {
				executeCommand(state, shell, commands.FileOpenRecent)
			}
			if MenuItem(NoIcon, "Reopen Closed") {
				executeCommand(state, shell, commands.DocumentReopenClosed)
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
			if MenuItem(NoIcon, "Go to Line…") {
				executeCommand(state, shell, commands.DocumentGoToLine)
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
	tree := &shell.Tree
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
			outlinePanel(state, shell, theme)
			return
		}
		if shell.ShowSearch {
			workspaceSearchPanel(state, shell, theme)
		}
		Container(Attrs(Viewport, Grow(1), Expand, Clip, Pad2(6, 4)), func() {
			ScrollOnInput()
			renderTreeWithShell(state, tree, shell, "", 0, theme)
			ScrollBars()
		})
	})
}

func outlinePanel(state *application.Application, shell *workbenchState, theme Theme) {
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
				outlineLink(state, shell, doc, link, doc.Projections.Valid, theme)
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

func outlineLink(state *application.Application, shell *workbenchState, doc *document.Document, link document.Link, enabled bool, theme Theme) {
	Container(Attrs(Row, FixHeight(24), Expand, Pad2(0, 10), Gap(4)), func() {
		button := ProcessButtonEvents(enabled)
		Label(link.Label, FontSize(11), TextColorVec(theme.Ink))
		if button.Clicked && enabled {
			doc.Editor.SetCursor(link.StartByte)
		}
		if CtrlButton(NoIcon, "Open", enabled) && enabled {
			openLinkTarget(state, shell, doc, link.Target)
		}
	})
}

func openLinkTarget(state *application.Application, shell *workbenchState, doc *document.Document, target string) {
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
	if !isWindowsFilePath(target) && parsed.Path == "" && parsed.Fragment != "" {
		jumpToHeadingID(doc, parsed.Fragment)
		return
	}
	if !isWindowsFilePath(target) && parsed.Path == "" {
		return
	}
	path, err := resolveLocalLinkPath(doc.Path, target)
	if err != nil {
		return
	}
	if executeCommand(state, shell, commands.FileOpen, path) && !isWindowsFilePath(target) && parsed.Fragment != "" {
		jumpToHeadingID(state.ActiveDocument(), parsed.Fragment)
	}
}

func resolveLocalLinkPath(documentPath, target string) (string, error) {
	if isWindowsFilePath(target) {
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

func isWindowsFilePath(target string) bool {
	if strings.HasPrefix(target, `\\`) || strings.HasPrefix(target, "//") {
		return true
	}
	return len(target) >= 3 && ((target[0] >= 'a' && target[0] <= 'z') || (target[0] >= 'A' && target[0] <= 'Z')) && target[1] == ':' && (target[2] == '\\' || target[2] == '/')
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
	shell := &workbenchState{Tree: *tree}
	renderTreeWithShell(state, &shell.Tree, shell, relative, depth, theme)
	*tree = shell.Tree
}

func renderTreeWithShell(state *application.Application, tree *treeState, shell *workbenchState, relative string, depth int, theme Theme) {
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
				secondaryClick := GetFrameInput().Mouse == MouseClick && GetInputState().MouseButton == MouseSecondary
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
					if secondaryClick && button.Hovered {
						openTreeContextMenu(shell, filepath.Join(state.Workspace.Root, entry.Path), true)
					} else if button.Clicked {
						executeCommand(state, shell, commands.WorkspaceToggleFolder, entry.Path)
					}
					return
				}
				marker := "  "
				if isActivePath(state, filepath.Join(state.Workspace.Root, entry.Path)) {
					marker = "● "
				}
				Label(marker+entry.Name, FontSize(12), TextColorVec(theme.Ink))
				if secondaryClick && button.Hovered {
					openTreeContextMenu(shell, filepath.Join(state.Workspace.Root, entry.Path), false)
				} else if button.Clicked {
					executeCommand(state, shell, commands.FileOpen, filepath.Join(state.Workspace.Root, entry.Path))
				}
			})
			tree.RowIDs[entry.Path] = rowID
			if entry.Dir && tree.Expanded[entry.Path] {
				renderTreeWithShell(state, tree, shell, entry.Path, depth+1, theme)
			}
		})
	}
}

func emptyState(state *application.Application, shell *workbenchState, theme Theme) {
	Container(Attrs(Grow(1), Expand, Center, BackgroundVec(theme.Paper), Pad(28)), func() {
		Container(Attrs(FixWidth(560), Gap(8)), func() {
			Label("A quiet place for files, notes, and code.", FontWeight(WeightBold), FontSize(20), TextColorVec(theme.Ink))
			Label("Open a file for a focused editor, or a folder for the workspace tree.", FontSize(13), TextColorVec(theme.Muted))
			Container(Attrs(Row, Gap(8)), func() {
				if CtrlButton(NoIcon, "Open…", true) {
					executeCommand(state, shell, commands.FileOpen)
				}
				if CtrlButton(NoIcon, "Quick open", true) {
					executeCommand(state, shell, commands.QuickOpen)
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
				secondaryClick := GetFrameInput().Mouse == MouseClick && GetInputState().MouseButton == MouseSecondary
				middleClick := GetFrameInput().Mouse == MouseClick && GetInputState().MouseButton == MouseTertiary
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
						executeCommand(state, shell, commands.DocumentClose, id)
					}
				})
				if middleClick && button.Hovered {
					executeCommand(state, shell, commands.DocumentClose, id)
				} else if secondaryClick && button.Hovered {
					openTabContextMenu(shell, id, doc.Path)
				} else if button.Clicked {
					executeCommand(state, shell, commands.DocumentActivate, id)
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
			TextInputExt(&shell.FindQuery, input)
		})
		search.Current = nil
		if state.Active != "" && shell.FindQuery != "" {
			search.Current = state.FindCurrent(state.Active, []byte(shell.FindQuery))
			Label(fmt.Sprintf("%d matches", len(search.Current)), FontSize(10), TextColorVec(theme.Muted))
		}
		Container(Attrs(Grow(1)), func() {})
		if CtrlButton(NoIcon, "Close", true) {
			shell.ShowFind = false
		}
	})
	if len(search.Current) > 0 && GetFrameInput().Key == KeyEnter {
		if GetInputState().Modifiers&ModShift != 0 {
			executeCommand(state, shell, commands.DocumentFindPrevious)
		} else {
			executeCommand(state, shell, commands.DocumentFindNext)
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
		if CtrlButton(NoIcon, "Save and close", true) {
			executeCommand(state, shell, commands.DocumentClose, shell.ClosePending, closeSave)
		}
		if CtrlButton(NoIcon, "Discard", true) {
			executeCommand(state, shell, commands.DocumentClose, shell.ClosePending, closeDiscard)
		}
		if CtrlButton(NoIcon, "Cancel", true) {
			shell.ClosePending = ""
			shell.CloseQueue = nil
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
				if executeCommand(state, shell, commands.FileOpen, filepath.Clean(shell.FolderPicker.Result)) {
					shell.ShowFolder = false
				}
			}
		})
	}
	if shell.ShowOpen {
		Modal(620, func() { shell.ShowOpen = false; shell.ShowFolder = false }, func() {
			Label("Open file or folder", FontWeight(WeightBold), FontSize(14), TextColorVec(theme.Ink))
			ContainerWithKey(fmt.Sprintf("open-picker-%d", shell.OpenEpoch), Attrs(), func() {
				if FileBrowserPanel(&shell.PathPicker.Cwd, &shell.PathPicker.Filter, &shell.PathPicker.Selected, &shell.PathPicker.Result, FileBrowserAttrs{Title: "Open", Dirs: true, Files: true, Start: shell.PathPicker.Cwd, Width: 580, ShowHidden: true}) {
					if executeCommand(state, shell, commands.FileOpen, filepath.Clean(shell.PathPicker.Result)) {
						shell.ShowOpen = false
						shell.ShowFolder = false
					}
				}
			})
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
	if shell.ShowRecent {
		recentPopup(state, shell, theme)
	}
	if shell.ShowGoToLine {
		Modal(420, func() { shell.ShowGoToLine = false }, func() {
			Label("Go to Line", FontWeight(WeightBold), FontSize(14), TextColorVec(theme.Ink))
			field := DefaultTextInputAttrs()
			field.MinWidth = 360
			TextInputExt(&shell.GoToLineText, field)
			if shell.GoToLineError != "" {
				Label(shell.GoToLineError, FontSize(11), TextColorVec(theme.Warning))
			}
			Container(Attrs(Row, Gap(6)), func() {
				if Button(NoIcon, "Go") {
					executeCommand(state, shell, commands.DocumentGoToLine, shell.GoToLineText)
				}
				if Button(NoIcon, "Cancel") {
					shell.ShowGoToLine = false
				}
			})
			if GetFrameInput().Key == KeyEnter {
				executeCommand(state, shell, commands.DocumentGoToLine, shell.GoToLineText)
				GetFrameInput().Key = KeyCodeNone
			}
		})
	}
	contextMenu(state, shell, theme)
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
					if executeCommand(state, shell, commands.FileOpen, quick.Result) {
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
	ClearFocus()
	shell.PathPicker = folderPickerState{Cwd: start, Selected: -1}
	shell.OpenEpoch++
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
	ClearFocus()
	shell.FolderPicker = folderPickerState{Cwd: start, Selected: -1}
	shell.ShowFolder = true
}

func folderPickerPanel(shell *workbenchState) bool {
	return FileBrowserPanel(&shell.FolderPicker.Cwd, &shell.FolderPicker.Filter, &shell.FolderPicker.Selected, &shell.FolderPicker.Result, FileBrowserAttrs{Title: "Open folder", Dirs: true, Width: 520, ShowHidden: true})
}

func requestClose(state *application.Application, shell *workbenchState, id application.DocumentID) {
	shell.CloseQueue = nil
	requestNextClose(state, shell, id)
}

func requestNextClose(state *application.Application, shell *workbenchState, id application.DocumentID) {
	if state.Status(id) == application.StatusSynced {
		_ = state.CloseDocument(id, false)
		return
	}
	shell.ClosePending = id
}

func requestCloseMany(state *application.Application, shell *workbenchState, ids []application.DocumentID) {
	shell.CloseQueue = append([]application.DocumentID(nil), ids...)
	continueCloseQueue(state, shell)
}

func continueCloseQueue(state *application.Application, shell *workbenchState) {
	if shell.ClosePending != "" || len(shell.CloseQueue) == 0 {
		return
	}
	id := shell.CloseQueue[0]
	shell.CloseQueue = shell.CloseQueue[1:]
	requestNextClose(state, shell, id)
	if shell.ClosePending == "" {
		continueCloseQueue(state, shell)
	}
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
		case KeyG:
			executeCommand(state, shell, commands.DocumentGoToLine)
		default:
			return
		}
		frame.Key = KeyCodeNone
		return
	}
	if mods == 0 && frame.Key == KeyF3 {
		executeCommand(state, shell, commands.DocumentFindNext)
		frame.Key = KeyCodeNone
		return
	}
	if mods == ModShift && frame.Key == KeyF3 {
		executeCommand(state, shell, commands.DocumentFindPrevious)
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

func executeCommand(state *application.Application, shell *workbenchState, id commands.ID, args ...any) bool {
	if strings.HasPrefix(string(id), string(commands.FileOpenRecent)+":") {
		path, err := url.QueryUnescape(strings.TrimPrefix(string(id), string(commands.FileOpenRecent)+":"))
		if err == nil {
			return executeCommand(state, shell, commands.FileOpenRecent, path)
		}
		return false
	}
	switch id {
	case commands.FileOpen:
		if path := explicitCommandPath(args); path != "" {
			return state.OpenPath(path) == nil
		}
		openPathPicker(state, shell)
		return true
	case commands.FileSave:
		_ = state.SaveActive()
	case commands.FileSaveAs:
		if doc := state.ActiveDocument(); doc != nil {
			shell.SaveAsPath = doc.Path
			shell.ShowSaveAs = true
		}
	case commands.DocumentFind:
		if !shell.ShowFind {
			ClearFocus()
			shell.FindEpoch++
		}
		shell.ShowFind = true
		shell.ShowSearch = false
	case commands.QuickOpen:
		if !shell.ShowQuickOpen {
			ClearFocus()
			shell.QuickOpenEpoch++
		}
		shell.ShowQuickOpen = true
		shell.ShowFind = false
	case commands.WorkspaceSearch:
		shell.ShowSearch = true
		shell.ShowFind = false
	case commands.DocumentClose:
		target := commandDocumentID(state, args)
		if target == "" {
			target = state.Active
		}
		if target != "" {
			decision := closePrompt
			if len(args) > 1 {
				decision, _ = args[1].(closeDecision)
			}
			if decision == closeSave {
				if err := state.SaveDocument(target); err != nil {
					return false
				}
			} else if decision == closeDiscard {
				if err := state.CloseDocument(target, true); err != nil {
					return false
				}
				shell.ClosePending = ""
				continueCloseQueue(state, shell)
				return true
			}
			if decision == closeSave {
				if err := state.CloseDocument(target, false); err != nil {
					return false
				}
				shell.ClosePending = ""
				continueCloseQueue(state, shell)
				return true
			}
			requestClose(state, shell, target)
		}
	case commands.DocumentActivate:
		if target := commandDocumentID(state, args); target != "" {
			state.Activate(target)
		}
	case commands.DocumentCloseOthers:
		target := commandDocumentID(state, args)
		if target == "" {
			target = state.Active
		}
		var ids []application.DocumentID
		for _, id := range state.Order {
			if id != target {
				ids = append(ids, id)
			}
		}
		requestCloseMany(state, shell, ids)
	case commands.DocumentCloseAll:
		requestCloseMany(state, shell, append([]application.DocumentID(nil), state.Order...))
	case commands.DocumentReopenClosed:
		_ = state.ReopenClosed()
	case commands.DocumentGoToLine:
		spec := commandString(args)
		if spec == "" {
			ClearFocus()
			shell.ShowGoToLine = true
			shell.GoToLineError = ""
			return true
		}
		if doc := state.ActiveDocument(); doc != nil {
			if err := moveToLine(doc, spec); err != nil {
				shell.ShowGoToLine = true
				shell.GoToLineError = err.Error()
				return false
			}
			shell.ShowGoToLine = false
			shell.GoToLineError = ""
		}
	case commands.DocumentFindNext:
		findCurrent(state, shell, false)
	case commands.DocumentFindPrevious:
		findCurrent(state, shell, true)
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
		shell.Tree.Expanded = make(map[string]bool)
	case commands.WorkspaceToggleFolder:
		if relative := commandString(args); relative != "" {
			tree := &shell.Tree
			if tree.Expanded == nil {
				tree.Expanded = make(map[string]bool)
			}
			tree.Expanded[relative] = !tree.Expanded[relative]
		}
	case commands.FileOpenRecent:
		if path := explicitCommandPath(args); path != "" {
			if state.OpenPath(path) == nil {
				shell.ShowRecent = false
				return true
			}
		} else {
			shell.ShowRecent = true
			shell.ShowQuickOpen = false
			shell.ShowFind = false
			return true
		}
	case commands.FileCopyPath:
		if path := commandPath(state, args); path != "" {
			RequestTextCopy(path)
		}
	case commands.FileCopyRelativePath:
		if path := commandPath(state, args); path != "" {
			RequestTextCopy(relativePath(state, path))
		}
	case commands.FileReveal:
		if path := commandPath(state, args); path != "" {
			reveal := shell.RevealPath
			if reveal == nil {
				reveal = revealPath
			}
			_ = reveal(path)
		}
	case commands.FileRevealActive:
		revealActiveFile(state, shell)
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
	return false
}

func commandString(args []any) string {
	if len(args) == 0 {
		return ""
	}
	if value, ok := args[0].(string); ok {
		return value
	}
	return ""
}

func commandDocumentID(state *application.Application, args []any) application.DocumentID {
	if len(args) == 0 {
		return ""
	}
	switch value := args[0].(type) {
	case application.DocumentID:
		if state.Documents[value] != nil {
			return value
		}
	case string:
		for id, doc := range state.Documents {
			if doc.Path == value {
				return id
			}
		}
	}
	return ""
}

func explicitCommandPath(args []any) string {
	if len(args) > 0 {
		if value, ok := args[0].(string); ok && value != "" {
			return filepath.Clean(value)
		}
	}
	return ""
}

func commandPath(state *application.Application, args []any) string {
	if path := explicitCommandPath(args); path != "" {
		return path
	}
	if doc := state.ActiveDocument(); doc != nil {
		return doc.Path
	}
	return ""
}

func relativePath(state *application.Application, path string) string {
	if state.HasWorkspace {
		if relative, err := state.Workspace.RelativePath(path); err == nil {
			return relative
		}
		return path
	}
	return filepath.Base(path)
}

func moveToLine(doc *document.Document, spec string) error {
	parts := strings.FieldsFunc(strings.TrimSpace(spec), func(r rune) bool { return r == ':' || r == ',' })
	if len(parts) == 0 || len(parts) > 2 {
		return fmt.Errorf("enter a line or line:column")
	}
	line, err := strconv.Atoi(parts[0])
	if err != nil || line < 1 {
		return fmt.Errorf("line must be a positive number")
	}
	column := 1
	if len(parts) == 2 {
		column, err = strconv.Atoi(parts[1])
		if err != nil || column < 1 {
			return fmt.Errorf("column must be a positive number")
		}
	}
	line--
	start, end, ok := doc.Editor.Buffer.LineRange(line)
	if !ok {
		return fmt.Errorf("line %d is outside this document", line+1)
	}
	data, err := doc.Editor.Buffer.Bytes(start, end)
	if err != nil {
		return err
	}
	offset := start
	for n := 1; n < column && offset-start < len(data); n++ {
		_, size := utf8.DecodeRune(data[offset-start:])
		if size == 0 {
			break
		}
		offset += size
	}
	doc.Editor.SetCursor(offset)
	return nil
}

func findCurrent(state *application.Application, shell *workbenchState, previous bool) {
	shell.ShowFind = true
	if shell.FindQuery == "" || state.ActiveDocument() == nil {
		return
	}
	doc := state.ActiveDocument()
	matches := state.FindCurrent(state.Active, []byte(shell.FindQuery))
	if len(matches) == 0 {
		return
	}
	anchor, cursor := doc.Editor.Selection()
	from, to := anchor, cursor
	if from > to {
		from, to = to, from
	}
	target := matches[0]
	if previous {
		target = matches[len(matches)-1]
		for i := len(matches) - 1; i >= 0; i-- {
			if matches[i].Start < from {
				target = matches[i]
				break
			}
		}
	} else {
		for _, match := range matches {
			if match.Start >= to {
				target = match
				break
			}
		}
	}
	doc.Editor.SetSelection(target.Start, target.End)
}

func openTreeContextMenu(shell *workbenchState, path string, isDir bool) {
	shell.ContextMenu = contextMenuState{
		Open: true, Generation: shell.ContextMenu.Generation + 1,
		Kind: contextMenuTree, Path: path, IsDir: isDir, Position: GetInputState().MousePoint,
	}
}

func openTabContextMenu(shell *workbenchState, id application.DocumentID, path string) {
	shell.ContextMenu = contextMenuState{
		Open: true, Generation: shell.ContextMenu.Generation + 1,
		Kind: contextMenuTab, ID: id, Path: path, Position: GetInputState().MousePoint,
	}
}

func contextMenuItem(label string) bool {
	var clicked bool
	Container(Attrs(Row, Expand, CrossMid, FixHeight(26), Pad2(0, 10)), func() {
		button := ProcessButtonEvents(false)
		if button.Hovered {
			ModAttrs(BackgroundVec(DefaultTheme().Highlight))
		}
		Label(label, FontSize(12), TextColorVec(DefaultTheme().Ink))
		clicked = button.Clicked && GetInputState().MouseButton == MousePrimary
	})
	return clicked
}

func contextMenu(state *application.Application, shell *workbenchState, theme Theme) {
	menu := shell.ContextMenu
	if !menu.Open {
		return
	}
	Popup(func() {
		var menuID ContainerId
		ContainerWithKey(fmt.Sprintf("context-menu-%d", menu.Generation), Attrs(FixWidth(260), Gap(1), Pad(6), BackgroundVec(theme.Raised), BorderWidth(1), BorderColorVec(theme.Border), Corners(3), Clip), func() {
			ModAttrs(FloatVec(menu.Position))
			menuID = CurrentId()
			shell.ContextMenu.MenuID = menuID
			if menu.Kind == contextMenuTab {
				if contextMenuItem("Close") {
					executeCommand(state, shell, commands.DocumentClose, menu.ID)
					shell.ContextMenu.Open = false
				}
				if contextMenuItem("Close Others") {
					executeCommand(state, shell, commands.DocumentCloseOthers, menu.ID)
					shell.ContextMenu.Open = false
				}
				if contextMenuItem("Close All") {
					executeCommand(state, shell, commands.DocumentCloseAll)
					shell.ContextMenu.Open = false
				}
				if contextMenuItem("Reopen Closed") {
					executeCommand(state, shell, commands.DocumentReopenClosed)
					shell.ContextMenu.Open = false
				}
			} else if menu.IsDir {
				label := "Expand"
				if shell.Tree.Expanded[workspaceRelative(state, menu.Path)] {
					label = "Collapse"
				}
				if contextMenuItem(label) {
					executeCommand(state, shell, commands.WorkspaceToggleFolder, workspaceRelative(state, menu.Path))
					shell.ContextMenu.Open = false
				}
			} else if contextMenuItem("Open") {
				executeCommand(state, shell, commands.FileOpen, menu.Path)
				shell.ContextMenu.Open = false
			}
			if contextMenuItem("Copy Path") {
				executeCommand(state, shell, commands.FileCopyPath, menu.Path)
				shell.ContextMenu.Open = false
			}
			if contextMenuItem("Copy Relative Path") {
				executeCommand(state, shell, commands.FileCopyRelativePath, menu.Path)
				shell.ContextMenu.Open = false
			}
			if contextMenuItem("Reveal") {
				executeCommand(state, shell, commands.FileReveal, menu.Path)
				shell.ContextMenu.Open = false
			}
		})
		if GetFrameInput().Mouse == MouseClick && GetInputState().MouseButton == MousePrimary && !IdIsHovered(menuID) {
			shell.ContextMenu.Open = false
		}
	})
}

func workspaceRelative(state *application.Application, path string) string {
	if state.HasWorkspace {
		if relative, err := state.Workspace.RelativePath(path); err == nil {
			return relative
		}
	}
	return filepath.Base(path)
}

func recentPopup(state *application.Application, shell *workbenchState, theme Theme) {
	Popup(func() {
		var popupID ContainerId
		ContainerWithKey("recent-files-popup", Attrs(FixWidth(360), Gap(1), Pad(6), BackgroundVec(theme.Raised), BorderWidth(1), BorderColorVec(theme.Border), Corners(3), Clip), func() {
			ModAttrs(Float(8, 38))
			popupID = CurrentId()
			Label("Open Recent", FontWeight(WeightBold), FontSize(12), TextColorVec(theme.Ink))
			paths := state.RecentPaths()
			if len(paths) == 0 {
				Label("No recent files", FontSize(11), TextColorVec(theme.Muted))
			}
			for _, path := range paths {
				path := path
				if contextMenuItem(filepathBase(path)) {
					executeCommand(state, shell, commands.FileOpenRecent, path)
					shell.ShowRecent = false
				}
			}
		})
		if GetFrameInput().Mouse == MouseClick && GetInputState().MouseButton == MousePrimary && !IdIsHovered(popupID) {
			shell.ShowRecent = false
		}
	})
}

func revealActiveFile(state *application.Application, shell *workbenchState) {
	if !state.HasWorkspace {
		return
	}
	doc := state.ActiveDocument()
	if doc == nil {
		return
	}
	relative, err := state.Workspace.RelativePath(doc.Path)
	if err != nil {
		return
	}
	tree := &shell.Tree
	if tree.Expanded == nil {
		tree.Expanded = make(map[string]bool)
	}
	for dir := filepath.Dir(relative); dir != "." && dir != ""; dir = filepath.Dir(dir) {
		tree.Expanded[dir] = true
	}
	shell.SidebarMode = SidebarFiles
	shell.SidebarVisible = true
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
