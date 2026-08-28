# ScratchEditor core contract

This is the Gate B freeze point for the first scalable editor proof. It fixes
the observable behavior and keeps the storage representation replaceable.

## Ownership and units

- `editor.Buffer` owns document bytes, line accounting, and edit operations.
  The current implementation is a balanced piece tree with cached subtree
  byte/newline summaries; the representation remains replaceable.
- `editor.ScratchEditor` owns one caret, one directional selection, affinity,
  composition state, and range-based undo/redo.
- Caret and selection positions are UTF-8 byte offsets at rune boundaries.
  Public setters clamp to the nearest preceding boundary.
- The Shirei adapter owns shaping, visible-row layout, visual bidi mapping,
  native clipboard transport, native IME delivery, focus, and painting.
- Composition text is transient and is inserted into the buffer only on
  commit. Cancel never changes document bytes.

## Required behavior

- Insertion replaces the normalized selection and places the caret after the
  inserted bytes.
- Backspace and forward delete remove one grapheme-like cluster, or the whole
  selection when one exists. The current proof covers combining marks,
  variation selectors, emoji modifiers, and ZWJ sequences.
- Copy returns the normalized selected byte range. Cut returns it and records a
  range edit. Paste is ordinary insertion.
- Undo/redo records changed ranges and caret/selection positions. It must not
  snapshot the complete document.
- `LineRange` and visible-row consumers may copy/shape only the requested line.
  Soft wrapping is intentionally outside this contract.
- `NewLineCursor` seeks the first visible line through the indexed tree and
  then walks neighboring leaves without restarting a root lookup for every
  row. Its current `Line` method still returns a copy; zero-copy shaping is a
  later measured optimization.

## Deliberate non-contracts

- The current tree shape is not frozen. Another balanced piece index, cached
  line metadata layout, or buffer can replace it without changing these APIs.
- The former linear piece sequence remains as a test-only slice oracle for
  differential edit streams.
- The proof does not yet promise visual bidi hit-testing, pixel caret geometry,
  or native IME composition rectangles. Those belong to the Shirei-backed view
  parity step.
- Key decoding, multi-cursor editing, folding, syntax highlighting, and
  language services remain outside the Gate B core.

The fragmentation benchmark is a required regression fixture for any storage
replacement. The balanced piece tree completes the bounded 100k-edit session;
the remaining measured cost is primarily row materialization during repeated
scroll walks, not document-size-proportional edit work.
