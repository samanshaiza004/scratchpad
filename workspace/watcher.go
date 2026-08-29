package workspace

import "github.com/fsnotify/fsnotify"

type WatchEvent struct {
	Name string
	Op   uint32
}

type Watcher interface {
	WatchDirectory(path string) error
	Events() <-chan WatchEvent
	Errors() <-chan error
	Close() error
}

type OSWatcher struct {
	watcher *fsnotify.Watcher
}

func NewOSWatcher() (*OSWatcher, error) {
	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		return nil, err
	}
	return &OSWatcher{watcher: watcher}, nil
}

func (w *OSWatcher) WatchDirectory(path string) error {
	return w.watcher.Add(path)
}

func (w *OSWatcher) Events() <-chan WatchEvent {
	out := make(chan WatchEvent)
	go func() {
		defer close(out)
		for event := range w.watcher.Events {
			out <- WatchEvent{Name: event.Name, Op: uint32(event.Op)}
		}
	}()
	return out
}

func (w *OSWatcher) Errors() <-chan error { return w.watcher.Errors }

func (w *OSWatcher) Close() error { return w.watcher.Close() }
