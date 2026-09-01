# Gate E parser bake-off

## E0 decision record

The first bake-off uses the same deterministic generated Go source and the
same one-insertion edit for both runtimes. The official C runtime is compiled
through `go-tree-sitter`; the alternate runtime is `gotreesitter`. The
benchmark reports parser structure, upstream highlight captures, and tags
captures separately. Folds are Scratchpad-owned and are not treated as an
upstream grammar asset.

Environment for the recorded run:

- Scratchpad commit: `03389a5ad5883c075fff7efc86cf646d645bca7b` plus the
  uncommitted E0 harness changes that became the next commit.
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
