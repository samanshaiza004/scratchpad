package backend

import (
	"fmt"
	"path/filepath"
	"testing"
)

func TestFindCurrentReportsTruncationOnlyWhenResultsExceedTheLimit(t *testing.T) {
	for _, count := range []int{MaxFindMatches, MaxFindMatches + 1} {
		t.Run(fmt.Sprint(count), func(t *testing.T) {
			root := t.TempDir()
			path := filepath.Join(root, "many.txt")
			contents := make([]byte, 0, count*2)
			for index := 0; index < count; index++ {
				contents = append(contents, 'x', '\n')
			}
			writeFile(t, path, string(contents))
			runtime := newStartedRuntime(t, root)
			defer stopRuntime(t, runtime)
			opened := dispatchSearchCommand(t, runtime, CommandRequest{Command: "open_path", Path: path})
			if !opened.OK {
				t.Fatalf("open document: %+v", opened)
			}
			state := latestStateForTest(t, runtime)
			if len(state.Documents) != 1 {
				t.Fatalf("documents = %d", len(state.Documents))
			}
			response := dispatchSearchCommand(t, runtime, CommandRequest{
				Command: "find_current", DocumentID: state.Documents[0].ID, Query: "x", MaxMatches: MaxFindMatches,
			})
			if !response.OK {
				t.Fatalf("find response: %+v", response)
			}
			if len(response.Matches) != MaxFindMatches {
				t.Fatalf("match count = %d, want %d", len(response.Matches), MaxFindMatches)
			}
			wantTruncated := count > MaxFindMatches
			if response.MatchesTruncated != wantTruncated {
				t.Fatalf("truncated = %v, want %v", response.MatchesTruncated, wantTruncated)
			}
		})
	}
}
