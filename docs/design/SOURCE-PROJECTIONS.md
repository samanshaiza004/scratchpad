# Ephemeral source projections

The v0.2 projection core lives in `application`, beside the open-document
registry. A projection is an immutable ordering of source ranges. It contains
document IDs, exact source revisions, byte offsets, labels, and context metadata;
it owns no document text and retains no document, editor, parser, or frontend
objects. Dropping it discards only derived metadata.

`Application.NewProjection(id, kind, segments)` validates every segment against
an open authoritative document. A segment must be nonempty, in bounds, and at
the current source revision. Sources may repeat or come from different files.
Construction copies the input and assigns a new generation. An occurrence's
presentation key is its generation plus ordinal, so repeated ranges remain
distinct and keys stay stable for that generation.

`Application.QueryProjection(projection, first, limit)` returns copied metadata
for at most 256 occurrences, including total count and generation. Its work and
allocation depend on that window, not source size or total projection size.
It reads no source bytes. Consumers arrange, virtualize, shape, and scroll their
own presentation; there is no serialized universal document model.

Each returned occurrence explicitly says `current`, `stale`, or `missing`.
Both the document instance and its source revision must match. Closing and
reopening the same path cannot revive an old range when the new buffer starts
at revision zero. Undo in the same document may restore the exact original
revision and make a range current again. No offsets are silently rebased.

Projection creation and queries run on the application goroutine alongside
source mutations. They do not change bytes, selection, save state, or file
order. Rebuilding/reordering a projection produces a new generation and leaves
its sources untouched.

The Caliber `read_view_window` command also exposes parser-owned tasks,
symbols/headings, and links through bounded structural views. Scratchpad's
Outline sidebar consumes these windows for the active document, navigates to
exact source bytes, and routes task toggles through the existing command
system. It does not persist a graph or copy authority into the sidebar. Any
future write-through projection must revalidate the source and reject stale or
ambiguous mapping at the moment it applies.

Language-derived selection ranges remain separate disposable analysis. They
provide meaningful candidate ranges for `selection.expand`; future projection
producers can turn those source coordinates into ordered segments without
exposing parser nodes.
