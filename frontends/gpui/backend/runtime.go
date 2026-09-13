package backend

import (
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"unicode/utf8"
	"unsafe"

	"scratchpad/application"
)

const (
	lifecycleStopped = "stopped"
	lifecycleRunning = "running"
)

type Runtime struct {
	mu                  sync.Mutex
	lifecycle           string
	caliber             *caliberRuntime
	app                 *application.Application
	revision            uint64
	applicationRevision uint64
	state               StateEnvelope
	stateLeases         int
	resourceLeases      int
}

func NewRuntime() *Runtime {
	return &Runtime{lifecycle: lifecycleStopped}
}

func (r *Runtime) Start(input []byte) []byte {
	r.mu.Lock()
	defer r.mu.Unlock()

	request, response, ok := decodeStartRequest(input)
	if !ok {
		return marshalResponse(response)
	}
	if r.lifecycle == lifecycleRunning {
		return marshalResponse(errorResponse(request.RequestID, r.lifecycle, "already_running", "backend is already running", false))
	}
	caliber, err := loadCaliber()
	if err != nil {
		return marshalResponse(errorResponse(request.RequestID, lifecycleStopped, "caliber_unavailable", err.Error(), true))
	}
	app := application.New(nil)
	if request.WorkspacePath != "" {
		if err := app.OpenWorkspace(request.WorkspacePath); err != nil {
			caliber.close()
			return marshalResponse(errorResponse(request.RequestID, lifecycleStopped, "application_error", err.Error(), false))
		}
	}
	r.caliber = caliber
	r.app = app
	r.lifecycle = lifecycleRunning
	r.revision = 0
	r.applicationRevision = 0
	r.state = StateEnvelope{}
	r.stateLeases = 0
	r.resourceLeases = 0
	if err := r.publishApplicationState(); err != nil {
		r.caliber.close()
		r.caliber = nil
		r.app = nil
		r.lifecycle = lifecycleStopped
		return marshalResponse(errorResponse(request.RequestID, lifecycleStopped, "caliber_error", err.Error(), true))
	}
	response = okResponse(request.RequestID, r.lifecycle, r.revision)
	return marshalResponse(response)
}

func (r *Runtime) Stop(input []byte) []byte {
	r.mu.Lock()
	defer r.mu.Unlock()

	request, response, ok := decodeStopRequest(input, r.lifecycle)
	if !ok {
		return marshalResponse(response)
	}
	if r.lifecycle == lifecycleStopped {
		return marshalResponse(errorResponse(request.RequestID, lifecycleStopped, "already_stopped", "backend is already stopped", false))
	}
	if r.stateLeases != 0 {
		return marshalResponse(errorResponse(request.RequestID, r.lifecycle, "outstanding_state_leases", fmt.Sprintf("cannot stop with %d outstanding state lease(s)", r.stateLeases), false))
	}
	if r.resourceLeases != 0 {
		return marshalResponse(errorResponse(request.RequestID, r.lifecycle, "outstanding_resource_leases", fmt.Sprintf("cannot stop with %d outstanding resource lease(s)", r.resourceLeases), false))
	}
	r.caliber.close()
	r.caliber = nil
	r.app = nil
	r.lifecycle = lifecycleStopped
	r.revision = 0
	r.applicationRevision = 0
	r.state = StateEnvelope{}
	r.stateLeases = 0
	r.resourceLeases = 0
	return marshalResponse(Response{
		Version:   ProtocolVersion,
		RequestID: request.RequestID,
		Lifecycle: lifecycleStopped,
		OK:        true,
		Outcome:   Outcome{Code: "ok"},
	})
}

// AcquireLatestState records a state lease owned by the foreign client. The
// caller must release it with ReleaseState before requesting shutdown.
func (r *Runtime) AcquireLatestState() (caliberStateLease, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.lifecycle != lifecycleRunning {
		return caliberStateLease{}, errors.New("backend is not running")
	}
	lease, err := r.caliber.acquireLatestStateForTest()
	if err != nil {
		return caliberStateLease{}, err
	}
	r.stateLeases++
	return lease, nil
}

// ReleaseState releases one foreign state lease. Double release is rejected
// by the Caliber lease itself and does not decrement the accounting twice.
func (r *Runtime) ReleaseState(lease *caliberStateLease) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if lease == nil || lease.lease == nil {
		return errors.New("state lease is already released")
	}
	if r.caliber == nil {
		return errors.New("backend is not running")
	}
	r.caliber.releaseStateForTest(*lease)
	lease.Data = nil
	lease.Len = 0
	lease.lease = nil
	if r.stateLeases > 0 {
		r.stateLeases--
	}
	return nil
}

func (r *Runtime) NoteStateLeaseAcquired() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.lifecycle != lifecycleRunning {
		return errors.New("backend is not running")
	}
	r.stateLeases++
	return nil
}

func (r *Runtime) NoteStateLeaseReleased() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.stateLeases == 0 {
		return errors.New("no outstanding state lease")
	}
	r.stateLeases--
	return nil
}

// NoteResourceLeaseAcquired records the short-lived mapped-resource lease
// owned by the foreign client. The resource bytes may be copied and used only
// until the matching release notification.
func (r *Runtime) NoteResourceLeaseAcquired() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.lifecycle != lifecycleRunning {
		return errors.New("backend is not running")
	}
	r.resourceLeases++
	return nil
}

// NoteResourceLeaseReleased is deterministic: a release without a matching
// acquisition is rejected and does not underflow the accounting.
func (r *Runtime) NoteResourceLeaseReleased() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.resourceLeases == 0 {
		return errors.New("no outstanding resource lease")
	}
	r.resourceLeases--
	return nil
}

func (r *Runtime) Pump() []byte {
	r.mu.Lock()
	defer r.mu.Unlock()

	if r.lifecycle != lifecycleRunning {
		return marshalResponse(errorResponse(0, lifecycleStopped, "not_running", "backend is not running", false))
	}
	commandBytes, err := r.caliber.takeCommand()
	if err != nil {
		if errors.Is(err, errNoCommand) {
			return marshalResponse(errorResponse(0, r.lifecycle, "no_command", "no pending Caliber command", true))
		}
		return marshalResponse(errorResponse(0, r.lifecycle, "caliber_error", err.Error(), true))
	}
	request, response, ok := decodeCommandRequest(commandBytes, r.lifecycle)
	if !ok {
		return marshalResponse(response)
	}
	response.BasedOnRevision = request.BasedOnRevision
	if request.BasedOnRevision != 0 && request.BasedOnRevision != r.applicationRevision {
		response = errorResponse(request.RequestID, r.lifecycle, "stale_revision", fmt.Sprintf("based_on_revision %d does not match current application revision %d", request.BasedOnRevision, r.applicationRevision), false)
		response.BasedOnRevision = request.BasedOnRevision
		response.Revision = r.revision
		return marshalResponse(response)
	}
	response = r.applyCommand(request)
	return marshalResponse(response)
}

func (r *Runtime) CaliberAPIPointer() unsafe.Pointer {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.lifecycle != lifecycleRunning {
		return nil
	}
	return r.caliber.apiPointer()
}

func (r *Runtime) CaliberContextPointer() unsafe.Pointer {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.lifecycle != lifecycleRunning {
		return nil
	}
	return r.caliber.contextPointer()
}

func (r *Runtime) applyCommand(request CommandRequest) Response {
	var listing *DirectoryListing
	var edit *EditAck
	switch request.Command {
	case "ping", "snapshot":
	case "open_path":
		if err := r.app.Dispatch(application.PresentationCommand{
			Kind: application.PresentationOpenPath,
			Path: request.Path,
		}); err != nil {
			return commandError(request, "application_error", err)
		}
	case "select_document":
		if err := r.app.Dispatch(application.PresentationCommand{
			Kind:       application.PresentationSelectDocument,
			DocumentID: application.DocumentID(request.DocumentID),
		}); err != nil {
			return commandError(request, "application_error", err)
		}
	case "save_document":
		if err := r.app.Dispatch(application.PresentationCommand{
			Kind:       application.PresentationSaveDocument,
			DocumentID: application.DocumentID(request.DocumentID),
		}); err != nil {
			return commandError(request, "application_error", err)
		}
	case "close_document":
		if err := r.app.Dispatch(application.PresentationCommand{
			Kind:       application.PresentationCloseDocument,
			DocumentID: application.DocumentID(request.DocumentID),
			Discard:    request.Discard,
		}); err != nil {
			return commandError(request, "application_error", err)
		}
	case "replace_document":
		replacement := make([]byte, len(request.Replacement))
		for i, value := range request.Replacement {
			replacement[i] = byte(value)
		}
		if err := r.app.Dispatch(application.PresentationCommand{
			Kind:           application.PresentationReplaceDocument,
			DocumentID:     application.DocumentID(request.DocumentID),
			EditorRevision: request.EditorRevision,
			StartByte:      int(request.StartByte),
			EndByte:        int(request.EndByte),
			Replacement:    replacement,
		}); err != nil {
			if errors.Is(err, application.ErrStaleEditorRevision) {
				return commandError(request, "stale_editor_revision", err)
			}
			return commandError(request, "application_error", err)
		}
		doc := r.app.Documents[application.DocumentID(request.DocumentID)]
		edit = &EditAck{
			DocumentID:     request.DocumentID,
			EditorRevision: doc.Revision(),
			StartByte:      request.StartByte,
			OldEndByte:     request.EndByte,
			NewEndByte:     request.StartByte + uint64(len(replacement)),
		}
	case "list_directory":
		if !r.app.HasWorkspace {
			return commandError(request, "no_workspace", errors.New("no workspace is open"))
		}
		entries, err := r.app.Workspace.List(request.RelativePath)
		if err != nil {
			return commandError(request, "application_error", err)
		}
		value := directoryListing(request.RelativePath, request.Limit, entries)
		if err := validateDirectoryListing(value); err != nil {
			return commandError(request, "invalid_path", err)
		}
		listing = &value
	case "read_visible_lines":
		response, err := r.readVisibleLines(request)
		if err != nil {
			return commandError(request, "application_error", err)
		}
		return response
	default:
		return commandError(request, "unknown_command", fmt.Errorf("unknown command %q", request.Command))
	}
	if err := r.publishApplicationState(); err != nil {
		return commandError(request, "caliber_error", err)
	}
	response := okResponse(request.RequestID, r.lifecycle, r.revision)
	response.BasedOnRevision = request.BasedOnRevision
	response.DirectoryListing = listing
	response.Edit = edit
	return response
}

func (r *Runtime) readVisibleLines(request CommandRequest) (Response, error) {
	doc, ok := r.app.Documents[application.DocumentID(request.DocumentID)]
	if !ok || doc == nil || doc.Editor == nil {
		return Response{}, errors.New("unknown document")
	}
	lineCount := doc.Editor.Buffer.LineCount()
	if request.StartLine >= uint64(lineCount) {
		return Response{}, fmt.Errorf("start_line %d is outside the document's %d lines", request.StartLine, lineCount)
	}

	lines, startByte, endLine, truncated, err := doc.Editor.Buffer.BoundedLines(
		int(request.StartLine),
		int(request.MaxLines),
		int(request.MaxBytes),
	)
	if err != nil {
		return Response{}, err
	}
	payload, err := encodeVisibleSlice(r.applicationRevision, doc.Revision(), request.StartLine, uint64(endLine), truncated, lines)
	if err != nil {
		return Response{}, err
	}
	resourceID, generation, err := r.caliber.publishResource(payload)
	if err != nil {
		return Response{}, err
	}
	response := okResponse(request.RequestID, r.lifecycle, r.revision)
	response.BasedOnRevision = request.BasedOnRevision
	response.Resource = &ResourceDescriptor{
		ResourceID:     resourceID,
		Generation:     generation,
		DocumentID:     request.DocumentID,
		ApplicationRev: r.applicationRevision,
		EditorRevision: doc.Revision(),
		StartLine:      request.StartLine,
		EndLine:        uint64(endLine),
		ByteLen:        uint64(len(lines)),
		Truncated:      truncated,
		StartByte:      uint64(startByte),
	}
	return response, nil
}

func commandError(request CommandRequest, code string, err error) Response {
	response := errorResponse(request.RequestID, lifecycleRunning, code, err.Error(), false)
	response.BasedOnRevision = request.BasedOnRevision
	return response
}

func (r *Runtime) publishApplicationState() error {
	snapshot := r.app.Snapshot()
	state := stateFromApplication(r.revision+1, snapshot)
	if err := validateStatePaths(state); err != nil {
		return err
	}
	payload, err := json.Marshal(state)
	if err != nil {
		return err
	}
	revision, err := r.caliber.publishState(payload)
	if err != nil {
		return err
	}
	// Caliber has copied the bounded payload by this point. The foreign client
	// owns the read lease and validates the table/state schema on its side, so
	// do not perform an extra Go read/copy/unmarshal merely to echo our own
	// publication back into the runtime.
	state.Revision = revision
	r.revision = revision
	r.applicationRevision = snapshot.Revision
	r.state = state
	return nil
}

func validateDirectoryListing(listing DirectoryListing) error {
	if !utf8.ValidString(listing.RelativePath) {
		return errors.New("relative_path contains invalid UTF-8")
	}
	for _, entry := range listing.Entries {
		if !utf8.ValidString(entry.Name) || !utf8.ValidString(entry.Path) {
			return errors.New("directory entry contains invalid UTF-8")
		}
	}
	return nil
}

func validateStatePaths(state StateEnvelope) error {
	values := []string{state.WorkspaceRoot, state.Active}
	for _, document := range state.Documents {
		values = append(values, document.ID, document.Path, document.Status, document.Language)
	}
	for _, value := range values {
		if !utf8.ValidString(value) {
			return errors.New("application state contains invalid UTF-8")
		}
	}
	return nil
}
