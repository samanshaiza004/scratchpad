package ui

import (
	"path/filepath"
	"testing"
)

func TestResolveLocalLinkPathDecodesEscapedPath(t *testing.T) {
	base := filepath.Join("/tmp", "notes", "README.md")
	got, err := resolveLocalLinkPath(base, "docs/guide%20one.md#start")
	if err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(filepath.Dir(base), "docs", "guide one.md")
	if got != want {
		t.Fatalf("path = %q, want %q", got, want)
	}
}

func TestResolveLocalLinkPathPreservesEncodedPercent(t *testing.T) {
	base := filepath.Join("/tmp", "notes", "README.md")
	got, err := resolveLocalLinkPath(base, "docs/%2520.md")
	if err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(filepath.Dir(base), "docs", "%20.md")
	if got != want {
		t.Fatalf("path = %q, want %q", got, want)
	}
}

func TestResolveLocalLinkPathRecognizesWindowsPaths(t *testing.T) {
	for _, target := range []string{`C:\\work\\notes.md`, `\\server\share\notes.md`} {
		got, err := resolveLocalLinkPath("/tmp/README.md", target)
		if err != nil {
			t.Fatal(err)
		}
		if got != filepath.Clean(target) {
			t.Fatalf("path = %q, want %q", got, filepath.Clean(target))
		}
	}
}
