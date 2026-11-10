package workspace

import (
	"errors"
	"testing"

	"github.com/fsnotify/fsnotify"
)

func TestMergedWatcherStreamIncludesFilesystemErrors(t *testing.T) {
	events := make(chan fsnotify.Event, 1)
	errorsIn := make(chan error, 1)
	done := make(chan struct{})
	events <- fsnotify.Event{Name: "note.md", Op: fsnotify.Write}
	wantErr := errors.New("watch queue overflow")
	errorsIn <- wantErr
	close(events)
	close(errorsIn)

	stream := mergeFSNotifyStreams(events, errorsIn, done)
	gotEvent, gotError := false, false
	for event := range stream {
		if event.Err != nil {
			gotError = errors.Is(event.Err, wantErr)
			continue
		}
		gotEvent = event.Name == "note.md" && event.Op == uint32(fsnotify.Write)
	}
	if !gotEvent || !gotError {
		t.Fatalf("merged stream event=%t error=%t", gotEvent, gotError)
	}
}

func TestMergedWatcherStreamCanStopWhenConsumerLeaves(t *testing.T) {
	events := make(chan fsnotify.Event, 1)
	events <- fsnotify.Event{Name: "blocked"}
	errorsIn := make(chan error)
	done := make(chan struct{})
	stream := mergeFSNotifyStreams(events, errorsIn, done)
	close(done)
	for range stream {
	}
}

func TestOSWatcherEventsReturnsOneMergedStream(t *testing.T) {
	watcher := &OSWatcher{
		watcher: &fsnotify.Watcher{
			Events: make(chan fsnotify.Event),
			Errors: make(chan error),
		},
		done: make(chan struct{}),
	}
	first := watcher.Events()
	second := watcher.Events()
	if first != second {
		t.Fatal("Events returned competing merged streams")
	}
	close(watcher.done)
	for range first {
	}
}
