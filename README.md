# Scratchpad

Scratchpad is a planned native, file-first text editor and notes organizer. It
is intended to provide one continuous writing surface for notes, prose, tasks,
and code without turning into an IDE or a proprietary note database.

This repository currently contains the research record, a deliberately small
Go scaffold, and the implementation gates. It does not contain a replacement
editor engine, a syntax-highlighting system, Tree-sitter, LSP support, plugins,
or sync logic.

## Current status

The first source audit of Shirei is complete. The central finding is that
Shirei already contains a strong, well-tested editing behavior stack, but its
current `TextArea` stores and shapes a whole bound string. Scratchpad will keep
that behavior as the reference and measure it before deciding whether an
editor-scale buffer and viewport are necessary.

See:

- [`docs/RESEARCH.md`](docs/RESEARCH.md) — findings from the pinned Shirei source.
- [`docs/EDITOR-AUDIT.md`](docs/EDITOR-AUDIT.md) — what `TextArea` solves and where scale is uncertain.
- [`docs/GATE-A-CLOSEOUT.md`](docs/GATE-A-CLOSEOUT.md) — Gate A result and native-smoke limitations.
- [`docs/GATE-B-RESULTS.md`](docs/GATE-B-RESULTS.md) — measurements and the custom-editor decision.
- [`docs/BEHAVIOR-PARITY.md`](docs/BEHAVIOR-PARITY.md) — the parity artifact for the conditional spike.
- [`docs/EDITOR-CORE-CONTRACT.md`](docs/EDITOR-CORE-CONTRACT.md) — the frozen Gate B core boundary.
- [`docs/TREE-SITTER-OPTIONS.md`](docs/TREE-SITTER-OPTIONS.md) — parsing options and the provisional recommendation.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — ownership and package boundaries.
- [`docs/PLAN.md`](docs/PLAN.md) — ordered engineering gates.
- [`docs/SHIREI-CONTRIBUTIONS.md`](docs/SHIREI-CONTRIBUTIONS.md) — upstream boundary and candidate work.

## Run the scaffold

Prerequisite: Go 1.25 or newer, matching the current Shirei module declaration.

```bash
go test ./...
go run ./cmd/scratchpad
```

The current window is intentionally plain: it proves that Scratchpad can
consume Shirei as a normal Go application without introducing an application
runtime boundary.

For local work against the audit checkout, use a replace directive pointing at
your own checkout. For example:

```bash
go mod edit -replace=go.hasen.dev/shirei=/path/to/go-shirei
```

The committed module requirement is pinned to the audited Shirei snapshot;
the replace directive is a local development choice and need not be committed.

## Working rules

- Ordinary files remain authoritative; Scratchpad state is disposable.
- Do not add Tree-sitter or another parser until the language-service gate.
- Do not build a temporary regex syntax highlighter.
- Measure the editor path before replacing Shirei behavior.
- Keep `document` independent of Shirei wherever the product model permits.
- Treat framework changes as small, evidence-backed upstream contributions.

## Gate B benchmark

The real Shirei TextArea benchmark is a headless executable: it runs Shirei
frame layout, text shaping, and surface generation while driving deterministic
synthetic input. Headless mode makes scaling comparisons repeatable; native
smoke remains a separate concern. Add `-software-render` for a separate
software-raster stress run; it is intentionally not part of the large-fixture
default because rasterizing the whole current TextArea surface can dominate the
editor measurement.

```bash
go run ./cmd/textbench -fixture 100k
go run ./cmd/textbench -fixture all -out /tmp/scratchpad-textbench.tsv
go run ./cmd/textbench -fixture 1m -operations first-paint,insert-middle
go run ./cmd/scratcheditor -fixture 10m -operations first-paint,insert-near-9m
go run ./cmd/fragmentbench -edits 10000
go run ./cmd/fragmentbench -edits 100000
```

Output is TSV with document size, operation, wall time, allocation count and
bytes, and heap before/after. The benchmark intentionally records scaling
across 100 KiB, 1 MiB, and 10 MiB rather than enforcing an arbitrary latency
threshold. `fragmentbench` is the separate long-edit-session experiment; its
10k and 100k runs use the same deterministic 10 MiB source and seed.
