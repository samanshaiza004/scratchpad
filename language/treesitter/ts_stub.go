//go:build !cgo || treesitter_pure

package treesitter

import (
	"errors"

	"scratchpad/document"
	"scratchpad/editor"
)

var errTypeScriptBackendUnavailable = errors.New("TypeScript adapter requires the selected official CGO backend")

type typeScriptImplementationStub struct{}

func newTypeScriptImplementation(bool) (typeScriptImplementation, error) {
	return nil, errTypeScriptBackendUnavailable
}

func (*typeScriptImplementationStub) Analyze([]byte, uint64, []editor.SourceEdit) (document.CodeProjection, error) {
	return document.CodeProjection{}, errTypeScriptBackendUnavailable
}

func (*typeScriptImplementationStub) Close() {}
