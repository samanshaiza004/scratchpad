# Scratchpad #71: stable views and pane groups

**Research and implementation proposal — 2026-11-11**

Baseline: Scratchpad v0.2.0, commit **05631867b6a6c238aeea59184fa4abcaa581696f**. The pinned Alicorn dependency is **655c0f07dc73b3e22da184ea78e479acd0b0758f**.

## Original recommendation

Implement #71 as a first workbench slice, while keeping its promise narrow: add stable view instances and a small split/tab-group tree around the existing document and view code. Keep file bytes and edit history in the existing Go document. A pane contains a view reference; it never becomes the owner of a document, repository, or process.

Do not start with a universal resource registry, plugin API, layout solver, persistent compositor, or terminal implementation. Use typed references to the resource owners that already exist. Integrate History and Diff through their own resource/view types as #73 lands; terminal views follow the #40/#41 decision.

The central implementation change was to stop using a document identifier as the identity of its presentation. The current workbench has stable view IDs, but the app still does not offer multiple independent editor views of one document.

## Current implementation status — 2026-11-11

This document began as a proposal from the v0.2.0 baseline. The current
unreleased implementation has since added a recursive workbench UI and
integrated the retired Alicorn History application's useful Git surfaces:

- `Workbench_Model` owns view identity, pane groups, and recursive split
  topology. The app renders it through Alicorn's retained Split, TabBar, focus,
  semantics, and drag/drop APIs.
- Editor, History, and read-only Diff are typed views in the same workbench.
  Each split group has its own tab strip; tabs can be reordered or moved between
  groups. History and Diff can open beside the focused view.
- The Go backend remains the shared owner of documents and repository state.
  Historical snapshots do not enter the editable document model. History and
  Diff restore their captured scroll positions when hidden and reopened.
- Editor tabs remain in one pane group because the app still has one live
  editing, IME, and accessibility pipeline. A second independently navigable
  editor view of the same document is not supported.
- Search is still an existing workspace surface rather than a generic view
  kind. Pane placement is not persisted. Terminal sessions are not implemented.
- The standalone Alicorn History repository has been archived after its bounded
  repository/history presentation was consolidated into Scratchpad.

The implementation additions in this branch have not yet received a new
validation run; the historical validation results below describe the earlier
foundation only, not native split interactions.

## Issue and product context

Scratchpad [#71](https://github.com/samanshaiza004/scratchpad/issues/71) is the
pane/view foundation under [#70, the composable workbench roadmap](https://github.com/samanshaiza004/scratchpad/issues/70).
The current slice proves that typed workbench views can share a recursive
layout while resource ownership stays in the existing application services.
Independent editor presentations and terminal process ownership remain future
work. Terminal planning stays with the explicit
[PTY/emulator feasibility work in #40](https://github.com/samanshaiza004/scratchpad/issues/40)
and [single-terminal product issue #41](https://github.com/samanshaiza004/scratchpad/issues/41).

## Baseline findings before pane integration

The following notes describe the v0.2.0 code inspected when this proposal was
written. They explain the original design constraints; they are not a status
report for the current branch.

Scratchpad has useful foundations, but they describe one active document workbench rather than a general collection of views:

- Application has one ordered document list and one Active document. Its Views map is keyed by DocumentID; Session v2 persists one document entry and one view state per document. See [application.go](../../application/application.go) and [session.go](../../application/session.go).
- `App.editor_views` contains editor presentation state including caret, selection, scroll, semantic zoom, folding, and IME state. It now stores the Workbench View ID, but the application lookup remains one-to-one by document ID, so a second editor view would still reuse the first view's state. See [main.odin](../../frontends/alicorn/main.odin) and [editor_model.odin](../../frontends/alicorn/editor_model.odin).
- The main layout has a retained Split for the workspace sidebar/editor and another for source/Pinned. Inside the document-workbench it renders one active document and one document tab bar. It does not recursively render pane groups. See [app_layout.odin](../../frontends/alicorn/app_layout.odin).
- Tab bars already require explicit stable keys and report selection/close actions to the application. Drag/drop is an application-owned Drag_Event; Alicorn does not own tab ordering or interpret the payload.
- The visible-window worker coalesces one pending request per View ID behind a shared active worker. Requests include view lifecycle and request generations as well as document instance, revision, and source range, so sibling requests do not supersede each other. The primary UI still has only one editor view per document; the detached document continues to use its existing separate override.
- The detached-window prototype proves that a document can be presented by a second native runtime, but it duplicates editor state in Floating_Window_State and swaps many fields into and out of the shared App through Floating_Window_Scope. Extending that field-copy protocol to arbitrary groups and windows would multiply lifecycle and ownership risks. See [floating_window.odin](../../frontends/alicorn/floating_window.odin).
- The current clean-session schema stores document tabs, active document, one view record per document, and split widths. It does not store a pane tree. Full layout persistence is explicitly deferred to #72.

These are concrete reasons #71 needs a view identity. They are not reasons to replace the document model.

## Alicorn fit and limits

The pinned public APIs are sufficient for the basic layout mechanics:

- split_begin supports horizontal or vertical splits, minimum sizes, stable UI keys, and a preferred divider position. split_state exposes preferred and resolved positions. Use the preferred value as the model for later restore; let Alicorn own pointer tracking and live divider geometry.
- tab_bar accepts explicit stable item keys, exposes selection and close requests, and can mark tabs as drag sources. drop_target and drag_event_take provide application-level reparent/reorder events. Horizontal magnetic tracking is already available for tab-strip drags.
- The tab-bar result is not a pane manager. Group membership, view ownership, tab ordering, empty-group collapse, and focus policy remain Scratchpad responsibilities.

See the pinned [Split implementation](https://github.com/samanshaiza004/alicorn/blob/655c0f07dc73b3e22da184ea78e479acd0b0758f/runtime/layout_widgets.odin), [TabBar implementation](https://github.com/samanshaiza004/alicorn/blob/655c0f07dc73b3e22da184ea78e479acd0b0758f/runtime/tab_bar.odin), and [drag/drop primitives](https://github.com/samanshaiza004/alicorn/blob/655c0f07dc73b3e22da184ea78e479acd0b0758f/runtime/drag_drop.odin).

Each native window has its own Alicorn Runtime and drag session. From that boundary, I infer that a drag cannot currently be assumed to continue seamlessly across native windows; the inspected public API does not establish a cross-window handoff contract. In-window tab dragging can reparent between groups. Moving a view to another window should first use an explicit command/menu action. Revisit native cross-window dragging only if a reproduction demonstrates a reusable host primitive.

## Proposed identity and ownership model

Keep the four identities distinct:

| Identity | Means | Lifetime |
| --- | --- | --- |
| Resource reference | An existing authoritative document, repository/history query, diff input, or later terminal session | Owned by its domain/application service |
| View ID | One presentation instance of a resource | Stable while moved or hidden; a newly opened second view gets a new ID |
| Pane-group ID | One tab collection and its active view | Stable while the group remains in the layout |
| Window ID | One Scratchpad native window/workbench root | Stable for that host window; never an SDL pointer or Alicorn node ID |

For text files, initially use the existing document ID plus document-instance identity as the resource reference. Do not mint a second document identity or use the file path as a generic resource key. A Save As/rekey must preserve the underlying document instance and every view that references it.

Use typed references for other resource owners as they arrive. For example, a History view refers to a repository/history-query identity, and a Diff view refers to its two revision/source identities. A tagged union is enough; these do not need a registry of arbitrary resources or a public extension protocol.

The minimal model is:

    Workbench
      windows: WindowID -> Window
      views: ViewID -> View

    Window
      root: Split | PaneGroup
      focused_group: PaneGroupID

    PaneGroup
      tabs: ordered ViewID list
      active_view: ViewID

    View
      kind: Editor | History | Diff | (Terminal after #40/#41)
      resource: typed resource reference
      lifecycle_generation: changes when this view closes or is rebound
      request_generation: separate, monotonically increasing generation per view/request lane
      state: type-specific view state

The split node stores a stable split identity, axis, and two children. It does not contain resources. Splitting inserts a group; deleting the last view collapses that group and promotes its sibling. Enforce practical minimum group sizes through the existing Split API rather than introducing an adaptive constraint solver.

### Ownership boundary

- Go remains the authority for document bytes, document revisions, undo/recovery, Git/history data, and resource lifetime.
- The in-memory workbench model in the Odin frontend coordinator owns which view instances exist and which group/window contains them. Keep the topology bounded and update it only for coarse actions such as split, move, close, and focus; never send divider pointer motion through Caliber.
- Alicorn owns realized geometry, divider interaction, keyboard/pointer routing, accessibility presentation, native focus, and retained node identities. Runtime nodes and restore tokens are never serialized as workbench identity.
- View-specific editor presentation state is keyed by ViewID; document edits remain keyed by the existing document/resource identity.
- Durable layout serialization and named arrangements stay in #72. Preserve the current v0.2.0 session fallback for this issue: restoring an older session opens the documents in one group. Do not duplicate a document record just to represent two views.

Keep the live Workbench_Model in the frontend App coordinator for #71. Pane placement, group focus, and split interaction are presentation state, and the issue deliberately defers durable layout persistence. Do not mirror this tree into Caliber's whole application state. Send Go only resource-scoped operations such as editing or selecting a document. Treat Application.Active as a transitional “last focused editor resource” compatibility value; it must not decide which View ID is visible or receive focus. Commands originating from a view should carry that view's typed resource reference.

For v0.2.0 session compatibility, continue saving each document once and restore it into one group. When several editor views reference one document, save the last-focused editor view's legacy caret/scroll state for that document. Do not change the session schema or claim layout restoration in #71; versioned pane-tree persistence belongs to #72.

## Editor state and shared document behavior

Change Editor_View_State from “one editor state per document” to “one editor state per Editor View ID, referencing a document resource.” Keep the fields that describe a user's viewport or editing interaction there: caret, selection, scroll anchor, semantic depth, fold state, wrapping, and IME/preedit recovery. Keep document identity, revision, text, dirty state, and edit/undo history with the existing document.

All retained UI keys and semantic IDs beneath an editor must include the View ID. Scoping only the tab label is insufficient: two views of the same document currently derive the editor component identity from the document ID, which would collide in one runtime.

Visible-source requests also need a View ID and view-lifecycle generation. Two views of one document can request different line windows at the same revision. A single global “latest request” must not cause one viewport to supersede the other. Each request carries `ViewID`, `DocumentID`, `DocumentInstanceID`, document revision, requested range, request generation, and view-lifecycle generation. Use one shared bounded worker pool with pending work coalesced independently by View ID; do not create one worker per view. Reparenting preserves source work when the view identity remains live, while closing/replacing a view invalidates its lifecycle generation. A result is installable only if all of its captured identity, instance, revision, range, and generation fields still match that view's latest request.

Edits remain resource-scoped. If view A has an optimistic mutation awaiting acknowledgment while view B displays another range, B must not treat an older snapshot as current and submit a conflicting edit. Serialize writes through the existing authoritative document edit path. A sibling view may temporarily show its last accepted revision, but it must be visibly stale/read-only until its source window and caret mapping are reconciled to the accepted document revision. Undo from either view uses the same document history. Tests must cover alternating edits, undo from both views, and save while both views are open before claiming coherent shared-document behavior.

Commands capture their origin at dispatch. A small command context should carry at least `WindowID`, `PaneGroupID`, `ViewID`, and the typed resource reference when available. Deferred editor actions must target the resource associated with the originating view, even if focus changes before completion. `Application.Active` can remain a compatibility alias during migration, but must not be used to retarget a view-originated command.

Editing either view mutates the same document and undo history. The other view observes the new source revision and reconciles its own caret/selection through the edit mapping. Undo invoked in either editor view targets the shared document history; it must never create a per-view source undo stack. Define the caret restoration policy explicitly: restore the invoking view's mapped selection, while other views keep independently mapped selections.

Only the focused editor view owns keyboard input and IME composition in a window. Before closing or moving a composing view, follow the existing commit/cancel/recovery behavior; never silently transfer a preedit buffer to another view.

## View lifecycle and interactions

Use explicit operations rather than treating every tab close as resource destruction:

| Operation | View | Resource | Focus |
| --- | --- | --- | --- |
| Move view between groups | Preserve View ID and all local state | Unchanged | Moving the active view follows it; moving an inactive view does not steal focus |
| Split current view | Keep original; create a new View ID over the same Resource ID | Shared | New group receives the duplicate view and focus |
| Close one of several views of a document | Destroy only that view | Keep document open for remaining views | Choose a neighbor in the same group |
| Close last editor view | Run the existing dirty-document close policy | Close resource only after existing save/discard confirmation | Choose a neighbor or empty group |
| Hide a view | Preserve its identity/state while detached from visible layout | Unchanged | Focus moves to a visible group |
| Permanently close a view | Destroy view state and invalidate its async generation | Type-specific policy; Editor resource still follows last-view rule, Terminal process is not killed by view close | No stale completion may restore focus |

For History/Diff, keep query/repository state separate from each view's selection and scroll. Moving a view must preserve all of its state. Make the #71 “close/reopen while preserving selected commit/scroll where supported” behavior an explicit hide/restore or a bounded, session-local reopen state owned by that view kind. Do not imply that v0.3.0 restores arbitrary pane layouts across application restarts; that belongs to #72.

For tab movement, use Alicorn drag events and stable group/view semantic identities. Empty groups need a drop target on their content surface. Split creation should be an explicit keyboard/menu action in this slice; edge-drop-to-split is optional and should not delay the basic move path. Tab and directional group navigation must work without a pointer. If the active tab is dragged into a group, focus follows the view; if a background tab is moved, focus stays where it was.

### Native titlebar policy

Keep connected titlebar tabs while the window contains one pane group. When it is split, render a local tab strip in every visible pane group and leave the native titlebar to platform controls and workspace-level commands. Do not make the titlebar swap to whichever group has focus, and never render two selectable copies of one group's tabs. When the tree collapses back to one group, restore the existing connected-tab presentation. Preserve each editor's source scroll anchor and caret through the content-height change caused by switching policies.

## Delivery plan and remaining work

### 1. Define and test the topology/lifecycle model

**Implemented.** The model and topology operations live in `frontends/alicorn/workbench.odin`; `App` creates its primary window/group, synchronizes document resources, and associates editor state with a Workbench View ID. The request lane is independently keyed by View ID. Existing model tests cover cache identity, resource rekeying, topology invariants, cross-window moves, and failure-atomic rejection. The current UI still has one editor-bearing group; duplicate independently navigable views of one document are deferred. Retain these topology invariants: each live View ID belongs to exactly one group; each active view belongs to its group; global IDs are unique across windows; removing a view invalidates its async generation; and moving an inactive view does not steal focus.

Keep type-specific view payloads narrow. Do not create packages or generic callbacks solely to anticipate plugins.

### 2. Render the tree with pinned Alicorn primitives

**Implemented.** Split nodes are recursively described with `split_begin`, two pane scopes, and `split_divider`. Groups have keyed tab bars and active view renderers using stable group/view identity. Divider positions remain frontend presentation state and pointer movement remains in Alicorn Runtime.

Keep the existing workspace sidebar outside the workbench tree for this slice. Do not turn Pinned, menus, or every transient panel into a pane view.

### 3. Support independent editor views over shared documents

**Deferred.** The current app keeps Editor tabs in one pane group and does not expose duplicate Editor views of one document. A future implementation must make editor state, subtree keys, focus, hit testing, accessibility identity, and visible-window routing view-scoped before enabling this. Edit and undo commands remain resource-scoped; duplicate views will need independent selection reconciliation across shared source mutations and must reject edits from obsolete revisions.

Move the existing detached document path toward the same View record and per-view editor state, rather than adding another Floating_Window_Scope snapshot. Keep native window lifetime and Runtime ownership separate from view identity.

### 4. Add heterogeneous views and close policy

**Implemented for Editor, History, and Diff.** These typed views share the recursive group/tab layout. Git History and Diff use the shared repository backend and remain read-only; their scroll state is captured and restored when hidden and reopened. Source Control remains in the workspace sidebar. Terminal, a generic plugin/view registry, arbitrary duplicate views, and durable pane restoration are not included.

### 5. Native acceptance and performance pass

**Remaining acceptance.** Validate keyboard and pointer focus, accessibility, titlebar behavior, resize, and tab dragging on macOS and Windows, including fractional DPI and lost pointer capture. Verify workspace changes and reparenting during async work cannot install stale results or steal focus. Duplicate-editor edit/undo/save cases remain deferred with duplicate editor views. Confirm a plain-file workspace starts no Git subprocess until needed and that a settled split layout schedules no recurring work.

## Future acceptance matrix

The scenarios below include future duplicate-editor work and are not all
implemented or acceptance-tested by the current pane integration.

| Scenario | Required result |
| --- | --- |
| Split a dirty document into two Editor views | One document buffer and one undo history; edits from either view appear in both |
| Navigate each editor independently | Caret, selection, folds, zoom, and scroll do not jump when focus changes |
| Two views request different source ranges | Both ranges can be installed for the same resource revision; neither request supersedes the sibling |
| Move a tab to another group | Same View ID and local state; active-view focus follows only when the moved view was active |
| Close or reparent during pending visible-source work | Result retains View ID, document instance/revision, requested range, request generation, and lifecycle generation; close rejects it and reparent accepts it only for the same live view |
| Pointer, keyboard, text, and IME input | Each event edits/navigates the view that owns the originating Alicorn target, even when another view references the same document |
| Accessibility actions in both views | Distinct view semantic identities route focus, selection, and text actions to the correct presentation |
| Alternating edits, undo, and save | One source history; the initiating view restores its mapped selection while sibling positions reconcile independently |
| Close one duplicate editor | Other view and shared dirty document remain intact |
| Close last dirty editor | Existing save/discard/cancel flow remains authoritative |
| History and Diff coexist with editors | Typed view kinds render in the same split/tab tree without owning source bytes |
| Hide/restore or close/reopen History | Preserve selection/scroll according to the explicit view-kind policy |
| Keyboard-only operation | Split, switch groups, navigate tabs, move/close views, and resize dividers without pointer-only actions |
| Native accessibility | Groups, tabs, split handles, active view, and focus changes expose meaningful semantics on macOS and Windows |
| Resize, narrow width, fractional DPI, lost capture | Split bounds remain valid; resize tracks the pointer without spring lag; no pane becomes unreachable |
| Plain file launch | No Git or PTY initialization; idle split layout schedules no recurring frames |

## Risks and friction to plan for

1. **Document ID is currently overloaded as presentation identity.** This is the principal correctness blocker for duplicate editor views. Every node key, semantic ID, request, restore token, and selection lookup must be audited for whether it is resource-scoped or view-scoped.
2. **The detached-window state-swap protocol is too expensive to generalize.** A view-owned state record should replace field-by-field snapshots; window-owned Runtime/theme/chrome state remains separate.
3. **Backend active-document assumptions are widespread.** Menus and commands that currently read Application.Active need a deterministic target rule: commands from an Editor use that view's resource; commands from History/Diff use their explicit resource; global file actions use the last focused Editor or ask the user. Do not silently target whichever document happened to be active before a pane switch.
4. **Duplicate editor views require independent bounded viewport work.** The current request/result path is keyed by View ID, but duplicated editing is not yet exposed. Preserve bounded work while preventing one view from canceling another's request when that capability is added.
5. **Native titlebar tabs have one visual home.** The current implementation uses connected titlebar tabs for one group and group-local tabs when split. Keep this policy aligned if additional platform titlebar modes are introduced.
6. **Close, hide, resource close, and process termination are distinct.** Current Editor close follows the document's existing dirty-close flow; History/Diff close or hide retains type-specific state. Define terminal process lifetime separately if a terminal view is added.
7. **Session v2 is document-oriented.** Keep old sessions readable and restore them into one group. Defer durable pane trees and arbitrary view restoration to #72.
8. **Do not pull in Alicorn #143 implicitly.** Split resizing and tab movement should use current target geometry and finish immediately; target-first FLIP continuity is an optional, separately measured motion experiment described by [Alicorn #143](https://github.com/samanshaiza004/alicorn/issues/143).

## What would count as a generic Alicorn gap?

The current Split, TabBar, drag-source/drop-target, focus, and semantic APIs appear sufficient for the first slice. Keep the arrangement tree and lifecycle in Scratchpad. File an Alicorn issue only if a minimal consumer fixture demonstrates a missing reusable mechanism—for example, if a view cannot be reparented with stable interaction identity, a split cannot support the needed focus/accessibility contract, or the host cannot perform an explicitly requested cross-window transfer. Do not move Scratchpad's resource or pane policy into the UI framework.

## Sources

- [Scratchpad #71 — stable view identity and split/tab groups](https://github.com/samanshaiza004/scratchpad/issues/71)
- [Scratchpad #70 — composable, file-native workbench](https://github.com/samanshaiza004/scratchpad/issues/70)
- [Scratchpad #40 — terminal feasibility](https://github.com/samanshaiza004/scratchpad/issues/40)
- [Scratchpad #41 — one integrated terminal](https://github.com/samanshaiza004/scratchpad/issues/41)
- Alicorn source at pinned revision [655c0f0](https://github.com/samanshaiza004/alicorn/tree/655c0f07dc73b3e22da184ea78e479acd0b0758f)
- Scratchpad baseline [0563186](https://github.com/samanshaiza004/scratchpad/commit/05631867b6a6c238aeea59184fa4abcaa581696f)
