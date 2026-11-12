# Git client

This guide describes the unreleased local Git integration being developed
after Scratchpad v0.2.0. It is not present in the v0.2.0 packages.

## Surfaces

- **Source Control** is a compact workspace sidebar. It shows branch and
  upstream status, staged and unstaged files, and supports staging, unstaging,
  and creating a local commit.
- **History** is a workbench tab with recent commits, a retained commit DAG,
  branch/remote/tag refs, commit filtering, first-parent metadata, changed-file
  summaries, and navigation to a selected ref's commit.
- **Diff** is a read-only workbench tab for working-tree, staged, or historical
  diffs. A selected commit can open its full diff or a changed file's diff.

The sidebar is the compact status navigator. History and Diff use the central
workbench and can also open beside the current workbench view. The first split
supports a document beside History or Diff, and History's refs, commits, and
detail columns can be resized independently. This is a focused two-view layout,
not yet a general pane tree: arbitrary view rearrangement, multiple splits,
dragging any view to a new group, and layout presets remain future work.

## Ownership and safety

Git operations belong to the Go application backend, not to a visible pane. A
bounded worker runs Git with argument vectors, tags work with the active
workspace generation, discards stale results, and serializes index and commit
mutations. The frontend receives detached snapshots. Repository status uses
Git's porcelain-v2 format; branch and remote-tracking refs are data for
navigation and display.

The Git worktree reflects saved files. Save open documents before reviewing or
staging them; unsaved editor buffers are not written to the Git index
implicitly. Historical commits and all displayed diffs remain read-only and do
not enter Scratchpad's editable document store.

Repository status is read on workspace startup and after Scratchpad's own Git
mutations. Use **Refresh** after changing the repository through an external
terminal or another application.

## Current bounds and limits

- The status snapshot is capped at 256 changed files, the ref snapshot at 1,000
  refs, and the recent history snapshot at 100 commits.
- A displayed diff is capped at 96 KiB. Larger diffs are truncated with an
  explicit marker. Commit detail is limited to 256 changed files.
- Commit history follows Git's topological order across refs visible to the
  local repository. Shallow histories can have missing parent edges; the graph
  does not invent edges for absent commits. Filtering hides graph connections
  rather than implying new ancestry.
- Commit details and commit diffs compare with the first parent. Root commits
  compare against the empty tree.
- Local stage, unstage, and commit are supported. Fetch, pull, push, branch
  creation/switching, merge/rebase operations, hunk staging, and conflict
  resolution are not part of this initial integration. Conflicting paths may
  be shown by status, but the UI does not resolve them.
- History selection supports mouse and focused-list keyboard navigation;
  commit details and diffs remain read-only.
- Diffs include old/new line gutters, hunk navigation, horizontal scrolling,
  and explicit truncation when the bounded output limit is reached.

## Standalone Alicorn History

The separate Alicorn History application supplied the bounded Git reads, ref
navigation, first-parent semantics, retained commit graph, and review workflow
that have been consolidated into Scratchpad. The standalone repository is no
longer a supported application; its source history is retained in the archived
repository for reference. This does not change Alicorn or Scratchpad's supported
dependency pins.
