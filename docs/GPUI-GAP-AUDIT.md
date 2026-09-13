# GPUI parity gap audit

This is the feature audit for Scratchpad at starting commit `e621f3b` (the
merged Gate 4 Windows validation commit). It compares the current Rust/GPUI
frontend with the Go/Shirei product surface. The Shirei implementation and its
tests are the behavioral oracle; a pixel-identical renderer is not the goal.

## Evidence and scope

The audit used:

- `README.md`, `docs/ARCHITECTURE.md`, `docs/PLAN.md`,
  `docs/BEHAVIOR-PARITY.md`, `docs/GPUI-DOGFOOD.md`, and the completed gate and
  milestone documents;
- `commands.InitialVocabulary` and `commands.DefaultRegistry`;
- all current `ui/*_test.go` behavior tests and the ten workstation snapshot
  fixtures under `ui/testdata/snapshots`;
- the current GPUI source in `frontends/gpui/src`, its nested Go backend, and
  `frontends/gpui/tests/foreign_smoke.rs`.

The Go/Shirei tests cover the shell, editor input, tree, menus, dialogs,
settings, Markdown, language projections, find/search, and visual states. The
GPUI tests currently cover protocol validation, scheduler coalescing, shell
state reconciliation, the small `EditorSession`, foreign bounded resources,
one optimistic edit, and lifecycle smoke. No GPUI interaction test currently
drives a rendered window.

Status terms in the tables mean:

- **working** — present in the GPUI product path and covered by a relevant
  test or foreign smoke check;
- **partial** — an affordance or lower-level seam exists, but the user-visible
  behavior is incomplete;
- **missing** — no GPUI implementation exists;
- **owned elsewhere** — the behavior remains an application/document concern;
- **frontend-local** — it belongs in Rust/GPUI and must not become a Caliber
  command;
- **blocked** — the required seam or native evidence does not exist yet.

## Current GPUI surface

The GPUI shell can start the nested Go c-shared backend, request a root
directory listing, open a file by clicking a flat tree row, select an existing
document tab, show a dirty marker, save, close with `discard: false`, display a
bounded visible source slice, and show a status line. It can also toggle two
placeholder surfaces labelled command palette and settings. `EditorSession`
proves one UTF-8, non-truncated, one-in-flight optimistic replacement, but it
is not connected to the rendered GPUI view or an input handler.

The protocol currently exposes nine semantic operations (`snapshot`, `ping`,
`open_path`, `select_document`, `save_document`, `close_document`,
`list_directory`, `read_visible_lines`, and `replace_document`). It has no
Scratchpad command ID, projection, search, mutation, settings, recovery, or
conflict payload. `ListDirectory` and `ReadVisibleLines` are coalesced by the
scheduler; semantic edits are not coalesced and the editor permits one pending
edit.

## Parity ledger

### Shell, lifecycle, and workspace

| Shirei-visible behavior and evidence | GPUI status/classification | Acceptance evidence needed |
|---|---|---|
| Open a single file and present a focused editor (`docs/ARCHITECTURE.md`; `TestSnapshotWorkstationSingleFile`) | **partial**. GPUI can open a path only through a tree click or an environment-selected workspace; there is no Open picker or file argument surface in the shell. Application path/document identity remains **owned elsewhere**. | GPUI Open command and picker test; no-workspace and single-file native smoke. |
| Open a workspace, list files, and keep workspace root identity (`TestSnapshotWorkstationFilesSidebar`) | **partial**. Startup workspace comes from `SCRATCHPAD_GPUI_WORKSPACE`; only one flat listing is fetched. Root/workspace authority is **owned elsewhere**. | Root and nested listing tests, refresh/reconcile tests, workspace lifecycle smoke. |
| Files sidebar show/hide and Files/Outline switch (`TestSnapshotWorkstationFilesSidebar`, `TestSnapshotWorkstationOutlineSidebar`) | **missing**. GPUI always renders a fixed tree column and has no Outline surface. Sidebar visibility/mode is **frontend-local**. | GPUI interaction tests for toggle, mode, focus transfer, and responsive layout. |
| Tree expansion/collapse, path identity, focus versus selection, multi-selection, type-ahead, Home/End, PageUp/PageDown, Enter/Space (`tree_navigation_test.go`, `tree_keyboard.go`, `tree_test.go`) | **partial**. GPUI Kit's `TreeState` renders rows; GPUI `ShellModel` stores only a `Vec<TreeRow>`, and there is no recursive listing, expanded-path model, composite focus target, selection set, keyboard dispatcher, or mutation reconciliation. These mechanics are **frontend-local**; filesystem operations are **owned elsewhere**. | GPUI tree model tests matching every navigation and selection case; rendered keyboard tests; large-tree virtualization measurement. |
| Create file/folder, rename, move, trash, refresh, and mutation reconciliation (`tree_test.go`, `commands.InitialVocabulary`) | **missing**. No corresponding protocol command or UI. The operation semantics are **owned elsewhere**; focus/inline rename/mutation presentation are **frontend-local**. | Application contract tests remain unchanged; GPUI command/inline-dialog tests and filesystem integration smoke. |
| File copy path/relative path, reveal, reveal active, drag/drop workspace behavior (`TestWorkbenchCommandsCopyPaths`, `TestTreeDragSelectionMatchesSinglePathPayload`, `revealActiveFile`) | **missing**. No protocol or presentation path. Clipboard/drag gesture mechanics are **frontend-local**; path and reveal operations are **owned elsewhere**. | Native clipboard/drag/drop certification and application command contract tests. |
| Tabs list and activation (`TestWorkstationTabsActivateAndCloseDocuments`) | **partial**. GPUI renders and activates tabs. It has no close affordance per tab, tab keyboard navigation, or context menu. Tab selection is presentation-local; document lifecycle is **owned elsewhere**. | GPUI rendered tab interaction tests for activation, focus, next/previous, and close. |
| Close active, close others, close all, reopen closed, dirty-close confirmation (`TestWorkbenchCommands...`, `closePanel`) | **partial**. A toolbar Close sends `discard: false`; a dirty document returns an application error, but `close_dialog` is never rendered or resolved. Other close/reopen operations are absent. Save/discard policy remains **owned elsewhere**. | Protocol decision payload or explicit close-decision flow; dirty-close, cancel, save, discard, and reopen tests. |
| Dirty/synced/missing/conflict state and conflict panel (`application` status tests; `conflictPanel`) | **partial**. Dirty is a tab dot and status text; conflict/missing have no distinct presentation or actions. Status truth is **owned elsewhere**. | State-to-view tests for all document statuses; external-change/compare/reload/keep smoke. |
| Recovery/session restore (`docs/PLAN.md` C4; application lifecycle tests) | **missing**. No GPUI startup restore, recovery indicator, or recovery decision UI. Recovery data remains **owned elsewhere**. | Application recovery contract tests plus GPUI restore/recovery dialog tests. |

### Commands, menus, dialogs, and focus

| Shirei-visible behavior and evidence | GPUI status/classification | Acceptance evidence needed |
|---|---|---|
| Stable Scratchpad vocabulary and contextual enablement (`commands/commands.go`, `commands/registry.go`, `commands_test.go`) | **missing**. GPUI defines `BackendCommand`, a second Rust enum of transport operations, but no mapping from `commands.InitialVocabulary` IDs to GPUI actions/key contexts. Product command semantics are **owned elsewhere**; GPUI dispatch/focus is **frontend-local**. | A shared command-ID mapping table/test; GPUI action tests prove bindings resolve to existing IDs and do not send raw keypresses through Caliber. |
| Native/application menus (`native_menu.go`, menu reproduction test) | **missing**. No menu bar or menu action routing in GPUI. Menu structure is presentation-local; invoked semantics must use the existing command IDs. | Menu rendering and keyboard invocation tests on each supported desktop platform. |
| Command palette (`workbenchState.ShowQuickOpen`, command registry, snapshots) | **partial**. A button toggles a text placeholder; no searchable registry, enablement, keyboard navigation, invocation, or dismissal. Popup focus/selection are **frontend-local**. | GPUI command palette test with all visible commands, action dispatch, filtering, escape, and focus restoration. |
| Context menus for tree, workspace root, and tabs (`context_click_test.go`, `tree_test.go`, popup snapshot) | **missing**. No secondary-click or context menu. Menu action semantics are **owned elsewhere**; placement/dismissal are **frontend-local**. | GPUI secondary-click, outside-dismiss, keyboard-dismiss, and action tests. |
| Open/Open Folder picker and Save As/overwrite dialogs (`folder_picker_test.go`, `workbench_test.go`, dialog snapshots) | **missing**. Environment configuration is the only open path; no picker, Save As, overwrite confirmation, or error-preserving modal. File policy is **owned elsewhere**; dialog/input is **frontend-local**. | GPUI dialog tests plus native file-picker and Save As smoke. |
| Current find bar, replace, next/previous, and Go To Line (`keymap_test.go`, `workbench_test.go`, `reveal_mapping_test.go`) | **missing**. No input surface or protocol command. Search range/replace semantics are **owned elsewhere**; focus, selection, and reveal are **frontend-local**. | Application search contract tests plus GPUI find/replace/line dialog interaction tests. |
| Workspace search, streamed results, cancellation, and quick open (`application/search.go`, `searchState`, `QuickOpen`) | **missing**. No search stream, cancellation, result list, or virtualized list. Search computation is **owned elsewhere**; result scrolling/focus are **frontend-local**. | Cancellation/stale-result tests and a large-result-list performance test. |
| Keyboard focus routing and escape precedence (editor, tree, dialogs, find, menus) | **partial**. GPUI Kit components receive their own local events, but Scratchpad has no composite focus model or action context. Focus/navigation are **frontend-local**. | GPUI synthetic interaction tests covering modal precedence, focus transfer, and restore. |
| Status rail, save notices, warning/error surfaces (`workbench_snapshot_test.go`, `saveNoticePanel`) | **partial**. GPUI has a single status string/code/revision line; it cannot show save durability warnings, workspace notices, or actionable retry state beyond text. | Outcome-to-status tests for ordinary failures, committed warnings, retryable errors, and conflict notices. |

### Editor and input

| Shirei-visible behavior and evidence | GPUI status/classification | Acceptance evidence needed |
|---|---|---|
| Interactive text editing with caret, selection, undo/redo, clipboard, mouse hit testing, word/line movement, and caret blink (`editor_view_test.go`, `caret_blink_test.go`, `word_navigation_test.go`) | **missing in the product path**. The read-only `format!(...)` viewport is rendered by `main.rs`; `EditorSession` is unit-tested only. Caret, selection, scrolling, shaping, and blink are **frontend-local**. Go bytes, revision, undo/domain semantics remain **owned elsewhere**. | GPUI `InputHandler` editor tests and native smoke for typing, selection, clipboard, undo/redo, mouse, blink, and focus. |
| Optimistic source edit, acknowledgement, stale rejection, rollback (`editor.rs`, `foreign_smoke.rs`) | **partial/working seam**. Gate 4 proves one UTF-8 bounded replacement and stale rejection, but no rendered editor invokes it and no fresh-window reconciliation is wired. | Integrated rendered editor test; deterministic stale rejection/re-fetch/rollback scenario. |
| IME preedit, marked text, UTF-16 selection mapping, replacement, and platform composition (`TestEditableViewPublishesKeyboardAndIMEGeometry`) | **missing and blocked** until a GPUI `InputHandler`-based editor exists. IME state must remain frontend-local; committed source edits cross Caliber. | GPUI Kit/GPUI input test fixtures and Windows/macOS/Linux native IME certification. |
| Source byte fidelity: invalid bytes, BOM, LF/CRLF, missing final newline, byte↔Unicode/UTF-16/glyph mapping (`TestVisualLinePreservesInvalidBytesWithExplicitMapping`) | **partial/blocked**. Caliber preserves raw bytes, but `VisibleTextSlice::display_text()` is lossy and `EditorSession` rejects non-UTF-8/truncated windows. The restriction is explicitly temporary Gate 4 behavior. | Bounded raw-byte display mapping and edit tests for malformed bytes, BOM, line endings, and Unicode clusters; no lossy coordinates. |
| Bounded viewport, overscan, scroll, latest-wins requests, long-line chunks, and no whole-document frame allocation (`editor_view_test.go`, `docs/baselines/*`) | **partial**. Caliber has a 256-line/64 KiB window and scheduler coalescing; GPUI always requests line zero after open/select, has no scroll-driven request, no viewport cache, and no shaping/layout. The frame path must remain document-size bounded. | Scroll/resize stress at 100 KiB, 1 MiB, 10 MiB, long single line, fragmented buffer, and rapid latest-wins requests. |
| Soft wrapping and visual-row movement for prose; code unwrapped; table no-wrap (`editor_view_test.go`, `prose_render_geometry_test.go`) | **missing**. No GPUI text shaping, wrap policy, visual rows, hit testing, or scroll preservation. Layout is **frontend-local**; wrap/table policy originates from application projections. | GPUI layout tests and visual baselines for wrapped prose, wide tables, code, and resize reflow. |

### Markdown, language, and derived presentation

| Shirei-visible behavior and evidence | GPUI status/classification | Acceptance evidence needed |
|---|---|---|
| Markdown heading hierarchy/spacing, emphasis, links, blockquotes, lists, tasks, thematic breaks, source-visible tables, fenced code, inline code (`markdown_presentation_test.go`, Markdown snapshots) | **missing**. GPUI receives only `StateDocument.language` and raw visible bytes; no revision-tagged Markdown spans/blocks reach Rust. Markdown semantics and projections are **owned elsewhere**; style/layout are **frontend-local**. | Add a bounded projection payload or experiment-local resource justified by visible use cases; GPUI semantic rendering tests for every current presentation kind. |
| Markdown command behavior, slash menu, task toggle, table navigation/formatting, one-undo-step semantics (`markdown_presentation_test.go`, `commands.InitialVocabulary`) | **missing**. No command-ID mapping or edit path beyond raw `replace_document`. Transformations remain **owned elsewhere** and must not be recreated in Rust. | Shared command contract fixtures; stale-projection and one-undo-step foreign tests. |
| Outline hierarchy, code symbols, tasks, links, navigation/reveal (`outline_test.go`, `reveal_mapping_test.go`) | **missing**. GPUI has no outline model or panel. Symbol/projection data is **owned elsewhere**; tree/list focus and reveal are **frontend-local**. | Revision-tagged outline resource tests and GPUI outline navigation tests. |
| Go, TypeScript, TSX, and injected/fenced Go syntax spans, folds, stale-result handling (`docs/PLAN.md` Gate E; language tests) | **missing**. GPUI does not receive spans, folds, language regions, or projection revisions and must not run a second parser. Parsing is **owned elsewhere**. | Visible-range span/fold transport tests, stale revision rejection, and GPUI code rendering tests. |

### Settings, design, accessibility, and platform evidence

| Shirei-visible behavior and evidence | GPUI status/classification | Acceptance evidence needed |
|---|---|---|
| Persistent editor font size, increase/decrease/reset, wrap/line-number preferences, theme selection (`settings_test.go`, `font_zoom_test.go`, `theme_test.go`) | **partial**. GPUI has only a placeholder. Product settings are **owned elsewhere**; GPUI applies text metrics/theme locally. | Settings surface tests for load/default/malformed/persist/reload and immediate application across open tabs. |
| Aero Paper visual identity and important states (empty, file, Markdown, tree selection, multiple tabs, sidebars, status, popup, dialog) (`workbench_snapshot_test.go`) | **partial**. GPUI uses generic GPUI Kit controls and plain text; no paper/chrome theme, selected-row state, popup, dialog, Markdown, or GPUI visual baselines. Styling/animation are **frontend-local**. | GPUI-native structural/visual baselines for all ten scenarios; acceptance is semantic state and product identity, not Shirei pixel identity. |
| Accessibility semantics for tree, tabs, commands, dialogs, editor, search, outline, settings | **blocked**. No GPUI accessibility metadata is currently attached because most surfaces do not exist. Accessibility is a strict improvement target for each new surface. | Inspect GPUI Kit accessible roles/labels; add interaction/keyboard accessibility tests and record framework gaps. |
| Native startup, RSS, first paint, typing latency, frame/scroll/resize, idle CPU; Windows/macOS/Linux native validation (`docs/GPUI-DOGFOOD.md`) | **blocked/partial**. Windows validation covers build and smoke lifecycle, while the existing native smoke has no settled RSS or frame/typing measurements. macOS and Linux certification are absent from this branch. | Per-platform manual certification and recorded measurements separating frontend latency, Caliber sync, Go work, and GPU cost. |

## Ownership and boundary decisions

The audit does not justify moving product truth into Rust. Keep these in Go:
filesystem/workspace authority, raw document bytes, revisions and dirty/conflict
policy, save/recovery/session behavior, undo/domain edits, language and
Markdown projections, and command semantics. Caliber should carry semantic
commands, bounded source resources, revisioned edits, and revision-tagged
visible projections only when a concrete GPUI surface needs them.

Keep these in GPUI: window/layout, tree/tab presentation, composite focus,
selection/caret, viewport/scroll, hit testing, IME preedit, shaping/layout,
menus/dialogs, animation, and transient popup/search state. Cursor movement,
raw mouse motion, hover, scroll offsets, IME preedit, glyph positions, and paint
commands must remain local and must not become per-frame Caliber traffic.

The Gate 4 valid-UTF-8 window restriction is the only current source-fidelity
exception. It must be visible in any release-readiness ledger until the editor
has explicit byte/Unicode/UTF-16 mappings. A whole-document string is not an
acceptable shortcut for closing any of these gaps.

## Smallest coherent implementation slices

The slices below preserve a buildable branch and turn one parity family on at a
time. Each slice should add GPUI interaction tests and keep the existing Go/UI
tests unchanged.

1. **Parity artifacts and command bridge.** Add the command-ID/action mapping,
   GPUI key contexts, shared outcome/status mapping, and a protocol envelope
   for command results. Add command palette filtering/invocation and native
   keyboard tests before adding more widgets.
2. **Shell lifecycle.** Implement Open/Open Recent/Quick Open, Save As,
   close-decision dialogs, tab close/next/previous/close-others/close-all/
   reopen, and explicit conflict/recovery state presentation. Keep all
   decisions in application commands.
3. **Workspace tree.** Replace the flat listing with a path-identity model
   supporting recursive expansion, one composite focus target, separate
   selection/anchor/lead, type-ahead, keyboard navigation, inline rename, and
   latest-listing reconciliation. Add mutations only through semantic backend
   commands. Use virtual rows for large trees.
4. **Reusable GPUI input surfaces.** Use GPUI/GPUI Kit input and dialog
   primitives for find/replace, Go To Line, Settings, Open, and Save As. Add
   clipboard, focus precedence, escape, and accessibility tests before wiring
   the editor.
5. **Interactive bounded editor.** Integrate `InputHandler` and a GPUI-native
   shaped text surface around `EditorSession`; add viewport requests, cache
   boundaries, local caret/selection/scroll, optimistic ack/reject/re-fetch,
   and malformed-byte coordinate mapping. Start with one in-flight edit, then
   measure before batching.
6. **Projection and language surfaces.** Add only the bounded, revision-tagged
   Markdown spans/blocks, syntax spans, folds, and outline resources needed by
   visible rows. Port command behavior by ID; never parse again in Rust.
7. **Search and visual closeout.** Add workspace search streams/cancellation,
   quick-open virtualization, context/application menus, sidebar modes,
   theme/settings persistence, semantic visual baselines, and native
   accessibility checks.
8. **Certification and decision.** Measure cold startup, RSS, first paint,
   local edit latency, acknowledgement latency, scroll/frame/resize, and idle
   CPU at 100 KiB/1 MiB/10 MiB plus large trees. Certify Windows, macOS, and
   Linux where available, then update `docs/GPUI-MIGRATION-RESULTS.md` with one
   final recommendation.

## Test migration map

Keep all application/document/workspace/language tests unchanged. Keep the
existing Shirei UI tests while GPUI is a replacement candidate. For each
behavior, add one of the following only when its GPUI slice lands:

| Test ownership | Examples |
|---|---|
| Go/application contract | save/close/conflict/recovery, raw-byte fidelity, workspace mutations, search semantics, Markdown transforms, language projections, stale revision handling |
| Shared frontend-independent contract | command IDs, state/status schema, bounded visible resources, projection revisions, source byte ranges |
| GPUI interaction | focus/context routing, tree navigation/selection, tabs, dialogs, menus, editor caret/IME/hit testing, virtual result lists |
| GPUI visual baseline | empty/file/Markdown/tree-selected/multiple-tabs/sidebar/status/popup/dialog/wrapped/code/folded states |
| Native certification | IME candidate behavior, clipboard, drag/drop, file picker, GPU startup, RSS/frame/idle measurements on Windows/macOS/Linux |
| Obsolete implementation detail | Shirei container IDs, Shirei shape/layout internals, pixel identity with Shirei, direct `TextArea` private-state tests |

This report intentionally leaves Shirei as the parity oracle and keeps it
buildable. It does not recommend making GPUI the default at Gate 4.
