# Source-preserving Markdown presentation — Alicorn

## Research verdict

Scratchpad already lowers Goldmark into `document.MarkdownPresentation` source spans and `BlockPresentation` ranges. Shirei's Markdown presentation remains the behavioral oracle. Reuse these projections; do not parse Markdown in Odin or transfer an AST.

The missing integration was the foreign backend's asynchronous projection lifecycle. It activates on the first Markdown presentation request; clients using the default resource format do not start new parser work. It must drive the application's existing debounced worker coordinator, publish exact-revision readiness, and wake sleeping clients when a projection becomes available. Parsing stays outside the visible-window request. No periodic frontend polling is required.

## Ownership

Go owns raw source, Markdown meaning, absolute source-byte ranges, revision validation, and disposable projection workers. Caliber carries immutable bounded resources and wakes; its ABI does not gain Markdown concepts. Scratchpad's Odin frontend maps source ranges through its existing byte-safe display projection. Alicorn paints generic UTF-8 byte spans on one shaped text run, without changing metrics or caret/selection geometry.

Syntax remains visible. Tabs, BOMs, CRLF, invalid bytes, and saved bytes retain their existing source mapping. Styling is disposable. Exact authoritative metadata is used normally; during optimistic edits, Alicorn shifts unaffected ranges and conservatively drops ranges intersected ambiguously by the edit. That rebased metadata keeps presentation visually continuous while remaining presentation-only: semantic commands and source mutations still require current authoritative state. IME preedit remains transient and is not parsed locally.

## Resource extension

`read_visible_lines` defaults to the unchanged SPVS v1 payload, so existing GPUI clients need no decoder changes. `include_presentation=true` requests SPVS v2. Its first 48 bytes and following raw source bytes retain the v1 layout and meanings; the descriptor's `byte_len` still counts only source bytes.

The appended little-endian trailer has a 24-byte header: presentation revision (`u64`), flags (`u32`, ready=1 and truncated=2), span count (`u32`), block count (`u32`), and a zero reserved word (`u32`). Span records followed by block records each occupy 16 bytes: explicit wire kind, start, end, and level/flags (`u32` each). The low eight bits hold level; block bits 8 and 9 indicate clipping at the window start and end. Ranges are half-open, relative to the returned source window, and clipped to it. Wire IDs are explicit constants rather than Go enum ordinals.

The source limit remains 64 KiB / 256 logical lines, with 16 KiB anchored long-line chunks. Metadata is capped at 4,096 combined records plus its header. A pathological window may truncate metadata while retaining all its bounded source; the flag makes that degradation explicit. Pending or unsupported presentation without a safe rebased snapshot produces plain source. Revision/readiness changes trigger a request through the existing latest-wins visible-window lane, not a fourth async lane.

## Markdown A — bounded semantics and typography

Markdown A supplies revision-tagged semantic spans and block ranges. Shaping-aware text style spans map strong to bold and emphasis to italic. Paint spans add colors, links, inline-code backgrounds, and strike-through while preserving the source bytes. Presentation metadata applies only to an exact authoritative revision.

## Markdown B — structural source presentation

The visible editor remains a source editor. It keeps Markdown punctuation in place and derives presentation from Goldmark's existing spans and block ranges; the Odin frontend does not parse Markdown or construct a second document model.

All six heading levels have distinct weight and color, with progressively larger measured row spacing for higher-level headings. Blockquote, fenced-code, list, thematic-break, and table meaning is shown through source typography, markers, and spacing; full-width semantic row fills are omitted so selection and text remain visually dominant. List and task markers are emphasized; completed task text is struck through as presentation only. Table headers are bold, delimiters and separators are subdued, and source columns can be aligned with Document > Format Table. Tab/Shift+Tab and Enter use Scratchpad's table navigation commands. These actions are published to Alicorn whenever a Markdown document is active; Go validates them against the current frontend caret and authoritative source. Their result distinguishes a source edit, a caret-only move, an already-formatted table, and an unavailable or unsafe operation. Caret-only navigation does not create a document revision or undo record. If a table cannot be safely formatted, Scratchpad reports why rather than silently treating refusal as an already-formatted no-op. Fenced code and tables retain horizontal scrolling; prose continues to wrap.

These treatments change only derived layout and paint. The displayed source, caret/selection coordinates, edit ranges, and saved bytes remain source-mapped. Heading, thematic-break, and table-header spacing is included in sparse row-height measurement, so navigation, selection, and scroll anchoring use the presented geometry.

Soft wrapping now operates on the final shaped typography. One logical Markdown source line can contain multiple Runa visual rows, while Scratchpad continues to own the logical line and source-byte ranges. The bounded Odin frontend measures only the loaded 64 KiB / 256-line window; Alicorn's sparse variable-height list index maps logical rows to scroll geometry without allocating one height entry per document line. Caret navigation, hit testing, selection, and caret geometry use the wrapped run. Home/End remain logical-line boundaries.

Markdown and plain-text prose wrap; exact Markdown fenced-code and table records remain horizontally scrollable, as do ordinary code-language files. The document retains one horizontal scroll position, but Alicorn applies it only inside clipped no-wrap row lanes; wrapped prose and the line-number gutter stay fixed. Horizontal extent is measured from rows near the viewport, so a distant table does not leave a scrollbar over an all-prose view. The per-document horizontal position is retained while that lane is temporarily hidden. Runa's constrained shaping handles long unbroken words at grapheme boundaries. Width changes remeasure the bounded source window and keep the top visible logical line plus its pixel offset stable. Local source edits invalidate and shift the affected sparse row measurements; authoritative Undo/Redo revisions clear stale measurements.

After an optimistic edit, presentation ranges that were explicitly rebased with the source remain usable for visual continuity across the edit acknowledgement. As Goldmark catches up, Alicorn can take an exact projection for an acknowledged revision and chase it through the remaining queued replacements, so newly formed headings and inline constructs can appear styled while typing continues. Rebased ranges remain presentation-only and never authorize source mutation; the next exact projection replaces them when it arrives. Table commands use the frontend's current caret and selection snapshot, while Go synchronously validates table context against authoritative source before applying a command.

The recorded Markdown A and soft-wrap coverage verifies exact-revision styling, source/display mapping, wrapped visual-row navigation and selection, no-wrap policy for code/tables, long-word wrapping, sparse height shifts, and resize anchoring. Markdown B's visual appearance still needs a desktop review on Windows and macOS alongside the existing resize, scrolling, and IME candidate-position checks. This pass does not claim full Shirei appearance or Markdown-command parity. Shirei remains the default/product frontend.

## Validation limits

Headless tests must cover exact/stale revision handling, metadata bounds and malformed payloads, source/display mapping, lease ownership, and unchanged caret/layout geometry under paint spans. Typography tests verify semantic ranges and source preservation; shaping changes are expected for those spans. Native startup smoke verifies publication, wake, presentation, and shutdown; it does not certify visual style or native IME. Windows/macOS visual checks and the remaining Phase 4 manual matrix must be recorded separately before release certification.

## Validation recorded for Markdown A

On Windows, the locked dependency validation passes root Go tests (including the existing Shirei editor/UI), cgo bridge tests, Odin type checking, nine bridge tests, and forty frontend tests. The bridge also passes `go test -race ./...` with the canonical Caliber header and actual library. GPUI's eighteen unit tests, foreign smoke, and `cargo clippy --all-targets -- -D warnings` pass with the locked Caliber source.

The locked native Alicorn smoke passes startup, publication, wake, GPU submission, and ordered shutdown. The real-backend Markdown regression covers pending-to-ready publication, edit invalidation, retained row identity, unchanged shaped-run/caret/hit geometry, source fidelity, and request deduplication. Alicorn's foundation/runtime/native suites pass, including dense decorated-span allocation and geometry checks.

The bounded transport benchmark caps a 20,000-block fixture at 4,096 records (about 120 microseconds per query on this machine). A late-viewport query with an enclosing span and 100,000 indexed spans takes about 3 microseconds; indexed subtree end bounds prevent scanning all earlier spans. These are local microbenchmarks, not end-to-end typing measurements.

macOS/Linux execution and native Markdown appearance/wrap feel were not manually checked in this slice. Native Phase 4 pointer/clipboard/IME certification also remains open. Markdown blocks and full product presentation remain incomplete.
