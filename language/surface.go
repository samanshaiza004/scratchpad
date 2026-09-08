package language

import (
	"path/filepath"
	"strings"
)

// Surface describes the editing treatment for a file independently from its
// language-service identity. A code surface is useful even when no parser or
// highlighter is registered for the file's language.
type Surface uint8

const (
	SurfaceCode Surface = iota
	SurfaceProse
)

// SurfaceForPath keeps the product's prose/code boundary deliberately small:
// Markdown and ordinary text are prose; every other path is code-oriented.
// Language detection remains separate and may still return PlainText for an
// unknown extension.
func SurfaceForPath(path string) Surface {
	switch strings.ToLower(filepath.Ext(path)) {
	case ".md", ".markdown", ".mdown", ".txt", ".text":
		return SurfaceProse
	default:
		return SurfaceCode
	}
}
