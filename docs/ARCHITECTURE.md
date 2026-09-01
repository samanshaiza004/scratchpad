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

`document.Document` now owns one `*editor.ScratchEditor`; its `Buffer` is the
only authoritative in-memory content. `Document.Revision()` delegates to the
editor's byte-state revision, and `SavedRevision` determines dirty state.
Document metadata, disk identity, and derived projections never copy the full
text. Mutations should enter through the document editing methods so derived
state is invalidated at the same seam; callers that work directly with the
editor must still check the revision-tagged projection validity.

The application shell has two presentations over that same model. Opening a
file without a workspace keeps `HasWorkspace` false and presents a focused
editor; opening a directory enables the workspace tree and its per-document
views. `ui` owns this presentation choice, while `application.OpenPath` stays
the shared file-or-directory entry seam.

## Package boundaries

Only packages with immediate scaffold value exist today:

- `document/`: product-owned document identity, revision bookkeeping, derived
  projection tags, and the byte line index helper. Its only text authority is
  the editor package; it has no Shirei imports.
- `workspace/`: workspace-root validation, path containment, file-store and
  disk-fingerprint policy, atomic replacement, advisory directory watching,
  directory listing, and raw-byte search.
- `application/`: the product coordinator for OpenPath, document registry,
  active/tab state, conflict resolution, session metadata, and recovery.
- `language/`: root-language detection plus the replaceable concrete Markdown
  projection adapter. Parser/provider seams for other languages remain a Gate
  E decision.
- `commands/`: stable command names, not keybinding or context behavior.
- `ui/`: Shirei composition. It should translate application state into views;
  it should not become the document authority.
- `cmd/scratchpad/`: native process entry point.

Planned packages should be created only when a real second consumer or a
coherent state boundary exists. In particular, do not create empty `buffer`,
`edits`, `undo`, `viewport`, `decorations`, `config`, or `session` packages as
architecture theater.

## Editor/view split

The current `ScratchEditor` is the Gate B-proven implementation for ordinary
documents. It separates:

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

The current internal provider seam is query-oriented:

- input: immutable document view/snapshot, root language, visible range, and
  relevant change information;
- output: visible highlight spans and optional structural projections such as
  symbols, folds, todos, links, or tables;
- lifecycle: asynchronous, cancellable, revision-tagged results that are
  discarded when stale.

The application keeps the interface private to its language coordinator. The
document-facing concepts are parser-neutral byte spans, symbols, folds,
injections, and revision tags; Tree-sitter runtimes, Goldmark, parser trees,
and Shirei types remain behind their adapters. A backend must fall back to a
fresh parse when its edit journal chain is unavailable.

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

Markdown projections are captured from `document.DocumentSnapshot` after the
150 ms edit debounce. Snapshot capture copies piece descriptors; materializing
bytes and parsing happen in bounded background workers. The application keeps
one latest desired revision per document and at most two global projection
workers. Goldmark types do not cross `language/markdown`, so changing the
Markdown parser does not change document ownership or UI contracts.

## Save semantics

`workspace.AtomicWriteFile` provides atomic visibility by writing a temporary
file in the destination directory, writing all bytes, syncing and closing the
temporary file, then replacing the destination. Readers see either the old
file or the complete replacement; they do not observe a partially written
replacement. Existing regular-file permissions are preserved. Symlink paths
resolve and replace their validated final regular-file target so the link
itself remains intact. Hard-linked files are rejected by the atomic path to
avoid silently breaking their relationship.

On Unix, the parent directory is opened and synced after the rename, covering
the directory-entry durability step described by the Linux `fsync(2)` manual
page ([man7.org](https://man7.org/linux/man-pages/man2/fsync.2.html)). macOS
uses the same directory-sync path, but its `fsync(2)` documentation warns that
drive/OS power-loss behavior can still be weaker than an application can
prove ([Apple fsync(2)](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fsync.2.html)).
Windows uses `MoveFileEx` with `MOVEFILE_REPLACE_EXISTING` and
`MOVEFILE_WRITE_THROUGH`; Windows has no portable directory-handle equivalent
for the Unix post-rename sync ([Microsoft MoveFileEx](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-movefileexw),
[Microsoft FlushFileBuffers](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-flushfilebuffers)).
The implementation therefore claims atomic replacement and the strongest
available OS flush request, not immunity from storage hardware that lies about
flush completion or sudden power loss.

The POSIX rename contract keeps the destination name visible throughout the
replacement and leaves it unaffected when rename fails for reasons other than
I/O failure ([The Open Group rename](https://pubs.opengroup.org/onlinepubs/9699919799/functions/rename.html)).

## File authority and conflicts

The workspace layer owns:

- file loading, saving, and atomic replacement;
- path and rename identity;
- line-ending, BOM, and encoding policy;
- external-change observation and disk fingerprints.

The application layer owns the open-document registry, active/tab state,
reload/keep/compare conflict decisions, and recovery/session orchestration.

The filesystem remains authoritative after a successful save. Scratchpad does
not synchronize files, invent a note database, or require a cloud service.
Sync tools operate on the ordinary folder outside the application.

Gate C now contains the file store, raw-byte document lifecycle, open-document
registry, parent-directory watcher hints, verified reconciliation and conflict
state, disposable session/recovery state, workspace listing, and asynchronous
raw-byte search. Native platform certification remains an explicit C7 task.

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
