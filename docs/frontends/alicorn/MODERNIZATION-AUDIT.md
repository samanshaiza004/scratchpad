# Alicorn frontend modernization audit

Reviewed against Scratchpad `main` at `ef1f1bfd` and
[Carnival-Science/Alicorn `master`](https://github.com/Carnival-Science/Alicorn)
at `3d49b8bd` on 2026-11-22. Scratchpad's lockfile now names that canonical
repository while retaining the same exact latest commit. This is a source-level
architecture review, not a performance benchmark or a claim that each direct
runtime call is a defect.

## Findings

Scratchpad is already partway through the intended Alicorn model. The command
palette uses AliKit, ordinary rows/buttons/text use `alicorn:ui`, and the
application uses retained surfaces, typed theme roles, virtual lists, and
retained motion. Those migrations should be preserved. The remaining friction
is concentrated in event ownership, repeated projection work, and lifecycle
organization.

| Area | Evidence | Finding |
| --- | --- | --- |
| Keyboard dispatch | `application_key` in `frontends/alicorn/main.odin` is a large ordered policy function for modal precedence, workspace navigation, editor commands, and IME-sensitive behavior. | Application policy belongs here, but picker-local navigation and activation can be owned by the retained component that describes the picker. Keep command meaning, editor operations, and IME policy application-owned. |
| Quick Open | `quick_open_filter` was called separately by build, Up/Down navigation, and activation. Each call scored and sorted the bounded path index again. | Cache the sorted result projection by exact query and index generation. Keep workspace indexing, ranking semantics, opening files, and ownership of the path index in Scratchpad. |
| Other pickers | `symbol_picker_handle_key`, workspace-address movement, and font-picker navigation each implement local selection movement. | Share Alicorn's pure `Roving_View` mechanics and interaction scopes where their behavior matches. Keep disabled-item policy, paging, symbol identity, and selection effects local to each feature. |
| Frame orchestration | `build_app` mixes request/adoption work, retained description, and after-frame focus, caret, scroll, and deferred-action work. | Name these lifecycle stages explicitly before changing their scheduling. Do not move editor mutation, IME recovery, or source-window adoption into generic UI helpers. |
| Settings sizing | `settings_surface_build` describes `settings_page_build` twice to measure and then render the form. | Investigate intrinsic/content measurement before simplifying this. Preserve scroll extent, wrapping, and accessibility scaling; a one-pass rewrite without equivalent measurements could clip content. |
| Runtime API use | Production frontend source currently contains 358 `alicorn.invalidate_root`, 233 `alicorn.layout_style`, and 116 `alicorn.key_string` call sites, alongside 336 calls through `gui.row/column/button/text`. | These counts show where to review, not a target to eliminate. Explicit invalidation still expresses application intent, and advanced editor/layout boundaries still need typed runtime APIs. |

The Go application remains authoritative for document bytes, transactions,
undo/redo, repository operations, and source revisions. Alicorn should continue
to own retained interaction, presentation, layout, and accessibility. Audio,
DSP, workspace policy, projection meaning, and resource lifecycle remain
application-owned.

## Implemented in this pass

Quick Open now caches its filtered and sorted results until either its exact
query or path-index generation changes. Rendering, navigation, and activation
share the same projection. Selection movement uses Alicorn's public
`Roving_View` functions. Its retained panel registers a public interaction
scope for picker text changes and Escape/Return/Up/Down input; result opening
still goes through Scratchpad's deferred action path when handled during
description. The cache remains alive until the active description finishes so
an activated row cannot invalidate the result slice being iterated.

The pin update also exposed two newer public-boundary adjustments: worker wake
callbacks for theme compilation now use `ui.Application_Waker`, adapted once
from the native host callback, and the relief rendering fixture uses
`alicorn:renderer/cpu` rather than a removed SDL-specific helper.

The scope is incremental: the application key callback remains the modal
fallback and continues to own command precedence and IME-sensitive behavior.
The cache is cleared before its borrowed path strings are released.

## Audit of `codex/scratchpad-audit-unused-code`

The local branch is 62 commits behind refreshed `main`. Its committed unused
code cleanup is already present in `main` (including removal of the old helper
functions and release guard), so it must not be merged or cherry-picked again.

The uncommitted draft is based on older application/theme state. Its modal
surface helpers, exact fractional wrap fingerprints, and external-revision
geometry reset are already represented in newer `main`; the current mainline
also includes accessibility-observation handling that the stale helper lacks.
The stale lockfile points away from the current Alicorn pin and must not be
copied.

The draft's Pinned context-menu expansion is not adopted: its command enablement
and execution depend on global editor state, and the same draft removes the
visible current/stale/missing status cue from Pinned excerpts. The private-node
editor-row trace is retained only as opt-in diagnostic code already present on
`main`; it is not a pattern for normal application components or a stable API
contract.

## Recommended next slices

1. Migrate symbol-picker navigation and text changes to a retained interaction
   scope and `Roving_View`; keep source navigation and page requests in
   `projection_sidebar_navigate` and the existing application service.
2. Give workspace-address and font-picker controls their own scoped input
   ownership. Preserve workspace validation/confirmation and disabled-font
   behavior in their existing application code.
3. Introduce a typed command-binding table for stable global shortcuts only
   after command IDs, menu accelerators, text-field precedence, and IME policy
   have one documented source. Keep dynamic context commands and editor
   transactions application-owned.
4. Split `build_app` into named prepare/adopt, describe, and after-frame stages
   without changing ordering. Verify caret, scroll anchors, source-window
   revisions, and deferred operations before considering any scheduling change.
5. Revisit Settings' two-pass content sizing with large text, narrow windows,
   and long labels as acceptance cases. Retain the current layout if Alicorn's
   intrinsic sizing cannot express the same scroll extent reliably.

These are migration slices, not a request for a new frontend framework. Each
should keep its existing Go/backend authority and be adopted only where
Alicorn's public primitive matches the behavior already required by Scratchpad.
