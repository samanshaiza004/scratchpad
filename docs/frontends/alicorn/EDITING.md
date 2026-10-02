# Alicorn editing ownership contract

Status: ordinary editing and soft wrapping/visual rows are implemented and headless-tested, including pointer selection, multiline indentation, clipboard, undo/redo, IME composition, and source-preserving reflow. Native Windows/macOS click-count, modifier, drag-autoscroll, clipboard, IME, and wrap-resize behavior still needs manual verification. This document records ownership boundaries, invariants, and the editing contract for the supported Alicorn frontend.

## Ownership

| Concern | Owner |
|---|---|
| Complete document bytes and document/editor revisions | Scratchpad (Go) |
| Undo/redo history, dirty state, save, and external-change/conflict semantics | Scratchpad (Go) |
| Caret, directional selection, preferred X, and viewport/scroll state | Alicorn frontend (Odin) |
| Shaped visible rows, pointer hit testing, and bidi visual affinity | Alicorn frontend and Alicorn/Runa presentation |
| OS clipboard access and UTF-8 transfer | Alicorn SDL host service; Scratchpad frontend owns Copy/Cut/Paste semantics |
| IME preedit/composition display and candidate positioning | Alicorn frontend and native text-input presentation |
| Unacknowledged optimistic source bytes | Alicorn frontend, pending reconciliation with Scratchpad |
| Committed source edits | Alicorn applies a bounded optimistic projection; Scratchpad remains authoritative through the existing `replace_document` command and revision acknowledgement |
| Bounded commands and resources, wakeups, and cross-language ownership/lifetimes | Caliber |

The frontend may keep bounded visible source windows and an optimistic projection for responsive presentation. These do not replace Scratchpad's authoritative document or revision. Alicorn owns interaction and presentation state; it does not define Scratchpad document or file semantics.

## Invariants

1. Cursor movement stays in the Alicorn frontend; cursor movement never crosses Caliber.
2. Selection movement and changes stay in the Alicorn frontend; selection state never crosses Caliber.
3. IME preedit/composition stays in the Alicorn frontend and is presentation state until commit; preedit never crosses Caliber. A commit becomes one ordinary bounded optimistic source edit.
4. Whole-document bytes never cross Caliber. Source transfer remains bounded to the requested visible/resource window.
5. Every source mutation must eventually converge to an authoritative Scratchpad editor revision. Optimistic frontend state is pending until accepted or reconciled with that authority.

Committed source edits are projected locally before dispatch. The frontend retains ordered edit intents and sends only one existing `replace_document` request at a time; later edits remain local until each preceding editor-revision acknowledgement arrives. Enter sends a literal LF through that same range-replacement command, allowing Scratchpad's Go editor to choose the document's line-ending convention and leading indentation. The existing acknowledgement now includes the effective inserted bytes when those semantics transform the requested LF, so the frontend can reconcile its projection and rebase queued offsets without synchronous whole-document access. Caliber carries bounded edit commands, acknowledgements, and their lifecycle; it does not become an editor model or a second source of document truth.

## Phase 4B — interactive read-only substrate

The Alicorn surface gives the durable editor viewport text-input focus and places a caret by hit-testing the retained Runa run for a realized source row. It supports grapheme-aware Left/Right, Home/End, Up/Down, Page Up/Down, preferred-X retention, and directional Shift selection over the bounded display projection. Single click places a caret; Shift-click extends from the existing anchor. Double-click selects the Runa UAX #29 segment under the pointer, and double-click-drag extends by whole segments. Triple-click selects logical line content without its line terminator, matching Shirei; triple-click-drag extends by logical lines. Dragging preserves the selection granularity chosen at pointer-down. While a captured drag remains outside the editor viewport, one-shot scheduled wakes scroll vertically or horizontally toward the pointer, stopping at scroll limits and on pointer-up/cancel. Caret and directional anchor remain frontend-local source-byte offsets. Expanded tabs and escaped invalid bytes are treated as indivisible source units, and horizontal movement uses Runa grapheme boundaries.

## Phase 4C.1 — committed text insertion

Committed SDL text is applied immediately to a per-document optimistic copy of the bounded visible source window; the caret advances before the foreign command is dispatched. The frontend queues source insertions locally and permits exactly one in-flight `replace_document` request. Each acknowledgement advances the expected Scratchpad editor revision before the next queued request is sent. Caliber leases remain short-lived and the UI thread consumes the publication after the worker command finishes.

This slice accepts insertion within the loaded bounded window. Save, close, and navigation actions remain visually stable and are deferred behind pending edits, so they cannot overtake queued text without leaking transport latency into the chrome. Headless integration holds the worker before dispatch, verifies immediate local presentation while Go still owns the original bytes, then releases the lane and checks serial editor revisions converge.

## Phase 4C.2–4C.4 — replacement, recovery, and Enter

Selection replacement and Backspace/Delete use the same local range-replacement path, including cross-line joins. Stale acknowledgements discard the dependent optimistic chain, reload a fresh authoritative bounded window, normalize the caret, and allow editing to resume. Enter is projected locally using the visible line ending/indentation, while Scratchpad remains authoritative for the actual line ending and indentation rule. If its effective replacement differs, the acknowledgement patches the optimistic source and rebases queued edit ranges and local positions. The regression holds the serial lane across two Enter operations and a subsequent character, verifies immediate multi-line/line-count presentation, then checks authoritative revision and bytes converge. Clipboard, undo/redo, and editor IME are documented in phases 4D–4F below.

## Phase 4C.5 — keyboard ownership and word editing

The native host checks menu/global shortcuts before routing normalized text-key intents to the focused generic text-input owner. That owner gets first refusal on Tab; if it declines, forward/backward focus traversal remains the fallback. A collapsed Tab inserts four spaces; Tab with a non-empty selection indents every touched logical line; Shift+Tab outdents the touched lines or the caret's current line. Each line-wide operation uses one bounded source replacement and one undo record, preserves selection direction, and refuses when a touched line is incomplete in the authoritative window. The host translates platform-specific Ctrl/Option word keys, line-edge keys, and document-edge keys into semantic intents; Scratchpad applies the same Runa UAX #29 segmentation for word movement, deletion, and pointer selection, mapping display positions back to source byte offsets. Word deletion and movement stay frontend-local except that deletion uses the existing serial source-replacement lane.

## Phase 4D — clipboard

The SDL host owns native plain-text clipboard access and returns UTF-8 text; it does not interpret editor commands. Copy requires a selection fully present in the bounded source window and valid UTF-8. Cut copies the exact visible Markdown source bytes first, then queues one ordinary deletion. Paste sends the selected source range and plain clipboard bytes to Scratchpad's authoritative paste_document command, which normalizes line endings and records one undo transaction. In Markdown only, a clean HTTP(S) URL over a non-empty, single-line selection becomes a Markdown link; other content and all non-Markdown documents receive plain text. HTML and rich clipboard representations are ignored. Empty paste is a no-op. Select All adjusts frontend-local selection to the current projected document extent. Edit payloads are bounded to 128 KiB while the visible source window remains capped at 64 KiB, allowing a 100 KiB paste without copying the whole document into Odin.

## Phase 4D — current-file Find and Replace

Find queries the authoritative Go document buffer, including unsaved edits. Alicorn retains only bounded match coordinates and selection/focus state; those source-byte ranges remain valid through Markdown styling and soft-wrapped display rows. Find Next/Previous wraps at document ends and reveals an active match near the viewport center without moving a match already comfortably visible. Replace Current revalidates the exact query/range against the current editor revision before applying one ordinary source edit. Replace All computes literal, non-overlapping matches in Go and sends no document snapshot through Caliber; the entire replacement is one atomic undo transaction. Match coordinates refresh immediately against the new revision. Workspace-wide replacement and regular expressions are out of scope.

## Phase 4E — authoritative undo and redo

The Go editor remains the sole owner of history. Undo/Redo are semantic Scratchpad commands; if local edits are still awaiting acknowledgement, the frontend queues the history command until those edits settle. Scratchpad returns the restored anchor, cursor byte, and cursor line so Alicorn restores local selection and scrolls the caret into view. Alicorn does not mirror the undo stack. Undo/Redo state is published with document metadata and reflected in the Edit menu.

## Phase 4F — IME composition

SDL editing/preedit events update a transient frontend-only projection over the original selected source range. They do not mutate committed source bytes, create a revision, or dispatch Caliber edits. A committed text-input event becomes an ordinary optimistic range replacement; if the bounded edit is rejected, committed text remains recoverable across SDL's terminal cancel and document switches. Further commits append without replacing prior bytes. If one commit crosses the 128 KiB recovery threshold, Alicorn preserves that commit with one exact-size growth and immediately suspends its generic text-input target; later commits are refused without changing retained recovery text. Copy clears recovery only after the OS clipboard write succeeds; close offers Copy Recovery, Discard Recovery, or Cancel, while save/discard close paths retain a backstop guard. Ordinary uncommitted preedit cancellation clears the transient projection. The native host updates SDL's text-input target rectangle from shaped caret geometry so candidate UI can follow the caret. Native composition and candidate placement remain platform-sensitive and require manual Windows/macOS verification.

## Phase 4G — closeout boundary

Pointer selection supports Shift-click, UAX #29 word double-click/drag, logical-line triple-click/drag, and captured-drag autoscroll on both axes. Tab/Shift+Tab applies one undoable indent/outdent transaction across the touched lines when the complete range is present in the bounded window. Headless tests cover these semantics and the existing clipboard, history, bounded-edit, and IME recovery paths. Native Windows/macOS click-count and modifier delivery, drag autoscroll feel, clipboard, Japanese composition/conversion/cancellation, candidate placement, and idle-after-edit still require manual platform verification.

## Phase 5A — soft wrapping and visual rows

Scratchpad keeps logical source lines as the stable edit identity. For prose, Alicorn shapes each bounded logical line with its final exact-revision typography spans and the current text width; Runa then supplies the visual rows, caret geometry, selection rectangles, and hit-test positions. The bytes and source/display map do not change. A logical line can therefore render as several visual rows without creating new source lines.

Up/Down move between adjacent shaped visual rows, including rows within one logical line. Page Up/Down target a content-space position using measured variable row heights. The preferred horizontal caret position survives row transitions. Home/End remain logical-line edges; soft wrapping does not redefine them. Pointer selection, caret reveal, IME candidate positioning, and source-byte mapping use Runa's wrapped run geometry.

Markdown and plain-text prose wrap. Markdown tables use parser-provided trimmed cell ranges and one shared column plan per table, so rows cannot independently switch between wrapping and overflow. Delimiter rows do not affect content sizing. Long prose cells become aligned visual subrows while the file keeps one physical source line per row. If the table-wide minimum column widths do not fit, all rows use the horizontal overflow lane; fenced code and ordinary language/code files remain unwrapped. Width changes reshape only the current bounded source window, and the visible logical-line anchor plus its intra-row offset is retained through reflow.

Alicorn's variable-height virtual-list index stores measured overrides sparsely from the fixed row-height estimate. Source edits drop measurements for touched logical lines and shift unaffected suffix identities. Undo/redo or other external authoritative revision changes discard old measurements before remeasurement. Shaping work remains bounded by the loaded source window rather than the full document. Existing automated integration covers styled multi-row shaping, source fidelity, within-line keyboard movement/selection, code wrapping and table overflow fallback, long-word fallback, line-count edits, and resize anchoring. The new cell-wrapped table path compiles but still needs focused automated coverage. Native resize, table selection, scroll, and IME checks remain platform certification work.
