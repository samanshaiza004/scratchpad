//go:build windows

package workspace

// NewOSTrasher returns the Windows Recycle Bin adapter.
func NewOSTrasher() Trasher { return windowsTrasher{} }
