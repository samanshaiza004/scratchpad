package backend

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"scratchpad/application"
	"scratchpad/document"
	"scratchpad/language/markdown"
)

func TestVisibleSliceV2AppendsBoundedRevisionTaggedPresentation(t *testing.T) {
	source := []byte("# Heading\n\n> **quote**\n")
	doc := document.New("note.md", source, "markdown")
	projection := markdown.Project(source, doc.Revision())
	if !doc.SetDerived(nil, projection) {
		t.Fatal("could not publish Markdown projection")
	}
	windowStart := 2
	window := source[windowStart:]
	revision, ready, wasTruncated, spans, blocks := windowPresentation(doc, windowStart, window)
	if !ready || wasTruncated || revision != doc.Revision() || len(spans) == 0 || len(blocks) == 0 {
		t.Fatalf("window presentation: revision=%d ready=%v truncated=%v spans=%d blocks=%d", revision, ready, wasTruncated, len(spans), len(blocks))
	}
	for _, record := range append(append([]presentationWireRecord(nil), spans...), blocks...) {
		if record.start >= record.end || uint64(record.end) > uint64(len(window)) {
			t.Fatalf("record escaped visible source window: %+v len=%d", record, len(window))
		}
	}
	payload, err := encodeVisibleSliceV2(7, doc.Revision(), 0, 4, false, window, revision, ready, wasTruncated, spans, blocks)
	if err != nil {
		t.Fatal(err)
	}
	if string(payload[:4]) != "SPVS" || binary.LittleEndian.Uint32(payload[4:8]) != VisibleSliceSchemaV2 ||
		binary.LittleEndian.Uint32(payload[44:48]) != uint32(len(window)) {
		t.Fatalf("SPVS2 header mismatch: magic=%q schema=%d source_len=%d", payload[:4], binary.LittleEndian.Uint32(payload[4:8]), binary.LittleEndian.Uint32(payload[44:48]))
	}
	trailer := payload[visibleSliceHeaderBytes+len(window):]
	if binary.LittleEndian.Uint64(trailer[:8]) != revision || binary.LittleEndian.Uint32(trailer[8:12]) != presentationReadyFlag ||
		binary.LittleEndian.Uint32(trailer[12:16]) != uint32(len(spans)) || binary.LittleEndian.Uint32(trailer[16:20]) != uint32(len(blocks)) ||
		binary.LittleEndian.Uint32(trailer[20:24]) != 0 {
		t.Fatalf("SPVS2 metadata header mismatch: %v", trailer[:presentationTrailerHeaderBytes])
	}
	if len(payload) != visibleSliceHeaderBytes+len(window)+presentationTrailerHeaderBytes+(len(spans)+len(blocks))*presentationRecordBytes {
		t.Fatalf("SPVS2 total size mismatch: %d", len(payload))
	}
}

func TestWindowPresentationIsExactRevisionAndRecordCapped(t *testing.T) {
	source := []byte("**x**")
	doc := document.New("note.md", source, "markdown")
	spans := make([]document.PresentationSpan, MaxPresentationRecords+4)
	for i := range spans {
		spans[i] = document.PresentationSpan{StartByte: 0, EndByte: 5, Kind: document.PresentationStrong}
	}
	projection := document.Projections{
		Revision: doc.Revision(),
		Markdown: document.NewMarkdownPresentation(doc.Revision(), spans),
	}
	if !doc.SetDerived(nil, projection) {
		t.Fatal("could not publish dense test projection")
	}
	revision, ready, truncated, gotSpans, gotBlocks := windowPresentation(doc, 0, source)
	if revision != doc.Revision() || !ready || !truncated || len(gotSpans) != MaxPresentationRecords || len(gotBlocks) != 0 {
		t.Fatalf("dense metadata: revision=%d ready=%v truncated=%v spans=%d blocks=%d", revision, ready, truncated, len(gotSpans), len(gotBlocks))
	}
	if err := doc.Replace(0, 0, []byte("!")); err != nil {
		t.Fatal(err)
	}
	_, ready, truncated, gotSpans, gotBlocks = windowPresentation(doc, 0, source)
	if ready || truncated || len(gotSpans) != 0 || len(gotBlocks) != 0 {
		t.Fatalf("stale projection leaked metadata: ready=%v truncated=%v spans=%d blocks=%d", ready, truncated, len(gotSpans), len(gotBlocks))
	}
}

func TestWindowPresentationForNonMarkdownIsEmptyAndReady(t *testing.T) {
	doc := document.New("main.go", []byte("package main"), "go")
	_, ready, truncated, spans, blocks := windowPresentation(doc, 0, []byte("package main"))
	if !ready || truncated || len(spans) != 0 || len(blocks) != 0 {
		t.Fatalf("non-Markdown presentation = ready:%v truncated:%v spans:%d blocks:%d", ready, truncated, len(spans), len(blocks))
	}
}

func TestWindowPresentationClipsLongLineAnchoredChunk(t *testing.T) {
	source := bytes.Repeat([]byte("x"), 200000)
	doc := document.New("long.md", source, "markdown")
	projection := document.Projections{
		Revision: doc.Revision(),
		Markdown: document.NewMarkdownPresentation(doc.Revision(), []document.PresentationSpan{
			{StartByte: 0, EndByte: len(source), Kind: document.PresentationInlineCode},
			{StartByte: 150000, EndByte: 150010, Kind: document.PresentationStrong},
		}),
		Blocks: []document.BlockPresentation{{Kind: document.BlockQuote, StartByte: 0, EndByte: len(source)}},
	}
	projection.IndexBlocks()
	if !doc.SetDerived(nil, projection) {
		t.Fatal("could not publish long-line projection")
	}
	start, end := 100000, 116384
	window := source[start:end]
	revision, ready, truncated, spans, blocks := windowPresentation(doc, start, window)
	if !ready || truncated || revision != doc.Revision() || len(spans) != 1 || len(blocks) != 1 {
		t.Fatalf("anchored chunk metadata: revision=%d ready=%v truncated=%v spans=%d blocks=%d", revision, ready, truncated, len(spans), len(blocks))
	}
	if spans[0].start != 0 || spans[0].end != uint32(len(window)) || blocks[0].start != 0 || blocks[0].end != uint32(len(window)) ||
		blocks[0].levelFlags&(blockClippedStartFlag|blockClippedEndFlag) != blockClippedStartFlag|blockClippedEndFlag {
		t.Fatalf("long-line metadata was not clipped: span=%+v block=%+v", spans[0], blocks[0])
	}
}

func TestStatePresentationReadinessIsOptIn(t *testing.T) {
	snapshot := applicationSnapshotForTest()
	legacy, err := json.Marshal(stateFromApplication(1, snapshot))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(legacy, []byte("presentation_ready")) || bytes.Contains(legacy, []byte("presentation_revision")) {
		t.Fatalf("legacy state includes opt-in presentation fields: %s", legacy)
	}
	optIn, err := json.Marshal(stateFromApplication(1, snapshot, true))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(optIn, []byte(`"presentation_revision"`)) || !bytes.Contains(optIn, []byte(`"presentation_ready":true`)) {
		t.Fatalf("opt-in state omitted readiness: %s", optIn)
	}
}

func TestOptInMarkdownProjectionPublishesReadinessWithoutPumping(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "note.md")
	writeFile(t, path, "# Heading\n\n**bold**\n")
	runtime := newStartedRuntime(t, root)
	defer stopRuntime(t, runtime)

	state := latestStateForTest(t, runtime)
	dispatchForTest(t, runtime, mustJSON(t, CommandRequest{
		Version: ProtocolVersion, RequestID: 210, BasedOnRevision: state.ApplicationRev,
		Command: "open_path", Path: path,
	}))
	opened := decodeResponse(t, runtime.Pump())
	state = latestStateForTest(t, runtime)
	if !opened.OK || len(state.Documents) != 1 || state.Documents[0].PresentationRevision != 0 {
		t.Fatalf("default open unexpectedly enabled presentation state: %+v", state)
	}
	docID := state.Documents[0].ID
	appRevision := state.ApplicationRev
	dispatchForTest(t, runtime, mustJSON(t, CommandRequest{
		Version: ProtocolVersion, RequestID: 211, BasedOnRevision: appRevision,
		Command: "read_visible_lines", DocumentID: docID, StartLine: 0,
		MaxLines: 16, MaxBytes: 1024, IncludePresentation: true,
	}))
	pending := decodeResponse(t, runtime.Pump())
	if !pending.OK || pending.Resource == nil || pending.Resource.MetadataByteLen != presentationTrailerHeaderBytes {
		t.Fatalf("first opt-in resource = %+v", pending)
	}
	resource, err := runtime.caliber.readResourceCopy(pending.Resource.ResourceID, pending.Resource.Generation)
	if err != nil {
		t.Fatal(err)
	}
	trailer := resource[visibleSliceHeaderBytes+int(pending.Resource.ByteLen):]
	if binary.LittleEndian.Uint32(trailer[8:12])&presentationReadyFlag != 0 {
		t.Fatal("first opt-in request unexpectedly blocked until parse completed")
	}
	if err := runtime.caliber.releaseResourceOwner(pending.Resource.ResourceID, pending.Resource.Generation); err != nil {
		t.Fatal(err)
	}

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		state = latestStateForTest(t, runtime)
		if len(state.Documents) == 1 && state.Documents[0].PresentationReady {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if len(state.Documents) != 1 || !state.Documents[0].PresentationReady || state.Documents[0].PresentationRevision != state.Documents[0].EditorRevision {
		t.Fatalf("async readiness was not published: %+v", state)
	}
	if state.ApplicationRev != appRevision {
		t.Fatalf("derived publication changed source application revision: %d -> %d", appRevision, state.ApplicationRev)
	}

	dispatchForTest(t, runtime, mustJSON(t, CommandRequest{
		Version: ProtocolVersion, RequestID: 212, BasedOnRevision: state.ApplicationRev,
		Command: "read_visible_lines", DocumentID: docID, StartLine: 0,
		MaxLines: 16, MaxBytes: 1024, IncludePresentation: true,
	}))
	ready := decodeResponse(t, runtime.Pump())
	if !ready.OK || ready.Resource == nil {
		t.Fatalf("ready opt-in resource = %+v", ready)
	}
	resource, err = runtime.caliber.readResourceCopy(ready.Resource.ResourceID, ready.Resource.Generation)
	if err != nil {
		t.Fatal(err)
	}
	trailer = resource[visibleSliceHeaderBytes+int(ready.Resource.ByteLen):]
	if binary.LittleEndian.Uint64(trailer[:8]) != state.Documents[0].EditorRevision || binary.LittleEndian.Uint32(trailer[8:12])&presentationReadyFlag == 0 || binary.LittleEndian.Uint32(trailer[12:16]) == 0 {
		t.Fatalf("ready trailer does not match state: revision=%d flags=%d spans=%d", binary.LittleEndian.Uint64(trailer[:8]), binary.LittleEndian.Uint32(trailer[8:12]), binary.LittleEndian.Uint32(trailer[12:16]))
	}
	if err := runtime.caliber.releaseResourceOwner(ready.Resource.ResourceID, ready.Resource.Generation); err != nil {
		t.Fatal(err)
	}

	oldRevision := state.Documents[0].EditorRevision
	dispatchForTest(t, runtime, mustJSON(t, CommandRequest{
		Version: ProtocolVersion, RequestID: 213, BasedOnRevision: state.ApplicationRev,
		Command: "replace_document", DocumentID: docID, EditorRevision: oldRevision,
		StartByte: 0, EndByte: 0, Replacement: []int{'!'},
	}))
	edited := decodeResponse(t, runtime.Pump())
	state = latestStateForTest(t, runtime)
	if !edited.OK || state.Documents[0].EditorRevision == oldRevision || state.Documents[0].PresentationReady || state.Documents[0].PresentationRevision != state.Documents[0].EditorRevision {
		t.Fatalf("edit did not publish stale/pending readiness: response=%+v state=%+v", edited, state.Documents[0])
	}
}

func TestOldProjectionWakeCannotTouchRestartedRuntime(t *testing.T) {
	runtime := newStartedRuntime(t, "")
	oldApp := runtime.app
	oldGeneration := runtime.generation
	stopRuntime(t, runtime)
	start := decodeResponse(t, runtime.Start(mustJSON(t, StartRequest{Version: ProtocolVersion, RequestID: 214})))
	if !start.OK {
		t.Fatalf("restart failed: %+v", start)
	}
	beforeRevision := runtime.revision
	runtime.handleDerivedWake(oldGeneration, oldApp)
	if runtime.revision != beforeRevision || runtime.app == oldApp || runtime.lifecycle != lifecycleRunning {
		t.Fatalf("stale callback touched restarted runtime: revision=%d appSame=%v lifecycle=%s", runtime.revision, runtime.app == oldApp, runtime.lifecycle)
	}
	stopRuntime(t, runtime)
}

func BenchmarkWindowPresentationLargeMarkdownManyBlocks(b *testing.B) {
	source := []byte(strings.Repeat("> **item**\n\n", 20000))
	doc := document.New("large.md", source, "markdown")
	projection := markdown.Project(source, doc.Revision())
	if !doc.SetDerived(nil, projection) {
		b.Fatal("could not install benchmark projection")
	}
	start := len(source) - MaxVisibleBytes
	if start < 0 {
		start = 0
	}
	window := source[start:]
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, ready, truncated, spans, blocks := windowPresentation(doc, start, window)
		if !ready || len(spans)+len(blocks) > MaxPresentationRecords {
			b.Fatalf("unbounded metadata result: ready=%v truncated=%v spans=%d blocks=%d", ready, truncated, len(spans), len(blocks))
		}
	}
}

func applicationSnapshotForTest() application.PresentationState {
	return application.PresentationState{Documents: []application.PresentationDocument{{
		ID: "doc", Language: "markdown", EditorRevision: 9, PresentationRevision: 9, PresentationReady: true,
	}}}
}
