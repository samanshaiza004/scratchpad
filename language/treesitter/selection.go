package treesitter

import (
	"slices"
	"sort"

	"scratchpad/document"
)

// normalizeSelectionRanges leaves only nonempty source ranges, ordered by
// start byte and then end byte. Named wrappers can share their child's range;
// collapse those duplicates so selection expansion always makes progress.
func normalizeSelectionRanges(ranges []document.SelectionRange, sourceLen int) []document.SelectionRange {
	valid := ranges[:0]
	for _, span := range ranges {
		if span.StartByte >= 0 && span.StartByte < span.EndByte && span.EndByte <= sourceLen {
			valid = append(valid, span)
		}
	}
	sort.Slice(valid, func(i, j int) bool {
		if valid[i].StartByte == valid[j].StartByte {
			return valid[i].EndByte < valid[j].EndByte
		}
		return valid[i].StartByte < valid[j].StartByte
	})
	return slices.Compact(valid)
}
