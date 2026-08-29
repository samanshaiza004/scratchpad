// Package application owns the product's open-document registry and active
// application state. It deliberately contains no Shirei dependency.
package application

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"scratchpad/document"
	"scratchpad/language"
	"scratchpad/workspace"
)

type DocumentID string

type ViewState struct {
	ScrollY float32
}

type Application struct {
	Store        workspace.FileStore
	Workspace    workspace.Workspace
	HasWorkspace bool
	Documents    map[DocumentID]*document.Document
	Order        []DocumentID
	Active       DocumentID
	Views        map[DocumentID]ViewState
}

func New(store workspace.FileStore) *Application {
	if store == nil {
		store = workspace.NewOSFileStore()
	}
	return &Application{
		Store:     store,
		Documents: make(map[DocumentID]*document.Document),
		Views:     make(map[DocumentID]ViewState),
	}
}

// OpenPath is the shared entry seam for CLI paths, file pickers, and future
// drag-and-drop or recent-file actions.
func (a *Application) OpenPath(path string) error {
	if a == nil {
		return errors.New("nil application")
	}
	if path == "" {
		return errors.New("empty path")
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return err
	}
	abs = filepath.Clean(abs)
	info, err := os.Stat(abs)
	if err != nil {
		return err
	}
	if info.IsDir() {
		return a.OpenWorkspace(abs)
	}
	return a.OpenDocument(abs)
}

func (a *Application) OpenWorkspace(path string) error {
	ws, err := workspace.Open(path)
	if err != nil {
		return err
	}
	a.Workspace = ws
	a.HasWorkspace = true
	return nil
}

func (a *Application) OpenDocument(path string) error {
	if a == nil {
		return errors.New("nil application")
	}
	snapshot, err := a.Store.Load(path)
	if err != nil {
		return err
	}
	id := documentID(path)
	if existing, ok := a.Documents[id]; ok {
		a.Active = id
		_ = existing
		return nil
	}
	if !a.HasWorkspace {
		if err := a.OpenWorkspace(filepath.Dir(snapshot.Path)); err != nil {
			return err
		}
	}
	rootLanguage := string(language.DetectPath(snapshot.Path))
	doc := document.NewLoaded(snapshot.Path, snapshot.Data, snapshot.Version, snapshot.Mode, rootLanguage)
	a.Documents[id] = doc
	a.Order = append(a.Order, id)
	a.Views[id] = ViewState{}
	a.Active = id
	return nil
}

func (a *Application) Activate(id DocumentID) bool {
	if _, ok := a.Documents[id]; !ok {
		return false
	}
	a.Active = id
	return true
}

func (a *Application) ActiveDocument() *document.Document {
	if a == nil {
		return nil
	}
	return a.Documents[a.Active]
}

func (a *Application) Reorder(order []DocumentID) error {
	if len(order) != len(a.Order) {
		return errors.New("document order does not contain every open document")
	}
	seen := make(map[DocumentID]bool, len(order))
	for _, id := range order {
		if seen[id] {
			return fmt.Errorf("duplicate document id %q", id)
		}
		if _, ok := a.Documents[id]; !ok {
			return fmt.Errorf("unknown document id %q", id)
		}
		seen[id] = true
	}
	a.Order = append(a.Order[:0], order...)
	return nil
}

func documentID(path string) DocumentID {
	abs, err := filepath.Abs(path)
	if err != nil {
		return DocumentID(filepath.Clean(path))
	}
	abs = filepath.Clean(abs)
	if resolved, err := filepath.EvalSymlinks(abs); err == nil {
		abs = filepath.Clean(resolved)
	}
	return DocumentID(abs)
}
