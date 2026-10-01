package backend

import (
	"context"
	"errors"
	"path/filepath"

	"scratchpad/workspace"
)

type workspaceSearchSession struct {
	generation uint64
	sequence   uint64
	count      uint64
	done       bool
	truncated  bool
	page       *WorkspaceSearchPage
	cancel     context.CancelFunc
	consumed   chan struct{}
}

func (r *Runtime) startWorkspaceSearch(generation uint64, query string) error {
	if r.app == nil || !r.app.HasWorkspace {
		return errors.New("no workspace is open")
	}
	if r.workspaceSearch != nil && generation <= r.workspaceSearch.generation {
		return errors.New("search generation must be newer than the active generation")
	}
	if r.workspaceSearch != nil && r.workspaceSearch.cancel != nil {
		r.workspaceSearch.cancel()
	}

	ctx, cancel := context.WithCancel(context.Background())
	session := &workspaceSearchSession{
		generation: generation,
		done:       query == "",
		cancel:     cancel,
		consumed:   make(chan struct{}, 1),
	}
	r.workspaceSearch = session
	if query != "" {
		workspaceSnapshot := r.app.Workspace
		results := r.app.SearchWorkspace(ctx, []byte(query))
		go r.runWorkspaceSearch(ctx, session, workspaceSnapshot, results)
	}
	return nil
}

func (r *Runtime) cancelWorkspaceSearchLocked() {
	if r.workspaceSearch == nil {
		return
	}
	if r.workspaceSearch.cancel != nil {
		r.workspaceSearch.cancel()
	}
	r.workspaceSearch = nil
}

func (r *Runtime) cancelWorkspaceSearchGeneration(generation uint64) bool {
	session := r.workspaceSearch
	if session == nil || session.generation != generation {
		return false
	}
	if session.cancel != nil {
		session.cancel()
	}
	session.page = nil
	session.done = true
	select {
	case session.consumed <- struct{}{}:
	default:
	}
	return true
}

func (r *Runtime) runWorkspaceSearch(ctx context.Context, session *workspaceSearchSession, workspaceSnapshot workspace.Workspace, results <-chan workspace.SearchResult) {
	batch := make([]WorkspaceSearchResult, 0, WorkspaceSearchPageSize)
	var count uint64
	truncated := false
	reachedLimit := false

	for result := range results {
		if ctx.Err() != nil {
			return
		}
		if count >= WorkspaceSearchMaxResults {
			truncated = true
			reachedLimit = true
			break
		}

		relativePath, err := workspaceSnapshot.RelativePath(result.Path)
		if err != nil {
			continue
		}
		batch = append(batch, WorkspaceSearchResult{
			Path:          filepath.ToSlash(relativePath),
			Line:          result.Line,
			Column:        result.Column,
			StartByte:     result.StartByte,
			EndByte:       result.EndByte,
			Text:          result.Text,
			TextTruncated: result.TextTruncated,
		})
		count++

		if len(batch) == WorkspaceSearchPageSize {
			if !r.publishWorkspaceSearchPage(ctx, session, batch, count, truncated) {
				return
			}
			batch = make([]WorkspaceSearchResult, 0, WorkspaceSearchPageSize)
			if !waitForWorkspaceSearchPage(ctx, session.consumed) {
				return
			}
		}
		if count >= WorkspaceSearchMaxResults {
			truncated = true
			reachedLimit = true
			break
		}
	}

	if ctx.Err() != nil {
		return
	}
	if len(batch) > 0 {
		if !r.publishWorkspaceSearchPage(ctx, session, batch, count, truncated) {
			return
		}
		if !waitForWorkspaceSearchPage(ctx, session.consumed) {
			return
		}
	}
	if reachedLimit && session.cancel != nil {
		session.cancel()
	}
	r.finishWorkspaceSearch(session, count, truncated)
}

func waitForWorkspaceSearchPage(ctx context.Context, consumed <-chan struct{}) bool {
	select {
	case <-consumed:
		return true
	case <-ctx.Done():
		return false
	}
}

func (r *Runtime) publishWorkspaceSearchPage(ctx context.Context, session *workspaceSearchSession, results []WorkspaceSearchResult, count uint64, truncated bool) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if ctx.Err() != nil || r.lifecycle != lifecycleRunning || r.workspaceSearch != session || r.workspaceSearch.generation != session.generation {
		return false
	}
	session.sequence++
	session.count = count
	session.truncated = truncated
	session.page = &WorkspaceSearchPage{
		Generation: session.generation,
		Sequence:   session.sequence,
		Count:      count,
		Results:    append([]WorkspaceSearchResult(nil), results...),
	}
	if err := r.publishApplicationState(); err != nil {
		r.asyncError = err.Error()
		return false
	}
	return true
}

func (r *Runtime) finishWorkspaceSearch(session *workspaceSearchSession, count uint64, truncated bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.lifecycle != lifecycleRunning || r.workspaceSearch != session || r.workspaceSearch.generation != session.generation {
		return
	}
	session.count = count
	session.truncated = truncated
	session.done = true
	if err := r.publishApplicationState(); err != nil {
		r.asyncError = err.Error()
	}
}

func (r *Runtime) takeWorkspaceSearchPage(generation uint64) (*WorkspaceSearchPage, error) {
	session := r.workspaceSearch
	if session == nil || session.generation != generation {
		return nil, errors.New("workspace search generation is no longer active")
	}
	if session.page == nil {
		return &WorkspaceSearchPage{
			Generation: generation,
			Sequence:   session.sequence,
			Count:      session.count,
			Done:       session.done,
			Truncated:  session.truncated,
			Results:    []WorkspaceSearchResult{},
		}, nil
	}
	page := *session.page
	page.Count = session.count
	page.Done = session.done
	page.Truncated = session.truncated
	page.Results = append([]WorkspaceSearchResult(nil), session.page.Results...)
	session.page = nil
	select {
	case session.consumed <- struct{}{}:
	default:
	}
	return &page, nil
}
