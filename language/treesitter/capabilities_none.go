//go:build treesitter_none

package treesitter

func backendCapabilities() BackendCapabilities {
	return BackendCapabilities{Backend: BackendNone}
}
