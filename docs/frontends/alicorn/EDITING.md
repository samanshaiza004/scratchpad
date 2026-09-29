# Alicorn editing ownership contract

Status: Phase 4C.1–4C.5 implemented: optimistic insertion/replacement, deletion, stale recovery, Scratchpad-owned Enter semantics, and platform-normalized keyboard editing. This document records ownership boundaries and invariants for the experimental Alicorn frontend; it is a constitution, not a complete editor specification. Clipboard, undo/redo, editor IME, and full editor parity are not claimed.

## Ownership

| Concern | Owner |
|---|---|
| Complete document bytes and document/editor revisions | Scratchpad (Go) |
| Undo/redo history, dirty state, save, and external-change/conflict semantics | Scratchpad (Go) |
| Caret, directional selection, preferred X, and viewport/scroll state | Alicorn frontend (Odin) |
| Shaped visible rows, pointer hit testing, and bidi visual affinity | Alicorn frontend and Alicorn/Runa presentation |
| IME preedit/composition display | Alicorn frontend and native text-input presentation |
| Unacknowledged optimistic source bytes | Alicorn frontend, pending reconciliation with Scratchpad |
| Committed source edits | Alicorn applies a bounded optimistic projection; Scratchpad remains authoritative through the existing `replace_document` command and revision acknowledgement |
| Bounded commands and resources, wakeups, and cross-language ownership/lifetimes | Caliber |

The frontend may keep bounded visible source windows and an optimistic projection for responsive presentation. These do not replace Scratchpad's authoritative document or revision. Alicorn owns interaction and presentation state; it does not define Scratchpad document or file semantics.

## Invariants

1. Cursor movement stays in the Alicorn frontend; cursor movement never crosses Caliber.
2. Selection movement and changes stay in the Alicorn frontend; selection state never crosses Caliber.
3. IME preedit/composition stays in the Alicorn frontend and is presentation state until commit; preedit never crosses Caliber.
4. Whole-document bytes never cross Caliber. Source transfer remains bounded to the requested visible/resource window.
5. Every source mutation must eventually converge to an authoritative Scratchpad editor revision. Optimistic frontend state is pending until accepted or reconciled with that authority.

Committed source edits are projected locally before dispatch. The frontend retains ordered edit intents and sends only one existing `replace_document` request at a time; later edits remain local until each preceding editor-revision acknowledgement arrives. Enter sends a literal LF through that same range-replacement command, allowing Scratchpad's Go editor to choose the document's line-ending convention and leading indentation. The existing acknowledgement now includes the effective inserted bytes when those semantics transform the requested LF, so the frontend can reconcile its projection and rebase queued offsets without synchronous whole-document access. Caliber carries bounded edit commands, acknowledgements, and their lifecycle; it does not become an editor model or a second source of document truth.

## Phase 4B — interactive read-only substrate

The Alicorn surface gives the durable editor viewport text-input focus, places a caret by hit-testing the retained Runa run for a realized source row, and supports Left/Right, Home/End, Up/Down, Page Up/Down, preferred-X retention, directional Shift selection, and in-viewport captured drag selection over the bounded display projection. Caret and directional anchor remain frontend-local source-byte offsets. Expanded tabs and escaped invalid bytes are treated as indivisible source units, and horizontal movement uses Runa grapheme boundaries.

## Phase 4C.1 — committed text insertion

Committed SDL text is applied immediately to a per-document optimistic copy of the bounded visible source window; the caret advances before the foreign command is dispatched. The frontend queues source insertions locally and permits exactly one in-flight `replace_document` request. Each acknowledgement advances the expected Scratchpad editor revision before the next queued request is sent. Caliber leases remain short-lived and the UI thread consumes the publication after the worker command finishes.

This slice accepts insertion within the loaded bounded window. Save, close, and navigation actions remain visually stable and are deferred behind pending edits, so they cannot overtake queued text without leaking transport latency into the chrome. Headless integration holds the worker before dispatch, verifies immediate local presentation while Go still owns the original bytes, then releases the lane and checks serial editor revisions converge.

## Phase 4C.2–4C.4 — replacement, recovery, and Enter

Selection replacement and Backspace/Delete use the same local range-replacement path, including cross-line joins. Stale acknowledgements discard the dependent optimistic chain, reload a fresh authoritative bounded window, normalize the caret, and allow editing to resume. Enter is projected locally using the visible line ending/indentation, while Scratchpad remains authoritative for the actual line ending and indentation rule. If its effective replacement differs, the acknowledgement patches the optimistic source and rebases queued edit ranges and local positions. The regression holds the serial lane across two Enter operations and a subsequent character, verifies immediate multi-line/line-count presentation, then checks authoritative revision and bytes converge. Clipboard, undo/redo, and editor IME remain subsequent slices.

## Phase 4C.5 — keyboard ownership and word editing

The native host checks menu/global shortcuts before routing normalized text-key intents to the focused generic text-input owner. That owner gets first refusal on Tab; if it declines, forward/backward focus traversal remains the fallback. Scratchpad inserts four spaces for Tab and removes one indentation unit from the caret's current line for Shift+Tab. The host translates platform-specific Ctrl/Option word keys, line-edge keys, and document-edge keys into semantic intents; Scratchpad applies Runa word boundaries to the bounded display projection and maps them back to source byte offsets. Word deletion and movement stay frontend-local except that deletion uses the existing serial source-replacement lane. Multi-line selection indentation and unsupported paragraph-navigation chords remain deferred.
