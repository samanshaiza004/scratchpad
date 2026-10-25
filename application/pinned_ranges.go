package application

import (
	"errors"
	"fmt"
	"path/filepath"
	"unicode/utf8"
)

const MaxPinnedRanges = 256
const MaxPinnedRows = 256
const MaxPinnedBytes = 64 * 1024
const MaxPinnedLineBytes = 16 * 1024

var ErrPinnedUnavailable = errors.New("pinned source is no longer current; select the passage in source and pin it again")
var ErrPinnedRevision = errors.New("pinned surface changed; refresh before using this action")

type PinID uint64

type pinnedRange struct {
	id                   PinID
	origin               projectionSegment
	path, relativePath   string
	firstLine, lineCount int
}

type pinnedSurface struct {
	epoch, revision, nextID uint64
	projection              *Projection
	order                   []pinnedRange
	statuses                []ProjectionStatus
	invalidations           uint64
}

// PinnedRangeView contains captured coordinates, never excerpt contents.
// FirstLine is zero-based. Source byte ranges are half-open.
type PinnedRangeView struct {
	ID             PinID            `json:"id"`
	DocumentID     DocumentID       `json:"document_id"`
	InstanceID     uint64           `json:"instance_id"`
	SourceRevision uint64           `json:"source_revision"`
	StartByte      int              `json:"start_byte"`
	EndByte        int              `json:"end_byte"`
	Path           string           `json:"path"`
	RelativePath   string           `json:"relative_path"`
	FirstLine      int              `json:"first_line"`
	LineCount      int              `json:"line_count"`
	FirstRow       int              `json:"first_row"`
	Status         ProjectionStatus `json:"status"`
}

type PinnedSnapshot struct {
	Epoch               uint64            `json:"epoch"`
	Revision            uint64            `json:"revision"`
	Generation          uint64            `json:"generation"`
	TotalRows           int               `json:"total_rows"`
	SourceInvalidations uint64            `json:"source_invalidations"`
	Ranges              []PinnedRangeView `json:"ranges"`
}

// PinSourceRange captures a new current source. Carried pins are never
// revalidated as NEW ranges: their original instance/revision survives edits,
// reorder, removal, and addition of another current range.
func (a *Application) PinSourceRange(id DocumentID, instance, revision uint64, start, end int) (PinID, error) {
	if a == nil {
		return 0, errors.New("nil application")
	}
	a.PinnedSnapshot()
	if len(a.pinned.order) >= MaxPinnedRanges || a.pinned.nextID == ^uint64(0) {
		return 0, errors.New("pinned range limit reached")
	}
	doc := a.Documents[id]
	if doc == nil || doc.Editor == nil || instance == 0 || doc.InstanceID() != instance || doc.Revision() != revision {
		return 0, ErrPinnedUnavailable
	}
	if _, nonText := a.FileViews[id]; nonText {
		return 0, ErrReadOnlyFileView
	}
	buffer := &doc.Editor.Buffer
	if start < 0 || end <= start || end > buffer.ByteLen() {
		return 0, errors.New("select a nonempty source range before pinning")
	}
	// Reject positions inside valid UTF-8 runes, retaining malformed bytes as
	// independently addressable source, just like the ordinary editor.
	for _, boundary := range []int{start, end} {
		lo, hi := max(0, boundary-3), min(buffer.ByteLen(), boundary+3)
		bytes, _ := buffer.Bytes(lo, hi)
		for at := 0; at < len(bytes); {
			_, size := utf8.DecodeRune(bytes[at:])
			if lo+at < boundary && lo+at+size > boundary {
				return 0, errors.New("source range splits a UTF-8 character")
			}
			at += size
		}
	}
	first, _ := buffer.LineAt(start)
	last, _ := buffer.LineAt(end - 1)
	path := filepath.Clean(doc.Path)
	relativePath := path
	if a.HasWorkspace {
		if rel, relErr := filepath.Rel(a.Workspace.Root, path); relErr == nil {
			relativePath = filepath.ToSlash(rel)
		}
	}
	pin := pinnedRange{id: PinID(a.pinned.nextID + 1), path: path, relativePath: relativePath, firstLine: first, lineCount: last - first + 1,
		origin: projectionSegment{source: ProjectionSegment{DocumentID: id, SourceRevision: revision, StartByte: start, EndByte: end}, instanceID: instance}}
	order := append(append([]pinnedRange(nil), a.pinned.order...), pin)
	if err := a.setPinnedOrder(order); err != nil {
		return 0, err
	}
	a.pinned.nextID++
	a.PinPreview(id)
	return pin.id, nil
}

func (a *Application) setPinnedOrder(order []pinnedRange) error {
	if a.pinned.revision == ^uint64(0) {
		return errors.New("pinned revision exhausted")
	}
	captured := make([]projectionSegment, len(order))
	total := 0
	for i, pin := range order {
		if pin.lineCount > int(^uint(0)>>1)-total-1 {
			return errors.New("pinned row count exceeds host capacity")
		}
		total += pin.lineCount + 1
		captured[i] = pin.origin
	}
	projection, err := a.newCapturedProjection("pinned", "pinned", captured)
	if err != nil {
		return err
	}
	a.pinned.order = order
	a.pinned.projection = projection
	window, _ := a.QueryProjection(projection, 0, MaxPinnedRanges)
	a.pinned.statuses = make([]ProjectionStatus, len(window.Segments))
	for i, segment := range window.Segments {
		a.pinned.statuses[i] = segment.Status
	}
	a.pinned.revision++
	a.touchPresentation()
	return nil
}

func (a *Application) PinnedSnapshot() PinnedSnapshot {
	if a == nil {
		return PinnedSnapshot{}
	}
	s := PinnedSnapshot{Epoch: a.pinned.epoch, Revision: a.pinned.revision, SourceInvalidations: a.pinned.invalidations, Ranges: make([]PinnedRangeView, 0, len(a.pinned.order))}
	if len(a.pinned.order) == 0 {
		return s
	}
	window, _ := a.QueryProjection(a.pinned.projection, 0, MaxPinnedRanges)
	changed := false
	for i, segment := range window.Segments {
		if len(a.pinned.statuses) == len(window.Segments) && a.pinned.statuses[i] != segment.Status {
			changed = true
			if a.pinned.invalidations != ^uint64(0) {
				a.pinned.invalidations++
			}
		}
		pin := a.pinned.order[i]
		rows := pin.lineCount
		if segment.Status != ProjectionCurrent {
			rows = 1
		}
		s.Ranges = append(s.Ranges, PinnedRangeView{ID: pin.id, DocumentID: pin.origin.source.DocumentID, InstanceID: pin.origin.instanceID,
			SourceRevision: pin.origin.source.SourceRevision, StartByte: pin.origin.source.StartByte, EndByte: pin.origin.source.EndByte,
			Path: pin.path, RelativePath: pin.relativePath, FirstLine: pin.firstLine, LineCount: pin.lineCount, FirstRow: s.TotalRows, Status: segment.Status})
		s.TotalRows += 1 + rows
	}
	if changed {
		if a.pinned.revision != ^uint64(0) {
			a.pinned.revision++
		}
		a.touchPresentation()
	}
	a.pinned.statuses = make([]ProjectionStatus, len(window.Segments))
	for i, segment := range window.Segments {
		a.pinned.statuses[i] = segment.Status
	}
	s.Generation = window.Generation
	s.Revision = a.pinned.revision
	s.SourceInvalidations = a.pinned.invalidations
	return s
}

func (a *Application) pinnedAt(epoch, revision uint64, id PinID) (PinnedSnapshot, int, error) {
	s := a.PinnedSnapshot()
	if epoch != s.Epoch || revision != s.Revision {
		return s, -1, ErrPinnedRevision
	}
	for i, pin := range s.Ranges {
		if pin.ID == id {
			return s, i, nil
		}
	}
	return s, -1, errors.New("unknown pin")
}

func (a *Application) MovePinnedRange(epoch, revision uint64, id PinID, delta int) error {
	_, i, err := a.pinnedAt(epoch, revision, id)
	if err != nil {
		return err
	}
	if delta != -1 && delta != 1 {
		return errors.New("pin movement must be one position")
	}
	to := i + delta
	if to < 0 || to >= len(a.pinned.order) {
		return nil
	}
	order := append([]pinnedRange(nil), a.pinned.order...)
	order[i], order[to] = order[to], order[i]
	return a.setPinnedOrder(order)
}

func (a *Application) RemovePinnedRange(epoch, revision uint64, id PinID) error {
	_, i, err := a.pinnedAt(epoch, revision, id)
	if err != nil {
		return err
	}
	order := append([]pinnedRange(nil), a.pinned.order[:i]...)
	order = append(order, a.pinned.order[i+1:]...)
	return a.setPinnedOrder(order)
}

func (a *Application) ClearPinnedRanges() error {
	if a.pinned.epoch == ^uint64(0) {
		return errors.New("pinned surface epoch exhausted")
	}
	if err := a.setPinnedOrder(nil); err != nil {
		return err
	}
	a.pinned.epoch++
	return nil
}

// ResolvePinnedSource never maps or clamps old coordinates into newer bytes.
func (a *Application) ResolvePinnedSource(epoch, revision uint64, id PinID) (PinnedRangeView, error) {
	s, i, err := a.pinnedAt(epoch, revision, id)
	if err != nil {
		return PinnedRangeView{}, err
	}
	pin := s.Ranges[i]
	if pin.Status != ProjectionCurrent {
		return PinnedRangeView{}, ErrPinnedUnavailable
	}
	return pin, nil
}

func (a *Application) ReadPinnedBytes(epoch, revision uint64, id PinID) ([]byte, error) {
	pin, err := a.ResolvePinnedSource(epoch, revision, id)
	if err != nil {
		return nil, err
	}
	if pin.EndByte-pin.StartByte > MaxPinnedBytes {
		return nil, errors.New("Copy excerpt is limited to 64 KiB; open the source to copy a larger selection")
	}
	return a.Documents[pin.DocumentID].Editor.Buffer.Bytes(pin.StartByte, pin.EndByte)
}

// PinnedRow describes one header, source line, or unavailable-status row.
// Text bytes are in the detached window payload, not in the metadata snapshot.
type PinnedRow struct {
	Row        int    `json:"row"`
	PinID      PinID  `json:"pin_id"`
	Kind       string `json:"kind"`
	SourceLine int    `json:"source_line"`
	StartByte  int    `json:"start_byte"`
	EndByte    int    `json:"end_byte"`
	Offset     int    `json:"offset"`
	Length     int    `json:"length"`
	HasBefore  bool   `json:"has_before"`
	HasMore    bool   `json:"has_more"`
}

type PinnedWindow struct {
	Epoch     uint64      `json:"epoch"`
	Revision  uint64      `json:"revision"`
	First     int         `json:"first"`
	TotalRows int         `json:"total_rows"`
	Rows      []PinnedRow `json:"rows"`
	Data      []byte      `json:"-"`
}

func (a *Application) ReadPinnedWindow(epoch, revision uint64, first, limit, maxBytes, anchor int) (PinnedWindow, error) {
	s := a.PinnedSnapshot()
	if s.Epoch != epoch || s.Revision != revision {
		return PinnedWindow{}, ErrPinnedRevision
	}
	if first < 0 || limit < 1 || limit > MaxPinnedRows || maxBytes < 1 || maxBytes > MaxPinnedBytes || anchor < 0 {
		return PinnedWindow{}, errors.New("invalid pinned window bounds")
	}
	w := PinnedWindow{Epoch: s.Epoch, Revision: s.Revision, First: first, TotalRows: s.TotalRows, Rows: make([]PinnedRow, 0, min(limit, 32))}
	for row := first; row < s.TotalRows && len(w.Rows) < limit; row++ {
		pin := s.Ranges[0]
		for _, candidate := range s.Ranges {
			if candidate.FirstRow > row {
				break
			}
			pin = candidate
		}
		r := PinnedRow{Row: row, PinID: pin.ID, Kind: "header"}
		if row > pin.FirstRow {
			if pin.Status != ProjectionCurrent {
				r.Kind = "status"
			} else {
				r.Kind = "text"
				r.SourceLine = pin.FirstLine + row - pin.FirstRow - 1
				buffer := &a.Documents[pin.DocumentID].Editor.Buffer
				lineStart, lineEnd, ok := buffer.LineRange(r.SourceLine)
				if !ok {
					return PinnedWindow{}, ErrPinnedUnavailable
				}
				if lineEnd > lineStart && lineEnd < buffer.ByteLen() {
					last, _ := buffer.ByteAt(lineEnd - 1)
					next, _ := buffer.ByteAt(lineEnd)
					if last == '\r' && next == '\n' {
						lineEnd--
					}
				}
				start, end := max(pin.StartByte, lineStart), min(pin.EndByte, lineEnd)
				if end < start {
					end = start
				}
				at := start
				if row == first && anchor != 0 {
					at = anchor
					if at < start || at > end {
						return PinnedWindow{}, errors.New("pin chunk anchor is outside the selected line")
					}
				}
				budget := min(MaxPinnedLineBytes, maxBytes-len(w.Data))
				if at < end && budget == 0 {
					break
				}
				r.StartByte, r.EndByte = at, at
				var bytes []byte
				if at < end {
					chunk, chunkStart, _, _, err := buffer.BoundedLineChunk(r.SourceLine, at, budget)
					if err != nil {
						return PinnedWindow{}, fmt.Errorf("pinned line: %w", err)
					}
					chunkEnd := min(end, chunkStart+len(chunk))
					if chunkEnd > at {
						bytes = chunk[at-chunkStart : chunkEnd-chunkStart]
						r.EndByte = chunkEnd
					}
					if r.EndByte == at && at < end { // CR from a CRLF is intentionally not displayed.
						if end-at == 1 {
							b, _ := buffer.ByteAt(at)
							if b == '\r' {
								end = at
							}
						}
						if at < end {
							return PinnedWindow{}, errors.New("pinned line chunk cannot make progress within the read budget")
						}
					}
				}
				r.Offset = len(w.Data)
				r.Length = len(bytes)
				r.HasBefore = at > start
				r.HasMore = r.EndByte < end
				w.Data = append(w.Data, bytes...)
			}
		}
		w.Rows = append(w.Rows, r)
	}
	return w, nil
}
