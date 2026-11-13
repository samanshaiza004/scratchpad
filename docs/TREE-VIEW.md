# Workspace Tree View

Scratchpad's workspace explorer uses AliKit's `tree_model` and `tree_view`
packages. The vendored source is pinned in
[`third_party/alicorn-kit/UPSTREAM.md](../third_party/alicorn-kit/UPSTREAM.md),
so a public Scratchpad checkout can build without credentials for the private
AliKit repository.

## Ownership

The Go backend remains authoritative for filesystem listings and mutations.
The Odin frontend keeps the loaded directory snapshots and flattens only the
currently expanded folders into a preorder row projection. AliKit virtualizes
the realized rows and owns tree navigation, focus reveal, Tree/Tree_Item
semantics, stable selection state, and row-anchored context-menu targeting.

Scratchpad owns:

- Directory discovery, ignored-file policy, expansion persistence, and sorting.
- Opening files and expanding or collapsing directories.
- Rename, move, trash, create, and drag/drop policy.
- Context-menu contents and command dispatch.
- The active-document marker, which remains distinct from keyboard focus.

Row IDs reuse Scratchpad's stable semantic IDs derived from the normalized
workspace-relative path and entry kind. Row indices are never identities.
Projection revisions include membership, order, parent, depth, and expansion.
Switching workspaces resets the tree's retained focus state; ordinary changes
preserve compatible rows and the scroll anchor.

## Presentation and interactions

The tree uses the existing theme's folder/file icons and row metrics. A focused
row remains independent of the active editor document. The active document is
accented using the theme's readable contrast fallback, and Alicorn's
differentiate-without-color preference adds an underline.

AliKit handles keyboard navigation and requests expansion or collapse from the
application. A row activation opens a file or toggles a directory. Scratchpad
adds its workspace drag source/drop target to each row and keeps filesystem
operations outside AliKit. The component requests the context menu for a stable
item ID; Scratchpad copies the path and revalidates that the item is still
visible before building destructive actions. Menu actions remain application
commands.

The workspace backend returns bounded entries per directory. Expanding a
directory loads that directory through the existing backend path; AliKit does
not read the filesystem or require a second data provider. Rendering remains
virtualized over the visible preorder projection.

## Build and source

The native build and test wrappers pass the vendored package collection:

```sh
./tools/alicorn.sh run
./tools/alicorn.sh test
```

The AliKit source snapshot includes its component guide, canonical small
consumer, model tests, and retained-runtime tests. See
[`third_party/alicorn-kit/docs/tree-view.md`](../third_party/alicorn-kit/docs/tree-view.md)
for the public component contract and
[`third_party/alicorn-kit/examples/tree_view/main.odin`](../third_party/alicorn-kit/examples/tree_view/main.odin)
for a standalone example.
