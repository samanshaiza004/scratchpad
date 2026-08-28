# Gate B scale experiment

Date: 2026-08-28. Machine: development macOS host, Go 1.27 toolchain. Shirei
source: commit [`6df9f18`](https://github.com/hasenj/go-shirei/tree/6df9f18).

## Method

[`cmd/textbench`](../cmd/textbench/main.go) drives the real Shirei `TextArea`
through `RunFrameFn`: TextArea input processing, whole-buffer text shaping,
layout, surface generation, and deterministic synthetic input are included.
The default run does not add software rasterization because the current
TextArea surface can itself contain the whole shaped document; use
`-software-render` as a separate stress mode. Every measured frame records
wall time, allocations, allocated bytes, and heap before/after.

Fixtures are deterministic generated sources:

- 100 KiB normal source;
- 1 MiB normal source;
- 10 MiB normal source;
- 10 MiB Unicode-heavy source with combining marks, emoji/ZWJ, Arabic, and
  Devanagari;
- 2 MiB single line.

The full operation set is available with `-operations all`. Large fixtures can
be narrowed with a comma-separated filter, which is necessary when a whole
TextArea frame becomes minutes-long.

## TextArea measurements

Representative valid runs from the same process shape are below. Values are
wall milliseconds for one complete Shirei frame build; allocation values are
bytes allocated during that measured operation.

| Fixture | Operation | Wall ms | Allocs | Allocated bytes |
|---|---|---:|---:|---:|
| 100 KiB | first-paint | 65.459 | 236,434 | 64,355,472 |
| 100 KiB | insert-middle | 404.546 | 2,089,547 | 278,362,328 |
| 100 KiB | paste-100KiB | 842.396 | 2,641,201 | 557,622,328 |
| 100 KiB | undo | 195.876 | 257,577 | 72,530,232 |
| 100 KiB | redo | 95.688 | 236,454 | 70,221,464 |
| 100 KiB | selection-visible | 234.904 | 474,015 | 126,102,336 |
| 100 KiB | scroll top→bottom | 82.981 | 236,434 | 64,355,472 |
| 100 KiB | resize | 108.275 | 236,430 | 64,355,248 |
| 1 MiB | first-paint | 4,349.136 | 2,418,946 | 658,106,976 |
| 1 MiB | insert-middle | 41,032.533 | 21,202,308 | 2,828,297,600 |
| 10 MiB | first-paint | >75 s | — | did not complete; interrupted |

The one-character middle edit grew from 404.546 ms at 100 KiB to 41,032.533
ms at 1 MiB: approximately 101× the wall time for a 10× document increase.
Its allocated bytes grew from 278 MB to 2.83 GB. First paint grew roughly 66×.
The 10 MiB first-paint run did not complete within a bounded additional minute
and was interrupted to protect the machine. This is already sufficient evidence
that current TextArea work is not proportional to the visible viewport.

The 100 KiB run also verified that the operation harness is reaching the real
widget: insertion changed the document to 102,401 bytes, paste changed it to
204,800 bytes, backspace removed a byte, and undo/redo reversed and reapplied
the edit. A fresh stable Shirei identity is used for each independent case.

## Minimal ScratchEditor spike

Because TextArea fails the scale gate, [`cmd/scratcheditor`](../cmd/scratcheditor/main.go)
and [`editor/`](../editor/) contain the smallest conditional alternative:

- piece-backed byte storage with an append-only add store;
- insertion splits only the piece containing the edit point;
- newline counts are retained as piece metadata;
- one byte-oriented caret and selection in the pure editor shell;
- fixed-height logical rows through Shirei `VirtualListViewExt`;
- visible rows only, no soft wrapping, syntax, folding, or language services.

The pure editor core now carries the first parity layer: one caret and
selection, logical hit-testing, clipboard-shaped copy/cut/paste operations,
range-based undo/redo, local grapheme motion/deletion for combining marks and
ZWJ emoji, affinity state, and a preedit/commit/cancel model. This is still not
native TextArea parity: the Shirei-backed view must later supply shaped visual
bidi hit-testing, rendered caret geometry, and native IME composition geometry.

Representative spike results:

| Fixture | Operation | Wall ms | Allocated bytes |
|---|---|---:|---:|
| 1 MiB | first-paint | 0.522 | 713,480 |
| 1 MiB | insert-middle | 0.522 | 764,800 |
| 10 MiB | first-paint | 0.497 | 727,832 |
| 10 MiB | insert-near-9MiB | 0.831 | 725,296 |
| 10 MiB Unicode | insert-near-9MiB | 0.955 | 882,536 |
| 2 MiB single line | insert-near-9MiB | 7.220 | 14,090,688 |

The single-line case is slower because the one visible line itself must be
copied for the row; it is not a whole-document line-index scan. Normal and
Unicode multi-line edits remain sub-millisecond in this small proof.

## Fragmentation experiment

[`cmd/fragmentbench`](../cmd/fragmentbench/main.go) starts from a deterministic
10 MiB ordinary-source fixture and uses a fixed random seed. It performs random
single-byte insert/delete edits, then measures line lookup, repeated edits at
the beginning/middle/end, and visible-row scrolling. Each row records wall
time, allocations, allocated bytes, heap before/after, piece count, and final
document size.

The completed 10,000-edit run was:

| Operation | Wall ms | Allocs | Allocated bytes | Pieces | Document bytes |
|---|---:|---:|---:|---:|---:|
| random-10000 | 98.570 | 40 | 2,293,944 | 13,327 | 10,482,428 |
| line-lookup | 103.960 | 13,344 | 589,968 | 13,327 | 10,482,428 |
| edit-start | 142.658 | 5 | 50,432 | 13,327 | 10,482,428 |
| edit-middle | 184.991 | 2 | 50,432 | 13,328 | 10,482,428 |
| edit-end | 211.017 | 1 | 40,960 | 13,329 | 10,482,428 |
| scroll-visible-rows | 2,377.139 | 466,660 | 14,933,600 | 13,329 | 10,482,428 |

The 100,000-edit run completed all mutation, lookup, and localized-edit
phases before the visible-row phase was stopped. The benchmark now emits each
phase as it completes, so these are retained even when a later phase is
bounded:

| Operation | Wall ms | Allocs | Allocated bytes | Heap before → after | Pieces | Document bytes |
|---|---:|---:|---:|---:|---:|---:|
| random-100000 | 8,187.091 | 121 | 20,866,856 | 10.7 → 25.2 MB | 132,311 | 10,452,428 |
| line-lookup | 9,467.380 | 133,844 | 5,900,336 | 15.0 → 20.9 MB | 132,311 | 10,452,428 |
| edit-start | 16,306.370 | 6 | 532,496 | 15.0 → 15.5 MB | 132,311 | 10,452,428 |
| edit-middle | 18,673.891 | 2 | 499,712 | 15.1 → 15.6 MB | 132,312 | 10,452,428 |
| edit-end | 21,266.029 | 1 | 352,256 | 15.3 → 15.6 MB | 132,313 | 10,452,428 |

The 100,000-edit visible-row phase exceeded a further bounded minute and was
interrupted. The 10,000-edit result already shows the simple piece sequence
reaching roughly 13k pieces; at 100,000 edits it reaches 132k pieces, and line
lookup/localized edits grow into multi-second operations. This is evidence that
the next storage iteration needs cached metadata or a balanced piece index; it
does not justify changing the observable editor contract.

The experiment therefore changes the storage risk from unknown to explicit:
the simple piece sequence is a valid scale proof and benchmark fixture, but is
not yet a long-session production representation. Keep it as regression
evidence while the next editor-core iteration evaluates cached metadata or a
balanced tree.

## Decision

**The Gate B decision is complete: TextArea is rejected for Scratchpad-scale
editing, and the custom-editor path is required. Gate B remains open until the
parity and fragmentation artifacts are accepted.** Freeze the TextArea and
fragmentation measurements as regression evidence. Do not begin Gate C or
language work yet.

The parity order is:

```text
storage + viewport
→ caret/hit-testing
→ selection
→ clipboard
→ undo/redo
→ cluster-aware motion
→ bidi affinity
→ IME/preedit
→ soft wrap later
```

The TextArea path remains the behavioral oracle. The parity artifact is
specified in [`BEHAVIOR-PARITY.md`](BEHAVIOR-PARITY.md); it is intentionally not
implemented by copying Shirei’s entire editor into Scratchpad. Gate C is
blocked until the custom view can connect this core to shaped caret/hit-test
and native composition behavior without putting whole-document work back on
the keystroke-to-frame path.
