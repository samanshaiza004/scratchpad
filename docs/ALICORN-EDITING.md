# Alicorn editing ownership contract

Status: Phase 4 kickoff. This document records ownership boundaries and invariants for the experimental Alicorn frontend; it is a constitution, not an implementation specification. No editing or IME parity is claimed yet.

## Ownership

| Concern | Owner |
|---|---|
| Complete document bytes and document/editor revisions | Scratchpad (Go) |
| Undo/redo history, dirty state, save, and external-change/conflict semantics | Scratchpad (Go) |
| Caret, directional selection, preferred X, and viewport/scroll state | Alicorn frontend (Odin) |
| Shaped visible rows, pointer hit testing, and bidi visual affinity | Alicorn frontend and Alicorn/Runa presentation |
| IME preedit/composition display | Alicorn frontend and native text-input presentation |
| Unacknowledged optimistic source bytes | Alicorn frontend, pending reconciliation with Scratchpad |
| Committed source edits | Scratchpad remains authoritative; an IME commit is one source edit |
| Bounded commands and resources, wakeups, and cross-language ownership/lifetimes | Caliber |

The frontend may keep bounded visible source windows and an optimistic projection for responsive presentation. These do not replace Scratchpad's authoritative document or revision. Alicorn owns interaction and presentation state; it does not define Scratchpad document or file semantics.

## Invariants

1. Cursor movement stays in the Alicorn frontend; cursor movement never crosses Caliber.
2. Selection movement and changes stay in the Alicorn frontend; selection state never crosses Caliber.
3. IME preedit/composition stays in the Alicorn frontend and is presentation state until commit; preedit never crosses Caliber.
4. Whole-document bytes never cross Caliber. Source transfer remains bounded to the requested visible/resource window.
5. Every source mutation must eventually converge to an authoritative Scratchpad editor revision. Optimistic frontend state is pending until accepted or reconciled with that authority.

An IME commit is submitted as one source edit, not as a stream of preedit updates. Caliber carries bounded, ordered edit commands and their lifecycle; it does not become an editor model or a second source of document truth.
