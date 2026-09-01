//go:build treesitter_pure && !treesitter_none

package treesitter

func backendCapabilities() BackendCapabilities {
	return BackendCapabilities{Backend: BackendPure, Go: true}
}
