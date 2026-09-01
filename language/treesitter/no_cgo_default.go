//go:build !cgo && !treesitter_pure && !treesitter_none

package treesitter

import "errors"

// An untagged no-CGO build must not silently become a different product. Use
// -tags treesitter_pure for the explicit Go-only fallback or
// -tags treesitter_none for an intentionally parser-free build.
var errImplicitNoCGO = errors.New("CGO is disabled; select -tags treesitter_pure or -tags treesitter_none")

func newGoImplementation() (goImplementation, error) {
	return nil, errImplicitNoCGO
}

func newTypeScriptImplementation(bool) (typeScriptImplementation, error) {
	return nil, errImplicitNoCGO
}

func backendCapabilities() BackendCapabilities {
	return BackendCapabilities{Backend: BackendNone}
}

// Deliberately fail compilation rather than allow an implicit no-CGO product
// build with incomplete language-service behavior.
var _ = implicitNoCGOReleaseBuildMustChooseAnExplicitBackend
