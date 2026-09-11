package ui

import (
	"path/filepath"
	"reflect"
	"testing"
)

func TestTreeNavigationVisiblePathMovement(t *testing.T) {
	visible := []string{
		"docs",
		filepath.Join("docs", "README.md"),
		filepath.Join("docs", "src"),
		filepath.Join("docs", "src", "Μain.go"),
		"notes.md",
	}
	navigation := NewTreeNavigation(visible)

	if got := navigation.Index(filepath.Join("docs", "src")); got != 2 {
		t.Fatalf("Index = %d, want 2", got)
	}
	if got := navigation.Index("missing"); got != -1 {
		t.Fatalf("Index(missing) = %d, want -1", got)
	}
	if got, ok := navigation.Previous(filepath.Join("docs", "src")); !ok || got != filepath.Join("docs", "README.md") {
		t.Fatalf("Previous = %q, %v", got, ok)
	}
	if got, ok := navigation.Next(filepath.Join("docs", "src")); !ok || got != filepath.Join("docs", "src", "Μain.go") {
		t.Fatalf("Next = %q, %v", got, ok)
	}
	if _, ok := navigation.Previous(visible[0]); ok {
		t.Fatal("Previous wrapped before the first path")
	}
	if _, ok := navigation.Next(visible[len(visible)-1]); ok {
		t.Fatal("Next advanced past the last path")
	}
}

func TestTreeNavigationHierarchyAndHomeEnd(t *testing.T) {
	visible := []string{
		"folder",
		filepath.Join("folder", "child.txt"),
		filepath.Join("folder", "nested"),
		filepath.Join("folder", "nested", "deep.txt"),
		"last.txt",
	}
	navigation := NewTreeNavigation(visible)

	if got, ok := navigation.FirstChild("folder"); !ok || got != filepath.Join("folder", "child.txt") {
		t.Fatalf("FirstChild = %q, %v", got, ok)
	}
	if got, ok := navigation.FirstChild("last.txt"); ok || got != "" {
		t.Fatalf("FirstChild(file) = %q, %v", got, ok)
	}
	if got, ok := navigation.Parent(filepath.Join("folder", "nested", "deep.txt")); !ok || got != filepath.Join("folder", "nested") {
		t.Fatalf("Parent = %q, %v", got, ok)
	}
	if _, ok := navigation.Parent("folder"); ok {
		t.Fatal("root-level path unexpectedly had a visible parent")
	}
	if got, ok := navigation.Home(); !ok || got != visible[0] {
		t.Fatalf("Home = %q, %v", got, ok)
	}
	if got, ok := navigation.End(); !ok || got != visible[len(visible)-1] {
		t.Fatalf("End = %q, %v", got, ok)
	}
	if _, ok := NewTreeNavigation(nil).Home(); ok {
		t.Fatal("Home succeeded for an empty tree")
	}
}

func TestTreeNavigationRangeEndpoints(t *testing.T) {
	navigation := NewTreeNavigation([]string{"a", "b", "c", "d"})

	for _, test := range []struct {
		name      string
		anchor    string
		lead      string
		wantStart string
		wantEnd   string
		wantOK    bool
	}{
		{name: "forward", anchor: "b", lead: "d", wantStart: "b", wantEnd: "d", wantOK: true},
		{name: "backward", anchor: "d", lead: "b", wantStart: "b", wantEnd: "d", wantOK: true},
		{name: "single", anchor: "c", lead: "c", wantStart: "c", wantEnd: "c", wantOK: true},
		{name: "missing anchor", anchor: "missing", lead: "c", wantOK: false},
	} {
		t.Run(test.name, func(t *testing.T) {
			start, end, ok := navigation.RangeEndpoints(test.anchor, test.lead)
			if start != test.wantStart || end != test.wantEnd || ok != test.wantOK {
				t.Fatalf("RangeEndpoints = %q, %q, %v; want %q, %q, %v", start, end, ok, test.wantStart, test.wantEnd, test.wantOK)
			}
		})
	}
}

func TestTreeNavigationTypeAheadMatchesUnicodeNamesAndWraps(t *testing.T) {
	visible := []string{
		filepath.Join("docs", "Résumé.md"),
		"notes.md",
		filepath.Join("src", "main.go"),
		filepath.Join("src", "main_test.go"),
	}
	navigation := NewTreeNavigation(visible)

	tests := []struct {
		name    string
		current string
		prefix  string
		want    string
		ok      bool
	}{
		{name: "unicode case insensitive", current: "", prefix: "rÉ", want: visible[0], ok: true},
		{name: "searches displayed basename", current: visible[0], prefix: "main", want: visible[2], ok: true},
		{name: "continues then wraps", current: visible[2], prefix: "main", want: visible[3], ok: true},
		{name: "wraps to first match", current: visible[3], prefix: "main", want: visible[2], ok: true},
		{name: "unknown current starts at beginning", current: "missing", prefix: "notes", want: visible[1], ok: true},
		{name: "no match", current: "", prefix: "zzz", ok: false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, ok := navigation.TypeAhead(test.current, test.prefix)
			if got != test.want || ok != test.ok {
				t.Fatalf("TypeAhead = %q, %v; want %q, %v", got, ok, test.want, test.ok)
			}
		})
	}
}

func TestNewTreeNavigationSnapshotsVisiblePaths(t *testing.T) {
	visible := []string{"a", "b"}
	navigation := NewTreeNavigation(visible)
	visible[0] = "changed"
	got, ok := navigation.Home()
	if !ok || got != "a" {
		t.Fatalf("snapshot Home = %q, %v", got, ok)
	}

	if !reflect.DeepEqual(navigation.visible, []string{"a", "b"}) {
		t.Fatalf("snapshot paths = %#v", navigation.visible)
	}
}
