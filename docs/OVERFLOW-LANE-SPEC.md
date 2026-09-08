# Overflow lane + Org-style tables spec

Note: repo has no configured issue tracker (`/setup-matt-pocock-skills` never run), so this spec is published as a docs file instead of a tracked issue. No `ready-for-agent` label applied.

## Problem Statement

Wide unwrapped rows (Markdown tables, long code lines) overflow the editor viewport and are clipped with no way to read them. Tables are additionally a single whole-block projection with no row/cell/pipe geometry, so columns cannot align, pipes cannot mute, and `Tab`/`Enter` cannot navigate fields. Checkbox toggle only exists in the Outline sidebar, not at the caret.

## Solution

Build a horizontal overflow lane first, then semantic table projections on top of it. Keep files ordinary Markdown at all times: align by padding real source spaces (Org/`markdown-mode` model), style with Aero-paper surfaces, never a virtual grid renderer.

Correction accepted: `md-mode` auto-align default is `t` per current docs (earlier audit said `nil` from an older README). Precedent taken from `md-mode` is edit-view source honesty + unwrapped wide rows + cursor-following, not the default value.

## User Stories

1. As a notes author, I want wide table rows to stay on one source line and scroll horizontally, so that I can read every cell.
2. As a notes author, I want the caret to stay visible when I arrow into overflow, so that I am never typing blind.
3. As a notes author, I want wrapped prose to stay fixed at x=0 while only unwrapped rows shift, so that prose never slides sideways.
4. As a notes author, I want the gutter/line numbers to stay fixed while overflow scrolls, so that I keep my place.
5. As a code author, I want long code lines to use the same overflow lane, so that the fix is not table-specific debt.
6. As a Markdown author, I want `Format Table` to pad columns with real spaces, so that the file stays valid Markdown and caret/copy/save stay trivial.
7. As a Markdown author, I want header/delimiter/pipes styled (cool well, stronger header + bold, muted delimiter + 1px rule, muted pipes), so that aligned source reads as a table without HTML rendering.
8. As a Markdown author, I want `Tab` to align + go to next cell, `Shift+Tab` to previous, `Enter` same-column next row/create row, so that tables edit like Org/`markdown-mode`.
9. As a tasks author, I want `item.toggle` at the caret to flip `[ ]`/`[x]`, so that I do not need the Outline sidebar.
10. As a reader of unaligned files, I want nothing rewritten on open, so that dirty state is never invented (explicit align only, like `md-mode` opt-in).

## Implementation Decisions

- Slice order (agreed): 1) overflow lane + caret-follow; 2) row/cell/pipe projection; 3) header/delimiter/pipe visuals; 4) `Format Table`; 5) `Tab`/`Shift+Tab`/`Enter` navigation; 6) caret task toggle. This spec covers all six; only slices 1–2 are dispatched now.
- Slice 1 — overflow lane (UI-only, no buffer/document-text change):
  - `scrollX` lives in document view state alongside `ScrollY` (per-document, session-disposable like `ScrollY`, not part of `Document` text authority).
  - Applies only to lines resolved as unwrapped (`NoWrapLine` true — tables — or code mode unwrapped). Wrapped prose always renders at x=0 and ignores `scrollX`.
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
  - Existing whole-block `BlockTable`/`PresentationTable` stays until slice 3 rewires styling; new projection is additive, revision-tagged + disposable like current projections.
- Slice 3 — visuals only: faint cool well (block), stronger header surface + bold cell content, very muted delimiter + real 1px rule, muted cool pipes, regular ink cells. No zebra, no virtual boxes.
- Slice 4 — aligner is one undoable whole-table edit preserving meaning; explicit command only, never on open.
- Slice 5 — navigation reuses aligner (`Tab` = align + next, `Shift+Tab` = prev, `Enter` = same-column next/create). Must intercept `Tab` before it inserts `\t`.
- Slice 6 — caret toggle mirrors Outline logic (`[ ]`↔`[x]`, accept `[X]` as checked).
- Contracts: `ScrollY` pattern in `application.ViewState` + `ui` wiring is the prior art for `scrollX`; `document.NewMarkdownPresentation`/`SpansIn` + `visualLineCache` epoch pattern is prior art for revision-tagged projections.

## Testing Decisions

- Good tests assert external behavior at the highest seam: view-state + rendered x-offset/caret visibility for slice 1 (headless `ui` tests, no pixels); projection byte ranges + alignments for slice 2 (pure `language/markdown` tests with escaped-pipe/code-span/CJK/uneven fixtures); style mapping + no-op-on-open for later slices.
- Prior art: `ui/editor_view_test.go` (visual lines, wrap widths, cache epochs), `ui/prose_render_geometry_test.go`, `language/markdown/presentation_test.go` + `project_test.go`, `application/gatec_test.go` for view/conflict flows.
- Benchmarks: wide-table overflow pan + 100-row table projection/align latency; never block keystroke-to-frame (align off the frame path like current 150ms debounce).

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
