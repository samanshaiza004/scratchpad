# Implementation plan and gates

The order below is intentionally evidence-driven. The main correction to the
initial instinct is that a scalable editor decision comes before language
architecture and before a feature-rich UI.

## Gate C0 — preflight hardening

Objective: enter file-native work with one content authority, explicit save
guarantees, reproducible evidence, broader deterministic fixtures, differential
fuzz coverage, and bounded long-line shaping.

Status: complete. `document.Document` owns one `*editor.ScratchEditor`; the
document no longer stores a `Source` shadow. Atomic replacement now preserves
existing regular-file permissions, rejects symlink paths, flushes the parent
directory on Unix, and requests write-through replacement on Windows. CI runs
tests, vet, and command builds. Realistic benchmark TSV is retained under
`docs/baselines/`, and `FuzzBufferDifferential` retains committed seeds.

The editor view limits each synchronous Shirei shaping request to 64 KiB for a
pathological logical line. This is a responsiveness fallback, not a claim that
long-line horizontal navigation is complete.

Deferred from C0: external-change conflict policy, file watching, encoding and
line-ending policy, complete long-line chunk navigation, and all language or
Markdown work.

## Gate 0 — source-pinned scaffold

Objective: keep a tiny native application and a reproducible research baseline.

Prerequisites: Go 1.25+, the audited Shirei snapshot or its pinned module.

Implementation work:

- keep the normal Go process entry point and minimal Shirei window;
- retain only useful domain baselines: document revision state, line index,
  workspace containment/atomic write, language hint, and command IDs;
- record the source snapshot and local replace workflow.

Tests and benchmarks: `go test ./...`; document and workspace unit tests; line
index baseline benchmarks.

Acceptance: `go test ./...` and `go run ./cmd/scratchpad` work on a Go-equipped
desktop; no parser, LSP, plugin, sync, or custom editor dependency exists.

Framework risks: module/API drift between the pinned Shirei snapshot and later
versions.

Deferred: every product feature beyond the scaffold.

## Gate A — Shirei editor audit

Objective: establish behavioral expectations and a list of proven framework
capabilities.

Prerequisites: current Shirei source, tests, examples, and a native desktop.

Implementation work:

- run the existing text-input behavior and snapshot tests;
- manually exercise multiline input, selection, undo/redo, Unicode, combining
  marks, emoji/ZWJ, bidi, IME, soft wrap, mouse selection, clipboard, and
  programmatic cursor/selection;
- retain `EDITOR-AUDIT.md` as the behavioral reference.

Tests: pure editcore/textinput/textlayout tests; snapshot tests; native smoke
tests on macOS, Linux Wayland/X11, and Windows as available.

Benchmarks: none required for correctness, but capture startup and ordinary
typing baseline.

Acceptance: each capability is classified as works as-is, scale concern,
missing, bug, or unknown; no custom editor is started from assumption.

Framework risks: platform IME/focus differences and single-window limits.

Deferred: upstream issues unless a reproducible generic bug appears.

## Gate B — editor-scale experiment

Objective: determine whether current `TextArea` meets practical file-size and
latency requirements.

Prerequisites: Gate A; benchmark harness and representative fixtures.

Implementation work:

- measure current `TextArea` with 100 KiB, 1 MiB, and 10 MiB files;
- include long single-line, Unicode-heavy, 100 KiB paste, and edits at three
  positions;
- record first paint, typing/backspace/paste latency, scroll, resize, undo,
  peak memory, and allocations;
- if it fails, build the smallest line-oriented buffer/viewport proof with no
  soft wrap and visible-row-only shaping.

Tests: correctness parity for selection, cluster motion, bidi, IME, clipboard,
undo, and hit testing on small fixtures; large-file stress tests.

Benchmarks: repeatable `go test -bench` or behavior harness with a written
machine/environment record; compare work per keystroke against document size.

Acceptance: either a measured decision to use `TextArea`, or a measured list
of failures and a minimal custom editor boundary. This gate now has the
measured failure, balanced-index fragmentation proof, and Shirei-backed visual
parity result recorded in [`GATE-B-RESULTS.md`](GATE-B-RESULTS.md). Gate B is
closed; “it feels slow” was not used as an acceptance criterion.

Framework risks: no public scalable editable-text primitive; custom paint may
need a small Shirei capability or a downstream adapter. A simple piece sequence
has now been replaced by a cached balanced piece index after fragmentation
testing; row-copy allocation remains a measured follow-up bottleneck.

Deferred: soft wrapping, long-line chunked shaping, syntax highlighting,
parser selection, LSP.

## Gate C — file-native Scratchpad

Objective: deliver a useful plain-text editor around ordinary files. Gate C is
the next implementation phase; Gate B and the editor storage architecture are
closed and should not be reopened without new contradictory evidence.

Prerequisites: Gate B storage/view decision.

Implementation work, in order:

1. C1 — open actual files into `Document`, save from the canonical editor
   buffer, establish UTF-8/invalid-UTF-8, BOM, CRLF/LF, disk fingerprint, dirty
   state, Save As, and reload behavior. A no-op open/save should be
   byte-identical where policy permits.
2. C2 — add the open-document registry, stable file identity, tabs, active
   document, independent view state, and dirty-close handling.
3. C3 — treat file-watcher events as hints, re-read/fingerprint disk state,
   reload clean documents, and require explicit conflict handling for dirty
   documents. Never silently overwrite external changes.
4. C4 — add disposable session restore and recovery copies for dirty buffers;
   recovery must never become a hidden note database.
5. C5 — add the file tree, create/rename/delete policy, filename quick-open,
   current-file find, and asynchronous workspace search.

Tests: pure conflict, revision, path, encoding, and command tests; Shirei
snapshots for chrome/tree/tabs/dialogs; native smoke tests for watching,
keyboard shortcuts, clipboard, and window behavior.

Benchmarks: startup, workspace indexing, quick-open, workspace search, open
latency, save latency, idle CPU, and memory with modest/large folders.

Acceptance: a user can open a folder, edit plain text, save safely, recover a
session, and understand an external-change conflict without data loss.

Framework risks: file APIs are caches/pickers, not complete persistence policy;
native watcher semantics differ by platform.

Deferred: syntax parsing, autocomplete, diagnostics, Git UI, sync.

After C5, complete long-line chunk navigation and reduce the measured shaping
allocation cost before Markdown structure or language-service work. The
existing bounded long-line fallback remains a safety mechanism, not finished
editor behavior.

## Gate D — Markdown and structural prose

Objective: prove the notes side without creating a note mode.

Prerequisites: Gate C and a stable document/view model.

Implementation work:

- heading outline and folding;
- Markdown-aware todo, table, and link projections only in eligible regions;
- contextual unified commands such as `outline.toggle` and `item.toggle`.

Tests: pure projection tests with nested/fenced/invalid Markdown and revision
staleness; snapshot tests for outline/folds; native keyboard smoke tests.

Benchmarks: projection latency during typing and on large Markdown files;
ensure parser/projection work never blocks the keystroke-to-frame path.

Acceptance: Markdown structure is useful while the same Document/editor model
still handles plain text and code files.

Framework risks: folds/outline may need stable keyed identity and visible-range
updates; do not make Shirei own Markdown semantics.

Deferred: backlinks, graph view, rich text, collaboration.

## Gate E — language-service proof

Objective: resolve the parser/runtime decision with one or two real languages.

Prerequisites: Gate B scalable snapshot/input boundary; Gate D projection
patterns; selected grammar fixtures.

Implementation work:

- implement a narrow provider seam only after two adapters or equivalent
  evidence shape it;
- compare pure-Go `gotreesitter` with isolated official Go Tree-sitter + CGO;
- prove incremental edits, visible syntax spans, folds, outline, and one
  injection case;
- convert byte captures to rune-indexed visible Shirei spans without a global
  document conversion;
- run parsing asynchronously with revision/cancellation checks.

Tests: parser projection and stale-result unit tests; Unicode byte/rune mapping;
Shirei snapshots for visible highlights; native smoke test for typing while a
parse is pending.

Benchmarks: incremental parse, highlight conversion, memory, grammar payload /
binary size, startup, and cross-build/package time.

Acceptance: one provider works on Markdown plus Go or Rust, the build story is
documented for macOS/Windows/Linux, and unsupported languages remain usable
plain text.

Framework risks: rune-indexed spans versus byte-offset parsers; parser work may
starve frames; a generic visible-span primitive may be missing.

Deferred: LSP, autocomplete, diagnostics, format-on-save, debugging.

## Gate F — unified contextual commands

Objective: make one command vocabulary useful across prose and code contexts.

Prerequisites: Gate D and Gate E semantics.

Implementation work: stabilize command IDs, context providers, enablement,
undo grouping, and eventually user-configurable bindings.

Tests: command behavior independent of UI; keybinding/native smoke tests;
snapshots for menus/palettes if added.

Benchmarks: command dispatch and projection refresh under ordinary typing.

Acceptance: no separate note/code configuration universes are required for the
same conceptual action.

Framework risks: focus/identity and command routing can become coupled to view
construction; keep context explicit.

Deferred: plugin API, macros, broad automation, IDE features.

## Gate G — release hardening

Objective: validate the product as a modest-hardware native desktop app.

Prerequisites: Gates C–F as applicable.

Implementation work: packaging, crash recovery verification, idle/typing/scroll
profiling, accessibility assessment as Shirei evolves, and platform-specific
regression coverage.

Tests: complete pure, snapshot/headless, and native smoke layers.

Benchmarks: cold start, idle CPU, memory by file size, typing latency, scroll
latency, workspace search, save, and parser background load.

Acceptance: ordinary files are always recoverable, unsupported languages remain
plain text, and no background feature blocks editing.

Framework risks: Shirei currently documents one window, no accessibility, and
no GPU surfaces; product scope must respect those facts.

Deferred: cloud sync, collaboration, CRDT, Git UI, execution/debugging, and
plugins until a separate product decision.

## Testing layers used by every applicable gate

1. Pure unit tests for document, line/index, selection mapping, undo, language
   detection/projections, conflict logic, and command behavior.
2. Shirei headless/snapshot tests for layout, editor chrome, sidebars, dialogs,
   themes, and selected/caret visuals where pixels add value.
3. Native smoke tests for IME, clipboard, shortcuts, file watching, window
   behavior, and Wayland/X11/macOS/Windows differences.

Behavior should not be converted into pixel tests merely because a snapshot
harness exists.
