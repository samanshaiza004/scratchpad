# Alicorn feature coverage and follow-up gaps

Alicorn is the supported Scratchpad frontend for v0.1.0. The former Shirei workbench is retired from the active source tree and preserved at the `archive/pre-v0.1.0-frontends` Git branch and tag. This page records capabilities that existed in Shirei but are not currently implemented in Alicorn; it is not a requirement to restore the old frontend.

## Shirei capabilities Alicorn does not yet have

| Capability in the retired Shirei workbench | Alicorn status | Notes for a future issue |
|---|---|---|
| Restore the last workspace and open-document session, including recent paths | Missing | Alicorn restores unsaved crash-recovery documents, but the normal saved-session restore/persist flow from the Go application is not wired into its startup/shutdown path. Keep recovery and saved-session persistence as separate lifecycles. |
| Outline sidebar for code symbols and Markdown headings, tasks, and links | Missing | Outline rows should navigate to source and retain the editor's source-byte ownership. |
| Collapse/fold controls for Markdown sections and supported code blocks | Missing | The Go language and Markdown projections already expose fold ranges; the frontend still needs fold state, controls, and folded-row geometry. |
| Selectable built-in/custom themes with persisted user settings | Missing | Alicorn currently uses a fixed palette and its Settings surface only exposes ignored-file visibility. |
| Editor font increase/decrease/reset controls | Missing | Add frontend-local sizing with predictable per-session or persisted scope; do not alter source semantics. |
| Expand-selection command for progressively larger semantic/source ranges | Missing | The shared command vocabulary contains `selection.expand`, but Alicorn does not currently implement the interaction. |

These are follow-up product gaps, not reasons to retain Shirei as a second frontend. Keep them as separate, scoped follow-ups if they are promoted into the release or next-version plan.

## Alicorn coverage already in place

Alicorn now covers the core v0.1.0 file/editor path: open/save/Save As, reorderable tabs with drag-and-drop, dirty-close decisions, workspace browsing and mutations with file/directory drag-and-drop, quick open, workspace search, Find/Replace with match-case and whole-word options, Go to Line, undo/redo, clipboard, IME composition, conflict resolution and recovery, Markdown editing commands, Tree-sitter syntax highlighting for Go/TypeScript/TSX, table formatting/navigation, prose and cell-aware wrapping, and per-document wrap override. The Go application owns document bytes and product commands; Alicorn owns transient interaction and presentation through the Caliber boundary.

## Native validation still required

These are implementation checks rather than known missing features: verify Windows and macOS file dialogs, OS trash, clipboard, IME composition/candidate positioning, pointer selection and drag autoscroll, tab reordering, file/directory drag-and-drop (including invalid targets and preview-tab promotion), DPI/resizing, and shutdown behavior on real desktop builds. Headless tests and CI smoke checks do not replace those platform checks.

Validation record for 2026-10-02: the Windows native lifecycle smoke passed (`publication_rendered`, `wake_observed`, and `ordered_shutdown` all true). The full automated Go/Caliber/Alicorn test suite and `go vet ./...` also passed locally. This does not certify the manual interaction matrix above; macOS and hands-on Windows checks remain open release-gate work.

## Historical design evidence

The retired UI's Shirei research and keyboard-navigation implementation notes are preserved under [`docs/history/shirei`](../../history/shirei/README.md). The GPUI experiment reports remain under [`docs/history`](../../history/README.md). The old implementation itself can be recovered from the archive branch/tag.
