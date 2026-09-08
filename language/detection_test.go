package language

import "testing"

func TestDetectPath(t *testing.T) {
	tests := map[string]ID{
		"README.md":     Markdown,
		"main.go":       Go,
		"lib.rs":        Rust,
		"component.TSX": TSX,
		"script.py":     Python,
		"data.json":     JSON,
		"notes.txt":     PlainText,
		"no-extension":  PlainText,
	}
	for path, want := range tests {
		if got := DetectPath(path); got != want {
			t.Errorf("DetectPath(%q) = %q, want %q", path, got, want)
		}
	}
}

func TestSurfaceForPath(t *testing.T) {
	tests := map[string]Surface{
		"README.md":        SurfaceProse,
		"notes.txt":        SurfaceProse,
		"notes.TEXT":       SurfaceProse,
		"main.go":          SurfaceCode,
		"Background.astro": SurfaceCode,
		"styles.css":       SurfaceCode,
		"config.toml":      SurfaceCode,
		"unknown.xyz":      SurfaceCode,
		"Makefile":         SurfaceCode,
		".env":             SurfaceCode,
		"":                 SurfaceCode,
	}
	for path, want := range tests {
		if got := SurfaceForPath(path); got != want {
			t.Errorf("SurfaceForPath(%q) = %v, want %v", path, got, want)
		}
	}
}
