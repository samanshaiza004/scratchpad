package application

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"scratchpad/workspace"
)

func TestGateCFileNativeCertification(t *testing.T) {
	dir := t.TempDir()
	lf := filepath.Join(dir, "lf.txt")
	crlf := filepath.Join(dir, "crlf.txt")
	invalid := filepath.Join(dir, "invalid.txt")
	if err := os.WriteFile(lf, []byte("one\ntwo\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	crlfBytes := []byte("one\r\ntwo\r\n")
	if err := os.WriteFile(crlf, crlfBytes, 0o644); err != nil {
		t.Fatal(err)
	}
	invalidBytes := []byte{'a', 0xff, 'b'}
	if err := os.WriteFile(invalid, invalidBytes, 0o644); err != nil {
		t.Fatal(err)
	}
	store := workspace.NewOSFileStore()
	a := New(store)
	if err := a.OpenPath(lf); err != nil {
		t.Fatal(err)
	}
	if err := a.SaveActive(); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(lf); !bytes.Equal(got, []byte("one\ntwo\n")) {
		t.Fatalf("LF no-op save changed bytes: %x", got)
	}
	if err := a.OpenPath(crlf); err != nil {
		t.Fatal(err)
	}
	crlfDoc := a.ActiveDocument()
	crlfDoc.Editor.SetCursor(len("one\r\n"))
	if err := crlfDoc.Insert([]byte("X")); err != nil {
		t.Fatal(err)
	}
	if err := a.SaveActive(); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(crlf); !bytes.Equal(got, []byte("one\r\nXtwo\r\n")) {
		t.Fatalf("CRLF edit changed bytes: %x", got)
	}
	if err := a.OpenPath(invalid); err != nil {
		t.Fatal(err)
	}
	invalidDoc := a.ActiveDocument()
	invalidDoc.Editor.SetCursor(1)
	if err := invalidDoc.Insert([]byte("Z")); err != nil {
		t.Fatal(err)
	}
	if err := a.SaveActive(); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(invalid)
	if !bytes.Equal(got, []byte{'a', 'Z', 0xff, 'b'}) {
		t.Fatalf("invalid byte was not preserved: %x", got)
	}

	id := a.Active
	a.Documents[id].Editor.SetSelection(0, 1)
	if err := a.Reorder([]DocumentID{a.Order[2], a.Order[0], a.Order[1]}); err != nil {
		t.Fatal(err)
	}
	a.Activate(id)
	anchor, cursor := a.ActiveDocument().Editor.Selection()
	if anchor != 0 || cursor != 1 {
		t.Fatalf("tab switch lost editor state: %d:%d", anchor, cursor)
	}
}

func TestGateCConflictRecoveryAndSymlinkCertification(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "note.txt")
	if err := os.WriteFile(path, []byte("disk"), 0o644); err != nil {
		t.Fatal(err)
	}
	a := New(nil)
	if err := a.OpenPath(path); err != nil {
		t.Fatal(err)
	}
	id := a.Active
	if err := a.Documents[id].Insert([]byte("local")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("external"), 0o644); err != nil {
		t.Fatal(err)
	}
	status, err := a.Reconcile(id)
	if err != nil || status != StatusConflict {
		t.Fatalf("conflict status=%v err=%v", status, err)
	}
	if err := a.SaveActive(); !errors.Is(err, ErrConflict) {
		t.Fatalf("SaveActive error=%v, want conflict", err)
	}
	if err := a.OverwriteDisk(id); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(path); string(got) != "localdisk" {
		t.Fatalf("overwrite result=%q", got)
	}

	recoveryDir := filepath.Join(t.TempDir(), "recovery")
	a.Documents[id].Editor.SetCursor(a.Documents[id].Editor.Buffer.ByteLen())
	if err := a.Documents[id].Insert([]byte(" recovered")); err != nil {
		t.Fatal(err)
	}
	if err := a.WriteRecovery(recoveryDir); err != nil {
		t.Fatal(err)
	}
	restored := New(nil)
	if err := restored.RestoreRecovery(recoveryDir); err != nil {
		t.Fatal(err)
	}
	if !restored.ActiveDocument().Dirty() || string(restored.ActiveDocument().Editor.Buffer.Text()) != "localdisk recovered" {
		t.Fatalf("recovery dirty=%v text=%q", restored.ActiveDocument().Dirty(), restored.ActiveDocument().Editor.Buffer.Text())
	}

	target := filepath.Join(dir, "target.txt")
	link := filepath.Join(dir, "link.txt")
	if err := os.WriteFile(target, []byte("target"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, link); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
	symlinkApp := New(nil)
	if err := symlinkApp.OpenPath(link); err != nil {
		t.Fatal(err)
	}
	symlinkDoc := symlinkApp.ActiveDocument()
	symlinkDoc.Editor.SetCursor(symlinkDoc.Editor.Buffer.ByteLen())
	if err := symlinkDoc.Insert([]byte("!")); err != nil {
		t.Fatal(err)
	}
	if err := symlinkApp.SaveActive(); err != nil {
		t.Fatal(err)
	}
	info, err := os.Lstat(link)
	if err != nil || info.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("symlink replaced: %v", err)
	}
	if got, _ := os.ReadFile(target); string(got) != "target!" {
		t.Fatalf("symlink target=%q", got)
	}
}

func TestGateCLargeDocumentSwitching(t *testing.T) {
	dir := t.TempDir()
	large := filepath.Join(dir, "large.txt")
	other := filepath.Join(dir, "other.txt")
	if err := os.WriteFile(large, []byte(strings.Repeat("0123456789\n", (10<<20)/11)), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(other, []byte("other"), 0o644); err != nil {
		t.Fatal(err)
	}
	a := New(nil)
	if err := a.OpenPath(large); err != nil {
		t.Fatal(err)
	}
	largeID := a.Active
	doc := a.ActiveDocument()
	doc.Editor.SetCursor(9 << 20)
	if err := doc.Insert([]byte("x")); err != nil {
		t.Fatal(err)
	}
	if err := a.OpenPath(other); err != nil {
		t.Fatal(err)
	}
	a.Activate(largeID)
	if a.ActiveDocument().Editor.Cursor != 9<<20+1 {
		t.Fatalf("large document cursor=%d", a.ActiveDocument().Editor.Cursor)
	}
}
