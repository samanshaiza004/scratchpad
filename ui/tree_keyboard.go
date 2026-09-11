package ui

import (
	"path/filepath"
	"strings"
	"time"
	"unicode/utf8"

	"scratchpad/application"
	"scratchpad/commands"

	. "go.hasen.dev/shirei"
)

const treeTypeAheadTimeout = 700 * time.Millisecond

func treeHasFocus(shell *workbenchState) bool {
	return shell != nil && shell.Tree.FocusID != nil && IdHasFocus(shell.Tree.FocusID)
}

func treeKeyboardFallbackPath(state *application.Application, tree *treeState) string {
	if tree == nil {
		return ""
	}
	navigation := NewTreeNavigation(tree.VisiblePaths)
	if tree.FocusedPath != "" && navigation.Index(tree.FocusedPath) >= 0 {
		return tree.FocusedPath
	}
	if tree.LeadPath != "" && navigation.Index(tree.LeadPath) >= 0 {
		return tree.LeadPath
	}
	if state != nil && state.ActiveDocument() != nil && state.HasWorkspace {
		if relative, err := state.Workspace.RelativePath(state.ActiveDocument().Path); err == nil && navigation.Index(relative) >= 0 {
			return relative
		}
	}
	if path, ok := navigation.Home(); ok {
		return path
	}
	return ""
}

func treeKeyboardAbsolutePath(state *application.Application, tree *treeState) string {
	if state == nil || !state.HasWorkspace || tree == nil || tree.FocusedPath == "" {
		return ""
	}
	return filepath.Join(state.Workspace.Root, tree.FocusedPath)
}

func treeKeyboardDirectory(state *application.Application, relative string) bool {
	if state == nil || !state.HasWorkspace || relative == "" {
		return false
	}
	info, err := state.Workspace.Stat(relative)
	return err == nil && info.IsDir()
}

func treeKeyboardSelect(tree *treeState, path string, modifiers, primary Modifiers) {
	if tree == nil || path == "" {
		return
	}
	previous := tree.FocusedPath
	tree.FocusedPath = path
	if modifiers&ModShift != 0 && previous != "" && tree.AnchorPath == "" {
		tree.AnchorPath = previous
	}
	if modifiers&primary != 0 && modifiers&ModShift == 0 {
		ensureTreeSelection(tree)
		if len(tree.Selected) == 0 {
			treeSelectionClick(tree, path, 0, primary, tree.VisiblePaths)
		}
		return
	}
	treeSelectionClick(tree, path, modifiers, primary, tree.VisiblePaths)
}

func treeKeyboardReveal(shell *workbenchState) {
	if shell == nil || shell.Tree.FocusedPath == "" {
		return
	}
	rowID := shell.Tree.RowIDs[shell.Tree.FocusedPath]
	if rowID == nil || shell.Tree.ViewportID == nil {
		return
	}
	revealPopupSelection(shell.Tree.ViewportID, rowID)
}

func treeKeyboardPageSize(shell *workbenchState) int {
	if shell == nil || shell.Tree.ViewportID == nil {
		return 8
	}
	data := GetRenderDataOf(shell.Tree.ViewportID)
	page := int(data.ResolvedSize[1] / 24)
	if page < 1 {
		return 1
	}
	return page
}

func treeKeyboardMove(tree *treeState, target string, modifiers, primary Modifiers) bool {
	if tree == nil || target == "" {
		return false
	}
	treeKeyboardSelect(tree, target, modifiers, primary)
	return true
}

func treeKeyboardToggleFolder(tree *treeState, path string) bool {
	if tree == nil || path == "" {
		return false
	}
	if tree.Expanded == nil {
		tree.Expanded = make(map[string]bool)
	}
	tree.Expanded[path] = !tree.Expanded[path]
	tree.VisiblePaths = nil
	tree.RowIDs = nil
	return true
}

func treeKeyboardActivate(state *application.Application, shell *workbenchState) bool {
	if state == nil || shell == nil {
		return false
	}
	path := treeKeyboardAbsolutePath(state, &shell.Tree)
	if path == "" {
		return false
	}
	if treeKeyboardDirectory(state, shell.Tree.FocusedPath) {
		return treeKeyboardToggleFolder(&shell.Tree, shell.Tree.FocusedPath)
	}
	return executeCommand(state, shell, commands.FileOpen, path)
}

func beginTreeRename(state *application.Application, shell *workbenchState) bool {
	if state == nil || shell == nil {
		return false
	}
	path := treeKeyboardAbsolutePath(state, &shell.Tree)
	if path == "" || path == filepath.Clean(state.Workspace.Root) {
		return false
	}
	shell.TreeRename = treeRenameState{
		Open:       true,
		Path:       path,
		Text:       filepath.Base(path),
		Generation: shell.TreeRename.Generation + 1,
	}
	ClearFocus()
	return true
}

func commitTreeRename(state *application.Application, shell *workbenchState) bool {
	if state == nil || shell == nil || !shell.TreeRename.Open {
		return false
	}
	text := strings.TrimSpace(shell.TreeRename.Text)
	if text == "" {
		shell.TreeRename.Error = "Enter a name."
		return false
	}
	oldPath := shell.TreeRename.Path
	if err := state.RenamePath(oldPath, text); err != nil {
		shell.TreeRename.Error = err.Error()
		return false
	}
	newPath := filepath.Join(filepath.Dir(oldPath), text)
	newRelative := workspaceRelative(state, newPath)
	resetTreeAfterMutation(shell)
	shell.Tree.FocusedPath = newRelative
	shell.Tree.Selected = map[string]bool{newRelative: true}
	shell.Tree.AnchorPath = newRelative
	shell.Tree.LeadPath = newRelative
	return true
}

func treeKeyboardTypeAhead(state *application.Application, shell *workbenchState, text string, now time.Time) bool {
	if state == nil || shell == nil || text == "" || !treeKeyboardPrintable(text) {
		return false
	}
	if now.Sub(shell.Tree.TypeAheadAt) > treeTypeAheadTimeout {
		shell.Tree.TypeAhead = ""
	}
	prefix := shell.Tree.TypeAhead + text
	navigation := NewTreeNavigation(shell.Tree.VisiblePaths)
	current := shell.Tree.FocusedPath
	match, ok := navigation.TypeAhead(current, prefix)
	if !ok {
		prefix = text
		match, ok = navigation.TypeAhead(current, prefix)
	}
	if !ok {
		return true
	}
	shell.Tree.TypeAhead = prefix
	shell.Tree.TypeAheadAt = now
	treeKeyboardSelect(&shell.Tree, match, 0, PrimaryMod())
	treeKeyboardReveal(shell)
	return true
}

func treeKeyboardPrintable(text string) bool {
	if !utf8.ValidString(text) {
		return false
	}
	for _, r := range text {
		if r < 0x20 || r == 0x7f {
			return false
		}
	}
	return strings.TrimSpace(text) != "" || strings.Contains(text, " ")
}

// handleTreeKeyboardInput is called before the normal editor/global command
// bindings when the composite Files tree owns focus. It consumes only keys
// that are meaningful to the tree; editor, modal, and text-input behavior is
// therefore left unchanged outside this focus scope.
func handleTreeKeyboardInput(state *application.Application, shell *workbenchState) bool {
	if state == nil || shell == nil || !treeHasFocus(shell) || !state.HasWorkspace {
		return false
	}
	frame := GetFrameInput()
	modifiers := GetInputState().Modifiers
	primary := PrimaryMod()
	now := time.Now()
	if len(shell.Tree.VisiblePaths) == 0 {
		shell.Tree.VisiblePaths = visibleTreePaths(state, &shell.Tree, "")
	}
	shell.Tree.FocusedPath = treeKeyboardFallbackPath(state, &shell.Tree)
	navigation := NewTreeNavigation(shell.Tree.VisiblePaths)
	current := shell.Tree.FocusedPath

	move := func(target string) bool {
		if !treeKeyboardMove(&shell.Tree, target, modifiers, primary) {
			return false
		}
		shell.Tree.TypeAhead = ""
		treeKeyboardReveal(shell)
		return true
	}

	switch frame.Key {
	case KeyUp:
		if current == "" {
			if target, ok := navigation.End(); ok {
				return move(target)
			}
		}
		target, ok := navigation.Previous(current)
		return ok && move(target)
	case KeyDown:
		if current == "" {
			if target, ok := navigation.Home(); ok {
				return move(target)
			}
		}
		target, ok := navigation.Next(current)
		return ok && move(target)
	case KeyHome:
		target, ok := navigation.Home()
		return ok && move(target)
	case KeyEnd:
		target, ok := navigation.End()
		return ok && move(target)
	case KeyPageUp:
		target := current
		for i := 0; i < treeKeyboardPageSize(shell); i++ {
			var ok bool
			target, ok = navigation.Previous(target)
			if !ok {
				break
			}
		}
		return target != current && move(target)
	case KeyPageDown:
		target := current
		for i := 0; i < treeKeyboardPageSize(shell); i++ {
			var ok bool
			target, ok = navigation.Next(target)
			if !ok {
				break
			}
		}
		return target != current && move(target)
	case KeyRight:
		if current == "" || !treeKeyboardDirectory(state, current) {
			return false
		}
		if !shell.Tree.Expanded[current] {
			return treeKeyboardToggleFolder(&shell.Tree, current)
		}
		child, ok := navigation.FirstChild(current)
		return ok && move(child)
	case KeyLeft:
		if current == "" || !treeKeyboardDirectory(state, current) || !shell.Tree.Expanded[current] {
			parent, ok := navigation.Parent(current)
			return ok && move(parent)
		}
		return treeKeyboardToggleFolder(&shell.Tree, current)
	case KeyEnter, KeySpace:
		return treeKeyboardActivate(state, shell)
	case KeyF2:
		return beginTreeRename(state, shell)
	case KeyDeleteForward:
		if state.Trasher != nil {
			if path := treeKeyboardAbsolutePath(state, &shell.Tree); path != "" {
				_ = executeCommand(state, shell, commands.WorkspaceTrash, path)
			}
		}
		// Keep Delete local to the tree even when this platform has no trash
		// adapter. It must never fall through to document editing.
		return true
	case KeyEscape:
		if shell.Tree.TypeAhead != "" {
			shell.Tree.TypeAhead = ""
			shell.Tree.TypeAheadAt = time.Time{}
			return true
		}
	}
	if modifiers == 0 && frame.Key == KeyCodeNone && treeKeyboardTypeAhead(state, shell, frame.Text, now) {
		return true
	}
	return false
}
