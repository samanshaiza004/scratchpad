package backend

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	goruntime "runtime"
	"sort"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"scratchpad/application"
)

// Set SCRATCHPAD_SEMANTIC_ZOOM_DIAGNOSTICS=1 to measure the actual bridge
// worker on a million-line prose document. This is intentionally opt-in: it is
// a diagnostic run, not a timing-sensitive CI assertion.
func TestSemanticZoomWorkerDiagnostics(t *testing.T) {
	if os.Getenv("SCRATCHPAD_SEMANTIC_ZOOM_DIAGNOSTICS") != "1" {
		t.Skip("set SCRATCHPAD_SEMANTIC_ZOOM_DIAGNOSTICS=1 to run the large worker diagnostic")
	}

	const (
		paragraphLines = 1000
		paragraphCount = 1000
		sampleCount    = 20
	)
	paragraph := "Opening sentence.\n" + strings.Repeat("Supporting detail.\n", paragraphLines-2) + "\n"
	source := strings.Repeat(paragraph, paragraphCount)
	root := t.TempDir()
	path := filepath.Join(root, "semantic-zoom-diagnostic.txt")
	writeFile(t, path, source)
	runtime := newStartedRuntime(t, root)
	defer stopRuntime(t, runtime)
	dispatchForTest(t, runtime, mustJSON(t, CommandRequest{
		Version: ProtocolVersion, RequestID: 1, Command: "open_path", Path: path,
	}))
	if response := decodeResponse(t, runtime.Pump()); !response.OK {
		t.Fatalf("open diagnostic source: %+v", response)
	}
	state := latestStateForTest(t, runtime)
	id, revision := state.Documents[0].ID, state.Documents[0].EditorRevision

	type workerSample struct {
		started time.Time
		ended   time.Time
		err     error
	}
	workerStarted := make(chan time.Time, 1)
	workerFinished := make(chan workerSample, 1)
	runtime.mu.Lock()
	runtime.semanticZoomBuilder = func(ctx context.Context, snapshot application.SemanticZoomSnapshot) (application.SemanticZoomPlan, error) {
		started := time.Now()
		workerStarted <- started
		plan, err := application.BuildSemanticZoom(ctx, snapshot)
		workerFinished <- workerSample{started: started, ended: time.Now(), err: err}
		return plan, err
	}
	runtime.mu.Unlock()

	var baseline goruntime.MemStats
	goruntime.ReadMemStats(&baseline)
	var peakHeapAlloc, peakHeapInuse atomic.Uint64
	peakHeapAlloc.Store(baseline.HeapAlloc)
	peakHeapInuse.Store(baseline.HeapInuse)
	stopSampling, samplingDone := make(chan struct{}), make(chan struct{})
	go func() {
		defer close(samplingDone)
		ticker := time.NewTicker(2 * time.Millisecond)
		defer ticker.Stop()
		var stats goruntime.MemStats
		for {
			select {
			case <-stopSampling:
				return
			case <-ticker.C:
				goruntime.ReadMemStats(&stats)
				atomicMax(&peakHeapAlloc, stats.HeapAlloc)
				atomicMax(&peakHeapInuse, stats.HeapInuse)
			}
		}
	}()
	defer func() {
		close(stopSampling)
		<-samplingDone
	}()

	requestToReady := make([]time.Duration, 0, sampleCount)
	workerBuild := make([]time.Duration, 0, sampleCount)
	for i := 0; i < sampleCount; i++ {
		depth := application.SemanticZoomFocus + i%3
		requestStarted := time.Now()
		pending := semanticZoomBridgeRead(t, runtime, id, revision, depth, uint64(len(source)/2))
		if !pending.OK || pending.SemanticZoom == nil || pending.SemanticZoom.Ready || pending.SemanticZoom.Generation == 0 {
			t.Fatalf("sample %d did not enter the background worker: %+v", i, pending)
		}
		select {
		case <-workerStarted:
		case <-time.After(5 * time.Second):
			t.Fatalf("sample %d worker did not start", i)
		}
		var sample workerSample
		select {
		case sample = <-workerFinished:
		case <-time.After(10 * time.Second):
			t.Fatalf("sample %d worker did not finish", i)
		}
		if sample.err != nil {
			t.Fatalf("sample %d worker failed: %v", i, sample.err)
		}
		waitSemanticZoomDiagnosticDone(t, runtime, pending.SemanticZoom.Generation)
		requestToReady = append(requestToReady, time.Since(requestStarted))
		workerBuild = append(workerBuild, sample.ended.Sub(sample.started))
	}

	var cancelLatency, cancelAck time.Duration
	for attempt := 0; attempt < 3 && cancelLatency == 0; attempt++ {
		pending := semanticZoomBridgeRead(t, runtime, id, revision, application.SemanticZoomOverview, uint64(len(source)/2))
		if !pending.OK || pending.SemanticZoom == nil || pending.SemanticZoom.Ready || pending.SemanticZoom.Generation == 0 {
			t.Fatalf("cancellation attempt %d did not enter the background worker: %+v", attempt, pending)
		}
		select {
		case <-workerStarted:
		case <-time.After(5 * time.Second):
			t.Fatal("cancellation worker did not start")
		}
		cancelStarted := time.Now()
		dispatchForTest(t, runtime, mustJSON(t, CommandRequest{
			Version: ProtocolVersion, RequestID: uint64(100 + attempt),
			Command: "cancel_semantic_zoom", SemanticZoomGeneration: pending.SemanticZoom.Generation,
		}))
		if response := decodeResponse(t, runtime.Pump()); !response.OK {
			t.Fatalf("cancel generation: %+v", response)
		}
		cancelAck = time.Since(cancelStarted)
		select {
		case sample := <-workerFinished:
			if errors.Is(sample.err, application.ErrSemanticZoomCanceled) {
				cancelLatency = sample.ended.Sub(cancelStarted)
			}
		case <-time.After(10 * time.Second):
			t.Fatal("canceled worker did not stop")
		}
	}
	if cancelLatency == 0 {
		t.Log("cancellation latency unavailable: all attempts completed before cancellation took effect")
	}

	t.Logf("SEMANTIC_ZOOM_DIAGNOSTIC fixture_lines=%d fixture_bytes=%d samples=%d request_to_ready_p50_ms=%.3f request_to_ready_p95_ms=%.3f worker_build_p50_ms=%.3f worker_build_p95_ms=%.3f cancel_ack_ms=%.3f cancel_to_worker_exit_ms=%.3f heap_alloc_baseline_mb=%.2f heap_alloc_peak_mb=%.2f heap_inuse_baseline_mb=%.2f heap_inuse_peak_mb=%.2f",
		paragraphLines*paragraphCount, len(source), sampleCount,
		durationMilliseconds(percentileDuration(requestToReady, 50)),
		durationMilliseconds(percentileDuration(requestToReady, 95)),
		durationMilliseconds(percentileDuration(workerBuild, 50)),
		durationMilliseconds(percentileDuration(workerBuild, 95)),
		durationMilliseconds(cancelAck), durationMilliseconds(cancelLatency),
		float64(baseline.HeapAlloc)/(1<<20), float64(peakHeapAlloc.Load())/(1<<20),
		float64(baseline.HeapInuse)/(1<<20), float64(peakHeapInuse.Load())/(1<<20))
}

func waitSemanticZoomDiagnosticDone(t *testing.T, runtime *Runtime, generation uint64) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		runtime.mu.Lock()
		done := runtime.semanticZoom != nil && runtime.semanticZoom.generation == generation && runtime.semanticZoom.done
		runtime.mu.Unlock()
		if done {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("semantic zoom generation %d did not publish", generation)
}

func percentileDuration(values []time.Duration, percentile int) time.Duration {
	ordered := append([]time.Duration(nil), values...)
	sort.Slice(ordered, func(i, j int) bool { return ordered[i] < ordered[j] })
	index := (percentile*len(ordered)+99)/100 - 1
	if index < 0 {
		index = 0
	}
	if index >= len(ordered) {
		index = len(ordered) - 1
	}
	return ordered[index]
}

func durationMilliseconds(value time.Duration) float64 {
	return float64(value) / float64(time.Millisecond)
}

func atomicMax(destination *atomic.Uint64, value uint64) {
	for current := destination.Load(); value > current; current = destination.Load() {
		if destination.CompareAndSwap(current, value) {
			return
		}
	}
}
