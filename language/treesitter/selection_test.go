package treesitter

import (
	"slices"
	"strings"
	"testing"
	"unicode/utf8"

	"scratchpad/document"
	"scratchpad/editor"
)

var selectionFixtures = []struct {
	language    string
	source      string
	expression  string
	replacement string
}{
	{
		language: "go",
		source: "package demo\n\ntype Item struct {\n\tName string\n}\n\n// café 🌳\n" +
			"func render(item Item) string {\n\tlabel := strings.TrimSpace(item.Name)\n\treturn label\n}\n",
		expression:  "strings.TrimSpace(item.Name)",
		replacement: "strings.TrimSpace(item.Name + \"é\")",
	},
	{
		language: "typescript",
		source: "interface User {\n  name: string\n}\n// café 🌳\n" +
			"function greet(user: User): string {\n  const label = user.name.trim();\n  return label;\n}\n",
		expression:  "user.name.trim()",
		replacement: "(user.name + \"é\").trim()",
	},
	{
		language: "tsx",
		source: "type Props = { name: string };\n// café 🌳\n" +
			"export function App(p: Props) {\n  return <div><span>{p.name}</span></div>;\n}\n",
		expression:  "<span>{p.name}</span>",
		replacement: "<strong>{p.name + \"é\"}</strong>",
	},
}

func newSelectionAdapter(t *testing.T, language string) goImplementation {
	t.Helper()
	caps := Capabilities()
	if language == "go" && !caps.Go || language == "typescript" && !caps.TypeScript || language == "tsx" && !caps.TSX {
		t.Skipf("%s is unavailable on backend %s", language, caps.Backend)
	}
	var adapter goImplementation
	var err error
	if language == "go" {
		adapter, err = NewGoAdapter()
	} else {
		adapter, err = NewTypeScriptAdapter(language == "tsx")
	}
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(adapter.Close)
	return adapter
}

func assertSelectionRangeBounds(t *testing.T, source string, ranges []document.SelectionRange) {
	t.Helper()
	for i, span := range ranges {
		if span.StartByte < 0 || span.StartByte >= span.EndByte || span.EndByte > len(source) {
			t.Fatalf("invalid selection range %#v for %d bytes", span, len(source))
		}
		if !utf8.ValidString(source[:span.StartByte]) || !utf8.ValidString(source[:span.EndByte]) {
			t.Fatalf("selection range %#v splits a UTF-8 character", span)
		}
		if i > 0 {
			previous := ranges[i-1]
			if previous.StartByte > span.StartByte || previous.StartByte == span.StartByte && previous.EndByte >= span.EndByte {
				t.Fatalf("selection ranges are not sorted and unique: %#v, %#v", previous, span)
			}
		}
		if text := source[span.StartByte:span.EndByte]; text == "(" || text == ")" || text == "{" || text == "}" || text == ";" {
			t.Fatalf("anonymous punctuation contributed a selection range: %q", text)
		}
	}
}

func requireSelectionChain(t *testing.T, source string, ranges []document.SelectionRange, anchor int, snippets ...string) {
	t.Helper()
	previous := document.SelectionRange{StartByte: anchor, EndByte: anchor + 1}
	for _, snippet := range snippets {
		searchFrom := 0
		var want document.SelectionRange
		for {
			offset := strings.Index(source[searchFrom:], snippet)
			if offset < 0 {
				t.Fatalf("fixture has no %q containing byte %d", snippet, anchor)
			}
			want = document.SelectionRange{StartByte: searchFrom + offset, EndByte: searchFrom + offset + len(snippet)}
			if want.StartByte <= anchor && anchor < want.EndByte {
				break
			}
			searchFrom = want.StartByte + 1
		}
		if !slices.Contains(ranges, want) {
			t.Fatalf("missing selection range %#v for %q", want, snippet)
		}
		if want.StartByte > previous.StartByte || want.EndByte < previous.EndByte {
			t.Fatalf("range %#v for %q does not contain previous range %#v", want, snippet, previous)
		}
		previous = want
	}
}

func TestAdaptersPublishNestedSelectionRanges(t *testing.T) {
	for _, fixture := range selectionFixtures {
		t.Run(fixture.language, func(t *testing.T) {
			adapter := newSelectionAdapter(t, fixture.language)
			projection, err := adapter.Analyze([]byte(fixture.source), 7, nil)
			if err != nil {
				t.Fatal(err)
			}
			if projection.Language != fixture.language || projection.Revision != 7 {
				t.Fatalf("projection identity = %q/%d", projection.Language, projection.Revision)
			}
			ranges := projection.SelectionRanges
			assertSelectionRangeBounds(t, fixture.source, ranges)
			switch fixture.language {
			case "go":
				body := "{\n\tlabel := strings.TrimSpace(item.Name)\n\treturn label\n}"
				requireSelectionChain(t, fixture.source, ranges, strings.Index(fixture.source, "item.Name")+len("item."),
					"Name", "item.Name", fixture.expression, "label := "+fixture.expression,
					body, "func render(item Item) string "+body, fixture.source)
				requireSelectionChain(t, fixture.source, ranges, strings.Index(fixture.source, "Name string"),
					"Name", "Name string", "{\n\tName string\n}", "struct {\n\tName string\n}",
					"Item struct {\n\tName string\n}", "type Item struct {\n\tName string\n}")
			case "typescript":
				body := "{\n  const label = user.name.trim();\n  return label;\n}"
				requireSelectionChain(t, fixture.source, ranges, strings.Index(fixture.source, "user.name")+len("user."),
					"name", "user.name", "user.name.trim", fixture.expression, "label = "+fixture.expression,
					"const label = "+fixture.expression+";", body, "function greet(user: User): string "+body, fixture.source)
				requireSelectionChain(t, fixture.source, ranges, strings.Index(fixture.source, "name: string"),
					"name", "name: string", "{\n  name: string\n}", "interface User {\n  name: string\n}")
			case "tsx":
				body := "{\n  return <div><span>{p.name}</span></div>;\n}"
				requireSelectionChain(t, fixture.source, ranges, strings.Index(fixture.source, "p.name")+len("p."),
					"name", "p.name", "{p.name}", fixture.expression, "<div>"+fixture.expression+"</div>",
					"return <div>"+fixture.expression+"</div>;", body, "function App(p: Props) "+body,
					"export function App(p: Props) "+body, fixture.source)
				requireSelectionChain(t, fixture.source, ranges, strings.Index(fixture.source, "name: string"),
					"name", "name: string", "{ name: string }", "type Props = { name: string };")
			}
		})
	}
}

func TestSelectionRangesFollowEditsAndRevisions(t *testing.T) {
	for _, fixture := range selectionFixtures {
		t.Run(fixture.language, func(t *testing.T) {
			adapter := newSelectionAdapter(t, fixture.language)
			ed := editor.NewScratchEditor([]byte(fixture.source))
			initial, err := adapter.Analyze(ed.Buffer.Text(), ed.Revision(), nil)
			if err != nil {
				t.Fatal(err)
			}
			snapshot := slices.Clone(initial.SelectionRanges)
			checkFresh := func(edits []editor.SourceEdit) document.CodeProjection {
				t.Helper()
				source := ed.Buffer.Text()
				got, err := adapter.Analyze(source, ed.Revision(), edits)
				if err != nil {
					t.Fatal(err)
				}
				fresh := newSelectionAdapter(t, fixture.language)
				want, err := fresh.Analyze(source, ed.Revision(), nil)
				if err != nil {
					t.Fatal(err)
				}
				if got.Revision != ed.Revision() || got.Language != fixture.language || !slices.Equal(got.SelectionRanges, want.SelectionRanges) {
					t.Fatalf("revision %d selection ranges differ from fresh parse: got %+v, want %+v", ed.Revision(), got, want)
				}
				assertSelectionRangeBounds(t, string(source), got.SelectionRanges)
				if initial.Revision != 0 || !slices.Equal(initial.SelectionRanges, snapshot) {
					t.Fatal("editing or replacing the parser tree mutated the previous projection")
				}
				return got
			}
			start := strings.Index(fixture.source, fixture.expression)
			ed.SetSelection(start, start+len(fixture.expression))
			if err := ed.Insert([]byte(fixture.replacement)); err != nil {
				t.Fatal(err)
			}
			edits, ok := ed.EditsSince(initial.Revision)
			if !ok || len(edits) != 1 {
				t.Fatalf("replacement edit chain ok=%v len=%d", ok, len(edits))
			}
			changed := checkFresh(edits)
			requireSelectionChain(t, string(ed.Buffer.Text()), changed.SelectionRanges, start, fixture.replacement)

			// A missing journal or one starting before the adapter's current
			// revision must rebuild ranges from the current source.
			for _, missingHistory := range []bool{true, false} {
				ed.SetCursor(0)
				if err := ed.Insert([]byte("// naïve\n")); err != nil {
					t.Fatal(err)
				}
				var history []editor.SourceEdit
				if !missingHistory {
					history, ok = ed.EditsSince(0)
					if !ok || history[0].BeforeRevision == changed.Revision {
						t.Fatal("fixture did not provide a mismatched edit journal")
					}
				}
				changed = checkFresh(history)
			}
			ed.SetSelection(0, ed.Buffer.ByteLen())
			if err := ed.Insert(nil); err != nil {
				t.Fatal(err)
			}
			edits, ok = ed.EditsSince(changed.Revision)
			if !ok {
				t.Fatal("deletion edit chain unavailable")
			}
			empty := checkFresh(edits)
			if len(empty.SelectionRanges) != 0 {
				t.Fatalf("empty source retained selection ranges: %+v", empty.SelectionRanges)
			}
			if err := ed.Undo(); err != nil {
				t.Fatal(err)
			}
			edits, ok = ed.EditsSince(empty.Revision)
			if !ok {
				t.Fatal("undo edit chain unavailable")
			}
			if restored := checkFresh(edits); !slices.Equal(restored.SelectionRanges, changed.SelectionRanges) {
				t.Fatal("undo did not restore selection ranges from the earlier revision")
			}
		})
	}
}

func TestSelectionRangesForDeepSyntax(t *testing.T) {
	const depth = 512
	expression := strings.Repeat("(", depth) + "value" + strings.Repeat(")", depth)
	for _, language := range []string{"go", "typescript", "tsx"} {
		t.Run(language, func(t *testing.T) {
			adapter := newSelectionAdapter(t, language)
			source := "function deep() { return " + expression + "; }\n"
			if language == "go" {
				source = "package demo\nfunc deep() int { return " + expression + " }\n"
			}
			projection, err := adapter.Analyze([]byte(source), 0, nil)
			if err != nil {
				t.Fatal(err)
			}
			assertSelectionRangeBounds(t, source, projection.SelectionRanges)
			requireSelectionChain(t, source, projection.SelectionRanges, strings.Index(source, "value"),
				"value", "(value)", expression)
			if len(projection.SelectionRanges) < depth {
				t.Fatalf("deep syntax lost ranges: got %d, want at least %d", len(projection.SelectionRanges), depth)
			}
		})
	}
}

func TestSelectionRangesForIncompleteSyntax(t *testing.T) {
	for _, fixture := range []struct{ language, source string }{
		{"go", "package demo\nfunc broken() {\n value := call(\n"},
		{"typescript", "function broken() {\n const value = call(\n"},
		{"tsx", "function App() { return <div>{user.\n"},
	} {
		t.Run(fixture.language, func(t *testing.T) {
			adapter := newSelectionAdapter(t, fixture.language)
			projection, err := adapter.Analyze([]byte(fixture.source), 11, nil)
			if err != nil {
				t.Fatal(err)
			}
			if len(projection.SelectionRanges) == 0 {
				t.Fatal("incomplete syntax discarded all named ranges")
			}
			assertSelectionRangeBounds(t, fixture.source, projection.SelectionRanges)
		})
	}
}

func TestNormalizeSelectionRanges(t *testing.T) {
	ranges := []document.SelectionRange{
		{StartByte: 4, EndByte: 7}, {StartByte: 0, EndByte: 7},
		{StartByte: 0, EndByte: 3}, {StartByte: 4, EndByte: 7},
		{StartByte: -1, EndByte: 3}, {StartByte: 2, EndByte: 2},
		{StartByte: 5, EndByte: 3}, {StartByte: 0, EndByte: 8},
	}
	want := []document.SelectionRange{{StartByte: 0, EndByte: 3}, {StartByte: 0, EndByte: 7}, {StartByte: 4, EndByte: 7}}
	if got := normalizeSelectionRanges(ranges, 7); !slices.Equal(got, want) {
		t.Fatalf("normalized ranges = %+v, want %+v", got, want)
	}
}
