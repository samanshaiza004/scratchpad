package backend

import (
	"context"
	"errors"
	"fmt"

	"scratchpad/application"
)

type semanticZoomSession struct {
	generation        uint64
	runtimeGeneration uint64
	documentID        application.DocumentID
	instanceID        uint64
	revision          uint64
	depth             int
	anchorByte        int
	lineCount         int
	cancel            context.CancelFunc
	done              bool
	plan              application.SemanticZoomPlan
	err               error
}

type semanticZoomJob struct {
	session *semanticZoomSession
	ctx     context.Context
	input   application.SemanticZoomSnapshot
}

func (r *Runtime) readSemanticZoomLocked(request CommandRequest) Response {
	documentID := application.DocumentID(request.DocumentID)
	superseded := false
	if request.ZoomDepth == application.SemanticZoomFull {
		superseded = r.cancelSemanticZoomLocked()
	}
	if request.SemanticZoomGeneration != 0 {
		if superseded {
			if err := r.publishApplicationState(); err != nil {
				return commandError(request, "caliber_error", err)
			}
		}
		session := r.semanticZoom
		if session == nil || session.generation != request.SemanticZoomGeneration ||
			session.documentID != documentID || session.revision != request.EditorRevision ||
			session.depth != request.ZoomDepth || session.anchorByte != int(request.AnchorByte) {
			return commandError(request, "stale_semantic_zoom_request", errors.New("semantic zoom request was superseded or its source changed"))
		}
		if !session.done {
			return r.semanticZoomPendingResponse(request, session)
		}
		if session.err != nil {
			return commandError(request, "zoom_unavailable", session.err)
		}
		return r.semanticZoomPlanResponse(request, session.plan)
	}

	// A fresh request supersedes any older work. Cancellation is cooperative;
	// the worker lane keeps only one active build and one latest pending request.
	superseded = r.cancelSemanticZoomLocked() || superseded
	if superseded {
		// Other editor views may still be waiting on the canceled generation.
		// Publish a terminal watermark before doing work that can fail or block.
		if err := r.publishApplicationState(); err != nil {
			return commandError(request, "caliber_error", err)
		}
	}
	plan, snapshot, err := r.app.CaptureSemanticZoom(documentID, request.EditorRevision,
		request.ZoomDepth, int(request.AnchorByte))
	if err != nil {
		return commandError(request, semanticZoomErrorCode(err), err)
	}
	if !plan.Ready {
		if err := r.enablePresentationLocked(request.DocumentID); err != nil {
			return commandError(request, "zoom_unavailable", err)
		}
		return r.semanticZoomPlanResponse(request, plan)
	}
	if snapshot == nil {
		return r.semanticZoomPlanResponse(request, plan)
	}
	if !snapshot.RequiresBackground() {
		plan, err = application.BuildSemanticZoom(context.Background(), *snapshot)
		if err != nil {
			return commandError(request, "zoom_unavailable", err)
		}
		return r.semanticZoomPlanResponse(request, plan)
	}
	if r.semanticZoomJobs == nil || r.semanticZoomStop == nil {
		return commandError(request, "zoom_unavailable", errors.New("semantic zoom worker is unavailable"))
	}
	r.semanticZoomGeneration++
	if r.semanticZoomGeneration == 0 {
		r.semanticZoomGeneration++
	}
	ctx, cancel := context.WithCancel(context.Background())
	session := &semanticZoomSession{
		generation: r.semanticZoomGeneration, runtimeGeneration: r.generation,
		documentID: documentID, instanceID: plan.InstanceID, revision: plan.Revision,
		depth: plan.Depth, anchorByte: plan.AnchorByte, lineCount: plan.LineCount, cancel: cancel,
	}
	r.semanticZoom = session
	job := semanticZoomJob{session: session, ctx: ctx, input: *snapshot}
	select {
	case r.semanticZoomJobs <- job:
	default:
		select {
		case <-r.semanticZoomJobs:
		default:
		}
		r.semanticZoomJobs <- job
	}
	return r.semanticZoomPendingResponse(request, session)
}

func semanticZoomErrorCode(err error) string {
	switch {
	case errors.Is(err, application.ErrStaleEditorRevision):
		return "stale_editor_revision"
	case errors.Is(err, application.ErrInvalidSemanticZoomAnchor):
		return "invalid_zoom_anchor"
	case errors.Is(err, application.ErrInvalidSemanticZoomDepth):
		return "invalid_zoom_depth"
	default:
		return "zoom_unavailable"
	}
}

func (r *Runtime) semanticZoomPlanResponse(request CommandRequest, plan application.SemanticZoomPlan) Response {
	response := okResponse(request.RequestID, r.lifecycle, r.revision)
	response.BasedOnRevision = request.BasedOnRevision
	response.SemanticZoom = semanticZoomFromApplication(plan)
	return response
}

func (r *Runtime) semanticZoomPendingResponse(request CommandRequest, session *semanticZoomSession) Response {
	plan := application.SemanticZoomPlan{
		DocumentID: session.documentID, Revision: session.revision, InstanceID: session.instanceID,
		Generation: session.generation, Depth: session.depth, AnchorByte: session.anchorByte,
		Ready: false, Supported: true, Reason: "pending", LineCount: session.lineCount,
	}
	response := r.semanticZoomPlanResponse(request, plan)
	return response
}

func (r *Runtime) cancelSemanticZoomLocked() bool {
	if r.semanticZoom == nil {
		return false
	}
	if r.semanticZoom.generation > r.semanticZoomSupersededThrough {
		r.semanticZoomSupersededThrough = r.semanticZoom.generation
	}
	if r.semanticZoom.cancel != nil {
		r.semanticZoom.cancel()
	}
	r.semanticZoom = nil
	return true
}

func (r *Runtime) cancelSemanticZoomGenerationLocked(generation uint64) bool {
	if generation == 0 || r.semanticZoom == nil || r.semanticZoom.generation != generation {
		return false
	}
	r.cancelSemanticZoomLocked()
	return true
}

func (r *Runtime) cancelStaleSemanticZoomLocked() {
	session := r.semanticZoom
	if session == nil || r.app == nil {
		return
	}
	doc := r.app.Documents[session.documentID]
	if doc == nil || doc.Editor == nil || doc.InstanceID() != session.instanceID || doc.Revision() != session.revision {
		r.cancelSemanticZoomLocked()
	}
}

func (r *Runtime) runSemanticZoomWorker(jobs <-chan semanticZoomJob, stop <-chan struct{}) {
	for {
		select {
		case <-stop:
			return
		case job := <-jobs:
			if job.ctx.Err() != nil {
				continue
			}
			plan, err := r.buildSemanticZoom(job.ctx, job.input)
			r.finishSemanticZoom(job, plan, err)
		}
	}
}

func (r *Runtime) buildSemanticZoom(ctx context.Context, snapshot application.SemanticZoomSnapshot) (application.SemanticZoomPlan, error) {
	if r.semanticZoomBuilder != nil {
		return r.semanticZoomBuilder(ctx, snapshot)
	}
	return application.BuildSemanticZoom(ctx, snapshot)
}

func (r *Runtime) finishSemanticZoom(job semanticZoomJob, plan application.SemanticZoomPlan, err error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	session := job.session
	if r.lifecycle != lifecycleRunning || r.generation != session.runtimeGeneration ||
		r.semanticZoom != session || job.ctx.Err() != nil {
		return
	}
	doc := r.app.Documents[session.documentID]
	if doc == nil || doc.Editor == nil || doc.InstanceID() != session.instanceID || doc.Revision() != session.revision {
		r.cancelSemanticZoomLocked()
		return
	}
	if err != nil {
		if errors.Is(err, application.ErrSemanticZoomCanceled) {
			return
		}
		session.err = fmt.Errorf("could not construct semantic zoom: %w", err)
	} else {
		plan.Generation = session.generation
		session.plan = plan
	}
	if session.cancel != nil {
		session.cancel()
		session.cancel = nil
	}
	session.done = true
	if err := r.publishApplicationState(); err != nil {
		r.asyncError = fmt.Sprintf("could not publish semantic zoom completion: %v", err)
	}
}
