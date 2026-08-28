// fragmentbench measures the simple piece sequence after long edit sessions.
// It exists to decide whether the Gate B proof needs a balanced tree; it is
// not a claim that the current piece sequence is the final buffer.
package main

import (
	"flag"
	"fmt"
	"math/rand"
	"os"
	"runtime"
	"strings"
	"time"

	"scratchpad/editor"
)

type measurement struct {
	Edits       int
	Operation   string
	Wall        time.Duration
	Allocs      uint64
	AllocBytes  uint64
	HeapBefore  uint64
	HeapAfter   uint64
	PieceCount  int
	DocumentLen int
}

func main() {
	editCounts := flag.Int("edits", 10000, "number of random edits (run separately with 100000)")
	flag.Parse()
	if *editCounts < 1 {
		fmt.Fprintln(os.Stderr, "-edits must be positive")
		os.Exit(2)
	}

	source := []byte(normal(10 << 20))
	b := editor.NewBuffer(source)
	rng := rand.New(rand.NewSource(0x53435241544348))

	fmt.Println("edits\toperation\twall_ms\tallocs\talloc_bytes\theap_before\theap_after\tpieces\tdocument_bytes")
	printMeasurement(torture(&b, rng, *editCounts))
	printMeasurement(lookup(&b, *editCounts))
	for _, position := range []struct {
		name string
		frac float64
	}{
		{name: "edit-start", frac: 0},
		{name: "edit-middle", frac: 0.5},
		{name: "edit-end", frac: 1},
	} {
		printMeasurement(localizedEdits(&b, *editCounts, position.name, position.frac))
	}
	printMeasurement(scrolling(&b, *editCounts))
}

func printMeasurement(r measurement) {
	fmt.Printf("%d\t%s\t%.3f\t%d\t%d\t%d\t%d\t%d\t%d\n",
		r.Edits, r.Operation, float64(r.Wall)/float64(time.Millisecond), r.Allocs,
		r.AllocBytes, r.HeapBefore, r.HeapAfter, r.PieceCount, r.DocumentLen)
}

func normal(target int) string {
	line := "package scratchpad\n\nfunc generatedLine() { return \"ordinary source text\" }\n"
	var b strings.Builder
	b.Grow(target)
	for b.Len() < target {
		b.WriteString(line)
	}
	return b.String()[:target]
}

func torture(b *editor.Buffer, rng *rand.Rand, edits int) measurement {
	startMeasurement := beginMeasurement()
	start := time.Now()
	for i := 0; i < edits; i++ {
		at := rng.Intn(b.ByteLen() + 1)
		if i%3 == 0 || b.ByteLen() == 0 {
			_ = b.Insert(at, []byte("x"))
		} else {
			if at == b.ByteLen() {
				at--
			}
			_ = b.Delete(at, at+1)
		}
		if (i+1)%10000 == 0 {
			fmt.Fprintf(os.Stderr, "random edits: %d/%d pieces=%d elapsed=%s\n", i+1, edits, b.PieceCount(), time.Since(start).Round(time.Millisecond))
		}
	}
	return finishMeasurement(startMeasurement, time.Since(start), b, fmt.Sprintf("random-%d", edits), edits)
}

func lookup(b *editor.Buffer, edits int) measurement {
	startMeasurement := beginMeasurement()
	start := time.Now()
	lines := b.LineCount()
	for i := 0; i < edits; i++ {
		line := (i * 7919) % lines
		_, _ = b.Line(line)
	}
	return finishMeasurement(startMeasurement, time.Since(start), b, "line-lookup", edits)
}

func localizedEdits(b *editor.Buffer, edits int, name string, fraction float64) measurement {
	startMeasurement := beginMeasurement()
	start := time.Now()
	for i := 0; i < edits; i++ {
		at := int(float64(b.ByteLen()) * fraction)
		if at >= b.ByteLen() {
			at = b.ByteLen() - 1
		}
		_ = b.Insert(at, []byte("y"))
		_ = b.Delete(at, at+1)
	}
	return finishMeasurement(startMeasurement, time.Since(start), b, name, edits)
}

func scrolling(b *editor.Buffer, edits int) measurement {
	startMeasurement := beginMeasurement()
	start := time.Now()
	lines := b.LineCount()
	for i := 0; i < edits; i++ {
		base := []int{0, lines / 2, lines - 1}[i%3]
		for row := 0; row < 30; row++ {
			line := base + row
			if line >= lines {
				line = lines - 1
			}
			_, _ = b.Line(line)
		}
	}
	return finishMeasurement(startMeasurement, time.Since(start), b, "scroll-visible-rows", edits)
}

type memoryMeasurement struct {
	heap, mallocs, totalAlloc uint64
}

func beginMeasurement() memoryMeasurement {
	runtime.GC()
	var m runtime.MemStats
	runtime.ReadMemStats(&m)
	return memoryMeasurement{heap: m.HeapAlloc, mallocs: m.Mallocs, totalAlloc: m.TotalAlloc}
}

func finishMeasurement(before memoryMeasurement, wall time.Duration, b *editor.Buffer, operation string, edits int) measurement {
	var after runtime.MemStats
	runtime.ReadMemStats(&after)
	return measurement{
		Edits: edits, Operation: operation, Wall: wall,
		Allocs: after.Mallocs - before.mallocs, AllocBytes: after.TotalAlloc - before.totalAlloc,
		HeapBefore: before.heap, HeapAfter: after.HeapAlloc,
		PieceCount: b.PieceCount(), DocumentLen: b.ByteLen(),
	}
}
