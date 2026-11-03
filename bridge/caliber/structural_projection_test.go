package backend

import (
	"path/filepath"
	"testing"
	"time"

	"scratchpad/application"
)

func TestReadViewWindowValidatesStructuralProjectionKind(t *testing.T) {
	valid := []byte("{\"version\":1,\"request_id\":10,\"command\":\"read_view_window\",\"document_id\":\"doc\",\"projection_kind\":\"tasks\",\"projection_first\":0,\"projection_limit\":8}")
	request, response, ok := decodeCommandRequest(valid, lifecycleRunning)
	if !ok || response.OK || request.ProjectionKind != "tasks" {
		t.Fatalf("valid structural projection request = %+v, response %+v, ok=%v", request, response, ok)
	}
	invalid := []byte("{\"version\":1,\"request_id\":11,\"command\":\"read_view_window\",\"document_id\":\"doc\",\"projection_kind\":\"backlinks\",\"projection_first\":0,\"projection_limit\":8}")
	_, rejected, accepted := decodeCommandRequest(invalid, lifecycleRunning)
	if accepted || rejected.OK || rejected.Outcome.Code != "invalid_projection_kind" {
		t.Fatalf("unknown structural projection kind accepted: %+v", rejected)
	}
}

func TestStructuralProjectionCommandsReturnBoundedProviderRanges(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "structure.md")
	source := "# Notes\n\n- [ ] First task\n\nSee [guide](docs/guide.md).\n"
	writeFile(t, path, source)
	runtime := newStartedRuntime(t, root)
	defer stopRuntime(t, runtime)

	state := latestStateForTest(t, runtime)
	dispatchForTest(t, runtime, mustJSON(t, CommandRequest{
		Version: ProtocolVersion, RequestID: 81, BasedOnRevision: state.ApplicationRev,
		Command: "open_path", Path: path,
	}))
	opened := decodeResponse(t, runtime.Pump())
	if !opened.OK {
		t.Fatalf("open document = %+v", opened)
	}
	state = latestStateForTest(t, runtime)
	documentID := state.Documents[0].ID
	doc := runtime.app.Documents[application.DocumentID(documentID)]
	deadline := time.Now().Add(3 * time.Second)
	for !doc.DerivedCurrent() && time.Now().Before(deadline) {
		runtime.app.PollDerived(time.Now())
		time.Sleep(time.Millisecond)
	}
	if !doc.DerivedCurrent() {
		t.Fatal("Markdown analysis did not become current")
	}

	for requestID, kind := range map[uint64]string{82: "tasks", 83: "links", 84: "symbols"} {
		dispatchForTest(t, runtime, mustJSON(t, CommandRequest{
			Version: ProtocolVersion, RequestID: requestID, BasedOnRevision: state.ApplicationRev,
			Command: "read_view_window", DocumentID: documentID, ProjectionKind: kind,
			ProjectionFirst: 0, ProjectionLimit: 1,
		}))
		read := decodeResponse(t, runtime.Pump())
		window := read.SemanticViewWindow
		if !read.OK || window == nil || !window.Ready || !window.Supported || window.Mode != kind ||
			window.Total == 0 || len(window.Segments) != 1 || window.Segments[0].Status != string(application.ProjectionCurrent) {
			t.Fatalf("%s projection response = %+v", kind, read)
		}
		if window.Segments[0].DocumentID != documentID || window.Segments[0].StartByte < 0 ||
			window.Segments[0].EndByte <= window.Segments[0].StartByte {
			t.Fatalf("%s segment lost its source mapping: %+v", kind, window.Segments[0])
		}
	}
}
