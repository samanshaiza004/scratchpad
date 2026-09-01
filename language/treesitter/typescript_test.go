package treesitter

import (
	"strings"
	"testing"
)

func TestTypeScriptQueriesLayerCompatibleJavaScriptAssets(t *testing.T) {
	for _, test := range []struct {
		name string
		sx   bool
		want []string
	}{
		{name: "typescript", want: []string{"function_declaration", "type_identifier"}},
		{name: "tsx", sx: true, want: []string{"function_declaration", "jsx_opening_element", "jsx_attribute"}},
	} {
		t.Run(test.name, func(t *testing.T) {
			highlights, tags := TypeScriptQueries(test.sx)
			for _, needle := range test.want {
				if !strings.Contains(highlights, needle) {
					t.Fatalf("highlight query does not contain %q", needle)
				}
			}
			if !strings.Contains(tags, "definition.") || !strings.Contains(tags, "@name") {
				t.Fatalf("tags query is not tags-shaped: %q", tags)
			}
			if test.sx && !strings.Contains(highlights, "@tag") {
				t.Fatal("TSX query did not include JSX captures")
			}
		})
	}
}

func TestTypeScriptAdapterParsesTypeScriptAndTSX(t *testing.T) {
	for _, test := range []struct {
		name string
		sx   bool
		src  string
	}{
		{name: "typescript", src: "interface User {\n  name: string\n}\nfunction greet(user: User): string {\n  return user.name\n}\n"},
		{name: "tsx", sx: true, src: "type Props = { name: string };\nexport function App(p: Props) {\n  return <div>{p.name}</div>\n}\n"},
	} {
		t.Run(test.name, func(t *testing.T) {
			adapter, err := NewTypeScriptAdapter(test.sx)
			if err != nil {
				t.Skipf("selected TypeScript backend unavailable: %v", err)
			}
			defer adapter.Close()
			projection, err := adapter.Analyze([]byte(test.src), 7, nil)
			if err != nil {
				t.Fatal(err)
			}
			if projection.Language != map[bool]string{false: "typescript", true: "tsx"}[test.sx] || projection.Revision != 7 {
				t.Fatalf("projection identity = %q/%d", projection.Language, projection.Revision)
			}
			if len(projection.Highlights) == 0 || len(projection.Symbols) == 0 || len(projection.Folds) == 0 {
				t.Fatalf("projection lacks expected analysis: highlights=%d symbols=%d folds=%d", len(projection.Highlights), len(projection.Symbols), len(projection.Folds))
			}
			for _, span := range projection.Highlights {
				if span.StartByte < 0 || span.StartByte >= span.EndByte || span.EndByte > len(test.src) {
					t.Fatalf("invalid highlight span %#v", span)
				}
			}
		})
	}
}
