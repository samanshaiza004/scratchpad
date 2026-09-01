//go:build cgo && !treesitter_pure && !treesitter_none

package treesitter

func backendCapabilities() BackendCapabilities {
	return BackendCapabilities{Backend: BackendOfficial, Go: true, TypeScript: true, TSX: true}
}
