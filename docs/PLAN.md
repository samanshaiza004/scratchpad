# Roadmap

The latest published release is [Scratchpad v0.1.1](https://github.com/samanshaiza004/scratchpad/releases/tag/v0.1.1). The current `main` branch contains unreleased v0.2.0 work; implementation status and release notes are summarized in the [changelog](../CHANGELOG.md).

## v0.1.0 and v0.1.1 — released foundation

These releases established Scratchpad as a native, file-first editor and stabilized its Windows and macOS packages. Ordinary files remain authoritative; Scratchpad owns editing, workspace operations, saving, conflict handling, and recovery. See the versioned entries in the [changelog](../CHANGELOG.md).

## v0.2.0 — source-connected views (in development)

The v0.2.0 direction is to make alternate ways of working with content useful while keeping their source mapping explicit. The current `main` implementation includes:

- semantic selection expansion and a bounded, revision-scoped projection model;
- Full, Focus, Skim, and Overview source views, plus revision-safe Markdown and code folding;
- pinned ranges with safe write-through for unambiguous edits;
- editable workspace Search and source-linked task, symbol, heading, and link views;
- session restoration, editor typography, persisted themes, and native workspace refinements that dogfood Alicorn's retained UI.

These implementations do not by themselves mean v0.2.0 is release-ready. The release gate remains [issue #17](https://github.com/samanshaiza004/scratchpad/issues/17). Large semantic plans now build from immutable snapshots on a cancellable worker, leaving Full source interactive and rejecting stale generations. The historical million-line prose measurement was about 206 ms; current native responsiveness, cancellation, and memory behavior still need acceptance evidence. User-facing source mapping, stale-reference handling, bounded rendering, and the ordinary editor fallback remain part of acceptance.

Image previews and the Quick Open blur treatment are additional product work on `main`; they do not change the file-authority or source-mapping contracts.

## Longer-term questions

History-aware views, stronger range re-anchoring, additional language projections, and broader projection composition remain research topics. They do not require event-sourced storage, a canonical graph, or a proprietary document format.

## Engineering records

The earlier gate-by-gate implementation plan is preserved in [engineering history](history/IMPLEMENTATION-GATES.md). Historical implementation and validation reports retain their original scope and date; use this roadmap and the [current Alicorn coverage page](frontends/alicorn/PARITY.md) for present status.
