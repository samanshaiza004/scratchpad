# Anchored semantic zoom and source folding

Semantic zoom and revision-safe local folding are implemented in the v0.2.0
release candidate. Release acceptance is complete; the worker and platform
evidence are summarized in the [roadmap](PLAN.md) and
[validation reports](validation/README.md). v0.2.0 has not yet been published.

Semantic zoom changes which source lines are visible in the ordinary editor.
It keeps one authoritative Go document buffer, original source line numbers,
byte selections, undo history, save state, and the Alicorn source renderer.
The status bar identifies the active depth; the View menu and command palette
provide depth changes without a persistent toolbar row.

Large semantic plans are built from an immutable source/projection snapshot on
a single cancellable background worker. Inputs above 64 KiB, 2,048 source
lines, or 2,048 derived structures take that path; smaller plans stay on the
serialized command path. While a plan is pending, Full source remains visible
and editable. A new request or source revision supersedes the old generation;
the frontend discards stale results and requests a plan for the latest
authoritative revision after active typing or IME composition settles. Closing
the backend cancels its worker. This keeps source scanning out of the command
lock, while preserving document-instance, revision, and request-generation
checks at publication.

## Interaction

- **More detail:** Ctrl+Alt+Plus on Windows/Linux; Cmd+Option+Plus on macOS.
- **Less detail:** Ctrl+Alt+Minus; Cmd+Option+Minus on macOS.
- **Full source:** Ctrl+Alt+0; Cmd+Option+0 on macOS.
- The View menu and command palette expose the same three actions.
- Modifier+wheel over the editor moves through discrete depths. Ordinary wheel
  still scrolls. Settings → Editor can switch the gesture to Ctrl/Cmd+Shift+wheel
  or disable it. The setting persists in the existing preferences file.
- Existing font-size zoom commands keep their behavior.

The status bar identifies **Full / Focus / Skim / Overview**. A collapsed range
shows its original line interval and an **expand** action. The same disclosure
collapses it again after expansion. Local folds retain their identity within
the current depth; another global zoom transition resets them.

## Manual source folding

In **Full source**, supported Markdown headings and parser-recognized code
blocks have disclosure controls in the line-number gutter. The Document menu
and command palette also provide **Toggle Fold at Cursor**, **Fold All**, and
**Unfold All**. These controls hide whole source lines while keeping the
heading or opening-delimiter line visible. A collapsed heading shows a muted
inline ellipsis when there is room. The gutter chevron expands the fold and
reports the number of hidden lines. Folding does not change document bytes,
revision, or undo history.

Nested folds retain independent collapsed state: collapsing an outer range
temporarily hides its inner controls, and expanding the outer range restores
the inner folds as they were. Manual folds are suspended while another semantic
zoom depth is active and resume when returning to Full source. Editing or
reloading the document discards revision-stale fold state and leaves the new
source visible. Navigation to a hidden source target expands its collapsed
ancestors before resolving visible geometry.

| Depth | Markdown / prose | Supported code |
| --- | --- | --- |
| Full | All editable source | All editable source |
| Focus | Anchored section/paragraph expanded; other bodies folded | Anchored symbol expanded; other bodies folded |
| Skim | Headings, source lines containing complete opening sentences, tasks, code-fence openings | Parser-backed signatures, doc comments, important declarations |
| Overview | Heading hierarchy; paragraph openings when headings are absent | Recognized symbol declarations |

Reduced views fold **whole logical source lines**. An opening sentence
is never cut at the previous 256-byte excerpt limit, but text after that sentence
on the same logical line stays visible. Source syntax and ordering are retained.
Sentence boundaries use deterministic terminal punctuation followed by whitespace;
this is a source-visibility heuristic rather than linguistic analysis of abbreviations.
At reduced depths, hidden ranges containing only whitespace remove their source
rows silently; they do not create an expandable “lines hidden” marker.
Unsupported language adapters keep Full source available. Plain prose does not
need a parser. No heuristic ranks code statements by importance.

## Orientation and editing

Wheel zoom uses identifiable source under the pointer. Empty space and collapsed
ranges retain the current semantic anchor. Commands use the caret/selection end.
The anchor stores an original byte position and its viewport Y coordinate,
separately from both selection endpoints. When its source is hidden, its fold
represents that position. Returning to Full resolves the original byte through
the shaped source row. Geometry is clamped at document edges; scroll percentages
are never used to translate between representations.

Pointer placement and selection operate on the visible source while preserving
the current depth. Single click places the caret, double-click selects a word,
triple-click selects a line, and drag selection stays in source-byte coordinates.
Arrow, word, line, and page navigation follow visible presentation rows and skip
collapsed ranges; they do not rebuild the semantic plan or switch to Full. A
selection that would cross hidden source is refused until that range is expanded.
The local disclosure can then be used to collapse it again without changing the
document's global depth.

Editing keys, IME input, and paste first return to Full and load the bounded
source window for the original caret. The input then follows the existing source
edit path. An edit/reload invalidates the old folding coordinates. The editor
stays Full afterward until another explicit zoom, so parser completion cannot
unexpectedly fold the file while someone types. Save operates on the same
document at every depth; Undo/Redo use the existing document history.

Zoom refuses a transition while an edit, IME composition, or selection drag is
pending. Old parser results do not produce folds for a newer source revision.
Waiting for current analysis leaves source visible; publication can complete
the requested transition. Closing a view frees its plans, pages, and row index.

## Cost and ownership

`application.QuerySemanticZoom` returns detached metadata tagged with document
instance, revision, depth, and source anchor. Folds are disjoint half-open line
and byte ranges. Plans exceeding 4,096 folds explicitly fall back to Full;
there is no silent truncation. Initial construction scans source in bounded
chunks and indexes lines once per explicit transition. Its cost scales with
source size/structure, not just the visible viewport.

The frontend stores a compact fold map rather than one entry for each hidden
line. Source/presentation row lookups are logarithmic in the number of folds.
Wrapping measurements stay in the existing sparse source-height index, with a
separate sparse geometry index for the folded presentation. At most 64 bounded
source pages are cached per view (8 lines / 16 KiB source per page); rendering
uses the same line, selection, and syntax code as Full. Only visible/frontier
rows are realized. No extra work is scheduled while idle.

Alicorn's optional `on_scroll_capture` callback receives the exact modal-aware
retained scroll target before normal scrolling. Scratchpad claims only its own
editor and a configured modifier gesture. Inspector, modal, and nested-control
routing stays with the native host. Detached windows enter their existing
editor scope before invoking the same callback.

Wheel intent is latched until a 250 ms gap; fractional deltas accumulate before
one depth change. Modifier changes during an ordinary scroll do not turn its
tail into zoom. SDL wheel events do not carry a portable gesture-end phase, so
the gap is a deliberate heuristic. Keyboard, mouse, and trackpad acceptance
has been confirmed on macOS and Windows. Pinch,
animation, and automatic fisheye refolding remain separate work. The
source-connected Tasks, Outline, and Links sidebar is a separate projection
consumer documented in [Source projections](design/SOURCE-PROJECTIONS.md).

See [research and original sources](research/semantic-zoom.md) and
[the manual validation matrix](validation/semantic-zoom.md).
