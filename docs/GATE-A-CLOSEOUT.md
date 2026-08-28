# Gate A closeout

Date: 2026-08-28. Source baseline: Shirei commit
[`6df9f18`](https://github.com/hasenj/go-shirei/tree/6df9f18).

## Result

The source audit is closed with no new Shirei failure identified. The existing
Shirei edit-model, text-input, text-layout, snapshot, and platform-decoding
tests are the behavioral baseline. No upstream issue was opened.

The native window entry path was launched on the main development machine. A
native automated TextArea behavior run could open the window but did not reach
its completion verdict in this managed desktop session; macOS emitted
LaunchServices/host-service connection warnings and the run was stopped. This
is an environment limitation, not classified as a TextArea failure. Native
manual IME/clipboard interaction remains a follow-up smoke run when a normal
interactive desktop session is available.

The source-level and headless frame evidence for the requested behavior is:

| Behavior | Gate A result | Evidence |
|---|---|---|
| Multiline editing | Pass baseline | `widgets/textinput_test.go`, `editcore_test.go` |
| Selection and mouse hit testing | Pass baseline | Text input harness and selection tests |
| Undo/redo | Pass baseline | Edit history and TextArea tests |
| Combining marks | Pass baseline | Cluster-boundary and motion tests |
| Emoji/ZWJ | Pass baseline | Cluster-boundary tests |
| Bidi | Pass baseline | Bidi boundary/caret tests and snapshots |
| IME composition | Pass baseline | Composition state, selected-clause, and bidi IME tests |
| Clipboard | Pass baseline | Copy/cut/paste behavior tests |
| Soft wrap | Pass baseline | Wrap, affinity, and caret-scroll tests |
| Programmatic cursor/selection | Pass baseline | `EditorSetCursor` / `EditorSetSelection` path and tests |
| Native platform interaction | Deferred smoke | Requires a functioning interactive desktop session per platform |

“Pass baseline” means the current Shirei test and frame harness establishes the
behavior. It does not claim that a future editor-scale widget has parity yet.

## Decision

Gate A does not justify rewriting editing behavior. Gate B should measure the
current `TextArea` path and preserve its behavior as the oracle for any future
custom editor.
