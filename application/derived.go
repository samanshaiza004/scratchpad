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

// Code parsers are designed to provide useful incremental results while the
// user is typing. Markdown still uses a quiet-period debounce because its
// whole-document structural projection is less latency-sensitive.
func projectionDelay(id language.ID) time.Duration {
	if id == language.Markdown {
		return projectionDebounce
	}
	return 0
}

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
	runningRevision uint64
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
			if exists && doc != nil && result.revision == doc.Revision() {
				publish := result.err == nil
				if !publish && result.runtime == nil &&
					result.projections.Revision == result.revision &&
					result.projections.Markdown.Revision == result.revision {
					// Injected-Go partial failure: the Markdown base projection
					// plus any partial Code remain valid for this revision, so
					// publish them instead of dropping the whole update. The
					// nested-language error stays recorded on result.err.
					publish = true
				}
				if publish {
					doc.SetDerived(nil, result.projections)
					state.seenRevision = result.revision
					state.hasSeen = true
				}
			}
			if exists {
				state.running = false
				state.runningRevision = 0
				if state.hasDesired && state.desiredRevision == result.revision {
					// A poll may have observed the same revision while its
					// worker was running. It is already represented by this
					// result, so do not schedule it a second time.
					state.hasDesired = false
					state.desiredRevision = 0
				}
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
		if revision := doc.Revision(); (!state.hasSeen || revision != state.seenRevision) &&
			(!state.hasDesired || revision != state.desiredRevision) &&
			(!state.running || revision != state.runningRevision) {
			state.desiredRevision = revision
			state.hasDesired = true
			delay := projectionDelay(language.ID(doc.RootLanguage))
			state.due = now.Add(delay)
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
			delay := projectionDelay(language.ID(doc.RootLanguage))
			state.due = now.Add(delay)
			continue
		}
		state.running = true
		state.runningRevision = revision
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
					if len(result.projections.Injected) > 0 {
						result.err = projectInjectedGo(result.projections.Injected, data, revision, &result.projections)
					}
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

	if a.derivedWake != nil {
		var nextDue time.Time
		for _, state := range a.derived {
			if !state.closed && state.hasDesired && state.due.After(now) &&
				(nextDue.IsZero() || state.due.Before(nextDue)) {
				nextDue = state.due
			}
		}
		if !nextDue.IsZero() {
			a.scheduleDerivedWake(nextDue.Sub(now))
		}
	}
}

func projectInjectedGo(regions []document.InjectedRegion, source []byte, revision uint64, projection *document.Projections) error {
	var highlights []document.HighlightSpan
	var symbols []document.Symbol
	var folds []document.LanguageFold
	// One adapter per projection: cheaper than per-fence construction and
	// safe to reuse because each region is fully reparsed (nil edits reset
	// the incremental tree). defer guarantees Close on every return path.
	adapter, err := treesitter.NewGoAdapter()
	if err != nil {
		return err
	}
	defer adapter.Close()
	var firstErr error
	for _, region := range regions {
		if region.Language != "go" || region.StartByte < 0 || region.EndByte > len(source) || region.StartByte >= region.EndByte {
			continue
		}
		code, err := adapter.Analyze(source[region.StartByte:region.EndByte], revision, nil)
		if err != nil {
			// Per-region failure must not discard other regions or the
			// Markdown base projection: accumulate what succeeded and
			// report the first error separately.
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		for _, span := range code.Highlights {
			span.StartByte += region.StartByte
			span.EndByte += region.StartByte
			highlights = append(highlights, span)
		}
		for _, symbol := range code.Symbols {
			symbol.StartByte += region.StartByte
			symbol.EndByte += region.StartByte
			symbols = append(symbols, symbol)
		}
		for _, fold := range code.Folds {
			fold.StartByte += region.StartByte
			fold.EndByte += region.StartByte
			folds = append(folds, fold)
		}
	}
	if len(highlights) > 0 || len(symbols) > 0 || len(folds) > 0 {
		projection.Code = document.NewCodeProjection(revision, "go", highlights, symbols, folds)
	}
	return firstErr
}

func analysisLanguage(id language.ID) language.ID {
	switch id {
	case language.Markdown:
		return id
	case language.Go:
		if treesitter.Capabilities().Go {
			return id
		}
	case language.TypeScript:
		if treesitter.Capabilities().TypeScript {
			return id
		}
	case language.TSX:
		if treesitter.Capabilities().TSX {
			return id
		}
	default:
		return ""
	}
	return ""
}

// AnalysisSupported reports whether this build has a projection adapter for
// the requested root language. UI surfaces can use it to distinguish a
// temporarily stale projection from a language that the compatibility build
// intentionally leaves as plain text.
func AnalysisSupported(id language.ID) bool {
	return analysisLanguage(id) != ""
}

func newLanguageAnalyzer(id language.ID) (languageAnalyzer, error) {
	switch id {
	case language.Go:
		return treesitter.NewGoAdapter()
	case language.TypeScript:
		return treesitter.NewTypeScriptAdapter(false)
	case language.TSX:
		return treesitter.NewTypeScriptAdapter(true)
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
		afterFunc := a.derivedAfterFunc
		if afterFunc == nil {
			afterFunc = func(delay time.Duration, wake func()) {
				time.AfterFunc(delay, wake)
			}
		}
		afterFunc(delay, func() {
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
