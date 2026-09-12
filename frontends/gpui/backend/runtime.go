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
	r.caliber.close()
	r.caliber = nil
	r.app = nil
	r.lifecycle = lifecycleStopped
	r.revision = 0
	r.applicationRevision = 0
	r.state = StateEnvelope{}
	r.stateLeases = 0
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
	default:
		return commandError(request, "unknown_command", fmt.Errorf("unknown command %q", request.Command))
	}
	if err := r.publishApplicationState(); err != nil {
		return commandError(request, "caliber_error", err)
	}
	response := okResponse(request.RequestID, r.lifecycle, r.revision)
	response.BasedOnRevision = request.BasedOnRevision
	response.DirectoryListing = listing
	return response
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
	data, readRevision, schema, err := r.caliber.readLatestStateCopy()
	if err != nil {
		return err
	}
	var published StateEnvelope
	if err := json.Unmarshal(data, &published); err != nil {
		return fmt.Errorf("decode published state: %w", err)
	}
	if schema != StateSchemaV1 {
		return fmt.Errorf("Caliber state schema mismatch: got %d want %d", schema, StateSchemaV1)
	}
	if readRevision != revision {
		return fmt.Errorf("Caliber state revision mismatch: published %d read %d", revision, readRevision)
	}
	if published.Revision != revision {
		return fmt.Errorf("state envelope revision mismatch: payload %d Caliber %d", published.Revision, revision)
	}
	published.Schema = schema
	published.Revision = readRevision
	r.revision = readRevision
	r.applicationRevision = published.ApplicationRev
	r.state = published
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
