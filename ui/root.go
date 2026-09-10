package ui

import (
	"context"
	"errors"
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
	"scratchpad/language"
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
	installWorkstationChrome()
	state.PollWatcher()
	state.ReconcileStale()
	state.PollDerived(time.Now())
	state.MaybeWriteRecovery(state.RecoveryDir)

	shell := Use[workbenchState]("workbench")
	loadUserSettings(shell)
	if shell.EditorFontSize <= 0 {
		shell.EditorFontSize = defaultEditorFontSize
	}
	lineNumbersEnabled(shell)
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
		Container(Attrs(Row, Grow(1), Expand, Gap(0)), func() {
			if shell.SidebarVisible && (state.HasWorkspace || shell.SidebarMode == SidebarOutline) {
				sidebar(state, shell, theme)
				EtchedDivider(theme, dividerVertical)
			}
			Container(Attrs(Grow(1), Expand, Gap(0), Clip, BackgroundVec(theme.Chrome)), func() {
				if shell.ShowSettings {
					settingsSurface(state, shell, theme)
					return
				}
				if len(state.Order) == 0 {
					emptyState(state, shell, theme)
					return
				}
				if len(state.Order) > 1 {
					tabs(state, shell, theme)
				}
				findBar(state, shell, theme)
				saveNoticePanel(shell, theme)
				conflictPanel(state, shell, theme)
				closePanel(state, shell, theme)
				if doc := state.ActiveDocument(); doc != nil {
					id := state.Active
					view := state.Views[id]
					if view.LastRevision != 0 && view.LastRevision != doc.Revision() {
						view.CollapsedHeadings = nil
					}
					rows := rowMapForDocument(doc, view)
					style := EditorTextStyleForDocument(doc)
					style.FontSize = editorFontSize(shell)
					PaperWell(theme, Attrs(Grow(1), Expand, Clip), Attrs(Clip), func() {
						EditableDocumentView(id, doc, EditorViewOptions{
							Style: style, RowHeight: editorRowHeight(style.FontSize), Wrap: wrapEnabled(shell, doc), ScrollY: &view.ScrollY,
							ScrollInitialized:  view.ScrollInitialized,
							ScrollX:            &view.ScrollX,
							ScrollXInitialized: view.ScrollXInitialized,
							LineNumbers:        lineNumbersEnabled(shell),
							Rows:               &rows,
							LineDecoration:     markdownLineDecoration(doc, theme),
							LineSpacing:        markdownLineSpacing(doc),
							Foldable:           func(line int) bool { return foldForLine(doc, line) != nil },
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
					view.ScrollXInitialized = true
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
	ShowReplace        bool
	ShowGoToLine       bool
	ShowRecent         bool
	ShowSearch         bool
	ShowSettings       bool
	Mutation           workspaceMutationState
	TrashConfirmation  workspaceTrashConfirmation
	SidebarVisible     bool
	EditorFontSize     float32
	LineNumbers        bool
	LineNumbersSet     bool
	WrapOverrides      map[application.DocumentID]bool
	SidebarInitialized bool
	WorkspaceWasOpen   bool
	FindEpoch          uint64
	QuickOpenEpoch     uint64
	OpenEpoch          uint64
	FilePath           string
	FindQuery          string
	ReplaceQuery       string
	findMatches        []application.CurrentMatch
	findDocument       application.DocumentID
	findEditor         *editor.ScratchEditor
	findRevision       uint64
	findMatchesQuery   string
	findMatchesValid   bool
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
	TabIDs             map[application.DocumentID]ContainerId // transient handles used by interaction tests
	TabCloseIDs        map[application.DocumentID]ContainerId // transient handles used by interaction tests
	Slash              slashState
	Fence              fenceState
	PendingSmartPaste  bool
	UserSettingsLoaded bool
	UserSettingsPath   string
	UserSettingsError  string

	SaveAsError             string
	SaveNotice              string
	ShowSaveAsOverwrite     bool
	SaveAsOverwriteDocument application.DocumentID
	SaveAsOverwritePath     string
	SaveAsOverwriteVersion  workspace.DiskVersion
}

type workspaceMutationKind uint8

const (
	mutationNewFile workspaceMutationKind = iota
	mutationNewFolder
	mutationRename
	mutationMove
)

type workspaceMutationState struct {
	Open       bool
	Kind       workspaceMutationKind
	Path       string
	Text       string
	Error      string
	Generation uint64
}

type workspaceTrashConfirmation struct {
	Open  bool
	Path  string
	Error string
}

type SidebarMode uint8

const (
	defaultEditorFontSize float32 = 16
	minEditorFontSize     float32 = 8
	maxEditorFontSize     float32 = 48
	editorFontSizeStep    float32 = 1
)

const (
	viewToggleLineNumbers commands.ID = "view.toggle-line-numbers"
	viewToggleWrap        commands.ID = "view.toggle-wrap"
)

func lineNumbersEnabled(shell *workbenchState) bool {
	if shell == nil {
		return true
	}
	if !shell.LineNumbersSet {
		shell.LineNumbers = true
		shell.LineNumbersSet = true
	}
	return shell.LineNumbers
}

func toggleLineNumbers(shell *workbenchState) {
	if shell == nil {
		return
	}
	lineNumbersEnabled(shell)
	shell.LineNumbers = !shell.LineNumbers
	persistUserSettings(shell)
}

func wrapEnabled(shell *workbenchState, doc *document.Document) bool {
	if doc == nil {
		return false
	}
	if shell != nil && shell.WrapOverrides != nil {
		if enabled, ok := shell.WrapOverrides[stateDocumentID(doc)]; ok {
			return enabled
		}
	}
	return proseWraps(doc.Path)
}

func toggleWrap(shell *workbenchState, doc *document.Document) {
	if shell == nil || doc == nil {
		return
	}
	if shell.WrapOverrides == nil {
		shell.WrapOverrides = make(map[application.DocumentID]bool)
	}
	id := stateDocumentID(doc)
	shell.WrapOverrides[id] = !wrapEnabled(shell, doc)
	persistUserSettings(shell)
}

// stateDocumentID is only used for the UI-local wrap preference. Document IDs
// are path-derived in Application, so matching by path keeps this helper
// independent of application internals while retaining the preference per tab.
func stateDocumentID(doc *document.Document) application.DocumentID {
	if doc == nil {
		return ""
	}
	path, err := filepath.Abs(doc.Path)
	if err != nil {
		return application.DocumentID(filepath.Clean(doc.Path))
	}
	path = filepath.Clean(path)
	if resolved, err := filepath.EvalSymlinks(path); err == nil {
		path = filepath.Clean(resolved)
	}
	return application.DocumentID(path)
}

func editorFontSize(shell *workbenchState) float32 {
	if shell == nil || shell.EditorFontSize <= 0 {
		return defaultEditorFontSize
	}
	return clampEditorFontSize(shell.EditorFontSize)
}

func clampEditorFontSize(size float32) float32 {
	if size < minEditorFontSize {
		return minEditorFontSize
	}
	if size > maxEditorFontSize {
		return maxEditorFontSize
	}
	return size
}

func adjustEditorFontSize(size float32, delta int) float32 {
	if size <= 0 {
		size = defaultEditorFontSize
	}
	size = clampEditorFontSize(size)
	return clampEditorFontSize(size + float32(delta)*editorFontSizeStep)
}

func editorRowHeight(fontSize float32) float32 {
	if fontSize <= 0 {
		fontSize = defaultEditorFontSize
	}
	return clampEditorFontSize(fontSize) * 1.5
}

func setEditorFontSize(state *application.Application, shell *workbenchState, size float32) {
	if shell == nil {
		return
	}
	shell.EditorFontSize = clampEditorFontSize(size)
	persistUserSettings(shell)
	if state != nil {
		for _, doc := range state.Documents {
			if doc == nil {
				continue
			}
			doc.Editor.ClearPreferredVerticalX()
		}
	}
}

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
	Open          bool
	Generation    uint64
	MenuID        ContainerId
	Kind          contextMenuKind
	ID            application.DocumentID
	Path          string
	IsDir         bool
	WorkspaceRoot bool
	Position      Vec2
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

type slashState struct {
	Open         bool
	Query        string
	TriggerStart int
	TriggerEnd   int
	Selected     int
	DocumentID   application.DocumentID
}

type fenceState struct {
	Open       bool
	Selected   int
	DocumentID application.DocumentID
}

type slashCommand struct {
	ID   commands.ID
	Name string
	Hint string
}

func markdownSlashCommands() []slashCommand {
	return []slashCommand{
		{commands.MarkdownToggleStrong, "bold", "strong text"},
		{commands.MarkdownToggleEmphasis, "italic", "emphasis"},
		{commands.MarkdownToggleStrike, "strike", "strikethrough"},
		{commands.MarkdownToggleInlineCode, "code", "inline code"},
		{commands.MarkdownInsertLink, "link", "link"},
		{commands.MarkdownHeading1, "heading 1", "level-one heading"},
		{commands.MarkdownHeading2, "heading 2", "level-two heading"},
		{commands.MarkdownHeading3, "heading 3", "level-three heading"},
		{commands.MarkdownToggleBulletedList, "bullet", "bulleted list"},
		{commands.MarkdownToggleNumberedList, "number", "numbered list"},
		{commands.MarkdownToggleQuote, "quote", "blockquote"},
		{commands.MarkdownInsertTask, "task", "task item"},
		{commands.MarkdownInsertCodeBlock, "code block", "fenced code block"},
		{commands.MarkdownInsertTable, "table", "table"},
		{commands.MarkdownInsertDivider, "divider", "horizontal rule"},
	}
}

const (
	slashCommandRowHeight      float32 = 25
	slashCommandViewportHeight float32 = 300
)

// revealPopupSelection keeps a keyboard-selected row reachable in a bounded
// Shirei viewport. Render data is the source of truth for the row geometry;
// this avoids duplicating the viewport's scroll math in the slash picker.
func revealPopupSelection(viewportID, rowID ContainerId) {
	if viewportID == nil || rowID == nil {
		return
	}
	viewport := GetRenderDataOf(viewportID)
	row := GetRenderDataOf(rowID)
	if viewport.ResolvedSize[1] <= 0 || row.ResolvedSize[1] <= 0 {
		return
	}

	top := row.ResolvedOrigin[1] - viewport.ResolvedOrigin[1] + viewport.ScrollOffset[1]
	bottom := top + row.ResolvedSize[1]
	offset := viewport.ScrollOffset
	if top < offset[1] {
		offset[1] = top
	} else if bottom > offset[1]+viewport.ResolvedSize[1] {
		offset[1] = bottom - viewport.ResolvedSize[1]
	}
	if offset != viewport.ScrollOffset {
		SetScrollOffset(offset)
		RequestNextFrame()
	}
}

func markdownFenceLanguages() []string {
	return []string{"plain", "go", "javascript", "typescript", "tsx"}
}

func menuBar(state *application.Application, shell *workbenchState, theme Theme) {
	if nativeMenuBar(state, shell) {
		return
	}
	Container(Attrs(FixHeight(36), Expand, NoAnimate), func() {
		ChromeBar(theme, Attrs(Row, CrossMid, FixHeight(34), Pad2(0, 8), Gap(2)), func() {
			WorkstationMenuButton(theme, "File", func() {
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
			WorkstationMenuButton(theme, "Edit", func() {
				if MenuItem(NoIcon, "Find…    "+primaryShortcut("F")) {
					executeCommand(state, shell, commands.DocumentFind)
				}
				if MenuItem(NoIcon, "Find and Replace…    "+primaryShortcut("H")) {
					executeCommand(state, shell, commands.DocumentFindReplace)
				}
				if MenuItem(NoIcon, "Join Lines") {
					executeCommand(state, shell, commands.EditJoinLines)
				}
				if MenuItem(NoIcon, "Find in Files…    "+primaryShortcut("Shift+F")) {
					executeCommand(state, shell, commands.WorkspaceSearch)
				}
			})
			if doc := state.ActiveDocument(); doc != nil && doc.RootLanguage == string(language.Markdown) {
				WorkstationMenuButton(theme, "Markdown", func() {
					if MenuItem(NoIcon, "Bold    "+primaryShortcut("B")) {
						executeCommand(state, shell, commands.MarkdownToggleStrong)
					}
					if MenuItem(NoIcon, "Italic    "+primaryShortcut("I")) {
						executeCommand(state, shell, commands.MarkdownToggleEmphasis)
					}
					if MenuItem(NoIcon, "Strike") {
						executeCommand(state, shell, commands.MarkdownToggleStrike)
					}
					if MenuItem(NoIcon, "Inline code") {
						executeCommand(state, shell, commands.MarkdownToggleInlineCode)
					}
					if MenuItem(NoIcon, "Link    "+primaryShortcut("K")) {
						executeCommand(state, shell, commands.MarkdownInsertLink)
					}
					MenuSeparator()
					if MenuItem(NoIcon, "Heading 1") {
						executeCommand(state, shell, commands.MarkdownHeading1)
					}
					if MenuItem(NoIcon, "Heading 2") {
						executeCommand(state, shell, commands.MarkdownHeading2)
					}
					if MenuItem(NoIcon, "Heading 3") {
						executeCommand(state, shell, commands.MarkdownHeading3)
					}
					if MenuItem(NoIcon, "Task") {
						executeCommand(state, shell, commands.MarkdownInsertTask)
					}
					if MenuItem(NoIcon, "Code block") {
						executeCommand(state, shell, commands.MarkdownInsertCodeBlock)
					}
					if MenuItem(NoIcon, "Table") {
						executeCommand(state, shell, commands.MarkdownInsertTable)
					}
					if MenuItem(NoIcon, "Divider") {
						executeCommand(state, shell, commands.MarkdownInsertDivider)
					}
					if MenuItem(NoIcon, "Format table") {
						executeCommand(state, shell, commands.DocumentFormat)
					}
				})
			}
			WorkstationMenuButton(theme, "View", func() {
				if MenuItem(NoIcon, "Outline") {
					executeCommand(state, shell, commands.OutlineToggle)
				}
				if MenuItem(NoIcon, "Line Numbers") {
					executeCommand(state, shell, viewToggleLineNumbers)
				}
				if MenuItem(NoIcon, "Word Wrap") {
					executeCommand(state, shell, viewToggleWrap)
				}
				if MenuItem(NoIcon, "Increase Editor Font Size    "+primaryShortcut("+")) {
					executeCommand(state, shell, commands.ViewIncreaseFontSize)
				}
				if MenuItem(NoIcon, "Decrease Editor Font Size    "+primaryShortcut("-")) {
					executeCommand(state, shell, commands.ViewDecreaseFontSize)
				}
				if MenuItem(NoIcon, "Reset Editor Font Size    "+primaryShortcut("0")) {
					executeCommand(state, shell, commands.ViewResetFontSize)
				}
				if (state.HasWorkspace || state.ActiveDocument() != nil) && MenuItem(NoIcon, "Toggle Sidebar") {
					executeCommand(state, shell, commands.ViewToggleSidebar)
				}
				if state.HasWorkspace && MenuItem(NoIcon, "Refresh Workspace") {
					executeCommand(state, shell, commands.WorkspaceRefresh)
				}
			})
			WorkstationMenuButton(theme, "Go", func() {
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
			WorkstationMenuButton(theme, "Help", func() { MenuItem(NoIcon, "Scratchpad") })
			Container(Attrs(Grow(1)), func() {})
			Label(documentTitle(state), FontSize(12), FontWeight(WeightBold), TextColorVec(theme.Ink))
			if state.HasWorkspace {
				Label(filepath.Base(state.Workspace.Root), FontSize(11), TextColorVec(theme.Muted))
			}
		})
		EtchedDivider(theme, dividerHorizontal)
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
	Container(Attrs(FixWidth(248), Expand, Clip, BackgroundVec(theme.Sidebar), NoAnimate), func() {
		Container(Attrs(Row, CrossAlign(AlignEnd), FixHeight(34), Pad4(5, 8, 0, 8)), func() {
			WorkstationSegmentedControl(theme, &shell.SidebarMode, Cell("Files", SidebarFiles), Cell("Outline", SidebarOutline))
			Container(Attrs(Grow(1)), func() {})
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
			ContainerWithKey("workspace-tree-background", Attrs(Float(0, 0), FixSizeVec(GetContentRect().Size), Behind), func() {
				rootContextClick, rootContextGesture := contextMenuGestureWithHover(func() bool {
					return RectContainsPoint(GetScreenRect(), GetInputState().MousePoint) && !treeRowHovered(tree)
				})
				if rootContextClick {
					openWorkspaceContextMenu(shell, state.Workspace.Root)
				}
				if GetFrameInput().Mouse == MouseClick && GetInputState().MouseButton == MousePrimary &&
					!rootContextGesture && IsHoveredDirectly() {
					clearTreeSelection(tree)
					tree.MarqueeActive = true
					tree.MarqueeMoved = false
					tree.MarqueeStart = GetInputState().MousePoint
					tree.MarqueeCurrent = tree.MarqueeStart
				}
			})
			ContainerWithKey("workspace-root-drop", Attrs(FixHeight(22), Pad2(0, 6)), func() {
				if CanDropHere[treeDragPayload](treeDropTarget("")) {
					ModAttrs(BackgroundVec(theme.Selection))
				}
				Label("Workspace", FontSize(11), TextColorVec(theme.Muted))
			})
			renderTreeWithShell(state, tree, shell, "", 0, theme)
			if tree.MarqueeActive {
				tree.MarqueeCurrent = GetInputState().MousePoint
				delta := Vec2Sub(tree.MarqueeCurrent, tree.MarqueeStart)
				if absFloat(delta[0]) > 2 || absFloat(delta[1]) > 2 {
					tree.MarqueeMoved = true
				}
				updateTreeMarqueeSelection(tree)
				if GetFrameInput().Mouse == MouseRelease {
					tree.MarqueeActive = false
				}
			}
			if tree.MarqueeActive && tree.MarqueeMoved {
				selectionRect := treeMarqueeRect(tree.MarqueeStart, tree.MarqueeCurrent)
				surface := GetScreenRect()
				localOrigin := Vec2{selectionRect.Origin[0] - surface.Origin[0], selectionRect.Origin[1] - surface.Origin[1]}
				if selectionRect.Size[0] > 0 && selectionRect.Size[1] > 0 {
					fill := theme.Selection
					fill[3] *= 0.35
					Container(Attrs(FloatVec(localOrigin), FixSize(selectionRect.Size[0], selectionRect.Size[1]), InFront, BorderWidth(1), BorderColorVec(theme.Focus), BackgroundVec(fill)), func() {})
				}
			}
			ScrollBars()
		})
	})
}

func outlinePanel(state *application.Application, shell *workbenchState, theme Theme) {
	doc := state.ActiveDocument()
	if doc == nil {
		Container(Attrs(Grow(1), Pad(10)), func() { Label("Open a document to view its outline.", FontSize(11), TextColorVec(theme.Muted)) })
		return
	}
	if !outlineLanguageSupported(doc.RootLanguage) ||
		!application.AnalysisSupported(language.ID(doc.RootLanguage)) {
		Container(Attrs(Grow(1), Pad(10)), func() { Label("No outline available for this file type.", FontSize(11), TextColorVec(theme.Muted)) })
		return
	}
	if !doc.DerivedCurrent() {
		Container(Attrs(Grow(1), Pad(10)), func() { Label("Updating outline…", FontSize(11), TextColorVec(theme.Muted)) })
		return
	}
	Container(Attrs(Viewport, Grow(1), Expand, Clip, Pad2(6, 4)), func() {
		ScrollOnInput()
		if doc.RootLanguage != string(language.Markdown) {
			outlineCodeSymbols(doc, theme)
			ScrollBars()
			return
		}
		for _, heading := range doc.Projections.Headings {
			button := WorkstationRow(theme, Attrs(Row, FixHeight(24), Expand, Pad2(0, float32(8+heading.Level*10))), false, !doc.Projections.Valid, func() {
				Label(heading.Text, FontSize(11), TextColorVec(theme.Ink))
			})
			if button.Clicked && doc.Projections.Valid {
				doc.Editor.SetCursor(heading.StartByte)
			}
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

func outlineLanguageSupported(root string) bool {
	switch language.ID(root) {
	case language.Markdown, language.Go, language.TypeScript, language.TSX:
		return true
	default:
		return false
	}
}

func outlineCodeSymbols(doc *document.Document, theme Theme) {
	if len(doc.Projections.Code.Symbols) == 0 {
		Label("No symbols found.", FontSize(11), TextColorVec(theme.Muted))
		return
	}
	for _, symbol := range doc.Projections.Code.Symbols {
		symbol := symbol
		button := WorkstationRow(theme, Attrs(Row, FixHeight(24), Expand, Pad2(0, 10), Gap(6)), false, false, func() {
			Label(symbol.Name, FontSize(11), TextColorVec(theme.Ink))
			Label(outlineSymbolKind(symbol.Kind), FontSize(10), TextColorVec(theme.Muted))
		})
		if button.Clicked {
			doc.Editor.SetCursor(symbol.StartByte)
		}
	}
}

func outlineSymbolKind(kind string) string {
	switch kind {
	case "function", "method":
		return "ƒ " + kind
	case "class", "struct", "interface", "type", "enum":
		return "◇ " + kind
	case "variable", "constant", "property":
		return "· " + kind
	default:
		if kind == "" {
			return "symbol"
		}
		return kind
	}
}

func outlineTask(state *application.Application, doc *document.Document, task document.Task, enabled bool, theme Theme) {
	Container(Attrs(Row, FixHeight(24), Expand, Pad2(0, 10), Gap(4)), func() {
		if WorkstationToolButton(theme, checkbox(task.Checked), enabled) && enabled {
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
		if WorkstationToolButton(theme, "Open", enabled) && enabled {
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

// formatTableAtCursor performs one whole-table source replacement. Document
// invalidation makes the edit disposable/reparseable, while ScratchEditor's
// Replace path keeps the operation as one undo record.
func formatTableAtCursor(doc *document.Document) bool {
	return applyDocumentCommand(doc, commands.DocumentFormat)
}

// navigateTableAtCursor formats the active table before moving through its
// semantic header/data cells. Enter moves down the same column; Tab advances
// row-major. At the end of the available rows both operations create one new
// empty source row, preserving the whole action as one undoable replacement.
func navigateTableAtCursor(doc *document.Document, previous, enter bool) bool {
	id := commands.MarkdownTableNext
	if previous {
		id = commands.MarkdownTablePrevious
	} else if enter {
		id = commands.MarkdownTableEnter
	}
	return applyDocumentCommand(doc, id)
}

func toggleTaskAtCursor(doc *document.Document) bool {
	return applyDocumentCommand(doc, commands.ItemToggle)
}

// applyDocumentCommand is the only UI-side adapter for product editing
// commands. The command package decides whether an action is meaningful and
// returns one source replacement; Document then records that replacement as
// one ordinary undoable edit.
func applyDocumentCommand(doc *document.Document, id commands.ID, args ...string) bool {
	request, err := commands.NewRequest(doc, id)
	if err != nil {
		return false
	}
	if len(args) > 0 {
		request.Argument = args[0]
	}
	return applyCommandRequest(doc, request)
}

func applyDocumentCommandRange(doc *document.Document, id commands.ID, argument string, start, end int, slash bool) bool {
	request, err := commands.NewRequest(doc, id)
	if err != nil {
		return false
	}
	request.Argument = argument
	request.RangeStart = start
	request.RangeEnd = end
	request.RangeOverride = true
	request.SlashTrigger = slash
	return applyCommandRequest(doc, request)
}

func applyCommandRequest(doc *document.Document, request commands.Request) bool {
	outcome := commands.Execute(request)
	if outcome.Status != commands.ResultExecuted || outcome.Start < 0 || outcome.End < outcome.Start {
		return false
	}
	if err := doc.ReplaceWithSelection(outcome.Start, outcome.End, outcome.Replacement, outcome.Anchor, outcome.Cursor); err != nil {
		return false
	}
	return true
}

func slashCandidate(state *application.Application) (int, int, string, bool) {
	if state == nil || state.ActiveDocument() == nil {
		return 0, 0, "", false
	}
	doc := state.ActiveDocument()
	ctx := commandContext(state)
	if !ctx.Markdown {
		return 0, 0, "", false
	}
	line, ok := doc.Editor.Buffer.LineAt(doc.Editor.Cursor)
	if !ok {
		return 0, 0, "", false
	}
	lineStart, lineEnd, ok := doc.Editor.Buffer.LineRange(line)
	if !ok || doc.Editor.Cursor < lineStart || doc.Editor.Cursor > lineEnd {
		return 0, 0, "", false
	}
	source, err := doc.Editor.Buffer.Bytes(lineStart, lineEnd)
	if err != nil {
		return 0, 0, "", false
	}
	prefix := string(source[:doc.Editor.Cursor-lineStart])
	trimmed := strings.TrimLeft(prefix, " \t")
	if !strings.HasPrefix(trimmed, "/") {
		return 0, 0, "", false
	}
	if strings.TrimSpace(string(source[doc.Editor.Cursor-lineStart:])) != "" {
		return 0, 0, "", false
	}
	if !ctx.ProjectionCurrent {
		// Reparse only after the line actually looks like a slash command.
		// Ordinary typing must not synchronously reparse the whole document
		// while the debounced Markdown projection is stale.
		request, err := commands.NewRequest(doc, commands.MarkdownInsertCodeBlock)
		if err != nil || request.InFence {
			return 0, 0, "", false
		}
	} else if ctx.InFence {
		return 0, 0, "", false
	}
	slash := lineStart + len(prefix) - len(trimmed)
	return slash, doc.Editor.Cursor, trimmed[1:], true
}

func filteredSlashCommands(query string) []slashCommand {
	query = strings.ToLower(strings.TrimSpace(query))
	result := make([]slashCommand, 0)
	for _, command := range markdownSlashCommands() {
		if fuzzyCommandMatch(query, strings.ToLower(command.Name)) {
			result = append(result, command)
		}
	}
	return result
}

func fuzzyCommandMatch(query, candidate string) bool {
	if query == "" {
		return true
	}
	at := 0
	for _, want := range query {
		found := false
		for at < len(candidate) {
			r, size := utf8.DecodeRuneInString(candidate[at:])
			at += size
			if r == want {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	return true
}

func handleSlashInput(state *application.Application, shell *workbenchState) bool {
	if shell == nil {
		return false
	}
	if shell.Slash.Open {
		start, end, query, ok := slashCandidate(state)
		if !ok || shell.Slash.DocumentID != state.Active {
			shell.Slash = slashState{}
			return false
		}
		shell.Slash.TriggerStart, shell.Slash.TriggerEnd, shell.Slash.Query = start, end, query
		items := filteredSlashCommands(query)
		if shell.Slash.Selected >= len(items) {
			shell.Slash.Selected = maxInt(0, len(items)-1)
		}
		frame := GetFrameInput()
		switch frame.Key {
		case KeyEscape:
			shell.Slash = slashState{}
			frame.Key = KeyCodeNone
			return true
		case KeyUp:
			if len(items) > 0 {
				shell.Slash.Selected = (shell.Slash.Selected + len(items) - 1) % len(items)
			}
			frame.Key = KeyCodeNone
			return true
		case KeyDown:
			if len(items) > 0 {
				shell.Slash.Selected = (shell.Slash.Selected + 1) % len(items)
			}
			frame.Key = KeyCodeNone
			return true
		case KeyEnter:
			if len(items) == 0 {
				return false
			}
			selected := items[shell.Slash.Selected]
			doc := state.ActiveDocument()
			if applyDocumentCommandRange(doc, selected.ID, "", start, end, true) {
				shell.Slash = slashState{}
				if selected.ID == commands.MarkdownInsertCodeBlock {
					shell.Fence = fenceState{Open: true, DocumentID: state.Active}
				}
				frame.Key = KeyCodeNone
				return true
			}
		}
		return false
	}
	if transientInputOpen(shell) {
		return false
	}
	if start, end, query, ok := slashCandidate(state); ok {
		shell.Slash = slashState{Open: true, Query: query, TriggerStart: start, TriggerEnd: end, DocumentID: state.Active}
	}
	return false
}

func handleFenceInput(state *application.Application, shell *workbenchState) bool {
	if shell == nil || !shell.Fence.Open || state == nil || shell.Fence.DocumentID != state.Active {
		return false
	}
	if doc := state.ActiveDocument(); doc == nil {
		shell.Fence = fenceState{}
		return false
	} else if request, err := commands.NewRequest(doc, commands.MarkdownSetFenceLanguage); err != nil || !request.InFence {
		// The caret or source may have changed while the chooser was open.
		shell.Fence = fenceState{}
		return false
	}
	languages := markdownFenceLanguages()
	frame := GetFrameInput()
	switch frame.Key {
	case KeyEscape:
		shell.Fence = fenceState{}
		frame.Key = KeyCodeNone
		return true
	case KeyUp:
		if len(languages) > 0 {
			shell.Fence.Selected = (shell.Fence.Selected + len(languages) - 1) % len(languages)
		}
		frame.Key = KeyCodeNone
		return true
	case KeyDown:
		if len(languages) > 0 {
			shell.Fence.Selected = (shell.Fence.Selected + 1) % len(languages)
		}
		frame.Key = KeyCodeNone
		return true
	case KeyEnter:
		if len(languages) == 0 {
			return false
		}
		if executeCommand(state, shell, commands.MarkdownSetFenceLanguage, languages[shell.Fence.Selected]) {
			frame.Key = KeyCodeNone
			return true
		}
	}
	return false
}

type treeState struct {
	Expanded       map[string]bool
	Selected       map[string]bool
	AnchorPath     string
	LeadPath       string
	VisiblePaths   []string
	RowIDs         map[string]ContainerId // transient handles used by layout tests
	MarqueeActive  bool
	MarqueeStart   Vec2
	MarqueeCurrent Vec2
	MarqueeMoved   bool
	rowsDirty      bool
	renderDepth    int
}

type treeDragPayload string
type treeDropTarget string

func ensureTreeSelection(tree *treeState) {
	if tree.Selected == nil {
		tree.Selected = make(map[string]bool)
	}
}

func clearTreeSelection(tree *treeState) {
	if tree == nil {
		return
	}
	tree.Selected = make(map[string]bool)
	tree.AnchorPath = ""
	tree.LeadPath = ""
}

func treeSelectionClick(tree *treeState, path string, modifiers, primary Modifiers, visible []string) {
	if tree == nil || path == "" {
		return
	}
	ensureTreeSelection(tree)
	if modifiers&ModShift != 0 && tree.AnchorPath != "" {
		anchor := treePathIndex(visible, tree.AnchorPath)
		lead := treePathIndex(visible, path)
		if anchor >= 0 && lead >= 0 {
			anchorPath := tree.AnchorPath
			clearTreeSelection(tree)
			if anchor > lead {
				anchor, lead = lead, anchor
			}
			for _, candidate := range visible[anchor : lead+1] {
				tree.Selected[candidate] = true
			}
			tree.AnchorPath = anchorPath
			tree.LeadPath = path
			return
		}
	}
	if modifiers&primary != 0 {
		tree.Selected[path] = !tree.Selected[path]
		if tree.AnchorPath == "" {
			tree.AnchorPath = path
		}
		tree.LeadPath = path
		return
	}
	clearTreeSelection(tree)
	tree.Selected[path] = true
	tree.AnchorPath = path
	tree.LeadPath = path
}

func treePathIndex(paths []string, path string) int {
	for index, candidate := range paths {
		if candidate == path {
			return index
		}
	}
	return -1
}

func treeRowHovered(tree *treeState) bool {
	if tree == nil {
		return false
	}
	for _, row := range tree.RowIDs {
		if row != nil && IdIsHovered(row) {
			return true
		}
	}
	return false
}

func selectedTreePaths(tree *treeState) []string {
	if tree == nil || len(tree.Selected) == 0 {
		return nil
	}
	paths := make([]string, 0, len(tree.Selected))
	for _, path := range tree.VisiblePaths {
		if tree.Selected[path] {
			paths = append(paths, path)
		}
	}
	return paths
}

func treeContextPaths(state *application.Application, shell *workbenchState, menu contextMenuState) []string {
	if state == nil || shell == nil || menu.WorkspaceRoot {
		return []string{menu.Path}
	}
	selected := selectedTreePaths(&shell.Tree)
	relative := workspaceRelative(state, menu.Path)
	if len(selected) <= 1 || !shell.Tree.Selected[relative] {
		return []string{menu.Path}
	}
	paths := make([]string, 0, len(selected))
	for _, path := range selected {
		paths = append(paths, filepath.Join(state.Workspace.Root, path))
	}
	return paths
}

func visibleTreePaths(state *application.Application, tree *treeState, relative string) []string {
	if state == nil || tree == nil || !state.HasWorkspace {
		return nil
	}
	entries, err := state.Workspace.List(relative)
	if err != nil {
		return nil
	}
	paths := make([]string, 0, len(entries))
	for _, entry := range entries {
		paths = append(paths, entry.Path)
		if entry.Dir && tree.Expanded[entry.Path] {
			paths = append(paths, visibleTreePaths(state, tree, entry.Path)...)
		}
	}
	return paths
}

func treeMarqueeRect(start, end Vec2) Rect {
	origin := Vec2{minFloat(start[0], end[0]), minFloat(start[1], end[1])}
	far := Vec2{maxFloat(start[0], end[0]), maxFloat(start[1], end[1])}
	return Rect{Origin: origin, Size: Vec2{far[0] - origin[0], far[1] - origin[1]}}
}

func absFloat(value float32) float32 {
	if value < 0 {
		return -value
	}
	return value
}

func treeRectsIntersect(a, b Rect) bool {
	return a.Origin[0] < b.Origin[0]+b.Size[0] && b.Origin[0] < a.Origin[0]+a.Size[0] &&
		a.Origin[1] < b.Origin[1]+b.Size[1] && b.Origin[1] < a.Origin[1]+a.Size[1]
}

func updateTreeMarqueeSelection(tree *treeState) {
	if tree == nil || !tree.MarqueeActive || !tree.MarqueeMoved {
		return
	}
	selectionRect := treeMarqueeRect(tree.MarqueeStart, tree.MarqueeCurrent)
	clearTreeSelection(tree)
	for _, path := range tree.VisiblePaths {
		row, ok := tree.RowIDs[path]
		if !ok || treeRectsIntersect(selectionRect, GetResolvedRectOf(row)) {
			tree.Selected[path] = ok && treeRectsIntersect(selectionRect, GetResolvedRectOf(row))
		}
	}
	for _, path := range tree.VisiblePaths {
		if tree.Selected[path] {
			tree.AnchorPath = path
			break
		}
	}
	for index := len(tree.VisiblePaths) - 1; index >= 0; index-- {
		if tree.Selected[tree.VisiblePaths[index]] {
			tree.LeadPath = tree.VisiblePaths[index]
			break
		}
	}
}

func renderTree(state *application.Application, tree *treeState, relative string, depth int, theme Theme) {
	shell := &workbenchState{Tree: *tree}
	renderTreeWithShell(state, &shell.Tree, shell, relative, depth, theme)
	*tree = shell.Tree
}

func renderTreeWithShell(state *application.Application, tree *treeState, shell *workbenchState, relative string, depth int, theme Theme) {
	ensureTreeSelection(tree)
	if tree.renderDepth == 0 {
		tree.VisiblePaths = visibleTreePaths(state, tree, relative)
	}
	if tree.renderDepth == 0 && tree.rowsDirty {
		tree.RowIDs = nil
		tree.rowsDirty = false
	}
	if tree.RowIDs == nil {
		tree.RowIDs = make(map[string]ContainerId)
	}
	tree.renderDepth++
	defer func() { tree.renderDepth-- }()
	entries, err := state.Workspace.List(relative)
	if err != nil {
		Label("Workspace unavailable: "+err.Error(), FontSize(11), TextColorVec(theme.Muted))
		return
	}
	for _, entry := range entries {
		entry := entry
		selected := tree.Selected[entry.Path]
		ContainerWithKey(entry.Path, Attrs(Expand), func() {
			// Keep the item itself horizontal. Expanded children are siblings
			// below it in this vertical subtree, never children of its row.
			active := !entry.Dir && isActivePath(state, filepath.Join(state.Workspace.Root, entry.Path))
			var button ButtonState
			var secondaryGesture bool
			rowID := Container(Attrs(Expand), func() {
				secondaryClick, secondary := contextMenuGesture()
				secondaryGesture = secondary
				if entry.Dir && CanDropHere[treeDragPayload](treeDropTarget(entry.Path)) {
					ModAttrs(BackgroundVec(theme.Selection))
				}
				button = WorkstationRow(theme, Attrs(Row, CrossMid, Expand, FixHeight(24), Pad4(0, 6, 0, float32(8+depth*14))), active || selected, secondaryGesture, func() {
					if entry.Dir {
						arrow := "▸"
						if tree.Expanded[entry.Path] {
							arrow = "▾"
						}
						Label(arrow+"  "+entry.Name, FontSize(12), TextColorVec(theme.Ink))
						if secondaryClick && IsHovered() {
							if !tree.Selected[entry.Path] {
								treeSelectionClick(tree, entry.Path, 0, PrimaryMod(), tree.VisiblePaths)
							}
							openTreeContextMenu(shell, filepath.Join(state.Workspace.Root, entry.Path), true)
						}
						return
					}
					marker := "  "
					if isActivePath(state, filepath.Join(state.Workspace.Root, entry.Path)) {
						marker = "● "
					}
					Label(marker+entry.Name, FontSize(12), TextColorVec(theme.Ink))
					if secondaryClick && IsHovered() {
						if !tree.Selected[entry.Path] {
							treeSelectionClick(tree, entry.Path, 0, PrimaryMod(), tree.VisiblePaths)
						}
						openTreeContextMenu(shell, filepath.Join(state.Workspace.Root, entry.Path), false)
					}
				})
				sourcePath := filepath.Join(state.Workspace.Root, entry.Path)
				if !secondaryGesture && DragAndDrop(treeDragPayload(sourcePath)) {
					target := GetDropTarget[treeDropTarget]()
					destinationDir := filepath.Join(state.Workspace.Root, string(target))
					destination := filepath.Join(destinationDir, filepath.Base(sourcePath))
					if err := state.MovePath(sourcePath, destination); err != nil {
						shell.Mutation.Error = err.Error()
					} else {
						resetTreeAfterMutation(shell)
					}
				}
			})
			if button.Clicked && !secondaryGesture && GetInputState().MouseButton == MousePrimary {
				modifiers := GetInputState().Modifiers
				treeSelectionClick(tree, entry.Path, modifiers, PrimaryMod(), tree.VisiblePaths)
				if modifiers&(PrimaryMod()|ModShift) == 0 {
					if entry.Dir {
						executeCommand(state, shell, commands.WorkspaceToggleFolder, entry.Path)
					} else {
						executeCommand(state, shell, commands.FileOpen, filepath.Join(state.Workspace.Root, entry.Path))
					}
				}
			}
			tree.RowIDs[entry.Path] = rowID
			if entry.Dir && tree.Expanded[entry.Path] {
				renderTreeWithShell(state, tree, shell, entry.Path, depth+1, theme)
			}
		})
	}
}

func emptyState(state *application.Application, shell *workbenchState, theme Theme) {
	PaperWell(theme, Attrs(Grow(1), Expand), Attrs(Center, Pad(28)), func() {
		Container(Attrs(FixWidth(560), Gap(8)), func() {
			Label("A quiet place for files, notes, and code.", FontWeight(WeightBold), FontSize(20), TextColorVec(theme.Ink))
			Label("Open a file for a focused editor, or a folder for the workspace tree.", FontSize(13), TextColorVec(theme.Muted))
			Container(Attrs(Row, Gap(8)), func() {
				if WorkstationButton(theme, "Open…", true) {
					executeCommand(state, shell, commands.FileOpen)
				}
				if WorkstationButton(theme, "Quick open", true) {
					executeCommand(state, shell, commands.QuickOpen)
				}
			})
		})
	})
}

func tabs(state *application.Application, shell *workbenchState, theme Theme) {
	if shell.TabIDs == nil {
		shell.TabIDs = make(map[application.DocumentID]ContainerId)
	}
	if shell.TabCloseIDs == nil {
		shell.TabCloseIDs = make(map[application.DocumentID]ContainerId)
	}
	ChromeBar(theme, Attrs(Row, CrossAlign(AlignEnd), FixHeight(32), Gap(1), Pad4(3, 4, 0, 4)), func() {
		for _, id := range state.Order {
			doc := state.Documents[id]
			id, doc := id, doc
			active := id == state.Active
			var closeID ContainerId
			tabID := ContainerWithKey(id, Attrs(FixHeight(29)), func() {
				secondaryClick, secondaryGesture := contextMenuGesture()
				button := ProcessButtonEvents(secondaryGesture)
				middleClick := GetFrameInput().Mouse == MouseClick && GetInputState().MouseButton == MouseTertiary
				drawContent := func() {
					Container(Attrs(Row, CrossMid, FixHeight(27), Pad2(0, 8), Gap(6)), func() {
						weight := WeightNormal
						if active {
							weight = WeightBold
						}
						Label(filepathBase(doc.Path), FontSize(12), FontWeight(weight), TextColorVec(theme.Ink))
						if doc.Dirty() {
							Label("●", FontSize(8), TextColorVec(theme.Warning))
						}
						closeID = Container(Attrs(FixWidth(16), FixHeight(18), Center, Corners(1)), func() {
							closeButton := ProcessButtonEvents(secondaryGesture)
							if closeButton.Hovered {
								ModAttrs(BackgroundVec(theme.Highlight), BorderWidth(1), BorderColorVec(theme.Shadow))
							}
							Label("×", FontSize(13), TextColorVec(theme.Muted))
							if closeButton.Clicked {
								executeCommand(state, shell, commands.DocumentClose, id)
							}
						})
					})
				}
				if active {
					Container(Attrs(Grow(1), Expand, BackgroundVec(theme.DarkShadow), Pad4(1, 1, 0, 1), NoAnimate), func() {
						Container(Attrs(Grow(1), Expand, BackgroundVec(theme.Paper), NoAnimate), drawContent)
					})
				} else if button.Active {
					InsetFrame(theme, Attrs(Grow(1), Expand), Attrs(), drawContent)
				} else {
					RaisedFrame(theme, Attrs(Grow(1), Expand), Attrs(), func() {
						if button.Hovered {
							ModAttrs(BackgroundVec(theme.Highlight))
						}
						drawContent()
					})
				}
				if middleClick && button.Hovered {
					executeCommand(state, shell, commands.DocumentClose, id)
				} else if secondaryClick && button.Hovered {
					openTabContextMenu(shell, id, doc.Path)
				} else if button.Clicked && !secondaryGesture && GetInputState().MouseButton == MousePrimary {
					executeCommand(state, shell, commands.DocumentActivate, id)
				}
			})
			shell.TabIDs[id] = tabID
			shell.TabCloseIDs[id] = closeID
		}
		Container(Attrs(Grow(1)), func() {})
	})
}

func findBar(state *application.Application, shell *workbenchState, theme Theme) {
	if !shell.ShowFind {
		return
	}
	search := Use[searchState]("current-find")
	var matches []application.CurrentMatch
	replaceFocused := false
	Container(Attrs(Row, CrossMid, Gap(6), FixHeight(34), Pad2(3, 8), BackgroundVec(theme.ChromeRaised), BorderWidth(1), BorderColorVec(theme.Border)), func() {
		Label("Find", FontWeight(WeightBold), FontSize(11), TextColorVec(theme.Ink))
		input := CtrlTextInputAttrs()
		input.MinWidth = 220
		ContainerWithKey(fmt.Sprintf("find-field-%d", shell.FindEpoch), Attrs(Grow(1)), func() {
			TextInputExt(&shell.FindQuery, input)
		})
		matches = currentFindMatches(state, shell)
		search.Current = matches
		if state.Active != "" && shell.FindQuery != "" {
			Label(fmt.Sprintf("%d matches", len(search.Current)), FontSize(10), TextColorVec(theme.Muted))
		}
		if shell.ShowReplace {
			Label("Replace", FontWeight(WeightBold), FontSize(11), TextColorVec(theme.Ink))
			replaceInput := CtrlTextInputAttrs()
			replaceInput.MinWidth = 180
			replaceInput.NoAutoFocus = true
			ContainerWithKey(fmt.Sprintf("replace-field-%d", shell.FindEpoch), Attrs(Grow(1)), func() {
				TextInputExt(&shell.ReplaceQuery, replaceInput)
				replaceFocused = HasFocusWithin()
			})
			if WorkstationToolButton(theme, "Replace", len(matches) > 0) {
				replaceCurrentMatch(state, shell)
			}
			if WorkstationToolButton(theme, "All", len(matches) > 0) {
				replaceAllMatches(state, shell)
			}
		}
		Container(Attrs(Grow(1)), func() {})
		if WorkstationToolButton(theme, "Close", true) {
			shell.ShowFind = false
			shell.ShowReplace = false
		}
	})
	if len(search.Current) > 0 && GetFrameInput().Key == KeyEnter {
		if shell.ShowReplace && replaceFocused {
			replaceCurrentMatch(state, shell)
		} else if GetInputState().Modifiers&ModShift != 0 {
			executeCommand(state, shell, commands.DocumentFindPrevious)
		} else {
			executeCommand(state, shell, commands.DocumentFindNext)
		}
		GetFrameInput().Key = KeyCodeNone
	}
}

func workspaceSearchPanel(state *application.Application, shell *workbenchState, theme Theme) {
	search := Use[searchState]("workspace-search")
	Container(Attrs(Gap(5), Pad2(6, 8), BackgroundVec(theme.ChromeInset)), func() {
		Container(Attrs(Row, CrossMid, Gap(4)), func() {
			input := CtrlTextInputAttrs()
			input.MinWidth = 140
			TextInputExt(&search.Query, input)
			if WorkstationButton(theme, "Search", true) {
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
		if WorkstationToolButton(theme, "Compare", true) {
			shell.ShowCompare = true
		}
		if WorkstationToolButton(theme, "Reload", true) {
			_ = state.ReloadDisk(state.Active)
		}
		if WorkstationToolButton(theme, "Overwrite…", true) {
			_ = state.OverwriteDisk(state.Active)
		}
	})
	if shell.ShowCompare {
		Container(Attrs(Row, CrossMid, Gap(8), FixHeight(28), Pad2(2, 8), BackgroundVec(theme.ChromeRaised)), func() {
			localBytes := 0
			if doc := state.ActiveDocument(); doc != nil {
				localBytes = len(doc.Editor.Buffer.Text())
			}
			Label(fmt.Sprintf("Compare · base %d B · local %d B · disk %d B", len(conflict.Base), localBytes, len(conflict.Disk)), FontSize(10), TextColorVec(theme.Muted))
			Container(Attrs(Grow(1)), func() {})
			if WorkstationToolButton(theme, "Close", true) {
				shell.ShowCompare = false
			}
		})
	}
}

func saveNoticePanel(shell *workbenchState, theme Theme) {
	if shell == nil || shell.SaveNotice == "" {
		return
	}
	color := theme.Warning
	Container(Attrs(Row, CrossMid, Gap(7), FixHeight(34), Pad2(3, 8), BackgroundVec(color), BorderWidth(1), BorderColorVec(theme.Border)), func() {
		Label(shell.SaveNotice, FontSize(11), TextColorVec(theme.Ink))
		Container(Attrs(Grow(1)), func() {})
		if WorkstationToolButton(theme, "Dismiss", true) {
			shell.SaveNotice = ""
		}
	})
}

func saveWarningCommitted(state *application.Application, err error, path, beforePath string, beforeVersion workspace.DiskVersion, beforeDirty bool) bool {
	if !errors.Is(err, workspace.ErrParentDirSync) || state == nil {
		return false
	}
	doc := state.ActiveDocument()
	if doc == nil || doc.Dirty() {
		return false
	}
	if path != "" && filepath.Clean(doc.Path) != filepath.Clean(path) {
		return false
	}
	return beforeDirty || doc.Path != beforePath || doc.DiskVersion != beforeVersion
}

func clearSaveNotice(shell *workbenchState) {
	shell.SaveNotice = ""
}

func recordSaveNotice(shell *workbenchState, err error, committedWarning bool) {
	if err == nil {
		clearSaveNotice(shell)
		return
	}
	if committedWarning {
		shell.SaveNotice = "Saved with a durability warning: " + err.Error()
		return
	}
	shell.SaveNotice = "Save failed: " + err.Error()
}

func saveAsFromModal(state *application.Application, shell *workbenchState, path string) {
	if state == nil || shell == nil || state.Active == "" {
		return
	}
	beforeDoc := state.ActiveDocument()
	var beforePath string
	var beforeVersion workspace.DiskVersion
	var beforeDirty bool
	if beforeDoc != nil {
		beforePath, beforeVersion, beforeDirty = beforeDoc.Path, beforeDoc.DiskVersion, beforeDoc.Dirty()
	}
	err := state.SaveAs(state.Active, path)
	if err == nil {
		shell.ShowSaveAs = false
		shell.SaveAsError = ""
		clearSaveNotice(shell)
		return
	}
	if saveWarningCommitted(state, err, path, beforePath, beforeVersion, beforeDirty) {
		shell.ShowSaveAs = false
		shell.SaveAsError = ""
		recordSaveNotice(shell, err, true)
		return
	}
	var request *application.SaveAsDestinationExistsError
	if errors.As(err, &request) {
		shell.ShowSaveAs = false
		shell.ShowSaveAsOverwrite = true
		shell.SaveAsOverwriteDocument = state.Active
		shell.SaveAsOverwritePath = request.Path
		shell.SaveAsOverwriteVersion = request.Version
		shell.SaveAsError = ""
		return
	}
	shell.SaveAsError = "Save failed: " + err.Error()
}

func confirmSaveAsFromModal(state *application.Application, shell *workbenchState) {
	if state == nil || shell == nil {
		return
	}
	beforeDoc := state.ActiveDocument()
	var beforePath string
	var beforeVersion workspace.DiskVersion
	var beforeDirty bool
	if beforeDoc != nil {
		beforePath, beforeVersion, beforeDirty = beforeDoc.Path, beforeDoc.DiskVersion, beforeDoc.Dirty()
	}
	err := state.ConfirmSaveAs(shell.SaveAsOverwriteDocument, shell.SaveAsOverwritePath, shell.SaveAsOverwriteVersion)
	if err == nil {
		shell.ShowSaveAsOverwrite = false
		shell.SaveAsError = ""
		clearSaveNotice(shell)
		return
	}
	if saveWarningCommitted(state, err, shell.SaveAsOverwritePath, beforePath, beforeVersion, beforeDirty) {
		shell.ShowSaveAsOverwrite = false
		shell.SaveAsError = ""
		recordSaveNotice(shell, err, true)
		return
	}
	if errors.Is(err, document.ErrDiskChanged) {
		shell.ShowSaveAsOverwrite = false
		shell.ShowSaveAs = true
		shell.SaveAsPath = shell.SaveAsOverwritePath
		shell.SaveAsError = "The destination changed on disk. Review and confirm again."
		return
	}
	shell.SaveAsError = "Save failed: " + err.Error()
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
		if WorkstationButton(theme, "Save and close", true) {
			executeCommand(state, shell, commands.DocumentClose, shell.ClosePending, closeSave)
		}
		if WorkstationToolButton(theme, "Discard", true) {
			executeCommand(state, shell, commands.DocumentClose, shell.ClosePending, closeDiscard)
		}
		if WorkstationToolButton(theme, "Cancel", true) {
			shell.ClosePending = ""
			shell.CloseQueue = nil
		}
	})
}

func statusBar(state *application.Application, theme Theme) {
	Container(Attrs(FixHeight(27), Expand, NoAnimate), func() {
		EtchedDivider(theme, dividerHorizontal)
		ChromeBar(theme, Attrs(Row, CrossMid, FixHeight(25), Gap(8), Pad2(0, 8)), func() {
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
			statusColor := theme.Muted
			if status == "Conflict" {
				statusColor = theme.Warning
			}
			Label(status, FontSize(10), FontWeight(WeightBold), TextColorVec(statusColor))
			Label(relativePath(state, doc.Path), FontSize(10), TextColorVec(theme.Ink))
			Container(Attrs(Grow(1)), func() {})
			line, column := cursorPosition(doc)
			Label(fmt.Sprintf("Ln %d · Col %d", line, column), FontSize(10), TextColorVec(theme.Muted))
			EtchedDivider(theme, dividerVertical)
			encoding := strings.ToUpper(doc.Format.Encoding)
			if doc.Format.UTF8BOM {
				encoding += " BOM"
			}
			Label(encoding, FontSize(10), TextColorVec(theme.Muted))
			if doc.RootLanguage != "" {
				EtchedDivider(theme, dividerVertical)
				Label(documentSurfaceLabel(doc), FontSize(10), TextColorVec(theme.Muted))
			}
		})
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
		WorkstationModal(theme, 560, func() { shell.ShowFolder = false }, func() {
			Label("Open folder", FontWeight(WeightBold), FontSize(14), TextColorVec(theme.Ink))
			if folderPickerPanel(shell) {
				if executeCommand(state, shell, commands.FileOpen, filepath.Clean(shell.FolderPicker.Result)) {
					shell.ShowFolder = false
				}
			}
		})
	}
	if shell.ShowOpen {
		WorkstationModal(theme, 620, func() { shell.ShowOpen = false; shell.ShowFolder = false }, func() {
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
		WorkstationModal(theme, 520, func() { shell.ShowSaveAs = false; shell.SaveAsError = "" }, func() {
			Label("Save As", FontWeight(WeightBold), FontSize(14), TextColorVec(theme.Ink))
			if shell.SaveAsError != "" {
				Label(shell.SaveAsError, FontSize(11), TextColorVec(theme.Warning))
			}
			field := DefaultTextInputAttrs()
			field.MinWidth = 420
			TextInputExt(&shell.SaveAsPath, field)
			Container(Attrs(Row, Gap(6)), func() {
				if WorkstationButton(theme, "Save As", true) && state.Active != "" {
					saveAsFromModal(state, shell, shell.SaveAsPath)
				}
				if WorkstationButton(theme, "Cancel", true) {
					shell.ShowSaveAs = false
					shell.SaveAsError = ""
				}
			})
		})
	}
	if shell.ShowSaveAsOverwrite {
		WorkstationModal(theme, 520, func() {
			shell.ShowSaveAsOverwrite = false
			shell.SaveAsError = ""
		}, func() {
			Label("Replace existing file?", FontWeight(WeightBold), FontSize(14), TextColorVec(theme.Ink))
			Label(shell.SaveAsOverwritePath, FontSize(11), TextColorVec(theme.Muted))
			Label("The file already exists. Replace it with the current document?", FontSize(11), TextColorVec(theme.Ink))
			if shell.SaveAsError != "" {
				Label(shell.SaveAsError, FontSize(11), TextColorVec(theme.Warning))
			}
			Container(Attrs(Row, Gap(6)), func() {
				if WorkstationButton(theme, "Replace", true) {
					confirmSaveAsFromModal(state, shell)
				}
				if WorkstationButton(theme, "Cancel", true) {
					shell.ShowSaveAsOverwrite = false
					shell.SaveAsError = ""
				}
			})
		})
	}
	if shell.Mutation.Open {
		workspaceMutationModal(state, shell, theme)
	}
	if shell.TrashConfirmation.Open {
		trashConfirmationModal(state, shell, theme)
	}
	if shell.ShowQuickOpen {
		quickOpenPopup(state, shell, theme)
	}
	if shell.ShowRecent {
		recentPopup(state, shell, theme)
	}
	if shell.ShowGoToLine {
		WorkstationModal(theme, 420, func() { shell.ShowGoToLine = false }, func() {
			Label("Go to Line", FontWeight(WeightBold), FontSize(14), TextColorVec(theme.Ink))
			field := DefaultTextInputAttrs()
			field.MinWidth = 360
			TextInputExt(&shell.GoToLineText, field)
			if shell.GoToLineError != "" {
				Label(shell.GoToLineError, FontSize(11), TextColorVec(theme.Warning))
			}
			Container(Attrs(Row, Gap(6)), func() {
				if WorkstationButton(theme, "Go", true) {
					executeCommand(state, shell, commands.DocumentGoToLine, shell.GoToLineText)
				}
				if WorkstationButton(theme, "Cancel", true) {
					shell.ShowGoToLine = false
				}
			})
			if GetFrameInput().Key == KeyEnter {
				executeCommand(state, shell, commands.DocumentGoToLine, shell.GoToLineText)
				GetFrameInput().Key = KeyCodeNone
			}
		})
	}
	markdownCommandPopups(state, shell, theme)
	contextMenu(state, shell, theme)
}

func workspaceMutationModal(state *application.Application, shell *workbenchState, theme Theme) {
	mutation := &shell.Mutation
	WorkstationModal(theme, 500, func() {
		mutation.Open = false
		mutation.Error = ""
	}, func() {
		Label(workspaceMutationTitle(mutation.Kind), FontWeight(WeightBold), FontSize(14), TextColorVec(theme.Ink))
		if mutation.Kind == mutationRename || mutation.Kind == mutationMove {
			Label(relativePath(state, mutation.Path), FontSize(11), TextColorVec(theme.Muted))
		} else {
			Label("Create in "+relativePath(state, mutation.Path), FontSize(11), TextColorVec(theme.Muted))
		}
		field := DefaultTextInputAttrs()
		field.MinWidth = 420
		ContainerWithKey(fmt.Sprintf("workspace-mutation-%d", mutation.Generation), Attrs(), func() {
			TextInputExt(&mutation.Text, field)
		})
		if mutation.Error != "" {
			Label(mutation.Error, FontSize(11), TextColorVec(theme.Warning))
		}
		Container(Attrs(Row, Gap(6)), func() {
			if WorkstationButton(theme, workspaceMutationTitle(mutation.Kind), true) {
				commitWorkspaceMutation(state, shell)
			}
			if WorkstationButton(theme, "Cancel", true) {
				mutation.Open = false
				mutation.Error = ""
			}
		})
		if GetFrameInput().Key == KeyEnter {
			commitWorkspaceMutation(state, shell)
			GetFrameInput().Key = KeyCodeNone
		}
	})
}

func trashConfirmationModal(state *application.Application, shell *workbenchState, theme Theme) {
	confirmation := &shell.TrashConfirmation
	WorkstationModal(theme, 520, func() {
		*confirmation = workspaceTrashConfirmation{}
	}, func() {
		Label("Move to Trash", FontWeight(WeightBold), FontSize(14), TextColorVec(theme.Ink))
		Label(relativePath(state, confirmation.Path), FontSize(11), TextColorVec(theme.Muted))
		Label("This entry contains unsaved documents.", FontSize(11), TextColorVec(theme.Ink))
		Label("Save them before moving to Trash, or discard their edits explicitly.", FontSize(11), TextColorVec(theme.Ink))
		if confirmation.Error != "" {
			Label(confirmation.Error, FontSize(11), TextColorVec(theme.Warning))
		}
		Container(Attrs(Row, Gap(6)), func() {
			if WorkstationButton(theme, "Save and Trash", true) {
				if err := saveDocumentsUnder(state, confirmation.Path); err != nil {
					confirmation.Error = err.Error()
				} else if err := state.TrashPath(confirmation.Path, false); err != nil {
					confirmation.Error = err.Error()
				} else {
					resetTreeAfterMutation(shell)
				}
			}
			if WorkstationButton(theme, "Discard and Trash", true) {
				if err := state.TrashPath(confirmation.Path, true); err != nil {
					confirmation.Error = err.Error()
				} else {
					resetTreeAfterMutation(shell)
				}
			}
			if WorkstationButton(theme, "Cancel", true) {
				*confirmation = workspaceTrashConfirmation{}
			}
		})
	})
}

func saveDocumentsUnder(state *application.Application, path string) error {
	if state == nil {
		return application.ErrWorkspaceRequired
	}
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	ids := make([]application.DocumentID, 0)
	for id, doc := range state.Documents {
		if doc == nil || !documentPathAffected(path, doc.Path, info.IsDir()) {
			continue
		}
		ids = append(ids, id)
	}
	for _, id := range ids {
		if err := state.SaveDocument(id); err != nil {
			return err
		}
	}
	return nil
}

func documentPathAffected(source, path string, directory bool) bool {
	if !directory {
		return filepath.Clean(source) == filepath.Clean(path)
	}
	rel, err := filepath.Rel(filepath.Clean(source), filepath.Clean(path))
	return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

func markdownCommandPopups(state *application.Application, shell *workbenchState, theme Theme) {
	if state == nil || shell == nil {
		return
	}
	doc := state.ActiveDocument()
	if doc == nil || doc.RootLanguage != string(language.Markdown) {
		shell.Slash = slashState{}
		shell.Fence = fenceState{}
		return
	}
	if shell.Slash.Open {
		items := filteredSlashCommands(shell.Slash.Query)
		Popup(func() {
			FloatingSurface(theme, Attrs(Float(70, 64), FixWidth(320), MaxHeight(390)), Attrs(Pad(8), Gap(2)), func() {
				Label("Markdown commands", FontWeight(WeightBold), FontSize(11), TextColorVec(theme.Ink))
				Container(Attrs(Viewport, MaxHeight(slashCommandViewportHeight), Clip), func() {
					ScrollOnInput()
					var viewportID ContainerId = CurrentId()
					rowIDs := make([]ContainerId, len(items))
					if len(items) == 0 {
						Label("No matching commands", FontSize(11), TextColorVec(theme.Muted))
					}
					for index, item := range items {
						index, item := index, item
						rowIDs[index] = ContainerWithKey(item.ID, Attrs(Row, CrossMid, FixHeight(slashCommandRowHeight), Pad2(1, 5)), func() {
							selected := index == shell.Slash.Selected
							if selected {
								ModAttrs(BackgroundVec(theme.SelectionHighlight))
							}
							if WorkstationToolButton(theme, "/"+item.Name, true) {
								if applyDocumentCommandRange(doc, item.ID, "", shell.Slash.TriggerStart, shell.Slash.TriggerEnd, true) {
									shell.Slash = slashState{}
									if item.ID == commands.MarkdownInsertCodeBlock {
										shell.Fence = fenceState{Open: true, DocumentID: state.Active}
									}
								}
							}
							// Keep the hint beside the command button without giving it
							// another interaction or focus target.
							Container(Attrs(Grow(1)), func() {})
							Label(item.Hint, FontSize(10), TextColorVec(theme.Muted))
						})
					}
					if shell.Slash.Selected >= 0 && shell.Slash.Selected < len(rowIDs) {
						revealPopupSelection(viewportID, rowIDs[shell.Slash.Selected])
					}
					ScrollBars()
				})
			})
		})
	}
	if shell.Fence.Open && shell.Fence.DocumentID == state.Active {
		languages := markdownFenceLanguages()
		if shell.Fence.Selected >= len(languages) {
			shell.Fence.Selected = len(languages) - 1
		}
		Popup(func() {
			FloatingSurface(theme, Attrs(Float(70, 96), FixWidth(260)), Attrs(Pad(8), Gap(3)), func() {
				Label("Fence language", FontWeight(WeightBold), FontSize(11), TextColorVec(theme.Ink))
				for index, languageName := range languages {
					index, languageName := index, languageName
					if WorkstationToolButton(theme, languageName, true) {
						executeCommand(state, shell, commands.MarkdownSetFenceLanguage, languageName)
					}
					if index == shell.Fence.Selected {
						// The button interaction remains framework-owned; the label
						// below makes the keyboard-selected option visible in tests.
						Label("selected", FontSize(9), TextColorVec(theme.Muted))
					}
				}
			})
		})
	}
	ctx := commandContext(state)
	if shell.Slash.Open || shell.Fence.Open || transientInputOpen(shell) || !ctx.HasSelection || ctx.InFence {
		return
	}
	Popup(func() {
		FloatingSurface(theme, Attrs(Float(70, 34), FixWidth(330)), Attrs(Row, CrossMid, Gap(3), Pad(5)), func() {
			for _, item := range []struct {
				label string
				id    commands.ID
			}{
				{"B", commands.MarkdownToggleStrong},
				{"I", commands.MarkdownToggleEmphasis},
				{"S", commands.MarkdownToggleStrike},
				{"Code", commands.MarkdownToggleInlineCode},
				{"Link", commands.MarkdownInsertLink},
			} {
				item := item
				if WorkstationToolButton(theme, item.label, true) {
					executeCommand(state, shell, item.id)
				}
			}
		})
	})
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
		FloatingSurface(theme, Attrs(Float(0, 42), FixWidth(620), MaxHeight(520)), Attrs(Pad(10), Gap(5)), func() {
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
	if shell != nil && shell.PendingSmartPaste && transientInputOpen(shell) {
		shell.PendingSmartPaste = false
	} else if shell != nil && shell.PendingSmartPaste && frame.Text != "" {
		if doc := state.ActiveDocument(); doc != nil {
			ctx := commandContext(state)
			if ctx.Markdown && !ctx.InFence && applyDocumentCommand(doc, commands.MarkdownSmartPaste, frame.Text) {
				frame.Text = ""
				shell.PendingSmartPaste = false
				frame.Key = KeyCodeNone
				return
			}
		}
		shell.PendingSmartPaste = false
	} else if shell != nil && shell.PendingSmartPaste {
		// Shirei delivers a requested clipboard read on the next frame. If
		// that frame contains no text, do not let a later ordinary keystroke
		// inherit the pending paste interpretation.
		shell.PendingSmartPaste = false
	}
	if handleSlashInput(state, shell) {
		return
	}
	if handleFenceInput(state, shell) {
		return
	}
	// Text inputs and modal controls own Tab/Enter. In particular, the active
	// document may still have its caret inside a table while Find, Save As, or
	// Go to Line is open; letting table navigation run first would consume the
	// modal's key press and make those controls appear unresponsive.
	if doc := state.ActiveDocument(); doc != nil && !transientInputOpen(shell) {
		if frame.Key == KeyTab && (mods == 0 || mods == ModShift) {
			id := commands.MarkdownTableNext
			if mods == ModShift {
				id = commands.MarkdownTablePrevious
			}
			if executeCommand(state, shell, id) {
				frame.Key = KeyCodeNone
				return
			}
		}
		if frame.Key == KeyEnter && mods == 0 {
			if executeCommand(state, shell, commands.MarkdownTableEnter) {
				frame.Key = KeyCodeNone
				return
			}
		}
	}
	if frame.Key == KeyEscape {
		if shell.ShowSettings {
			shell.ShowSettings = false
			frame.Key = KeyCodeNone
			return
		}
		if shell.ShowFind {
			shell.ShowFind = false
			shell.ShowReplace = false
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
	if zoom := editorZoomCommand(frame.Key, mods, primary); zoom != "" {
		executeCommand(state, shell, zoom)
		frame.Key = KeyCodeNone
		return
	}
	if !transientInputOpen(shell) && mods == 0 && frame.Key == KeyF2 {
		if executeCommand(state, shell, commands.WorkspaceRename) {
			frame.Key = KeyCodeNone
			return
		}
	}
	if !transientInputOpen(shell) {
		switch {
		case mods == ModAlt && frame.Key == KeyZ:
			toggleWrap(shell, state.ActiveDocument())
			frame.Key = KeyCodeNone
			return
		case mods == primary && frame.Key == KeyH:
			executeCommand(state, shell, commands.DocumentFindReplace)
			frame.Key = KeyCodeNone
			return
		case mods == primary|ModShift && frame.Key == KeyS:
			executeCommand(state, shell, commands.FileSaveAs)
			frame.Key = KeyCodeNone
			return
		case mods == primary|ModShift && frame.Key == KeyT:
			executeCommand(state, shell, commands.DocumentReopenClosed)
			frame.Key = KeyCodeNone
			return
		}
	}
	if !transientInputOpen(shell) {
		if id, ok := commandKeyBinding(state, frame.Key, frame.Text, mods, primary); ok {
			if executeCommand(state, shell, id) {
				frame.Key = KeyCodeNone
				return
			}
		}
	}
	if mods == primary && (frame.Key == KeyCode(',') || (frame.Key == KeyCodeNone && frame.Text == ",")) {
		shell.ShowSettings = !shell.ShowSettings
		frame.Key = KeyCodeNone
		return
	}
	if mods == primary && frame.Key == KeyV && !transientInputOpen(shell) {
		ctx := commandContext(state)
		if ctx.Markdown && !ctx.InFence {
			RequestPaste()
			shell.PendingSmartPaste = true
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
		case KeyS:
			executeCommand(state, shell, commands.FileSaveAs)
		case KeyT:
			executeCommand(state, shell, commands.DocumentReopenClosed)
		case KeyTab:
			executeCommand(state, shell, commands.TabPrevious)
		default:
			return
		}
		frame.Key = KeyCodeNone
	}
}

func commandKeyBinding(state *application.Application, key KeyCode, text string, mods, primary Modifiers) (commands.ID, bool) {
	if mods == primary && (key == KeyCode(',') || (key == KeyCodeNone && text == ",")) {
		return commands.SettingsOpen, true
	}
	if state == nil || state.ActiveDocument() == nil {
		return "", false
	}
	if mods == ModAlt && key == KeyUp {
		return commands.EditMoveLineUp, true
	}
	if mods == ModAlt && key == KeyDown {
		return commands.EditMoveLineDown, true
	}
	if mods != primary && mods != primary|ModShift {
		return "", false
	}
	switch {
	case mods == primary && key == KeyCode(']'):
		return commands.EditIndentLines, true
	case mods == primary && key == KeyCode('['):
		return commands.EditOutdentLines, true
	case mods == primary|ModShift && key == KeyK:
		return commands.EditDeleteLine, true
	case mods == primary && key == KeyEnter:
		return commands.EditInsertLineBelow, true
	case mods == primary|ModShift && key == KeyEnter:
		return commands.EditInsertLineAbove, true
	}
	stroke := ""
	switch key {
	case KeyB:
		stroke = "primary+b"
	case KeyI:
		stroke = "primary+i"
	case KeyK:
		stroke = "primary+k"
	case KeyH:
		stroke = "primary+h"
	case KeyCode('/'):
		stroke = "primary+/"
	default:
		if text == "/" {
			stroke = "primary+/"
		}
	}
	if stroke == "" {
		return "", false
	}
	ctx := commandContext(state)
	if ctx.Markdown && !ctx.ProjectionCurrent {
		// A shortcut is an explicit editing action, so it may use the same
		// synchronous current-source refresh as command execution. Passive
		// surfaces below remain non-blocking when the debounced projection is
		// stale.
		if doc := state.ActiveDocument(); doc != nil {
			if request, err := commands.NewRequest(doc, commands.DocumentFormat); err == nil {
				ctx.ProjectionCurrent = request.ProjectionsCurrent
				ctx.InFence = request.InFence
			}
		}
	}
	return commands.DefaultRegistry().Match(stroke, ctx)
}

func commandContext(state *application.Application) commands.CommandContext {
	ctx := commands.CommandContext{}
	if state == nil {
		return ctx
	}
	ctx.HasWorkspace = state.HasWorkspace
	ctx.HasTrasher = state.Trasher != nil
	doc := state.ActiveDocument()
	if doc == nil || doc.Editor == nil {
		return ctx
	}
	ctx.ActiveDocument = true
	ctx.RootLanguage = doc.RootLanguage
	ctx.Markdown = doc.RootLanguage == string(language.Markdown)
	ctx.Code = !ctx.Markdown
	ctx.EditorFocused = true
	ctx.Cursor = doc.Editor.Cursor
	ctx.SelectionStart, ctx.SelectionEnd = doc.Editor.Selection()
	if ctx.SelectionStart > ctx.SelectionEnd {
		ctx.SelectionStart, ctx.SelectionEnd = ctx.SelectionEnd, ctx.SelectionStart
	}
	ctx.HasSelection = ctx.SelectionStart != ctx.SelectionEnd
	ctx.ProjectionCurrent = doc.DerivedCurrent()
	if ctx.Markdown && ctx.ProjectionCurrent {
		for _, table := range doc.Projections.Tables {
			if ctx.Cursor >= table.StartByte && ctx.Cursor < table.EndByte {
				ctx.InTable = true
			}
		}
		for _, task := range doc.Projections.Tasks {
			if ctx.Cursor >= task.StartByte && ctx.Cursor <= task.EndByte {
				ctx.InTask = true
			}
		}
		for _, block := range doc.Projections.Blocks {
			if block.Kind == document.BlockCode && ctx.Cursor >= block.StartByte && ctx.Cursor < block.EndByte {
				ctx.InFence = true
			}
			if block.Kind == document.BlockCode && ctx.HasSelection && ctx.SelectionStart < block.EndByte && ctx.SelectionEnd > block.StartByte {
				ctx.InFence = true
			}
		}
	} else if ctx.Markdown {
		// Without a current structural projection the safe passive-context
		// answer is "possibly inside a fence". Explicit commands reparse on
		// invocation; the frame path does not.
		ctx.InFence = true
	}
	return ctx
}

func transientInputOpen(shell *workbenchState) bool {
	if shell == nil {
		return false
	}
	return shell.ShowSettings || shell.ShowOpen || shell.ShowFolder || shell.ShowQuickOpen || shell.Mutation.Open || shell.TrashConfirmation.Open ||
		shell.ShowSaveAs || shell.ShowSaveAsOverwrite || shell.ShowFind ||
		shell.ShowGoToLine || shell.ShowSearch || shell.ShowRecent ||
		shell.ShowCompare || shell.Slash.Open || shell.Fence.Open
}

// editorZoomCommand maps the platform-independent physical key codes to the
// editor font commands. On a US keyboard, plus is the '=' key with Shift;
// accepting an unshifted '=' as well accommodates keyboards that report the
// produced character rather than the physical legend. PrimaryMod is Cmd on
// Apple hosts and Ctrl elsewhere.
func editorZoomCommand(key KeyCode, mods, primary Modifiers) commands.ID {
	if mods != primary && mods != primary|ModShift {
		return ""
	}
	switch {
	case key == KeyCode('-') && mods == primary:
		return commands.ViewDecreaseFontSize
	case (key == KeyCode('=') || key == KeyCode('+')) && (mods == primary || mods == primary|ModShift):
		return commands.ViewIncreaseFontSize
	case key == Key0 && mods == primary:
		return commands.ViewResetFontSize
	default:
		return ""
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
	if isProductCommand(id) {
		var argument string
		if len(args) > 0 {
			argument, _ = args[0].(string)
		}
		if doc := state.ActiveDocument(); doc != nil {
			ok := applyDocumentCommand(doc, id, argument)
			if ok && id == commands.MarkdownInsertCodeBlock {
				shell.Fence = fenceState{Open: true, DocumentID: state.Active}
			} else if ok && id == commands.MarkdownSetFenceLanguage {
				shell.Fence = fenceState{}
			}
			return ok
		}
		return false
	}
	switch id {
	case commands.FileOpen:
		shell.ShowSettings = false
		if path := explicitCommandPath(args); path != "" {
			return state.OpenPath(path) == nil
		}
		openPathPicker(state, shell)
		return true
	case commands.SettingsOpen:
		ClearFocus()
		shell.ShowSettings = !shell.ShowSettings
		shell.ShowFind = false
		shell.ShowReplace = false
		shell.ShowSearch = false
		shell.ShowQuickOpen = false
		return true
	case commands.FileSave:
		id := state.Active
		beforeDoc := state.Documents[id]
		var beforePath string
		var beforeVersion workspace.DiskVersion
		var beforeDirty bool
		if beforeDoc != nil {
			beforePath, beforeVersion, beforeDirty = beforeDoc.Path, beforeDoc.DiskVersion, beforeDoc.Dirty()
		}
		err := state.SaveActive()
		var path string
		if doc := state.Documents[id]; doc != nil {
			path = doc.Path
		}
		recordSaveNotice(shell, err, saveWarningCommitted(state, err, path, beforePath, beforeVersion, beforeDirty))
	case commands.FileSaveAs:
		if doc := state.ActiveDocument(); doc != nil {
			shell.SaveAsPath = doc.Path
			shell.SaveAsError = ""
			clearSaveNotice(shell)
			shell.ShowSaveAs = true
		}
	case commands.DocumentFind:
		if !shell.ShowFind {
			ClearFocus()
			shell.FindEpoch++
		}
		shell.ShowFind = true
		shell.ShowReplace = false
		shell.ShowSearch = false
	case commands.DocumentFindReplace:
		if !shell.ShowFind {
			ClearFocus()
			shell.FindEpoch++
		}
		shell.ShowFind = true
		shell.ShowReplace = true
		shell.ShowSearch = false
	case commands.QuickOpen:
		shell.ShowSettings = false
		if !shell.ShowQuickOpen {
			ClearFocus()
			shell.QuickOpenEpoch++
		}
		shell.ShowQuickOpen = true
		shell.ShowFind = false
		shell.ShowReplace = false
	case commands.WorkspaceSearch:
		shell.ShowSearch = true
		shell.ShowFind = false
		shell.ShowReplace = false
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
		shell.ShowSettings = false
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
	case commands.ViewIncreaseFontSize:
		setEditorFontSize(state, shell, adjustEditorFontSize(editorFontSize(shell), 1))
		return true
	case commands.ViewDecreaseFontSize:
		setEditorFontSize(state, shell, adjustEditorFontSize(editorFontSize(shell), -1))
		return true
	case commands.ViewResetFontSize:
		setEditorFontSize(state, shell, defaultEditorFontSize)
		return true
	case viewToggleLineNumbers:
		toggleLineNumbers(shell)
		return true
	case viewToggleWrap:
		toggleWrap(shell, state.ActiveDocument())
		return true
	case commands.OutlineToggle:
		shell.SidebarMode = SidebarOutline
		shell.SidebarVisible = true
	case commands.WorkspaceRefresh:
		shell.Tree.Expanded = make(map[string]bool)
		shell.Tree.RowIDs = nil
		clearTreeSelection(&shell.Tree)
		shell.Tree.VisiblePaths = nil
	case commands.WorkspaceToggleFolder:
		if relative := commandString(args); relative != "" {
			tree := &shell.Tree
			if tree.Expanded == nil {
				tree.Expanded = make(map[string]bool)
			}
			tree.Expanded[relative] = !tree.Expanded[relative]
		}
	case commands.WorkspaceNewFile:
		beginWorkspaceMutation(shell, mutationNewFile, workspaceMutationPath(state, commandString(args)), "")
		return true
	case commands.WorkspaceNewFolder:
		beginWorkspaceMutation(shell, mutationNewFolder, workspaceMutationPath(state, commandString(args)), "")
		return true
	case commands.WorkspaceRename:
		path := commandPath(state, args)
		if path == "" {
			return false
		}
		beginWorkspaceMutation(shell, mutationRename, path, filepath.Base(path))
		return true
	case commands.WorkspaceMove:
		if len(args) > 1 {
			source, sourceOK := args[0].(string)
			destination, destinationOK := args[1].(string)
			if sourceOK && destinationOK {
				if err := state.MovePath(source, destination); err != nil {
					shell.Mutation.Error = err.Error()
					return false
				}
				resetTreeAfterMutation(shell)
				return true
			}
		}
		path := commandPath(state, args)
		if path == "" {
			return false
		}
		beginWorkspaceMutation(shell, mutationMove, path, "")
		return true
	case commands.WorkspaceTrash:
		path := commandPath(state, args)
		if path == "" {
			return false
		}
		if err := state.TrashPath(path, false); err != nil {
			if errors.Is(err, application.ErrDirty) {
				shell.TrashConfirmation = workspaceTrashConfirmation{Open: true, Path: path}
				return true
			}
			shell.Mutation.Error = err.Error()
			return false
		}
		resetTreeAfterMutation(shell)
		return true
	case commands.FileOpenRecent:
		shell.ShowSettings = false
		if path := explicitCommandPath(args); path != "" {
			if state.OpenPath(path) == nil {
				shell.ShowRecent = false
				return true
			}
		} else {
			shell.ShowRecent = true
			shell.ShowQuickOpen = false
			shell.ShowFind = false
			shell.ShowReplace = false
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
			if commandContext(state).Markdown {
				shell.PendingSmartPaste = true
			}
			RequestPaste()
		}
	case commands.EditSelectAll:
		if doc := state.ActiveDocument(); doc != nil {
			doc.Editor.SelectAll()
		}
	}
	return false
}

func isProductCommand(id commands.ID) bool {
	switch id {
	case commands.DocumentFormat, commands.ItemToggle, commands.CommentToggle,
		commands.MarkdownToggleStrong, commands.MarkdownToggleEmphasis, commands.MarkdownToggleStrike,
		commands.MarkdownToggleInlineCode, commands.MarkdownInsertLink, commands.MarkdownHeading1,
		commands.MarkdownHeading2, commands.MarkdownHeading3, commands.MarkdownToggleBulletedList,
		commands.MarkdownToggleNumberedList, commands.MarkdownToggleQuote, commands.MarkdownInsertTask,
		commands.MarkdownInsertCodeBlock, commands.MarkdownSetFenceLanguage, commands.MarkdownInsertTable, commands.MarkdownInsertDivider,
		commands.MarkdownTableNext, commands.MarkdownTablePrevious, commands.MarkdownTableEnter,
		commands.MarkdownSmartPaste, commands.EditIndentLines, commands.EditOutdentLines,
		commands.EditDeleteLine, commands.EditInsertLineAbove, commands.EditInsertLineBelow,
		commands.EditMoveLineUp, commands.EditMoveLineDown, commands.EditDuplicateLine,
		commands.EditJoinLines:
		return true
	default:
		return false
	}
}

func workspaceMutationPath(state *application.Application, path string) string {
	if path != "" {
		return path
	}
	if state != nil && state.HasWorkspace {
		return state.Workspace.Root
	}
	return ""
}

func beginWorkspaceMutation(shell *workbenchState, kind workspaceMutationKind, path, text string) {
	if shell == nil {
		return
	}
	shell.Mutation = workspaceMutationState{
		Open:       true,
		Kind:       kind,
		Path:       path,
		Text:       text,
		Generation: shell.Mutation.Generation + 1,
	}
	shell.ContextMenu.Open = false
}

func resetTreeAfterMutation(shell *workbenchState) {
	if shell == nil {
		return
	}
	shell.Tree.Expanded = make(map[string]bool)
	clearTreeSelection(&shell.Tree)
	shell.Tree.VisiblePaths = nil
	if shell.Tree.renderDepth > 0 {
		shell.Tree.rowsDirty = true
	} else {
		shell.Tree.RowIDs = nil
		shell.Tree.rowsDirty = false
	}
	shell.Mutation = workspaceMutationState{}
	shell.TrashConfirmation = workspaceTrashConfirmation{}
}

func commitWorkspaceMutation(state *application.Application, shell *workbenchState) bool {
	if state == nil || shell == nil || !shell.Mutation.Open {
		return false
	}
	mutation := shell.Mutation
	text := strings.TrimSpace(mutation.Text)
	if text == "" {
		shell.Mutation.Error = "Enter a name or destination."
		return false
	}
	var err error
	switch mutation.Kind {
	case mutationNewFile:
		err = state.CreateFile(workspaceChildPath(state, mutation.Path, text))
	case mutationNewFolder:
		err = state.CreateDirectory(workspaceChildPath(state, mutation.Path, text))
	case mutationRename:
		err = state.RenamePath(mutation.Path, text)
	case mutationMove:
		err = state.MovePath(mutation.Path, text)
	}
	if err != nil {
		shell.Mutation.Error = err.Error()
		return false
	}
	resetTreeAfterMutation(shell)
	return true
}

func workspaceChildPath(state *application.Application, parent, name string) string {
	if state == nil || !state.HasWorkspace {
		return name
	}
	parentRelative := workspaceRelative(state, parent)
	if parentRelative == "." {
		parentRelative = ""
	}
	return filepath.Join(parentRelative, name)
}

func workspaceMutationTitle(kind workspaceMutationKind) string {
	switch kind {
	case mutationNewFile:
		return "New file"
	case mutationNewFolder:
		return "New folder"
	case mutationRename:
		return "Rename"
	case mutationMove:
		return "Move"
	default:
		return "Workspace"
	}
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
	matches := currentFindMatches(state, shell)
	if len(matches) == 0 {
		return
	}
	doc := state.ActiveDocument()
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

// currentFindMatches retains the current document's search results between
// frames and navigation commands. Editor revisions change whenever document
// bytes change, so this key also invalidates the cache after edits or reloads.
func currentFindMatches(state *application.Application, shell *workbenchState) []application.CurrentMatch {
	doc := state.ActiveDocument()
	id := state.Active
	query := shell.FindQuery
	var revision uint64
	var currentEditor *editor.ScratchEditor
	if doc != nil {
		revision = doc.Revision()
		currentEditor = doc.Editor
	}
	if shell.findMatchesValid && shell.findDocument == id && shell.findEditor == currentEditor && shell.findRevision == revision && shell.findMatchesQuery == query {
		return shell.findMatches
	}
	shell.findMatchesValid = true
	shell.findDocument = id
	shell.findEditor = currentEditor
	shell.findRevision = revision
	shell.findMatchesQuery = query
	shell.findMatches = nil
	if doc == nil || id == "" || query == "" {
		return nil
	}
	shell.findMatches = state.FindCurrent(id, []byte(query))
	return shell.findMatches
}

func replaceCurrentMatch(state *application.Application, shell *workbenchState) bool {
	if state == nil || shell == nil {
		return false
	}
	doc := state.ActiveDocument()
	matches := currentFindMatches(state, shell)
	if doc == nil || len(matches) == 0 {
		return false
	}
	anchor, cursor := doc.Editor.Selection()
	from, to := anchor, cursor
	if from > to {
		from, to = to, from
	}
	index := 0
	for i, match := range matches {
		if match.Start == from && match.End == to {
			index = i
			break
		}
		if match.Start >= to {
			index = i
			break
		}
		index = (i + 1) % len(matches)
	}
	target := matches[index]
	replacement := []byte(shell.ReplaceQuery)
	end := target.Start + len(replacement)
	if err := doc.ReplaceWithSelection(target.Start, target.End, replacement, end, end); err != nil {
		return false
	}
	shell.findMatchesValid = false
	return true
}

func replaceAllMatches(state *application.Application, shell *workbenchState) bool {
	if state == nil || shell == nil {
		return false
	}
	doc := state.ActiveDocument()
	matches := currentFindMatches(state, shell)
	if doc == nil || len(matches) == 0 {
		return false
	}
	source := doc.Editor.Buffer.Text()
	queryLength := len([]byte(shell.FindQuery))
	replacement := []byte(shell.ReplaceQuery)
	next := make([]byte, 0, len(source)+len(matches)*(len(replacement)-queryLength))
	last := 0
	for _, match := range matches {
		if match.Start < last || match.End > len(source) {
			return false
		}
		next = append(next, source[last:match.Start]...)
		next = append(next, replacement...)
		last = match.End
	}
	next = append(next, source[last:]...)
	anchor, cursor := doc.Editor.Selection()
	delta := len(replacement) - queryLength
	anchor = remapReplaceAllPosition(anchor, matches, delta)
	cursor = remapReplaceAllPosition(cursor, matches, delta)
	if err := doc.ReplaceWithSelection(0, len(source), next, anchor, cursor); err != nil {
		return false
	}
	shell.findMatchesValid = false
	return true
}

func remapReplaceAllPosition(position int, matches []application.CurrentMatch, delta int) int {
	shift := 0
	queryLength := 0
	if len(matches) > 0 {
		queryLength = matches[0].End - matches[0].Start
	}
	for _, match := range matches {
		if position < match.Start {
			break
		}
		if position <= match.End {
			return match.Start + shift + queryLength + delta
		}
		shift += delta
	}
	return position + shift
}

func openTreeContextMenu(shell *workbenchState, path string, isDir bool) {
	shell.ContextMenu = contextMenuState{
		Open: true, Generation: shell.ContextMenu.Generation + 1,
		Kind: contextMenuTree, Path: path, IsDir: isDir, Position: GetInputState().MousePoint,
	}
}

func openWorkspaceContextMenu(shell *workbenchState, path string) {
	shell.ContextMenu = contextMenuState{
		Open: true, Generation: shell.ContextMenu.Generation + 1,
		Kind: contextMenuTree, Path: path, IsDir: true, WorkspaceRoot: true, Position: GetInputState().MousePoint,
	}
}

func openTabContextMenu(shell *workbenchState, id application.DocumentID, path string) {
	shell.ContextMenu = contextMenuState{
		Open: true, Generation: shell.ContextMenu.Generation + 1,
		Kind: contextMenuTab, ID: id, Path: path, Position: GetInputState().MousePoint,
	}
}

func contextMenuItem(theme Theme, label string) bool {
	var clicked bool
	Container(Attrs(Row, Expand, CrossMid, FixHeight(23), Pad2(0, 8)), func() {
		_, secondaryGesture := contextMenuGesture()
		button := ProcessButtonEvents(secondaryGesture)
		if button.Hovered {
			ModAttrs(BackgroundVec(theme.Selection), Grad(0, 0, -5, 0))
		}
		Label(label, FontSize(11), TextColorVec(theme.Ink))
		clicked = button.Clicked && GetInputState().MouseButton == MousePrimary && !secondaryGesture
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
		menuID = floatingSurfaceWithKey(fmt.Sprintf("context-menu-%d", menu.Generation), theme, Attrs(FloatVec(menu.Position), FixWidth(224), Clip), Attrs(Gap(1), Pad(5), Clip), func() {
			contextPaths := []string(nil)
			if menu.Kind == contextMenuTree {
				contextPaths = treeContextPaths(state, shell, menu)
			}
			if menu.Kind == contextMenuTab {
				if contextMenuItem(theme, "Close") {
					executeCommand(state, shell, commands.DocumentClose, menu.ID)
					shell.ContextMenu.Open = false
				}
				if contextMenuItem(theme, "Close Others") {
					executeCommand(state, shell, commands.DocumentCloseOthers, menu.ID)
					shell.ContextMenu.Open = false
				}
				if contextMenuItem(theme, "Close All") {
					executeCommand(state, shell, commands.DocumentCloseAll)
					shell.ContextMenu.Open = false
				}
				if contextMenuItem(theme, "Reopen Closed") {
					executeCommand(state, shell, commands.DocumentReopenClosed)
					shell.ContextMenu.Open = false
				}
			} else {
				if menu.WorkspaceRoot {
					if contextMenuItem(theme, "New File") {
						executeCommand(state, shell, commands.WorkspaceNewFile, menu.Path)
					}
					if contextMenuItem(theme, "New Folder") {
						executeCommand(state, shell, commands.WorkspaceNewFolder, menu.Path)
					}
					if contextMenuItem(theme, "Refresh Workspace") {
						executeCommand(state, shell, commands.WorkspaceRefresh)
						shell.ContextMenu.Open = false
					}
					if contextMenuItem(theme, "Collapse All") {
						shell.Tree.Expanded = make(map[string]bool)
						shell.Tree.RowIDs = nil
						shell.ContextMenu.Open = false
					}
					if contextMenuItem(theme, "Reveal Workspace") {
						executeCommand(state, shell, commands.FileReveal, menu.Path)
						shell.ContextMenu.Open = false
					}
				} else if menu.IsDir {
					label := "Expand"
					if shell.Tree.Expanded[workspaceRelative(state, menu.Path)] {
						label = "Collapse"
					}
					if contextMenuItem(theme, label) {
						executeCommand(state, shell, commands.WorkspaceToggleFolder, workspaceRelative(state, menu.Path))
						shell.ContextMenu.Open = false
					}
				} else if contextMenuItem(theme, "Open") {
					executeCommand(state, shell, commands.FileOpen, menu.Path)
					shell.ContextMenu.Open = false
				}
				if !menu.WorkspaceRoot {
					parent := menu.Path
					if !menu.IsDir {
						parent = filepath.Dir(parent)
					}
					if contextMenuItem(theme, "New File") {
						executeCommand(state, shell, commands.WorkspaceNewFile, parent)
					}
					if contextMenuItem(theme, "New Folder") {
						executeCommand(state, shell, commands.WorkspaceNewFolder, parent)
					}
					if contextMenuItem(theme, "Rename") {
						executeCommand(state, shell, commands.WorkspaceRename, menu.Path)
					}
					if state.Trasher != nil && contextMenuItem(theme, "Move to Trash") {
						executeCommand(state, shell, commands.WorkspaceTrash, menu.Path)
					}
				}
			}
			copyPathLabel := "Copy Path"
			copyRelativeLabel := "Copy Relative Path"
			if len(contextPaths) > 1 {
				copyPathLabel = "Copy Paths"
				copyRelativeLabel = "Copy Relative Paths"
			}
			if contextMenuItem(theme, copyPathLabel) {
				if len(contextPaths) > 1 {
					RequestTextCopy(strings.Join(contextPaths, "\n"))
				} else {
					executeCommand(state, shell, commands.FileCopyPath, menu.Path)
				}
				shell.ContextMenu.Open = false
			}
			if contextMenuItem(theme, copyRelativeLabel) {
				if len(contextPaths) > 1 {
					relative := make([]string, 0, len(contextPaths))
					for _, path := range contextPaths {
						relative = append(relative, relativePath(state, path))
					}
					RequestTextCopy(strings.Join(relative, "\n"))
				} else {
					executeCommand(state, shell, commands.FileCopyRelativePath, menu.Path)
				}
				shell.ContextMenu.Open = false
			}
			if !menu.WorkspaceRoot && contextMenuItem(theme, "Reveal") {
				executeCommand(state, shell, commands.FileReveal, menu.Path)
				shell.ContextMenu.Open = false
			}
		})
		shell.ContextMenu.MenuID = menuID
		if GetFrameInput().Mouse == MouseClick && GetInputState().MouseButton == MousePrimary && !contextMenuButton() && !IdIsHovered(menuID) {
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
		popupID = floatingSurfaceWithKey("recent-files-popup", theme, Attrs(Float(8, 38), FixWidth(360), Clip), Attrs(Gap(1), Pad(6), Clip), func() {
			Label("Open Recent", FontWeight(WeightBold), FontSize(12), TextColorVec(theme.Ink))
			paths := state.RecentPaths()
			if len(paths) == 0 {
				Label("No recent files", FontSize(11), TextColorVec(theme.Muted))
			}
			for _, path := range paths {
				path := path
				if contextMenuItem(theme, filepathBase(path)) {
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

func proseWraps(path string) bool {
	return language.SurfaceForPath(path) == language.SurfaceProse
}

func documentSurfaceLabel(doc *document.Document) string {
	if doc == nil {
		return ""
	}
	if language.SurfaceForPath(doc.Path) == language.SurfaceProse {
		if language.ID(doc.RootLanguage) == language.Markdown {
			return "Markdown"
		}
		return "Text"
	}
	if doc.RootLanguage == "" || language.ID(doc.RootLanguage) == language.PlainText {
		return "Code"
	}
	return doc.RootLanguage
}

func markdownLineDecoration(doc *document.Document, theme Theme) func(int) EditorLineDecoration {
	return func(line int) EditorLineDecoration {
		if doc == nil || doc.RootLanguage != string(language.Markdown) || !doc.DerivedCurrent() {
			return EditorLineDecoration{}
		}
		start, end, ok := doc.Editor.Buffer.LineRange(line)
		if !ok {
			return EditorLineDecoration{}
		}
		for _, table := range doc.Projections.Tables {
			for _, row := range table.Rows {
				if row.StartByte != start {
					continue
				}
				background := theme.ChromeRaised
				background[3] = 0.16
				if row.Header {
					background = theme.Highlight
					background[3] = 0.24
				}
				if row.Delimiter {
					background = theme.ChromeInset
					background[3] = 0.10
					accent := theme.Border
					accent[3] = 0.72
					return EditorLineDecoration{Background: background, Accent: accent}
				}
				return EditorLineDecoration{Background: background}
			}
		}
		for _, block := range doc.Projections.Blocks {
			if block.StartByte >= end || block.EndByte <= start {
				continue
			}
			background := theme.ChromeInset
			switch block.Kind {
			case document.BlockQuote:
				background = theme.SelectionHighlight
			case document.BlockTable:
				background = theme.ChromeRaised
			case document.BlockThematicBreak:
				background = theme.ChromeInset
			case document.BlockList:
				return EditorLineDecoration{}
			}
			background[3] = 0.16
			return EditorLineDecoration{Background: background}
		}
		return EditorLineDecoration{}
	}
}

func markdownLineSpacing(doc *document.Document) func(int) float32 {
	return func(line int) float32 {
		if doc == nil || doc.RootLanguage != string(language.Markdown) || !doc.DerivedCurrent() {
			return 0
		}
		start, _, ok := doc.Editor.Buffer.LineRange(line)
		if !ok {
			return 0
		}
		for _, heading := range doc.Projections.Headings {
			if heading.StartByte != start {
				continue
			}
			switch heading.Level {
			case 1:
				return 7
			case 2:
				return 5
			default:
				return 3
			}
		}
		return 0
	}
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
