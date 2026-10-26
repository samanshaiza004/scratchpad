package backend

import (
	"errors"
	"strings"

	"scratchpad/application"
)

func (r *Runtime) applyPinnedCommand(request CommandRequest) Response {
	response := okResponse(request.RequestID, r.lifecycle, r.revision)
	response.BasedOnRevision = request.BasedOnRevision
	var err error
	switch request.Command {
	case "pinned_add":
		_, err = r.app.PinSourceRange(application.DocumentID(request.DocumentID), request.SourceInstance, request.EditorRevision, int(request.StartByte), int(request.EndByte))
	case "pinned_move":
		err = r.app.MovePinnedRange(request.PinEpoch, request.PinRevision, application.PinID(request.PinID), request.PinDelta)
	case "pinned_remove":
		err = r.app.RemovePinnedRange(request.PinEpoch, request.PinRevision, application.PinID(request.PinID))
	case "pinned_read":
	case "pinned_go_to_source":
		var pin application.PinnedRangeView
		pin, err = r.app.ResolvePinnedSource(request.PinEpoch, request.PinRevision, application.PinID(request.PinID))
		if err == nil {
			err = r.app.Dispatch(application.PresentationCommand{Kind: application.PresentationSelectDocument, DocumentID: pin.DocumentID})
			if err == nil {
				doc := r.app.Documents[pin.DocumentID]
				doc.Editor.SetSelection(pin.StartByte, pin.EndByte)
				line, _ := doc.Editor.Buffer.LineAt(pin.StartByte)
				response.EditorSelection = &EditorSelection{DocumentID: string(pin.DocumentID), EditorRevision: pin.SourceRevision, AnchorByte: uint64(pin.StartByte), CursorByte: uint64(pin.EndByte), CursorLine: uint64(line)}
			}
		}
	case "pinned_window", "pinned_copy":
		var window application.PinnedWindow
		if request.Command == "pinned_window" {
			window, err = r.app.ReadPinnedWindow(request.PinEpoch, request.PinRevision, int(request.ProjectionFirst), int(request.ProjectionLimit), int(request.MaxBytes), int(request.AnchorByte))
		} else {
			window = application.PinnedWindow{Epoch: request.PinEpoch, Revision: request.PinRevision}
			window.Data, err = r.app.ReadPinnedBytes(request.PinEpoch, request.PinRevision, application.PinID(request.PinID))
		}
		if err == nil {
			if len(window.Data) > 0 {
				var id, generation uint64
				id, generation, err = r.caliber.publishResource(window.Data)
				if err == nil {
					response.Resource = &ResourceDescriptor{ResourceID: id, Generation: generation, ByteLen: uint64(len(window.Data)), ApplicationRev: r.applicationRevision}
				}
			}
			window.Data = nil
			response.PinnedWindow = &window
		}
		if err == nil {
			return response
		}
	default:
		err = errors.New("unknown pinned command")
	}
	if err != nil {
		code := "pinned_unavailable"
		if errors.Is(err, application.ErrPinnedRevision) {
			code = "stale_pinned_response"
		}
		return commandError(request, code, err)
	}
	snapshot := r.app.PinnedSnapshot()
	response.Pinned = &snapshot
	if e := r.publishApplicationState(); e != nil {
		return commandError(request, "caliber_error", e)
	}
	response.Revision = r.revision
	return response
}

func validatePinnedRequest(input []byte, request CommandRequest) error {
	required := []string{}
	switch request.Command {
	case "pinned_add":
		required = []string{"source_instance", "editor_revision", "start_byte", "end_byte"}
		if request.SourceInstance == 0 || request.DocumentID == "" || strings.ContainsRune(request.DocumentID, 0) || request.EndByte <= request.StartByte {
			return errors.New("pin requires a current source instance and a nonempty selection")
		}
	case "pinned_read":
		return nil
	case "pinned_move", "pinned_remove", "pinned_go_to_source", "pinned_copy":
		required = []string{"pin_epoch", "pin_revision", "pin_id"}
		if request.PinID == 0 {
			return errors.New("pin_id is required")
		}
		if request.Command == "pinned_move" && request.PinDelta != -1 && request.PinDelta != 1 {
			return errors.New("pin_delta must be -1 or 1")
		}
	case "pinned_window":
		required = []string{"pin_epoch", "pin_revision", "projection_first", "projection_limit", "max_bytes"}
		if request.ProjectionLimit < 1 || request.ProjectionLimit > application.MaxPinnedRows || request.MaxBytes < 1 || request.MaxBytes > application.MaxPinnedBytes {
			return errors.New("pinned window exceeds the 256 row / 64 KiB budget")
		}
	default:
		return errors.New("unknown pinned command")
	}
	for _, key := range required {
		if !jsonNonNullFieldPresent(input, key) {
			return errors.New("missing pinned request field: " + key)
		}
	}
	if request.Command != "pinned_add" && (request.PinEpoch == 0 || request.PinRevision == 0) {
		return errors.New("pinned epoch and revision must be nonzero")
	}
	max := uint64(^uint(0) >> 1)
	if request.StartByte > max || request.EndByte > max || request.ProjectionFirst > max || request.AnchorByte > max {
		return errors.New("pinned coordinate exceeds host integer capacity")
	}
	return nil
}
