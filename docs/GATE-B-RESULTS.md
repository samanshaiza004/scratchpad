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

## Balanced piece-tree rerun

The next storage iteration keeps the same public `Buffer` API but replaces the
linear piece slice with an implicit balanced treap. Each node caches subtree
byte length, newline count, and piece count. Splitting at an edit offset and
merging the resulting subtrees provide expected logarithmic edit/index work.
The previous slice behavior is retained as a test-only oracle, and the
identical deterministic edit stream is compared against it for 5,000 steps.

The same 10,000-edit suite now measures:

| Operation | Wall ms | Allocs | Allocated bytes | Pieces | Document bytes |
|---|---:|---:|---:|---:|---:|
| random-10000 | 10.792 | 36,676 | 2,946,072 | 13,327 | 10,482,428 |
| line-lookup | 19.404 | 13,343 | 589,952 | 13,327 | 10,482,428 |
| edit-start | 2.584 | 10,005 | 850,432 | 13,327 | 10,482,428 |
| edit-middle | 9.142 | 10,004 | 850,592 | 13,328 | 10,482,428 |
| edit-end | 2.789 | 10,003 | 841,120 | 13,329 | 10,482,428 |
| scroll-visible-rows | 23.423 | 240,017 | 13,552,648 | 13,329 | 10,482,428 |

The same 100,000-edit suite completed every phase:

| Operation | Wall ms | Allocs | Allocated bytes | Heap before → after | Pieces | Document bytes |
|---|---:|---:|---:|---:|---:|---:|
| random-100000 | 115.851 | 364,725 | 29,344,480 | 10.7 → 25.3 MB | 132,311 | 10,452,428 |
| line-lookup | 102.543 | 133,844 | 5,900,352 | 21.3 → 27.2 MB | 132,311 | 10,452,428 |
| edit-start | 21.364 | 100,005 | 8,532,480 | 21.3 → 29.8 MB | 132,311 | 10,452,428 |
| edit-middle | 35.779 | 100,005 | 8,499,888 | 21.4 → 29.9 MB | 132,312 | 10,452,428 |
| edit-end | 37.055 | 100,003 | 8,352,416 | 21.5 → 29.9 MB | 132,313 | 10,452,428 |
| scroll-visible-rows | 159.116 | 2,400,013 | 199,466,912 | 21.6 → 25.6 MB | 132,313 | 10,452,428 |

The tree changes the 100k line lookup from 9.467 seconds to 103 ms and the
localized edit probes from 16–21 seconds to 21–37 ms. The sequential line
cursor brings visible-row traversal below 160 ms. Allocation pressure remains
visible: the 100k scroll phase still performs roughly 2.4 million allocations
and allocates about 199 MB because `Line` copies requested row text. That is
now the next measured bottleneck, separate from piece-index lookup.

The pre-tree experiment changed the storage risk from unknown to explicit: the
simple piece sequence was a valid scale proof and benchmark fixture, but not a
long-session production representation. It remains regression evidence for
the balanced implementation above.

## Shirei-backed visual and native parity

The custom path is now wired through [`ui/editor_view.go`](../ui/editor_view.go)
as a real fixed-height Shirei view. `VirtualListViewExt` builds only visible
logical rows. Each row copies and shapes only its own byte range, then retains
the local byte/rune mapping needed by painting and pointer hit-testing. No
whole-document rune conversion is performed above the buffer.

The view currently provides:

- shaped visible-row rendering through `ShapedTextLayout`;
- local byte↔rune conversion, including UTF-8 text outside ASCII;
- bidi-aware glyph hit-testing using the same cluster/segment direction rules
  as Shirei `ComputeCursorIndex`;
- affinity-aware caret placement at the selected visual side;
- directional selection painting;
- native Shirei keyboard ownership, clipboard request path, preedit delivery,
  and screen-space caret/composition anchors;
- fixed logical rows without soft wrapping.

The executable fixtures and UI tests are the parity artifact. The hit-test
fixture compares the custom result against Shirei's public
`ComputeCursorIndex` over a mixed Hebrew/LTR line. The core fixtures continue
to compare text, caret, selection, undo, redo, cluster motion, and composition
behavior against the behavior established by Shirei's pure edit model. Native
IME hardware delivery remains a platform smoke concern; the custom view uses
the same public Host fields and frame input path as TextArea.

The real Shirei frame-path rerun was:

| Fixture | Operation | Wall ms | Allocs | Allocated bytes |
|---|---|---:|---:|---:|
| 1 MiB | first-paint | 0.804 | 3,439 | 770,648 |
| 1 MiB | insert-middle | 1.081 | 3,336 | 761,752 |
| 1 MiB | paste-100KiB | 1.155 | 3,510 | 1,093,800 |
| 1 MiB | selection-visible | 1.754 | 8,044 | 1,679,360 |
| 1 MiB | scroll top→bottom | 0.664 | 3,500 | 778,840 |
| 1 MiB | resize | 0.695 | 3,380 | 812,632 |
| 10 MiB | first-paint | 1.387 | 3,724 | 837,680 |
| 10 MiB | insert-middle | 1.814 | 3,645 | 799,752 |
| 10 MiB | paste-100KiB | 2.199 | 3,591 | 1,111,328 |
| 10 MiB | selection-visible | 1.332 | 7,595 | 1,627,456 |
| 10 MiB | scroll top→bottom | 0.845 | 3,666 | 777,216 |
| 10 MiB | resize | 2.921 | 3,379 | 781,000 |
| Unicode 10 MiB | first-paint | 0.765 | 4,068 | 944,448 |
| Unicode 10 MiB | insert-near-9MiB | 1.012 | 4,024 | 937,296 |

These results preserve the scale result through the real view: the normal
10 MiB middle edit remains in the low milliseconds, and the Unicode/bidi-heavy
fixture does not introduce document-proportional work. A 2 MiB single-line
fixture does not yet complete first paint within the bounded minute because
the visible logical row is itself a 2 MiB shaping request. That is a concrete
long-line rendering limitation for a later viewport/chunking pass, not a
piece-index failure; it is intentionally not being solved by changing the
buffer in this gate.

## Decision

**Gate B is closed.** TextArea is rejected for Scratchpad-scale editing, the
balanced piece tree survives the 10k/100k fragmentation suite, and the custom
editor now has a Shirei-backed fixed-line visual/input path with passing
row-local bidi hit-testing, caret/selection, clipboard, undo/redo, preedit,
and IME-anchor fixtures. Freeze the TextArea and both fragmentation baselines
as regression evidence. The 2 MiB single-line shaping limitation is recorded
as a bounded follow-up; it does not change the storage/editor contract.

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
implemented by copying Shirei’s entire editor into Scratchpad. Gate C may now
start with file-native product behavior; soft wrapping, long-line chunking,
and all language work remain deferred.
