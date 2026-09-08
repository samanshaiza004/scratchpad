package application

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"time"

	"scratchpad/document"
	"scratchpad/editor"
	"scratchpad/language"
	"scratchpad/workspace"
)

type Session struct {
	Workspace string            `json:"workspace"`
	Documents []SessionDocument `json:"documents"`
	Active    DocumentID        `json:"active"`
	Recent    []string          `json:"recent,omitempty"`
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
	session := Session{Active: a.Active, Recent: a.RecentPaths()}
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
	a.recent = append([]string(nil), session.Recent...)
	return nil
}

type recoveryPayload struct {
	Manifest recoveryManifest
	Files    map[string][]byte
}

func (a *Application) captureRecovery() recoveryPayload {
	payload := recoveryPayload{Files: make(map[string][]byte)}
	for _, id := range a.Order {
		doc := a.Documents[id]
		if !doc.Dirty() {
			continue
		}
		name := recoveryName(id) + ".bytes"
		payload.Files[name] = doc.Editor.Buffer.Text()
		anchor, cursor := doc.Editor.Selection()
		payload.Manifest.Documents = append(payload.Manifest.Documents, recoveryDocument{
			ID: id, Path: doc.Path, BytesFile: name, BaseVersion: doc.DiskVersion,
			Revision: doc.Revision(), Mode: doc.FileMode, Format: doc.Format,
			Cursor: cursor, Anchor: anchor, Affinity: doc.Editor.Affinity, View: a.Views[id],
		})
	}
	return payload
}

func writeRecovery(dir string, payload recoveryPayload) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	if len(payload.Manifest.Documents) == 0 {
		return clearRecovery(dir)
	}
	for name, data := range payload.Files {
		if err := workspace.AtomicWriteFile(filepath.Join(dir, name), data, 0o600); err != nil {
			return err
		}
	}
	data, err := json.MarshalIndent(payload.Manifest, "", "  ")
	if err != nil {
		return err
	}
	return workspace.AtomicWriteFile(filepath.Join(dir, "manifest.json"), append(data, '\n'), 0o600)
}

func (a *Application) WriteRecovery(dir string) error {
	return writeRecovery(dir, a.captureRecovery())
}

// MaybeWriteRecovery captures dirty bytes on the UI goroutine and performs
// filesystem work asynchronously, keeping large recovery writes out of the
// keystroke-to-frame path. A clean payload also goes through the throttled
// async path so writeRecovery can clear stale files; saves additionally call
// refreshRecoveryAfterSave for an immediate synchronous rewrite (see below).
func (a *Application) MaybeWriteRecovery(dir string) {
	if dir == "" {
		return
	}
	select {
	case <-a.recoveryDone:
		a.recoveryRunning = false
	default:
	}
	if a.recoveryRunning || time.Since(a.lastRecovery) < time.Second {
		return
	}
	payload := a.captureRecovery()
	a.lastRecovery = time.Now()
	a.recoveryRunning = true
	go func() { a.recoveryDone <- writeRecovery(dir, payload) }()
}

// refreshRecoveryAfterSave rewrites recovery synchronously after a successful
// save so a crash cannot resurrect stale bytes. Saves are rare user gestures
// (not the keystroke path), so blocking disk IO here is acceptable; it drains
// any in-flight MaybeWriteRecovery snapshot first to avoid concurrent writers,
// then captures the current (post-save) state. Best-effort: recovery errors
// never fail the save. Callers must invoke it only after the save succeeded.
func (a *Application) refreshRecoveryAfterSave() {
	dir := a.RecoveryDir
	if dir == "" {
		return
	}
	_ = a.FlushRecovery(dir)
	a.lastRecovery = time.Now()
}

func (a *Application) FlushRecovery(dir string) error {
	var previousErr error
	if a.recoveryRunning {
		previousErr = <-a.recoveryDone
		a.recoveryRunning = false
	}
	// The asynchronous snapshot was captured before the caller's most recent
	// edits. Once it has drained, capture the current state synchronously so a
	// shutdown flush cannot leave recovery data behind an in-flight snapshot.
	return errors.Join(previousErr, a.WriteRecovery(dir))
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
	// Read every blob before mutating the document registry. A cleanup or copy
	// interrupted after the manifest is written can leave one referenced blob
	// unavailable; in that case startup can fall back to the regular session
	// without retaining a partially restored recovery state.
	recovered := make([][]byte, len(manifest.Documents))
	for i, saved := range manifest.Documents {
		bytes, err := os.ReadFile(filepath.Join(dir, saved.BytesFile))
		if err != nil {
			return err
		}
		recovered[i] = bytes
	}
	for i, saved := range manifest.Documents {
		if err := a.restoreRecoveredDocument(saved, recovered[i]); err != nil {
			return err
		}
	}
	return nil
}

func (a *Application) restoreRecoveredDocument(saved recoveryDocument, recovered []byte) error {
	id := saved.ID
	identityMismatch := false
	pathExists := false
	if _, err := os.Stat(saved.Path); err == nil {
		pathExists = true
		// Document IDs resolve symlinks. The link may have been retargeted
		// since the recovery snapshot, so opening the path can register a
		// different ID than the one in the manifest. Keep using the current
		// document, but force a conflict below so recovered bytes cannot be
		// silently applied to the new target.
		id = documentID(saved.Path)
		identityMismatch = id != saved.ID
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if identityMismatch {
		if _, exists := a.Documents[id]; exists {
			return errors.New("cannot restore recovery: retargeted document is already open")
		}
	}
	if _, exists := a.Documents[id]; !exists {
		if pathExists {
			if err := a.OpenDocument(saved.Path); err != nil {
				return err
			}
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
	doc := a.Documents[id]
	if doc == nil {
		return errors.New("recovery document identity is unavailable")
	}
	if identityMismatch || !doc.DiskVersion.Equal(saved.BaseVersion) {
		// Recovery stores the base fingerprint, but not a second copy of the
		// base bytes. Keep the recovered bytes as the local side and retain the
		// currently loaded disk bytes as the external side. The conflict gate
		// ensures ordinary Save cannot overwrite those external changes until
		// the user explicitly resolves the situation.
		a.Conflicts[id] = Conflict{
			Disk:        append([]byte(nil), doc.Editor.Buffer.Text()...),
			DiskVersion: doc.DiskVersion,
			DiskMode:    doc.FileMode,
		}
	}
	if string(doc.Editor.Buffer.Text()) != string(recovered) {
		if err := doc.ReplaceText(recovered); err != nil {
			return err
		}
	}
	doc.Editor.SetSelection(saved.Anchor, saved.Cursor)
	doc.Editor.SetAffinity(saved.Affinity)
	a.Views[id] = saved.View
	a.Active = id
	return nil
}

func (a *Application) ClearRecovery(dir string) error {
	return clearRecovery(dir)
}

func clearRecovery(dir string) error {
	entries, err := os.ReadDir(dir)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	// Remove the manifest first. If cleanup is interrupted, leaving orphaned
	// blobs is safe; leaving a manifest that references missing blobs is not.
	if err := os.Remove(filepath.Join(dir, "manifest.json")); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	for _, entry := range entries {
		if entry.Name() == "manifest.json" {
			continue
		}
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
