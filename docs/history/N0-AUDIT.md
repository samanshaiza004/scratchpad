# Milestone N0 — Prose Surface Audit

Milestone M.1 remains the shell baseline. This audit records the seams used by
the document-surface work; it does not change the application shell or the
editor's byte authority.

## Current seams

- `editor.ScratchEditor.Buffer` remains the only authoritative text state.
- `editor.RowMap` still maps logical lines, including folded lines.
- `ui.VisualLine` owns the local source-byte to Shirei-rune mapping for a
  bounded logical-line window.
- Shirei `ShapeTextMax` accepts a width and returns stacked shaped lines with
  individual heights. `ShapedTextLayout` already renders those lines and
  accepts the existing selection/style spans.
- Shirei `VirtualListViewExt` accepts a variable `ItemHeight`; only visible
  item views are built, while height lookup may use estimates around its
  current anchor.
- Markdown structure and presentation remain revision-tagged disposable
  projections. Goldmark stays behind `language/markdown`.

## N0 decisions

1. Keep the virtual-list item identity at the logical-line level. Wrapping is
   represented by multiple Shirei shaped rows inside one item, so folds,
   gutter controls, and source navigation do not acquire a second document
   coordinate system.
2. Use `ShapeTextMax` for Markdown and plain text only. Go, TypeScript, and
   other code views remain unwrapped by default.
3. Cache shaped logical lines by editor revision, available content width, and
   wrap mode. The UI cache is bounded; it is not a document layout store.
4. A wrapped row's pointer and caret geometry is resolved locally from its
   `ShapedText.Lines`. No whole-document byte-to-rune conversion is introduced.
5. Long logical lines continue to use the existing bounded chunk fallback.
   Chunking and shaping-context correctness remain an explicit follow-up; N
   must not turn a multi-megabyte line into a synchronous whole-line request.

## Deferred from N0

Heading hierarchy, block decoration, tables, and richer Markdown presentation
are subsequent N slices. The M.1 shell, menus, tabs, file lifecycle, parser
backend, and storage architecture are frozen during this work.
