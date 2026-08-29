// textbench measures Shirei's real TextArea frame and software-render path.
// It is intentionally a headless executable so fixture runs are deterministic
// and do not depend on window focus. It does not replace native smoke tests.
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

	. "go.hasen.dev/shirei"
	. "go.hasen.dev/shirei/widgets"
)

const (
	windowWidth  = 1200
	windowHeight = 800
)

type fixture struct {
	Name string
	Text string
}

type frameInput struct {
	Text   string
	Key    KeyCode
	Mods   Modifiers
	Scroll Vec2
}

type measurement struct {
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
	buffer          string
	fieldID         ContainerId
	windowSize      = Vec2{windowWidth, windowHeight}
	currentFixture  string
	sessionKey      any
	operationFilter map[string]bool
	softwareRender  bool
)

func main() {
	fixtureName := flag.String("fixture", "all", "fixture: 100k, 1m, 10m, unicode-10m, single-2m, or all")
	outputPath := flag.String("out", "", "optional TSV output path")
	operations := flag.String("operations", "all", "comma-separated operations, or all")
	softwareRenderFlag := flag.Bool("software-render", false, "also rasterize each frame with Shirei's software renderer")
	flag.Parse()
	setOperationFilter(*operations)
	softwareRender = *softwareRenderFlag

	fixtures, err := selectFixtures(*fixtureName)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}

	out := io.Writer(os.Stdout)
	var file *os.File
	if *outputPath != "" {
		file, err = os.Create(*outputPath)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		defer file.Close()
		out = file
	}

	fmt.Fprintln(out, "fixture\tdocument_bytes\toperation\twall_ms\tallocs\talloc_bytes\theap_before\theap_after")
	for _, f := range fixtures {
		for _, result := range runFixture(f) {
			fmt.Fprintf(out, "%s\t%d\t%s\t%.3f\t%d\t%d\t%d\t%d\n",
				result.Fixture, result.DocumentBytes, result.Operation,
				float64(result.Wall)/float64(time.Millisecond), result.Allocs,
				result.AllocBytes, result.HeapBefore, result.HeapAfter)
		}
	}
}

func selectFixtures(name string) ([]fixture, error) {
	all := []fixture{
		{Name: "100k", Text: generatedNormal(100 << 10)},
		{Name: "1m", Text: generatedNormal(1 << 20)},
		{Name: "10m", Text: generatedNormal(10 << 20)},
		{Name: "unicode-10m", Text: generatedUnicode(10 << 20)},
		{Name: "single-2m", Text: strings.Repeat("x", 2<<20)},
	}
	if name == "all" {
		return all, nil
	}
	for _, f := range all {
		if f.Name == name {
			return []fixture{f}, nil
		}
	}
	for _, f := range realisticFixtures() {
		if f.Name == name {
			return []fixture{f}, nil
		}
	}
	return nil, fmt.Errorf("unknown fixture %q", name)
}

func generatedNormal(target int) string {
	line := "package scratchpad\n\nfunc generatedLine() { return \"ordinary source text\" }\n"
	var b strings.Builder
	b.Grow(target)
	for b.Len() < target {
		b.WriteString(line)
	}
	return b.String()[:target]
}

func generatedUnicode(target int) string {
	return generatedUnicodeMixed(target)
}

func realisticFixtures() []fixture {
	return []fixture{
		{Name: "source-mixed-100k", Text: generatedSourceMixed(100 << 10)},
		{Name: "source-mixed-1m", Text: generatedSourceMixed(1 << 20)},
		{Name: "source-mixed-10m", Text: generatedSourceMixed(10 << 20)},
		{Name: "prose-mixed-1m", Text: generatedProseMixed(1 << 20)},
		{Name: "data-mixed-1m", Text: generatedDataMixed(1 << 20)},
		{Name: "unicode-mixed-1m", Text: generatedUnicodeMixed(1 << 20)},
	}
}

func generatedUnicodeMixed(target int) string {
	lines := []string{
		"// 日本語 e\u0301 café 👩‍💻 — مرحبا — नमस्ते\n",
		"説明: ordinary Latin prose mixed with CJK and العربية.\n",
		"עברית — русский — Ελληνικά — हिन्दी — português.\n",
	}
	var b strings.Builder
	b.Grow(target + len(lines[0]))
	for i := 0; b.Len() < target; i++ {
		b.WriteString(lines[i%len(lines)])
	}
	text := b.String()
	for len(text) > target && !utf8.ValidString(text[:target]) {
		target--
	}
	return text[:target]
}

func generatedSourceMixed(target int) string {
	lines := []string{
		"package generated\n\n",
		"import (\n\t\"fmt\"\n\t\"strings\"\n)\n\n",
		"// This comment varies the source-like workload and its line lengths.\n",
		"func parseRecord(input string, limit int) (string, error) {\n",
		"\tif strings.TrimSpace(input) == \"\" { return \"\", fmt.Errorf(\"empty record\") }\n",
		"\treturn input, nil\n}\n\n",
		"type Record struct { Name string; Count int; Enabled bool }\n\n",
	}
	var b strings.Builder
	b.Grow(target)
	for i := 0; b.Len() < target; i++ {
		b.WriteString(lines[i%len(lines)])
		if i%11 == 0 {
			b.WriteString("\t// varied identifier record_abcdefghijklmnopqrstuvwxyz\n")
		}
	}
	return b.String()[:target]
}

func generatedProseMixed(target int) string {
	paragraphs := []string{
		"# Project notes\n\nScratchpad keeps ordinary files authoritative while making a calm continuous writing surface. This paragraph intentionally has varied prose length.\n\n",
		"## Tasks\n\n- [ ] Review the saved revision\n- [x] Measure visible rows\n- [ ] Revisit the long line window\n\n",
		"A useful reference is https://example.invalid/notes, and this text includes café, 日本語, مرحبا, and 👩‍💻 without interpreting any Markdown semantics.\n\n",
		"```text\nplain fenced content remains just fixture text\nline two\n```\n\n",
	}
	var b strings.Builder
	b.Grow(target)
	for i := 0; b.Len() < target; i++ {
		b.WriteString(paragraphs[i%len(paragraphs)])
	}
	text := b.String()
	for len(text) > target && !utf8.ValidString(text[:target]) {
		target--
	}
	return text[:target]
}

func generatedDataMixed(target int) string {
	lines := []string{
		`{"timestamp":"2026-08-28T12:34:56Z","level":"info","message":"opened workspace","count":12}` + "\n",
		`{"config":{"enabled":true,"paths":["notes","src"],"limit":1048576},"tags":["local","plain-text"]}` + "\n",
		`2026-08-28T12:35:01Z WARN worker=search duration_ms=184 result_count=27` + "\n",
		`{"nested":{"record":{"name":"varied-value","numbers":[1,3,5,8,13]}}}` + "\n",
	}
	var b strings.Builder
	b.Grow(target)
	for i := 0; b.Len() < target; i++ {
		b.WriteString(lines[i%len(lines)])
	}
	return b.String()[:target]
}

func setOperationFilter(spec string) {
	operationFilter = make(map[string]bool)
	for _, operation := range strings.Split(spec, ",") {
		operation = strings.TrimSpace(operation)
		if operation != "" {
			operationFilter[operation] = true
		}
	}
	if len(operationFilter) == 0 {
		operationFilter["all"] = true
	}
}

func shouldRun(operation string) bool {
	return operationFilter["all"] || operationFilter[operation]
}

func runFixture(f fixture) []measurement {
	currentFixture = f.Name
	results := make([]measurement, 0, 20)

	if shouldRun("first-paint") {
		resetSession(f.Text)
		results = append(results, measure("first-paint", frameInput{}))
		settleFocus()
	}

	for _, position := range []struct {
		name  string
		runes int
	}{
		{name: "start", runes: 0},
		{name: "middle", runes: utf8.RuneCountInString(f.Text) / 2},
		{name: "end", runes: utf8.RuneCountInString(f.Text)},
	} {
		insertOperation := "insert-" + position.name
		if shouldRun(insertOperation) {
			resetSession(f.Text)
			settleFocus()
			setCursor(position.runes)
			results = append(results, measure(insertOperation, frameInput{Text: "x"}))
		}

		backspaceOperation := "backspace-" + position.name
		if shouldRun(backspaceOperation) {
			resetSession(f.Text)
			settleFocus()
			setCursor(position.runes)
			results = append(results, measure(backspaceOperation, frameInput{Key: KeyDeleteBackward}))
		}
	}

	if shouldRun("paste-100k") {
		resetSession(f.Text)
		settleFocus()
		setCursor(utf8.RuneCountInString(f.Text) / 2)
		results = append(results, measure("paste-100k", frameInput{Text: strings.Repeat("P", 100<<10)}))
	}

	if shouldRun("edit-for-undo") || shouldRun("undo") || shouldRun("redo") {
		resetSession(f.Text)
		settleFocus()
		setCursor(utf8.RuneCountInString(f.Text) / 2)
		if shouldRun("edit-for-undo") {
			results = append(results, measure("edit-for-undo", frameInput{Text: "x"}))
		} else {
			GetFrameInput().Text = "x"
			RunFrameFn(rootView)
		}
		if shouldRun("undo") {
			results = append(results, measure("undo", frameInput{Key: KeyZ, Mods: PrimaryMod()}))
		} else {
			GetFrameInput().Key = KeyZ
			GetInputState().Modifiers = PrimaryMod()
			RunFrameFn(rootView)
		}
		if shouldRun("redo") {
			results = append(results, measure("redo", frameInput{Key: KeyZ, Mods: PrimaryMod() | ModShift}))
		}
	}

	if shouldRun("selection") || shouldRun("selection-visible") {
		resetSession(f.Text)
		settleFocus()
		if shouldRun("selection") {
			results = append(results, measure("selection", frameInput{}))
		}
		setSelection(0, min(100, utf8.RuneCountInString(f.Text)))
		if shouldRun("selection-visible") {
			results = append(results, measure("selection-visible", frameInput{}))
		}
	}

	if shouldRun("scroll-top-bottom") || shouldRun("scroll-bottom-top") {
		resetSession(f.Text)
		settleFocus()
		if shouldRun("scroll-top-bottom") {
			results = append(results, measure("scroll-top-bottom", frameInput{Scroll: Vec2{0, 1 << 20}}))
		}
		if shouldRun("scroll-bottom-top") {
			results = append(results, measure("scroll-bottom-top", frameInput{Scroll: Vec2{0, -1 << 20}}))
		}
	}

	if shouldRun("resize") {
		resetSession(f.Text)
		settleFocus()
		windowSize = Vec2{800, 600}
		results = append(results, measure("resize", frameInput{}))
	}
	windowSize = Vec2{windowWidth, windowHeight}
	return results
}

func resetSession(text string) {
	ResetInputSession()
	GetHost().HeadlessRender = true
	GetHost().WindowFocused = true
	GetHost().WindowSize = windowSize
	GetHost().WindowScale = 1
	GetHost().GlyphCacheBudgetBytes = 16 << 20
	buffer = text
	sessionKey = new(int)
	fieldID = nil
	RunFrameFn(rootView)
}

func settleFocus() {
	RunFrameFn(rootView)
	RunFrameFn(rootView)
}

func setCursor(cursor int) {
	EditorSetCursor(fieldID, cursor)
	RunFrameFn(rootView)
}

func setSelection(from, to int) {
	EditorSetSelection(fieldID, from, to)
	RunFrameFn(rootView)
}

func measure(operation string, input frameInput) measurement {
	runtime.GC()
	var before runtime.MemStats
	runtime.ReadMemStats(&before)

	GetFrameInput().Text = input.Text
	GetFrameInput().Key = input.Key
	GetInputState().Modifiers = input.Mods
	GetFrameInput().Scroll = input.Scroll
	start := time.Now()
	out := RunFrameFn(rootView)
	if softwareRender {
		var renderer SoftRenderer
		renderer.Render(out.Surfaces, int(windowSize[0]), int(windowSize[1]), 1)
	}
	wall := time.Since(start)

	var after runtime.MemStats
	runtime.ReadMemStats(&after)
	return measurement{
		Fixture:       currentFixture,
		DocumentBytes: len(buffer),
		Operation:     operation,
		Wall:          wall,
		Allocs:        after.Mallocs - before.Mallocs,
		AllocBytes:    after.TotalAlloc - before.TotalAlloc,
		HeapBefore:    before.HeapAlloc,
		HeapAfter:     after.HeapAlloc,
	}
}

func rootView() {
	ContainerWithKey(sessionKey, Attrs(Viewport, Background(220, 12, 96, 1), Pad(16), Gap(8)), func() {
		Label("Scratchpad Gate B — Shirei TextArea", FontWeight(WeightBold), FontSize(16))
		Label(fmt.Sprintf("fixture=%s bytes=%d", currentFixture, len(buffer)), FontSize(12))
		TextArea(&buffer)
		fieldID = GetLastId()
	})
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
