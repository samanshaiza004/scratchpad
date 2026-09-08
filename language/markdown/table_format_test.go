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
