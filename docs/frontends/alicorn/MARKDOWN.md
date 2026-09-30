# Bounded Markdown presentation — first Alicorn slice

## Research verdict

Scratchpad already lowers Goldmark into `document.MarkdownPresentation` source spans and `BlockPresentation` ranges. Shirei's Markdown presentation remains the behavioral oracle. Reuse these projections; do not parse Markdown in Odin or transfer an AST.

The missing integration was the foreign backend's asynchronous projection lifecycle. It activates on the first Markdown presentation request; clients using the default resource format do not start new parser work. It must drive the application's existing debounced worker coordinator, publish exact-revision readiness, and wake sleeping clients when a projection becomes available. Parsing stays outside the visible-window request. No periodic frontend polling is required.

## Ownership

Go owns raw source, Markdown meaning, absolute source-byte ranges, revision validation, and disposable projection workers. Caliber carries immutable bounded resources and wakes; its ABI does not gain Markdown concepts. Scratchpad's Odin frontend maps source ranges through its existing byte-safe display projection. Alicorn paints generic UTF-8 byte spans on one shaped text run, without changing metrics or caret/selection geometry.

Syntax remains visible. Tabs, BOMs, CRLF, invalid bytes, and saved bytes retain their existing source mapping. Styling is disposable and applies only to an exact, authoritative Markdown window. Optimistic edits, stale presentation, and IME preedit render plain text until current metadata arrives.

## Resource extension

`read_visible_lines` defaults to the unchanged SPVS v1 payload, so existing GPUI clients need no decoder changes. `include_presentation=true` requests SPVS v2. Its first 48 bytes and following raw source bytes retain the v1 layout and meanings; the descriptor's `byte_len` still counts only source bytes.

The appended little-endian trailer has a 24-byte header: presentation revision (`u64`), flags (`u32`, ready=1 and truncated=2), span count (`u32`), block count (`u32`), and a zero reserved word (`u32`). Span records followed by block records each occupy 16 bytes: explicit wire kind, start, end, and level/flags (`u32` each). The low eight bits hold level; block bits 8 and 9 indicate clipping at the window start and end. Ranges are half-open, relative to the returned source window, and clipped to it. Wire IDs are explicit constants rather than Go enum ordinals.

The source limit remains 64 KiB / 256 logical lines, with 16 KiB anchored long-line chunks. Metadata is capped at 4,096 combined records plus its header. A pathological window may truncate metadata while retaining all its bounded source; the flag makes that degradation explicit. Pending or unsupported presentation produces plain source. Revision/readiness changes trigger a request through the existing latest-wins visible-window lane, not a fourth async lane.

## Styling and next gate

This slice uses colors, underline/strikethrough, and solid backgrounds for headings, inline code, links, blockquotes, lists, and tasks. Shaping-aware text style spans map strong to bold and emphasis to italic; heading levels use modest font weights without changing font size. These spans use the same source-to-display byte mapping and exact-revision gate as paint spans. Paint spans remain paint-only and preserve shaping and caret geometry. Typography can change glyph shaping within the fixed row height while source text stays unchanged. It does not claim full Shirei appearance parity.

Soft wrapping/visual rows (issue #8) is the next geometry gate. Heading sizes, richer blocks, code/table presentation, and full Markdown parity follow it. Ordinary advanced editor gestures remain outside this slice. Shirei remains the default/product frontend.

## Validation limits

Headless tests must cover exact/stale revision handling, metadata bounds and malformed payloads, source/display mapping, lease ownership, and unchanged caret/layout geometry under paint spans. Typography tests verify semantic ranges and source preservation; shaping changes are expected for those spans. Native startup smoke verifies publication, wake, presentation, and shutdown; it does not certify visual style or native IME. Windows/macOS visual checks and the remaining Phase 4 manual matrix must be recorded separately before release certification.

## Validation recorded for Markdown A

On Windows, the locked dependency validation passes root Go tests (including the existing Shirei editor/UI), cgo bridge tests, Odin type checking, nine bridge tests, and forty frontend tests. The bridge also passes `go test -race ./...` with the canonical Caliber header and actual library. GPUI's eighteen unit tests, foreign smoke, and `cargo clippy --all-targets -- -D warnings` pass with the locked Caliber source.

The locked native Alicorn smoke passes startup, publication, wake, GPU submission, and ordered shutdown. The real-backend Markdown regression covers pending-to-ready publication, edit invalidation, retained row identity, unchanged shaped-run/caret/hit geometry, source fidelity, and request deduplication. Alicorn's foundation/runtime/native suites pass, including dense decorated-span allocation and geometry checks.

The bounded transport benchmark caps a 20,000-block fixture at 4,096 records (about 120 microseconds per query on this machine). A late-viewport query with an enclosing span and 100,000 indexed spans takes about 3 microseconds; indexed subtree end bounds prevent scanning all earlier spans. These are local microbenchmarks, not end-to-end typing measurements.

macOS/Linux execution, native Markdown appearance, and the remaining Phase 4 pointer/clipboard/IME certification were not performed in this slice. Issue #7 remains partial; wrapping and richer Markdown presentation are not implemented here.
