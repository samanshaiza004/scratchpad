package commands

import (
	"bytes"
	"fmt"
	"runtime"
	"sort"
	"testing"
	"time"

	"scratchpad/document"
)

// BenchmarkSelectionExpandLargeDocuments reports repeated-sample p95 and
// allocation metrics for both the isolated expansion and the production
// NewRequest+Execute path. The caret is near the end of each ASCII document to
// stress the old whole-file segmentation path; the word case then expands into
// the fixture's long sentence.
func BenchmarkSelectionExpandLargeDocuments(b *testing.B) {
	for _, size := range []int{1 << 20, 10 << 20} {
		b.Run(fmt.Sprintf("%dMiB", size>>20), func(b *testing.B) {
			const pattern = "word token. "
			source := bytes.Repeat([]byte(pattern), (size+len(pattern)-1)/len(pattern))[:size]
			patternStart := (len(source)/len(pattern) - 2) * len(pattern)
			caret := patternStart + len("word ") + 2
			requests := []struct {
				name      string
				request   Request
				wantStart int
				wantEnd   int
			}{
				{name: "caret", request: Request{ID: SelectionExpand, Source: source, Anchor: caret, Cursor: caret}, wantStart: patternStart + len("word "), wantEnd: patternStart + len("word token")},
				{name: "word", request: Request{ID: SelectionExpand, Source: source, Anchor: patternStart + len("word "), Cursor: patternStart + len("word token")}, wantEnd: len(source)},
			}
			for _, sample := range requests {
				b.Run("expand-only/"+sample.name, func(b *testing.B) {
					benchmarkSelectionExpansion(b, source, sample, false)
				})
				b.Run("user-action/"+sample.name, func(b *testing.B) {
					benchmarkSelectionExpansion(b, source, sample, true)
				})
			}
		})
	}
}

func benchmarkSelectionExpansion(b *testing.B, source []byte, sample struct {
	name      string
	request   Request
	wantStart int
	wantEnd   int
}, includeRequestSnapshot bool) {
	const sampleCount = 20
	latencies := make([]time.Duration, 0, sampleCount)
	var allocatedBytes, allocatedObjects uint64
	b.StopTimer()
	var doc *document.Document
	if includeRequestSnapshot {
		doc = document.New("", source, "")
		doc.Editor.Anchor, doc.Editor.Cursor = sample.request.Anchor, sample.request.Cursor
	}
	for i := 0; i < sampleCount; i++ {
		var before, after runtime.MemStats
		runtime.ReadMemStats(&before)
		b.StartTimer()
		started := time.Now()
		var outcome Outcome
		if includeRequestSnapshot {
			request, err := NewRequest(doc, SelectionExpand)
			if err != nil {
				b.Fatalf("create request: %v", err)
			}
			outcome = Execute(request)
		} else {
			outcome = expandSelection(sample.request)
		}
		latencies = append(latencies, time.Since(started))
		b.StopTimer()
		runtime.ReadMemStats(&after)
		allocatedBytes += after.TotalAlloc - before.TotalAlloc
		allocatedObjects += after.Mallocs - before.Mallocs
		if outcome.Status != ResultExecuted || outcome.Anchor != sample.wantStart || outcome.Cursor != sample.wantEnd {
			b.Fatalf("unexpected expansion: %+v, want [%d, %d)", outcome, sample.wantStart, sample.wantEnd)
		}
	}

	sort.Slice(latencies, func(i, j int) bool { return latencies[i] < latencies[j] })
	p95Index := (95*len(latencies)+99)/100 - 1
	b.ReportMetric(float64(latencies[p95Index].Nanoseconds()), "p95-ns/expand")
	b.ReportMetric(float64(allocatedBytes)/sampleCount, "alloc-B/expand")
	b.ReportMetric(float64(allocatedObjects)/sampleCount, "allocs/expand")
	b.ReportMetric(float64(sampleCount), "samples")
}
