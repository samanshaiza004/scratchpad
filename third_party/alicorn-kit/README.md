# AliKit

AliKit is an optional set of reusable application components for Alicorn, the
native GUI runtime for Odin. It uses Alicorn's existing retained runtime,
controls, semantics, layout, and host input APIs. It does not introduce another
UI tree, state store, or application lifecycle.

The first component is an application-facing command palette. The application
owns command discovery, ranking, and dispatch; AliKit owns query filtering,
selection behavior, modal presentation, and keyboard navigation. Applications
can select AliKit's built-in substring matching or supply already-filtered,
ranked results from their own matcher.

## Current status

AliKit is an early, source-level companion package. Its first component targets
the Alicorn revision recorded in `dependencies.lock.json`. The API may evolve
with Alicorn; pin both projects when consuming it. Built-in matching is ASCII
case-insensitive substring search. The caller-filtered mode preserves an
application's own matching and ranking. Both modes support stable numeric item
IDs, disabled actions, virtualized result rows, focus restoration, and native
host key routing. The palette also accepts optional surface and query
presentation settings so an application can preserve its existing theme and
backdrop treatment.

AliKit does not promise Unicode case folding or fuzzy ranking itself, and it does
not provide command registration, application dispatch, or native OS command
services.

## Repository layout

- `palette_model/` — UI-independent filtering and selection behavior.
- `command_palette/` — Alicorn presentation and native input adapter.
- `examples/command_palette/` — small native consumer showing callback wiring.
- `docs/command-palette.md` — API, ownership, and integration guide.

See the guide before adopting the component in an application. A native Alicorn
consumer needs the same Odin, SDL, and AccessKit setup as other Alicorn desktop
applications.

## Validation

The Windows CI workflow checks the UI-independent model, retained-runtime
interaction tests, and the native example against the exact Alicorn and
AccessKit binding commits in `dependencies.lock.json`. To run the same checks
locally, place the pinned Alicorn checkout at `./alicorn` and run:

```powershell
./tools/test.ps1 -Odin odin
```
