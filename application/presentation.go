package application

import (
	"errors"
	"fmt"
	"path/filepath"
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
	Kind           PresentationCommandKind
	Path           string
	DocumentID     DocumentID
	Discard        bool
	EditorRevision uint64
	StartByte      int
	EndByte        int
	Replacement    []byte
}

// PresentationDocument is the shell-visible portion of one open document.
// Document bytes and editor mechanics are deliberately absent: the scalable
// editor remains local to Scratchpad's existing application/editor path.
type PresentationDocument struct {
	ID             DocumentID
	Path           string
	Status         DocumentStatus
	Dirty          bool
	EditorRevision uint64
	Language       string
}

// PresentationState is a bounded, UI-independent snapshot for a shell. The
// revision covers lifecycle/registry changes; EditorRevision identifies
// content changes without asking a frontend to serialize the buffer.
type PresentationState struct {
	Revision      uint64
	HasWorkspace  bool
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
		state.Documents = append(state.Documents, PresentationDocument{
			ID:             id,
			Path:           doc.Path,
			Status:         a.Status(id),
			Dirty:          doc.Dirty(),
			EditorRevision: doc.Revision(),
			Language:       doc.RootLanguage,
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
		doc := a.Documents[command.DocumentID]
		if doc == nil {
			return errors.New("unknown document")
		}
		if doc.Revision() != command.EditorRevision {
			return fmt.Errorf("%w: expected %d, current %d", ErrStaleEditorRevision, command.EditorRevision, doc.Revision())
		}
		before := doc.Revision()
		if err := doc.Replace(command.StartByte, command.EndByte, command.Replacement); err != nil {
			return err
		}
		if doc.Revision() != before {
			a.touchPresentation()
		}
		return nil
	default:
		return errors.New("unknown presentation command")
	}
}

var _ PresentationClient = (*Application)(nil)
