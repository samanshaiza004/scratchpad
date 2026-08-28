# Shirei TextArea audit

This audit answers the first architectural gate: how far the current Shirei
editing stack can take Scratchpad before the data/layout model becomes
unsuitable.

Source basis: Shirei commit
[`6df9f18`](https://github.com/hasenj/go-shirei/tree/6df9f18), especially
`widgets/editcore.go`, `widgets/textinput.go`, `widgets/textlayout.go`,
`text.go`, and the associated tests.

## Capability matrix

| Area | Status | Evidence | Scratchpad implication |
|---|---|---|---|
| Basic insertion/deletion | Works as-is | `_EditCommand`, `Apply`, and insertion/deletion operations in `widgets/editcore.go` | Reuse behavior. |
| Cursor and selection | Works as-is | Cursor/anchor state, selection commands, `EditorSetCursor`, `EditorSetSelection` | Preserve rune-index adapter at the UI edge. |
| Combining marks and emoji/ZWJ | Works as-is | Cluster-bound tests and cluster-aware motion/deletion | Do not replace with byte-wise motion. |
| Word and line motion | Works as-is | Word classes and line commands in `editcore.go` | Reuse and add product commands around it. |
| Unicode shaping | Works as-is for shaped fields | `ShapeTextMax`, glyph clusters, text layout | Use for ordinary/visible text; benchmark file-scale use. |
| Bidirectional text | Works as-is for current TextArea path | Paragraph bidi, caret affinity, bidi boundary tests | Keep as behavioral reference; native smoke test custom path. |
| IME composition | Works as-is for current TextArea path | Host composition fields, composition display splice, IME tests/snapshots | Reuse `ProcessTextInput` concepts; preserve caret/composition geometry. |
| Clipboard | Works as-is | Copy/cut/paste commands and host request path | Reuse platform integration. |
| Undo/redo | Works as-is behaviorally | History tests and redo invalidation/coalescing | Storage is not scale-safe; replace representation only if benchmarks require it. |
| Mouse hit testing | Works as-is for the shaped field | `ComputeCursorIndex` and layout index mapping | A scalable editor needs viewport-local hit testing. |
| Soft wrap | Works as-is for ordinary fields | `Wrap`, `ShapeTextMax`, wrap/affinity tests | Defer in the first scalable proof if necessary. |
| Caret rendering/reveal | Works as-is for current TextArea path | `DrawTextInputCaret`, scroll-follow tests | Reuse visual conventions. |
| Programmatic cursor/selection | Works as-is when focused | `EditorSetCursor` / `EditorSetSelection` | Stable focus/identity must be explicit across tabs. |
| Whole-buffer edit representation | Works but unsuitable at editor scale | `_EditState.Runes []rune`; every command batch builds it from `string` | Gate B must measure conversion and allocation cost. |
| Whole-buffer layout | Works but unsuitable at editor scale | `makeTextLayout` calls shaping on the bound string; `ShapedText` retains full runes/lines | Shape only visible lines in a custom scalable viewport if needed. |
| Undo storage | Works but unsuitable at editor scale | `_EditSnapshot.Text string`, full restore to `[]rune` | Use an edit log/snapshot strategy only after workload measurements. |
| Long single line | Unknown / high risk | Current layout is whole-string and soft-wrap aware; no editable pathological-line benchmark observed | Include a multi-megabyte single-line fixture. |
| Read-only large files | Works as a separate facility | `LargeText` + `VirtualListView` | Reuse line indexing/virtualization principles, not its storage as an editor. |
| Incremental mutable line index | Missing | `LargeText` indexes immutable source strings; `TextArea` has no equivalent editor-scale index | Scratchpad likely owns this if Gate B fails. |
| Visible-line-only editable shaping | Missing as a public path | Current `TextArea` builds one text layout; no public editor-scale line renderer | Potential generic upstream candidate after a minimal reproduction. |
| File authority/save/conflicts | Missing | Shirei file APIs are caches/pickers, not persistence policy | Scratchpad workspace layer owns it. |
| Syntax/language projections | Missing | No parser/provider contract in the audited path | Keep a Scratchpad language seam. |

## Exact scale concern

The critical path is visible in the source, not inferred from API names:

1. `ProcessTextInput` receives a bound `*string`.
2. For a command batch it constructs `_EditState{Runes: []rune(*buf), ...}`.
3. `Apply` mutates that complete rune slice.
4. On edit it writes `*buf = string(es.Runes)`.
5. It rebuilds the text layout.
6. `makeTextLayout` shapes the complete string and computes a complete
   document/display/pixel mapping.

Undo snapshots also convert the complete rune slice to a string. This is a
correct and clean small-widget design, but ordinary typing can perform work
proportional to document size. Shirei's content hash cache can help repeated
unchanged frames; it cannot make a changed whole document incremental.

## What not to duplicate

Scratchpad should not independently implement:

- grapheme/cluster motion and deletion;
- bidi caret affinity and selection behavior;
- IME composition display and clause styling;
- native clipboard requests;
- ordinary caret blink/reveal behavior;
- generic text span flattening;
- the basic command semantics already covered by `editcore`.

If a custom editor becomes necessary, its first implementation should be
compared against these behaviors and should either adapt Shirei's generic
mechanisms or copy only the smallest proven mechanism with tests.

## Required Gate B experiment

The experiment must compare current `TextArea` with the smallest candidate
editor path over:

- 100 KiB, 1 MiB, and 10 MiB ordinary files;
- a multi-megabyte single line;
- Unicode-heavy text with combining marks and emoji/ZWJ;
- 100 KiB paste;
- edits near the beginning, middle, and end;
- undo, backspace, scroll, and resize;
- first paint, keystroke-to-frame latency, peak memory, and allocations.

The first scalable proof may disable soft wrapping and use fixed-height logical
rows. This isolates storage, line indexing, visible-row virtualization, and
input latency. Width-dependent wrapping can be added after the line-oriented
path is stable.

## Audit result

Use `TextArea` first for small files and for behavior comparison. Do not commit
to it as the final storage model. Do not commit to a custom `ScratchEditor`
until the benchmark shows a user-visible failure or unacceptable memory bound.

No reproducible framework bug was established by this audit. The scale issue is
an observed architectural limitation, not a bug report by itself.
