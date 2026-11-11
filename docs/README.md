# Documentation

## Current product and architecture

- [Product thesis](THESIS.md) — file-native source, derived structure, projections, and design laws.
- [Roadmap](PLAN.md) — published releases, v0.2.0 scope, and accepted measurement limits.
- [Changelog](../CHANGELOG.md) — consolidated changes from v0.1.0 through Unreleased.
- [Architecture](ARCHITECTURE.md) — ownership, document model, package boundaries, and persistence.
- [Alicorn coverage](frontends/alicorn/PARITY.md) — implemented frontend capabilities and known limits.
- [Session restoration](SESSION-RESTORATION.md) — persisted session, recent workspaces, and recovery boundaries.

## Frontend contracts and design

- [Alicorn setup and usage](../frontends/alicorn/README.md).
- [Editing ownership](frontends/alicorn/EDITING.md) — source edits, interaction state, and Caliber boundaries.
- [Markdown presentation](frontends/alicorn/MARKDOWN.md) — source-preserving Markdown styles, wrapping, and tasks.
- [Semantic zoom and folding](SEMANTIC_VIEWS.md) — reduced source views, local folds, navigation, and cost model.
- [Source projections](design/SOURCE-PROJECTIONS.md), [editor core contract](design/EDITOR-CORE-CONTRACT.md), and [overflow lane specification](design/OVERFLOW-LANE-SPEC.md).
- [Alicorn UI API dogfood](frontends/alicorn/UI-API-DOGFOOD.md) — migration scope and retained-output comparison.

## Research, validation, and history

- [Research index](research/README.md) — active design investigations and measured dogfood.
- [Validation index](validation/README.md) — platform records, manual matrices, and captured artifacts.
- [Baselines](baselines/README.md) — retained-runtime and parser measurements.
- [Engineering history](history/README.md) — completed investigations and implementation records from earlier phases.

Research and validation documents are scoped evidence, not a single current certification statement. Each report should be read with its date, commit, platform, and tested scenario. Use the roadmap for current release scope and the coverage page for implementation status.
