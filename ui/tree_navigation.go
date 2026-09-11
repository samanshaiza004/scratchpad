package ui

import (
	"path/filepath"
	"strings"
)

// TreeNavigation provides pure navigation over a tree's flattened visible
// paths. The paths are expected to be in preorder, as treeState.VisiblePaths
// is. It does not know about selection, expansion, focus, or filesystem
// state.
type TreeNavigation struct {
	visible []string
}

// NewTreeNavigation snapshots visiblePaths so callers can rebuild the helper
// when the tree changes without sharing mutable navigation state.
func NewTreeNavigation(visiblePaths []string) TreeNavigation {
	paths := make([]string, len(visiblePaths))
	copy(paths, visiblePaths)
	return TreeNavigation{visible: paths}
}

// Index returns the visible-path index of path, or -1 when path is not
// visible.
func (n TreeNavigation) Index(path string) int {
	for index, candidate := range n.visible {
		if candidate == path {
			return index
		}
	}
	return -1
}

// Previous returns the visible path immediately before path. It returns
// false when path is unknown or already the first visible path.
func (n TreeNavigation) Previous(path string) (string, bool) {
	index := n.Index(path)
	if index <= 0 {
		return "", false
	}
	return n.visible[index-1], true
}

// Next returns the visible path immediately after path. It returns false when
// path is unknown or already the last visible path.
func (n TreeNavigation) Next(path string) (string, bool) {
	index := n.Index(path)
	if index < 0 || index+1 >= len(n.visible) {
		return "", false
	}
	return n.visible[index+1], true
}

// FirstChild returns path's first visible direct child. A collapsed folder
// has no visible child, and an unknown path is not a valid parent.
func (n TreeNavigation) FirstChild(path string) (string, bool) {
	if n.Index(path) < 0 {
		return "", false
	}
	for _, candidate := range n.visible {
		if filepath.Dir(candidate) == path {
			return candidate, true
		}
	}
	return "", false
}

// Parent returns path's immediate parent when that parent is also visible.
// The workspace root is not itself a visible path, so root-level paths have
// no visible parent.
func (n TreeNavigation) Parent(path string) (string, bool) {
	if n.Index(path) < 0 {
		return "", false
	}
	parent := filepath.Dir(path)
	if parent == "." || parent == "" || parent == path || n.Index(parent) < 0 {
		return "", false
	}
	return parent, true
}

// Home returns the first visible path.
func (n TreeNavigation) Home() (string, bool) {
	if len(n.visible) == 0 {
		return "", false
	}
	return n.visible[0], true
}

// End returns the last visible path.
func (n TreeNavigation) End() (string, bool) {
	if len(n.visible) == 0 {
		return "", false
	}
	return n.visible[len(n.visible)-1], true
}

// RangeEndpoints returns the inclusive visible-order endpoints for a Shift
// range from anchor to lead. It preserves neither selection nor endpoint
// ownership; callers can use the returned paths to derive the selected slice.
func (n TreeNavigation) RangeEndpoints(anchor, lead string) (start, end string, ok bool) {
	anchorIndex := n.Index(anchor)
	leadIndex := n.Index(lead)
	if anchorIndex < 0 || leadIndex < 0 {
		return "", "", false
	}
	if anchorIndex > leadIndex {
		anchorIndex, leadIndex = leadIndex, anchorIndex
	}
	return n.visible[anchorIndex], n.visible[leadIndex], true
}

// TypeAhead returns the next visible path whose displayed name starts with
// prefix, comparing Unicode text case-insensitively. Searching starts after
// current and wraps once around the visible list. If current is not visible,
// searching starts at the beginning.
func (n TreeNavigation) TypeAhead(current, prefix string) (string, bool) {
	if len(n.visible) == 0 || prefix == "" {
		return "", false
	}

	start := 0
	if currentIndex := n.Index(current); currentIndex >= 0 {
		start = (currentIndex + 1) % len(n.visible)
	}
	for offset := 0; offset < len(n.visible); offset++ {
		index := (start + offset) % len(n.visible)
		if unicodePrefix(filepath.Base(n.visible[index]), prefix) {
			return n.visible[index], true
		}
	}
	return "", false
}

// unicodePrefix compares prefix-sized rune sequences rather than bytes, then
// uses Go's Unicode-aware simple case folding for the comparison.
func unicodePrefix(value, prefix string) bool {
	valueRunes := []rune(value)
	prefixRunes := []rune(prefix)
	if len(prefixRunes) == 0 || len(prefixRunes) > len(valueRunes) {
		return false
	}
	return strings.EqualFold(string(valueRunes[:len(prefixRunes)]), prefix)
}
