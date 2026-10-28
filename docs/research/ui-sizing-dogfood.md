# Percentage sizing dogfood: editor font picker

Date: 2026-10-28

## Decision

The editor font picker is a useful first Scratchpad dogfood for Alicorn #109. Its panel has a real relationship to the application viewport: use the modal's available inner width, then cap the panel at 900 logical units. Typed percentage sizing removes the manual width calculation while retaining the existing panel, theme, and retained identity.

This is evidence for the narrow percentage-width prototype, not a reason to close #109. Percentage height and arbitrary allocated-parent sizing remain undecided. The converted call site is a panel; it does not currently need percentage sizing on its internal rows or columns. Their existing width, height, and grow arguments express the patterns present there. Keep the low-level typed sizing API available, and extend row/column only when another real call site establishes useful defaults and arguments.

## Before and after

| Measure | Previous panel | Percentage-sized panel |
| --- | --- | --- |
| Geometry declarations | 6 explicit style fields | 7 explicit geometry fields |
| Width rule | min(900, max(viewport.w - 48, 1)) | width=percent(1), min_width=logical(1), max_width=logical(900) |
| Height rule | max_height=min(700, max(viewport.h - 48, 1)) | Same manual viewport-height calculation |
| Content height | Fit content | ui.panel's fit-content default |
| Panel surface and identity | One keyed surface | One keyed panel surface; no wrapper |
| App-owned panel node ID | Stored to find bounds for outside-click handling | Removed; bounds are queried by the existing semantic key |

The declarations increase by one because the minimum width remains explicit to preserve the old positive-width floor. The API is slightly more explicit, not shorter in raw field count. The horizontal -48 calculation is gone; the vertical -48 calculation remains because percentage height is not part of this prototype. The new width declaration states the relationship directly, while the maximum remains an application-specific design constraint.

## Behavior verified

The headless retained-runtime regression builds the picker in a 360×280 viewport. The modal overlay has 24 units of padding on each horizontal edge, so percent(1) resolves to 312 units. The test switches from the Warm theme to Workbench Relief at 1200×800, where the panel reaches but does not exceed its 900-unit maximum. Shrinking to 900×700 releases the cap and resolves to 852 units. Both transitions remain within the viewport and preserve the same Node_ID.

The test also keeps the existing virtual-font-list assertions: the extent represents the full catalog while the realized result window remains bounded. No Scratchpad panel-node field or extra retained wrapper was added.

`.\tools\alicorn.ps1 test` passed on the Scratchpad working tree. Its Go checks and the Alicorn frontend suite completed successfully, including the picker regression. This is runtime geometry evidence; it is not a claim of native visual testing on multiple DPI settings.

## Friction recorded

- **Declaration count:** one additional explicit geometry field (6 → 7). The API is slightly more explicit, not shorter in raw field count.
- **Readability:** improved for width. The old declaration mixed a design cap with viewport arithmetic. The new declaration says “fill the available parent width, at least 1, at most 900.”
- **Remaining manual calculations:** one axis calculation removed out of two. Height still uses min(700, max(viewport.h-48, 1)); no percentage-height capability was added.
- **Unsupported-parent diagnostics:** the first attempt exposed that the generic percentage resolver did not recognize the modal overlay as a definite parent. Alicorn now treats its host-assigned viewport width as definite, after overlay padding. Arbitrary content-sized, growing, and compressible parents are still rejected with a source-located diagnostic. A maximum constraint alone does not make a parent definite.
- **Helper API friction:** keeping Scratchpad's established appearance required passing the panel's shape, material, and physical-height settings through ui.panel. The helper accepts those options while sizing the same surface node. This is useful dogfood evidence for the current helper boundary; it does not yet justify adding parallel row or column wrappers.
- **Feature boundary:** percentages describe preferred extents. They do not divide remaining sibling space. If a later real layout needs proportional sibling allocation, that is a distinct allocator contract.

## Allocator semantics

Alicorn's guide now includes a concrete example: a 400-unit row with two children each requesting percent(0.5) and a 16-unit gap. Each child requests 200 units; total preferred extent is 416. With compression unavailable, the row overflows by 16 units. The allocator does not silently renormalize the requests to 48% each.

## Remaining evaluation

Keep #109 open. The original experiment gate still requires a second materially improved dogfood layout, plus allocation, p95, invalidation, and incremental-versus-fresh replay evidence. This Scratchpad conversion establishes the first example’s width clarity and retained identity, but not those broader adoption criteria. It also does not establish native DPI behavior or a performance benefit. The next decision should follow another genuine use case or evidence that remaining viewport arithmetic materially harms authoring.
