package markdown

import (
	"testing"

	"scratchpad/document"
)

func TestProjectHeadingsAndRanges(t *testing.T) {
	source := []byte("# One\n\ntext\n\nTitle\n-----\n\n```md\n# not a heading\n```\n\n    # also code\n")
	got := Project(source, 7)
	if got.Revision != 7 || len(got.Headings) != 2 {
		t.Fatalf("projection = %+v", got)
	}
	if got.Headings[0].ID != "one" || got.Headings[1].ID != "title" {
		t.Fatalf("heading IDs = %+v", got.Headings)
	}
	want := []document.Heading{
		{Level: 1, Text: "One", ID: "one", StartByte: 0, EndByte: 5},
		{Level: 2, Text: "Title", ID: "title", StartByte: 13, EndByte: 25},
	}
	for i := range want {
		if got.Headings[i] != want[i] {
			t.Fatalf("heading %d = %+v, want %+v", i, got.Headings[i], want[i])
		}
	}
}

func TestProjectEscapesInvalidHeadingBytesForDisplay(t *testing.T) {
	got := Project([]byte("# good\n# bad \xff\n"), 1)
	if len(got.Headings) != 2 || got.Headings[1].Text != `bad \xFF` {
		t.Fatalf("headings = %+v", got.Headings)
	}
}

func TestProjectLowersTasksAndLinksWithoutChangingSource(t *testing.T) {
	source := []byte("- [ ] Read [the guide](docs/guide%20one.md)\n- [x] Visit <https://example.com>\n")
	got := Project(source, 3)
	if len(got.Tasks) != 2 {
		t.Fatalf("tasks = %+v", got.Tasks)
	}
	if got.Tasks[0].Checked || !got.Tasks[1].Checked || got.Tasks[0].MarkerStart != 2 || got.Tasks[0].MarkerEnd != 5 {
		t.Fatalf("task markers = %+v", got.Tasks)
	}
	if len(got.Links) != 2 || got.Links[0].Target != "docs/guide%20one.md" || got.Links[1].Target != "https://example.com" {
		t.Fatalf("links = %+v", got.Links)
	}
}

func TestProjectLowersReferenceLinks(t *testing.T) {
	source := []byte("Read [full][guide], [collapsed][], and [shortcut].\n\n[guide]: docs/guide%20one.md\n[collapsed]: other.md\n[shortcut]: third.md\n")
	got := Project(source, 4)
	if len(got.Links) != 3 {
		t.Fatalf("links = %+v", got.Links)
	}
	want := []struct {
		target string
		text   string
		raw    string
	}{
		{target: "docs/guide%20one.md", text: "full", raw: "[full][guide]"},
		{target: "other.md", text: "collapsed", raw: "[collapsed][]"},
		{target: "third.md", text: "shortcut", raw: "[shortcut]"},
	}
	for i, want := range want {
		if got.Links[i].Target != want.target || got.Links[i].Label != want.text {
			t.Fatalf("link %d = %+v, want target %q label %q", i, got.Links[i], want.target, want.text)
		}
		if string(source[got.Links[i].StartByte:got.Links[i].EndByte]) != want.raw {
			t.Fatalf("link %d source = %q, want %q", i, source[got.Links[i].StartByte:got.Links[i].EndByte], want.raw)
		}
	}
}

func TestLinkTargetKindRecognizesAllowedAndWindowsPaths(t *testing.T) {
	for target, want := range map[string]string{
		"https://example.com":       "https",
		"mailto:person@example.com": "mailto",
		"ftp://example.com/file":    "unsupported",
		`C:\\work\\notes.md`:        "path",
		`\\server\share\notes.md`:   "path",
	} {
		if got := LinkTargetKind(target); got != want {
			t.Fatalf("LinkTargetKind(%q) = %q, want %q", target, got, want)
		}
	}
}

func TestProjectEmitsOnlySupportedFencedGoRegions(t *testing.T) {
	source := []byte("```go\nfunc main() {}\n```\n\n```rust\nfn main() {}\n```\n")
	got := Project(source, 11)
	if len(got.Injected) != 1 {
		t.Fatalf("injected regions = %+v", got.Injected)
	}
	region := got.Injected[0]
	if region.Language != "go" || string(source[region.StartByte:region.EndByte]) != "func main() {}\n" {
		t.Fatalf("Go region = %+v source=%q", region, source[region.StartByte:region.EndByte])
	}
	if region.StartByte < 0 || region.EndByte > len(source) || region.StartByte >= region.EndByte {
		t.Fatalf("invalid region = %+v", region)
	}
}
