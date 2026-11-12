# Changelog

Notable changes to Scratchpad are collected here. The latest published release
is [v0.2.0](https://github.com/samanshaiza004/scratchpad/releases/tag/v0.2.0).
The Unreleased section tracks changes after v0.2.0. Merge commits and duplicate
integration commits are represented by their resulting changes, not repeated
as separate entries.

## [Unreleased]

### Added

- Added local Alicorn color-theme import, preview, persistence, and duplicate-
  and-customize controls in Settings, with built-in Catppuccin Mocha and
  layered Scratchpad defaults.
- Added a local Git Source Control sidebar with branch/upstream status, staged
  and unstaged file groups, file staging and unstaging, and local commits.
- Added workbench History and read-only Diff views with bounded recent history,
  branch/remote/tag navigation, commit filtering, first-parent commit details,
  changed-file summaries, keyboard selection, and a retained commit graph
  aligned to virtualized rows. History and Diff can open beside a document;
  History's refs, commits, and details are independently resizable.
- Added readable diff line gutters, hunk navigation, horizontal scrolling, and
  bounded diff parsing for working, staged, and historical changes.
- Added asynchronous repository inspection and serialized Git mutations through
  the Go backend. Git status uses porcelain v2, repository paths and subprocess
  arguments are validated, stale workspace results are discarded, and historical
  diffs remain separate from editable document buffers.
- Added a recursive workbench pane tree for Editor, History, and Diff views,
  with group-local tabs, tab reordering and movement between groups, and
  side-by-side History/Diff workflows. The existing Source Control sidebar
  remains the compact repository navigator; document editing still uses one
  editor-bearing group, and pane placement is not yet persisted.

### Fixed

- Kept open-document synchronization retryable after a workbench view allocation
  or activation failure, so a partial sync cannot be cached as complete.

## [0.2.0] — 2026-11-11

See the [v0.2.0 release](https://github.com/samanshaiza004/scratchpad/releases/tag/v0.2.0)
for platform downloads, package manifests, and checksums.

### Added

- Added bounded, revision-scoped semantic selection expansion and a reusable
  source-projection core. Stale document instances, revisions, or ambiguous
  edits are rejected instead of being applied to unrelated bytes.
- Added source-connected Full, Focus, Skim, and Overview views, with semantic
  zoom anchors, modifier-wheel/menu/command controls, source navigation, local
  reversible folds, and parser-backed Markdown and code structure. Editing
  returns to the authoritative full source.
- Added a Pinned working pane for source ranges, including references across
  files, current/stale/missing state, navigation to source, and conservative
  write-through for unambiguous edits.
- Added workspace Search and Symbols surfaces. Search results can be edited
  against their source; task, symbol, heading, and link projections navigate
  to exact source locations. Markdown task markers can be toggled in place.
- Added read-only PNG and QOI previews in ordinary tabs, with bounded
  background decoding, zoom, pan, and retained per-tab view state.
- Added detachable text-document windows and a shared workspace across primary
  and floating editors.
- Added complete clean-session restoration for workspace, tabs, active and
  preview documents, editor positions, tree focus, and pane sizes. Recent
  workspaces persist independently from session restoration and crash recovery.
- Added installed-font selection, persisted editor family and size, independent
  editor zoom, and proportional-font support for prose.
- Added persisted Warm and Cool Light themes, theme-authored syntax and modal
  colors, and the optional Workbench Relief appearance.
- Added an opt-in Quick Open backdrop-blur comparison and adopted the Gaussian
  blur presentation for the Scratchpad palette.
- Added Scratchpad Windows `.ico` and macOS `.icns` application branding.
- Added development dogfood for live color-theme replacement in open editor
  windows, including detached editors, while retaining document and view state.
- Added a development-only watcher path that keeps the last valid editor theme
  active when a candidate theme is invalid.
- Added a semantic source editor fold model that supports nested, revision-safe
  Markdown and code folds and navigation into collapsed ranges.
- Added an editable workspace-address picker in the titlebar and controls for
  switching workspaces from the workspace header.

### Changed

- Connected document tabs to the editor surface on macOS and Windows, moved
  workspace switching and address controls into the titlebar, and added
  animated tab reordering and tab overflow controls.
- Added the native Windows caption frame and macOS content-titlebar treatment;
  Linux keeps its system-decorated window and separate-tab fallback.
- Reworked Settings into responsive, independently scrolling pages and made
  editor toolbars and workspace layouts fit their content more closely.
- Refined the native titlebar, connected tab and workspace states, preview-tab
  styling, overflow controls, font-picker sizing, and workspace tree focus.
- Improved source-mapped Markdown presentation, table-aware wrapping, folded
  source density, pinned cards, editor focus visuals, and workspace navigation.
- Added motion dogfood for connected tabs, tab reordering, and Quick Open; kept
  the Quick Open blur comparison opt-in and the editing foreground crisp.
- Dogfooded Alicorn's public UI helpers for ordinary controls while retaining
  direct runtime access for editor, scrolling, text-input, and native features.
- Updated Scratchpad's Alicorn pin to include connected tabs, UI sizing, and
  restored trackpad momentum, while keeping native rendering and interaction
  ownership in Alicorn.

### Fixed

- Resolved workspace-relative Quick Open paths and kept workspace context
  intact while editing Search results.
- Preserved the editor viewport during clipboard paste and retained editor
  focus and caret when navigating from semantic views to source.
- Corrected tab tear-off input routing, optional tab-node handling, font
  resolution against the selected Alicorn checkout, and Windows DirectWrite
  font-file discovery.
- Fixed recent-workspace persistence being coupled to session restore, tree
  focus leaking across workspace switches, and watcher races in live UI dogfood.
- Fixed Duplicate & Customize for valid themes with trailing whitespace and
  sparse role declarations by editing parsed JSON while preserving color
  declarations; generated color-token names avoid collisions, and errors now
  identify the failing customization stage.
- Deferred semantic-view changes until safe frame boundaries; corrected
  selection, clipboard, whitespace-fold, source-anchor, and hidden-range
  navigation behavior.
- Kept search editing state valid across result switches and freed results;
  retained crash diagnostics and prevented stale result context from replacing
  the active editor unexpectedly.
- Routed typing and paste to the focused Find field, and deferred result
  switches and semantic-view actions to safe frame boundaries.
- Preserved committed IME edits across stale acknowledgements and distinguished
  reopened documents with a new source-instance identity.
- Stabilized editor presentation during edits, preserved unaffected wrapped-row
  measurements, aligned Explorer rows, compacted collapsed folds, and removed
  excess editor surface spacing.
- Honored system contrast preferences and restored editor helpers needed by the
  theme and presentation paths.

### Performance

- Bounded semantic selection expansion and added large-document benchmarks.
- Preserved unaffected wrap-height measurements across local edits and counted
  status-bar columns in one grapheme pass.
- Kept image decoding, font catalog work, source projection transport, and
  semantic-view rendering bounded or off the latency-sensitive UI path.
- Moved large semantic-plan construction to a bounded worker over immutable
  source snapshots, with cooperative cancellation and document-instance,
  revision, and request-generation checks. Repeated million-line worker results
  and platform release evidence are recorded in the [Windows](docs/validation/issue-17-windows-2026-11-10.md)
  and [macOS](docs/validation/issue-17-macos-2026-11-11.md) validation reports.
  The earlier 206 ms synchronous construction result remains a historical
  baseline, not a current foreground-latency measurement.

### Build, packaging, and validation

- Added opt-in Windows static-SDL packaging work and tightened package
  provenance, selected-library checks, manifests, checksums, and clean-location
  launch validation.
- Pinned the macOS package to macOS 13, aligned SDL with Alicorn, synchronized
  SDL 3.4.18 fixtures, and pinned validated macOS host and CI toolchains.
- Fixed macOS CoreText fixture ownership, CoreFoundation string conversion,
  Rust dylib link-edit alignment, and the Windows AccessKit bootstrap's
  PowerShell selection.
- Added native session-restoration and crash-recovery smoke coverage to CI.
- Fixed Linux native menu setup and semantic shortcuts, and used the host-owned
  Linux font fallback.
- Added retained-mutation diagnostics and native validation records for
  semantic zoom, connected-tab motion, and live-theme dogfood.
- Added package-launch checks outside the source checkout and removed unused
  implementation code.
- Completed v0.2.0 release acceptance and recorded the current Windows and
  macOS test, physical-validation, and package evidence in [issue #17](https://github.com/samanshaiza004/scratchpad/issues/17).

## [0.1.1] — 2026-10-12

See the [v0.1.1 release](https://github.com/samanshaiza004/scratchpad/releases/tag/v0.1.1)
for downloads, manifests, checksums, and package verification details.

- Added clean-session and recent-workspace restoration, persistent appearance
  preferences, editor text zoom, accessibility appearance controls, and
  improvements to Find, Settings, Quick Open, tabs, and the welcome surface.
- Improved status-bar and tab presentation, close-button contrast, wrapped
  Settings layouts, atomic preference writes, and Windows workspace trash.
- Published a portable Windows x64 ZIP and an Apple Silicon macOS app ZIP with
  dependency audits, manifests, checksums, and extracted-package smoke checks.
- The macOS package requires macOS 13 or later. Packages are not Developer ID
  signed/notarized on macOS or Authenticode signed on Windows.

## [0.1.0] — 2026-10-04

See the [v0.1.0 release](https://github.com/samanshaiza004/scratchpad/releases/tag/v0.1.0)
for the original package hashes and release instructions.

- Established the native, file-first editor with Alicorn as its supported
  desktop frontend, ordinary-file persistence, workspace operations, and
  predictable editing and recovery behavior.
- Published a portable Windows x64 build and a universal macOS app for Apple
  Silicon and Intel, targeting macOS 13 and using statically built SDL 3.4.16.
- Verified clean launch, open/edit/save, quit, and relaunch. The packages were
  unsigned and not notarized at release.
