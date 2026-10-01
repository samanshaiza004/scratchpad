# Overflow lane + Org-style tables spec

Note: repo has no configured issue tracker (`/setup-matt-pocock-skills` never run), so this spec is published as a docs file instead of a tracked issue. No `ready-for-agent` label applied.

## Problem Statement

Wide unwrapped rows (Markdown tables, long code lines) overflow the editor viewport and are clipped with no way to read them. Tables are additionally a single whole-block projection with no row/cell/pipe geometry, so columns cannot align, pipes cannot mute, and `Tab`/`Enter` cannot navigate fields. Checkbox toggle only exists in the Outline sidebar, not at the caret.

## Solution

Keep files ordinary Markdown at all times: explicit formatting may align columns by padding source spaces (Org/`markdown-mode` model), while presentation can wrap table cells into aligned visual subrows without changing the file. Use parser-provided row/cell/pipe geometry; do not build a virtual grid renderer.

Correction accepted: `md-mode` auto-align default is `t` per current docs (earlier audit said `nil` from an older README). Precedent taken from `md-mode` is edit-view source honesty + unwrapped wide rows + cursor-following, not the default value.

## User Stories

1. As a notes author, I want long table cells to wrap into aligned visual subrows when useful column widths fit, so that I can read summaries without rewriting source.
2. As a notes author, I want tables with too many columns or very long unbroken tokens to retain horizontal overflow, so that each column still has useful space.
3. As a notes author, I want the caret and selection to map to source bytes in wrapped continuations, so that the source remains directly editable.
4. As a notes author, I want Tab/Shift+Tab to navigate semantic cells regardless of their visual row count, so that table navigation stays structural.
5. As a notes author, I want resize to reflow cells without changing bytes, dirty state, or the source-row count.
6. As a notes author, I want wrapped cells and prose to remain fixed while only true overflow rows shift horizontally.
7. As a notes author, I want the gutter/line numbers to stay fixed while overflow scrolls, so that I keep my place.
8. As a code author, I want long code lines to use the same overflow lane, so that the fix is not table-specific debt.
9. As a Markdown author, I want `Format Table` to pad columns with real spaces, so that the file stays valid Markdown and caret/copy/save stay trivial.
10. As a reader of unaligned files, I want nothing rewritten on open, so that dirty state is never invented (explicit align only, like `md-mode` opt-in).

## Implementation Decisions

- Original slices 1–6 (overflow lane, row/cell/pipe projection, table visuals, `Format Table`, cell navigation, and task toggle) are implemented. Cell-aware visual rows are a follow-on presentation slice: parser-owned cell boundaries feed bounded width measurement, per-cell shaping, source-mapped hit testing, and sparse logical-row height updates. Manual table selection/resize/IME checks remain a release-hardening follow-up.
- Slice 1 — overflow lane (UI-only, no buffer/document-text change):
  - `scrollX` lives in document view state alongside `ScrollY` (per-document, session-disposable like `ScrollY`, not part of `Document` text authority).
  - Applies only to no-wrap code rows and table rows that fail the cell-width fit rule. Wrapped prose and cell-wrapped table rows stay at x=0 and ignore `scrollX`.
  - Alicorn keeps the scroll owner on its variable-height list. Scratchpad counter-shifts the line-number gutter and wrapped prose so only no-wrap row content moves. The horizontal bar follows no-wrap rows near the viewport and can disappear over wrapped-only sections without discarding the saved per-document X position.
  - Caret-follow: when caret enters a wide row, adjust `scrollX` just enough to keep caret visible (with small padding); when caret returns to wrapped prose, reset/ignore it. Mouse click into overflow maps through `scrollX`. Gutter stays fixed.
  - No generic sideways shift of wrapped prose. No vertical behavior change. No new dependencies.
- Slice 2 — table projection (parser-owned, UI-agnostic):
  - Goldmark remains behind `language/markdown`; Shirei types/colors never cross into it.
  - Shape (byte ranges only):
    - `TableProjection { StartByte, EndByte, Columns []TableColumn, Rows []TableRow }`
    - `TableColumn { Alignment }` from delimiter colons (default/left/center/right); no numeric inference (Markdown colons are the source of truth, unlike Org).
    - `TableRow { StartByte, EndByte, Header, Delimiter bool, Cells []TableCell, Pipes []ByteRange }`
    - `TableCell { StartByte, EndByte, Column }`
  - Explicit pipe ranges required so UI never re-parses syntax (preserves parser/UI split).
  - Hard cases owned by the projection/aligner: escaped `\|` (the only way to keep a pipe inside inline content), unescaped pipes inside code spans split like any other GFM delimiter, optional leading/trailing pipes, inline markup (`**`, links), Unicode/CJK/emoji display width measured from source-aware visible content, uneven rows.
  - Existing whole-block `BlockTable`/`PresentationTable` remains the block/source styling seam; the row/cell/pipe projection is additive, revision-tagged + disposable like current projections.
- Slice 3 — visuals only: faint cool well (block), stronger header surface + bold cell content, very muted delimiter + real 1px rule, muted cool pipes, regular ink cells. No zebra, no virtual boxes.
- Slice 4 — aligner is one undoable whole-table edit preserving meaning; explicit command only, never on open.
- Slice 5 — navigation reuses aligner (`Tab` = align + next, `Shift+Tab` = prev, `Enter` = same-column next/create). Must intercept `Tab` before it inserts `\t`.
- Slice 6 — caret toggle mirrors Outline logic (`[ ]`↔`[x]`, accept `[X]` as checked).
- Cell-aware visual rows — each table source row remains one physical line. When the column minimums fit, cell contents wrap independently, column widths remain stable across rows, and row height follows the tallest cell. When the fit rule fails, the source row uses the existing horizontal overflow lane. Resizing changes only this disposable layout; it never reformats or dirties the document.
- Contracts: `ScrollY` pattern in `application.ViewState` + `ui` wiring is the prior art for `scrollX`; `document.NewMarkdownPresentation`/`SpansIn` + `visualLineCache` epoch pattern is prior art for revision-tagged projections.

## Testing Decisions

- Good tests assert external behavior at the highest seam: view-state + rendered x-offset/caret visibility for slice 1 (headless `ui` tests, no pixels); projection byte ranges + alignments for slice 2 (pure `language/markdown` tests with escaped-pipe/code-span/CJK/uneven fixtures); style mapping, one-edit formatting/undo, navigation, and caret toggling for later slices.
- Prior art: `ui/editor_view_test.go` (visual lines, wrap widths, cache epochs), `ui/prose_render_geometry_test.go`, `language/markdown/presentation_test.go` + `project_test.go`, `application/gatec_test.go` for view/conflict flows.
- Benchmarks: wide-table overflow pan + 100-row table projection/align latency; never block keystroke-to-frame (align off the frame path like current 150ms debounce).

Acceptance for cell-aware visual rows: a two-column Page/Summary table wraps the summary without a horizontal bar when it fits; a many-column table or an unbroken token wider than the lane keeps horizontal overflow; resize changes visual row height but not source bytes; pointer hit testing on continuation rows maps to the correct cell source range; Tab remains cell navigation and does not change the revision.

## Out of Scope

- Virtual grid renderer, cell-positioned hit-testing beyond `scrollX` translation, zebra striping, box-drawing cell borders.
- Row/column insert/delete/move, sorting, transpose, formulas/spreadsheet, numeric-inference alignment.
- Rendered-preview/HTML export, wiki links, footnotes, Setext/project-wide indexes.
- Generic horizontal scrolling of wrapped prose; touchpad gesture tuning.
- Zettlr-style active-cell-HTML/inactive-source split.

## Further Notes

- Precedents verified: Org `TAB`/`RET`/`C-c C-c` realign + motion and `<N>`/`<r,c,l>` cookies ([Org 3.1](https://orgmode.org/manual/Built_002din-Table-Editor.html), [Org 3.2](https://orgmode.org/manual/Column-Width-and-Alignment.html)); `markdown-mode` pipe-table port with `TAB`/`RET`, `C-c C-d`, row/col ops ([docs](https://jblevins.org/projects/markdown-mode), [#266](https://github.com/jrblevin/markdown-mode/issues/266)); `md-mode` source-preserving edit view + scrollable wide rows + cursor-follow ([md-mode](https://github.com/yibie/md-mode)); Zettlr HTML-split rejection ([Zettlr](https://docs.zettlr.com/en/editor/tables.html)); `valign` pixel-align alternative rejected ([valign](https://github.com/casouri/valign)).
- `md-mode` perf note worth stealing: debounce relayout on resize, cache measurements; same applies to our align + overflow layout.
- Table at `BRIEF.md:31-37` is valid GFM and already parses to one `BlockTable` — its failure mode is presentation/viewport (stale projections + clip), which slices 1–3 address in order.
