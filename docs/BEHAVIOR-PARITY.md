# Editor behavioral parity artifact

This is the formal parity contract for the conditional `ScratchEditor` spike.
It exists before adding more editing behavior so storage and viewport work do
not silently diverge from Shirei’s established semantics.

## Comparison fixture

Use small deterministic strings, including:

- ASCII multiline text;
- combining marks;
- emoji/ZWJ sequences;
- mixed left-to-right and right-to-left text;
- a trailing empty line.

For each fixture, establish equivalent caret and selection positions, then run
the same operation through the Shirei TextArea frame harness and the
ScratchEditor harness. The current pure-core tests are the first executable
parity cases; the public Shirei frame harness remains the oracle for behavior
that depends on shaping, focus, or native input.

## Required observations

Compare, after every operation:

| Observation | Required now | Notes |
|---|---:|---|
| Resulting text | Yes | Exact string equality. |
| Caret | Yes | Rune/byte conversion must be explicit; compare the corresponding logical position. |
| Selection | Yes | Direction and normalized range must both be understood. |
| Undo result | Yes for core edits | Undo stores the changed byte ranges and caret/selection state, not whole-text snapshots. |
| Redo result | Yes for core edits | Redo reapplies the same range record and restores the post-edit caret/selection. |

The Shirei reference should be exercised through its public frame path and
`ProcessTextInput`/`TextInputState` observation where possible. Do not import
Shirei private `_EditState` into product code. Existing Shirei `editcore_test.go`
and `textinput_test.go` remain the lower-level reference for cases that cannot
yet be observed through the public API.

## Current status

The current core has unit tests for insertion, deletion, selection replacement,
line counts, large-offset edits, logical hit testing, clipboard operations,
undo/redo, combining-mark and ZWJ cluster motion/deletion, affinity state, and
composition commit/cancel. Its IME layer is still a pure preedit state
adapter; native Shirei composition delivery and caret geometry are not claimed
by this storage package. Its bidi behavior is likewise limited to preserving
logical affinity and direction metadata; visual run hit-testing remains a
Shirei-backed view concern.

This is intentionally a staged parity result. The next view-level parity work
must compare shaped visual positions and native composition geometry against
TextArea before the custom editor is promoted beyond a Gate B proof.

Parity is a Gate B artifact. It does not authorize beginning Markdown,
Tree-sitter, tabs, workspace search, or other Gate C+ work.
