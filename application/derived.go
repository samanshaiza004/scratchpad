package application

import (
	"sync/atomic"
	"time"

	"scratchpad/document"
	"scratchpad/language"
	"scratchpad/language/markdown"
)

const projectionDebounce = 150 * time.Millisecond

type projectionResult struct {
	id          DocumentID
	revision    uint64
	projections document.Projections
}

type projectionState struct {
	seenRevision    uint64
	hasSeen         bool
	desiredRevision uint64
	hasDesired      bool
	due             time.Time
	running         bool
	closed          bool
}

// SetWake installs the UI wake seam. It is intentionally a callback rather
// than a Shirei dependency: the application can be tested without a window
// and workers never touch UI state.
func (a *Application) SetWake(wake func()) {
	a.derivedWake = wake
}

// PollDerived advances debouncing, bounded worker scheduling, and publication
// of Markdown projections. Call it from the application/frame goroutine.
func (a *Application) PollDerived(now time.Time) {
	if a == nil {
		return
	}
	a.ensureDerivedState()
	for {
		select {
		case result := <-a.derivedResults:
			a.derivedRunning--
			state, exists := a.derived[result.id]
			doc := a.Documents[result.id]
			if exists && doc != nil && !state.closed && result.revision == doc.Revision() {
				doc.SetDerived(nil, result.projections)
				state.seenRevision = result.revision
				state.hasSeen = true
			}
			if exists {
				state.running = false
			}
		default:
			goto drained
		}
	}
drained:
	for id, doc := range a.Documents {
		if doc == nil || doc.RootLanguage != string(language.Markdown) {
			continue
		}
		state := a.derived[id]
		if state == nil {
			state = &projectionState{}
			a.derived[id] = state
		}
		if revision := doc.Revision(); (!state.hasSeen || revision != state.seenRevision) && (!state.hasDesired || revision != state.desiredRevision) {
			state.desiredRevision = revision
			state.hasDesired = true
			state.due = now.Add(projectionDebounce)
			if a.derivedWake != nil {
				a.scheduleDerivedWake(projectionDebounce)
			}
		}
	}
	for id, state := range a.derived {
		doc := a.Documents[id]
		if state.closed || doc == nil {
			delete(a.derived, id)
			continue
		}
		if state.running || !state.hasDesired || now.Before(state.due) || a.derivedRunning >= maxProjectionWorkers {
			continue
		}
		revision := state.desiredRevision
		snapshot := doc.Snapshot()
		if snapshot.Revision != revision {
			state.desiredRevision = doc.Revision()
			state.hasDesired = true
			state.due = now.Add(projectionDebounce)
			continue
		}
		state.running = true
		a.derivedRunning++
		go func(id DocumentID, revision uint64, snapshot document.DocumentSnapshot) {
			data := snapshot.Materialize()
			result := projectionResult{id: id, revision: revision, projections: markdown.Project(data, revision)}
			a.derivedResults <- result
			a.wakeDerived()
		}(id, revision, snapshot)
		state.desiredRevision = 0
		state.hasDesired = false
	}
}

const maxProjectionWorkers = 2

func (a *Application) ensureDerivedState() {
	if a.derived == nil {
		a.derived = make(map[DocumentID]*projectionState)
	}
	if a.derivedResults == nil {
		a.derivedResults = make(chan projectionResult, 32)
	}
}

func (a *Application) scheduleDerivedWake(delay time.Duration) {
	if atomic.CompareAndSwapInt32(&a.derivedWakeScheduled, 0, 1) {
		time.AfterFunc(delay, func() {
			atomic.StoreInt32(&a.derivedWakeScheduled, 0)
			a.wakeDerived()
		})
	}
}

func (a *Application) wakeDerived() {
	if a.derivedWake != nil {
		a.derivedWake()
	}
}
