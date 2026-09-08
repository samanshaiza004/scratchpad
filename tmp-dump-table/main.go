package main

import (
	"fmt"

	"github.com/yuin/goldmark/v2/ast"
	"github.com/yuin/goldmark/v2/extension"
	markdownast "github.com/yuin/goldmark/v2/extension/ast"
	"github.com/yuin/goldmark/v2/parser"
	"github.com/yuin/goldmark/v2/text"
)

func dump(source string) {
	fmt.Printf("=== %q ===\n", source)
	src := []byte(source)
	root := parser.New(parser.WithAutoHeadingID(), parser.WithExtensions(
		extension.NewTaskListItemParser(), extension.NewStrikethroughParser(), extension.NewTableParser(),
	)).Parse(src)
	_ = ast.Walk(root, func(n ast.Node, entering bool) (ast.WalkStatus, error) {
		if !entering {
			return ast.WalkContinue, nil
		}
		switch t := n.(type) {
		case *markdownast.Table:
			fmt.Printf("Table pos=%d segs=%v\n", t.Pos(), segs(t, src))
		case *markdownast.TableHeader:
			fmt.Printf("  Header pos=%d\n", t.Pos())
		case *markdownast.TableBody:
			fmt.Printf("  Body pos=%d\n", t.Pos())
		case *markdownast.TableRow:
			fmt.Printf("  Row pos=%d parent=%s\n", t.Pos(), t.Parent().Kind().String())
		case *markdownast.TableCell:
			fmt.Printf("    Cell pos=%d align=%s segs=%v text=%q\n", t.Pos(), t.Alignment, segs(t, src), cellText(t, src))
		}
		return ast.WalkContinue, nil
	})
	fmt.Println()
}

func segs(n ast.Node, src []byte) []string {
	var out []string
	if b, ok := n.(ast.BlockNode); ok {
		for _, s := range b.Source() {
			out = append(out, fmt.Sprintf("[%d,%d]=%q pad=%d", s.Start, s.Stop, src[s.Start:s.Stop], s.Padding))
		}
	}
	return out
}

func cellText(n *markdownast.TableCell, src []byte) string {
	var out string
	for c := n.FirstChild(); c != nil; c = c.NextSibling() {
		if t, ok := c.(*ast.Text); ok {
			out += string(t.Value.Value(src))
		} else if cs, ok := c.(*ast.CodeSpan); ok {
			out += "`" + string(cs.Value.Bytes(src)) + "`"
		} else {
			out += "[" + c.Kind().String() + "]"
		}
	}
	return out
}

var _ = text.NewSegment

func main() {
	dump("| name | value |\n| :--- | ---: |\n| one | two |\n")
	dump("| a | b |\n| - | - |\n| c `x|y` d | e |\n")
	dump("| a | b |\n| - | - |\n| c \\| d | e |\n")
	dump("a | b\n-- | --\n1 | 2\n")
	dump("| a | b |\n| :- | :-: |\n|x|y|z|\n")
	dump("| `a` | **b** |\n| -- | :-: |\n| 日本語 | 🎉x |\n")
}
