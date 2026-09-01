//go:build treesitter_none

package treesitter

import (
	"errors"
)

var errBackendUnavailable = errors.New("Tree-sitter backend disabled")

func newGoImplementation() (goImplementation, error) {
	return nil, errBackendUnavailable
}

func newTypeScriptImplementation(bool) (typeScriptImplementation, error) {
	return nil, errBackendUnavailable
}
