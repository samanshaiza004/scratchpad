package workspace

import (
	"io/fs"
	"path/filepath"
	"strings"
	"sync"

	"github.com/git-pkgs/gitignore"
)

// Walker is the workspace's shared traversal seam. It keeps gitignore's
// matching and nested .gitignore discovery out of callers such as Quick Open,
// workspace search, and future recursive workspace views.
type Walker struct {
	root  string
	state *walkerState
}

type walkerState struct {
	mu      sync.Mutex
	matcher *gitignore.Matcher
	loaded  map[string]bool
}

func newWalkerState(root string) *walkerState {
	return &walkerState{matcher: gitignore.New(root), loaded: make(map[string]bool)}
}

// WalkFunc receives absolute paths for visible files and directories. The
// workspace root itself is not reported.
type WalkFunc func(path string, entry fs.DirEntry) error

// Walker returns a traversal policy rooted at the workspace.
func (w Workspace) Walker() Walker {
	state := w.state
	if state == nil {
		state = newWalkerState(w.Root)
	}
	return Walker{root: w.Root, state: state}
}

// Walk visits entries that are not excluded by Git's ignore rules. The
// dependency prunes ignored directories while descending and discovers nested
// .gitignore files at the directory where their scope begins. Scratchpad's
// private metadata directory is filtered at this seam as well.
func (w Walker) Walk(fn WalkFunc) error {
	if fn == nil {
		return nil
	}
	return gitignore.Walk(w.root, func(relative string, entry fs.DirEntry) error {
		if isPrivateWorkspacePath(relative) {
			return nil
		}
		return fn(filepath.Join(w.root, relative), entry)
	})
}

// matcherForLocked constructs the same root and nested-ignore policy used by
// Walk for a one-level directory listing. Loading only the ancestors of the
// requested directory keeps List cheap while still applying nested rules.
func (w Walker) matcherForLocked(relative string) *gitignore.Matcher {
	if w.state.matcher == nil {
		w.state.matcher = gitignore.New(w.root)
	}
	clean := filepath.Clean(relative)
	if clean == "." || clean == "" {
		return w.state.matcher
	}
	parts := strings.Split(filepath.ToSlash(clean), "/")
	for index := range parts {
		scope := strings.Join(parts[:index+1], "/")
		if w.state.loaded[scope] {
			continue
		}
		w.state.matcher.AddFromFile(filepath.Join(w.root, filepath.FromSlash(scope), ".gitignore"), scope)
		w.state.loaded[scope] = true
	}
	return w.state.matcher
}

func (w Walker) matchPath(relative string, isDir bool) bool {
	w.state.mu.Lock()
	defer w.state.mu.Unlock()
	return w.matcherForLocked(relative).MatchPath(filepath.ToSlash(relative), isDir)
}

func isPrivateWorkspacePath(relative string) bool {
	for _, part := range strings.Split(filepath.ToSlash(filepath.Clean(relative)), "/") {
		if part == ".scratchpad" {
			return true
		}
	}
	return false
}
