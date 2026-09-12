package backend

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"unsafe"

	"scratchpad/application"
)

func TestLifecycleDeterminism(t *testing.T) {
	runtime := newStartedRuntime(t, "")

	startAgain := decodeResponse(t, runtime.Start(mustJSON(t, StartRequest{
		Version:   ProtocolVersion,
		RequestID: 2,
	})))
	if startAgain.OK || startAgain.Outcome.Code != "already_running" || startAgain.Lifecycle != lifecycleRunning {
		t.Fatalf("double start response = %+v", startAgain)
	}

	if runtime.CaliberAPIPointer() == nil || runtime.CaliberContextPointer() == nil {
		t.Fatal("running backend did not expose Caliber API/context pointers")
	}
	lease, err := runtime.AcquireLatestState()
	if err != nil {
		t.Fatalf("acquire state: %v", err)
	}
	if lease.Len == 0 || lease.Data == nil {
		t.Fatalf("empty state lease = %+v", lease)
	}
	leasedBytes := unsafe.Slice((*byte)(lease.Data), int(lease.Len))

	stoppedWithLease := decodeResponse(t, runtime.Stop(mustJSON(t, StopRequest{
		Version:   ProtocolVersion,
		RequestID: 3,
	})))
	if stoppedWithLease.OK || stoppedWithLease.Outcome.Code != "outstanding_state_leases" || stoppedWithLease.Lifecycle != lifecycleRunning {
		t.Fatalf("stop with lease response = %+v", stoppedWithLease)
	}
	if !bytes.Contains(leasedBytes, []byte(`"schema":1`)) {
		t.Fatalf("lease bytes not readable while stop is refused: %q", string(leasedBytes))
	}
	if err := runtime.ReleaseState(&lease); err != nil {
		t.Fatalf("release state: %v", err)
	}
	stopped := decodeResponse(t, runtime.Stop(mustJSON(t, StopRequest{
		Version:   ProtocolVersion,
		RequestID: 14,
	})))
	if !stopped.OK || stopped.Lifecycle != lifecycleStopped {
		t.Fatalf("stop after releasing lease response = %+v", stopped)
	}

	stoppedAgain := decodeResponse(t, runtime.Stop(mustJSON(t, StopRequest{
		Version:   ProtocolVersion,
		RequestID: 4,
	})))
	if stoppedAgain.OK || stoppedAgain.Outcome.Code != "already_stopped" || stoppedAgain.Lifecycle != lifecycleStopped {
		t.Fatalf("double stop response = %+v", stoppedAgain)
	}

	afterStop := decodeResponse(t, runtime.Pump())
	if afterStop.OK || afterStop.Outcome.Code != "not_running" || afterStop.Lifecycle != lifecycleStopped {
		t.Fatalf("call after stop response = %+v", afterStop)
	}
}

func TestLinkedCaliberAPIPointerSurvivesRestart(t *testing.T) {
	runtime := newStartedRuntime(t, "")
	firstAPI := runtime.CaliberAPIPointer()
	firstContext := runtime.CaliberContextPointer()
	if firstAPI == nil || firstContext == nil {
		t.Fatalf("missing Caliber pointers: api=%p context=%p", firstAPI, firstContext)
	}
	stopRuntime(t, runtime)
	if runtime.CaliberAPIPointer() != nil || runtime.CaliberContextPointer() != nil {
		t.Fatal("stopped backend still exposes Caliber pointers")
	}
	restarted := decodeResponse(t, runtime.Start(mustJSON(t, StartRequest{
		Version:   ProtocolVersion,
		RequestID: 5,
	})))
	if !restarted.OK {
		t.Fatalf("restart response = %+v", restarted)
	}
	defer stopRuntime(t, runtime)
	if secondAPI := runtime.CaliberAPIPointer(); secondAPI != firstAPI {
		t.Fatalf("Caliber API pointer changed across restart: %p -> %p", firstAPI, secondAPI)
	}
	if secondContext := runtime.CaliberContextPointer(); secondContext == nil {
		t.Fatalf("Caliber context was not recreated after previous context %p", firstContext)
	}
}

func TestLeaseAccountingRejectsCallAfterRelease(t *testing.T) {
	runtime := newStartedRuntime(t, "")
	defer stopRuntime(t, runtime)
	lease, err := runtime.AcquireLatestState()
	if err != nil {
		t.Fatalf("acquire state: %v", err)
	}
	if err := runtime.ReleaseState(&lease); err != nil {
		t.Fatalf("release state: %v", err)
	}
	if err := runtime.ReleaseState(&lease); err == nil {
		t.Fatal("double state release was accepted")
	}
	if err := runtime.NoteStateLeaseReleased(); err == nil {
		t.Fatal("double lease release was accepted")
	}
}

func TestResourceLeaseAccountingRejectsShutdownAndDoubleRelease(t *testing.T) {
	runtime := newStartedRuntime(t, "")
	resourceID, generation, err := runtime.caliber.publishResource([]byte("resource"))
	if err != nil {
		t.Fatalf("publish resource: %v", err)
	}
	if err := runtime.NoteResourceLeaseAcquired(); err != nil {
		t.Fatalf("acquire resource lease: %v", err)
	}
	refused := decodeResponse(t, runtime.Stop(mustJSON(t, StopRequest{
		Version:   ProtocolVersion,
		RequestID: 17,
	})))
	if refused.OK || refused.Outcome.Code != "outstanding_resource_leases" || refused.Lifecycle != lifecycleRunning {
		t.Fatalf("stop with resource lease response = %+v", refused)
	}
	if err := runtime.NoteResourceLeaseReleased(); err != nil {
		t.Fatalf("release resource lease: %v", err)
	}
	if err := runtime.NoteResourceLeaseReleased(); err == nil {
		t.Fatal("double resource lease release was accepted")
	}
	if err := runtime.caliber.releaseResourceOwner(resourceID, generation); err != nil {
		t.Fatalf("release resource owner: %v", err)
	}
	stopRuntime(t, runtime)
}

func TestRequestIDsAreNumericAndCorrelated(t *testing.T) {
	runtime := newStartedRuntime(t, "")
	defer stopRuntime(t, runtime)
	request := CommandRequest{Version: ProtocolVersion, RequestID: 42, Command: "snapshot"}
	dispatchForTest(t, runtime, mustJSON(t, request))
	response := decodeResponse(t, runtime.Pump())
	if !response.OK || response.RequestID != request.RequestID {
		t.Fatalf("response = %+v, want request_id %d", response, request.RequestID)
	}
}

func TestMalformedOversizedAndPathValidation(t *testing.T) {
	runtime := newStartedRuntime(t, "")
	defer stopRuntime(t, runtime)

	dispatchForTest(t, runtime, []byte("{"))
	malformed := decodeResponse(t, runtime.Pump())
	if malformed.OK || malformed.Outcome.Code != "malformed_json" {
		t.Fatalf("malformed response = %+v", malformed)
	}

	oversized := bytes.Repeat([]byte("x"), MaxInputBytes+1)
	if err := runtime.caliber.dispatch(oversized); err == nil || !strings.Contains(err.Error(), "limit_exceeded") {
		t.Fatalf("oversized Caliber dispatch error = %v", err)
	}

	dispatchForTest(t, runtime, []byte{0xff, 0xfe})
	invalidUTF8 := decodeResponse(t, runtime.Pump())
	if invalidUTF8.OK || invalidUTF8.Outcome.Code != "invalid_utf8" {
		t.Fatalf("invalid UTF-8 response = %+v", invalidUTF8)
	}

	dispatchForTest(t, runtime, mustJSON(t, CommandRequest{
		Version:   ProtocolVersion,
		RequestID: 6,
		Command:   "open_path",
		Path:      "bad\ufffdpath",
	}))
	badPath := decodeResponse(t, runtime.Pump())
	if badPath.OK || badPath.Outcome.Code != "invalid_path" {
		t.Fatalf("bad path response = %+v", badPath)
	}
}

func TestVisibleLinesAreBoundedImmutableResource(t *testing.T) {
	workspace := t.TempDir()
	path := filepath.Join(workspace, "large.txt")
	content := strings.Repeat(strings.Repeat("x", 400)+"\n", 400)
	writeFile(t, path, content)

	runtime := newStartedRuntime(t, workspace)
	defer stopRuntime(t, runtime)
	state := latestStateForTest(t, runtime)
	dispatchForTest(t, runtime, mustJSON(t, CommandRequest{
		Version:         ProtocolVersion,
		RequestID:       18,
		BasedOnRevision: state.ApplicationRev,
		Command:         "open_path",
		Path:            path,
	}))
	opened := decodeResponse(t, runtime.Pump())
	state = latestStateForTest(t, runtime)
	if !opened.OK || len(state.Documents) != 1 {
		t.Fatalf("open response = %+v, state = %+v", opened, state)
	}
	documentID := state.Documents[0].ID
	dispatchForTest(t, runtime, mustJSON(t, CommandRequest{
		Version:         ProtocolVersion,
		RequestID:       19,
		BasedOnRevision: state.ApplicationRev,
		Command:         "read_visible_lines",
		DocumentID:      documentID,
		StartLine:       10,
		MaxLines:        MaxVisibleLines,
		MaxBytes:        1024,
	}))
	response := decodeResponse(t, runtime.Pump())
	if !response.OK || response.ResourceID == 0 || response.Generation == 0 {
		t.Fatalf("visible resource response = %+v", response)
	}
	if response.DocumentID != documentID || response.ApplicationRev != state.ApplicationRev || response.EditorRevision != state.Documents[0].EditorRevision {
		t.Fatalf("visible resource identity = %+v, state = %+v", response, state)
	}
	if response.ByteLen == 0 || response.ByteLen > MaxVisibleBytes || !response.Truncated {
		t.Fatalf("visible resource bounds = %+v", response)
	}
	resource, err := runtime.caliber.readResourceCopy(response.ResourceID, response.Generation)
	if err != nil {
		t.Fatalf("map visible resource: %v", err)
	}
	if len(resource) != visibleSliceHeaderBytes+int(response.ByteLen) {
		t.Fatalf("mapped resource length = %d, descriptor = %d", len(resource), response.ByteLen)
	}
	if string(resource[:4]) != "SPVS" || binary.LittleEndian.Uint32(resource[4:8]) != VisibleSliceSchemaV1 {
		t.Fatalf("visible resource header = %q schema=%d", resource[:4], binary.LittleEndian.Uint32(resource[4:8]))
	}
	if got := binary.LittleEndian.Uint64(resource[8:16]); got != response.ApplicationRev {
		t.Fatalf("resource application revision = %d, response = %d", got, response.ApplicationRev)
	}
	if got := binary.LittleEndian.Uint64(resource[16:24]); got != response.EditorRevision {
		t.Fatalf("resource editor revision = %d, response = %d", got, response.EditorRevision)
	}
	if got := binary.LittleEndian.Uint64(resource[24:32]); got != response.StartLine || binary.LittleEndian.Uint64(resource[32:40]) != response.EndLine {
		t.Fatalf("resource line range does not match response: start=%d end=%d response=%+v", got, binary.LittleEndian.Uint64(resource[32:40]), response)
	}
	if got := binary.LittleEndian.Uint32(resource[44:48]); got != uint32(response.ByteLen) {
		t.Fatalf("resource payload length = %d, response = %d", got, response.ByteLen)
	}
	if binary.LittleEndian.Uint32(resource[40:44])&1 == 0 {
		t.Fatal("bounded large-document resource was not marked truncated")
	}
	if len(resource) >= len(content) {
		t.Fatalf("visible resource unexpectedly contains whole document: %d >= %d", len(resource), len(content))
	}
	if !bytes.Contains(resource[visibleSliceHeaderBytes:], []byte("xxxxxxxx")) {
		t.Fatalf("visible resource did not contain line bytes")
	}
	if err := runtime.caliber.releaseResourceOwner(response.ResourceID, response.Generation); err != nil {
		t.Fatalf("release visible resource owner: %v", err)
	}
	if _, err := runtime.caliber.readResourceCopy(response.ResourceID, response.Generation); err == nil {
		t.Fatal("released visible resource remained mappable")
	}
}

func TestVisibleLineRequestsRejectInvalidBounds(t *testing.T) {
	runtime := newStartedRuntime(t, "")
	defer stopRuntime(t, runtime)
	for requestID, request := range map[uint64]CommandRequest{
		20: {Version: ProtocolVersion, RequestID: 20, Command: "read_visible_lines", DocumentID: "doc", MaxLines: MaxVisibleLines + 1, MaxBytes: 1},
		21: {Version: ProtocolVersion, RequestID: 21, Command: "read_visible_lines", DocumentID: "doc", MaxLines: 1, MaxBytes: MaxVisibleBytes + 1},
		22: {Version: ProtocolVersion, RequestID: 22, Command: "read_visible_lines", DocumentID: "doc", MaxLines: 0, MaxBytes: 1},
	} {
		request.RequestID = requestID
		dispatchForTest(t, runtime, mustJSON(t, request))
		response := decodeResponse(t, runtime.Pump())
		if response.OK || response.Outcome.Code != "invalid_visible_range" {
			t.Fatalf("invalid visible request %+v response = %+v", request, response)
		}
	}
}

func TestSmokeRoundTrip(t *testing.T) {
	workspace := t.TempDir()
	writeFile(t, filepath.Join(workspace, "b.txt"), "b")
	writeFile(t, filepath.Join(workspace, "a.txt"), "a")
	for i := 0; i < 5; i++ {
		writeFile(t, filepath.Join(workspace, "many", string(rune('a'+i))+".txt"), "x")
	}

	runtime := newStartedRuntime(t, workspace)
	defer stopRuntime(t, runtime)
	state := latestStateForTest(t, runtime)

	dispatchForTest(t, runtime, mustJSON(t, CommandRequest{
		Version:         ProtocolVersion,
		RequestID:       7,
		BasedOnRevision: state.ApplicationRev,
		Command:         "snapshot",
	}))
	initial := decodeResponse(t, runtime.Pump())
	state = latestStateForTest(t, runtime)
	if !initial.OK || !state.HasWorkspace {
		t.Fatalf("snapshot response = %+v", initial)
	}
	if initial.Revision != 2 {
		t.Fatalf("snapshot revision = %d, want 2", initial.Revision)
	}

	dispatchForTest(t, runtime, mustJSON(t, CommandRequest{
		Version:         ProtocolVersion,
		RequestID:       8,
		BasedOnRevision: state.ApplicationRev,
		Command:         "list_directory",
		RelativePath:    "",
		Limit:           1,
	}))
	listing := decodeResponse(t, runtime.Pump())
	if !listing.OK || listing.DirectoryListing == nil {
		t.Fatalf("listing response = %+v", listing)
	}
	if !listing.DirectoryListing.Truncated || len(listing.DirectoryListing.Entries) != 1 {
		t.Fatalf("listing bound not applied: %+v", listing.DirectoryListing)
	}

	dispatchForTest(t, runtime, mustJSON(t, CommandRequest{
		Version:         ProtocolVersion,
		RequestID:       9,
		BasedOnRevision: state.ApplicationRev,
		Command:         "open_path",
		Path:            filepath.Join(workspace, "a.txt"),
	}))
	open := decodeResponse(t, runtime.Pump())
	state = latestStateForTest(t, runtime)
	if !open.OK || len(state.Documents) != 1 {
		t.Fatalf("open response = %+v", open)
	}
	if state.Documents[0].Path != filepath.Join(workspace, "a.txt") {
		t.Fatalf("opened document = %+v", state.Documents[0])
	}
	if state.Revision != open.Revision {
		t.Fatalf("state revision %d != response revision %d", state.Revision, open.Revision)
	}
	id := application.DocumentID(state.Documents[0].ID)
	doc := runtime.app.Documents[id]
	doc.Editor.SetCursor(doc.Editor.Buffer.ByteLen())
	if err := doc.Insert([]byte(" changed")); err != nil {
		t.Fatalf("make document dirty: %v", err)
	}
	state = latestStateForTest(t, runtime)
	dispatchForTest(t, runtime, mustJSON(t, CommandRequest{
		Version:         ProtocolVersion,
		RequestID:       15,
		BasedOnRevision: state.ApplicationRev,
		Command:         "close_document",
		DocumentID:      string(id),
		Discard:         false,
	}))
	dirtyClose := decodeResponse(t, runtime.Pump())
	if dirtyClose.OK || dirtyClose.Outcome.Code != "application_error" {
		t.Fatalf("dirty close response = %+v", dirtyClose)
	}
	state = latestStateForTest(t, runtime)
	dispatchForTest(t, runtime, mustJSON(t, CommandRequest{
		Version:         ProtocolVersion,
		RequestID:       16,
		BasedOnRevision: state.ApplicationRev,
		Command:         "close_document",
		DocumentID:      string(id),
		Discard:         true,
	}))
	discardClose := decodeResponse(t, runtime.Pump())
	if !discardClose.OK {
		t.Fatalf("discard close response = %+v", discardClose)
	}
}

func TestStaleRevision(t *testing.T) {
	runtime := newStartedRuntime(t, "")
	defer stopRuntime(t, runtime)

	dispatchForTest(t, runtime, mustJSON(t, CommandRequest{
		Version:         ProtocolVersion,
		RequestID:       10,
		BasedOnRevision: 999,
		Command:         "snapshot",
	}))
	response := decodeResponse(t, runtime.Pump())
	if response.OK || response.Outcome.Code != "stale_revision" {
		t.Fatalf("stale revision response = %+v", response)
	}
	if response.Revision != 1 {
		t.Fatalf("stale response did not include current state: %+v", response)
	}
}

func BenchmarkRoundTrip(b *testing.B) {
	runtime := newStartedRuntime(b, "")
	defer stopRuntime(b, runtime)
	request := mustJSON(b, CommandRequest{
		Version:         ProtocolVersion,
		RequestID:       11,
		BasedOnRevision: 0,
		Command:         "snapshot",
	})
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		dispatchForTest(b, runtime, request)
		response := decodeResponse(b, runtime.Pump())
		if !response.OK {
			b.Fatalf("round trip failed: %+v", response)
		}
	}
}

func newStartedRuntime(tb testing.TB, workspace string) *Runtime {
	tb.Helper()
	runtime := NewRuntime()
	start := decodeResponse(tb, runtime.Start(mustJSON(tb, StartRequest{
		Version:       ProtocolVersion,
		RequestID:     12,
		WorkspacePath: workspace,
	})))
	if !start.OK || start.Lifecycle != lifecycleRunning || start.Revision != 1 {
		tb.Fatalf("start response = %+v", start)
	}
	_ = latestStateForTest(tb, runtime)
	return runtime
}

func stopRuntime(tb testing.TB, runtime *Runtime) {
	tb.Helper()
	response := decodeResponse(tb, runtime.Stop(mustJSON(tb, StopRequest{
		Version:   ProtocolVersion,
		RequestID: 13,
	})))
	if !response.OK {
		tb.Fatalf("stop response = %+v", response)
	}
}

func writeFile(tb testing.TB, path, content string) {
	tb.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		tb.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		tb.Fatal(err)
	}
}

func dispatchForTest(tb testing.TB, runtime *Runtime, data []byte) {
	tb.Helper()
	if err := runtime.caliber.dispatch(data); err != nil {
		tb.Fatalf("dispatch through Caliber function table: %v", err)
	}
}

func latestStateForTest(tb testing.TB, runtime *Runtime) StateEnvelope {
	tb.Helper()
	data, revision, schema, err := runtime.caliber.readLatestStateCopy()
	if err != nil {
		tb.Fatalf("read state through Caliber function table: %v", err)
	}
	if schema != StateSchemaV1 {
		tb.Fatalf("state schema = %d, want %d", schema, StateSchemaV1)
	}
	var state StateEnvelope
	if err := json.Unmarshal(data, &state); err != nil {
		tb.Fatalf("decode state revision %d: %v", revision, err)
	}
	if state.Revision != revision {
		tb.Fatalf("state revision = %d, Caliber revision = %d", state.Revision, revision)
	}
	return state
}

func mustJSON(tb testing.TB, value any) []byte {
	tb.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		tb.Fatal(err)
	}
	return data
}

func decodeResponse(tb testing.TB, data []byte) Response {
	tb.Helper()
	var response Response
	if err := json.Unmarshal(data, &response); err != nil {
		tb.Fatalf("decode response %q: %v", strings.TrimSpace(string(data)), err)
	}
	return response
}
