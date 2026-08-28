# Provisional Scratchpad architecture

This is a boundary document, not a specification for every future package.
The architecture stays intentionally shallow until the scale and language
gates produce evidence.

## Ownership model

```text
Scratchpad application
├── document state and editing policy
├── workspace/files/save/conflicts
├── language providers and derived projections
├── commands and application state
└── Shirei composition

Shirei
├── windowing and platform integration
├── layout, rendering, shaping, bidi
├── input, IME, clipboard, focus
├── generic widgets and virtualization
└── snapshot/headless infrastructure
```

There is one process and one normal Go application state model. There is no
host/guest protocol, replicated document state, capability layer, or revision
bridge inherited from the old Wasm experiments.

## Document model

The product object remains one `Document`, regardless of whether a user treats
the file as a note or code:

```text
Document
├── mutable text buffer
├── file identity and path
├── revision / dirty state
├── root language hint
├── nested/injected language regions
└── disposable derived projections
    ├── symbols / outline
    ├── folds
    ├── todos
    ├── tables
    └── links
```

There must not be `NoteDocument` and `CodeDocument` as competing authorities.
Language and context providers may offer different projections and commands,
but the editing surface and document ownership stay unified.

The scaffold's `document.Document` uses a copied `[]byte` only as a small,
testable placeholder. Gate B decides the serious mutable representation. The
likely evaluation order is a byte-oriented line index plus a simple mutable
buffer baseline, then a gap buffer/piece tree/rope only if workload measurements
show that it is needed. Parser snapshots and undo storage are separate
questions from the live editing representation.

## Package boundaries

Only packages with immediate scaffold value exist today:

- `document/`: product-owned document/revision bookkeeping and the byte line
  index baseline. No Shirei imports.
- `workspace/`: workspace-root validation, path containment, and a baseline
  atomic save helper. File watching, conflicts, ignored files, and sessions are
  later additions here or in clearly justified subpackages.
- `language/`: root-language detection only. Parser/provider adapters arrive at
  Gate E.
- `commands/`: stable command names, not keybinding or context behavior.
- `ui/`: Shirei composition. It should translate application state into views;
  it should not become the document authority.
- `cmd/scratchpad/`: native process entry point.

Planned packages should be created only when a real second consumer or a
coherent state boundary exists. In particular, do not create empty `buffer`,
`edits`, `undo`, `viewport`, `decorations`, `config`, or `session` packages as
architecture theater.

## Editor/view split

The current `TextArea` is the first implementation candidate for ordinary
documents. If it passes Gate B, Scratchpad wraps it rather than replacing it.

If it fails, the smallest custom editor should separate:

1. a document-owned editing/storage layer with byte offsets and mutation-aware
   line indexing;
2. an editor view with viewport, selection, caret affinity, scroll anchor,
   visible-line layout cache, and decorations;
3. a Shirei process/paint adapter that keeps focus, IME, clipboard, and native
   input on the framework side where possible.

The first custom proof should be line-oriented with fixed row height and no soft
wrapping. It should render only visible rows and convert byte/rune positions at
the boundary. Width-dependent wrapping becomes a cache problem after the
scalable baseline is proven.

This is a deep-module opportunity: the buffer/line-index module should expose a
small edit/snapshot/range surface while hiding its data structure. The editor
should ask for slices, line ranges, and mappings rather than reaching into a
rope or piece tree. If a future parser needs input callbacks, the language
adapter should read through the same narrow document snapshot surface.

## Language-provider seam

Language is modeled as a root grammar plus nested/injected regions and
contextual projections. A Markdown heading is not a global meaning of `#`; a
todo marker or table row is active only in its language/prose context.

The eventual provider seam should be query-oriented:

- input: immutable document view/snapshot, root language, visible range, and
  relevant change information;
- output: visible highlight spans and optional structural projections such as
  symbols, folds, todos, links, or tables;
- lifecycle: asynchronous, cancellable, revision-tagged results that are
  discarded when stale.

This is intentionally not a fixed interface yet. It must be tested with two
implementations before it becomes a package contract. Tree-sitter, pure-Go
parsing, Wasm, or a fallback provider are adapters behind it.

## Derived state and caches

Filesystem contents and the current in-memory document are authoritative for
their respective moments. Everything else is disposable:

- parser trees;
- line-layout and shaping caches;
- outline/todo/table/link projections;
- search indexes;
- file listings and watchers;
- session restore data;
- crash-recovery copies.

Every derived result is tagged with document revision and relevant settings
(language, width, theme, or viewport). Stale asynchronous results never mutate
the authoritative document.

## File authority and conflicts

The workspace layer owns:

- open/save and atomic replacement;
- path and rename identity;
- line-ending, BOM, and encoding policy;
- external-change observation;
- reload/keep/compare conflict decisions;
- recovery and session state.

The filesystem remains authoritative after a successful save. Scratchpad does
not synchronize files, invent a note database, or require a cloud service.
Sync tools operate on the ordinary folder outside the application.

The scaffold only contains path validation and a baseline atomic write helper.
The full policy is Gate C work and must be tested on all supported desktop
platforms.

## Unified commands

Commands are application concepts, not mode-specific keybinding universes:

```text
file.open       file.save       document.find
outline.toggle  item.toggle     selection.expand
comment.toggle  document.format
```

A context provider may implement `item.toggle` differently for Markdown and a
programming language, but the command vocabulary stays stable. Configurable
bindings come after semantics stabilize.

## Framework boundary

Scratchpad consumes Shirei. A generic framework limitation is upstream work only
after a minimal reproduction, a focused test, and evidence that the need is
not a product policy. Scratchpad-specific workspace semantics, Markdown todo
rules, parser selection, and command behavior remain downstream.
