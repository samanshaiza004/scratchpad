# Tree-sitter and Go parsing options

This is an early architecture gate. No parser dependency is included in the
scaffold.

Source basis: current upstream snapshots of
[tree-sitter](https://github.com/tree-sitter/tree-sitter),
[tree-sitter/go-tree-sitter](https://github.com/tree-sitter/go-tree-sitter),
[go-tree-sitter-bare](https://github.com/alexaandru/go-tree-sitter-bare), and
[gotreesitter](https://github.com/odvcencio/gotreesitter), inspected on
2026-08-28. The latter is a young project, so its claims are recorded as
observations to verify, not guarantees.

## What the official project establishes

Tree-sitter is an incremental parser generator/runtime designed to parse on
every keystroke and recover from syntax errors. The official C runtime accepts
input through callbacks, so a parser adapter can read chunks from a piece table,
rope, or another document buffer instead of requiring one contiguous string.
Trees can be edited with byte offsets and row/column points, changed ranges can
be queried, included ranges support injections, and query/highlight systems are
first-class concepts.

This matches Scratchpad's language model, but the parser must remain downstream
of the document/editor seam. A parser is a consumer of document snapshots and
changed ranges, not the owner of the document.

## Alternatives

| Option | Maintenance and correctness | Performance/incrementality | Build and packaging | Grammar/injection fit | Current position |
|---|---|---|---|---|---|
| Official Go binding + CGO | Lowest ecosystem risk; official API and grammars are the reference | Native runtime and incremental trees; custom input callbacks can avoid flattening | Requires a C toolchain or prebuilt native strategy per target; complicates cross-compilation and reproducible packaging | Broad grammar availability; edit APIs, queries, included ranges, and injections fit well | Safest fallback; isolate behind one adapter. |
| Official binding with runtime-loaded grammars | Keeps grammars out of the main binary; `purego` can load shared libraries | Same native parser path | Adds per-OS shared-library packaging and ABI/version handling | Good if grammar artifacts are managed carefully | Useful desktop variant, not the initial scaffold. |
| `go-tree-sitter-bare` | Maintained binding surface, but still a CGO binding; grammars are separate | Native Tree-sitter behavior | “Bare” means fewer bundled choices, not no-CGO; distribution work remains | Depends on separate grammar forest and compatibility | Consider only if its maintenance/package workflow beats official binding. |
| Pure-Go `gotreesitter` | No-CGO and compatible parse-table goal; repository is active and MIT, but young and less established | Claims incremental parsing, queries, highlighting, dynamic/recursive injections; tail coordinate updates can still be linear and some reuse is incomplete | Strong cross-compilation story; grammar blobs/registry can affect binary size and packaging | Claims a registry of 206 grammars and injection support; grammar/query/scanner fidelity needs proof | Best no-CGO candidate for a focused Gate E spike, not a dependency before that spike. |
| Wasm-hosted Tree-sitter | Official web binding and grammar-Wasm packaging are established | Adds Wasm boundary/runtime and data conversion; web docs note slower Node path than native bindings | Cross-platform runtime is attractive, but grammar assets and Wasm host become application dependencies | Language Wasm modules and injection logic fit conceptually; Go desktop integration is custom | Viable experiment if pure-Go fails; not the first desktop path. |
| External helper process | Strong isolation and independent parser toolchain | IPC, serialization, process startup, failure recovery, and snapshot latency are application costs | Per-platform helper packaging and upgrades are substantial | Any parser can be used; injections cross an IPC boundary | Last resort, not justified by current evidence. |
| Another incremental parser/highlighter | Could fit one or two languages with a small implementation | Potentially simple for narrow needs | Low initial dependency cost but high long-term language maintenance | Grammar coverage and injections become Scratchpad's problem | Avoid until Tree-sitter options are disproven. |

## Recommendation

Do not choose a parser implementation during scaffold work. Define a narrow,
query-oriented language-provider seam in Scratchpad and keep `document/` and
`editor/` independent of Tree-sitter.

At Gate E, run the same proof with one small language set (Markdown plus Go or
Rust) against:

1. `gotreesitter`, if its grammar/query support is available for the selected
   languages;
2. the official Go binding in an isolated CGO adapter.

The provisional default is `gotreesitter` if it passes correctness, incremental
update, memory, visible-span, injection, and packaging tests. That path best
preserves Shirei's cross-compilation/no-CGO direction. Confidence is medium-low
because the implementation is young and its large grammar registry, external
scanner coverage, query fidelity, and binary footprint must be measured in the
Scratchpad workload.

If it fails, use the official binding with CGO isolated to the language adapter
and desktop build pipeline. That is a conscious product tradeoff, not a reason
to contaminate `document/` or Shirei. Wasm remains an option when a single
runtime and asset strategy is more valuable than native latency; an external
helper is the least attractive option because it adds process and IPC failure
modes.

## Unknowns that must be measured

- Which selected grammars and external scanners work in each candidate without
  handwritten patches.
- Incremental parse latency after edits near the beginning, middle, and end of
  a 10 MiB document.
- Memory and binary-size impact of the pure-Go grammar registry versus native
  shared libraries or per-language Wasm assets.
- Cross-compilation and signing/package behavior on macOS, Windows, and Linux.
- Query compatibility for symbols, folds, highlights, and injections.
- Mapping parser byte ranges to Shirei rune-indexed spans for Unicode-heavy
  visible lines.
- Cancellation/staleness behavior when parsing runs behind rapid typing.
- Whether the official callback input path and a future mutable buffer avoid
  whole-document flattening.

## Proposed seam, deliberately not frozen

The final API should be shaped by the first two adapters. Conceptually, a
provider receives a consistent document snapshot plus a visible byte range and
can return syntax spans and structural projections such as symbols and folds.
It should also expose invalidation/change information without making the
document depend on a parser tree.

Do not freeze the exact `LanguageProvider` method set from this document. One
adapter is a hypothesis; two working adapters are evidence for an interface.
