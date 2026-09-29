# Scratchpad product thesis

## The idea

**Scratchpad is a file-native projection editor.**

Ordinary files are where text lives. They do not have to dictate every way that text can be experienced.

A file remains a durable, portable source. Scratchpad can derive structure from it and, over time, present that source through focused, reduced, or composite views. Where a view maps clearly to source, it can become an editing surface. The view never becomes a competing authority.

The product is not a proprietary note database, a graph users must maintain, or a Markdown-only environment. It is a comfortable text editor foundation that can eventually let one coherent editing model work across notes, prose, tasks, and code.

## What Scratchpad is building now

Version **0.1.0** is about establishing a dependable text editor foundation. The immediate product goal is the basic feel of editing text well: predictable input, caret and selection behavior, navigation, and trustworthy work with ordinary files.

This release is the base on which the product can grow. The distinctive projection ideas below are planned for **0.2.0**. They describe the direction of the project; they are not claims about what 0.1.0 already delivers.

Scratchpad should earn the right to experiment by making the source editing experience solid first.

## The product bet

Traditional editors commonly equate one file with one contiguous editing surface. Scratchpad keeps files as the storage foundation while treating source and view as separate concepts.

That distinction enables a view to:

- show only a useful part of a source;
- place related source ranges next to each other;
- present search matches as a working surface;
- expose an outline or a skim view without creating a second document;
- expand a selection through meaningful prose or language structure.

The user should experience direct actions such as “show only my tasks,” “pin these sections,” “skim this document,” or “edit these search results.” Projection is the model that makes those experiences consistent; it is not a feature users should have to understand before they can write.

Scratchpad does not claim that any single ingredient is new. The product bet is to make these ideas parts of one coherent, writable model grounded in ordinary files.

## Five useful concepts

### Source

The text in ordinary files is the durable authority. During an editing session, Scratchpad keeps one current document buffer for each open source; saving writes that text back to its file. A view does not own a second copy that can silently diverge.

### Structure

Structure is interpretation derived from source: headings, paragraphs, symbols, tasks, links, syntax, search matches, folds, and tables. It is tagged to the source revision that produced it. Scratchpad may discard and rebuild it at any time.

### Identity

Identity connects a piece of derived structure or a view back to its origin: document identity, source range, and source revision. Start with explicit, revision-scoped references. Invest in stronger re-anchoring only when actual workflows show that it is needed.

### Projection

A projection is an ordered view over source ranges and derived structure. It may omit, reorder, combine, annotate, or summarize what appears. When the mapping to source is unambiguous, editing can write through to that source.

### History

History is the time and revision dimension of source and projections. It may eventually enable useful ways to inspect or compose earlier states. It is an exploration area, not a reason to make Scratchpad an event database or to require a canonical revision graph.

The first four concepts define the near-term product direction. History stays experimental.

## Planned projection direction for 0.2.0

The first projection work should demonstrate the thesis in small, understandable steps:

1. **Semantic selection.** Expand a caret or selection through useful boundaries such as a word, inline construct, sentence, paragraph, section, or function. The command can remain consistent while the available structure depends on the content.
2. **Reduced views.** Let users move from full text toward skim or outline density while keeping shown text connected to its source.
3. **Pinned ranges.** Compose a temporary working surface from selected ranges, including ranges from multiple files, without copying them into a new authoritative note.
4. **Editable search.** Present search results with enough context to work in place, mapping clear edits back to their source files.
5. **Other structural views.** Tasks, symbols, links, and similar structures can use the same model rather than becoming unrelated secondary systems.

This sequence is a proving path, not a promise that every item ships together in 0.2.0. Start with views that make the source mapping obvious. A projection edit wholly inside one current segment can map directly to that segment. Stale references and edits that cross source boundaries need explicit handling; early versions should reject ambiguous mutations rather than guess.

## Design laws

1. **Ordinary files are authoritative.** Scratchpad must not require a private database for text to remain useful.
2. **Viewing never implicitly mutates source.** A displayed summary or arrangement does not change its inputs.
3. **Derive aggressively; mutate conservatively.** Rebuildable structure is cheap to replace; source edits require explicit, safe mapping.
4. **Advanced state degrades gracefully.** If derived structure is missing or stale, files remain readable and editable as ordinary text.
5. **Presentation mechanics stay frontend-local.** A frontend may shape, scroll, and arrange a view; shared application state owns document meaning and source mutations.

A feature that breaks one of these laws needs a strong user benefit and a clear explanation of the tradeoff.

## What Scratchpad is not trying to become

Scratchpad's default substrate is not:

- a proprietary note database or block store;
- a mandatory knowledge graph or canonical DAG;
- an infinite canvas used as primary storage;
- a cloud service required to open local work;
- an always-on rewriting system;
- separate document models for prose and code;
- persistent parser state that users must preserve for their files to work.

Graph, AI, block, and sync features can be considered as optional tools or derived views. They do not replace ordinary files as the user's durable source.

## The test for future features

A future capability fits Scratchpad when it makes ordinary source easier to understand or work with while preserving a clear path back to that source. A projection is valuable because it gives text a new useful context without taking ownership away from the file it came from.
