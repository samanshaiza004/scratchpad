package backend

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"unicode/utf8"

	"scratchpad/application"
	"scratchpad/workspace"
)

const (
	ProtocolVersion         uint32 = 1
	StateSchemaV1           uint32 = 1
	MaxInputBytes                  = 1 << 20
	DefaultListLimit               = 200
	MaxListLimit                   = 1000
	MaxVisibleLines                = 256
	MaxVisibleBytes                = 64 * 1024
	VisibleSliceSchemaV1           = 1
	visibleSliceHeaderBytes        = 48
)

type StartRequest struct {
	Version       uint32 `json:"version"`
	RequestID     uint64 `json:"request_id"`
	WorkspacePath string `json:"workspace_path,omitempty"`
}

type StopRequest struct {
	Version   uint32 `json:"version"`
	RequestID uint64 `json:"request_id"`
}

type CommandRequest struct {
	Version         uint32 `json:"version"`
	RequestID       uint64 `json:"request_id"`
	BasedOnRevision uint64 `json:"based_on_revision"`
	Command         string `json:"command"`
	Path            string `json:"path,omitempty"`
	DocumentID      string `json:"document_id,omitempty"`
	Discard         bool   `json:"discard,omitempty"`
	RelativePath    string `json:"relative_path,omitempty"`
	Limit           int    `json:"limit,omitempty"`
	StartLine       uint64 `json:"start_line,omitempty"`
	MaxLines        uint64 `json:"max_lines,omitempty"`
	MaxBytes        uint64 `json:"max_bytes,omitempty"`
}

type Response struct {
	Version          uint32              `json:"version"`
	RequestID        uint64              `json:"request_id,omitempty"`
	Lifecycle        string              `json:"lifecycle"`
	OK               bool                `json:"ok"`
	Outcome          Outcome             `json:"outcome"`
	Revision         uint64              `json:"revision,omitempty"`
	BasedOnRevision  uint64              `json:"based_on_revision,omitempty"`
	State            *StateEnvelope      `json:"state,omitempty"`
	DirectoryListing *DirectoryListing   `json:"directory_listing,omitempty"`
	Resource         *ResourceDescriptor `json:"resource,omitempty"`
}

type ResourceDescriptor struct {
	ResourceID     uint64 `json:"resource_id"`
	Generation     uint64 `json:"generation"`
	DocumentID     string `json:"document_id"`
	ApplicationRev uint64 `json:"application_revision"`
	EditorRevision uint64 `json:"editor_revision"`
	StartLine      uint64 `json:"start_line"`
	EndLine        uint64 `json:"end_line"`
	ByteLen        uint64 `json:"byte_len"`
	Truncated      bool   `json:"truncated"`
}

type Outcome struct {
	Code      string `json:"code"`
	Message   string `json:"message,omitempty"`
	Retryable bool   `json:"retryable,omitempty"`
}

type StateEnvelope struct {
	Schema         uint32          `json:"schema"`
	Revision       uint64          `json:"revision"`
	ApplicationRev uint64          `json:"application_revision"`
	HasWorkspace   bool            `json:"has_workspace"`
	WorkspaceRoot  string          `json:"workspace_root,omitempty"`
	Active         string          `json:"active,omitempty"`
	Documents      []StateDocument `json:"documents"`
}

type StateDocument struct {
	ID             string `json:"id"`
	Path           string `json:"path"`
	Status         string `json:"status"`
	Dirty          bool   `json:"dirty"`
	EditorRevision uint64 `json:"editor_revision"`
	Language       string `json:"language,omitempty"`
}

type DirectoryListing struct {
	RelativePath string           `json:"relative_path"`
	Limit        int              `json:"limit"`
	Truncated    bool             `json:"truncated"`
	Entries      []DirectoryEntry `json:"entries"`
}

type DirectoryEntry struct {
	Name string `json:"name"`
	Path string `json:"path"`
	Dir  bool   `json:"dir"`
}

func decodeStartRequest(input []byte) (StartRequest, Response, bool) {
	var request StartRequest
	if response, ok := validateWireInput(input, ""); !ok {
		return request, response, false
	}
	if err := json.Unmarshal(input, &request); err != nil {
		return request, errorResponse(0, "stopped", "malformed_json", fmt.Sprintf("invalid start request JSON: %v", err), false), false
	}
	if response, ok := validateEnvelope(request.Version, request.RequestID, "stopped"); !ok {
		return request, response, false
	}
	if err := validateOptionalPath(request.WorkspacePath, "workspace_path"); err != nil {
		return request, errorResponse(request.RequestID, "stopped", "invalid_path", err.Error(), false), false
	}
	return request, Response{}, true
}

func decodeStopRequest(input []byte, lifecycle string) (StopRequest, Response, bool) {
	var request StopRequest
	if len(input) == 0 {
		return request, Response{Version: ProtocolVersion, Lifecycle: lifecycle, OK: true, Outcome: Outcome{Code: "ok"}}, true
	}
	if response, ok := validateWireInput(input, ""); !ok {
		response.Lifecycle = lifecycle
		return request, response, false
	}
	if err := json.Unmarshal(input, &request); err != nil {
		return request, errorResponse(0, lifecycle, "malformed_json", fmt.Sprintf("invalid stop request JSON: %v", err), false), false
	}
	if response, ok := validateEnvelope(request.Version, request.RequestID, lifecycle); !ok {
		return request, response, false
	}
	return request, Response{}, true
}

func decodeCommandRequest(input []byte, lifecycle string) (CommandRequest, Response, bool) {
	var request CommandRequest
	if response, ok := validateWireInput(input, ""); !ok {
		response.Lifecycle = lifecycle
		return request, response, false
	}
	if err := json.Unmarshal(input, &request); err != nil {
		return request, errorResponse(0, lifecycle, "malformed_json", fmt.Sprintf("invalid command JSON: %v", err), false), false
	}
	if response, ok := validateEnvelope(request.Version, request.RequestID, lifecycle); !ok {
		return request, response, false
	}
	switch request.Command {
	case "snapshot", "ping":
	case "open_path":
		if err := validateRequiredPath(request.Path, "path"); err != nil {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_path", err.Error(), false), false
		}
	case "select_document", "save_document", "close_document":
		if request.DocumentID != "" && !utf8.ValidString(request.DocumentID) {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_document_id", "document_id must be valid UTF-8", false), false
		}
	case "read_visible_lines":
		if request.DocumentID == "" {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_document_id", "document_id is required", false), false
		}
		if !utf8.ValidString(request.DocumentID) {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_document_id", "document_id must be valid UTF-8", false), false
		}
		if request.MaxLines == 0 || request.MaxLines > MaxVisibleLines {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_visible_range", fmt.Sprintf("max_lines must be between 1 and %d", MaxVisibleLines), false), false
		}
		if request.MaxBytes == 0 || request.MaxBytes > MaxVisibleBytes {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_visible_range", fmt.Sprintf("max_bytes must be between 1 and %d", MaxVisibleBytes), false), false
		}
	case "list_directory":
		if err := validateOptionalPath(request.RelativePath, "relative_path"); err != nil {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_path", err.Error(), false), false
		}
		if request.Limit < 0 || request.Limit > MaxListLimit {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_limit", fmt.Sprintf("limit must be between 0 and %d", MaxListLimit), false), false
		}
	default:
		return request, errorResponse(request.RequestID, lifecycle, "unknown_command", fmt.Sprintf("unknown command %q", request.Command), false), false
	}
	return request, Response{}, true
}

// encodeVisibleSlice is an application-owned binary resource format. It is
// deliberately not part of Caliber: Caliber only owns the immutable bytes and
// their lease. Little-endian fields make the format explicit for the Rust
// foreign client while the raw payload preserves documents that are not valid
// UTF-8.
func encodeVisibleSlice(applicationRevision, editorRevision, startLine, endLine uint64, truncated bool, lines []byte) ([]byte, error) {
	if len(lines) > MaxVisibleBytes {
		return nil, fmt.Errorf("visible slice exceeds %d byte limit", MaxVisibleBytes)
	}
	payload := make([]byte, visibleSliceHeaderBytes+len(lines))
	copy(payload[:4], []byte("SPVS"))
	binary.LittleEndian.PutUint32(payload[4:8], VisibleSliceSchemaV1)
	binary.LittleEndian.PutUint64(payload[8:16], applicationRevision)
	binary.LittleEndian.PutUint64(payload[16:24], editorRevision)
	binary.LittleEndian.PutUint64(payload[24:32], startLine)
	binary.LittleEndian.PutUint64(payload[32:40], endLine)
	var flags uint32
	if truncated {
		flags = 1
	}
	binary.LittleEndian.PutUint32(payload[40:44], flags)
	binary.LittleEndian.PutUint32(payload[44:48], uint32(len(lines)))
	copy(payload[visibleSliceHeaderBytes:], lines)
	return payload, nil
}

func validateWireInput(input []byte, lifecycle string) (Response, bool) {
	if len(input) > MaxInputBytes {
		return errorResponse(0, lifecycle, "input_too_large", fmt.Sprintf("input exceeds %d byte limit", MaxInputBytes), false), false
	}
	if !utf8.Valid(input) {
		return errorResponse(0, lifecycle, "invalid_utf8", "input must be valid UTF-8 JSON", false), false
	}
	return Response{}, true
}

func validateEnvelope(version uint32, requestID uint64, lifecycle string) (Response, bool) {
	if version != ProtocolVersion {
		return errorResponse(requestID, lifecycle, "unsupported_version", fmt.Sprintf("version must be %d", ProtocolVersion), false), false
	}
	if requestID == 0 {
		return errorResponse(requestID, lifecycle, "missing_request_id", "request_id must be non-zero", false), false
	}
	return Response{}, true
}

func validateRequiredPath(path, field string) error {
	if strings.TrimSpace(path) == "" {
		return fmt.Errorf("%s is required", field)
	}
	return validateOptionalPath(path, field)
}

func validateOptionalPath(path, field string) error {
	if path == "" {
		return nil
	}
	if !utf8.ValidString(path) || strings.ContainsRune(path, utf8.RuneError) {
		return fmt.Errorf("%s must be valid UTF-8", field)
	}
	if strings.ContainsRune(path, 0) {
		return fmt.Errorf("%s must not contain NUL", field)
	}
	return nil
}

func okResponse(requestID uint64, lifecycle string, revision uint64) Response {
	return Response{
		Version:   ProtocolVersion,
		RequestID: requestID,
		Lifecycle: lifecycle,
		OK:        true,
		Outcome:   Outcome{Code: "ok"},
		Revision:  revision,
	}
}

func errorResponse(requestID uint64, lifecycle, code, message string, retryable bool) Response {
	return Response{
		Version:   ProtocolVersion,
		RequestID: requestID,
		Lifecycle: lifecycle,
		OK:        false,
		Outcome:   Outcome{Code: code, Message: message, Retryable: retryable},
	}
}

func stateFromApplication(revision uint64, snapshot application.PresentationState) StateEnvelope {
	state := StateEnvelope{
		Schema:         StateSchemaV1,
		Revision:       revision,
		ApplicationRev: snapshot.Revision,
		HasWorkspace:   snapshot.HasWorkspace,
		WorkspaceRoot:  snapshot.WorkspaceRoot,
		Active:         string(snapshot.Active),
		Documents:      make([]StateDocument, 0, len(snapshot.Documents)),
	}
	for _, document := range snapshot.Documents {
		state.Documents = append(state.Documents, StateDocument{
			ID:             string(document.ID),
			Path:           document.Path,
			Status:         documentStatusString(document.Status),
			Dirty:          document.Dirty,
			EditorRevision: document.EditorRevision,
			Language:       document.Language,
		})
	}
	return state
}

func directoryListing(relative string, limit int, entries []workspace.Entry) DirectoryListing {
	if limit == 0 {
		limit = DefaultListLimit
	}
	listing := DirectoryListing{
		RelativePath: relative,
		Limit:        limit,
		Truncated:    len(entries) > limit,
		Entries:      make([]DirectoryEntry, 0, min(len(entries), limit)),
	}
	for i, entry := range entries {
		if i >= limit {
			break
		}
		listing.Entries = append(listing.Entries, DirectoryEntry{
			Name: entry.Name,
			Path: entry.Path,
			Dir:  entry.Dir,
		})
	}
	return listing
}

func documentStatusString(status application.DocumentStatus) string {
	switch status {
	case application.StatusSynced:
		return "synced"
	case application.StatusDirty:
		return "dirty"
	case application.StatusConflict:
		return "conflict"
	case application.StatusMissing:
		return "missing"
	default:
		return "unknown"
	}
}

func marshalResponse(response Response) []byte {
	data, err := json.Marshal(response)
	if err != nil {
		fallback := errorResponse(response.RequestID, response.Lifecycle, "internal_error", err.Error(), false)
		data, _ = json.Marshal(fallback)
	}
	return append(data, '\n')
}

func appError(code string, err error) Response {
	if err == nil {
		err = errors.New("unknown error")
	}
	return errorResponse(0, "running", code, err.Error(), false)
}
