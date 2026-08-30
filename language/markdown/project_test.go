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
