package markdown

import (
	"reflect"
	"testing"

	"scratchpad/document"
)

func TestFormatTableAlignsCellsAndPreservesInlineSource(t *testing.T) {
	source := "| Name | Notes |\n| :-- | --: |\n| **Go** | `日本語` |\n"
	_, table := projectSingleTable(t, source, 41)
	formatted, ok := FormatTable([]byte(source), table)
	if !ok {
		t.Fatal("FormatTable returned !ok")
	}
	want := "| Name |  Notes |\n| :--- | -----: |\n| **Go**   | `日本語` |\n"
	if string(formatted) != want {
		t.Fatalf("formatted = %q, want %q", formatted, want)
	}
	if !reflect.DeepEqual(table.Columns, []document.TableColumn{{Alignment: document.TableAlignLeft}, {Alignment: document.TableAlignRight}}) {
		t.Fatalf("columns = %+v", table.Columns)
	}
}

func TestFormatTableUsesVisibleUnicodeWidthAndKeepsEscapedPipes(t *testing.T) {
	source := "| a | b |\n| --- | --- |\n| \u65e5 | x |\n| c\\|d | yy |\n"
	_, table := projectSingleTable(t, source, 42)
	formatted, ok := FormatTable([]byte(source), table)
	if !ok {
		t.Fatal("FormatTable returned !ok")
	}
	want := "| a   | b   |\n| --- | --- |\n| 日  | x   |\n| c\\|d | yy  |\n"
	if string(formatted) != want {
		t.Fatalf("formatted = %q, want %q", formatted, want)
	}
}

func TestFormatTableRefusesOverlongBodyRows(t *testing.T) {
	source := "| a | b |\n| --- | --- |\n| x | y | z |\n"
	_, table := projectSingleTable(t, source, 42)
	if len(table.Columns) != 2 || len(table.Rows[2].Cells) != 3 {
		t.Fatalf("projection schema = %d columns, %d body cells; want 2, 3", len(table.Columns), len(table.Rows[2].Cells))
	}
	if formatted, ok := FormatTable([]byte(source), table); ok || formatted != nil {
		t.Fatalf("FormatTable(%q) = %q, %v; want refusal", source, formatted, ok)
	}
}

func TestFormatTableKeepsTableTerminatingNewlineConvention(t *testing.T) {
	for _, source := range []string{
		"| a | b |\n| --- | --- |\n| c | d |",
		"| a | b |\r\n| --- | --- |\r\n| c | d |\r\n",
	} {
		_, table := projectSingleTable(t, source, 43)
		formatted, ok := FormatTable([]byte(source), table)
		if !ok {
			t.Fatalf("FormatTable returned !ok for %q", source)
		}
		if len(formatted) > 0 && formatted[len(formatted)-1] == '\n' != (len(source) > 0 && source[len(source)-1] == '\n') {
			t.Fatalf("newline convention changed: formatted=%q source=%q", formatted, source)
		}
	}
}

func TestFormatTableMinimumAlignedDelimiterWidths(t *testing.T) {
	tests := []struct {
		name, source, want string
	}{
		{"default", "| a |\n| --- |\n| b |\n", "| a   |\n| --- |\n| b   |\n"},
		{"left", "| a |\n| :-- |\n| b |\n", "| a    |\n| :--- |\n| b    |\n"},
		{"right", "| a |\n| --: |\n| b |\n", "|    a |\n| ---: |\n|    b |\n"},
		{"center", "| a |\n| :--: |\n| b |\n", "|   a   |\n| :---: |\n|   b   |\n"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, table := projectSingleTable(t, test.source, 44)
			formatted, ok := FormatTable([]byte(test.source), table)
			if !ok || string(formatted) != test.want {
				t.Fatalf("formatted = %q, %v; want %q", formatted, ok, test.want)
			}
		})
	}
}

func TestFormatTableClustersJoinedEmojiAndCombiningText(t *testing.T) {
	source := "| a |\n| --- |\n| 👩‍💻 |\n| 👍🏽 |\n| 🇬🇹 |\n| é |\n| का |\n"
	_, table := projectSingleTable(t, source, 45)
	formatted, ok := FormatTable([]byte(source), table)
	if !ok {
		t.Fatal("FormatTable returned !ok")
	}
	want := "| a   |\n| --- |\n| 👩‍💻  |\n| 👍🏽  |\n| 🇬🇹  |\n| é   |\n| का  |\n"
	if string(formatted) != want {
		t.Fatalf("formatted = %q, want %q", formatted, want)
	}
}

func TestTableCellDisplayWidthUsesUnicodeGraphemeWidth(t *testing.T) {
	tests := []struct {
		name string
		text string
		want int
	}{
		{"text presentation", "☺", 1},
		{"emoji presentation", "☺️", 2},
		{"joined emoji", "👩‍💻", 2},
		{"emoji modifier", "👍🏽", 2},
		{"regional indicator pair", "🇬🇹", 2},
		{"combining mark", "é", 1},
		{"Indic cluster", "का", 2},
		{"wide CJK", "界", 2},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := tableCellDisplayWidth([]byte(test.text)); got != test.want {
				t.Fatalf("tableCellDisplayWidth(%q) = %d, want %d", test.text, got, test.want)
			}
		})
	}
}
