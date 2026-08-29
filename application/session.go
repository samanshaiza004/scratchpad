package application

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"

	"scratchpad/document"
	"scratchpad/editor"
	"scratchpad/language"
	"scratchpad/workspace"
)

type Session struct {
	Workspace string            `json:"workspace"`
	Documents []SessionDocument `json:"documents"`
	Active    DocumentID        `json:"active"`
}

type SessionDocument struct {
	ID       DocumentID      `json:"id"`
	Path     string          `json:"path"`
	Cursor   int             `json:"cursor"`
	Anchor   int             `json:"anchor"`
	Affinity editor.Affinity `json:"affinity"`
	View     ViewState       `json:"view"`
}

type recoveryManifest struct {
	Documents []recoveryDocument `json:"documents"`
}

type recoveryDocument struct {
	ID          DocumentID            `json:"id"`
	Path        string                `json:"path"`
	BytesFile   string                `json:"bytes_file"`
	BaseVersion workspace.DiskVersion `json:"base_version"`
	Revision    uint64                `json:"revision"`
	Mode        fs.FileMode           `json:"mode"`
	Format      document.FileFormat   `json:"format"`
	Cursor      int                   `json:"cursor"`
	Anchor      int                   `json:"anchor"`
	Affinity    editor.Affinity       `json:"affinity"`
	View        ViewState             `json:"view"`
}

func DefaultStateDir() (string, error) {
	root, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(root, "scratchpad"), nil
}

func (a *Application) Session() Session {
	session := Session{Active: a.Active}
	if a.HasWorkspace {
		session.Workspace = a.Workspace.Root
	}
	for _, id := range a.Order {
		doc := a.Documents[id]
		anchor, cursor := doc.Editor.Selection()
		session.Documents = append(session.Documents, SessionDocument{
			ID: id, Path: doc.Path, Cursor: cursor, Anchor: anchor,
			Affinity: doc.Editor.Affinity, View: a.Views[id],
		})
	}
	return session
}

func (a *Application) SaveSession(path string) error {
	data, err := json.MarshalIndent(a.Session(), "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	return workspace.AtomicWriteFile(path, append(data, '\n'), 0o600)
}

func LoadSession(path string) (Session, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Session{}, err
	}
	var session Session
	if err := json.Unmarshal(data, &session); err != nil {
		return Session{}, err
	}
	return session, nil
}

func (a *Application) RestoreSession(path string) error {
	session, err := LoadSession(path)
	if err != nil {
		return err
	}
	if session.Workspace != "" {
		if err := a.OpenWorkspace(session.Workspace); err != nil {
			return err
		}
	}
	for _, saved := range session.Documents {
		if err := a.OpenDocument(saved.Path); err != nil {
			if errors.Is(err, os.ErrNotExist) {
				continue
			}
			return err
		}
		doc := a.Documents[a.Active]
		doc.Editor.SetSelection(saved.Anchor, saved.Cursor)
		doc.Editor.SetAffinity(saved.Affinity)
		a.Views[a.Active] = saved.View
	}
	if session.Active != "" {
		a.Activate(session.Active)
	}
	return nil
}

func (a *Application) WriteRecovery(dir string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	manifest := recoveryManifest{}
	for _, id := range a.Order {
		doc := a.Documents[id]
		if !doc.Dirty() {
			continue
		}
		name := recoveryName(id)
		data := doc.Editor.Buffer.Text()
		if err := workspace.AtomicWriteFile(filepath.Join(dir, name+".bytes"), data, 0o600); err != nil {
			return err
		}
		anchor, cursor := doc.Editor.Selection()
		manifest.Documents = append(manifest.Documents, recoveryDocument{
			ID: id, Path: doc.Path, BytesFile: name + ".bytes", BaseVersion: doc.DiskVersion,
			Revision: doc.Revision(), Mode: doc.FileMode, Format: doc.Format,
			Cursor: cursor, Anchor: anchor, Affinity: doc.Editor.Affinity, View: a.Views[id],
		})
	}
	data, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return err
	}
	return workspace.AtomicWriteFile(filepath.Join(dir, "manifest.json"), append(data, '\n'), 0o600)
}

func (a *Application) RestoreRecovery(dir string) error {
	data, err := os.ReadFile(filepath.Join(dir, "manifest.json"))
	if err != nil {
		return err
	}
	var manifest recoveryManifest
	if err := json.Unmarshal(data, &manifest); err != nil {
		return err
	}
	for _, saved := range manifest.Documents {
		recovered, err := os.ReadFile(filepath.Join(dir, saved.BytesFile))
		if err != nil {
			return err
		}
		if err := a.restoreRecoveredDocument(saved, recovered); err != nil {
			return err
		}
	}
	return nil
}

func (a *Application) restoreRecoveredDocument(saved recoveryDocument, recovered []byte) error {
	if _, exists := a.Documents[saved.ID]; !exists {
		if _, err := os.Stat(saved.Path); err == nil {
			if err := a.OpenDocument(saved.Path); err != nil {
				return err
			}
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		} else {
			doc := document.New(saved.Path, recovered, string(language.DetectPath(saved.Path)))
			doc.FileMode, doc.Format, doc.DiskVersion = saved.Mode, saved.Format, saved.BaseVersion
			doc.MarkSaved()
			if err := doc.Insert(nil); err != nil {
				return err
			}
			doc.SavedRevision = ^uint64(0)
			a.Documents[saved.ID] = doc
			a.Order = append(a.Order, saved.ID)
			a.Views[saved.ID] = saved.View
		}
	}
	doc := a.Documents[saved.ID]
	if string(doc.Editor.Buffer.Text()) != string(recovered) {
		if err := doc.ReplaceText(recovered); err != nil {
			return err
		}
	}
	doc.Editor.SetSelection(saved.Anchor, saved.Cursor)
	doc.Editor.SetAffinity(saved.Affinity)
	a.Views[saved.ID] = saved.View
	a.Active = saved.ID
	return nil
}

func (a *Application) ClearRecovery(dir string) error {
	entries, err := os.ReadDir(dir)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if err := os.Remove(filepath.Join(dir, entry.Name())); err != nil {
			return err
		}
	}
	return nil
}

func recoveryName(id DocumentID) string {
	digest := sha256.Sum256([]byte(id))
	return hex.EncodeToString(digest[:])
}
