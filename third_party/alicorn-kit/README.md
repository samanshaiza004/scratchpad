# AliKit

AliKit is an optional set of reusable application components for Alicorn, the
native GUI runtime for Odin. It uses Alicorn's existing retained runtime,
controls, semantics, layout, and host input APIs. It does not introduce another
UI tree, state store, or application lifecycle.

AliKit currently provides a command palette and a generic Tree View. The
application owns command discovery, ranking, and dispatch; AliKit owns query
filtering, selection behavior, modal presentation, and keyboard navigation.
For trees, the application supplies a visible-row projection and owns hierarchy,
loading, mutations, and commands; AliKit owns navigation, focus, semantics,
virtualized presentation, and optional context-menu targeting.

## Current status

AliKit is an early, source-level companion package. Its first component targets
the Alicorn revision recorded in `dependencies.lock.json`. The API may evolve
with Alicorn; pin both projects when consuming it. Built-in matching is ASCII
case-insensitive substring search. The caller-filtered mode preserves an
application's own matching and ranking. Both modes support stable numeric item
IDs, disabled actions, virtualized result rows, focus restoration, and native
host key routing. The palette also accepts optional surface and query
presentation settings so an application can preserve its existing theme and
backdrop treatment. Tree View supports nested visible projections and bounded
loaded windows, along with stable row semantics, keyboard navigation, and
application hooks for row icons, label colors, drag/drop, and context menus.

AliKit does not promise Unicode case folding or fuzzy ranking itself, and it does
not provide command registration, application dispatch, or native OS command
services.

## Start here

- [Component catalog](docs/components.md) — current packages and when to use
  them.
- [Command Palette guide](docs/command-palette.md) — API, ownership, input,
  appearance, and native integration.
- [Tree View guide](docs/tree-view.md) — stable identities, visible-row
  projections, loaded windows, keyboard navigation, and context menus.
- [Canonical native example](examples/command_palette/main.odin) — a complete
  consumer with app-owned actions and lifecycle.
- [Tree View example](examples/tree_view/main.odin) — a consumer with an
  app-owned hierarchy and expansion state.
- [Agent guidance](AGENTS.md) — project boundaries and validation steps.

The example is intentionally small enough to copy as a starter and is compiled
by the same validation script as the component tests.

## Repository layout

- `palette_model/` — UI-independent filtering and selection behavior.
- `command_palette/` — Alicorn presentation and native input adapter.
- `tree_model/` — UI-independent tree navigation and window reconciliation.
- `tree_view/` — Alicorn tree presentation, semantics, and input adapter.
- `examples/command_palette/` — canonical small native consumer and starter.
- `examples/tree_view/` — canonical visible-projection tree consumer.
- `docs/components.md` — package catalog and responsibility boundaries.
- `docs/command-palette.md` — API, ownership, and integration guide.
- `docs/tree-view.md` — API, ownership, and integration guide.

A native Alicorn consumer needs the same Odin, SDL, and AccessKit setup as
other Alicorn desktop applications.

## Validation

The Windows CI workflow checks the UI-independent model, retained-runtime
interaction tests, and the native example against the exact Alicorn and
AccessKit binding commits in `dependencies.lock.json`. To run the same checks
locally, place the pinned Alicorn checkout at `./alicorn` and run:

```powershell
./tools/test.ps1 -Odin odin
```
