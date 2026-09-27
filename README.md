# Scratchpad

Scratchpad is a planned native, file-first text editor and notes organizer. It
is intended to provide one continuous writing surface for notes, prose, tasks,
and code without turning into an IDE or a proprietary note database.

This repository contains a native Go editor with the Gate B scalable editor
core, the file-native Gate C slices, and the Gate E language-service proof for
Go and TypeScript/TSX. Its current shell uses a compact paper-workstation
visual system; it does not contain LSP support, plugins, or sync logic.

## Current status

The first source audit of Shirei is complete. The central finding is that
Shirei already contains a strong, well-tested editing behavior stack, but its
current `TextArea` stores and shapes a whole bound string. Gate B measured that
scale failure and Scratchpad now uses its own editor-scale buffer and viewport
while retaining Shirei as the behavioral reference.

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

## License status

Scratchpad is released under the [MIT License](LICENSE). “Non-commercial”
describes the project's intent and does not restrict commercial use under the
license.

## Run the scaffold

Prerequisite: Go 1.25 or newer, matching the current Shirei module declaration.

```bash
go test ./...
go run ./cmd/scratchpad
go run ./cmd/scratchpad --version
```

The current/default application, `cmd/scratchpad`, uses Go and Shirei. Its
window separates tactile, cool-gray application machinery from a quiet
warm-paper editor surface.

[`frontends/gpui`](frontends/gpui/README.md) is an experimental second frontend
using Rust, GPUI, Caliber, and a Go backend to prove UI/backend independence.
Its shared cgo bridge is a separate Go module, so ordinary root Go tests remain
independent. It currently provides a shell and bounded document viewport;
the Gate 4 editing seam is exercised through foreign acceptance tests, not a
complete interactive editor with viewport, IME, and shaping support. Shirei
remains the default application.

To build or test the experimental GPUI frontend, use the platform wrapper in
[`frontends/gpui/README.md`](frontends/gpui/README.md). It bootstraps Caliber's
pinned CLI when needed and synchronizes the exact revisions in
`dependencies.lock.json`; a sibling Caliber checkout is not required.

### Experimental Alicorn frontend

The Alicorn frontend is an experimental workbench shell: workspace tree,
document tabs, menus, and dialogs are connected to real Scratchpad state, but
the document area is still a placeholder (there is no text editor yet). Shirei
remains the default frontend.

From the repository root, build and launch it with:

```powershell
.\tools\alicorn.ps1 build
.\tools\alicorn.ps1 run
```

```sh
./tools/alicorn.sh build
./tools/alicorn.sh run
```

`run` also builds before launching, so it is fine to use it on its own. The
wrapper syncs the exact Alicorn and Caliber revisions from
`dependencies.lock.json`; you do not need sibling checkouts. It requires Odin
and Go on `PATH` (or `ALICORN_ODIN` / `SCRATCHPAD_GO`). On Windows, Go must be
64-bit with cgo enabled and a 64-bit MinGW-w64 GCC available; Odin also needs
the MSVC linker and Windows SDK. For checks and platform-specific details, see
[`frontends/alicorn/README.md`](frontends/alicorn/README.md).

The editor starts at a 16-pixel font size. Use **View → Increase Editor Font
Size**, **Decrease Editor Font Size**, or **Reset Editor Font Size** to adjust
it. Keyboard shortcuts are Ctrl+= (or Ctrl+Shift+=), Ctrl+-, and Ctrl+0 on
Windows/Linux, with Command in place of Ctrl on macOS. Font size applies to
the editor across open documents for the current application session.

Open **Settings** with Ctrl+, (or Command+, on macOS) to change persistent
editor preferences. Changes apply immediately and are stored in the user
configuration directory.

Use Ctrl+Left/Right to move by word on Windows/Linux, or Option+Left/Right on
macOS. Hold Shift to extend the selection. Up/Down follows visible wrapped
rows in prose documents.

On macOS, Control-click a file-tree row or document tab to open its context
menu. Secondary mouse/trackpad clicks open the same menus on every platform.

Host-font visual baselines are opt-in:

```bash
SCRATCHPAD_VISUAL_SNAPSHOTS=1 go test ./ui -run TestSnapshotWorkstation
```

For local work against the audit checkout, use a replace directive pointing at
your own checkout. For example:

```bash
go mod edit -replace=go.hasen.dev/shirei=/path/to/go-shirei
```

The committed module requirement is pinned to the audited Shirei snapshot;
the replace directive is a local development choice and need not be committed.

Official desktop builds use the native `tree-sitter-cgo` backend and are built
on native macOS, Windows, and Linux CI runners. Single-host cross-compilation
with the full language-service set is not a supported release workflow. An
explicit `-tags treesitter_pure` build is available for development and
compatibility testing; it intentionally provides Go only and does not claim
TypeScript or TSX support.

## Working rules

- Ordinary files remain authoritative; Scratchpad state is disposable.
- Keep parser adapters behind the language-service seam; unsupported files stay
  ordinary plain text.
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
