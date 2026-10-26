# Scratchpad #12: pinned source ranges

Research and implementation record, initially researched 2026-10-24 and updated 2026-10-25. The proposal was approved for implementation against Scratchpad `main` at `c2b68d6`.

Proceed with one read-only, session-scoped **Pinned** working surface, following [#12][issue] and [the v0.2 release direction][release]. Its first purpose is to keep two related implementations and a documentation passage visible while editing another source file. Use the existing projection core, small ordered metadata arrays, bounded source reads, and Alicorn's ordinary split/list controls.

The completion gate is a useful three-excerpt workflow with safe source navigation. Projection write-through remains #13. No new generic sequence library, persistent anchors, hidden document store, or theme infrastructure is needed.

**What the current code supplies**

The implementation base includes the merged anchored semantic-zoom work. Its instance-ID publication, bounded source-page behavior, source navigation, and frame-deferred action conventions are existing seams. Pinned ranges use these conventions without depending on semantic zoom's fold-plan representation.

| Existing seam | Consequence for #12 |
| --- | --- |
| `Application.NewProjection` captures source revision and document instance; `QueryProjection` returns current/stale/missing metadata in windows of at most 256 occurrences. | Reuse its validation and status contract. It already supports duplicate, overlapping, and multi-document ranges. [Core][core] |
| `ProjectionKey` is generation plus ordinal. Rebuilding assigns a new generation. | Add a separate session-local `PinID` so reorder does not change a pin's identity. |
| New projection construction requires every source to be current and open. | A naive rebuild from public segment metadata cannot preserve stale pins. Carry the original internal captured references when changing order. |
| Semantic `QueryView` requires derived structure and returns at most 256 source bytes per excerpt. | Reuse presentation conventions, not this reader: arbitrary pinned selections must remain fully traversable and parser-independent. [Reduced reader][density] |
| The ordinary editor has bounded line/long-line reads and a Caliber resource path; bridge limits are 256 lines, 64 KiB visible bytes, and 16 KiB long-line chunks. | Reuse these limits and byte-mapping rules. Keep Pinned pages separate from the active editor window. [Buffer][buffer], [wire][wire] |
| The application publishes `instance_id`, and semantic zoom fences its cached plans against it. | Reuse the merged identity field. A path and revision alone are insufficient. [Identity publication][instance] |
| Source navigation, frame-deferred actions, split controls, and sparse variable-height lists already exist. | Expect application/frontend changes; no Alicorn API addition is presently justified. [Navigation][frontend], [deferred actions][deferred] |

[Zed's multibuffers][zed] provide a useful precedent for clear excerpt boundaries and direct navigation to their source. [VS Code Peek][peek] demonstrates keeping reference context near ongoing work. These motivate the interaction; their editing and ownership architectures are outside this proposal.

**The first user workflow**

1. Select a nonempty contiguous range in the source editor. Choose **Document → Pin Selection**, the selection context-menu action, or the command-palette command. Do not silently expand an empty caret to a paragraph or function; semantic selection can provide that explicitly.
2. Append the pin and reveal Pinned without taking keyboard focus or moving the source selection. Pinning a preview source promotes it to an ordinary open tab, using existing `PinPreview`, so the next preview does not evict the source.
3. Pin another selection from that file, then one from another file. Repeated or overlapping ranges are independent occurrences, including exact duplicates.
4. Read all three alongside an editable source. A header shows workspace-relative path, original line interval, a full-path tooltip, and clear **Go to source**, **Copy excerpt**, **Move up**, **Move down**, and **Remove pin** actions. Use existing theme roles and font choices.
5. Go to source activates the owning source window, reveals the start, and selects the exact original byte range. Pinned stays available for reference. Moving/removing a pin changes only the arrangement.

Use one resizable pane beside the editor, inside the content area. It has one continuous outer scroller, rather than a separate scroller inside every excerpt. At widths that cannot accommodate both panes, show a switchable single content area with a visible return-to-source control. Native titlebars and document tabs continue to represent source files.

Ship accessible Move up/Move down actions first. Drag reordering, multiple named surfaces, collapsing excerpts, and saved collections can follow demonstrated use. Hide Pinned preserves its contents for the current workspace context; process exit or successful workspace switch clears them. No session-file schema change is needed.

An explicit source-tab close makes its pins unavailable. Reopening the path does not automatically rebind them. This first version does not add hidden source retention. The promotion of previews makes the ordinary three-excerpt workflow reliable while keeping deliberate closes predictable.

The pane is read-only and has no editing caret. Selecting its header selects a pin, independently of the source editor's selection. **Copy excerpt** copies one complete current range only when it fits the 64 KiB copy budget; larger ranges receive an explicit refusal with no clipboard change. Reading is not subject to this total-range limit. Fine-grained selection within an excerpt can be a later interaction improvement.

**Application state and identity**

Keep the collection in `application/pinned_ranges.go`. One possible internal shape is:

```go
type PinID uint64 // session-local, never reused or persisted

type pinnedRange struct {
    id              PinID
    origin          projectionSegment // original source + captured instanceID
    firstSourceLine int               // captured source coordinates
    sourceLineCount int
}

type pinnedSurface struct {
    epoch, revision uint64
    order           []pinnedRange
    projection      *Projection       // immutable derived ordering
}
```

These are illustrative private types. The collection owns metadata, not source bytes, editor objects, or parser nodes. Cap it at 256 pins initially and reject overflow explicitly. Labels are paths/line intervals and optional current structural metadata, not cached excerpt text.

Factor the existing core's capture/validation and immutable construction into small private helpers. A new pin goes through normal current-source validation. Recomposition copies existing `projectionSegment` values, including their original `instanceID`, and assigns a fresh projection generation. It must not look up and recapture an old pin against the current document. This lets stale pins remain removable/reorderable and permits adding a new current pin while another source is stale.

Keep `PinID` separate from the generation/ordinal key. UI anchors and focus use `PinID`; the projection key identifies a particular rendered occurrence in a particular ordering. A surface epoch prevents delayed replies from a cleared or replaced workspace context from being adopted. A surface revision covers membership, ordering, and relevant source-availability transitions. An O(pin count) status scan during normal source-state publication is sufficient at this cap; no dependency graph is needed. Queries still validate their sources directly. All counters and aggregate row counts use checked arithmetic.

Suggested application operations are `PinSourceRange`, `MovePinnedRange`, `RemovePinnedRange`, `QueryPinnedRanges`, `ReadPinnedWindow`, `ReadPinnedBytes`, and `GoToPinnedSource`. Exact names should follow repository conventions; do not publish a pluggable projection framework for this one consumer.

**Capture and navigation are checked at execution**

Pin requests contain an explicit document ID, instance ID, source revision, and normalized half-open source byte range `[start,end)`. Revision zero is valid; validate field presence separately from its value. The request also uses the existing application-state revision fence. The Go application verifies identity, revision, nonemptiness, bounds, and source boundary validity on its serialized owner before capturing the range.

The frontend obtains the current selection from the focused source editor. It must not use an old backend selection merely because the caret is visible elsewhere. Pin is unavailable during IME composition, an active selection drag, or unacknowledged optimistic source edits. Require the committed selection instead of attempting to transform a queued pin through edits. A source-mapped semantic selection is eligible only when it denotes an unambiguous contiguous source range; otherwise use Go to source first.

Go to source sends `PinID` and the expected surface epoch/revision. The application resolves the captured source itself, revalidates it, and produces the ordinary source selection/reveal result. Do not trust frontend-supplied replacement coordinates, map stale offsets through edits, or clamp an invalid destination into a plausible location. Use Full source when needed to expose the range, and honor the existing detached-window owner instead of duplicating the document.

Pin/add/remove/reorder/read do not change source bytes, source revision, source selection, save state, or document order. Preview promotion changes only tab presentation. Go to source intentionally changes source selection and focus, while leaving bytes and undo history intact.

**Visible source-state policy**

| Situation | Pinned behavior |
| --- | --- |
| Same document instance and exact source revision | Render bounded current bytes; enable exact source navigation and bounded Copy. |
| Any edit to that source, including outside the selected range | Show **Source changed — select the current passage and pin it again**. Preserve the pin's label/order; discard its old rendered body. Other sources' pins remain usable. |
| Source explicitly closed | Show **Source closed**; preserve metadata and removal/reorder actions. |
| Same path reopened or replaced at the same numeric revision | Remain unavailable/stale because the instance differs. |
| Undo restores the captured revision in the same instance | The core may make the pin current again, following its existing contract. |
| Rename or Save As changes the document ID | Treat as unavailable initially; no path-based automatic rebinding. |

Do not add a Refresh button that rereads the old offsets in changed source. Repinning is an explicit new capture. A stale pin can offer **Open file to review**, clearly distinct from exact Go to source, without selecting the old range.

Apply this check before both bytes are read and a destination is activated. Invalidate matching cached pages when backend state publishes a source revision/instance/lifecycle change. Parser readiness never controls pin validity.

This conservative policy has a real product cost: editing a pinned file invalidates all its pins. Dogfood must establish whether referencing other implementations/documentation remains useful under that rule. Stronger anchors are a later product decision, not an implicit promise of #12.

**Bounded reading and virtualization**

Large selections must not become one giant shaped widget or silently stop at the semantic view's 256-byte excerpt limit.

Represent the outer list as pin headers, selected logical source lines, and short status rows. Store a small prefix table over the pin row spans; seek into it to map a visible row to `(PinID, source line)`. Rebuild this table in O(pin count) on order/status changes. No record is allocated eagerly for every selected source line. Derive the captured first/last included source lines from `start` and `end-1`, respecting the half-open range. Clip the first and last body lines to the exact selected byte interval; synthetic headers/separators have no source coordinates.

Read a bounded viewport plus a small frontier from authoritative buffers. A response is limited globally to 256 logical rows and 64 KiB source bytes across all included pins, rather than granting that budget separately to every pin. Long lines use the existing 16 KiB chunk policy and an explicit continuation/long-line affordance. No partial line or excerpt is presented as complete. Handle CRLF, final empty lines, partial-line selections, malformed source bytes, and Unicode cluster boundaries using the ordinary source renderer's mapping rules. An overlarge indivisible cluster must fail explicitly rather than produce a no-progress fetch loop.

Use existing Caliber resource ownership for the copied raw bytes, plus a feature-specific bounded descriptor table identifying each chunk's pin, source identity/revision, absolute byte interval, and payload offset. Do not force a multi-source window into the single-document `VisibleWindow` fields. No `Materialize()` or full-buffer snapshot is needed for pinning, scrolling, or navigation.

The frontend owns a separate Pinned page cache, initially at most 16 pages/1 MiB of source payload. Track descriptor and sparse measured-height memory separately; that payload bound is not a claim about total feature memory. Reuse sparse variable-height measurement for visited rows, keyed by pin/source identity, byte range, width, font generation, and text scale. Preserve the viewport through reorder/invalidation with `(PinID, source byte, viewport Y)`, not a flattened row ordinal or scroll percentage.

Serialize authoritative reads with source mutation as the current application does. If loading occurs through a worker, publish only detached bounded data; reject delayed results after epoch/order/source changes. The UI thread owns its layout and caches. No shared mutable projection, reader lock, or persistent tree is required.

**Frontend and command ownership**

Add narrow Caliber commands such as `pin_source_range`, `move_pinned_range`, `remove_pinned_range`, `read_pinned_window`, `read_pinned_bytes`, and `go_to_pinned_source`, plus a small published count/epoch/revision summary. Keep payload text out of the general state envelope. Strictly validate bounds, required fields, integer conversions, and request/resource size limits.

`frontends/alicorn/pinned_surface.odin` owns the pane's split, row mapping, cache, focus, and scroll. Keep this state separate from `Editor_View_State`, `app.editor_window`, and the active source DocumentID. Extract only the source-line paint/mapping helpers actually shared with the editor; do not instantiate several hidden editors to render excerpts.

Use retained IDs and public Alicorn APIs. Schedule collection mutations and source navigation after the description closes, following frame-deferred actions, so a backend publication cannot invalidate borrowed state strings during `build_app`.

Add an explicit read-only Pinned destination to the Edit-command resolver. Copy targets the selected current pin. Cut, Paste, Undo, Redo, typing, and IME cannot fall through to the source editor while Pinned owns focus. Clicking back into the source restores ordinary editing. Shortcut and native-menu dispatch must reach the same destination. Do not tie menu availability to selection state that can change through painting alone without a reliable refresh.

**Delivery sequence**

| Slice | Files and deliverable | Gate |
| --- | --- | --- |
| 1. Headless collection | `application/pinned_ranges.go`, focused tests, minimal private helpers in `projection.go` | Two same-file ranges plus another source; stable IDs; stale-preserving reorder/remove/append; no source changes. |
| 2. Transfer contract | `bridge/caliber/protocol.go`, `runtime.go`, matching Odin bridge DTO/decoder and tests | Current-only bounded reads; identity/revision/epoch fences; resource cleanup; aggregate budgets and continuation. |
| 3. Useful pane | New `pinned_surface.odin`, small wiring in layout/actions/deferred actions/command palette and source input scope | Pin without losing source focus; read all selected content; keyboard reorder/remove/Copy; exact source jump; read-only input isolation. |
| 4. Native acceptance | Windows/macOS dogfood and a short validation report | Complete the real three-excerpt reference task, including narrow layout, DPI/font changes, stale sources, and ordinary editing alongside Pinned. |

Resolve the source-instance publication and focus-aware command routing from the existing work before depending on them. Reuse accepted semantic-zoom helpers where present; #12 does not require further semantic-zoom features. Keep #54 user-theme authoring in its stated v0.3-or-later scope.

**Acceptance tests that should decide whether to ship**

- Pin two distinct and two duplicate/overlapping ranges from A plus a range from B. Reorder/remove them; verify bytes, revisions, dirty flags, source selection, and source file order remain unchanged.
- Edit A, then reorder its stale pin, remove another pin, and append a new current pin from B. The stale pin must not be recaptured, silently dropped, or revived. Test closed/reopened A at revision zero and same-length replacement text. Undo restoration follows the core's exact-instance rule.
- Go to source for every current occurrence selects the exact original bytes, including partial lines and Unicode. Stale/missing destinations fail before changing source selection. Detached sources activate their owning window.
- Pin a preview then open another preview. Pin creation with stale activation data, pending edits, composition, or an ambiguous hidden-source selection cannot capture another range accidentally.
- Read very large and fragmented ranges across multiple documents, including an enormous single line, CRLF, EOF, and malformed UTF-8. Assert aggregate read budgets, continuation progress, bounded source cache, and no full-document copy. Test request decoding at zero revisions and host integer boundaries.
- While Pinned owns focus, native Edit-menu commands and shortcuts cannot alter the editor. Copy either copies the exact complete current range within budget or leaves the clipboard unchanged. Source editing resumes normally after focus returns.
- Hide/reopen Pinned; remove its focused pin; clear it through workspace A → B → A; replace a surface while a page is in flight; destroy the runtime with cached pages. Check focus fallback, scroll anchors, revision fencing, and allocator/resource cleanup.
- Run the three-excerpt task on Windows at fractional scaling and macOS Retina, including font/zoom changes. Measure source-edit/frame p95 with the pane closed and open, first pin/open cost, scroll cost, and live/peak memory using representative 1–10 MB fixtures. Source payload work must remain bounded; there must be no scheduled work at idle. Investigate a repeatable ordinary-editor regression above roughly 5% rather than declaring a microbenchmark victory.

The first implementation should prove the user task and this safety contract. If the pane is awkward to use, revise its workflow before adding persistence, live reanchoring, or write-through editing.

**Implementation status (2026-10-25)**

The first application, Caliber, and Alicorn slices are present on `codex/pinned-source-ranges`. The application preserves private captured projection segments through ordering changes while keeping ordinary `NewProjection` validation strict. It exposes bounded pinned snapshots, row windows, full-range copy with a 64 KiB refusal, exact source navigation, workspace-scoped lifetime, stale/missing status, and source invalidation counts.

The bridge uses explicit required-field validation (including valid revision zero), 256-row / 64 KiB response limits, 16 KiB long-line chunks, and Caliber-owned raw resources. The retained pane uses a single scroll region, sparse measured row heights, a 16-page cache, keyboard-accessible pin actions, a narrow-window source/pane switch, a read-only Edit-command destination, and visible stale/missing status. Cache eviction and rejected response counters are debug-only.

The captured-identity, stale reorder/remove/add, bounded long-line read, UTF-8/CRLF, copy-limit, workspace-lifetime, wire-validation, resource-ownership, stale-response, pane focus/read-only, detached-source focus, and bounded page-cache tests pass. The full Go/Caliber and 195-test Alicorn frontend suite, public runtime API boundary check, and Windows production build passed on 2026-10-25. Native Windows/macOS dogfooding and the strict stale-policy usefulness check remain acceptance work; no claim is made here that those interactions have been physically verified.

[issue]: https://github.com/samanshaiza004/scratchpad/issues/12
[release]: https://github.com/samanshaiza004/scratchpad/issues/17
[core]: https://github.com/samanshaiza004/scratchpad/blob/021cc409d8e18b3a4dfd84c23af847cae9e1fbff/application/projection.go
[density]: https://github.com/samanshaiza004/scratchpad/blob/021cc409d8e18b3a4dfd84c23af847cae9e1fbff/application/view_density.go
[buffer]: https://github.com/samanshaiza004/scratchpad/blob/021cc409d8e18b3a4dfd84c23af847cae9e1fbff/editor/buffer.go
[wire]: https://github.com/samanshaiza004/scratchpad/blob/021cc409d8e18b3a4dfd84c23af847cae9e1fbff/bridge/caliber/protocol.go
[instance]: https://github.com/samanshaiza004/scratchpad/blob/3d57fbfa7dca0672e244a85d4cc6f7cc6fec1b4b/bridge/caliber/protocol.go
[frontend]: https://github.com/samanshaiza004/scratchpad/blob/021cc409d8e18b3a4dfd84c23af847cae9e1fbff/frontends/alicorn/semantic_view.odin
[deferred]: https://github.com/samanshaiza004/scratchpad/blob/021cc409d8e18b3a4dfd84c23af847cae9e1fbff/frontends/alicorn/app_deferred.odin
[zed]: https://zed.dev/docs/multibuffers
[peek]: https://code.visualstudio.com/docs/editing/editingevolved#_peek
