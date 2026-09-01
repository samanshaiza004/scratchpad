# Gate E parser bake-off

## E0 decision record

The first bake-off uses the same deterministic generated Go source and the
same one-insertion edit for both runtimes. The official C runtime is compiled
through `go-tree-sitter`; the alternate runtime is `gotreesitter`. The
benchmark reports parser structure, upstream highlight captures, and tags
captures separately. Folds are Scratchpad-owned and are not treated as an
upstream grammar asset.

Environment for the recorded run:

- Scratchpad commit: `872824c` (`Add Tree-sitter runtime and grammar bake-off`).
- Go: `go1.27.0`, `darwin/arm64`.
- Shirei: `go.hasen.dev/shirei v0.6.7`.
- Goldmark: `github.com/yuin/goldmark/v2 v2.0.0`.
- Official runtime: `github.com/tree-sitter/go-tree-sitter v0.25.0`.
- Go grammar: `github.com/tree-sitter/tree-sitter-go v0.25.0`.
- Pure runtime: `github.com/odvcencio/gotreesitter v0.51.0`.

Exact commands:

```text
go run -tags treesitter_cgo ./cmd/treebench -backend=official -sizes=1024,102400,1048576
go run -tags treesitter_pure ./cmd/treebench -backend=pure -sizes=1024,102400,1048576
```

Raw compact JSONL is retained in [`baselines/gate-e-go-official.jsonl`](baselines/gate-e-go-official.jsonl)
and [`baselines/gate-e-go-pure.jsonl`](baselines/gate-e-go-pure.jsonl).

| Runtime | 1 KiB full / incremental | 100 KiB full / incremental | 1 MiB full / incremental | Highlight count parity | Tag capture parity |
| --- | ---: | ---: | ---: | --- | --- |
| Official C runtime | 0.409 / 0.042 ms | 14.747 / 0.995 ms | 79.773 / 6.777 ms | baseline | baseline |
| gotreesitter | 3.484 / 0.537 ms | 24.197 / 5.290 ms | 239.725 / 168.354 ms | counts match | does not match |

Both runtimes produced the same root type, edited root extent, and no-error
status for the generated corpus. Highlight counts also match. The pure-Go
runtime does not yet produce the same tag capture stream: its query parser
requires removal of the optional upstream `#set-adjacent!` directives, and its
tag capture count/digest differs. This is recorded as a correctness-parity
limitation, not hidden by normalizing the output.

The provisional product backend is therefore the official C runtime behind a
CGO build tag. It passes the current structure/highlight checks, consumes the
upstream Go query assets unchanged, and is materially faster and lower-memory
in this bake-off. The pure-Go runtime remains an isolated comparison/fallback;
it is not linked into the product build. This is a provisional E0 decision,
subject to TypeScript and three-platform packaging evidence.

Hard-gate status:

- Structure and incremental parse behavior: pass for both runtimes on the
  deterministic corpus.
- Query correctness parity: official baseline passes; pure-Go is not yet
  parity-complete for Go tags.
- Build feasibility: both benchmark variants build on the recorded macOS
  host; cross-platform packaging remains an E4 gate.

The benchmark is deliberately not a synthetic score. Runtime latency, memory,
allocations, binary size, and packaging are recorded as separate evidence.
The `root_end` field describes the edited tree; `edited_bytes` makes that
explicit.

## E4 language and packaging evidence

The selected official backend also parses TypeScript and TSX using the pinned
TypeScript grammar with the compatible JavaScript query layer. TypeScript uses
the JavaScript highlights/tags assets plus the TypeScript assets; TSX adds the
pinned JavaScript JSX highlights asset. The `.tsx` extension selects the TSX
grammar while `.ts`, `.mts`, and `.cts` select the TypeScript grammar.

The Go adapter and the TypeScript adapter share only the application-internal
`languageAnalyzer` contract. Both use the same revision-tagged
`editor.SourceEdit` chain, fresh-parse fallback, byte-oriented document
projection, and Scratchpad-owned fold policy. Goldmark remains the root parser
for Markdown, including the conservative fresh-parse fenced-Go composition.

Recorded local macOS builds (`darwin/arm64`, Go 1.27.0):

```text
go build -tags treesitter_cgo -o /tmp/scratchpad-treebench-cgo ./cmd/treebench
go build -tags treesitter_pure -o /tmp/scratchpad-treebench-pure ./cmd/treebench
go build -o /tmp/scratchpad-main ./cmd/scratchpad
```

The resulting binaries were 36,985,474 bytes (official benchmark),
32,975,986 bytes (pure benchmark), and 33,180,466 bytes (Scratchpad). The
Scratchpad binary uses the official CGO adapter on cgo-capable builds; the
benchmark binary's `treesitter_cgo` tag is needed only for the bake-off entry
point.

The CI matrix builds and tests on `ubuntu-latest`, `macos-latest`, and
`windows-latest`, and builds `cmd/treebench` with `treesitter_cgo`. This is
build coverage, not a claim of native interaction certification. No Windows or
Linux desktop smoke session has been performed on this host.

Known limitations at E4:

- the pure-Go runtime remains non-selected because its Go tag query requires
  removing `#set-adjacent!` and does not match the official tag capture stream;
- parser-level cancellation is not used; stale revision results are rejected;
- fold rules are Scratchpad-owned and intentionally cover only the initial
  syntax-node families;
- JavaScript root files are still plain text until a JavaScript-specific
  product adapter is justified; TypeScript's JavaScript query dependencies are
  bundled for TypeScript/TSX only.

## E5 certification

Automated certification passed on the recorded macOS host:

- Go root analysis publishes revision-tagged highlights, tags-derived symbols,
  and Scratchpad-owned folds.
- TypeScript and TSX query layering publishes the same byte-oriented result
  contract, including JSX tags/attributes for TSX.
- Fenced Go inside Markdown is freshly parsed from Goldmark's region and
  translated back to document offsets; unsupported fences remain plain text.
- Incremental and fresh Go projections are compared in tests, and unavailable
  edit chains use a fresh-parse fallback.
- Parsing runs in the existing debounced, globally bounded coordinator; stale
  results are rejected and completion wakes the application without touching
  Shirei from a worker.
- Visible code spans use the existing logical-row byte-to-rune bridge, so no
  full-document Unicode conversion or separate syntax renderer was added.
- `go test ./...`, `go test -tags treesitter_pure ./...`, the required race
  tests, `go vet ./...`, and all command builds passed.

The remaining native certification item is manual desktop interaction while a
parse is pending. It is not claimed here because this run was automated and
headless; it belongs to release-hardening rather than a new parser architecture
slice.
