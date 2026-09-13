package backend

import (
	"encoding/json"
	"testing"
)

func TestSemanticWorkspaceAndFindCommandsDecode(t *testing.T) {
	tests := []struct {
		name string
		body CommandRequest
		want string
	}{
		{
			name: "create file",
			body: CommandRequest{Version: ProtocolVersion, RequestID: 1, Command: "create_file", Path: "notes/today.md"},
			want: "create_file",
		},
		{
			name: "create folder",
			body: CommandRequest{Version: ProtocolVersion, RequestID: 2, Command: "create_folder", Path: "notes"},
			want: "create_folder",
		},
		{
			name: "rename",
			body: CommandRequest{Version: ProtocolVersion, RequestID: 3, Command: "rename_path", Path: "notes/today.md", Name: "renamed.md"},
			want: "rename_path",
		},
		{
			name: "move",
			body: CommandRequest{Version: ProtocolVersion, RequestID: 4, Command: "move_path", Path: "notes/today.md", RelativePath: "archive/today.md"},
			want: "move_path",
		},
		{
			name: "trash",
			body: CommandRequest{Version: ProtocolVersion, RequestID: 5, Command: "trash_path", Path: "notes/today.md", Discard: true},
			want: "trash_path",
		},
		{
			name: "find",
			body: CommandRequest{Version: ProtocolVersion, RequestID: 6, Command: "find_current", DocumentID: "doc", Query: "needle", MaxMatches: 10},
			want: "find_current",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			input, err := json.Marshal(test.body)
			if err != nil {
				t.Fatal(err)
			}
			request, response, ok := decodeCommandRequest(input, lifecycleRunning)
			if !ok {
				t.Fatalf("decode failed: %+v", response)
			}
			if request.Command != test.want {
				t.Fatalf("command = %q, want %q", request.Command, test.want)
			}
		})
	}
}

func TestFindCurrentCommandValidationBoundsMatches(t *testing.T) {
	base := CommandRequest{
		Version:    ProtocolVersion,
		RequestID:  7,
		Command:    "find_current",
		DocumentID: "doc",
		Query:      "needle",
	}
	input, err := json.Marshal(base)
	if err != nil {
		t.Fatal(err)
	}
	if _, response, ok := decodeCommandRequest(input, lifecycleRunning); !ok {
		t.Fatalf("default max_matches request rejected: %+v", response)
	}

	base.MaxMatches = MaxFindMatches + 1
	input, err = json.Marshal(base)
	if err != nil {
		t.Fatal(err)
	}
	if _, response, ok := decodeCommandRequest(input, lifecycleRunning); ok || response.Outcome.Code != "invalid_limit" {
		t.Fatalf("oversized max_matches result = ok=%v response=%+v", ok, response)
	}

	response := Response{
		Version:          ProtocolVersion,
		RequestID:        8,
		Lifecycle:        lifecycleRunning,
		OK:               true,
		Outcome:          Outcome{Code: "ok"},
		Matches:          []CurrentMatch{{Start: 4, End: 10, Line: 1, Column: 2}},
		MatchesTruncated: true,
	}
	encoded, err := json.Marshal(response)
	if err != nil {
		t.Fatal(err)
	}
	var decoded Response
	if err := json.Unmarshal(encoded, &decoded); err != nil {
		t.Fatal(err)
	}
	if len(decoded.Matches) != 1 || !decoded.MatchesTruncated || decoded.Matches[0].Start != 4 {
		t.Fatalf("find response = %+v", decoded)
	}
}
