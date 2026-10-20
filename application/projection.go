package application

import (
	"errors"
	"fmt"
)

// MaxProjectionWindow is the largest number of segments returned by one query.
const MaxProjectionWindow = 256

// ProjectionSegment describes a nonempty, half-open byte range at one source
// revision. Label and Context are optional caller-owned metadata, never source
// text fetched by the projection. Segments may overlap or repeat.
type ProjectionSegment struct {
	DocumentID     DocumentID
	SourceRevision uint64
	StartByte      int
	EndByte        int
	Label          string
	Context        string
}

// ProjectionKey identifies a presentation occurrence within one application's
// projection generations. Ordinal is zero-based; duplicate source ranges have
// distinct keys. Rebuilding a projection assigns a new Generation.
type ProjectionKey struct {
	Generation uint64
	Ordinal    int
}

// ProjectionStatus reports whether a segment still resolves to its source.
type ProjectionStatus string

const (
	// ProjectionCurrent means the document instance and source revision match.
	ProjectionCurrent ProjectionStatus = "current"
	// ProjectionStale means the path is open at another revision or instance.
	ProjectionStale ProjectionStatus = "stale"
	// ProjectionMissing means the source document is no longer open.
	ProjectionMissing ProjectionStatus = "missing"
)

// ProjectionSegmentView is copied metadata for one presentation occurrence.
// Stale and missing occurrences retain their original source coordinates.
type ProjectionSegmentView struct {
	ProjectionSegment
	PresentationKey ProjectionKey
	Status          ProjectionStatus
}

// ProjectionWindow contains a copied header and at most MaxProjectionWindow
// segment views. First is the requested zero-based ordinal, even past Total.
// The caller may freely modify the window without changing the projection.
type ProjectionWindow struct {
	ID         string
	Kind       string
	Generation uint64
	Total      int
	First      int
	Segments   []ProjectionSegmentView
}

// Projection is an immutable, disposable ordering of revision-scoped source
// ranges, constructed by Application.NewProjection. It owns only metadata,
// including numeric document instance identities; it retains no document,
// editor, parser, frontend, or application references. There is no registry:
// dropping the projection releases its derived metadata.
type Projection struct {
	id         string
	kind       string
	generation uint64
	segments   []projectionSegment
}

type projectionSegment struct {
	source     ProjectionSegment
	instanceID uint64
}

// NewProjection validates and copies the ordered metadata without reading
// source bytes or changing any source or selection state. ID and kind must be
// nonempty; an empty segment list is valid. Every source must be open, at the
// supplied revision, with 0 <= StartByte < EndByte <= its byte length.
// Successful builds receive increasing generations local to this application,
// even when ID is reused. Like other application operations, construction and
// queries run on the application goroutine, serialized with source mutations.
func (a *Application) NewProjection(id, kind string, segments []ProjectionSegment) (*Projection, error) {
	if a == nil {
		return nil, errors.New("nil application")
	}
	if id == "" || kind == "" {
		return nil, errors.New("projection ID and kind must be nonempty")
	}
	if a.projectionGeneration == ^uint64(0) {
		return nil, errors.New("projection generation exhausted")
	}
	copied := make([]projectionSegment, len(segments))
	for i, segment := range segments {
		doc := a.Documents[segment.DocumentID]
		if doc == nil || doc.Editor == nil || doc.InstanceID() == 0 {
			return nil, fmt.Errorf("projection segment %d: source document %q is not open", i, segment.DocumentID)
		}
		if doc.Revision() != segment.SourceRevision {
			return nil, fmt.Errorf("projection segment %d: %w: expected %d, current %d", i, ErrStaleEditorRevision, segment.SourceRevision, doc.Revision())
		}
		if segment.StartByte < 0 || segment.EndByte <= segment.StartByte || segment.EndByte > doc.Editor.Buffer.ByteLen() {
			return nil, fmt.Errorf("projection segment %d: source range outside buffer or empty", i)
		}
		copied[i] = projectionSegment{source: segment, instanceID: doc.InstanceID()}
	}
	a.projectionGeneration++
	return &Projection{id: id, kind: kind, generation: a.projectionGeneration, segments: copied}, nil
}

// QueryProjection returns at most limit copied occurrences in presentation
// order, using one open-document lookup per returned segment: O(limit) time
// and space, independent of source sizes and the total segment count. It
// never reads source bytes. Status is resolved at query time and is current
// only for the captured document instance and source revision; reopening a
// path cannot revive an old segment. A later undo to the same revision in the
// same instance can make a segment current again.
//
// A negative first or a limit outside [1, MaxProjectionWindow] is an error.
// At or beyond Total, the result is an empty window with the original header.
// A nil or unconstructed projection is an error.
func (a *Application) QueryProjection(proj *Projection, first, limit int) (ProjectionWindow, error) {
	if a == nil {
		return ProjectionWindow{}, errors.New("nil application")
	}
	if proj == nil || proj.generation == 0 {
		return ProjectionWindow{}, errors.New("projection was not constructed")
	}
	if first < 0 || limit <= 0 || limit > MaxProjectionWindow {
		return ProjectionWindow{}, errors.New("invalid projection window")
	}
	window := ProjectionWindow{
		ID: proj.id, Kind: proj.kind, Generation: proj.generation,
		Total: len(proj.segments), First: first,
	}
	if first >= window.Total {
		return window, nil
	}
	count := min(limit, window.Total-first)
	window.Segments = make([]ProjectionSegmentView, count)
	for i := range window.Segments {
		ordinal := first + i
		segment := proj.segments[ordinal]
		status := ProjectionCurrent
		doc := a.Documents[segment.source.DocumentID]
		if doc == nil {
			status = ProjectionMissing
		} else if doc.Editor == nil || doc.InstanceID() != segment.instanceID || doc.Revision() != segment.source.SourceRevision {
			status = ProjectionStale
		}
		window.Segments[i] = ProjectionSegmentView{
			ProjectionSegment: segment.source,
			PresentationKey:   ProjectionKey{Generation: proj.generation, Ordinal: ordinal},
			Status:            status,
		}
	}
	return window, nil
}
