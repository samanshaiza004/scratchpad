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

The sidebar is the compact status navigator. Editor, History, and Diff are
typed workbench views arranged in pane groups. The recursive layout supports
multiple side-by-side splits; each split group has its own tab strip, and tabs
can be reordered or moved between groups. History and Diff can open beside the
current view, while History's refs, commits, and detail columns can be resized
independently.

This is a first workbench slice, with deliberate limits. Scratchpad currently
keeps all Editor tabs in one pane group because editing still uses one live
editor, IME, and accessibility pipeline. A document can be moved as a view, but
the app does not yet support two independently navigable editor views of the
same document. History and Diff each have one shared view instance. Search
remains an existing workspace surface rather than a generic workbench view.
Pane layout is in-memory and is not restored across application restarts.
Terminal sessions are not implemented.

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
- The pane tree is frontend presentation state. Document/session restoration
  retains its existing document-oriented behavior and does not persist pane
  groups, splits, or History/Diff placement.

## Standalone Alicorn History

The separate Alicorn History application supplied the bounded Git reads, ref
navigation, first-parent semantics, retained commit graph, and review workflow
that have been consolidated into Scratchpad. The standalone repository is no
longer a supported application; its source history is retained in the archived
repository for reference. This does not change Alicorn or Scratchpad's supported
dependency pins.
