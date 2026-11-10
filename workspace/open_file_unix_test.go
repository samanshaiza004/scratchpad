//go:build unix

package workspace

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

func TestSymlinkToFIFOIsRejectedWithoutBlocking(t *testing.T) {
	dir := t.TempDir()
	fifo := filepath.Join(dir, "target.fifo")
	link := filepath.Join(dir, "note.txt")
	if err := unix.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(fifo, link); err != nil {
		t.Skipf("symlink unavailable: %v", err)
	}

	done := make(chan error, 1)
	go func() {
		_, err := NewOSFileStore().Load(link)
		done <- err
	}()
	select {
	case err := <-done:
		if err == nil || !errors.Is(err, os.ErrNotExist) && err.Error() != "path is not a regular file" {
			t.Fatalf("Load symlink to FIFO error = %v, want non-regular file rejection", err)
		}
	case <-time.After(time.Second):
		t.Fatal("Load blocked opening a symlink to a FIFO")
	}
}

func TestWorkspaceSearchSkipsFIFOsAndContinues(t *testing.T) {
	dir := t.TempDir()
	if runtime.GOOS == "windows" {
		t.Skip("named-pipe filesystem entries are not created by this Unix fixture")
	}
	if err := unix.Mkfifo(filepath.Join(dir, "a.fifo"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "b.txt"), []byte("needle"), 0o600); err != nil {
		t.Fatal(err)
	}
	ws, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		var matches int
		err := ws.Search(context.Background(), []byte("needle"), func(SearchResult) bool {
			matches++
			return true
		})
		if err == nil && matches != 1 {
			err = errors.New("search did not continue to the regular file after the FIFO")
		}
		done <- err
	}()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("workspace search blocked on a FIFO")
	}
}

func TestVerifyStreamsLargeFilesWithBoundedAllocations(t *testing.T) {
	path := filepath.Join(t.TempDir(), "large.bin")
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	const size = 64 << 20
	if err := file.Truncate(size); err != nil {
		_ = file.Close()
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	runtime.GC()
	var before, after runtime.MemStats
	runtime.ReadMemStats(&before)
	version, err := NewOSFileStore().Verify(path)
	runtime.ReadMemStats(&after)
	if err != nil {
		t.Fatal(err)
	}
	if !version.Verified || version.Size != size {
		t.Fatalf("verified file version = %+v", version)
	}
	if allocated := after.TotalAlloc - before.TotalAlloc; allocated > 2<<20 {
		t.Fatalf("Verify allocated %d bytes for a %d-byte file; want bounded streaming allocation", allocated, size)
	}
}
