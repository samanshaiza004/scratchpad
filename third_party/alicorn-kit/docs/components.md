# AliKit components

AliKit is a small, optional set of source-level Odin packages built on Alicorn.
It does not add another runtime, component lifecycle, or application state
store. This catalog describes the packages that exist today.

## Available packages

| Package | Use it for | Ownership |
| --- | --- | --- |
| `alikit:palette_model` | Filtering and navigating a caller-owned list without UI dependencies | The application owns items, stable IDs, ranking, and activation. The model borrows item text and stores selection by ID. |
| `alikit:command_palette` | An accessible modal palette with a controlled query, selection, keyboard navigation, virtualized results, and focus restoration | The application owns command discovery and dispatch. AliKit owns palette interaction and presentation. |
| `alikit:tree_model` | UI-independent tree-row validation, keyboard navigation, stable focus/selection, and paged-window reconciliation | The application owns the hierarchy, visible projection, loaded data, and commands. |
| `alikit:tree_view` | Accessible virtualized tree rows, indentation, focus reveal, keyboard navigation, and optional row-anchored context menus | The application owns expansion/loading policy, mutation, activation, selection policy, and context-menu actions. |

The native command-palette example is the canonical starting point for a small
Alicorn application using AliKit. It shows application-owned actions, optional
appearance settings, host callbacks, state initialization, and cleanup:
[`examples/command_palette`](../examples/command_palette/main.odin).
The tree example shows how an application builds a visible preorder projection
and handles expansion while AliKit owns reusable navigation and presentation:
[`examples/tree_view`](../examples/tree_view/main.odin).

## Choosing palette search behavior

Use the built-in substring mode when each whitespace-separated query term
should match contiguously in an item's title, description, or keywords. ASCII
letters compare without case; non-ASCII UTF-8 bytes compare exactly.

Use `Search_Mode.Caller_Filtered` when the application already has a matcher,
aliases, ranking, or recency policy. Build a fresh result slice for each
description and input turn, preserving stable, unique, nonzero `Item_ID` values.
The palette keeps selection by item ID rather than filtered row index.

See [the command-palette guide](command-palette.md) for the complete API,
ownership and lifetime rules, native callback wiring, presentation options,
and IME limitations.

See [the Tree View guide](tree-view.md) for stable row identity, full and paged
visible-row windows, keyboard behavior, context-menu targeting, and the
application-owned data contract.

## Not in AliKit yet

Calendars, color pickers, split panes, terminals, and rich editors are not
available AliKit components. Add a component when a real application need
demonstrates reusable behavior; keep application-specific data and policy in
the application, and keep independent domain engines outside the UI runtime
where practical.
