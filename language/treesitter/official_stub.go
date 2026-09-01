//go:build !treesitter_cgo

package treesitter

import "errors"

var errNoTree = errors.New("parser returned no tree")

func runOfficial([]byte) (BenchmarkResult, error) {
	return BenchmarkResult{}, errors.New("official backend requires -tags treesitter_cgo")
}
