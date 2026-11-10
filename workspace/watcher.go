package workspace

import (
	"sync"

	"github.com/fsnotify/fsnotify"
)

type WatchEvent struct {
	Name string
	Op   uint32
	Err  error
}

type Watcher interface {
	WatchDirectory(path string) error
	Events() <-chan WatchEvent
	Close() error
}

// DirectoryUnwatcher is implemented by watchers that can release a watched
// directory before a filesystem mutation. Windows may reject moving a watched
// directory while the watcher holds its handle open.
type DirectoryUnwatcher interface {
	UnwatchDirectory(path string) error
}

type OSWatcher struct {
	watcher    *fsnotify.Watcher
	done       chan struct{}
	eventsOnce sync.Once
	events     <-chan WatchEvent
	closeOnce  sync.Once
	closeErr   error
}

func NewOSWatcher() (*OSWatcher, error) {
	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		return nil, err
	}
	return &OSWatcher{watcher: watcher, done: make(chan struct{})}, nil
}

func (w *OSWatcher) WatchDirectory(path string) error {
	return w.watcher.Add(path)
}

func (w *OSWatcher) UnwatchDirectory(path string) error {
	return w.watcher.Remove(path)
}

func (w *OSWatcher) Events() <-chan WatchEvent {
	w.eventsOnce.Do(func() {
		w.events = mergeFSNotifyStreams(w.watcher.Events, w.watcher.Errors, w.done)
	})
	return w.events
}

func mergeFSNotifyStreams(events <-chan fsnotify.Event, errs <-chan error, done <-chan struct{}) <-chan WatchEvent {
	out := make(chan WatchEvent)
	go func() {
		defer close(out)
		for events != nil || errs != nil {
			select {
			case <-done:
				return
			case event, ok := <-events:
				if !ok {
					events = nil
					continue
				}
				if !forwardWatchEvent(out, done, WatchEvent{Name: event.Name, Op: uint32(event.Op)}) {
					return
				}
			case err, ok := <-errs:
				if !ok {
					errs = nil
					continue
				}
				if err != nil && !forwardWatchEvent(out, done, WatchEvent{Err: err}) {
					return
				}
			}
		}
	}()
	return out
}

func forwardWatchEvent(out chan<- WatchEvent, done <-chan struct{}, event WatchEvent) bool {
	select {
	case out <- event:
		return true
	case <-done:
		return false
	}
}

func (w *OSWatcher) Close() error {
	w.closeOnce.Do(func() {
		close(w.done)
		w.closeErr = w.watcher.Close()
	})
	return w.closeErr
}
