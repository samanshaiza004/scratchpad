// scratcheditor is the conditional Gate B prototype: a piece-backed editable
// buffer rendered as fixed-height logical lines through Shirei's virtual list.
// The pure editor package carries the first parity layer; this executable is
// still a storage/viewport proof, not a product editor.
package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"runtime"
	"strings"
	"time"
	"unicode/utf8"

	"scratchpad/editor"
	scratchui "scratchpad/ui"

	. "go.hasen.dev/shirei"
)

const (
	windowWidth  = 1200
	windowHeight = 800
)

type fixture struct {
	Name string
	Text []byte
}

type input struct {
	Text   string
	Scroll Vec2
}

type result struct {
	Fixture       string
	DocumentBytes int
	Operation     string
	Wall          time.Duration
	Allocs        uint64
	AllocBytes    uint64
	HeapBefore    uint64
	HeapAfter     uint64
}

var (
	active          *editor.ScratchEditor
	fixtureName     string
	windowSize      = Vec2{windowWidth, windowHeight}
	sessionKey      any
	operationFilter map[string]bool
)

func main() {
	name := flag.String("fixture", "all", "fixture: 100k, 1m, 10m, unicode-10m, single-2m, or all")
	operations := flag.String("operations", "all", "comma-separated operations, or all")
	output := flag.String("out", "", "optional TSV output path")
	flag.Parse()
	setFilter(*operations)

	fixtures, err := fixtures(*name)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	out := io.Writer(os.Stdout)
	if *output != "" {
		file, err := os.Create(*output)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		defer file.Close()
		out = file
	}
	fmt.Fprintln(out, "fixture\tdocument_bytes\toperation\twall_ms\tallocs\talloc_bytes\theap_before\theap_after")
	for _, f := range fixtures {
		for _, r := range runFixture(f) {
			fmt.Fprintf(out, "%s\t%d\t%s\t%.3f\t%d\t%d\t%d\t%d\n",
				r.Fixture, r.DocumentBytes, r.Operation,
				float64(r.Wall)/float64(time.Millisecond), r.Allocs,
				r.AllocBytes, r.HeapBefore, r.HeapAfter)
		}
	}
}

func fixtures(name string) ([]fixture, error) {
	all := []fixture{
		{Name: "100k", Text: normal(100 << 10)},
		{Name: "1m", Text: normal(1 << 20)},
		{Name: "10m", Text: normal(10 << 20)},
		{Name: "unicode-10m", Text: unicodeText(10 << 20)},
		{Name: "single-2m", Text: []byte(strings.Repeat("x", 2<<20))},
	}
	if name == "all" {
		return all, nil
	}
	for _, f := range all {
		if f.Name == name {
			return []fixture{f}, nil
		}
	}
	return nil, fmt.Errorf("unknown fixture %q", name)
}

func normal(target int) []byte {
	line := "package scratchpad\n\nfunc generatedLine() { return \"ordinary source text\" }\n"
	var b strings.Builder
	b.Grow(target)
	for b.Len() < target {
		b.WriteString(line)
	}
	return []byte(b.String()[:target])
}

func unicodeText(target int) []byte {
	line := "// 日本語 e\u0301 café 👩‍💻 — مرحبا — नमस्ते\n"
	var b strings.Builder
	b.Grow(target + len(line))
	for b.Len() < target {
		b.WriteString(line)
	}
	text := b.String()
	for len(text) > target && !utf8.ValidString(text[:target]) {
		target--
	}
	return []byte(text[:target])
}

func setFilter(spec string) {
	operationFilter = make(map[string]bool)
	for _, name := range strings.Split(spec, ",") {
		name = strings.TrimSpace(name)
		if name != "" {
			operationFilter[name] = true
		}
	}
	if len(operationFilter) == 0 {
		operationFilter["all"] = true
	}
}

func wants(operation string) bool {
	return operationFilter["all"] || operationFilter[operation]
}

func runFixture(f fixture) []result {
	fixtureName = f.Name
	results := make([]result, 0, 8)

	if wants("first-paint") {
		reset(f.Text)
		results = append(results, measure("first-paint", input{}))
	}

	for _, position := range []struct {
		name string
		byte int
	}{
		{name: "middle", byte: len(f.Text) / 2},
		{name: "near-9m", byte: min(9<<20, len(f.Text))},
	} {
		operation := "insert-" + position.name
		if !wants(operation) {
			continue
		}
		reset(f.Text)
		active.SetCursor(validOffset(f.Text, position.byte))
		results = append(results, measure(operation, input{Text: "x"}))
	}

	if wants("paste-100k") {
		reset(f.Text)
		active.SetCursor(len(f.Text) / 2)
		results = append(results, measure("paste-100k", input{Text: strings.Repeat("P", 100<<10)}))
	}
	if wants("selection-visible") {
		reset(f.Text)
		active.SetSelection(0, min(100, len(f.Text)))
		results = append(results, measure("selection-visible", input{}))
	}
	if wants("scroll-top-bottom") {
		reset(f.Text)
		results = append(results, measure("scroll-top-bottom", input{Scroll: Vec2{0, 1 << 20}}))
	}
	if wants("resize") {
		reset(f.Text)
		windowSize = Vec2{800, 600}
		results = append(results, measure("resize", input{}))
		windowSize = Vec2{windowWidth, windowHeight}
	}
	return results
}

func reset(source []byte) {
	ResetInputSession()
	GetHost().HeadlessRender = true
	GetHost().WindowFocused = true
	GetHost().WindowSize = windowSize
	GetHost().WindowScale = 1
	GetHost().GlyphCacheBudgetBytes = 16 << 20
	active = editor.NewScratchEditor(source)
	sessionKey = new(int)
	RunFrameFn(rootView)
	RunFrameFn(rootView)
}

func measure(operation string, in input) result {
	runtime.GC()
	var before runtime.MemStats
	runtime.ReadMemStats(&before)
	GetFrameInput().Text = in.Text
	GetFrameInput().Scroll = in.Scroll
	start := time.Now()
	RunFrameFn(rootView)
	wall := time.Since(start)
	var after runtime.MemStats
	runtime.ReadMemStats(&after)
	return result{
		Fixture: fixtureName, DocumentBytes: active.Buffer.ByteLen(), Operation: operation,
		Wall: wall, Allocs: after.Mallocs - before.Mallocs,
		AllocBytes: after.TotalAlloc - before.TotalAlloc,
		HeapBefore: before.HeapAlloc, HeapAfter: after.HeapAlloc,
	}
}

func rootView() {
	ContainerWithKey(sessionKey, Attrs(Viewport, Background(220, 12, 96, 1), Pad(16), Gap(8)), func() {
		Label("Scratchpad Gate B — ScratchEditor spike", FontWeight(WeightBold), FontSize(16))
		Label(fmt.Sprintf("fixture=%s bytes=%d lines=%d", fixtureName, active.Buffer.ByteLen(), active.Buffer.LineCount()), FontSize(12))
		scratchui.EditableView(sessionKey, active, scratchui.EditorViewOptions{
			Style:     TextStyle(FontSize(13), TextColor(0, 0, 15, 1)),
			RowHeight: 18,
		})
	})
}

func validOffset(source []byte, at int) int {
	if at >= len(source) {
		return len(source)
	}
	for at > 0 && !utf8.RuneStart(source[at]) {
		at--
	}
	return at
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
