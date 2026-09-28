# Alicorn editing ownership contract

Status: Phase 4C.1 committed-text insertion implemented. This document records ownership boundaries and invariants for the experimental Alicorn frontend; it is a constitution, not a complete editor specification. Editing remains intentionally limited; selection replacement, deletion, undo/redo, clipboard, and IME parity are not claimed.

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

Committed text is projected locally before dispatch. The frontend retains ordered edit intents and sends only one `replace_document` request at a time; later keystrokes remain local until each preceding editor-revision acknowledgement arrives. No new backend API or protocol was added. Caliber carries bounded edit commands and their lifecycle; it does not become an editor model or a second source of document truth.

## Phase 4B — interactive read-only substrate

The Alicorn surface gives the durable editor viewport text-input focus, places a caret by hit-testing the retained Runa run for a realized source row, and supports Left/Right, Home/End, Up/Down, Page Up/Down, preferred-X retention, directional Shift selection, and in-viewport captured drag selection over the bounded display projection. Caret and directional anchor remain frontend-local source-byte offsets. Expanded tabs and escaped invalid bytes are treated as indivisible source units, and horizontal movement uses Runa grapheme boundaries.

## Phase 4C.1 — committed text insertion

Committed SDL text is applied immediately to a per-document optimistic copy of the bounded visible source window; the caret advances before the foreign command is dispatched. The frontend queues source insertions locally and permits exactly one in-flight `replace_document` request. Each acknowledgement advances the expected Scratchpad editor revision before the next queued request is sent. Caliber leases remain short-lived and the UI thread consumes the publication after the worker command finishes.

This slice accepts insertion only at a collapsed selection and within the loaded bounded window. It intentionally does not implement line breaks, selection replacement, Backspace/Delete, clipboard, undo/redo, indentation policy, or document-view IME composition. Save, close, and navigation commands are held off while local edits are pending so they cannot overtake queued text. Headless integration holds the worker before dispatch, verifies immediate `hello worxabcdefld` local presentation while Go still owns `hello world`, then releases the lane and checks seven serial editor revisions converge to the same bytes.
