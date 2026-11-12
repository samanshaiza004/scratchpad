package backend

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"scratchpad/sourcecontrol"
)

type gitJob struct {
	runtimeGeneration uint64
	gitGeneration     uint64
	workspaceRoot     string
	repositoryRoot    string
	command           string
	path              string
	originalPath      string
	message           string
	kind              string
	revision          string
	untracked         bool
}

func (r *Runtime) startGitWorkerLocked() {
	r.gitContext, r.gitCancel = context.WithCancel(context.Background())
	r.gitJobs = make(chan gitJob, 16)
	r.gitStop = make(chan struct{})
	go r.runGitWorker(r.gitContext, r.gitJobs, r.gitStop)
}

func (r *Runtime) stopGitWorkerLocked() {
	if r.gitCancel != nil {
		r.gitCancel()
		r.gitCancel = nil
	}
	if r.gitStop != nil {
		close(r.gitStop)
		r.gitStop = nil
	}
	r.gitJobs = nil
	r.gitContext = nil
	r.gitState = GitState{}
	r.gitDiff = GitDiff{}
	r.gitRefreshPending = false
}

func (r *Runtime) enqueueGitJobLocked(job gitJob) error {
	if r.gitJobs == nil || r.gitContext == nil {
		return errors.New("Git worker is unavailable")
	}
	if r.app == nil || !r.app.HasWorkspace {
		return errors.New("no workspace is open")
	}
	workspaceRoot := r.app.Workspace.Root
	if workspaceRoot == "" {
		return errors.New("workspace root is unavailable")
	}
	r.gitGeneration++
	if r.gitGeneration == 0 {
		r.gitGeneration++
	}
	job.runtimeGeneration = r.generation
	job.gitGeneration = r.gitGeneration
	job.workspaceRoot = workspaceRoot
	job.repositoryRoot = workspaceRoot
	if r.gitState.Available && r.gitState.Root != "" {
		job.repositoryRoot = r.gitState.Root
	}
	select {
	case r.gitJobs <- job:
		return nil
	default:
		return errors.New("Git operation queue is full; wait for the current operation and retry")
	}
}

func (r *Runtime) requestGitRefreshLocked() error {
	if r.gitState.Loading {
		r.gitRefreshPending = true
		return nil
	}
	r.gitState.Loading = true
	r.gitState.Error = ""
	if err := r.enqueueGitJobLocked(gitJob{command: "refresh"}); err != nil {
		r.gitState.Loading = false
		r.gitState.Error = err.Error()
		return err
	}
	return nil
}

func (r *Runtime) runGitWorker(ctx context.Context, jobs <-chan gitJob, stop <-chan struct{}) {
	for {
		select {
		case <-stop:
			return
		case <-ctx.Done():
			return
		case job := <-jobs:
			if !r.gitJobCurrent(job) {
				continue
			}
			runCtx, cancel := context.WithCancel(ctx)
			var snapshot sourcecontrol.Snapshot
			var diff sourcecontrol.Diff
			var detail sourcecontrol.CommitDetail
			var history []sourcecontrol.Commit
			var err error
			if job.command == "stage" || job.command == "unstage" || job.command == "commit" {
				err = sourcecontrol.Mutate(runCtx, job.repositoryRoot, job.command, job.path, job.originalPath, job.message)
			}
			if err == nil {
				switch job.command {
				case "refresh", "stage", "unstage", "commit":
					snapshot, err = sourcecontrol.Load(runCtx, job.workspaceRoot)
				case "history":
					history, err = sourcecontrol.LoadHistory(runCtx, job.repositoryRoot, job.revision)
				case "diff":
					diff, err = sourcecontrol.ReadDiff(runCtx, job.repositoryRoot, job.kind, job.revision, job.path, job.untracked)
				case "detail":
					detail, err = sourcecontrol.ReadCommitDetail(runCtx, job.repositoryRoot, job.revision)
				default:
					err = errors.New("unknown Git worker operation")
				}
			}
			cancel()
			r.finishGitJob(job, snapshot, diff, detail, history, err)
		}
	}
}

func (r *Runtime) gitJobCurrent(job gitJob) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.lifecycle != lifecycleRunning || r.generation != job.runtimeGeneration ||
		r.app == nil || !r.app.HasWorkspace || r.app.Workspace.Root != job.workspaceRoot {
		return false
	}
	if job.command == "diff" {
		return r.gitState.DiffGeneration == job.gitGeneration
	}
	if job.command == "detail" {
		return r.gitState.DetailGeneration == job.gitGeneration
	}
	if job.command == "history" {
		return r.gitState.HistoryGeneration == job.gitGeneration
	}
	return true
}

func (r *Runtime) finishGitJob(job gitJob, snapshot sourcecontrol.Snapshot, diff sourcecontrol.Diff, detail sourcecontrol.CommitDetail, history []sourcecontrol.Commit, err error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.lifecycle != lifecycleRunning || r.generation != job.runtimeGeneration ||
		r.app == nil || !r.app.HasWorkspace ||
		r.app.Workspace.Root != job.workspaceRoot {
		return
	}
	if job.command == "diff" {
		if r.gitState.DiffGeneration != job.gitGeneration {
			return
		}
		r.gitState.DiffLoading = false
		if err != nil {
			r.gitState.DiffReady = false
			r.gitState.DiffError = err.Error()
		} else {
			r.gitDiff = GitDiff{Text: diff.Text, Truncated: diff.Truncated}
			r.gitState.DiffReady = true
			r.gitState.DiffError = ""
		}
	} else if job.command == "history" {
		if r.gitState.HistoryGeneration != job.gitGeneration {
			return
		}
		r.gitState.HistoryLoading = false
		if err != nil {
			r.gitState.HistoryError = err.Error()
		} else {
			r.gitState.Commits = make([]GitCommit, len(history))
			for i, commit := range history {
				r.gitState.Commits[i] = GitCommit{Hash: commit.Hash, Parents: append([]string(nil), commit.Parents...),
					Author: commit.Author, Date: commit.Date, Subject: commit.Subject, Refs: commit.Refs}
			}
			r.gitState.HistoryError = ""
			r.gitState.Generation++
			if r.gitState.Generation == 0 {
				r.gitState.Generation = 1
			}
		}
	} else if job.command == "detail" {
		if r.gitState.DetailGeneration != job.gitGeneration {
			return
		}
		r.gitState.DetailLoading = false
		if err != nil {
			r.gitState.DetailReady = false
			r.gitState.DetailError = err.Error()
		} else {
			r.gitState.Detail = gitCommitDetailFromSource(detail)
			r.gitState.DetailReady = true
			r.gitState.DetailError = ""
		}
	} else {
		previous := r.gitState
		pendingRefresh := r.gitRefreshPending
		r.gitRefreshPending = false
		if err != nil {
			if errors.Is(err, sourcecontrol.ErrNotRepository) {
				r.gitState = GitState{Error: "This workspace is not inside a Git repository."}
			} else {
				previous.Loading = false
				previous.Error = err.Error()
				r.gitState = previous
			}
		} else {
			r.gitState = gitStateFromSnapshot(snapshot)
			r.gitState.Generation = previous.Generation + 1
			if r.gitState.Generation == 0 {
				r.gitState.Generation = 1
			}
		}
		if r.gitState.Available && r.gitState.Root == previous.Root {
			// A status refresh must not invalidate a history request already queued
			// against this repository. The worker uses HistoryGeneration to reject
			// stale completions, so keep that lane's state across refreshes.
			r.gitState.HistoryGeneration = previous.HistoryGeneration
			r.gitState.HistoryLoading = previous.HistoryLoading
			r.gitState.HistoryError = previous.HistoryError
			r.gitState.DiffGeneration = previous.DiffGeneration
			r.gitState.DiffLoading = previous.DiffLoading
			r.gitState.DiffReady = previous.DiffReady
			r.gitState.DiffKind = previous.DiffKind
			r.gitState.DiffPath = previous.DiffPath
			r.gitState.DiffRevision = previous.DiffRevision
			r.gitState.DiffError = previous.DiffError
			r.gitState.DetailGeneration = previous.DetailGeneration
			r.gitState.DetailLoading = previous.DetailLoading
			r.gitState.DetailReady = previous.DetailReady
			r.gitState.DetailError = previous.DetailError
			r.gitState.Detail = previous.Detail
		}
		if pendingRefresh {
			if refreshErr := r.requestGitRefreshLocked(); refreshErr != nil {
				r.gitState.Error = refreshErr.Error()
			}
		}
	}
	if err := r.publishApplicationState(); err != nil {
		r.asyncError = fmt.Sprintf("could not publish Git state: %v", err)
	}
}

func gitCommitDetailFromSource(detail sourcecontrol.CommitDetail) GitCommitDetail {
	result := GitCommitDetail{
		Hash: detail.Hash, Parents: append([]string(nil), detail.Parents...), Author: detail.Author,
		Email: detail.Email, Date: detail.Date, Subject: detail.Subject, Body: detail.Body,
		Files: make([]GitChangedFile, len(detail.Files)),
	}
	for i, file := range detail.Files {
		result.Files[i] = GitChangedFile{Path: file.Path, Status: file.Status, Additions: file.Additions, Deletions: file.Deletions}
	}
	return result
}

func gitStateFromSnapshot(snapshot sourcecontrol.Snapshot) GitState {
	state := GitState{
		Available: snapshot.Available, Root: snapshot.Root, Branch: snapshot.Branch,
		Head: snapshot.Head, Upstream: snapshot.Upstream, Ahead: snapshot.Ahead,
		Behind: snapshot.Behind, Files: make([]GitFile, len(snapshot.Files)),
		Commits: make([]GitCommit, len(snapshot.Commits)),
		Refs:    make([]GitRef, len(snapshot.Refs)),
	}
	for i, file := range snapshot.Files {
		state.Files[i] = GitFile{Path: file.Path, OriginalPath: file.OriginalPath, Status: file.Status, Staged: file.Staged,
			Unstaged: file.Unstaged, Untracked: file.Untracked, Conflict: file.Conflict}
	}
	for i, commit := range snapshot.Commits {
		state.Commits[i] = GitCommit{Hash: commit.Hash, Parents: append([]string(nil), commit.Parents...),
			Author: commit.Author, Date: commit.Date, Subject: commit.Subject, Refs: commit.Refs}
	}
	for i, ref := range snapshot.Refs {
		state.Refs[i] = GitRef{FullName: ref.FullName, Name: ref.Name, Kind: ref.Kind, Target: ref.Target, Head: ref.Head}
	}
	return state
}

func gitStateClone(state GitState) GitState {
	clone := state
	clone.Files = append([]GitFile(nil), state.Files...)
	clone.Commits = make([]GitCommit, len(state.Commits))
	for i, commit := range state.Commits {
		clone.Commits[i] = commit
		clone.Commits[i].Parents = append([]string(nil), commit.Parents...)
	}
	clone.Refs = append([]GitRef(nil), state.Refs...)
	clone.Detail.Parents = append([]string(nil), state.Detail.Parents...)
	clone.Detail.Files = append([]GitChangedFile(nil), state.Detail.Files...)
	return clone
}

func validateGitJob(request CommandRequest) error {
	switch request.Command {
	case "git_refresh":
	case "git_detail_request":
		if len(request.GitRevision) < 7 || len(request.GitRevision) > 64 {
			return errors.New("git_revision must contain 7 to 64 hexadecimal characters")
		}
		for _, c := range request.GitRevision {
			if !strings.ContainsRune("0123456789abcdefABCDEF", c) {
				return errors.New("git_revision must be hexadecimal")
			}
		}
	case "git_history_request":
		if len(request.GitRevision) < 7 || len(request.GitRevision) > 64 {
			return errors.New("git_revision must contain 7 to 64 hexadecimal characters")
		}
		for _, c := range request.GitRevision {
			if !strings.ContainsRune("0123456789abcdefABCDEF", c) {
				return errors.New("git_revision must be hexadecimal")
			}
		}
	case "git_diff_request":
		if request.GitKind != "working" && request.GitKind != "staged" && request.GitKind != "commit" {
			return errors.New("git_kind must be working, staged, or commit")
		}
		if request.GitKind == "commit" {
			if len(request.GitRevision) < 7 || len(request.GitRevision) > 64 {
				return errors.New("git_revision must contain 7 to 64 hexadecimal characters")
			}
			for _, c := range request.GitRevision {
				if !strings.ContainsRune("0123456789abcdefABCDEF", c) {
					return errors.New("git_revision must be hexadecimal")
				}
			}
		}
		if request.Path != "" {
			if err := validateGitPath(request.Path); err != nil {
				return err
			}
		}
		if request.GitUntracked && (request.GitKind != "working" || request.Path == "") {
			return errors.New("untracked diffs require a working-tree file path")
		}
	case "git_stage", "git_unstage":
		if err := validateGitPath(request.Path); err != nil {
			return err
		}
		if request.GitOriginalPath != "" {
			return validateGitPath(request.GitOriginalPath)
		}
	case "git_commit":
		if strings.TrimSpace(request.GitMessage) == "" || len(request.GitMessage) > sourcecontrol.MaxMessageBytes || strings.ContainsRune(request.GitMessage, 0) {
			return errors.New("commit message must contain 1 to 16384 non-NUL bytes")
		}
	case "git_read_diff":
		if request.GitDiffGeneration == 0 {
			return errors.New("git_diff_generation must be nonzero")
		}
	default:
		return errors.New("unsupported Git command")
	}
	return nil
}

func (r *Runtime) applyGitCommand(request CommandRequest) Response {
	if err := validateGitJob(request); err != nil {
		return commandError(request, "invalid_git_request", err)
	}
	if r.app == nil || !r.app.HasWorkspace {
		return commandError(request, "no_workspace", errors.New("no workspace is open"))
	}
	switch request.Command {
	case "git_read_diff":
		if request.GitDiffGeneration != r.gitState.DiffGeneration || !r.gitState.DiffReady {
			return commandError(request, "stale_git_diff", errors.New("requested Git diff is no longer available"))
		}
		response := okResponse(request.RequestID, r.lifecycle, r.revision)
		response.GitDiff = &GitDiff{Text: r.gitDiff.Text, Truncated: r.gitDiff.Truncated}
		return response
	case "git_refresh":
		if err := r.requestGitRefreshLocked(); err != nil {
			return commandError(request, "git_unavailable", err)
		}
	case "git_history_request":
		if !r.gitState.Available {
			return commandError(request, "git_unavailable", errors.New("Git repository status is not available"))
		}
		job := gitJob{command: "history", revision: request.GitRevision}
		if err := r.enqueueGitJobLocked(job); err != nil {
			return commandError(request, "git_unavailable", err)
		}
		r.gitState.HistoryGeneration = r.gitGeneration
		r.gitState.HistoryLoading = true
		r.gitState.HistoryError = ""
	case "git_diff_request":
		job := gitJob{command: "diff", path: request.Path, kind: request.GitKind,
			revision: request.GitRevision, untracked: request.GitUntracked}
		if err := r.enqueueGitJobLocked(job); err != nil {
			return commandError(request, "git_unavailable", err)
		}
		r.gitState.DiffGeneration = r.gitGeneration
		r.gitState.DiffLoading = true
		r.gitState.DiffReady = false
		r.gitState.DiffKind = request.GitKind
		r.gitState.DiffPath = request.Path
		r.gitState.DiffRevision = request.GitRevision
		r.gitState.DiffError = ""
		r.gitDiff = GitDiff{}
	case "git_detail_request":
		if !r.gitState.Available {
			return commandError(request, "git_unavailable", errors.New("Git repository status is not available"))
		}
		job := gitJob{command: "detail", revision: request.GitRevision}
		if err := r.enqueueGitJobLocked(job); err != nil {
			return commandError(request, "git_unavailable", err)
		}
		r.gitState.DetailGeneration = r.gitGeneration
		r.gitState.DetailLoading = true
		r.gitState.DetailReady = false
		r.gitState.DetailError = ""
		r.gitState.Detail = GitCommitDetail{}
	case "git_stage", "git_unstage", "git_commit":
		if !r.gitState.Available {
			return commandError(request, "git_unavailable", errors.New("Git repository status is not available"))
		}
		if r.gitState.Loading {
			return commandError(request, "git_busy", errors.New("wait for the current Git operation to finish"))
		}
		job := gitJob{command: strings.TrimPrefix(request.Command, "git_"), path: request.Path,
			originalPath: request.GitOriginalPath, message: request.GitMessage}
		if err := r.enqueueGitJobLocked(job); err != nil {
			return commandError(request, "git_unavailable", err)
		}
		r.gitState.Loading = true
		r.gitState.Error = ""
	}
	return okResponse(request.RequestID, r.lifecycle, r.revision)
}

func validateGitPath(path string) error {
	return sourcecontrol.ValidateRelativePath(path)
}
