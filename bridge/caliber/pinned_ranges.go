package backend

import (
	"errors"
	"strings"
	"unicode/utf8"

	"scratchpad/application"
)

func (r *Runtime) applyPinnedCommand(request CommandRequest) Response {
	response := okResponse(request.RequestID, r.lifecycle, r.revision)
	response.BasedOnRevision = request.BasedOnRevision
	var err error
	switch request.Command {
	case "pinned_replace":
		replacement := make([]byte, len(request.Replacement))
		for i, value := range request.Replacement {
			replacement[i] = byte(value)
		}
		result, replaceErr := r.app.ReplacePinned(application.PinnedEditRequest{
			Epoch: request.PinEpoch, Revision: request.PinRevision, ID: application.PinID(request.PinID),
			Command: application.PresentationCommand{
				Kind:           application.PresentationReplaceDocument,
				ActionID:       request.ActionID,
				DocumentID:     application.DocumentID(request.DocumentID),
				EditorRevision: request.EditorRevision,
				StartByte:      int(request.StartByte), EndByte: int(request.EndByte), Replacement: replacement,
				HasSelectionState: request.HasSelectionState,
				BeforeAnchorByte:  int(request.BeforeAnchorByte), BeforeCursorByte: int(request.BeforeCursorByte),
				AfterAnchorByte: int(request.AfterAnchorByte), AfterCursorByte: int(request.AfterCursorByte),
				TypingGroupID: request.TypingGroupID,
			},
		})
		err = replaceErr
		if err == nil {
			if result.Applied.SourceEdit.AfterRevision == result.Applied.SourceEdit.BeforeRevision {
				response.CommandOutcome = CommandOutcomeNoOp
			} else {
				response.Edit = editAckFromPinnedResult(request.DocumentID, result)
			}
			if doc := r.app.Documents[application.DocumentID(request.DocumentID)]; doc != nil && doc.Editor != nil {
				anchor, cursor := doc.Editor.Selection()
				line, _ := doc.Editor.Buffer.LineAt(cursor)
				response.EditorSelection = &EditorSelection{DocumentID: request.DocumentID,
					EditorRevision: doc.Revision(), AnchorByte: uint64(anchor), CursorByte: uint64(cursor), CursorLine: uint64(line)}
			}
		}
	case "pinned_undo", "pinned_redo":
		result, historyErr := r.app.PinnedHistoryStep(request.PinEpoch, request.PinRevision,
			application.PinID(request.PinID), request.Command == "pinned_redo")
		err = historyErr
		if err == nil && result.Applied.SourceEdit.AfterRevision != result.Applied.SourceEdit.BeforeRevision {
			response.Edit = editAckFromPinnedResult(string(result.UpdatedPin.DocumentID), result)
			doc := r.app.Documents[result.UpdatedPin.DocumentID]
			anchor, cursor := doc.Editor.Selection()
			line, _ := doc.Editor.Buffer.LineAt(cursor)
			response.EditorSelection = &EditorSelection{DocumentID: string(result.UpdatedPin.DocumentID),
				EditorRevision: doc.Revision(), AnchorByte: uint64(anchor), CursorByte: uint64(cursor), CursorLine: uint64(line)}
		} else if err == nil {
			response.CommandOutcome = CommandOutcomeNoOp
		}
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
		} else if errors.Is(err, application.ErrPinnedBoundary) {
			code = "pinned_edit_outside_range"
		} else if errors.Is(err, application.ErrStaleEditorRevision) {
			code = "stale_editor_revision"
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

func editAckFromPinnedResult(documentID string, result application.PinnedEditResult) *EditAck {
	edit := result.Applied.SourceEdit
	ack := &EditAck{DocumentID: documentID, EditorRevision: edit.AfterRevision,
		StartByte: uint64(edit.StartByte), OldEndByte: uint64(edit.OldEndByte), NewEndByte: uint64(edit.NewEndByte)}
	if len(result.Applied.Replacement) > 0 {
		ack.AppliedReplacement = make([]int, len(result.Applied.Replacement))
		for i, value := range result.Applied.Replacement {
			ack.AppliedReplacement[i] = int(value)
		}
	}
	return ack
}

func validatePinnedRequest(input []byte, request CommandRequest) error {
	required := []string{}
	switch request.Command {
	case "pinned_replace":
		required = []string{"pin_epoch", "pin_revision", "pin_id", "document_id", "editor_revision", "start_byte", "end_byte"}
		if request.PinID == 0 || request.DocumentID == "" || !utf8.ValidString(request.DocumentID) || strings.ContainsRune(request.DocumentID, 0) {
			return errors.New("pinned replacement requires a pin identity and valid document ID")
		}
		if request.EndByte < request.StartByte || request.StartByte > uint64(^uint(0)>>1) || request.EndByte > uint64(^uint(0)>>1) {
			return errors.New("pinned replacement range is invalid")
		}
		if len(request.Replacement) > MaxEditBytes {
			return errors.New("pinned replacement exceeds the 128 KiB edit limit")
		}
		if request.TypingGroupID != 0 && !request.HasSelectionState {
			return errors.New("pinned typing transactions require an explicit selection snapshot")
		}
		for _, value := range request.Replacement {
			if value < 0 || value > 255 {
				return errors.New("pinned replacement values must be bytes")
			}
		}
		if request.HasSelectionState && (request.BeforeAnchorByte > uint64(^uint(0)>>1) || request.BeforeCursorByte > uint64(^uint(0)>>1) || request.AfterAnchorByte > uint64(^uint(0)>>1) || request.AfterCursorByte > uint64(^uint(0)>>1)) {
			return errors.New("pinned edit selection does not fit the host word size")
		}
	case "pinned_undo", "pinned_redo":
		required = []string{"pin_epoch", "pin_revision", "pin_id"}
		if request.PinID == 0 {
			return errors.New("pin_id is required")
		}
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
