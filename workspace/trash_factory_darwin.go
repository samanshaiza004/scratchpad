//go:build darwin

package workspace

// NewOSTrasher returns the macOS Finder-backed trash adapter.
func NewOSTrasher() Trasher { return darwinTrasher{} }
