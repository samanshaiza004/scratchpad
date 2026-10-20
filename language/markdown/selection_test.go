package markdown

import (
	"bytes"
	"reflect"
	"slices"
	"strings"
	"testing"
	"unicode/utf8"

	"scratchpad/document"
)

func TestProjectSelectionRangesRepeatedNested(t *testing.T) {
	source := []byte("Before ***bold and _nested_*** after.\n\n- outer **item**\n  - inner ~~old `code`~~\n- sibling\n")
	ranges := Project(source, 1).SelectionRanges
	assertSelectionRangesValid(t, source, ranges)
	assertSelectionChain(t, source, ranges,
		"_nested_",
		"**bold and _nested_**",
		"***bold and _nested_***",
		"Before ***bold and _nested_*** after.",
	)
	assertSelectionChain(t, source, ranges,
		"`code`",
		"~~old `code`~~",
		"inner ~~old `code`~~",
		"- inner ~~old `code`~~",
		"- outer **item**\n  - inner ~~old `code`~~",
		"- outer **item**\n  - inner ~~old `code`~~\n- sibling",
	)
	// Repeated constructs must retain their own source offsets.
	repeated := []byte("**same** and **same**\n\n**same**\n")
	ranges = Project(repeated, 2).SelectionRanges
	for at := 0; at < len(repeated); {
		next := bytes.Index(repeated[at:], []byte("**same**"))
		if next < 0 {
			break
		}
		start := at + next
		assertSelectionRange(t, ranges, start, start+len("**same**"))
		at = start + len("**same**")
	}
}

func TestProjectSelectionRangesHeadingSections(t *testing.T) {
	source := []byte("# One\n\nintro\n\n## Two\n\nchild\n\n### Three\n\nleaf\n\n## Four\n\nsibling\n\n# Five\n\nlast\n")
	ranges := Project(source, 3).SelectionRanges
	assertSelectionRangesValid(t, source, ranges)
	for _, heading := range []string{"# One", "## Two", "### Three", "## Four", "# Five"} {
		start := bytes.Index(source, []byte(heading))
		assertSelectionRange(t, ranges, start, start+len(heading))
	}
	for _, pair := range [][2]string{
		{"# One", "# Five"},
		{"## Two", "## Four"},
		{"### Three", "## Four"},
		{"## Four", "# Five"},
		{"# Five", ""},
	} {
		start, end := bytes.Index(source, []byte(pair[0])), len(source)
		if pair[1] != "" {
			end = bytes.Index(source, []byte(pair[1]))
		}
		assertSelectionRange(t, ranges, start, end)
	}
	setext := []byte("Title\n=====\n\nbody\n\nChild\n-----\n\nchild body\n\nNext\n====\n")
	ranges = Project(setext, 4).SelectionRanges
	assertSelectionRange(t, ranges, 0, len("Title\n====="))
	assertSelectionRange(t, ranges, 0, bytes.Index(setext, []byte("Next")))
	start := bytes.Index(setext, []byte("Child"))
	assertSelectionRange(t, ranges, start, start+len("Child\n-----"))
	assertSelectionRange(t, ranges, start, bytes.Index(setext, []byte("Next")))
}

func TestProjectSelectionRangesInlineBoundaries(t *testing.T) {
	for _, construct := range []string{
		"*em*", "_em_", "**strong**", "__strong__", "~~strike~~", "~strike~",
		"***nested***", "**_nested_**", "~~**nested**~~", "*`code`*", "*[link](url)*",
		"*[]()*", "**![alt](image.png)**", "*<em>html</em>*",
		"`code`", "`` code ` inside ``", "` `", "`first\nsecond`", "``first\n``",
		"[label](path(one(two)))", `[label](path\(one\))`,
		`[label](url "title ) ( here")`, `[label](url 'title ) here')`,
		"[label](url (title))", `[label](<url(with)paren> "title )")`,
		`[label](url "")`, `[label](<> "")`, "[label](<>)",
		"[label](foo'bar)", "[label](url\n  \"title )\")", "[empty]()", "[](url)",
		"[a `]` label](url)", "[a `[` label](url)", "[label [inner]](url)",
		`[a\]label](url)`, "[**label**](url)", "[![alt](image.png)](url)",
		"![alt](image(one).png)", "<https://example.com/a(b)>", "<a@example.com>",
		"*first\nsecond*", "**first\nsecond**", "~~first\nsecond~~",
	} {
		t.Run(construct, func(t *testing.T) {
			source := []byte("before " + construct + " after\n")
			ranges := Project(source, 5).SelectionRanges
			assertSelectionRangesValid(t, source, ranges)
			assertSelectionRange(t, ranges, len("before "), len("before ")+len(construct))
		})
	}
	for _, source := range []string{`before \*literal\* after`, "before *unclosed after", "before `unclosed after", "before [missing]( after"} {
		ranges := Project([]byte(source), 5).SelectionRanges
		if len(ranges) != 1 || ranges[0] != (document.SelectionRange{StartByte: 0, EndByte: len(source)}) {
			t.Errorf("literal %q ranges = %+v, want paragraph only", source, ranges)
		}
	}
}

func TestProjectSelectionRangesReferenceLinks(t *testing.T) {
	source := []byte("[full][ref] and [collapsed][] and [shortcut] and [a `[` label][ref]\n\n[ref]: target.md\n[collapsed]: two.md\n[shortcut]: three.md\n")
	ranges := Project(source, 6).SelectionRanges
	for _, construct := range []string{"[full][ref]", "[collapsed][]", "[shortcut]", "[a `[` label][ref]"} {
		start := bytes.Index(source, []byte(construct))
		assertSelectionRange(t, ranges, start, start+len(construct))
	}
}

func TestProjectSelectionRangesCompleteBlocks(t *testing.T) {
	for _, block := range []string{
		"first line\nsecond **line**", "> quote **bold**\n> continuation", ">",
		"- first\n- second", "1. first\n2. second", "- [ ] task\n- [x] done", "-",
		"---", "    indented\n    code", "```go\ncode\n```", "```\n```", "~~~\ncode\n~~~~",
		"```\nunclosed", "<div>\nhtml\n</div>", "| a | b |\n| - | - |\n| c | d |",
	} {
		t.Run(block, func(t *testing.T) {
			source := []byte(block + "\n\nfollowing\n")
			ranges := Project(source, 7).SelectionRanges
			assertSelectionRangesValid(t, source, ranges)
			if strings.Contains(block, "unclosed") {
				assertSelectionRange(t, ranges, 0, len(source)-1)
			} else {
				assertSelectionRange(t, ranges, 0, len(block))
			}
		})
	}
	// A block's final source segment may stop at the following line start.
	source := []byte("> quote\n\n```\ncode\n```\n# Next\n")
	ranges := Project(source, 7).SelectionRanges
	assertSelectionRange(t, ranges, 0, len("> quote"))
	start := bytes.Index(source, []byte("```"))
	assertSelectionRange(t, ranges, start, start+len("```\ncode\n```"))
}

func TestProjectSelectionRangesMultilineContainerLinks(t *testing.T) {
	source := []byte("> before [label](url\n> \"title )\"\n> ) after\n\n[ref]: target\n  \"multiline\n  title\"\n")
	ranges := Project(source, 7).SelectionRanges
	assertSelectionRangesValid(t, source, ranges)
	start := bytes.Index(source, []byte("[label]"))
	assertSelectionRange(t, ranges, start, start+len("[label](url\n> \"title )\"\n> )"))
	start = bytes.Index(source, []byte("[ref]:"))
	assertSelectionRange(t, ranges, start, len(source)-1)

	source = []byte("> before *`code\n> `* after\n")
	ranges = Project(source, 7).SelectionRanges
	start = bytes.IndexByte(source, '`')
	assertSelectionRange(t, ranges, start, start+len("`code\n> `"))
	assertSelectionRange(t, ranges, start-1, start+len("`code\n> `*"))
}

func TestProjectSelectionRangesCRLFAndUnicode(t *testing.T) {
	source := []byte("# 日本語 😀\r\n\r\nélan **界 _café_** and `` λ ` 😀 ``\r\ncontinued\r\n\r\n- [ ] tâche\r\n  - ~~終わり~~\r\n\r\n```\r\nλ\r\n```\r\n\r\n## 子\r\n\r\ntext\r\n\r\n# Fin\r\n")
	original := bytes.Clone(source)
	ranges := Project(source, 8).SelectionRanges
	assertSelectionRangesValid(t, source, ranges)
	for _, construct := range []string{
		"# 日本語 😀", "_café_", "**界 _café_**", "`` λ ` 😀 ``", "~~終わり~~",
		"élan **界 _café_** and `` λ ` 😀 ``\r\ncontinued",
		"- [ ] tâche\r\n  - ~~終わり~~", "```\r\nλ\r\n```",
	} {
		start := bytes.Index(source, []byte(construct))
		assertSelectionRange(t, ranges, start, start+len(construct))
	}
	assertSelectionRange(t, ranges, 0, bytes.Index(source, []byte("# Fin")))
	for _, r := range ranges {
		if !utf8.Valid(source[r.StartByte:r.EndByte]) {
			t.Errorf("range cuts a UTF-8 sequence: %+v", r)
		}
		for _, at := range []int{r.StartByte, r.EndByte} {
			if at > 0 && at < len(source) && source[at-1] == '\r' && source[at] == '\n' {
				t.Errorf("range splits CRLF: %+v", r)
			}
		}
	}
	if !bytes.Equal(source, original) {
		t.Fatal("Project mutated source")
	}
	if again := Project(source, 9).SelectionRanges; !reflect.DeepEqual(ranges, again) {
		t.Fatalf("ranges depend on projection revision: %+v vs %+v", ranges, again)
	}
}

func TestProjectSelectionRangesEmptyAndMalformed(t *testing.T) {
	for _, source := range [][]byte{nil, {}, []byte(" \t\r\n\r\n"), []byte("**bad \xff**\r\n"), []byte("#\r\n\r\n"), []byte("[]()\n")} {
		ranges := Project(source, 10).SelectionRanges
		assertSelectionRangesValid(t, source, ranges)
		if again := Project(source, 10).SelectionRanges; !reflect.DeepEqual(ranges, again) {
			t.Fatalf("nondeterministic ranges for %q: %+v vs %+v", source, ranges, again)
		}
	}
}

func assertSelectionRangesValid(t *testing.T, source []byte, ranges []document.SelectionRange) {
	t.Helper()
	for i, r := range ranges {
		if r.StartByte < 0 || r.StartByte >= r.EndByte || r.EndByte > len(source) {
			t.Fatalf("invalid range %+v for %q", r, source)
		}
		if i > 0 {
			previous := ranges[i-1]
			if previous.StartByte > r.StartByte || previous.StartByte == r.StartByte && previous.EndByte >= r.EndByte {
				t.Fatalf("ranges are unsorted or duplicated: %+v", ranges)
			}
		}
	}
}

func assertSelectionRange(t *testing.T, ranges []document.SelectionRange, start, end int) {
	t.Helper()
	if !slices.Contains(ranges, document.SelectionRange{StartByte: start, EndByte: end}) {
		t.Errorf("missing range [%d,%d) in %+v", start, end, ranges)
	}
}

func assertSelectionChain(t *testing.T, source []byte, ranges []document.SelectionRange, constructs ...string) {
	t.Helper()
	var previous document.SelectionRange
	for i, construct := range constructs {
		start := bytes.Index(source, []byte(construct))
		if start < 0 {
			t.Fatalf("test construct %q missing from source", construct)
		}
		next := document.SelectionRange{StartByte: start, EndByte: start + len(construct)}
		assertSelectionRange(t, ranges, next.StartByte, next.EndByte)
		if i > 0 && (next.StartByte > previous.StartByte || next.EndByte < previous.EndByte || next == previous) {
			t.Fatalf("chain did not strictly expand: %+v -> %+v", previous, next)
		}
		previous = next
	}
}
