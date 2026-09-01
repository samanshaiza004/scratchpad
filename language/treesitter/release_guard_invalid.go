//go:build treesitter_release && (!cgo || treesitter_pure || treesitter_none)

package treesitter

// Deliberately fail an explicitly requested release build that does not link
// the complete official backend. The undefined symbol makes this a build-time
// failure rather than a runtime capability surprise.
var _ = officialReleaseBackendUnavailable
