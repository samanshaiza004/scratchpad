package editor

import "sort"

// HiddenLineRange identifies logical lines omitted from a fixed-height view.
// End is exclusive.
type HiddenLineRange struct {
	Start int
	End   int
}

type rowSegment struct {
	logicalStart int
	logicalEnd   int
	visibleStart int
}

// RowMap maps a compact visible row sequence to logical buffer lines. Its
// storage is proportional to the number of normalized hidden intervals, not
// to the number of logical lines.
type RowMap struct {
	total    int
	visible  int
	segments []rowSegment
}

// NewRowMap clips, sorts, and coalesces hidden intervals before constructing
// the visible-row segments. Nested and overlapping intervals are represented
// only once.
func NewRowMap(total int, hidden []HiddenLineRange) RowMap {
	if total < 0 {
		total = 0
	}
	intervals := make([]HiddenLineRange, 0, len(hidden))
	for _, r := range hidden {
		if r.Start < 0 {
			r.Start = 0
		}
		if r.End > total {
			r.End = total
		}
		if r.Start < r.End {
			intervals = append(intervals, r)
		}
	}
	sort.Slice(intervals, func(i, j int) bool {
		if intervals[i].Start == intervals[j].Start {
			return intervals[i].End < intervals[j].End
		}
		return intervals[i].Start < intervals[j].Start
	})
	merged := intervals[:0]
	for _, r := range intervals {
		if len(merged) == 0 || r.Start > merged[len(merged)-1].End {
			merged = append(merged, r)
			continue
		}
		if r.End > merged[len(merged)-1].End {
			merged[len(merged)-1].End = r.End
		}
	}

	segments := make([]rowSegment, 0, len(merged)+1)
	logical, visible := 0, 0
	for _, r := range merged {
		if logical < r.Start {
			segments = append(segments, rowSegment{logicalStart: logical, logicalEnd: r.Start, visibleStart: visible})
			visible += r.Start - logical
		}
		logical = r.End
	}
	if logical < total {
		segments = append(segments, rowSegment{logicalStart: logical, logicalEnd: total, visibleStart: visible})
		visible += total - logical
	}
	return RowMap{total: total, visible: visible, segments: segments}
}

// IdentityRowMap returns a map with no hidden lines.
func IdentityRowMap(total int) RowMap { return NewRowMap(total, nil) }

func (m RowMap) Count() int { return m.visible }

func (m RowMap) Logical(visible int) (int, bool) {
	if visible < 0 || visible >= m.visible || len(m.segments) == 0 {
		return 0, false
	}
	index := sort.Search(len(m.segments), func(i int) bool {
		return m.segments[i].visibleStart+(m.segments[i].logicalEnd-m.segments[i].logicalStart) > visible
	})
	if index == len(m.segments) {
		return 0, false
	}
	s := m.segments[index]
	return s.logicalStart + visible - s.visibleStart, true
}

func (m RowMap) Visible(logical int) (int, bool) {
	if logical < 0 || logical >= m.total || len(m.segments) == 0 {
		return 0, false
	}
	index := sort.Search(len(m.segments), func(i int) bool {
		return m.segments[i].logicalEnd > logical
	})
	if index == len(m.segments) {
		return 0, false
	}
	s := m.segments[index]
	if logical < s.logicalStart {
		return 0, false
	}
	return s.visibleStart + logical - s.logicalStart, true
}
