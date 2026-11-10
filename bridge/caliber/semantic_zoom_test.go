package backend

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"scratchpad/application"
	"scratchpad/language"
)

func TestReadSemanticZoomRequestValidation(t *testing.T) {
	valid := `{"version":1,"request_id":80,"command":"read_semantic_zoom","document_id":"doc","editor_revision":0,"anchor_byte":0,"zoom_depth":0}`
	for depth := 0; depth <= 3; depth++ {
		input := strings.Replace(valid, `"zoom_depth":0`, fmt.Sprintf(`"zoom_depth":%d`, depth), 1)
		request, response, ok := decodeCommandRequest([]byte(input), lifecycleRunning)
		if !ok || request.ZoomDepth != depth || request.Command != "read_semantic_zoom" {
			t.Fatalf("depth %d rejected: %+v", depth, response)
		}
	}
	for _, tc := range []struct{ old, replacement, code string }{
		{`"document_id":"doc"`, `"document_id":""`, "invalid_document_id"},
		{`"document_id":"doc"`, `"document_id":"bad\u0000id"`, "invalid_document_id"},
		{`"editor_revision":0,`, "", "invalid_editor_revision"},
		{`"editor_revision":0`, `"editor_revision":null`, "invalid_editor_revision"},
		{`"zoom_depth":0`, `"zoom_depth":null`, "invalid_zoom_depth"},
		{`,"zoom_depth":0`, "", "invalid_zoom_depth"},
		{`"zoom_depth":0`, `"zoom_depth":-1`, "invalid_zoom_depth"},
		{`"zoom_depth":0`, `"zoom_depth":4`, "invalid_zoom_depth"},
		{`"anchor_byte":0`, `"anchor_byte":18446744073709551615`, "invalid_zoom_anchor"},
	} {
		input := strings.Replace(valid, tc.old, tc.replacement, 1)
		_, response, ok := decodeCommandRequest([]byte(input), lifecycleRunning)
		if ok || response.OK || response.Outcome.Code != tc.code {
			t.Fatalf("accepted/incorrect error for %s: %+v", input, response)
		}
	}
}

func TestSemanticZoomExactWireSchemaAndDetachedConversion(t *testing.T) {
	plan := application.SemanticZoomPlan{DocumentID: "doc", Revision: 7, InstanceID: 12, Depth: 2,
		AnchorByte: 3, Ready: true, Supported: true, LineCount: 5,
		Folds: []application.SemanticZoomFold{{StartLine: 1, EndLine: 4, StartByte: 9, EndByte: 30, Label: "3 lines"}}}
	wire := semanticZoomFromApplication(plan)
	encoded, err := json.Marshal(wire)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"document_id":"doc","revision":7,"instance_id":12,"depth":2,"anchor_byte":3,"ready":true,"supported":true,"line_count":5,"folds":[{"start_line":1,"end_line":4,"start_byte":9,"end_byte":30,"label":"3 lines"}]}`
	if string(encoded) != want {
		t.Fatalf("wire schema changed:\n%s\nwant:\n%s", encoded, want)
	}
	wire.Folds[0].StartByte = 999
	if plan.Folds[0].StartByte != 9 {
		t.Fatal("wire conversion aliases application plan")
	}
	plan.Generation = 42
	wire = semanticZoomFromApplication(plan)
	if wire.Generation != 42 {
		t.Fatalf("worker generation was lost in protocol conversion: %+v", wire)
	}
	plan.Folds = nil
	plan.Supported, plan.Reason = false, "fold_limit_exceeded"
	response := Response{Version: ProtocolVersion, OK: true, SemanticZoom: semanticZoomFromApplication(plan)}
	encoded, err = json.Marshal(response)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(encoded), `"semantic_zoom":`) || !strings.Contains(string(encoded), `"folds":[]`) ||
		!strings.Contains(string(encoded), `"reason":"fold_limit_exceeded"`) || strings.Contains(string(encoded), `"text":`) {
		t.Fatalf("fallback schema: %s", encoded)
	}
}

func semanticZoomBridgeRead(t *testing.T, runtime *Runtime, id string, revision uint64, depth int, anchor uint64) Response {
	t.Helper()
	dispatchForTest(t, runtime, mustJSON(t, CommandRequest{Version: ProtocolVersion, RequestID: 81,
		Command: "read_semantic_zoom", DocumentID: id, EditorRevision: revision, ZoomDepth: depth, AnchorByte: anchor}))
	return decodeResponse(t, runtime.Pump())
}

func semanticZoomBridgeReadGeneration(t *testing.T, runtime *Runtime, id string, revision uint64, depth int, anchor uint64, generation uint64) Response {
	t.Helper()
	dispatchForTest(t, runtime, mustJSON(t, CommandRequest{Version: ProtocolVersion, RequestID: 82,
		Command: "read_semantic_zoom", DocumentID: id, EditorRevision: revision, ZoomDepth: depth,
		AnchorByte: anchor, SemanticZoomGeneration: generation}))
	return decodeResponse(t, runtime.Pump())
}

func TestSemanticZoomGenerationRequestValidation(t *testing.T) {
	input := `{"version":1,"request_id":80,"command":"cancel_semantic_zoom","semantic_zoom_generation":1}`
	request, response, ok := decodeCommandRequest([]byte(input), lifecycleRunning)
	if !ok || request.SemanticZoomGeneration != 1 {
		t.Fatalf("valid cancel request rejected: %+v", response)
	}
	input = `{"version":1,"request_id":80,"command":"cancel_semantic_zoom"}`
	_, response, ok = decodeCommandRequest([]byte(input), lifecycleRunning)
	if ok || response.OK || response.Outcome.Code != "invalid_semantic_zoom_generation" {
		t.Fatalf("cancel without a generation was accepted: %+v", response)
	}
}

func TestLargeSemanticZoomBuildPublishesGenerationScopedPlan(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "large.txt")
	writeFile(t, path, strings.Repeat("x", 128*1024))
	runtime := newStartedRuntime(t, root)
	defer stopRuntime(t, runtime)
	dispatchForTest(t, runtime, mustJSON(t, CommandRequest{Version: ProtocolVersion, RequestID: 80, Command: "open_path", Path: path}))
	if response := decodeResponse(t, runtime.Pump()); !response.OK {
		t.Fatalf("open: %+v", response)
	}
	state := latestStateForTest(t, runtime)
	id, revision := state.Documents[0].ID, state.Documents[0].EditorRevision
	pending := semanticZoomBridgeRead(t, runtime, id, revision, application.SemanticZoomSkim, 0)
	if !pending.OK || pending.SemanticZoom == nil || pending.SemanticZoom.Ready || pending.SemanticZoom.Reason != "pending" || pending.SemanticZoom.Generation == 0 {
		t.Fatalf("large plan was not returned as a pending generation: %+v", pending)
	}
	generation := pending.SemanticZoom.Generation

	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		runtime.mu.Lock()
		ready := runtime.semanticZoom != nil && runtime.semanticZoom.generation == generation && runtime.semanticZoom.done
		runtime.mu.Unlock()
		if ready {
			break
		}
		time.Sleep(time.Millisecond)
	}
	state = latestStateForTest(t, runtime)
	if state.SemanticZoomGeneration != generation || !state.SemanticZoomReady {
		t.Fatalf("completion did not publish its matching generation: %+v", state)
	}
	completed := semanticZoomBridgeReadGeneration(t, runtime, id, revision, application.SemanticZoomSkim, 0, generation)
	if !completed.OK || completed.SemanticZoom == nil || !completed.SemanticZoom.Ready || completed.SemanticZoom.Generation != generation {
		t.Fatalf("could not retrieve completed generation: %+v", completed)
	}

	dispatchForTest(t, runtime, mustJSON(t, CommandRequest{Version: ProtocolVersion, RequestID: 83,
		Command: "cancel_semantic_zoom", SemanticZoomGeneration: generation}))
	if response := decodeResponse(t, runtime.Pump()); !response.OK {
		t.Fatalf("cancel completed generation: %+v", response)
	}
	stale := semanticZoomBridgeReadGeneration(t, runtime, id, revision, application.SemanticZoomSkim, 0, generation)
	if stale.OK || stale.Outcome.Code != "stale_semantic_zoom_request" {
		t.Fatalf("canceled generation remained retrievable: %+v", stale)
	}
}

func TestSemanticZoomNewDocumentPublishesSupersededGeneration(t *testing.T) {
	root := t.TempDir()
	largePath := filepath.Join(root, "large.txt")
	smallPath := filepath.Join(root, "small.txt")
	largeSource := strings.Repeat("x", 128*1024)
	writeFile(t, largePath, largeSource)
	writeFile(t, smallPath, "short document\n")
	runtime := newStartedRuntime(t, root)
	defer stopRuntime(t, runtime)

	workerStarted := make(chan struct{}, 1)
	workerCanceled := make(chan struct{}, 1)
	runtime.mu.Lock()
	runtime.semanticZoomBuilder = func(ctx context.Context, _ application.SemanticZoomSnapshot) (application.SemanticZoomPlan, error) {
		workerStarted <- struct{}{}
		<-ctx.Done()
		workerCanceled <- struct{}{}
		return application.SemanticZoomPlan{}, application.ErrSemanticZoomCanceled
	}
	runtime.mu.Unlock()

	state := latestStateForTest(t, runtime)
	dispatchForTest(t, runtime, mustJSON(t, CommandRequest{Version: ProtocolVersion, RequestID: 80,
		BasedOnRevision: state.ApplicationRev, Command: "open_path", Path: largePath}))
	if response := decodeResponse(t, runtime.Pump()); !response.OK {
		t.Fatalf("open large document: %+v", response)
	}
	state = latestStateForTest(t, runtime)
	largeDocument := state.Documents[0]
	pending := semanticZoomBridgeRead(t, runtime, largeDocument.ID, largeDocument.EditorRevision, application.SemanticZoomSkim, 0)
	if !pending.OK || pending.SemanticZoom == nil || pending.SemanticZoom.Ready || pending.SemanticZoom.Generation == 0 {
		t.Fatalf("large document did not start background semantic zoom: %+v", pending)
	}
	generation := pending.SemanticZoom.Generation
	select {
	case <-workerStarted:
	case <-time.After(5 * time.Second):
		t.Fatal("semantic zoom worker did not start")
	}

	state = latestStateForTest(t, runtime)
	dispatchForTest(t, runtime, mustJSON(t, CommandRequest{Version: ProtocolVersion, RequestID: 81,
		BasedOnRevision: state.ApplicationRev, Command: "open_path", Path: smallPath}))
	if response := decodeResponse(t, runtime.Pump()); !response.OK {
		t.Fatalf("open small document: %+v", response)
	}
	state = latestStateForTest(t, runtime)
	canonicalSmallPath, err := filepath.EvalSymlinks(smallPath)
	if err != nil {
		t.Fatal(err)
	}
	var smallDocument StateDocument
	for _, document := range state.Documents {
		if document.ID == string(application.DocumentID(canonicalSmallPath)) {
			smallDocument = document
			break
		}
	}
	if smallDocument.ID == "" {
		t.Fatalf("small document missing from state: %+v", state.Documents)
	}
	ready := semanticZoomBridgeRead(t, runtime, smallDocument.ID, smallDocument.EditorRevision, application.SemanticZoomSkim, 0)
	if !ready.OK || ready.SemanticZoom == nil || !ready.SemanticZoom.Ready {
		t.Fatalf("small document should be prepared synchronously: %+v", ready)
	}

	state = latestStateForTest(t, runtime)
	if state.SemanticZoomSupersededThrough < generation {
		t.Fatalf("canceled tab was not given a terminal state signal: got=%d want at least %d",
			state.SemanticZoomSupersededThrough, generation)
	}
	stale := semanticZoomBridgeReadGeneration(t, runtime, largeDocument.ID, largeDocument.EditorRevision,
		application.SemanticZoomSkim, 0, generation)
	if stale.OK || stale.Outcome.Code != "stale_semantic_zoom_request" {
		t.Fatalf("superseded tab still retrieved its canceled generation: %+v", stale)
	}
	select {
	case <-workerCanceled:
	case <-time.After(5 * time.Second):
		t.Fatal("superseding a request did not cancel its worker")
	}
}

func TestSemanticZoomEditCancelsBlockedWorkerAndRejectsOldGeneration(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "large.txt")
	source := strings.Repeat("x", 128*1024)
	writeFile(t, path, source)
	runtime := newStartedRuntime(t, root)
	defer stopRuntime(t, runtime)

	workerStarted := make(chan struct{}, 1)
	workerCanceled := make(chan struct{}, 1)
	runtime.mu.Lock()
	runtime.semanticZoomBuilder = func(ctx context.Context, _ application.SemanticZoomSnapshot) (application.SemanticZoomPlan, error) {
		workerStarted <- struct{}{}
		<-ctx.Done()
		workerCanceled <- struct{}{}
		return application.SemanticZoomPlan{}, application.ErrSemanticZoomCanceled
	}
	runtime.mu.Unlock()

	state := latestStateForTest(t, runtime)
	dispatchForTest(t, runtime, mustJSON(t, CommandRequest{Version: ProtocolVersion, RequestID: 80,
		BasedOnRevision: state.ApplicationRev, Command: "open_path", Path: path}))
	if response := decodeResponse(t, runtime.Pump()); !response.OK {
		t.Fatalf("open: %+v", response)
	}
	state = latestStateForTest(t, runtime)
	document := state.Documents[0]
	pending := semanticZoomBridgeRead(t, runtime, document.ID, document.EditorRevision, application.SemanticZoomSkim, 0)
	if !pending.OK || pending.SemanticZoom == nil || pending.SemanticZoom.Ready || pending.SemanticZoom.Generation == 0 {
		t.Fatalf("large plan was not pending: %+v", pending)
	}
	generation := pending.SemanticZoom.Generation
	select {
	case <-workerStarted:
	case <-time.After(5 * time.Second):
		t.Fatal("semantic zoom worker did not start")
	}

	// The test builder blocks until cancellation. The runtime lock must remain
	// available while it does, so an authoritative edit can proceed.
	if !runtime.mu.TryLock() {
		t.Fatal("semantic plan construction held the application runtime lock")
	}
	runtime.mu.Unlock()

	dispatchForTest(t, runtime, mustJSON(t, CommandRequest{Version: ProtocolVersion, RequestID: 81,
		BasedOnRevision: state.ApplicationRev, Command: "replace_document", DocumentID: document.ID,
		EditorRevision: document.EditorRevision, StartByte: uint64(len(source)), EndByte: uint64(len(source)),
		Replacement: []int{'!'}}))
	edited := decodeResponse(t, runtime.Pump())
	if !edited.OK || edited.Edit == nil || edited.Edit.EditorRevision == document.EditorRevision {
		t.Fatalf("edit did not proceed while semantic work was pending: %+v", edited)
	}
	select {
	case <-workerCanceled:
	case <-time.After(5 * time.Second):
		t.Fatal("source revision change did not cooperatively cancel semantic work")
	}

	stale := semanticZoomBridgeReadGeneration(t, runtime, document.ID, document.EditorRevision,
		application.SemanticZoomSkim, 0, generation)
	if stale.OK || stale.Outcome.Code != "stale_semantic_zoom_request" {
		t.Fatalf("superseded plan remained available after an edit: %+v", stale)
	}

	state = latestStateForTest(t, runtime)
	current := state.Documents[0]
	if current.EditorRevision <= document.EditorRevision {
		t.Fatalf("authoritative revision did not advance: before=%d after=%d", document.EditorRevision, current.EditorRevision)
	}
	next := semanticZoomBridgeRead(t, runtime, current.ID, current.EditorRevision, application.SemanticZoomSkim, 1)
	if !next.OK || next.SemanticZoom == nil || next.SemanticZoom.Ready || next.SemanticZoom.Generation <= generation {
		t.Fatalf("latest revision did not receive a newer pending generation: %+v", next)
	}
}

func TestSemanticZoomWorkerDropsSupersededCompletion(t *testing.T) {
	runtime := newStartedRuntime(t, t.TempDir())
	defer stopRuntime(t, runtime)
	old := &semanticZoomSession{generation: 1}
	current := &semanticZoomSession{generation: 2}
	runtime.mu.Lock()
	runtime.semanticZoom = current
	runtime.mu.Unlock()
	runtime.finishSemanticZoom(semanticZoomJob{session: old, ctx: context.Background()}, application.SemanticZoomPlan{Ready: true}, nil)
	runtime.mu.Lock()
	defer runtime.mu.Unlock()
	if runtime.semanticZoom != current || current.done {
		t.Fatal("a superseded worker completion replaced the current semantic plan")
	}
}

func TestReadSemanticZoomParserFreeReadOnlyAndValidation(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "prose.txt")
	source := "Opening sentence.\nHidden supporting line.\n\nOther paragraph.\nOther detail.\n"
	writeFile(t, path, source)
	runtime := newStartedRuntime(t, root)
	defer stopRuntime(t, runtime)
	dispatchForTest(t, runtime, mustJSON(t, CommandRequest{Version: ProtocolVersion, RequestID: 80, Command: "open_path", Path: path}))
	if response := decodeResponse(t, runtime.Pump()); !response.OK {
		t.Fatalf("open: %+v", response)
	}
	state := latestStateForTest(t, runtime)
	id, revision := state.Documents[0].ID, state.Documents[0].EditorRevision
	doc := runtime.app.Documents[application.DocumentID(id)]
	doc.Editor.SetSelection(2, 8)
	before := runtime.app.Snapshot()
	for depth := 0; depth <= 3; depth++ {
		response := semanticZoomBridgeRead(t, runtime, id, revision, depth, 0)
		plan := response.SemanticZoom
		if !response.OK || plan == nil || !plan.Ready || !plan.Supported || plan.DocumentID != id || plan.Revision != revision ||
			plan.InstanceID != doc.InstanceID() || plan.Depth != depth || plan.AnchorByte != 0 || plan.LineCount != strings.Count(source, "\n")+1 {
			t.Fatalf("read: %+v, plan=%+v", response, plan)
		}
		if depth == 0 && len(plan.Folds) != 0 {
			t.Fatal("Full returned folds")
		}
		if depth > 0 && len(plan.Folds) == 0 {
			t.Fatal("reduced prose returned no folds")
		}
		if depth == application.SemanticZoomFocus {
			separatorFound := false
			for _, fold := range plan.Folds {
				if fold.StartLine == 2 && fold.EndLine == 3 && fold.Silent {
					separatorFound = true
				}
			}
			if !separatorFound {
				t.Fatalf("bridge lost silent whitespace fold metadata: %+v", plan.Folds)
			}
		}
	}
	if runtime.presentationEnabled || !reflect.DeepEqual(before, runtime.app.Snapshot()) || string(doc.Editor.Buffer.Text()) != source || doc.CanUndo() {
		t.Fatal("zoom changed source/application or activated parser for prose")
	}
	if a, c := doc.Editor.Selection(); a != 2 || c != 8 {
		t.Fatal("zoom changed selection")
	}
	for _, tc := range []struct {
		id               string
		revision, anchor uint64
		code             string
	}{
		{id, revision + 1, 0, "stale_editor_revision"},
		{id, revision, uint64(len(source) + 1), "invalid_zoom_anchor"},
		{"missing", 0, 0, "zoom_unavailable"},
	} {
		response := semanticZoomBridgeRead(t, runtime, tc.id, tc.revision, 2, tc.anchor)
		if response.OK || response.Outcome.Code != tc.code || response.SemanticZoom != nil {
			t.Fatalf("validation: %+v", response)
		}
	}
}

func TestReadSemanticZoomUsesExistingDerivedLane(t *testing.T) {
	for _, tc := range []struct{ name, source string }{
		{"notes.md", "# A\n\nFirst.\nDetail.\n\n# B\n\nOther.\nOther detail.\n"},
		{"sample.go", "package p\n\n// F documents F.\nfunc F() {\n work()\n}\n\nfunc G() {\n other()\n}\n"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if strings.HasSuffix(tc.name, ".go") && !application.AnalysisSupported(language.Go) {
				t.Skip("Go analysis unavailable")
			}
			root := t.TempDir()
			path := filepath.Join(root, tc.name)
			writeFile(t, path, tc.source)
			runtime := newStartedRuntime(t, root)
			defer stopRuntime(t, runtime)
			dispatchForTest(t, runtime, mustJSON(t, CommandRequest{Version: ProtocolVersion, RequestID: 80, Command: "open_path", Path: path}))
			if response := decodeResponse(t, runtime.Pump()); !response.OK {
				t.Fatalf("open: %+v", response)
			}
			state := latestStateForTest(t, runtime)
			id, revision := state.Documents[0].ID, state.Documents[0].EditorRevision
			response := semanticZoomBridgeRead(t, runtime, id, revision, 3, 0)
			if !response.OK || response.SemanticZoom == nil || response.SemanticZoom.Ready || !response.SemanticZoom.Supported || len(response.SemanticZoom.Folds) != 0 {
				t.Fatalf("initial stale parser: %+v", response)
			}
			if !runtime.presentationEnabled {
				t.Fatal("read did not activate existing derived lane")
			}
			deadline := time.Now().Add(3 * time.Second)
			for time.Now().Before(deadline) {
				response = semanticZoomBridgeRead(t, runtime, id, revision, 3, 0)
				if response.SemanticZoom != nil && response.SemanticZoom.Ready {
					break
				}
				time.Sleep(time.Millisecond)
			}
			if !response.OK || response.SemanticZoom == nil || !response.SemanticZoom.Ready || len(response.SemanticZoom.Folds) == 0 {
				t.Fatalf("parser never ready: %+v", response)
			}
			if latestStateForTest(t, runtime).ApplicationRev != state.ApplicationRev {
				t.Fatal("query advanced source application revision")
			}
		})
	}
}

func TestReadSemanticZoomUnsupportedAndFoldBudget(t *testing.T) {
	for _, tc := range []struct{ name, source, reason string }{
		{"unsupported.rs", "fn main() {\n work();\n}\n", "unsupported_language"},
		{"large.txt", strings.Repeat("Opening.\nDetail.\n\n", application.MaxSemanticZoomFolds+1), "fold_limit_exceeded"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			root := t.TempDir()
			path := filepath.Join(root, tc.name)
			writeFile(t, path, tc.source)
			runtime := newStartedRuntime(t, root)
			defer stopRuntime(t, runtime)
			dispatchForTest(t, runtime, mustJSON(t, CommandRequest{Version: ProtocolVersion, RequestID: 80, Command: "open_path", Path: path}))
			if response := decodeResponse(t, runtime.Pump()); !response.OK {
				t.Fatalf("open: %+v", response)
			}
			state := latestStateForTest(t, runtime)
			id, revision := state.Documents[0].ID, state.Documents[0].EditorRevision
			response := semanticZoomBridgeRead(t, runtime, id, revision, 3, 0)
			plan := response.SemanticZoom
			if plan != nil && !plan.Ready && plan.Reason == "pending" {
				generation := plan.Generation
				deadline := time.Now().Add(5 * time.Second)
				for time.Now().Before(deadline) {
					runtime.mu.Lock()
					done := runtime.semanticZoom != nil && runtime.semanticZoom.generation == generation && runtime.semanticZoom.done
					runtime.mu.Unlock()
					if done {
						break
					}
					time.Sleep(time.Millisecond)
				}
				response = semanticZoomBridgeReadGeneration(t, runtime, id, revision, 3, 0, generation)
				plan = response.SemanticZoom
			}
			if !response.OK || plan == nil || !plan.Ready || plan.Supported || plan.Reason != tc.reason || len(plan.Folds) != 0 {
				t.Fatalf("unsupported fallback: %+v, %+v", response, plan)
			}
		})
	}
}
