package application

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"scratchpad/language"
	"scratchpad/workspace"
)

var (
	ErrWorkspaceRequired = errors.New("workspace is not open")
	ErrDocumentMissing   = errors.New("affected document is missing on disk")
	ErrInvalidName       = errors.New("invalid workspace name")
)

// DocumentRelocation is the already-validated application-state part of a
// workspace move. The document pointer is deliberately absent: a move
// changes identity metadata, not the authoritative editor or its undo state.
type DocumentRelocation struct {
	OldID   DocumentID
	NewID   DocumentID
	OldPath string
	NewPath string
}

// PathMutationPlan contains all state that can be computed before the disk
// operation. Once Workspace.Move succeeds, applying this plan is a local,
// deterministic registry migration.
type PathMutationPlan struct {
	Source      string
	Destination string
	Documents   []DocumentRelocation
}

// CreateFile creates and opens a real file. Scratchpad does not create an
// untitled buffer as a side effect of this command.
func (a *Application) CreateFile(relative string) error {
	if a == nil || !a.HasWorkspace {
		return ErrWorkspaceRequired
	}
	relative, absolute, err := a.workspacePath(relative)
	if err != nil {
		return err
	}
	if err := a.Workspace.CreateFile(relative); err != nil {
		return err
	}
	if err := a.OpenDocument(absolute); err != nil {
		return fmt.Errorf("open created file: %w", err)
	}
	return nil
}

func (a *Application) CreateDirectory(relative string) error {
	if a == nil || !a.HasWorkspace {
		return ErrWorkspaceRequired
	}
	relative, _, err := a.workspacePath(relative)
	if err != nil {
		return err
	}
	return a.Workspace.CreateDirectory(relative)
}

// TrashPath sends a workspace entry to the configured OS trash after
// reconciling every open document below it. Clean affected documents close
// automatically. Dirty documents require an explicit discard=true decision;
// no bytes are discarded implicitly.
func (a *Application) TrashPath(path string, discard bool) error {
	if a == nil || !a.HasWorkspace {
		return ErrWorkspaceRequired
	}
	if a.Trasher == nil {
		return workspace.ErrTrashUnavailable
	}
	relative, absolute, err := a.workspacePath(path)
	if err != nil {
		return err
	}
	info, err := a.Workspace.Lstat(relative)
	if err != nil {
		return err
	}
	isDirectory := info.IsDir()
	if info.Mode()&os.ModeSymlink != 0 {
		if followed, followErr := a.Workspace.Stat(relative); followErr == nil {
			isDirectory = followed.IsDir()
		}
	}
	affected := make([]DocumentID, 0)
	for id, doc := range a.Documents {
		if doc == nil {
			continue
		}
		_, inside := relocationRelative(absolute, filepath.Clean(doc.Path), isDirectory)
		if !inside {
			continue
		}
		affected = append(affected, id)
		status, reconcileErr := a.Reconcile(id)
		if reconcileErr != nil {
			return reconcileErr
		}
		if status == StatusConflict {
			return ErrConflict
		}
		if status == StatusMissing {
			return ErrDocumentMissing
		}
		if doc.Dirty() && !discard {
			return ErrDirty
		}
	}
	if err := a.Trasher.Trash(absolute); err != nil {
		return err
	}
	// Close only after the OS adapter confirms that the entry reached trash.
	for _, id := range affected {
		_ = a.CloseDocument(id, true)
	}
	return nil
}

// RenamePath renames one workspace entry without changing its parent.
func (a *Application) RenamePath(path, name string) error {
	if name == "" || name == "." || name == ".." ||
		filepath.Base(name) != name || strings.ContainsAny(name, `/\\`) {
		return ErrInvalidName
	}
	relative, _, err := a.workspacePath(path)
	if err != nil {
		return err
	}
	destination := filepath.Join(filepath.Dir(relative), name)
	if filepath.Dir(relative) == "." {
		destination = name
	}
	return a.MovePath(relative, destination)
}

// MovePath moves source to the exact destination path. It never overwrites
// and it preserves every affected Document and ScratchEditor in memory.
func (a *Application) MovePath(source, destination string) error {
	plan, err := a.PlanMovePath(source, destination)
	if err != nil {
		return err
	}
	for _, relocation := range plan.Documents {
		status, err := a.Reconcile(relocation.OldID)
		if err != nil {
			return err
		}
		if status == StatusConflict {
			return ErrConflict
		}
		if status == StatusMissing {
			return ErrDocumentMissing
		}
	}
	if err := a.Workspace.Move(plan.Source, plan.Destination); err != nil {
		return err
	}
	a.applyPathMutation(plan)
	a.watchPathMutation(plan)
	return nil
}

// PlanMovePath performs all logical validation without changing disk or
// application state. Paths may be absolute for UI callers, but the plan
// stores workspace-relative paths for the filesystem adapter.
func (a *Application) PlanMovePath(source, destination string) (PathMutationPlan, error) {
	if a == nil || !a.HasWorkspace {
		return PathMutationPlan{}, ErrWorkspaceRequired
	}
	source, sourceAbs, err := a.workspacePath(source)
	if err != nil {
		return PathMutationPlan{}, err
	}
	destination, destinationAbs, err := a.workspacePath(destination)
	if err != nil {
		return PathMutationPlan{}, err
	}
	if source == destination || pathWithin(destinationAbs, sourceAbs) {
		return PathMutationPlan{}, fmt.Errorf("%q to %q: %w", source, destination, workspace.ErrMoveIntoSelf)
	}
	sourceInfo, err := a.Workspace.Lstat(source)
	if err != nil {
		return PathMutationPlan{}, err
	}
	if _, err := a.Workspace.Lstat(destination); err == nil {
		return PathMutationPlan{}, fmt.Errorf("%q: %w", destination, workspace.ErrDestinationExists)
	} else if !errors.Is(err, os.ErrNotExist) {
		return PathMutationPlan{}, err
	}
	parent := filepath.Dir(destination)
	if parent == "." {
		parent = ""
	}
	parentInfo, err := a.Workspace.Stat(parent)
	if err != nil {
		return PathMutationPlan{}, err
	}
	if !parentInfo.IsDir() {
		return PathMutationPlan{}, fmt.Errorf("destination parent is not a directory")
	}
	// A symlink entry can refer to a directory while remaining a single entry
	// for the move operation. Open documents below its logical path must move
	// with that entry, even though the target directory itself is untouched.
	isDirectory := sourceInfo.IsDir()
	if sourceInfo.Mode()&os.ModeSymlink != 0 {
		if followed, followErr := a.Workspace.Stat(source); followErr == nil {
			isDirectory = followed.IsDir()
		}
	}

	plan := PathMutationPlan{Source: source, Destination: destination}
	seen := make(map[DocumentID]bool)
	for id, doc := range a.Documents {
		if doc == nil {
			continue
		}
		oldPath := filepath.Clean(doc.Path)
		rel, inside := relocationRelative(sourceAbs, oldPath, isDirectory)
		if !inside {
			continue
		}
		newPath := destinationAbs
		if isDirectory {
			newPath = filepath.Join(destinationAbs, rel)
		}
		newID := documentID(newPath)
		if seen[newID] {
			return PathMutationPlan{}, fmt.Errorf("multiple documents map to %q", newPath)
		}
		seen[newID] = true
		if existing, ok := a.Documents[newID]; ok && existing != doc {
			return PathMutationPlan{}, ErrDocumentAlreadyOpen
		}
		plan.Documents = append(plan.Documents, DocumentRelocation{OldID: id, NewID: newID, OldPath: oldPath, NewPath: newPath})
	}
	return plan, nil
}

func (a *Application) workspacePath(path string) (relative, absolute string, err error) {
	if a == nil || !a.HasWorkspace {
		return "", "", ErrWorkspaceRequired
	}
	if filepath.IsAbs(path) {
		relative, err = a.Workspace.RelativePath(path)
	} else {
		absolute = filepath.Join(a.Workspace.Root, path)
		relative, err = a.Workspace.RelativePath(absolute)
	}
	if err != nil {
		return "", "", err
	}
	if relative == "." || relative == "" {
		return "", "", errors.New("workspace root is not a mutable entry")
	}
	return filepath.Clean(relative), filepath.Join(a.Workspace.Root, relative), nil
}

func relocationRelative(source, path string, directory bool) (string, bool) {
	if !directory {
		return "", filepath.Clean(source) == filepath.Clean(path)
	}
	rel, err := filepath.Rel(source, path)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", false
	}
	return rel, true
}

func pathWithin(path, ancestor string) bool {
	rel, err := filepath.Rel(ancestor, path)
	return err == nil && rel != "." && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

func (a *Application) applyPathMutation(plan PathMutationPlan) {
	for _, relocation := range plan.Documents {
		doc := a.Documents[relocation.OldID]
		if doc == nil {
			continue
		}
		oldLanguage := language.ID(doc.RootLanguage)
		newLanguage := language.DetectPath(relocation.NewPath)
		doc.Path = filepath.Clean(relocation.NewPath)
		doc.RootLanguage = string(newLanguage)

		if relocation.OldID != relocation.NewID {
			delete(a.Documents, relocation.OldID)
			a.Documents[relocation.NewID] = doc
			for i, id := range a.Order {
				if id == relocation.OldID {
					a.Order[i] = relocation.NewID
				}
			}
			if a.Active == relocation.OldID {
				a.Active = relocation.NewID
			}
			a.Views[relocation.NewID] = a.Views[relocation.OldID]
			delete(a.Views, relocation.OldID)
			if a.Stale[relocation.OldID] {
				a.Stale[relocation.NewID] = true
			}
			delete(a.Stale, relocation.OldID)
			if conflict, ok := a.Conflicts[relocation.OldID]; ok {
				a.Conflicts[relocation.NewID] = conflict
			}
			delete(a.Conflicts, relocation.OldID)
		}
		if oldLanguage != newLanguage {
			doc.InvalidateDerived()
		}
		a.closeDerivedAfterPathChange(relocation.OldID)
	}
	// Recent and closed paths can include documents that were not open when a
	// directory moved. Rewrite the whole remembered subtree once, after open
	// documents have been rekeyed.
	a.replaceRememberedPath(filepath.Join(a.Workspace.Root, plan.Source), filepath.Join(a.Workspace.Root, plan.Destination))
}

func (a *Application) watchPathMutation(plan PathMutationPlan) {
	if a == nil || a.Watcher == nil {
		return
	}
	seen := make(map[string]bool)
	watch := func(path string) {
		path = filepath.Clean(path)
		if seen[path] {
			return
		}
		seen[path] = true
		_ = a.Watcher.WatchDirectory(path)
	}
	watch(filepath.Dir(filepath.Join(a.Workspace.Root, plan.Destination)))
	for _, relocation := range plan.Documents {
		watch(filepath.Dir(relocation.NewPath))
	}
}

func (a *Application) closeDerivedAfterPathChange(id DocumentID) {
	state := a.derived[id]
	if state == nil {
		return
	}
	state.closed = true
	if !state.running {
		if state.runtime != nil {
			state.runtime.Close()
		}
		delete(a.derived, id)
	}
}

func (a *Application) replaceRememberedPath(oldPath, newPath string) {
	rewrite := func(paths []string) []string {
		for i, path := range paths {
			cleanPath := filepath.Clean(path)
			cleanOld := filepath.Clean(oldPath)
			if cleanPath == cleanOld {
				paths[i] = newPath
				continue
			}
			rel, err := filepath.Rel(cleanOld, cleanPath)
			if err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
				paths[i] = filepath.Join(newPath, rel)
			}
		}
		return paths
	}
	a.recent = rewrite(a.recent)
	a.closed = rewrite(a.closed)
}
