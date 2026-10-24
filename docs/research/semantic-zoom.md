# Semantic zoom for Scratchpad

Researched and revised 2026-10-23 using official documentation, original research
papers, and Scratchpad source/tests. The accepted experiment is four discrete
depths, **Full / Focus / Skim / Overview**, over the same editable source using
explicit line folds. The user's experiment requirements supersede the earlier
read-only-view direction. Recommendations and historical evidence are separated
below; neither the research nor the accepted design proves implementation.
See [the implementation notes][zoom-docs] for the source-editor experiment's
current behavior and limitations.

## Primary-source findings

| Source | Finding and implication |
| --- | --- |
| Microsoft SemanticZoom | Two views represent the same content, usually items versus group headers. Keep layout/panning direction predictable and preserve content scope; header activation switches views and pinch is optional. Scratchpad's four-depth line-fold experiment adapts this correspondence principle rather than copying the two-view control. [Guidance][ms-guide] |
| Microsoft anchoring APIs | View changes exchange source/destination items; `SemanticZoomLocation` includes item bounds, and `MakeVisible` scrolls to and focuses the item. This supports identity-based correspondence. Preserving a particular screen coordinate is our proposed stronger invariant, not a documented pixel-accuracy guarantee. [View contract][ms-contract], [location][ms-location] |
| Emacs Org | Local `TAB` cycles FOLDED → CHILDREN → SUBTREE at a heading; global `S-TAB` cycles OVERVIEW → CONTENTS → SHOW ALL. `org-reveal` exposes the entry and its hierarchy. This demonstrates explicit, reversible structural visibility with separate local/global scopes; it does not specify Scratchpad's Skim excerpts. [Manual][org] |
| VS Code | `editor.mouseWheelZoom` defaults to false and changes editor font size with Cmd on macOS or Ctrl elsewhere. Its handler distinguishes wheel/trackpad input, accumulates smooth deltas, and latches modifiers at gesture start to avoid zoom caused by pressing a modifier during inertia. These are useful input precedents, not semantic-folding rules. [Setting][vscode-options], [handler][vscode-wheel] |
| Apple accessibility | macOS screen Zoom can use modifier-scroll with **Control, Option, or Command**, selected by the user. Therefore none of those single modifiers is universally conflict-free. Apple's documentation does not establish which native events Scratchpad will receive. [Mac guide][apple] |

Relevant source-code focus/context research:

- **Jakobsen & Hornbæk, CHI 2006:** sixteen participants completed tasks faster
  overall with their Java fisheye editor, with task-dependent results. Context
  updates followed scrolling, not caret movement within the focus area. Their
  later studies found no significant performance difference between transient
  and permanent interfaces. This motivates stable, explicit transitions without
  claiming a Scratchpad productivity improvement. [Original papers in the
  author's thesis, papers 1 and 3][fisheye]
- **DeLine et al., VL/HCC 2006:** Code Thumbnails preserves visual file structure
  for spatial navigation. Its eleven-developer study was formative; familiar-code
  behavior and larger-project scaling remained questions. Keep landmarks and
  ordering recognizable. [Paper][thumbnails]
- **Kersten & Murphy, FSE 2006:** Mylar filters/ranks artifacts using persisted
  task context and interaction history. Its sixteen-programmer field study used
  an edit-ratio productivity measure. This is evidence about task-specific
  context, not validation of a universal importance score or deterministic
  document folding. [Paper][mylar]

## Accepted interaction and recommendations

1. Remove the normal **Full / Skim / Outline toolbar**. Use four discrete depths:
   **Full → Focus → Skim → Overview** means less detail; reverse for more detail,
   clamping at the ends. Keep the same source editor, selection, normal text
   size, and scroll axis throughout. A status indicator may expose depth without
   recreating the old toolbar. Keep font zoom independent. This is the accepted
   experiment; Microsoft and VS Code supply precedents, not its specification.
   [Microsoft][ms-guide], [VS Code][vscode-options]
2. Use configurable **Primary+Alt+wheel**: Primary is Command on macOS and
   Control on Windows/Linux; Alt is Option on macOS. Provide keyboard and palette
   equivalents for **More detail**, **Less detail**, and **Full**, with the same
   transitions and anchors. Allow remapping/disabling the wheel binding and
   preserve ordinary scrolling without the chord. Validate accessibility Zoom
   conflicts instead of requiring users to disable it. [Apple][apple]
3. **Typing first reveals Full**, then applies the original input once at the
   preserved source selection, including input-method composition. Remain Full
   while typing: parser completion, caret movement, timers, and pauses must not
   automatically refold. Another explicit zoom action is required to fold again.
   Fold markers reveal source in this editor; there is no read-only excerpt UI
   or required Go to source step. Announce depth, omitted ranges, and focus
   accessibly; keep editing `TAB` available. [Org visibility precedent][org]

**Recommended inertia handling:** observe the whole scroll stream, including
events without the chord. At gesture start, latch whether semantic zoom is
eligible and capture its source anchor. Accumulate deltas into discrete steps
with thresholds/hysteresis; pressing the chord during an ordinary scroll's
inertia must not arm zoom. Modifier release stops stepping and must not rearm
until a new gesture. Use native gesture/momentum phases when available; otherwise
an inactivity boundary is a heuristic requiring device testing. Do not blindly
copy VS Code's timing constants. [VS Code handler][vscode-wheel]

**Inspection/manual limitation:** an earlier working-source inspection found
per-event modifier checks without the recommended gesture-start latch. The
[implementation notes][zoom-docs] now describe intent latching using a 250 ms
gap, with no portable SDL gesture-end phase. That gap remains a heuristic needing
physical-device validation. For manual testing, stop scrolling and wait for
momentum to end before holding the chord and starting a fresh gesture, or use
keyboard/palette commands. Exercise late modifier presses, release/repress during
momentum, and mouse/trackpad input; no native inertia acceptance is claimed here.

## Deterministic source folding

Derive sorted, disjoint folds of complete **logical source lines**, with source
byte/line ranges and omission markers. Fold metadata changes presentation only;
it creates no second buffer, copied excerpt, or summary. Capture the focus on an
explicit action and keep it fixed until the next action. [Org][org],
[source-authority goal][issue]

| Depth | Deterministic policy for the experiment |
| --- | --- |
| Full | All source lines visible; ordinary editing. |
| Focus | Retain the anchored paragraph, Markdown section, or code symbol body in full, with structural/opening-sentence context elsewhere. |
| Skim | Retain Markdown headings, section-opening sentences, tasks, and fence openings; prose paragraph-opening sentences; code signatures, documentation, imports, and type declarations including fields. Fold intervening bodies. |
| Overview | Retain heading/symbol landmarks; for plain prose or heading-free documents, use paragraph-opening sentences as landmarks. |

**Plain prose is supported** by a deterministic paragraph/sentence scan; it does
not need a parser. Define paragraph separators and sentence-ending punctuation,
quotes, abbreviations, and unterminated sentences explicitly. Preserve a complete
opening sentence across source lines. Because folds are line-granular, retain
every logical source line intersecting that sentence: text after its ending on
the same logical line remains visible. Soft wrapping does not create additional
foldable source lines. A single-line paragraph may therefore remain entirely
visible, and some depths can share visible lines in a particular document.

Use parser-derived ranges for Markdown/code where available, retaining multiline
declarations conservatively. Define blank-line/EOF focus, ties, overlaps, malformed
structure, and resource-limit fallback. Identical source revision, anchor,
configuration, and depth must yield identical folds. The in-progress
[fold producer][zoom-producer] is implementation evidence to verify separately;
the historical excerpt UI below does not specify this experiment.

## Proposed anchor invariants

These specialize Microsoft's item correspondence for the folded source editor.
[API precedent][ms-contract]

1. **Identity:** retain document instance, source revision, source byte offset,
   and affinity. Fold row indexes and historical projection generation/ordinal
   keys are not persistent source identity. [Projection precedent][projection]
2. **Selection:** retain both selection endpoints even when hidden. A density
   change cannot alter source bytes, revision, dirty state, or selection.
3. **Viewport:** capture a source anchor and its viewport y coordinate before
   changing layout. Prefer the source under the pointer for an explicit gesture;
   for commands use the visible caret, otherwise the first visible source row.
   Keep viewport anchoring separate from selection.
4. **Hidden anchor:** use its visible source position or the marker for the fold
   containing it, preserving the original byte position for Full. A fallback to
   an enclosing/preceding landmark must not move the stored selection. Empty or
   unsupported plans leave Full available.
5. **Geometry:** after wrapping/measuring, set scroll to the destination anchor's
   content y minus its saved viewport y, clamped to bounds. Preserve source
   identity before pixel position; never translate by scroll percentage.
6. **Round trip and freshness:** Full → any reduced depth → Full without
   navigation restores selection and the source viewport anchor. Reveal Full
   before typing, discard stale folds after edits/reload, and require an explicit
   action to refold. Parser refresh alone cannot hide source again. Resize, font
   zoom, composition, and document reopen need explicit coverage.
   [Source-authority requirement][issue], [revision precedent][projection]

## Historical read-only baseline

[Issue #11][issue] was **open with zero comments** at the original inspection;
this revision does not recheck issue status. Its prose is requirements, not
acceptance evidence. The following facts describe the prior Full/Skim/Outline
read-only experiment at source snapshot
`021cc409d8e18b3a4dfd84c23af847cae9e1fbff`.
They do not recommend retaining that UI or validate the new four-depth experiment.

| Area | Evidence and limit |
| --- | --- |
| Source authority and policy | Ten focused application tests passed during the original research with `treesitter_release`: bytes/revision/selection preservation, Markdown/Go excerpts, unsupported fallback, revision refresh, bounded UTF-8 excerpts, and session density. These tests were not rerun for this documentation revision. [Tests][app-tests] |
| Frontend | Source includes mode controls, read-only reduced rendering, measured wrapping, omission markers, and revision-checked Go to source. Native frontend tests were inspected, not executed here; no interactive acceptance is claimed. [Implementation][frontend], [tests][frontend-tests] |
| Context anchoring | At this snapshot, density changes retain Full's viewport and a separate reduced-list scroll position. The reduced list uses a per-document scroll key; mode changes rebuild its layout. Source-to-source viewport correspondence across modes is not established by that behavior. [Frontend][frontend] |
| Large documents | Frontend pages contain at most 128 excerpts; text is capped at 256 bytes per excerpt. The producer still gathers/sorts all selected structure when rebuilding a revision/mode. Bounded output does not prove bounded rebuild latency or large-document interaction performance. [Producer][producer], [frontend][frontend] |

## Risks and deferrals

Risks to validate: activation during inertia; accessibility gesture conflicts;
hidden-selection context; visual jumps after reflow; sentence-scan ambiguity;
limited reduction on long logical lines; and fold-plan rebuild cost. Exercise
all four depths on prose/Markdown/code, hidden anchors, first typing/composition,
stale revisions, Unicode/CRLF, narrow widths, and large structural counts. Verify
that typing stays Full until an explicit zoom action.

Defer AI summaries, history-based importance ranking, continuous fisheye
distortion, automatic caret-following/refolding, cross-file scope changes,
sub-line sentence elision, and polished gesture animation. Editing remains the
ordinary source editor's responsibility; separate excerpt write-through is
outside this experiment.
Evaluate navigation/reorientation against Full on real prose and code tasks
before claiming a benefit. [Issue non-goals][issue], [fisheye studies][fisheye],
[task-context study][mylar]

[ms-guide]: https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/semantic-zoom
[ms-contract]: https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.xaml.controls.isemanticzoominformation?view=windows-app-sdk-1.8
[ms-location]: https://learn.microsoft.com/en-us/uwp/api/windows.ui.xaml.controls.semanticzoomlocation?view=winrt-26100
[org]: https://orgmode.org/manual/Global-and-local-cycling.html
[vscode-options]: https://github.com/microsoft/vscode/blob/main/src/vs/editor/common/config/editorOptions.ts
[vscode-wheel]: https://github.com/microsoft/vscode/blob/main/src/vs/editor/browser/controller/mouseHandler.ts
[apple]: https://support.apple.com/guide/mac-help/zoom-in-on-your-mac-screen-mchl779716b8/mac
[fisheye]: https://di.ku.dk/english/research/phd/phd-theses/2009/phd_thesis_-_mikkel_r_jakobsen.pdf
[thumbnails]: https://www.microsoft.com/en-us/research/wp-content/uploads/2006/09/Using-Spatial-Memory-to-Navigate-Source-Code.pdf
[mylar]: https://www.cs.ubc.ca/~murphy/papers/mylar/2006-11-mylar-fse.pdf
[issue]: https://github.com/samanshaiza004/scratchpad/issues/11
[producer]: ../../application/view_density.go
[app-tests]: ../../application/semantic_view_test.go
[projection]: ../../application/projection.go
[frontend]: https://github.com/samanshaiza004/scratchpad/blob/021cc409d8e18b3a4dfd84c23af847cae9e1fbff/frontends/alicorn/semantic_view.odin
[frontend-tests]: https://github.com/samanshaiza004/scratchpad/blob/021cc409d8e18b3a4dfd84c23af847cae9e1fbff/frontends/alicorn/semantic_view_test.odin
[zoom-producer]: ../../application/semantic_zoom.go
[zoom-frontend]: ../../frontends/alicorn/semantic_zoom.odin
[zoom-docs]: ../SEMANTIC_VIEWS.md
