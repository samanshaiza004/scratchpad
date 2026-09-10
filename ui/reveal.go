package ui

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"

	"scratchpad/application"
	"scratchpad/document"
	"scratchpad/editor"

	. "go.hasen.dev/shirei/widgets"
)

// revealPath delegates the file-manager integration to the host OS. Keeping
// this behind the command dispatcher makes the workbench behavior testable
// without launching a native process.
func revealPath(path string) error {
	if path == "" {
		return errors.New("empty path")
	}
	var command *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		command = exec.Command("open", "-R", path)
	case "windows":
		command = exec.Command("explorer", "/select,"+path)
	default:
		// xdg-open opens files in their associated application, so reveal the
		// containing directory instead.
		directory := filepath.Dir(path)
		if info, err := os.Stat(path); err == nil && info.IsDir() {
			directory = path
		}
		command = exec.Command("xdg-open", directory)
	}
	return command.Start()
}

// RevealPolicy controls how an explicit navigation request positions its
// target in the editor viewport. It is deliberately a view concern: changing
// the logical editor position does not imply changing the viewport.
type RevealPolicy uint8

const (
	RevealMinimal RevealPolicy = iota
	RevealCenterIfOutside
	RevealNearTop
)

// EditorRevealRequest is a transient request to reveal a source range. The
// document pointer and generation together prevent a request for an old
// document instance or revision from being applied after an edit, reload, or
// close/reopen cycle. Requests live in workbenchState rather than
// application.ViewState because view state is persisted to session/recovery.
type EditorRevealRequest struct {
	Document   *document.Document
	StartByte  int
	EndByte    int
	Policy     RevealPolicy
	Horizontal bool
	Generation uint64
}

// editorListKey is application-owned identity for the virtual list. A typed
// key avoids sending a reveal command to a different editor when panes are
// added later. Pane is reserved for that future use; zero is the current pane.
type editorListKey struct {
	Document application.DocumentID
	Pane     uint8
}

func queueEditorReveal(shell *workbenchState, id application.DocumentID, doc *document.Document, start, end int, policy RevealPolicy, horizontal bool) {
	if shell == nil || doc == nil || doc.Editor == nil || id == "" {
		return
	}
	if start < 0 {
		start = 0
	}
	if end < start {
		end = start
	}
	if shell.RevealRequests == nil {
		shell.RevealRequests = make(map[application.DocumentID]EditorRevealRequest)
	}
	shell.RevealRequests[id] = EditorRevealRequest{
		Document: doc, StartByte: start, EndByte: end, Policy: policy, Horizontal: horizontal,
		Generation: doc.Revision(),
	}
}

func navigateToCursor(shell *workbenchState, id application.DocumentID, doc *document.Document, offset int, policy RevealPolicy) {
	if doc == nil || doc.Editor == nil {
		return
	}
	doc.Editor.SetCursor(offset)
	queueEditorReveal(shell, id, doc, offset, offset, policy, true)
}

func navigateToSelection(shell *workbenchState, id application.DocumentID, doc *document.Document, start, end int, policy RevealPolicy) {
	if doc == nil || doc.Editor == nil {
		return
	}
	doc.Editor.SetSelection(start, end)
	queueEditorReveal(shell, id, doc, start, end, policy, true)
}

// revealEditorRequest posts the list command while the list is being built.
// The list, rather than this package, walks variable row heights. Centering is
// conditional on the list's last painted visible interval, so repeated Find
// navigation does not move an already visible match.
func revealEditorRequest(listKey any, e *editor.ScratchEditor, rows editor.RowMap, request EditorRevealRequest, firstVisible, lastVisible int) {
	if listKey == nil || e == nil {
		return
	}
	logical, ok := e.Buffer.LineAt(request.StartByte)
	if !ok {
		return
	}
	visible, visibleOK := rows.Visible(logical)
	if !visibleOK {
		return
	}
	switch request.Policy {
	case RevealCenterIfOutside:
		if firstVisible >= 0 && lastVisible >= firstVisible && visible >= firstVisible && visible <= lastVisible {
			return
		}
		VirtualListView_ScrollToIndexAt(listKey, visible, 0.5)
	case RevealNearTop:
		VirtualListView_ScrollToIndexAt(listKey, visible, 0.15)
	default:
		// Item keys are logical lines, while ScrollToIndexAt takes compact
		// visible indexes. Minimal reveal uses the key-based API so it can
		// preserve the list's nearest-edge behavior.
		VirtualListScrollIntoView(listKey, logical)
	}
}

// expandFoldsForReveal opens only collapsed Markdown folds containing the
// target line. Nested folds are handled in one pass over the current map and
// the caller rebuilds the map after this returns.
func expandFoldsForReveal(doc *document.Document, view *application.ViewState, startByte int) bool {
	if doc == nil || view == nil || !doc.DerivedCurrent() || len(view.CollapsedHeadings) == 0 {
		return false
	}
	line, ok := doc.Editor.Buffer.LineAt(startByte)
	if !ok {
		return false
	}
	lineStart, _, ok := doc.Editor.Buffer.LineRange(line)
	if !ok {
		return false
	}
	changed := false
	for _, fold := range doc.Projections.Folds {
		if !view.CollapsedHeadings[fold.HeadingStart] || lineStart < fold.StartByte || lineStart >= fold.EndByte {
			continue
		}
		delete(view.CollapsedHeadings, fold.HeadingStart)
		changed = true
	}
	return changed
}
