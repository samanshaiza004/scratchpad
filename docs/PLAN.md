# Roadmap

## Version 0.1.0 — text editor foundation

The current goal is a reliable, comfortable foundation for editing ordinary text files. The work is centered on the basic editor feel and trustworthy file behavior.

The 0.1.0 bar is a user who can open a file and do ordinary writing and editing with predictable text input, caret movement, selection, and navigation, then trust that the result is saved back to the file. Notes, prose, tasks, and code remain text in the same document model.

This release does not depend on projection workflows. It establishes the source editing experience they will need.

## Version 0.2.0 — projection exploration

The differentiating product ideas in [the thesis](THESIS.md) are planned for 0.2.0. The goal is to prove that a view can differ from a file while staying grounded in source.

Candidate steps:

1. Semantic selection through derived prose and language structure.
2. Full, skim, and outline density views over a document.
3. Temporary pinned views composed from selected source ranges.
4. Search results presented as an editable working surface.
5. Shared projection and source-mapping rules for those experiences.

Treat these as a coherent direction, not a commitment to ship every item in one version. Begin with same-document or single-segment cases where mapping is direct. Keep projections revision-scoped and temporary until real use demonstrates the need for persistent identity. Reject stale or ambiguous writes rather than guessing.

## Longer-term questions

History-aware views, stronger range re-anchoring, and additional structural projections remain research topics. They do not require event-sourced storage, a canonical graph, or a proprietary document format.

## Engineering records

The previous gate-by-gate implementation plan is preserved in [the engineering history](history/IMPLEMENTATION-GATES.md). It records completed investigations and release evidence; this roadmap states product scope.
