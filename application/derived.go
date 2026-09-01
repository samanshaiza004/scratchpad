package application

import (
	"sync/atomic"
	"time"

	"scratchpad/document"
	"scratchpad/editor"
	"scratchpad/language"
	"scratchpad/language/markdown"
	"scratchpad/language/treesitter"
)

const projectionDebounce = 150 * time.Millisecond

type projectionResult struct {
	id          DocumentID
	revision    uint64
	projections document.Projections
	parsed      uint64
	runtime     languageAnalyzer
	err         error
}

type projectionState struct {
	seenRevision    uint64
	hasSeen         bool
	desiredRevision uint64
	hasDesired      bool
	due             time.Time
	running         bool
	closed          bool
	parsedRevision  uint64
	hasParsed       bool
	runtime         languageAnalyzer
}

// languageAnalyzer is the small application-internal seam shared by the
// concrete Markdown and Tree-sitter adapters. Parser implementations and
// parser trees do not cross into Document or the UI.
type languageAnalyzer interface {
	Analyze(source []byte, revision uint64, edits []editor.SourceEdit) (document.CodeProjection, error)
	Close()
}

// SetWake installs the UI wake seam. It is intentionally a callback rather
// than a Shirei dependency: the application can be tested without a window
// and workers never touch UI state.
func (a *Application) SetWake(wake func()) {
	a.derivedWake = wake
}

// PollDerived advances debouncing, bounded worker scheduling, and publication
// of language projections. Call it from the application/frame goroutine.
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
			if exists && result.runtime != nil {
				state.runtime = result.runtime
			}
			if exists && result.runtime != nil {
				state.parsedRevision = result.parsed
				state.hasParsed = true
			}
			if exists && state.closed {
				if state.runtime != nil {
					state.runtime.Close()
				}
				delete(a.derived, result.id)
				continue
			}
			if exists && doc != nil && result.err == nil && result.revision == doc.Revision() {
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
		if doc == nil || analysisLanguage(language.ID(doc.RootLanguage)) == "" {
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
			if state.running {
				continue
			}
			if state.runtime != nil {
				state.runtime.Close()
			}
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
		var edits []editor.SourceEdit
		if state.hasParsed {
			edits, _ = doc.Editor.EditsSince(state.parsedRevision)
		}
		runtime := state.runtime
		rootLanguage := language.ID(doc.RootLanguage)
		go func(id DocumentID, revision uint64, snapshot document.DocumentSnapshot, rootLanguage language.ID, edits []editor.SourceEdit, runtime languageAnalyzer) {
			data := snapshot.Materialize()
			var result projectionResult
			result.id, result.revision, result.parsed = id, revision, revision
			result.runtime = runtime
			if result.runtime == nil {
				result.runtime, result.err = newLanguageAnalyzer(rootLanguage)
			}
			if result.err == nil {
				if rootLanguage == language.Markdown {
					result.projections = markdown.Project(data, revision)
				} else if result.runtime != nil {
					code, err := result.runtime.Analyze(data, revision, edits)
					result.err = err
					result.projections = document.Projections{Revision: revision, Code: code}
				}
			}
			a.derivedResults <- result
			a.wakeDerived()
		}(id, revision, snapshot, rootLanguage, edits, runtime)
		state.desiredRevision = 0
		state.hasDesired = false
	}
}

func analysisLanguage(id language.ID) language.ID {
	switch id {
	case language.Markdown, language.Go:
		return id
	default:
		return ""
	}
}

func newLanguageAnalyzer(id language.ID) (languageAnalyzer, error) {
	switch id {
	case language.Go:
		return treesitter.NewGoAdapter()
	default:
		return nil, nil
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
