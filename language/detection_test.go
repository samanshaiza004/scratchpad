package language

import "testing"

func TestDetectPath(t *testing.T) {
	tests := map[string]ID{
		"README.md":     Markdown,
		"main.go":       Go,
		"lib.rs":        Rust,
		"component.TSX": TypeScript,
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
