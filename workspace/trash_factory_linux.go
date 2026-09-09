//go:build linux

package workspace

// NewOSTrasher returns the freedesktop/XDG trash adapter.
func NewOSTrasher() Trasher { return linuxTrasher{} }
