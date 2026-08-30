# Shirei contribution boundary

No upstream issue or pull request was opened during this audit. The source
review found a scale boundary and several possible generic capabilities, but no
obvious reproducible bug. The table records what to do if later evidence turns
one into a real framework need.

| Need | Observed evidence | Scratchpad-specific? | Framework-general? | Upstream candidate? | Proposed action |
|---|---|---:|---:|---:|---|
| Scalable editable text storage | `editcore` uses a whole `[]rune`; `TextArea` reconstructs it per command; `LargeText` is read-only | No | Likely | Yes, conditionally | Benchmark first; build the smallest Scratchpad proof; extract only a generic mechanism with a reproduction and tests. |
| Visible-row-only editable shaping | `TextArea` shapes a whole bound string; `LargeText` virtualizes read-only rows | No | Likely | Yes, conditionally | Prove a downstream custom widget; propose a small framework primitive only if a second use or clear generic seam exists. |
| Byte/rune span bridge | Shirei spans are rune-indexed; Tree-sitter captures are byte-indexed | No | Possibly | Not yet | Keep conversion in the language adapter; benchmark visible-line conversion before requesting API changes. |
| IME geometry or bidi bug | Existing source and tests cover composition, bidi boundaries, caret affinity, and platform decoding | No | Yes if reproduced | Only with reproduction | Run native Scratchpad smoke tests; file a focused test/issue only for an actual failure. |
| Virtual-list anchor bug | `VirtualListView` has anchor/estimated-height logic and dedicated docs/tests | No | Yes if reproduced | Only with reproduction | Stress with editor-like mutations; do not alter framework based on anticipated folds. |
| File tree, tabs, workspace search | Shirei has directory/content caches and a picker, not product workspace semantics | Yes | No | No | Implement in Scratchpad `workspace`/`ui`. |
| Atomic saves and reload conflicts | No observed Shirei persistence/conflict policy | Yes | No | No | Implement and test in Scratchpad. |
| Markdown headings/todos/tables/links | Product context projections, not generic widgets | Yes | No | No | Keep in Scratchpad language/projection providers. |
| Tree-sitter integration | Shirei is infrastructure; parser/runtime choice is a product build decision | Yes | No | No | Keep parser adapters downstream; do not add Tree-sitter to Shirei. |
| LSP, plugins, sync, collaboration | Explicitly deferred product scope | Yes | No | No | Do not build or upstream. |
| Headless custom-editor behavior coverage | Shirei has snapshot/headless support, but Scratchpad’s editor behavior is not yet built | Not yet | Potentially | Later | First build focused Scratchpad tests; propose generic harness improvements only when a concrete gap is encountered. |
| Accessibility and multi-window support | Current Shirei README lists accessibility unavailable and one standard-decorated window | Product may care later | Framework capability | Not now | Track as framework roadmap context; do not widen scaffold scope. |
| Native application menu | Scratchpad needs a real macOS `NSMenu`; the isolated adapter validates a semantic model, enforces the main thread, queues opaque IDs, and has unsupported-platform stubs | No | Yes | Yes | Published as a focused fork commit and [upstream PR](https://github.com/hasenj/go-shirei/pull/25); keep the Scratchpad command model independent of the adapter. |

## Contribution rule

The order is always:

1. smallest Scratchpad reproduction;
2. classify whether the need is generic;
3. add a focused test;
4. fix Shirei or propose an API only when the generic case is demonstrated;
5. remove the downstream workaround when the upstream change lands.

Scratchpad remains a downstream real application. Shirei should not gain
Markdown widgets, Tree-sitter, workspace policy, backlinks, or Scratchpad
keybinding semantics.
