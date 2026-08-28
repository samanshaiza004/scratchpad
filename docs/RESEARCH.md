# Shirei research

Status: source audit complete for the Shirei snapshot at commit
`6df9f18e3c2016d780f27f4ed67ff62cb189bf60` (2026-08-24). The audit used the
current source, tests, examples, and documentation in
[hasenj/go-shirei](https://github.com/hasenj/go-shirei/tree/6df9f18e3c2016d780f27f4ed67ff62cb189bf60).

This document separates observed behavior from conclusions. A conclusion is a
design implication, not a claim that Shirei itself makes that decision.

## Executive finding

Shirei has a substantial native editing stack. Its model, input shell, text
layout, shaping, IME, clipboard, focus, selection, caret, wrapping, and undo
behavior are already connected and heavily tested. It should be treated as the
behavioral reference implementation.

The scale boundary is real in the current source: the editable path represents
the bound value as a whole `[]rune`, the layout path shapes the whole string,
and undo snapshots retain whole strings. `LargeText` solves a different problem:
large read-only text with a source-string line index and visible-row
virtualization. It is a strong precedent, not an editable buffer.

The smallest responsible Scratchpad architecture is therefore:

1. keep the product document state in ordinary Go;
2. use Shirei `TextArea` while measurements show it is adequate;
3. if Gate B fails, introduce only an editor-scale buffer/line viewport and
   adapt Shirei's proven input behavior around it;
4. keep language parsing behind a replaceable provider seam;
5. keep filesystem authority, save policy, and derived projections in
   Scratchpad.

## Text editing architecture

The central pieces are:

- [`widgets/editcore.go`](https://github.com/hasenj/go-shirei/blob/6df9f18/widgets/editcore.go)
  defines a pure `_EditState` containing `[]rune`, cursor/anchor rune indexes,
  optional grapheme cluster boundaries, and optional line starts. `_EditCommand`
  values describe editing operations. `Apply` is a state transition with no
  rendering, focus, platform, or frame-global work.
- The same file implements cluster-aware cursor motion and deletion when bounds
  are supplied, word and line motion, selection, insertion, deletion, and
  clipboard command results. This is exactly the kind of generic behavior
  Scratchpad should not rewrite casually.
- Undo in `editcore.go` stores `_EditSnapshot{Text string, Cursor, Anchor}`.
  It coalesces simple single-rune typing/deletion but still reconstructs the
  full rune slice when applying a state. Paste and IME commits are separate
  undo units.
- [`widgets/textinput.go`](https://github.com/hasenj/go-shirei/blob/6df9f18/widgets/textinput.go)
  is the platform-facing shell. `ProcessTextInput` handles focus, key and mouse
  input, IME composition, clipboard requests, layout, and application of edit
  commands. `DrawTextInputPlain` and `DrawTextInputContent` render scrolling,
  selection, composition, and the caret. The file comments explicitly describe
  the separation between input analysis, the pure edit model, and rendering.
- `TextArea` is a multiline `TextInputExt` with default multiline attributes.
  Cursor and selection APIs such as `EditorSetCursor` and `EditorSetSelection`
  operate on rune indexes and require the input to be focused.
- [`widgets/textlayout.go`](https://github.com/hasenj/go-shirei/blob/6df9f18/widgets/textlayout.go)
  freezes a document-rune/display-rune/pixel mapping for a frame. Mouse hit
  testing, caret placement, selection geometry, and vertical motion all use
  that mapping.

### What this means for Scratchpad

Observed behavior supports the claim that Shirei already solves most editing
correctness. It does not support the claim that the current `TextArea` is an
editor-scale storage and rendering solution. The latter must be measured, with
the whole-string conversion and shaping path explicitly included in the
benchmark.

## Large text and virtualization

[`widgets/scroll.go`](https://github.com/hasenj/go-shirei/blob/6df9f18/widgets/scroll.go)
contains `LargeText` and `VirtualListView`.

Observed `LargeText` behavior:

- It retains one source `string`, not a `[]string` of all lines.
- It indexes line starts as byte offsets.
- It scans roughly the first 500 lines synchronously and completes the index in
  a background goroutine.
- Background work is generation-checked, updates shared state under
  `WithFrameLock`, and requests another frame.
- A visible row slices one line from the source string; it does not allocate a
  permanent line object for every row.
- `VirtualListView` builds visible rows plus slack, estimates total height from
  measured rows, keeps an anchor while scrolling, and supports semantic
  scroll-to-index operations.

This is a useful design vocabulary for Scratchpad's eventual line viewport.
However, `LargeText` is read-only. It has no edit commands, selections, undo
history, mutation-aware line index, or conflict/save semantics.

[`docs/virtual-list.md`](https://github.com/hasenj/go-shirei/blob/6df9f18/docs/virtual-list.md)
confirms that the virtual list is intended to avoid work proportional to a
large list and explains its visible-row and estimated-height behavior.

## Text shaping and styled spans

[`text.go`](https://github.com/hasenj/go-shirei/blob/6df9f18/text.go) provides:

- `TextSpan` and `StyleSpan` with half-open rune ranges;
- text color, background, font weight/style/aspect, underline, and strike;
- overlapping spans, flattened into renderable style runs;
- HarfBuzz-backed glyph clusters and bidirectional paragraph handling;
- `ShapeText` and `ShapeTextMax` with hard and soft line breaking;
- cached shaping keyed by content, width, and shaping-relevant style inputs.

The relevant limitation is also explicit in the file: the ordinary `Text`
widget truncates labels to 16 KiB, with segmented text called out as future
work. `ShapedText` retains the full rune slice, line list, and shaped segments
for its input. `ShapeTextMax` is therefore appropriate for a visible slice or
ordinary UI text, not evidence of a file-sized editable document pipeline.

The span API is a plausible Scratchpad presentation layer after a visible
range has been selected. Tree-sitter captures are byte-indexed while Shirei
spans are rune-indexed; the first adapter should convert only visible-line
ranges and should be benchmarked before any Shirei API change is proposed.

## IME, clipboard, and native input

[`host.go`](https://github.com/hasenj/go-shirei/blob/6df9f18/host.go) exposes
frame input, text input, composition text and selection, clipboard requests,
and IME anchor geometry. `textinput.go` reports the caret and composition
position to the host and uses the platform clipboard request path.

The current tests cover composition state and selected-clause underlining,
bidi boundaries during IME, clipboard operations, caret reveal, and platform
input decoding. Backend tests cover Windows UTF-16/surrogate handling and
composition positioning as well as X11 IBus extraction. This is strong
evidence to reuse the input behavior rather than recreate it in Scratchpad.

Native behavioral smoke tests are still required for the actual Scratchpad
custom editor if one is built: a custom viewport changes caret geometry,
visible-line hit testing, and the timing of composition updates.

## Focus and identity

[`docs/identity.md`](https://github.com/hasenj/go-shirei/blob/6df9f18/docs/identity.md)
distinguishes positional identity from explicit stable keys. The latter is
required when items are reordered, filtered, or virtualized. `Use` retains
state in a container across frames; `UseData` retains state on an application
object until deleted.

Scratchpad should key a tab/editor container by a stable document identity, not
by tab position. Application-owned document state should not be placed in
Shirei's transient widget state. The current single focused text input model is
compatible with a single active editor, but tab switching must preserve stable
identity and explicitly reconcile focus.

## File APIs and widgets

[`im_os.go`](https://github.com/hasenj/go-shirei/blob/6df9f18/im_os.go) provides
directory listing and file-content caches with fsnotify invalidation. Large
file reads are asynchronous past a 64 MiB threshold; cache invalidation and
pruning are handled by the framework.

[`widgets/filebrowser.go`](https://github.com/hasenj/go-shirei/blob/6df9f18/widgets/filebrowser.go)
provides a path field and a one-level file browser/picker. It is useful native
UI infrastructure, but it is not a Scratchpad workspace tree, open-document
manager, tab model, search index, or save/conflict policy.

No observed Shirei API supplies Scratchpad's product file policy: atomic
replacement, dirty buffers, line-ending/BOM decisions, external change
conflicts, rename identity, crash recovery, session restore, ignored files, or
workspace search.

## Custom widget boundary

[`docs/custom-widgets-tutorial.md`](https://github.com/hasenj/go-shirei/blob/6df9f18/docs/custom-widgets-tutorial.md)
documents a useful process/paint split. `ProcessTextInput` owns focus, hooks,
editing, clipboard, and IME with no children; `DrawTextInputPlain` owns the
scrollable text, selection, composition, and caret rendering. A future
Scratchpad editor can use this seam, but should first determine whether it can
retain Shirei's existing input model without copying its whole-buffer storage.

## Tests and examples

The source has broad pure tests in `widgets/editcore_test.go`,
`widgets/textinput_test.go`, `widgets/editdecode_test.go`, and
`widgets/textlayout_test.go`. Snapshot tests cover wrapped selection and IME
states. Behavior tests exercise typing, cut, undo, scrolling, and composition
bidi under a real frame loop.

`examples/markdown_viewer` demonstrates lowering parsed Markdown into stable
display items rendered through a virtual list. `examples/haystack` demonstrates
background search and virtualized results. Neither is an editable document
architecture; they are useful examples of derived display state and stable
row identity.

## Packaging and current framework limits

The Shirei README describes native Windows, macOS, Linux Wayland/X11, iOS, and
Android support, with a mostly no-CGO cross-compilation story except for
macOS/iOS portions. `cmd/shirei_bundle` documents desktop packaging into
macOS, Linux, and Windows artifacts. The same README currently lists one window,
no accessibility support, and no GPU surfaces as limitations.

These are observed framework facts, not reasons to widen Scratchpad's scope.
They do mean native smoke testing and a clear single-window product scope are
part of the plan.

## Audit conclusions

Works as-is: editing correctness primitives, native text input/IME/clipboard,
Unicode and bidi behavior, selection/caret behavior, ordinary shaping, custom
widget process/paint separation, virtualized read-only rows, and snapshot
testing.

Works but is a scale question: `TextArea` for small and ordinary documents,
whole-buffer wrapping and shaping, full-string undo snapshots, and framework
file caches.

Scratchpad must own: mutable editor-scale storage if needed, workspace and tab
semantics, save/recovery/conflict policy, language provider adapters, derived
projections, command semantics, and disposable session/cache state.

No obvious reproducible Shirei bug was found during this source audit. Any
upstream request should begin with a minimal reproduction and a test rather
than with a Scratchpad-specific abstraction.
