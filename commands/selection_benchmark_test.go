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
// NewRequest+Execute path. Cases cover caret-to-word, word-to-sentence, and an
// adversarial word inside a sentence extending through the entire document.
func BenchmarkSelectionExpandLargeDocuments(b *testing.B) {
	for _, size := range []int{1 << 20, 10 << 20} {
		b.Run(fmt.Sprintf("%dMiB", size>>20), func(b *testing.B) {
			const longSentencePattern = "word token. "
			longSentenceSource := bytes.Repeat([]byte(longSentencePattern), (size+len(longSentencePattern)-1)/len(longSentencePattern))[:size]
			longSentenceStart := (len(longSentenceSource)/len(longSentencePattern) - 2) * len(longSentencePattern)
			caret := longSentenceStart + len("word ") + 2
			const shortSentencePattern = "Word token. Next phrase. "
			shortSentenceSource := bytes.Repeat([]byte(shortSentencePattern), (size+len(shortSentencePattern)-1)/len(shortSentencePattern))[:size]
			shortSentenceStart := (len(shortSentenceSource)/len(shortSentencePattern) - 1) * len(shortSentencePattern)
			requests := []struct {
				name      string
				source    []byte
				request   Request
				wantStart int
				wantEnd   int
			}{
				{name: "caret", source: longSentenceSource, request: Request{ID: SelectionExpand, Source: longSentenceSource, Anchor: caret, Cursor: caret}, wantStart: longSentenceStart + len("word "), wantEnd: longSentenceStart + len("word token")},
				{name: "word-to-long-sentence", source: longSentenceSource, request: Request{ID: SelectionExpand, Source: longSentenceSource, Anchor: longSentenceStart + len("word "), Cursor: longSentenceStart + len("word token")}, wantEnd: len(longSentenceSource)},
				{name: "word-to-sentence", source: shortSentenceSource, request: Request{ID: SelectionExpand, Source: shortSentenceSource, Anchor: shortSentenceStart + len("Word "), Cursor: shortSentenceStart + len("Word token")}, wantStart: shortSentenceStart, wantEnd: shortSentenceStart + len("Word token.")},
			}
			for _, sample := range requests {
				b.Run("expand-only/"+sample.name, func(b *testing.B) {
					benchmarkSelectionExpansion(b, sample.source, sample, false)
				})
				b.Run("user-action/"+sample.name, func(b *testing.B) {
					benchmarkSelectionExpansion(b, sample.source, sample, true)
				})
			}
		})
	}
}

func benchmarkSelectionExpansion(b *testing.B, source []byte, sample struct {
	name      string
	source    []byte
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
