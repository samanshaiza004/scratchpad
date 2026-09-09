//go:build !darwin && !linux && !windows

package workspace

// NewOSTrasher makes unsupported desktop behavior explicit.
func NewOSTrasher() Trasher { return UnavailableTrasher{} }
