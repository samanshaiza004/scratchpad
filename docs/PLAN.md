# Roadmap

The latest published release is [Scratchpad v0.2.0](https://github.com/samanshaiza004/scratchpad/releases/tag/v0.2.0). Its implementation status, validation evidence, and accepted measurement limits are summarized here and in the [changelog](../CHANGELOG.md).

## v0.1.0 and v0.1.1 — released foundation

These releases established Scratchpad as a native, file-first editor and stabilized its Windows and macOS packages. Ordinary files remain authoritative; Scratchpad owns editing, workspace operations, saving, conflict handling, and recovery. See the versioned entries in the [changelog](../CHANGELOG.md).

## v0.2.0 — source-connected views (released 2026-11-11)

The v0.2.0 release makes alternate ways of working with content useful while keeping their source mapping explicit. It includes:

- semantic selection expansion and a bounded, revision-scoped projection model;
- Full, Focus, Skim, and Overview source views, plus revision-safe Markdown and code folding;
- pinned ranges with safe write-through for unambiguous edits;
- editable workspace Search and source-linked task, symbol, heading, and link views;
- session restoration, editor typography, persisted themes, and native workspace refinements that dogfood Alicorn's retained UI.

Release acceptance is recorded in [issue #17](https://github.com/samanshaiza004/scratchpad/issues/17) and the linked [Windows](validation/issue-17-windows-2026-11-10.md) and [macOS](validation/issue-17-macos-2026-11-11.md) reports. Automated suites, native/package checks, and maintainer-reported physical acceptance passed on both platforms. Large semantic plans build from immutable snapshots on a cancellable worker, leaving Full source interactive and rejecting stale generations. The historic 206 ms synchronous prose measurement remains a construction baseline; current worker timing is recorded separately. Native UI-to-visible latency and full GUI-process memory high-water were not instrumented and are not release claims.

Image previews and the Quick Open blur treatment are additional product work on `main`; they do not change the file-authority or source-mapping contracts.

## Post-v0.2.0 development — local Git workbench

The next product increment is integrating the useful local review and source
control workflows from Alicorn History into Scratchpad. The current branch
implements a Source Control sidebar, commit staging and creation, bounded
repository history and refs, a commit graph, commit details, and read-only
working/staged/historical diffs. These capabilities are unreleased and are not
included in the v0.2.0 packages.

The integration uses the existing workbench and shared Go backend. Documents,
History, and Diff can occupy the two sides of a focused split; History's refs,
commits, and details are resizable within their view. A general multi-pane
layout and arbitrary view movement are still future work. The backend owns
repository operations independently of which Git view is visible; historical
snapshots never enter the writable document model. Current limits and safety
boundaries are documented in the [Git client guide](GIT-CLIENT.md).

## Longer-term questions

Stronger range re-anchoring, additional language projections, and broader
projection composition remain research topics. They do not require
event-sourced storage, a canonical graph, or a proprietary document format.

## Engineering records

The earlier gate-by-gate implementation plan is preserved in [engineering history](history/IMPLEMENTATION-GATES.md). Historical implementation and validation reports retain their original scope and date; use this roadmap and the [current Alicorn coverage page](frontends/alicorn/PARITY.md) for present status.
