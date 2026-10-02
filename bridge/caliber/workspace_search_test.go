package backend

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"scratchpad/application"
	"scratchpad/commands"
)

func dispatchSearchCommand(t *testing.T, runtime *Runtime, request CommandRequest) Response {
	t.Helper()
	state := latestStateForTest(t, runtime)
	request.Version = ProtocolVersion
	request.RequestID = state.Revision + uint64(time.Now().UnixNano()%1_000_000)
	request.BasedOnRevision = state.ApplicationRev
	dispatchForTest(t, runtime, mustJSON(t, request))
	return decodeResponse(t, runtime.Pump())
}

func waitForWorkspaceSearchState(t *testing.T, runtime *Runtime, generation, afterSequence uint64) StateEnvelope {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		state := latestStateForTest(t, runtime)
		if state.WorkspaceSearchGeneration == generation && (state.WorkspaceSearchSequence > afterSequence || state.WorkspaceSearchDone) {
			return state
		}
		time.Sleep(time.Millisecond)
	}
	state := latestStateForTest(t, runtime)
	t.Fatalf("search generation %d did not publish a page or completion: %+v", generation, state)
	return StateEnvelope{}
}

func takeWorkspaceSearchPageForTest(t *testing.T, runtime *Runtime, generation uint64) *WorkspaceSearchPage {
	t.Helper()
	response := dispatchSearchCommand(t, runtime, CommandRequest{
		Command:          "workspace_search_take_page",
		SearchGeneration: generation,
	})
	if !response.OK || response.WorkspaceSearchPage == nil {
		t.Fatalf("take search page response = %+v", response)
	}
	return response.WorkspaceSearchPage
}

func TestWorkspaceSearchNewGenerationDiscardsLateOldResults(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "old.txt"), strings.Repeat("alpha\n", 100))
	writeFile(t, filepath.Join(root, "new.txt"), "beta result\n")
	runtime := newStartedRuntime(t, root)
	defer stopRuntime(t, runtime)

	old := dispatchSearchCommand(t, runtime, CommandRequest{
		Command:          "workspace_search_start",
		SearchGeneration: 1,
		Query:            "alpha",
	})
	if !old.OK {
		t.Fatalf("start old query: %+v", old)
	}
	current := dispatchSearchCommand(t, runtime, CommandRequest{
		Command:          "workspace_search_start",
		SearchGeneration: 2,
		Query:            "beta",
	})
	if !current.OK {
		t.Fatalf("replace query: %+v", current)
	}

	state := waitForWorkspaceSearchState(t, runtime, 2, 0)
	if state.WorkspaceSearchGeneration != 2 {
		t.Fatalf("published search generation = %d, want 2", state.WorkspaceSearchGeneration)
	}
	stale := dispatchSearchCommand(t, runtime, CommandRequest{
		Command:          "workspace_search_take_page",
		SearchGeneration: 1,
	})
	if stale.OK || stale.Outcome.Code != "stale_search_generation" {
		t.Fatalf("old generation page response = %+v", stale)
	}

	var results []WorkspaceSearchResult
	lastSequence := uint64(0)
	for {
		state = waitForWorkspaceSearchState(t, runtime, 2, lastSequence)
		if state.WorkspaceSearchPageAvailable && state.WorkspaceSearchSequence > lastSequence {
			page := takeWorkspaceSearchPageForTest(t, runtime, 2)
			lastSequence = page.Sequence
			results = append(results, page.Results...)
			continue
		}
		if state.WorkspaceSearchDone {
			break
		}
	}
	if len(results) != 1 || results[0].Path != "new.txt" || results[0].Text != "beta result" {
		t.Fatalf("results included stale generation or wrong match: %+v", results)
	}
}

func TestQuickOpenWorkspaceFilesArePathOnlyAndDoNotRepublishState(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "nested", "note.md"), "the document bytes stay out of the path index")
	writeFile(t, filepath.Join(root, "z.txt"), "z")
	runtime := newStartedRuntime(t, root)
	defer stopRuntime(t, runtime)

	state := latestStateForTest(t, runtime)
	request := CommandRequest{
		Version:         ProtocolVersion,
		RequestID:       state.Revision + 1,
		BasedOnRevision: state.ApplicationRev + 1,
		Command:         "list_workspace_files",
	}
	dispatchForTest(t, runtime, mustJSON(t, request))
	response := decodeResponse(t, runtime.Pump())
	if !response.OK || response.WorkspaceFiles == nil {
		t.Fatalf("Quick Open file list response = %+v", response)
	}
	if response.BasedOnRevision != request.BasedOnRevision {
		t.Fatalf("Quick Open response lost request revision identity: %+v", response)
	}
	if response.State != nil || response.WorkspaceFiles.Truncated {
		t.Fatalf("path-only read should not republish state or truncate this fixture: %+v", response)
	}
	want := []string{"nested/note.md", "z.txt"}
	if len(response.WorkspaceFiles.Paths) != len(want) {
		t.Fatalf("Quick Open paths = %v, want %v", response.WorkspaceFiles.Paths, want)
	}
	for index := range want {
		if response.WorkspaceFiles.Paths[index] != want[index] {
			t.Fatalf("Quick Open paths = %v, want %v", response.WorkspaceFiles.Paths, want)
		}
	}
}

func TestMarkdownSmartPasteReceivesFrontendClipboardArgument(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "note.md")
	writeFile(t, path, "selected text")
	runtime := newStartedRuntime(t, root)
	defer stopRuntime(t, runtime)

	opened := dispatchSearchCommand(t, runtime, CommandRequest{Command: "open_path", Path: "note.md"})
	if !opened.OK {
		t.Fatalf("open Markdown document = %+v", opened)
	}
	state := latestStateForTest(t, runtime)
	var documentRevision uint64
	for _, document := range state.Documents {
		if document.ID == state.Active {
			documentRevision = document.EditorRevision
			break
		}
	}
	response := dispatchSearchCommand(t, runtime, CommandRequest{
		Command:          "execute_command",
		ActionID:         string(commands.MarkdownSmartPaste),
		DocumentID:       state.Active,
		EditorRevision:   documentRevision,
		EditorAnchorByte: 0,
		EditorCursorByte: uint64(len("selected text")),
		Argument:         "https://example.test/page",
	})
	if !response.OK {
		t.Fatalf("smart paste = %+v", response)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "[selected text](https://example.test/page)" {
		t.Fatalf("smart-paste result = %q", got)
	}
}

func TestWorkspaceSearchStreamsBoundedPagesAndCapsResults(t *testing.T) {
	root := t.TempDir()
	var contents strings.Builder
	for index := 0; index < WorkspaceSearchMaxResults+7; index++ {
		contents.WriteString("needle\n")
	}
	writeFile(t, filepath.Join(root, "many.txt"), contents.String())
	runtime := newStartedRuntime(t, root)
	defer stopRuntime(t, runtime)

	response := dispatchSearchCommand(t, runtime, CommandRequest{
		Command:          "workspace_search_start",
		SearchGeneration: 1,
		Query:            "needle",
	})
	if !response.OK {
		t.Fatalf("start query: %+v", response)
	}

	var total int
	lastSequence := uint64(0)
	var state StateEnvelope
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		state = waitForWorkspaceSearchState(t, runtime, 1, lastSequence)
		if state.WorkspaceSearchPageAvailable && state.WorkspaceSearchSequence > lastSequence {
			page := takeWorkspaceSearchPageForTest(t, runtime, 1)
			lastSequence = page.Sequence
			if len(page.Results) == 0 || len(page.Results) > WorkspaceSearchPageSize {
				t.Fatalf("page %d has %d results", page.Sequence, len(page.Results))
			}
			if page.Generation != 1 || page.Sequence != lastSequence {
				t.Fatalf("page identity = %+v", page)
			}
			total += len(page.Results)
			continue
		}
		if state.WorkspaceSearchDone {
			break
		}
	}
	if !state.WorkspaceSearchDone || !state.WorkspaceSearchTruncated || state.WorkspaceSearchCount != WorkspaceSearchMaxResults || total != WorkspaceSearchMaxResults {
		t.Fatalf("search did not finish at its bounded cap: state=%+v results=%d", state, total)
	}
}

func TestWorkspaceSearchHitOpensAtExactSourceByte(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "nested", "hit.txt")
	writeFile(t, path, "before\nneedle after\n")
	runtime := newStartedRuntime(t, root)
	defer stopRuntime(t, runtime)

	start := dispatchSearchCommand(t, runtime, CommandRequest{
		Command:          "workspace_search_start",
		SearchGeneration: 1,
		Query:            "needle",
	})
	if !start.OK {
		t.Fatalf("start query: %+v", start)
	}
	_ = waitForWorkspaceSearchState(t, runtime, 1, 0)
	page := takeWorkspaceSearchPageForTest(t, runtime, 1)
	if len(page.Results) != 1 || page.Results[0].StartByte != 7 || page.Results[0].EndByte != 13 {
		t.Fatalf("search result = %+v", page.Results)
	}

	opened := dispatchSearchCommand(t, runtime, CommandRequest{
		Command:       "open_path",
		Path:          filepath.Join(root, filepath.FromSlash(page.Results[0].Path)),
		HasTargetByte: true,
		TargetByte:    uint64(page.Results[0].StartByte),
	})
	if !opened.OK || opened.EditorSelection == nil {
		t.Fatalf("open search hit: %+v", opened)
	}
	if opened.EditorSelection.AnchorByte != 7 || opened.EditorSelection.CursorByte != 7 || opened.EditorSelection.CursorLine != 1 {
		t.Fatalf("open selection = %+v", opened.EditorSelection)
	}
	doc := runtime.app.Documents[application.DocumentID(opened.EditorSelection.DocumentID)]
	anchor, cursor := doc.Editor.Selection()
	if anchor != 7 || cursor != 7 {
		t.Fatalf("authoritative opened selection = %d:%d", anchor, cursor)
	}
}
