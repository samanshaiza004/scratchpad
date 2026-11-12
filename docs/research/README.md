# Research and design investigations

These notes capture design questions, implementation options, and evidence gathered while developing Scratchpad. A research document may predate the implementation it discusses; check its opening scope and date before treating recommendations as current behavior.

## Current and reusable research

- [Semantic zoom](semantic-zoom.md) — source-anchored reduced views and construction cost.
- [Pinned source ranges](pinned-source-ranges.md) — multi-range source mapping and editing constraints.
- [Theme audit](issue-30-theme-audit.md) — semantic theme roles and appearance coverage.
- [UI sizing dogfood](ui-sizing-dogfood.md) — measured use of Alicorn's public UI helpers.
- [Windows static SDL dogfood](windows-static-sdl-dogfood.md) — package-build and dependency provenance investigation.
- [Workbench views and pane groups (#71)](issue-71-workbench-views-and-pane-groups.md) — stable view identity, shared resources, pane-tree ownership, and a staged implementation plan.
- [Tree-sitter options](TREE-SITTER-OPTIONS.md) — parser dependency and integration choices.

For what is implemented now, use the [roadmap](../PLAN.md), [Alicorn coverage](../frontends/alicorn/PARITY.md), and [changelog](../../CHANGELOG.md). Earlier experiments and superseded proposals are indexed in [engineering history](../history/README.md).
