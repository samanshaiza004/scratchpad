package application

import (
	"errors"
	"fmt"
	"path/filepath"

	"scratchpad/commands"
	"scratchpad/editor"
	"scratchpad/language"
)

// PresentationCommandKind names the small set of application-owned lifecycle
// operations and bounded source edits needed by a presentation client. It
// intentionally does not include keystrokes, cursor movement, layout, or paint
// operations.
type PresentationCommandKind uint8

const (
	PresentationOpenPath PresentationCommandKind = iota + 1
	PresentationSelectDocument
	PresentationSaveDocument
	PresentationCloseDocument
	PresentationReplaceDocument
)

// PresentationCommand is the first Scratchpad application/presentation
// contract. Paths, identities, save policy, and close policy remain
// application-owned; a frontend supplies only semantic intent.
type PresentationCommand struct {
	Kind              PresentationCommandKind
	ActionID          string
	Path              string
	Preview           bool
	DocumentID        DocumentID
	Discard           bool
	EditorRevision    uint64
	StartByte         int
	EndByte           int
	Replacement       []byte
	HasSelectionState bool
	BeforeAnchorByte  int
	BeforeCursorByte  int
	AfterAnchorByte   int
	AfterCursorByte   int
	TypingGroupID     uint64
}

// PresentationDocument is the shell-visible portion of one open document.
// Document bytes and editor mechanics are deliberately absent: the scalable
// editor remains local to Scratchpad's existing application/editor path.
type PresentationDocument struct {
	ID                   DocumentID
	Path                 string
	Status               DocumentStatus
	Dirty                bool
	Preview              bool
	EditorRevision       uint64
	ByteLength           uint64
	LineCount            uint64
	CanUndo              bool
	CanRedo              bool
	Language             string
	PresentationRevision uint64
	PresentationReady    bool
}

// PresentationState is a bounded, UI-independent snapshot for a shell. The
// revision covers lifecycle/registry changes; EditorRevision identifies
// content changes without asking a frontend to serialize the buffer.
type PresentationState struct {
	Revision      uint64
	HasWorkspace  bool
	HasTrasher    bool
	WorkspaceRoot string
	Active        DocumentID
	Documents     []PresentationDocument
}

// PresentationClient is the only interface a future shell needs for this
// first slice. Application implements it directly today, which is the
// zero-glue direct-integration baseline. A Caliber-backed or foreign client
// can implement the same semantic contract later without changing the
// document/editor model.
type PresentationClient interface {
	Snapshot() PresentationState
	Dispatch(PresentationCommand) error
}

// ErrStaleEditorRevision means that a foreign presentation client attempted
// to edit a document from an editor revision that is no longer current. The
// client must discard or reconcile its optimistic edit and request fresh
// bounded content; the application never applies a stale range blindly.
var ErrStaleEditorRevision = errors.New("stale editor revision")

// Snapshot returns the application-owned state needed by a presentation
// shell. The returned slices are copies and contain no mutable document
// pointers or frontend objects.
func (a *Application) Snapshot() PresentationState {
	if a == nil {
		return PresentationState{}
	}
	state := PresentationState{
		Revision:      a.presentationRevision,
		HasWorkspace:  a.HasWorkspace,
		HasTrasher:    a.Trasher != nil,
		WorkspaceRoot: filepath.Clean(a.Workspace.Root),
		Active:        a.Active,
		Documents:     make([]PresentationDocument, 0, len(a.Order)),
	}
	if !a.HasWorkspace {
		state.WorkspaceRoot = ""
	}
	for _, id := range a.Order {
		doc := a.Documents[id]
		if doc == nil {
			continue
		}
		presentationReady := false
		if doc.RootLanguage == string(language.Markdown) {
			presentationReady = doc.DerivedCurrent() && doc.Projections.Markdown.Revision == doc.Revision()
		} else if !AnalysisSupported(language.ID(doc.RootLanguage)) {
			// Unsupported languages have no derived presentation to wait for;
			// their visible source is complete as plain text.
			presentationReady = true
		} else {
			presentationReady = doc.DerivedCurrent() &&
				doc.Projections.Code.Revision == doc.Revision() &&
				doc.Projections.Code.Language != ""
		}
		state.Documents = append(state.Documents, PresentationDocument{
			ID:                   id,
			Path:                 doc.Path,
			Status:               a.Status(id),
			Dirty:                doc.Dirty(),
			Preview:              a.Preview == id && !doc.Dirty(),
			EditorRevision:       doc.Revision(),
			ByteLength:           uint64(doc.Editor.Buffer.ByteLen()),
			LineCount:            uint64(doc.Editor.Buffer.LineCount()),
			CanUndo:              doc.Editor.CanUndo(),
			CanRedo:              doc.Editor.CanRedo(),
			Language:             doc.RootLanguage,
			PresentationRevision: doc.Revision(),
			PresentationReady:    presentationReady,
		})
	}
	return state
}

// Dispatch applies one semantic lifecycle command. It is intentionally a
// direct adapter over Application: this is the smallest useful dogfood slice,
// not a second command system or a serialized editor protocol.
func (a *Application) Dispatch(command PresentationCommand) error {
	if a == nil {
		return errors.New("nil application")
	}
	switch command.Kind {
	case PresentationOpenPath:
		if command.Preview {
			return a.OpenPreviewPath(command.Path)
		}
		return a.OpenPath(command.Path)
	case PresentationSelectDocument:
		if !a.Activate(command.DocumentID) {
			return errors.New("unknown document")
		}
		return nil
	case PresentationSaveDocument:
		id := command.DocumentID
		if id == "" {
			id = a.Active
		}
		return a.SaveDocument(id)
	case PresentationCloseDocument:
		id := command.DocumentID
		if id == "" {
			id = a.Active
		}
		return a.CloseDocument(id, command.Discard)
	case PresentationReplaceDocument:
		_, err := a.ReplaceDocument(command)
		return err
	default:
		return errors.New("unknown presentation command")
	}
}

// ReplaceDocument applies one revision-checked source transaction and returns
// the exact edit result needed by foreign clients. The result is produced by
// the editor operation itself, so branched undo/redo history cannot make its
// acknowledgement ambiguous.
func (a *Application) ReplaceDocument(command PresentationCommand) (editor.AppliedEdit, error) {
	if a == nil {
		return editor.AppliedEdit{}, errors.New("nil application")
	}
	if command.Kind != PresentationReplaceDocument {
		return editor.AppliedEdit{}, errors.New("not a document replacement command")
	}
	doc := a.Documents[command.DocumentID]
	if doc == nil {
		return editor.AppliedEdit{}, errors.New("unknown document")
	}
	if doc.Revision() != command.EditorRevision {
		return editor.AppliedEdit{}, fmt.Errorf("%w: expected %d, current %d", ErrStaleEditorRevision, command.EditorRevision, doc.Revision())
	}
	if command.ActionID == string(commands.MarkdownEnter) {
		if doc.RootLanguage != "markdown" || len(command.Replacement) != 1 || command.Replacement[0] != '\n' {
			return editor.AppliedEdit{}, errors.New("markdown Enter intent requires a Markdown document and a single LF sentinel")
		}
		cursorByte := command.StartByte
		selectionCollapsed := command.StartByte == command.EndByte
		if command.HasSelectionState {
			cursorByte = command.BeforeCursorByte
			selectionCollapsed = command.BeforeAnchorByte == command.BeforeCursorByte
		}
		line, ok := doc.Editor.Buffer.LineAt(cursorByte)
		if !ok {
			return editor.AppliedEdit{}, errors.New("markdown Enter position is outside the document")
		}
		lineStart, lineEnd, ok := doc.Editor.Buffer.LineRange(line)
		if !ok || cursorByte < lineStart || cursorByte > lineEnd {
			return editor.AppliedEdit{}, errors.New("markdown Enter position is outside its logical line")
		}
		prefixEnd := min(cursorByte, lineStart+4096)
		linePrefix, readErr := doc.Editor.Buffer.Bytes(lineStart, prefixEnd)
		if readErr != nil {
			return editor.AppliedEdit{}, readErr
		}
		atLineEnd := selectionCollapsed && cursorByte == lineEnd
		projection := commands.MarkdownEnterPrefix(linePrefix, atLineEnd)
		start := command.StartByte
		if projection.Breakout {
			start = lineStart + projection.RemoveFrom
		}
		replacement := make([]byte, 1, len(projection.Prefix)+1)
		replacement[0] = '\n'
		replacement = append(replacement, projection.Prefix...)
		command.StartByte = start
		command.Replacement = doc.Editor.NormalizeLineEndings(replacement)
		if command.HasSelectionState {
			cursor := start + len(command.Replacement)
			command.AfterAnchorByte, command.AfterCursorByte = cursor, cursor
		}
	}
	before := doc.Revision()
	var applied editor.AppliedEdit
	var err error
	if command.HasSelectionState && command.TypingGroupID != 0 {
		applied, err = doc.ReplaceTypingWithSelectionStateResult(
			command.StartByte, command.EndByte, command.Replacement,
			command.BeforeAnchorByte, command.BeforeCursorByte,
			command.AfterAnchorByte, command.AfterCursorByte, command.TypingGroupID,
		)
	} else if command.HasSelectionState {
		applied, err = doc.ReplaceWithSelectionStateResult(
			command.StartByte, command.EndByte, command.Replacement,
			command.BeforeAnchorByte, command.BeforeCursorByte,
			command.AfterAnchorByte, command.AfterCursorByte,
		)
	} else {
		applied, err = doc.ReplaceResult(command.StartByte, command.EndByte, command.Replacement)
	}
	if err != nil {
		return editor.AppliedEdit{}, err
	}
	if doc.Revision() != before {
		a.PinPreview(command.DocumentID)
		a.touchPresentation()
	}
	return applied, nil
}

// UndoDocument applies one authoritative edit-history step. An empty ID
// targets the active document. The application advances its presentation
// revision only when the editor's source state changes.
func (a *Application) UndoDocument(id DocumentID) error {
	return a.applyDocumentHistoryStep(id, false)
}

// RedoDocument reapplies one authoritative edit-history step. An empty ID
// targets the active document.
func (a *Application) RedoDocument(id DocumentID) error {
	return a.applyDocumentHistoryStep(id, true)
}

func (a *Application) applyDocumentHistoryStep(id DocumentID, redo bool) error {
	if a == nil {
		return errors.New("nil application")
	}
	if id == "" {
		id = a.Active
	}
	doc := a.Documents[id]
	if doc == nil {
		return errors.New("unknown document")
	}
	before := doc.Revision()
	var err error
	if redo {
		err = doc.Redo()
	} else {
		err = doc.Undo()
	}
	if err != nil {
		return err
	}
	if doc.Revision() != before {
		if doc.Dirty() {
			a.PinPreview(id)
		}
		a.touchPresentation()
	}
	return nil
}

var _ PresentationClient = (*Application)(nil)
