package treesitter

import "fmt"

// BackendKind identifies the parser runtime linked into this build.
type BackendKind string

const (
	BackendOfficial BackendKind = "tree-sitter-cgo"
	BackendPure     BackendKind = "gotreesitter"
	BackendNone     BackendKind = "none"
)

// BackendCapabilities is the product-visible language-service capability
// report. It makes build-time backend selection observable instead of letting
// CGO availability silently change the application.
type BackendCapabilities struct {
	Backend    BackendKind
	Go         bool
	TypeScript bool
	TSX        bool
}

// Capabilities reports the parser backend and language support in this binary.
func Capabilities() BackendCapabilities {
	return backendCapabilities()
}

// RequireOfficial is used by release verification to reject incomplete
// no-CGO builds. Developer builds may intentionally use BackendPure or
// BackendNone.
func RequireOfficial() error {
	caps := Capabilities()
	if caps.Backend != BackendOfficial || !caps.Go || !caps.TypeScript || !caps.TSX {
		return fmt.Errorf("official Tree-sitter backend required, got %q (Go=%t TypeScript=%t TSX=%t)", caps.Backend, caps.Go, caps.TypeScript, caps.TSX)
	}
	return nil
}
