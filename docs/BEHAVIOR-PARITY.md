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
ScratchEditor harness.

## Required observations

Compare, after every operation:

| Observation | Required now | Notes |
|---|---:|---|
| Resulting text | Yes | Exact string equality. |
| Caret | Yes | Rune/byte conversion must be explicit; compare the corresponding logical position. |
| Selection | Yes | Direction and normalized range must both be understood. |
| Undo result | When undo exists | ScratchEditor currently has no undo; this row is pending. |
| Redo result | When redo exists | ScratchEditor currently has no redo; this row is pending. |

The Shirei reference should be exercised through its public frame path and
`ProcessTextInput`/`TextInputState` observation where possible. Do not import
Shirei private `_EditState` into product code. Existing Shirei `editcore_test.go`
and `textinput_test.go` remain the lower-level reference for cases that cannot
yet be observed through the public API.

## Current status

The storage spike currently has unit tests for insertion, deletion, selection
replacement, line counts, and large-offset edits. It deliberately has no
behavioral claim beyond those operations. Caret rendering, hit testing,
clipboard, undo, cluster motion, bidi affinity, and IME must each add a parity
case before being called complete.

Parity is a Gate B artifact. It does not authorize beginning Markdown,
Tree-sitter, tabs, workspace search, or other Gate C+ work.
