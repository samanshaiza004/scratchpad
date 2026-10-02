package backend

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"unicode/utf8"

	"scratchpad/application"
	"scratchpad/commands"
	"scratchpad/workspace"
)

const (
	ProtocolVersion                uint32 = 1
	StateSchemaV1                  uint32 = 1
	MaxInputBytes                         = 1 << 20
	DefaultListLimit                      = 200
	MaxListLimit                          = 1000
	MaxVisibleLines                       = 256
	MaxVisibleBytes                       = 64 * 1024
	MaxVisibleLineChunkBytes              = 16 * 1024
	MaxEditBytes                          = 128 * 1024
	MaxFindMatches                        = 1000
	MaxFindQueryBytes                     = 4096
	WorkspaceSearchQueryMaxBytes          = 4096
	WorkspaceSearchPageSize               = 32
	WorkspaceSearchMaxResults             = 5000
	VisibleSliceSchemaV1                  = 1
	VisibleSliceSchemaV2                  = 2
	visibleSliceHeaderBytes               = 48
	presentationTrailerHeaderBytes        = 24
	presentationRecordBytes               = 16
	MaxPresentationRecords                = 4096
	maxPresentationMetadataBytes          = presentationTrailerHeaderBytes + MaxPresentationRecords*presentationRecordBytes
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
	Version              uint32 `json:"version"`
	RequestID            uint64 `json:"request_id"`
	BasedOnRevision      uint64 `json:"based_on_revision"`
	Command              string `json:"command"`
	ActionID             string `json:"action_id,omitempty"`
	Argument             string `json:"argument,omitempty"`
	Path                 string `json:"path,omitempty"`
	Disposition          string `json:"disposition,omitempty"`
	Name                 string `json:"name,omitempty"`
	DocumentID           string `json:"document_id,omitempty"`
	Discard              bool   `json:"discard,omitempty"`
	RelativePath         string `json:"relative_path,omitempty"`
	Limit                int    `json:"limit,omitempty"`
	StartLine            uint64 `json:"start_line,omitempty"`
	AnchorByte           uint64 `json:"anchor_byte,omitempty"`
	MaxLines             uint64 `json:"max_lines,omitempty"`
	MaxBytes             uint64 `json:"max_bytes,omitempty"`
	IncludePresentation  bool   `json:"include_presentation,omitempty"`
	IncludeIgnored       bool   `json:"include_ignored,omitempty"`
	EditorRevision       uint64 `json:"editor_revision"`
	EditorAnchorByte     uint64 `json:"editor_anchor_byte,omitempty"`
	EditorCursorByte     uint64 `json:"editor_cursor_byte,omitempty"`
	StartByte            uint64 `json:"start_byte,omitempty"`
	EndByte              uint64 `json:"end_byte,omitempty"`
	Replacement          []int  `json:"replacement,omitempty"`
	HasSelectionState    bool   `json:"has_selection_state,omitempty"`
	BeforeAnchorByte     uint64 `json:"before_anchor_byte,omitempty"`
	BeforeCursorByte     uint64 `json:"before_cursor_byte,omitempty"`
	AfterAnchorByte      uint64 `json:"after_anchor_byte,omitempty"`
	AfterCursorByte      uint64 `json:"after_cursor_byte,omitempty"`
	TypingGroupID        uint64 `json:"typing_group_id,omitempty"`
	Query                string `json:"query,omitempty"`
	MaxMatches           int    `json:"max_matches,omitempty"`
	MatchCase            bool   `json:"match_case,omitempty"`
	WholeWord            bool   `json:"whole_word,omitempty"`
	SaveAsToken          uint64 `json:"save_as_token,omitempty"`
	SearchGeneration     uint64 `json:"search_generation,omitempty"`
	HasTargetByte        bool   `json:"has_target_byte,omitempty"`
	TargetByte           uint64 `json:"target_byte,omitempty"`
	HasSourceAnchor      bool   `json:"has_source_anchor,omitempty"`
	SourceAnchorRevision uint64 `json:"source_anchor_revision,omitempty"`
	SourceAnchorByte     uint64 `json:"source_anchor_byte,omitempty"`
	SourceAnchorLine     uint64 `json:"source_anchor_line,omitempty"`
}

type Response struct {
	Version             uint32               `json:"version"`
	RequestID           uint64               `json:"request_id,omitempty"`
	Lifecycle           string               `json:"lifecycle"`
	OK                  bool                 `json:"ok"`
	Outcome             Outcome              `json:"outcome"`
	Revision            uint64               `json:"revision,omitempty"`
	BasedOnRevision     uint64               `json:"based_on_revision,omitempty"`
	State               *StateEnvelope       `json:"state,omitempty"`
	DirectoryListing    *DirectoryListing    `json:"directory_listing,omitempty"`
	WorkspaceFiles      *WorkspaceFiles      `json:"workspace_files,omitempty"`
	Resource            *ResourceDescriptor  `json:"resource,omitempty"`
	Edit                *EditAck             `json:"edit,omitempty"`
	EditorSelection     *EditorSelection     `json:"editor_selection,omitempty"`
	CommandOutcome      string               `json:"command_outcome,omitempty"`
	CloseDecision       *CloseDecision       `json:"close_decision,omitempty"`
	Matches             []CurrentMatch       `json:"matches,omitempty"`
	MatchesTruncated    bool                 `json:"matches_truncated,omitempty"`
	MatchesReplaced     int                  `json:"matches_replaced,omitempty"`
	SourceRefreshNeeded bool                 `json:"source_refresh_needed,omitempty"`
	WorkspaceSearchPage *WorkspaceSearchPage `json:"workspace_search_page,omitempty"`
	SaveAsConflict      *SaveAsConflict      `json:"save_as_conflict,omitempty"`
	Diagnostic          string               `json:"diagnostic,omitempty"`
}

// SaveAsConflict carries an opaque, one-shot confirmation token. The
// destination's verified disk version stays backend-owned until confirmation.
type SaveAsConflict struct {
	Token uint64 `json:"token"`
	Path  string `json:"path"`
}

const (
	CommandOutcomeExecutedEdit  = "executed_edit"
	CommandOutcomeSelectionOnly = "selection_only"
	CommandOutcomeNoOp          = "no_op"
	CommandOutcomeUnavailable   = "unavailable"
	CommandOutcomeFailed        = "failed"
)

type ResourceDescriptor struct {
	ResourceID       uint64 `json:"resource_id"`
	Generation       uint64 `json:"generation"`
	DocumentID       string `json:"document_id"`
	ApplicationRev   uint64 `json:"application_revision"`
	EditorRevision   uint64 `json:"editor_revision"`
	StartLine        uint64 `json:"start_line"`
	EndLine          uint64 `json:"end_line"`
	ByteLen          uint64 `json:"byte_len"`
	Truncated        bool   `json:"truncated"`
	StartByte        uint64 `json:"start_byte"`
	LineByteLength   uint64 `json:"line_byte_length,omitempty"`
	MetadataByteLen  uint64 `json:"metadata_byte_len,omitempty"`
	HasSourceAnchor  bool   `json:"has_source_anchor,omitempty"`
	SourceAnchorByte uint64 `json:"source_anchor_byte,omitempty"`
	SourceAnchorLine uint64 `json:"source_anchor_line,omitempty"`
}

type EditAck struct {
	DocumentID         string `json:"document_id"`
	EditorRevision     uint64 `json:"editor_revision"`
	StartByte          uint64 `json:"start_byte"`
	OldEndByte         uint64 `json:"old_end_byte"`
	NewEndByte         uint64 `json:"new_end_byte"`
	AppliedReplacement []int  `json:"applied_replacement,omitempty"`
}

// EditorSelection is returned after authoritative undo/redo so a foreign
// frontend can restore the editor-owned caret/selection without mirroring the
// application's undo stack or sending ordinary cursor motion over Caliber.
type EditorSelection struct {
	DocumentID     string `json:"document_id"`
	EditorRevision uint64 `json:"editor_revision"`
	AnchorByte     uint64 `json:"anchor_byte"`
	CursorByte     uint64 `json:"cursor_byte"`
	CursorLine     uint64 `json:"cursor_line"`
}

// CloseDecision describes an application-owned close that needs an explicit
// frontend decision.  The frontend may present save/discard/cancel controls,
// but the application remains authoritative for the dirty check and the
// eventual save/close commands.
type CloseDecision struct {
	DocumentID string `json:"document_id"`
	Dirty      bool   `json:"dirty"`
	CanSave    bool   `json:"can_save"`
	CanDiscard bool   `json:"can_discard"`
}

// CurrentMatch is a bounded, application-owned search result. Offsets are
// source byte offsets so a frontend can keep raw-byte coordinates without
// materializing or owning the document.
type CurrentMatch struct {
	Start  int `json:"start"`
	End    int `json:"end"`
	Line   int `json:"line"`
	Column int `json:"column"`
}

type WorkspaceSearchResult struct {
	Path          string `json:"path"`
	Line          int    `json:"line"`
	Column        int    `json:"column"`
	StartByte     int    `json:"start_byte"`
	EndByte       int    `json:"end_byte"`
	Text          string `json:"text"`
	TextTruncated bool   `json:"text_truncated,omitempty"`
}

type WorkspaceSearchPage struct {
	Generation uint64                  `json:"generation"`
	Sequence   uint64                  `json:"sequence"`
	Count      uint64                  `json:"count"`
	Done       bool                    `json:"done"`
	Truncated  bool                    `json:"truncated"`
	Results    []WorkspaceSearchResult `json:"results"`
}

type Outcome struct {
	Code      string `json:"code"`
	Message   string `json:"message,omitempty"`
	Retryable bool   `json:"retryable,omitempty"`
}

type StateEnvelope struct {
	Schema                       uint32          `json:"schema"`
	Revision                     uint64          `json:"revision"`
	ApplicationRev               uint64          `json:"application_revision"`
	HasWorkspace                 bool            `json:"has_workspace"`
	WorkspaceRoot                string          `json:"workspace_root,omitempty"`
	Active                       string          `json:"active,omitempty"`
	StartupNotice                string          `json:"startup_notice,omitempty"`
	Documents                    []StateDocument `json:"documents"`
	Actions                      []ActionState   `json:"actions,omitempty"`
	WorkspaceSearchGeneration    uint64          `json:"workspace_search_generation,omitempty"`
	WorkspaceSearchSequence      uint64          `json:"workspace_search_sequence,omitempty"`
	WorkspaceSearchCount         uint64          `json:"workspace_search_count,omitempty"`
	WorkspaceSearchPageAvailable bool            `json:"workspace_search_page_available,omitempty"`
	WorkspaceSearchDone          bool            `json:"workspace_search_done,omitempty"`
	WorkspaceSearchTruncated     bool            `json:"workspace_search_truncated,omitempty"`
}

// ActionState publishes the canonical Scratchpad command vocabulary to any
// frontend. ID remains the product identity; a presentation may map it to a
// host-local numeric action token without creating another command namespace.
type ActionState struct {
	ID       string   `json:"id"`
	Title    string   `json:"title"`
	Category string   `json:"category"`
	Bindings []string `json:"bindings,omitempty"`
	Visible  bool     `json:"visible"`
	Enabled  bool     `json:"enabled"`
	Checked  bool     `json:"checked"`
}

type StateDocument struct {
	ID                   string `json:"id"`
	Path                 string `json:"path"`
	Status               string `json:"status"`
	Dirty                bool   `json:"dirty"`
	Preview              bool   `json:"preview,omitempty"`
	EditorRevision       uint64 `json:"editor_revision"`
	ByteLength           uint64 `json:"byte_length"`
	LineCount            uint64 `json:"line_count"`
	CanUndo              bool   `json:"can_undo"`
	CanRedo              bool   `json:"can_redo"`
	Language             string `json:"language,omitempty"`
	PresentationRevision uint64 `json:"presentation_revision,omitempty"`
	PresentationReady    bool   `json:"presentation_ready,omitempty"`
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

// WorkspaceFiles is the bounded, path-only candidate set used by frontend
// Quick Open. File bytes remain in the authoritative document/editor path.
type WorkspaceFiles struct {
	Paths     []string `json:"paths"`
	Truncated bool     `json:"truncated"`
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
	if request.Disposition != "" && request.Command != "open_path" {
		return request, errorResponse(request.RequestID, lifecycle, "invalid_disposition", "disposition is only valid for open_path", false), false
	}
	if request.Argument != "" && (request.Command != "execute_command" || request.ActionID != string(commands.MarkdownSmartPaste)) {
		return request, errorResponse(request.RequestID, lifecycle, "invalid_argument", "argument is only valid for Markdown smart paste", false), false
	}
	if len(request.Argument) > MaxEditBytes {
		return request, errorResponse(request.RequestID, lifecycle, "argument_too_large", fmt.Sprintf("argument exceeds %d bytes", MaxEditBytes), false), false
	}
	switch request.Command {
	case "snapshot", "ping", "refresh_workspace", "list_workspace_files":
	case "save_as_document":
		if err := validateRequiredPath(request.Path, "path"); err != nil {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_path", err.Error(), false), false
		}
		if request.DocumentID == "" || !utf8.ValidString(request.DocumentID) {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_document_id", "a valid document_id is required", false), false
		}
	case "confirm_save_as", "cancel_save_as":
		if request.DocumentID == "" || !utf8.ValidString(request.DocumentID) {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_document_id", "a valid document_id is required", false), false
		}
		if request.SaveAsToken == 0 {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_save_as_token", "save_as_token is required", false), false
		}
	case "create_file", "create_folder", "trash_path":
		if err := validateRequiredPath(request.Path, "path"); err != nil {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_path", err.Error(), false), false
		}
	case "rename_path":
		if err := validateRequiredPath(request.Path, "path"); err != nil {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_path", err.Error(), false), false
		}
		if err := validateRequiredPath(request.Name, "name"); err != nil {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_name", err.Error(), false), false
		}
	case "move_path":
		if err := validateRequiredPath(request.Path, "path"); err != nil {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_path", err.Error(), false), false
		}
		if err := validateRequiredPath(request.RelativePath, "relative_path"); err != nil {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_path", err.Error(), false), false
		}
	case "open_path":
		if err := validateRequiredPath(request.Path, "path"); err != nil {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_path", err.Error(), false), false
		}
		if request.HasTargetByte && request.TargetByte > uint64(^uint(0)>>1) {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_target_byte", "target_byte does not fit the host word size", false), false
		}
		if request.Disposition != "" && request.Disposition != "preview" {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_disposition", "open_path disposition must be empty or preview", false), false
		}
	case "select_document", "save_document", "close_document", "reload_conflict", "keep_mine_conflict", string(commands.EditUndo), string(commands.EditRedo):
		if request.DocumentID != "" && !utf8.ValidString(request.DocumentID) {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_document_id", "document_id must be valid UTF-8", false), false
		}
		if (request.Command == "reload_conflict" || request.Command == "keep_mine_conflict") && request.DocumentID == "" {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_document_id", "document_id is required", false), false
		}
	case "replace_document", "find_replace_current", "find_replace_all", "paste_document":
		if request.DocumentID == "" {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_document_id", "document_id is required", false), false
		}
		if !utf8.ValidString(request.DocumentID) {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_document_id", "document_id must be valid UTF-8", false), false
		}
		if request.EndByte < request.StartByte {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_edit_range", "end_byte must not precede start_byte", false), false
		}
		if request.StartByte > uint64(^uint(0)>>1) || request.EndByte > uint64(^uint(0)>>1) {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_edit_range", "edit range does not fit the host word size", false), false
		}
		if request.HasSelectionState && (request.BeforeAnchorByte > uint64(^uint(0)>>1) || request.BeforeCursorByte > uint64(^uint(0)>>1) || request.AfterAnchorByte > uint64(^uint(0)>>1) || request.AfterCursorByte > uint64(^uint(0)>>1)) {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_edit_selection", "edit selection does not fit the host word size", false), false
		}
		if request.TypingGroupID != 0 && !request.HasSelectionState {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_edit_intent", "typing transactions require an explicit selection snapshot", false), false
		}
		if len(request.Replacement) > MaxEditBytes {
			return request, errorResponse(request.RequestID, lifecycle, "edit_too_large", fmt.Sprintf("replacement exceeds %d bytes", MaxEditBytes), false), false
		}
		for _, value := range request.Replacement {
			if value < 0 || value > 255 {
				return request, errorResponse(request.RequestID, lifecycle, "invalid_edit_bytes", "replacement values must be bytes", false), false
			}
		}
		if request.Command == "find_replace_current" || request.Command == "find_replace_all" {
			if len(request.Query) == 0 {
				return request, errorResponse(request.RequestID, lifecycle, "invalid_query", "Find replacement requires a non-empty query", false), false
			}
			if len(request.Query) > MaxFindQueryBytes {
				return request, errorResponse(request.RequestID, lifecycle, "query_too_large", fmt.Sprintf("query exceeds %d bytes", MaxFindQueryBytes), false), false
			}
			if strings.ContainsRune(request.Query, 0) {
				return request, errorResponse(request.RequestID, lifecycle, "invalid_query", "query must not contain NUL", false), false
			}
		}
		if request.Command == "paste_document" && !request.HasSelectionState {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_edit_selection", "paste requires the current selection snapshot", false), false
		}
	case "execute_command":
		if request.DocumentID == "" || !utf8.ValidString(request.DocumentID) {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_document_id", "a valid document_id is required", false), false
		}
		if request.ActionID == "" || !utf8.ValidString(request.ActionID) || strings.ContainsRune(request.ActionID, 0) {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_action_id", "a valid action_id is required", false), false
		}
		if !jsonFieldPresent(input, "editor_revision") {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_editor_revision", "editor_revision is required", false), false
		}
		if request.EditorAnchorByte > uint64(^uint(0)>>1) || request.EditorCursorByte > uint64(^uint(0)>>1) {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_editor_selection", "editor selection does not fit the host word size", false), false
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
		if request.StartLine > uint64(^uint(0)>>1) || request.AnchorByte > uint64(^uint(0)>>1) {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_visible_range", "visible line or byte anchor does not fit the host word size", false), false
		}
		if request.HasSourceAnchor && (request.SourceAnchorRevision == 0 || request.SourceAnchorByte > uint64(^uint(0)>>1) || request.SourceAnchorLine > uint64(^uint(0)>>1)) {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_source_anchor", "source anchor revision, byte, or line is invalid", false), false
		}
	case "list_directory":
		if err := validateOptionalPath(request.RelativePath, "relative_path"); err != nil {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_path", err.Error(), false), false
		}
		if request.Limit < 0 || request.Limit > MaxListLimit {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_limit", fmt.Sprintf("limit must be between 0 and %d", MaxListLimit), false), false
		}
	case "find_current":
		if len(request.Query) > MaxFindQueryBytes {
			return request, errorResponse(request.RequestID, lifecycle, "query_too_large", fmt.Sprintf("query exceeds %d bytes", MaxFindQueryBytes), false), false
		}
		if request.DocumentID == "" {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_document_id", "document_id is required", false), false
		}
		if !utf8.ValidString(request.DocumentID) {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_document_id", "document_id must be valid UTF-8", false), false
		}
		if strings.ContainsRune(request.Query, 0) {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_query", "query must not contain NUL", false), false
		}
		if request.MaxMatches < 0 || request.MaxMatches > MaxFindMatches {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_limit", fmt.Sprintf("max_matches must be between 0 and %d", MaxFindMatches), false), false
		}
	case "workspace_search_start":
		if request.SearchGeneration == 0 {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_search_generation", "search_generation must be nonzero", false), false
		}
		if len(request.Query) > WorkspaceSearchQueryMaxBytes {
			return request, errorResponse(request.RequestID, lifecycle, "query_too_large", fmt.Sprintf("query exceeds %d bytes", WorkspaceSearchQueryMaxBytes), false), false
		}
		if strings.ContainsRune(request.Query, 0) {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_query", "query must not contain NUL", false), false
		}
	case "workspace_search_cancel", "workspace_search_take_page":
		if request.SearchGeneration == 0 {
			return request, errorResponse(request.RequestID, lifecycle, "invalid_search_generation", "search_generation must be nonzero", false), false
		}
	default:
		return request, errorResponse(request.RequestID, lifecycle, "unknown_command", fmt.Sprintf("unknown command %q", request.Command), false), false
	}
	return request, Response{}, true
}

func jsonFieldPresent(input []byte, name string) bool {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(input, &fields); err != nil {
		return false
	}
	_, present := fields[name]
	return present
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

type presentationWireRecord struct {
	kind       uint32
	start, end uint32
	levelFlags uint32
}

const (
	presentationReadyFlag     uint32 = 1
	presentationTruncatedFlag uint32 = 2
	blockClippedStartFlag     uint32 = 1 << 8
	blockClippedEndFlag       uint32 = 1 << 9
	blockWireKindBase         uint32 = 0x10000
)

func encodeVisibleSliceV2(applicationRevision, editorRevision, startLine, endLine uint64, truncated bool, lines []byte, presentationRevision uint64, ready, metadataTruncated bool, spans, blocks []presentationWireRecord) ([]byte, error) {
	if len(lines) > MaxVisibleBytes {
		return nil, fmt.Errorf("visible slice exceeds %d byte limit", MaxVisibleBytes)
	}
	if len(spans)+len(blocks) > MaxPresentationRecords {
		return nil, fmt.Errorf("presentation metadata exceeds %d record limit", MaxPresentationRecords)
	}
	if ready && presentationRevision != editorRevision {
		return nil, errors.New("ready presentation revision does not match editor revision")
	}
	for _, record := range spans {
		if record.kind < 1 || record.kind > 33 || record.start >= record.end || uint64(record.end) > uint64(len(lines)) || record.levelFlags > 0xff {
			return nil, errors.New("invalid presentation span record")
		}
	}
	for _, record := range blocks {
		if record.kind < blockWireKindBase+1 || record.kind > blockWireKindBase+5 || record.start >= record.end || uint64(record.end) > uint64(len(lines)) || record.levelFlags & ^uint32(0x3ff) != 0 {
			return nil, errors.New("invalid presentation block record")
		}
	}
	if !ready && (len(spans) != 0 || len(blocks) != 0) {
		return nil, errors.New("pending presentation cannot contain records")
	}
	metadataLen := presentationTrailerHeaderBytes + (len(spans)+len(blocks))*presentationRecordBytes
	if metadataLen > maxPresentationMetadataBytes {
		return nil, fmt.Errorf("presentation metadata exceeds %d byte limit", maxPresentationMetadataBytes)
	}
	payload := make([]byte, visibleSliceHeaderBytes+len(lines)+metadataLen)
	copy(payload[:4], []byte("SPVS"))
	binary.LittleEndian.PutUint32(payload[4:8], VisibleSliceSchemaV2)
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
	trailer := payload[visibleSliceHeaderBytes+len(lines):]
	binary.LittleEndian.PutUint64(trailer[0:8], presentationRevision)
	var presentationFlags uint32
	if ready {
		presentationFlags |= presentationReadyFlag
	}
	if metadataTruncated {
		presentationFlags |= presentationTruncatedFlag
	}
	binary.LittleEndian.PutUint32(trailer[8:12], presentationFlags)
	binary.LittleEndian.PutUint32(trailer[12:16], uint32(len(spans)))
	binary.LittleEndian.PutUint32(trailer[16:20], uint32(len(blocks)))
	// trailer[20:24] is reserved and remains zero.
	at := presentationTrailerHeaderBytes
	for _, group := range [][]presentationWireRecord{spans, blocks} {
		for _, record := range group {
			binary.LittleEndian.PutUint32(trailer[at:at+4], record.kind)
			binary.LittleEndian.PutUint32(trailer[at+4:at+8], record.start)
			binary.LittleEndian.PutUint32(trailer[at+8:at+12], record.end)
			binary.LittleEndian.PutUint32(trailer[at+12:at+16], record.levelFlags)
			at += presentationRecordBytes
		}
	}
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

func stateFromApplication(revision uint64, snapshot application.PresentationState, includePresentation ...bool) StateEnvelope {
	presentationEnabled := len(includePresentation) > 0 && includePresentation[0]
	commandContext := commands.CommandContext{
		ActiveDocument: snapshot.Active != "",
		EditorFocused:  snapshot.Active != "",
		HasWorkspace:   snapshot.HasWorkspace,
		HasTrasher:     snapshot.HasTrasher,
		DocumentCount:  len(snapshot.Documents),
	}
	state := StateEnvelope{
		Schema:         StateSchemaV1,
		Revision:       revision,
		ApplicationRev: snapshot.Revision,
		HasWorkspace:   snapshot.HasWorkspace,
		WorkspaceRoot:  snapshot.WorkspaceRoot,
		Active:         string(snapshot.Active),
		Documents:      make([]StateDocument, 0, len(snapshot.Documents)),
		Actions:        make([]ActionState, 0, len(shellActionIDs)),
	}
	for _, document := range snapshot.Documents {
		stateDocument := StateDocument{
			ID:             string(document.ID),
			Path:           document.Path,
			Status:         documentStatusString(document.Status),
			Dirty:          document.Dirty,
			Preview:        document.Preview,
			EditorRevision: document.EditorRevision,
			ByteLength:     document.ByteLength,
			LineCount:      document.LineCount,
			CanUndo:        document.CanUndo,
			CanRedo:        document.CanRedo,
			Language:       document.Language,
		}
		if presentationEnabled {
			stateDocument.PresentationRevision = document.PresentationRevision
			stateDocument.PresentationReady = document.PresentationReady
		}
		state.Documents = append(state.Documents, stateDocument)
		if document.ID == snapshot.Active {
			commandContext.CanUndo = document.CanUndo
			commandContext.CanRedo = document.CanRedo
			commandContext.RootLanguage = document.Language
			commandContext.Markdown = document.Language == "markdown"
			commandContext.Code = document.Language != "markdown"
		}
	}
	registry := commands.DefaultRegistry()
	for _, id := range shellActionIDs {
		descriptor, found := registry.Lookup(id)
		if !found {
			continue
		}
		bindings := make([]string, 0, len(descriptor.Bindings))
		for _, binding := range descriptor.Bindings {
			bindings = append(bindings, binding.Key)
		}
		state.Actions = append(state.Actions, ActionState{
			ID:       string(descriptor.ID),
			Title:    descriptor.Title,
			Category: descriptor.Category,
			Bindings: bindings,
			Visible:  descriptor.IsVisible(commandContext),
			Enabled:  descriptor.IsEnabled(commandContext),
		})
	}
	return state
}

var shellActionIDs = []commands.ID{
	commands.FileOpen,
	commands.QuickOpen,
	commands.WorkspaceOpen,
	commands.FileSave,
	commands.DocumentClose,
	commands.EditUndo,
	commands.EditRedo,
	commands.TabNext,
	commands.TabPrevious,
	commands.WorkspaceRefresh,
	commands.WorkspaceNewFile,
	commands.WorkspaceNewFolder,
	commands.WorkspaceRename,
	commands.WorkspaceMove,
	commands.WorkspaceTrash,
	commands.DocumentFormat,
	commands.EditIndentLines,
	commands.EditOutdentLines,
	commands.EditDeleteLine,
	commands.EditInsertLineAbove,
	commands.EditInsertLineBelow,
	commands.EditMoveLineUp,
	commands.EditMoveLineDown,
	commands.EditDuplicateLine,
	commands.EditJoinLines,
	commands.CommentToggle,
	commands.ItemToggle,
	commands.MarkdownToggleStrong,
	commands.MarkdownToggleEmphasis,
	commands.MarkdownToggleStrike,
	commands.MarkdownToggleInlineCode,
	commands.MarkdownInsertLink,
	commands.MarkdownHeading1,
	commands.MarkdownHeading2,
	commands.MarkdownHeading3,
	commands.MarkdownToggleBulletedList,
	commands.MarkdownToggleNumberedList,
	commands.MarkdownToggleQuote,
	commands.MarkdownInsertTask,
	commands.MarkdownInsertCodeBlock,
	commands.MarkdownSetFenceLanguage,
	commands.MarkdownInsertTable,
	commands.MarkdownTableNext,
	commands.MarkdownTablePrevious,
	commands.MarkdownTableEnter,
	commands.MarkdownInsertDivider,
	commands.MarkdownSmartPaste,
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
