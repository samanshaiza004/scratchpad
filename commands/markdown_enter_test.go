package commands

import "testing"

func TestMarkdownEnterContinuesStructuralPrefixes(t *testing.T) {
	tests := []struct {
		name   string
		prefix string
		want   string
	}{
		{"unordered", "- item", "- "},
		{"task resets unchecked", "- [x] done", "- [ ] "},
		{"ordered increments", "12. item", "13. "},
		{"ordered preserves delimiter", "8) item", "9) "},
		{"quote", "> quoted", "> "},
		{"nested quote list", "  > - item", "  > - "},
		{"plain indentation", "\t  text", "\t  "},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got := MarkdownEnterPrefix([]byte(test.prefix), false)
			if string(got.Prefix) != test.want || got.Breakout {
				t.Fatalf("MarkdownEnterPrefix(%q) = prefix %q breakout %v; want %q", test.prefix, got.Prefix, got.Breakout, test.want)
			}
		})
	}
}

func TestMarkdownEnterBreaksOutOfEmptyStructuralItems(t *testing.T) {
	tests := []struct {
		name       string
		prefix     string
		removeFrom int
		want       string
	}{
		{"bullet", "- ", 0, ""},
		{"indented bullet", "  - ", 2, "  "},
		{"checked task", "> - [x] ", 2, "> "},
		{"empty quote", "  > ", 2, "  "},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got := MarkdownEnterPrefix([]byte(test.prefix), true)
			if !got.Breakout || got.RemoveFrom != test.removeFrom || string(got.Prefix) != test.want {
				t.Fatalf("MarkdownEnterPrefix(%q) = %+v; want breakout from %d with prefix %q", test.prefix, got, test.removeFrom, test.want)
			}
		})
	}
	continued := MarkdownEnterPrefix([]byte("-  "), false)
	if continued.Breakout || string(continued.Prefix) != "- " {
		t.Fatalf("non-terminal empty-looking item should continue when not at EOL: %+v", continued)
	}
}
