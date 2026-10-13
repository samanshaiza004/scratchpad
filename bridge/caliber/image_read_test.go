package backend

import (
	"encoding/json"
	"os"
	"path/filepath"
	"scratchpad/application"
	"scratchpad/workspace"
	"testing"
	"time"
)

type gatedImageStore struct {
	workspace.OSFileStore
	entered, release chan struct{}
}

func (store *gatedImageStore) LoadImage(path string) (workspace.ImageFileSnapshot, error) {
	close(store.entered)
	<-store.release
	return store.OSFileStore.LoadImage(path)
}

func TestImageReadDoesNotHoldLifecycleLockAndRejectsClosedTab(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "image.qoi")
	data := []byte{'q', 'o', 'i', 'f', 0, 0, 0, 1, 0, 0, 0, 1, 4, 0, 0xff, 128, 96, 180, 255, 0, 0, 0, 0, 0, 0, 0, 1}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
	runtime := newStartedRuntime(t, dir)
	defer stopRuntime(t, runtime)
	store := &gatedImageStore{entered: make(chan struct{}), release: make(chan struct{})}
	runtime.mu.Lock()
	runtime.app.Store = store
	if err := runtime.app.OpenDocument(path); err != nil {
		runtime.mu.Unlock()
		t.Fatal(err)
	}
	id := runtime.app.Active
	revision := runtime.app.FileViews[id].Revision
	runtime.mu.Unlock()
	finished := make(chan []byte, 1)
	go func() {
		finished <- runtime.ReadImage(mustJSON(t, CommandRequest{Version: ProtocolVersion, RequestID: 900, Command: "read_image", DocumentID: string(id), ImageRevision: revision}))
	}()
	select {
	case <-store.entered:
	case <-time.After(2 * time.Second):
		t.Fatal("image reader did not enter")
	}
	closed := make(chan struct{})
	go func() {
		runtime.mu.Lock()
		_ = runtime.app.CloseDocument(application.DocumentID(id), false)
		runtime.mu.Unlock()
		close(closed)
	}()
	select {
	case <-closed:
	case <-time.After(time.Second):
		close(store.release)
		<-finished
		t.Fatal("slow image I/O held the lifecycle lock")
	}
	close(store.release)
	select {
	case encoded := <-finished:
		var response Response
		if err := json.Unmarshal(encoded, &response); err != nil {
			t.Fatal(err)
		}
		if response.OK || response.Resource != nil {
			t.Fatal("closed image tab must not publish a stale resource")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("image request did not finish")
	}
}
