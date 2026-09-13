# GPUI parity ledger

Status: initial audit of Scratchpad `main` at `e621f3b` (the merged Gate 1–4
GPUI/Caliber baseline). The ledger is deliberately written before a substantial
GPUI implementation pass. The current Go/Shirei application is the behavioral
oracle; a GPUI item is not considered complete because its Go application
operation already exists.

This is a parity ledger, not a replacement design. It records what a user can
see or do in the current Shirei workbench, what the current GPUI executable
actually provides, and the evidence required to close the gap.

## Classification

The `classification` column uses the following terms:

* **working** — the behavior is available in the GPUI frontend and has direct
  GPUI/foreign evidence;
* **partial** — a protocol, model, or headless proof exists, but the behavior
  is not exposed as an equivalent interactive product surface;
* **missing** — no GPUI implementation exists;
* **application-owned** — the semantic authority already exists in Go and must
  remain there; this is an ownership note, not a claim of GPUI parity;
* **frontend-local** — the behavior belongs in Rust/GPUI and should not cross
  Caliber;
* **can improve** — parity is required, but GPUI has a concrete opportunity to
  improve latency, shaping, focus, accessibility, or rendering;
* **blocked** — the behavior cannot be accepted until the named external or
  architectural evidence exists;
* **obsolete** — the behavior is a Shirei implementation detail with no user
  contract to reproduce.

Most rows carry two labels, for example `missing; application-owned`. This
means that the Go side already supplies the product semantics, while the GPUI
presentation or bridge is still absent.

## Evidence baseline

The audit used the following sources at the starting commit:

* `README.md`, `docs/ARCHITECTURE.md`, `docs/PLAN.md`, and
  `docs/BEHAVIOR-PARITY.md`;
* completed Gate A/B, Gate E, Milestone M/N, and Gate F records, especially
  `docs/GATE-A-CLOSEOUT.md`, `docs/GATE-B-RESULTS.md`,
  `docs/GATE-E-RESULTS.md`, and `docs/GATE-F-AUDIT.md`;
* `commands.InitialVocabulary` and the command registry in
  `commands/commands.go` and `commands/registry.go`;
* every current `ui/*_test.go` behavior test and the ten host-font snapshot
  cases in `ui/workbench_snapshot_test.go`;
* the current GPUI sources, GPUI README/dogfood record, Rust unit tests, and
  `frontends/gpui/tests/foreign_smoke.rs`.

The Shirei baseline is strong. Gate A records passing edit-model, text-input,
text-layout, snapshot, selection, undo/redo, Unicode, bidi, IME, clipboard,
soft-wrap, and programmatic selection behavior. Gate B adds the scalable
ScratchEditor and a fixed-row Shirei view with local byte/rune mapping,
visible-row shaping, bidi hit testing, caret affinity, directional selection,
clipboard, preedit, and IME-anchor fixtures. Gates C–F add file lifecycle,
workspace/search/conflict/recovery behavior, Markdown projections and prose
presentation, Go/TypeScript/TSX projections, structural commands, and the Aero
Paper workbench.

The current GPUI baseline is intentionally much smaller. `frontends/gpui/src/main.rs`
renders a GPUI window with a `Tree`, `TabBar`, Save/Close buttons, and text
placeholder; `src/app.rs` stores a flat tree, status, active selection, and
bounded visible slice; and `src/protocol.rs` exposes only Snapshot, Ping,
OpenPath, SelectDocument, SaveDocument, CloseDocument, ListDirectory,
ReadVisibleLines, and ReplaceDocument. `src/editor.rs` contains a tested
frontend-local one-window optimistic edit session, but the executable does not
attach it to a text input view. The resource is bounded to 256 lines/64 KiB and
the session currently rejects truncated or invalid-UTF-8 windows.

The foreign test proves the following slice only: list a workspace, open files,
read a bounded resource, perform one optimistic replacement, acknowledge it,
reject a stale edit, save, close, and shut down. It does not prove interactive
window editing, IME, selection, scroll, shaping, projections, menus, or
settings.

## Shell and workspace ledger

| ID | Shirei-visible behavior | Current GPUI classification | Acceptance evidence to close |
|---|---|---|---|
| S-01 | Empty application starts with the paper-workstation shell. | **partial; can improve** — a native GPUI window starts, but it is generic chrome and has no Aero Paper document surface. | Native launch on macOS, Windows, and Linux; GPUI visual baseline for empty workspace; compare semantic regions with `ui/workbench_snapshot_test.go:TestSnapshotWorkstationEmpty`. |
| S-02 | Open one file without inventing a containing workspace; show a focused editor. | **partial; application-owned** — `OpenPath` and active identity work through the foreign smoke path, but GPUI renders a read-only placeholder and does not expose focused editing. | Open a file through a GPUI picker/CLI handoff, type, select, save, and reopen; preserve `HasWorkspace=false`; exercise `TestSnapshotWorkstationSingleFile`. |
| S-03 | Open a workspace and show a Files tree with directories/files. | **partial; application-owned** — initial `ListDirectory` populates a GPUI Kit `Tree`; listing is flat and only the initial directory is requested. | Workspace fixture with nested directories; expand/collapse and refresh must request only needed listings; equivalent of `TestSnapshotWorkstationFilesSidebar` and `TestExpandedTreeRowsStackVertically`. |
| S-04 | Tree rows have separate focus and selection, path identity, and a composite keyboard target. | **missing; frontend-local** — GPUI uses the component's `TreeState` selection but has no Scratchpad focused path, anchor/lead, or application-independent keyboard model. | GPUI interaction tests for focus versus selected paths, active row, path-keyed reconciliation, and focus transfer. |
| S-05 | Folder expand/collapse persists and children are reconciled after refresh. | **partial; application-owned** — `TreeItem` marks folders, but `main.rs` does not dispatch a child `ListDirectory` on expansion or persist expansion in `ShellModel`. | Expand nested folders, refresh, mutate disk, and assert expansion/path state survives; map to `TestFolderClickUsesPersistentWorkbenchTreeState`, `TestTreeMutationDefersRowIDInvalidationDuringRender`, and `TestWorkspaceRefreshPrunesDeletedTreeViewState`. |
| S-06 | Tree single selection, Ctrl multi-selection, Shift range selection, anchor/lead, and marquee selection. | **missing; frontend-local** — no GPUI Scratchpad selection policy exists. | Port behavior-level tests from `TestTreeSelectionClickUsesVisiblePathModel` and `TestSidebarBackgroundMarqueeSelectsVisibleRows`; no row handles may cross Caliber. |
| S-07 | Tree keyboard navigation: arrows, Home/End, PageUp/PageDown, type-ahead, Enter/Space activation. | **missing; frontend-local** — no action/key-context routing or Scratchpad composite tree focus exists. | GPUI synthetic interaction tests equivalent to all tests in `tree_navigation_test.go` and `TestTreeKeyboardMovesAndActivatesFocusedPath`; include Unicode names and wrapping type-ahead. |
| S-08 | F2 inline rename and Delete/trash confirmation. | **missing; application-owned** — the Go mutation commands exist, but no protocol command or GPUI input/modal surface exists. | Create/rename/trash through application paths, preserve dirty-tab policy, and test `TestTreeKeyboardF2StartsInlineRenameAndCommitPreservesTarget`. |
| S-09 | Create file/folder, rename, no-replace move, drag-to-directory move, and safe trash. | **missing; application-owned** — Milestone H is in Go; GPUI has no corresponding `BackendCommand`. | Add semantic command requests only after two concrete use cases; test file identity/rekeying, collision errors, dirty close, and drag behavior from `TestTreeDragSelectionMatchesSinglePathPayload`. |
| S-10 | Drag/drop workspace behavior and path containment. | **missing; application-owned** — no GPUI drop target or path handoff. | Native drag/drop tests on available platforms; verify application path validation and no traversal. |
| S-11 | Document tabs show order, active tab, dirty marker, conflict/error state, activate, close, close others, close all, and reopen closed. | **partial; application-owned** — current `TabBar` shows labels/dirty marker and activates a tab; Close button closes active document. There is no tab context menu, close confirmation, conflict indicator, close history, or bulk action. | GPUI interaction tests equivalent to `TestWorkstationTabsActivateAndCloseDocuments`, snapshot `workstation_multiple_tabs`, and application close/conflict tests; dirty close must not discard silently. |
| S-12 | Active document state is reconciled after open/select/save/close. | **working for the Gate 1–4 slice; application-owned** — `StateEnvelope` revision checks and foreign smoke cover open, active selection, save, close, and shutdown. | Keep `foreign_smoke.rs` green; add stale state/latest-wins tests while exercising the visible shell. |
| S-13 | Save current document, Save As, dirty status, ordinary failures, and committed durability warnings. | **partial; application-owned** — Save button and `SaveDocument` work; Save As, failure/warning notices, and a dirty-preserving modal do not exist. | Equivalent of `TestFileSaveCommandSurfacesOrdinaryFailure`, `TestFileSaveCommandSurfacesCommittedDurabilityWarning`, `TestSaveAsModalSurfacesOrdinaryFailure`, and `TestSaveAsModalSurfacesCommittedDurabilityWarning`; verify bytes, path identity, and dirty state. |
| S-14 | Dirty-close confirmation with Save/Discard/Cancel, including multiple tabs. | **missing; application-owned** — Close currently sends `discard=false` from a button, but no dialog or pending close model exists. | GPUI dialog interaction test and native smoke with dirty document; no data loss on window/tab close. |
| S-15 | External-change detection, conflict summary, reload/keep/compare decisions. | **missing; application-owned** — Go application has conflict state, but protocol and GPUI surface do not. | External edit while open; show conflict UI, preserve dirty bytes, block unsafe Save, and test recovery/compare behavior. |
| S-16 | Recovery/session restore after restart and raw-byte recovery presentation. | **missing; application-owned** — Go recovery is implemented; GPUI has no session/recovery command or surface. | Restart certification with dirty recovery fixture; include missing/corrupt recovery cases and raw-byte fidelity. |
| S-17 | Refresh workspace and reconcile deleted/moved paths without stale rows. | **missing; application-owned** — current GPUI lists once at startup and has no refresh command. | GPUI refresh action and path-keyed reconciliation equivalent to `TestWorkspaceRefreshPrunesDeletedTreeViewState` and `TestTreePathMutationRemapsViewState`. |
| S-18 | Quick Open fuzzy path picker, first/second-open focus reset, and file open. | **missing; frontend-local + application-owned** — GPUI has a text label saying “Command palette” but no picker or fuzzy filter. | GPUI picker tests equivalent to `TestFileOpenWithoutArgumentsOpensPicker`, `TestCtrlOInvokesFileOpenCommand`, and `TestOpenPickerCanTypeOnFirstAndSecondOpening`; application receives only chosen path. |
| S-19 | Open Recent list and recent-file persistence. | **missing; application-owned** — no protocol command or GPUI surface. | Reopen recent files across process restart; status for missing paths; native menu/command test. |
| S-20 | Copy absolute/relative path and reveal file/reveal active document. | **missing; application-owned** — Shirei tests prove clipboard path behavior, but GPUI has no clipboard/reveal command. | Equivalent of `TestWorkbenchCommandsCopyPaths`; native clipboard and reveal tests per platform. |
| S-21 | Native/application menus, tab/tree context menus, dismissal, and menu anchors. | **missing; frontend-local** — no GPUI menu/action map; only buttons and placeholder affordances. | GPUI menu/context-menu tests equivalent to `TestContextMenuPositionsAtPointerAndDismissesOutside`, `TestContextClickTreeAndTabs`, `TestWorkspaceContextMenuTargetsRoot`, `TestSidebarEmptyBackgroundOpensWorkspaceContextMenu`, and `TestShireiDropdownAnchorRepro`. |
| S-22 | Status rail: save/error/conflict/revision/workspace state and transient notices. | **partial; application-owned** — `StatusLine` displays the latest `Outcome` and revision, but has no durable error actions, conflict/recovery state, or structured status segments. | GPUI semantic status baselines equivalent to `TestSnapshotWorkstationStatusBar`; exercise failure, warning, conflict, and retry states. |

## Editor and input ledger

| ID | Shirei-visible behavior | Current GPUI classification | Acceptance evidence to close |
|---|---|---|---|
| E-01 | Interactive text editing with immediate local insertion/deletion. | **partial; frontend-local + application-owned** — `EditorSession` optimistically replaces one bounded valid-UTF-8 window and `foreign_smoke.rs` acknowledges it, but `ShellView` never attaches it to a GPUI input surface. | Type into the actual GPUI editor and observe local paint before Go acknowledgement; preserve one in-flight edit initially, then measure coalescing. |
| E-02 | Go remains authoritative for raw document bytes, revisions, dirty state, undo/domain semantics, and persistence. | **working as an architectural invariant; application-owned** — `docs/GPUI-DOGFOOD.md`, backend protocol, and stale-edit smoke preserve the split. | Every future editor test must assert no whole document crosses the boundary and stale acknowledgements cannot overwrite Go state. |
| E-03 | Caret movement, affinity, visual caret, blinking, and screen-space caret anchor. | **missing; frontend-local** — no caret in the rendered GPUI view; `EditorSession` only stores byte positions. | GPUI editor tests for logical/visual caret, bidi affinity, blink, focus, and IME anchor; use Shirei tests `TestCaretBlinkPhasesAndTransition`, `TestCaretBlinkEligibilityAndReset`, `TestCaretGeometryUsesTextHeightAndCentersInRow`, and `TestEditorCaretGeometryUsesShireiTextMetric` as behavior evidence. |
| E-04 | Mouse hit testing, single/word/line selection, drag selection, and selection painting. | **missing; frontend-local** — no mouse input/editor selection surface is rendered. | GPUI hit-test and drag tests; preserve behavior in `TestEditorMouseSelectionUsesWordAndLineGranularity`, `TestVisualLineHitTestMatchesShireiReference`, and selection fixtures in `editor_view_test.go`. |
| E-05 | Clipboard copy, cut, paste, select all, and native clipboard requests. | **missing; frontend-local** — no GPUI clipboard action or input handler. | GPUI native clipboard test plus Go raw-byte fixtures; preserve `docs/BEHAVIOR-PARITY.md` exact selection/text contract. |
| E-06 | Undo/redo, including selection/caret restoration and command grouping. | **missing; application-owned** — Go editor supports it, but the GPUI command surface does not dispatch it. | Reuse application/editor tests unchanged; add GPUI action tests for `edit.undo`, `edit.redo`, and one-undo-step Markdown commands. |
| E-07 | UTF-8, combining marks, emoji/ZWJ, bidi, grapheme/cluster movement and deletion. | **missing; frontend-local** — bounded display currently uses `String::from_utf8_lossy`; the editor session has no cluster mapping or shaping. | Unicode fixtures from `docs/BEHAVIOR-PARITY.md`, `TestLongLineChunksDoNotSplitCommonGraphemeBoundaries`, `TestVisualLineCaretAffinityRoundTrip`, and mixed-direction hit-test parity. |
| E-08 | IME preedit, marked text, selected clauses, commit/cancel, UTF-16 selection mapping, and candidate-window anchoring. | **missing; frontend-local; blocked** — no GPUI `InputHandler` integration; Gate 4 only accepts replacement bytes. | Native IME certification on macOS/Windows/Linux where available plus headless GPUI input tests; preserve raw-byte mapping and stale revision behavior. |
| E-09 | Line navigation, word navigation, Page/Home/End, vertical movement, and Ctrl/Alt chunk movement. | **missing; frontend-local** — no key handling in GPUI shell. | GPUI action/key-context tests equivalent to `keymap_test.go`, `word_navigation_test.go`, `TestEditorVerticalNavigationUsesVisibleRows`, and `TestEditorLineBoundaryNavigationExtendsSelection`. |
| E-10 | Enter/CRLF behavior, duplicate/move/join/indent/outdent/delete line commands. | **missing; application-owned** — command transformations exist in Go; no GPUI dispatch or visible editor. | Map stable IDs and preserve `TestEditableViewDispatchesCRLFEnterAndDuplicate` plus `commands/line_commands_test.go`. |
| E-11 | Fixed-row and visual-row viewport scrolling, wheel/keyboard scroll, reveal, and scroll preservation. | **missing; frontend-local** — current GPUI renders a plain text child without a scroll/viewport model; only a bounded read request exists. | GPUI viewport tests for latest-wins requests, reveal, wheel, keyboard, and resize; use `TestEditableViewScrollsVisibleRows`, `TestEditableViewScrolledClickUsesRenderedRowGeometry`, `TestEditableViewRevealsOffscreenLogicalLine`, and `TestFindRevealKeepsKeyboardFocusInFindField`. |
| E-12 | Bounded window synchronization, optimistic acknowledgement, stale rejection, rollback/re-fetch, and latest-wins viewport reads. | **partial; application-owned** — one in-flight edit and stale rejection are proven in Rust/foreign tests; rollback is session-local, but no UI reconciliation or viewport boundary fetch exists. | Add an interactive stale-edit test that fetches a fresh revisioned window and deterministically reconciles; test rapid read requests against `PendingCommands` coalescing. |
| E-13 | Source byte fidelity: invalid bytes, BOM, LF/CRLF, missing final newline, exact save. | **partial; application-owned; blocked** — Go path and SPVS payload preserve raw bytes, but `EditorSession` rejects non-UTF-8 and the rendered string is lossy. | GPUI must show an explicit replacement/byte-safe policy while retaining byte offsets; run raw-byte fixtures at 100 KiB/1 MiB/10 MiB and exact-save tests before claiming parity. |
| E-14 | Large-file bounded frame path: 100 KiB, 1 MiB, 10 MiB, long line, fragmented buffer, Unicode-heavy input. | **partial; can improve** — the protocol bounds each visible payload and foreign smoke measures it; no interactive GPUI editor or frame/RSS evidence exists. | Native/perf harness records cold start, first paint, local edit, ack, scroll, resize, RSS, and idle CPU separately for 100 KiB/1 MiB/10 MiB and long-line fixtures. |
| E-15 | Soft wrapping for plain text/Markdown, code unwrapped by default, variable row heights, visual-row movement, width-sensitive cache. | **missing; frontend-local; can improve** — Shirei has it; GPUI has no layout/shaping code. | GPUI shaping/visual-row tests equivalent to `TestWrappedVisualLineKeepsSourceByteMapping`, `TestWrappedVisualLineHitTestingUsesVerticalRow`, `TestVisualLineHeightMatchesPublicShireiMeasure`, `TestVisualLineCaretRowsMatchRenderedGlyphOrigins`, and `TestTableLinesOptOutOfSoftWrap`. |
| E-16 | Pathological long-line bounded chunks and grapheme-safe boundary expansion. | **missing; frontend-local; can improve** — `EditorSession` has no line/chunk model. | Preserve the 16 KiB/1 KiB boundary invariants from `docs/GATE-B-RESULTS.md`; measure first paint and near-end edit without document-sized allocations. |

## Markdown, language, and projection ledger

| ID | Shirei-visible behavior | Current GPUI classification | Acceptance evidence to close |
|---|---|---|---|
| P-01 | Markdown headings, hierarchy, semantic spacing, heading fragments, and source-visible inline emphasis. | **missing; application-owned** — Go Goldmark projections and Shirei presentation are complete for the recorded scope; GPUI protocol exposes no spans. | Add revision-tagged visible presentation spans/resources; visual/structural GPUI baselines for headings and inline styles; preserve `TestMarkdownHeadingSpanStyleAddsHierarchy` and `TestVisualLineCarriesResolvedPresentationStylesToLayout`. |
| P-02 | Markdown blockquotes, lists, tasks, thematic breaks, fenced-code surfaces, and source-visible tables. | **missing; application-owned** — no projection fields or paint layer in GPUI. | Port semantic projection tests and add GPUI structural visual cases; preserve `TestMarkdownTablePresentationUsesCodeFace`, `TestMarkdownTableLineDecorationStylesRows`, `TestMarkdownThematicBreakPresentationIsMuted`, and `TestMarkdownTableLayoutPolicyCoversHitTestingAndVerticalNavigation`. |
| P-03 | Outline sidebar with symbol labels, selection, navigation, and reveal. | **missing; application-owned** — Go outline projection exists; GPUI tree has no Outline mode or symbol resource. | GPUI outline list and reveal tests equivalent to `TestOutlineSymbolKindLabels`, `TestOutlinePanelRendersCodeSymbols`, and `TestOutlineNavigationQueuesNearTopReveal`. |
| P-04 | Folding and reveal around folded headings/regions. | **missing; application-owned** — no fold projection or frontend fold state. | Revision-tagged fold projection plus GPUI keyboard/mouse fold tests; preserve `TestRowMapForDocumentDoesNotFoldHeadingItself` and `TestExpandFoldsForRevealOpensOnlyContainingFold`. |
| P-05 | Markdown task toggling, table navigation/formatting, smart paste, links, and source-preserving authoring commands. | **missing; application-owned** — `commands` transformations exist, but no GPUI command map or editor. | Keep all Go command tests unchanged; add GPUI dispatch tests for `item.toggle`, table navigation, Markdown menu/slash surfaces, and one-undo-step outcomes (`markdown_presentation_test.go`). |
| P-06 | Local links, escaped paths, encoded percent, fragments, and Windows path recognition. | **missing; application-owned** — Go resolver is tested; GPUI has no link click/presentation. | GPUI link hit testing opens only validated application paths; preserve all tests in `link_test.go` and `root.go` fragment routing. |
| P-07 | Go syntax spans/highlights, folds, outline, and injected/fenced Go. | **missing; application-owned** — Gate E Go provider is complete in Go; no GPUI span protocol. | Consume bounded revision-tagged spans for visible lines; compare syntax colors/structure with Shirei snapshots and pending/stale projection tests. |
| P-08 | TypeScript and TSX spans/highlights/folds/outline. | **missing; application-owned** — Gate E provides the adapters; GPUI has no language projection fields. | Same visible-span contract for `.ts`/`.tsx`; preserve TypeScript/TSX application tests and stale result rejection. |
| P-09 | Unsupported languages remain editable plain text; JavaScript remains plain text by current product policy. | **partial; application-owned** — GPUI displays bounded bytes as plain text and `StateDocument.language`; no editor exists to demonstrate editability. | Interactive plain-text edit test for unknown/Rust/JavaScript files, with no Rust parser duplication. |
| P-10 | Revision-safe asynchronous projection updates never overwrite current text or layout. | **missing; application-owned** — Go rejects stale results, but GPUI cannot receive or render projections yet. | Revision-tagged projection resource tests and latest-wins model tests; no per-frame Caliber polling. |

## Search, commands, settings, and accessibility ledger

| ID | Shirei-visible behavior | Current GPUI classification | Acceptance evidence to close |
|---|---|---|---|
| Q-01 | Current-document find, next/previous, replace, selection reveal, cancellation. | **missing; application-owned** — Go search behavior exists; protocol has no search request/result stream. | Add application-owned search command/resource, GPUI input/result list, keyboard focus retention, cancellation, and tests equivalent to `TestWorkbenchCommandsGoToLineAndFindNavigation`, `TestCurrentFindMatchesCachesUnchangedDocumentQuery`, and `TestFindNavigationQueuesCenterReveal`. |
| Q-02 | Workspace search with asynchronous streamed results, cancellation, and result navigation. | **missing; application-owned** — no protocol command or list view. | Stream bounded result records; test cancellation and large workspace result virtualization. |
| Q-03 | Go To Line with `line[:column]`, clamping, reveal, and editor focus. | **missing; application-owned** — application command exists; no GPUI field/action. | GPUI modal/input test equivalent to `TestWorkbenchCommandsGoToLineAndFindNavigation` and `TestGoToLineQueuesCenterReveal`. |
| Q-04 | Stable Scratchpad command IDs, platform bindings, context predicates, and command palette discovery. | **missing; application-owned + frontend-local** — GPUI scheduler invents a Rust `BackendCommand` enum for the Gate 1 protocol and does not map `commands.InitialVocabulary`; command palette is a placeholder string. | One GPUI action per stable product ID, with key contexts and platform bindings; command palette lists enabled descriptors from Go vocabulary without sending raw keypresses through Caliber. |
| Q-05 | File/application command IDs: `file.open`, `file.save`, `file.save-as`, `document.find`, `document.find-replace`, `file.quick-open`, `workspace.search`, `document.close`, `document.activate`, `document.close-others`, `document.close-all`, `document.reopen-closed`, `document.go-to-line`, `document.find-next`, `document.find-previous`, `tab.next`, `tab.previous`, `file.open-recent`, `file.copy-path`, `file.copy-relative-path`, `file.reveal`, `file.reveal-active`. | **partial; application-owned** — only OpenPath/SelectDocument/SaveDocument/CloseDocument are represented by the current protocol, and only a few are available as buttons/tree/tab clicks. All other product IDs are absent from the GPUI action map. | Protocol requests and GPUI actions must preserve IDs, context enablement, dirty/conflict policy, and tests in `workbench_test.go`; add command palette/native menu coverage. |
| Q-06 | View/workspace IDs: `view.toggle-sidebar`, `settings.open`, `view.increase-font-size`, `view.decrease-font-size`, `view.reset-font-size`, `workspace.refresh`, `workspace.focus-files`, `workspace.toggle-folder`, `workspace.new-file`, `workspace.new-folder`, `workspace.rename`, `workspace.move`, `workspace.trash`, `outline.toggle`. | **partial; frontend-local + application-owned** — `settings_open` is a boolean placeholder and the tree is initially listed; all actual toggles, font changes, focus commands, outline, refresh, and mutations are absent. | GPUI action/context tests equivalent to `font_zoom_test.go`, `settings_test.go`, tree tests, and outline tests; persistent settings remain Go/application-owned. |
| Q-07 | Editing IDs: `item.toggle`, `selection.expand`, `comment.toggle`, `document.format`, `edit.undo`, `edit.redo`, `edit.cut`, `edit.copy`, `edit.paste`, `edit.select-all`, `edit.indent-lines`, `edit.outdent-lines`, `edit.delete-line`, `edit.insert-line-above`, `edit.insert-line-below`, `edit.move-line-up`, `edit.move-line-down`, `edit.duplicate-line`, `edit.join-lines`. | **missing; application-owned** — no GPUI text input or action dispatch. `EditorSession` replacement is not a substitute for the product vocabulary. | GPUI action tests call the existing semantic command IDs; Go transformation tests stay unchanged; key contexts decide local focus movement versus application edits. |
| Q-08 | Markdown IDs: `markdown.toggle-strong`, `markdown.toggle-emphasis`, `markdown.toggle-strike`, `markdown.toggle-inline-code`, `markdown.insert-link`, `markdown.heading-1`, `markdown.heading-2`, `markdown.heading-3`, `markdown.toggle-bulleted-list`, `markdown.toggle-numbered-list`, `markdown.toggle-quote`, `markdown.insert-task`, `markdown.insert-code-block`, `markdown.set-fence-language`, `markdown.insert-table`, `markdown.table-next`, `markdown.table-previous`, `markdown.table-enter`, `markdown.insert-divider`, `markdown.smart-paste`. | **missing; application-owned** — no Markdown command context, menu, slash picker, toolbar, or editor dispatch exists. | GPUI menu/picker/input tests reuse `commands.Registry` and preserve all `markdown_presentation_test.go` outcomes. |
| Q-09 | Persistent editor font size, increase/decrease/reset, settings surface, immediate apply, and persistence. | **missing; application-owned** — GPUI settings is a placeholder; no font state or persistence. | Port behavior from `font_zoom_test.go` and `settings_test.go`; compare immediately rendered font metrics and persisted reload. |
| Q-10 | Theme selection, light/dark semantic palettes, user theme inheritance, syntax colors. | **missing; frontend-local for rendering, application-owned for persistent product settings** — GPUI uses no Scratchpad theme model. | GPUI theme model must preserve paper/chrome/selection/focus roles and pass semantic tests equivalent to `theme_test.go`; user theme persistence remains product settings. |
| Q-11 | Aero Paper visual language: warm paper, cool machinery, subdued selection/focus, shallow depth, compact controls, dense/breathable shell. | **missing; can improve** — current GPUI default components are functional but visually generic. | GPUI-native semantic visual baselines for all ten Shirei snapshot scenarios; acceptance is structural/state parity, not pixel identity. |
| Q-12 | Accessibility semantics for tree, tabs, commands, dialogs, editor, search, outline, settings. | **blocked; can improve** — current GPUI implementation has no Scratchpad accessibility audit or semantic annotations recorded. | Inspect GPUI/GPUI Kit accessibility surface; add role/name/focus/selection semantics and document framework gaps honestly on macOS, Windows, and Linux. |

## Visual snapshot ledger

The existing Shirei snapshots are semantic scenarios, not pixel requirements.
Each must have a GPUI-native baseline with equivalent product state. The GPUI
baseline should record focused/selected/dirty/conflict/visible modes and use
structural assertions where host font rasterization differs.

| Snapshot in `ui/workbench_snapshot_test.go` | Current GPUI classification | Required GPUI acceptance |
|---|---|---|
| `workstation_empty` | **missing; can improve** | Empty window, paper/editor region, chrome, status rail, initial focus. |
| `workstation_single_file` | **partial** | Single-file presentation with editable document and no invented workspace. |
| `workstation_markdown` | **missing; application-owned** | Markdown projection, soft wrap, task/heading styling, Files sidebar. |
| `workstation_selected_tree` | **partial** | Selected/focused tree row, active file, editor content, path identity. |
| `workstation_multiple_tabs` | **partial** | Multiple tab order, active tab, dirty markers, close affordances. |
| `workstation_files_sidebar` | **partial** | Expanded virtualized Files tree, keyboard focus, selection, refresh. |
| `workstation_outline_sidebar` | **missing; application-owned** | Outline symbols, selection/navigation/reveal, sidebar mode switch. |
| `workstation_status_bar` | **partial** | Structured status/error/revision/save state rather than one placeholder string. |
| `workstation_popup` | **missing; frontend-local** | Context menu/popup anchor, keyboard focus, dismissal, command dispatch. |
| `workstation_dialog` | **missing; frontend-local + application-owned** | Save As/dirty-close/conflict dialog with native text input and action semantics. |

## Shirei behavior-test inventory

This inventory makes the audit scope explicit. The named tests are the
behavioral evidence used by the ledger above; application/domain tests remain
the source of truth for application-owned rows, while GPUI gets interaction
tests for frontend-owned rows.

| File | Tests covered by the audit |
|---|---|
| `ui/caret_blink_test.go` | `TestCaretBlinkPhasesAndTransition`; `TestCaretBlinkEligibilityAndReset`; `TestCaretGeometryUsesTextHeightAndCentersInRow`; `TestEditorCaretGeometryUsesShireiTextMetric` |
| `ui/context_click_test.go` | `TestContextClickTreeAndTabs` |
| `ui/editor_style_test.go` | `TestEditorTextStyleLanguagePolicy`; `TestEditorTextStyleKeepsProseDefault`; `TestUnknownTextualDocumentUsesCodeSurface`; `TestCodeFontFamilyPolicyIsCopied`; `TestCodeStyleShapesRepresentativeUnicode` |
| `ui/editor_view_test.go` | `TestVisualLineKeepsDocumentMappingLocal`; `TestVisualLinePreservesInvalidBytesWithExplicitMapping`; `TestDisplayTextExpandsTabsToNextStop`; `TestVisualLineTabMappingKeepsCaretAndHitTestGeometry`; `TestVisualLineBoundsPathologicalLineShaping`; `TestLongLineUsesDeterministicBoundedChunks`; `TestLongLineChunkNavigationTraversesWholeLine`; `TestLongLineChunksDoNotSplitCommonGraphemeBoundaries`; `TestWrappedVisualLineKeepsSourceByteMapping`; `TestWrappedVisualLineHitTestingUsesVerticalRow`; `TestWrappedVisualLineHitTestUsesShireiBlockOrigin`; `TestVisualLineAtYUsesConfiguredHeightForBlankRows`; `TestEditorVerticalNavigationUsesWrappedRows`; `TestVisualLineHitTestMatchesShireiReference`; `TestVisualLineCaretAffinityRoundTrip`; `TestEditableViewPublishesKeyboardAndIMEGeometry`; `TestEditableViewScrollsVisibleRows`; `TestEditableViewScrolledClickUsesRenderedRowGeometry`; `TestEditorMouseSelectionUsesWordAndLineGranularity`; `TestEditableViewTextParityWithTextArea`; `TestEditorLineBoundaryNavigationExtendsSelection`; `TestEditorVerticalNavigationUsesVisibleRows`; `TestEditableViewDispatchesLineNavigationKeys`; `TestEditableViewDispatchesCRLFEnterAndDuplicate`; `TestVisualLineCacheRebuildsWhenPresentationArrivesAtSameRevision`; `TestDocumentPresentationKeySeparatesPendingFromPublished`; `TestCachedVisualLineStyleComparisonPreservesStyleSemantics`; `TestVisualLineCacheRebasesUnaffectedRowsAcrossEdit`; `TestVisualLineCacheRebasesLineKeysAfterNewlineEdit`; `TestVisualLineCacheClearsWhenEditHistoryUnavailable`; `TestAnchorForLineKeepsNonCaretRowsCacheable`; `TestCachedVisualLineReplacementKeepsLRUEntry`; `BenchmarkCachedVisualLineHit`; `BenchmarkWrappedVisualLine`; `TestTableLinesOptOutOfSoftWrap`; `TestOverflowLaneHelpers`; `TestCurrentEditorLineBackground`; `TestMarkdownTableLayoutPolicyCoversHitTestingAndVerticalNavigation` |
| `ui/folder_picker_test.go` | `TestFolderPickerNavigatesDirectoriesBeforeChoosing`; `TestFolderPickerClickNavigatesWithoutClosing` |
| `ui/font_zoom_test.go` | `TestEditorFontZoomDefaultsAndBounds`; `TestEditorFontZoomCommandsAndMetrics`; `TestEditorFontZoomCommandsUpdateState`; `TestEditorFontZoomClearsPreferredVerticalPosition`; `TestEditorFontZoomClearsPreferredVerticalPositionForAllOpenDocuments`; `TestEditorFontZoomRebuildsCachedLayout` |
| `ui/keymap_test.go` | `TestWindowsEditorKeyBindings`; `TestEditorViewDispatchesWindowsDocumentAndPageKeys`; `TestViewKeymapStateTogglesWithoutChangingOverflowPolicy`; `TestFindReplaceEditsCurrentAndAllMatches` |
| `ui/link_test.go` | `TestResolveLocalLinkPathDecodesEscapedPath`; `TestResolveLocalLinkPathPreservesEncodedPercent`; `TestResolveLocalLinkPathRecognizesWindowsPaths` |
| `ui/markdown_presentation_test.go` | `TestMarkdownPresentationStyleMapsSemanticKinds`; `TestMarkdownTablePresentationUsesCodeFace`; `TestMarkdownTableLineDecorationStylesRows`; `TestFormatTableAtCursorIsOneUndoableEdit`; `TestMarkdownCommandUsesOneUndoableEdit`; `TestMarkdownCommandsUndoRedoPreservesCommandSelections`; `TestTableNavigationFormatsAndMovesAcrossCells`; `TestTableCommandsUseCurrentSourceWhenProjectionIsStale`; `TestTableNavigationRefusesOverlongBodyRows`; `TestTableNavigationDoesNotStealKeysFromTransientInputs`; `TestToggleTaskAtCursorMatchesOutlineSemantics`; `TestMarkdownThematicBreakPresentationIsMuted`; `TestSyntaxPresentationStyleUsesVisibleHSLAColors`; `TestCodeSyntaxPresentationDoesNotChangeFontMetrics`; `TestMarkdownHeadingSpanStyleAddsHierarchy`; `TestVisualLineCarriesResolvedPresentationStylesToLayout`; `TestPresentationTextSpansClipToVisibleSourceWindow`; `TestPresentationTextSpansIgnoreEmptyStyles` |
| `ui/material_test.go` | `TestRaisedFrameUsesSoftContourAndGradient`; `TestInsetFrameUsesSoftContourAndGradient`; `TestThemeSeparatesMachineryFromPaper`; `TestWorkstationSegmentedControlSwitchesSelection`; `TestWorkstationButtonClickBehavior`; `TestWorkstationTabsActivateAndCloseDocuments` |
| `ui/menu_repro_test.go` | `TestShireiDropdownAnchorRepro` |
| `ui/outline_test.go` | `TestOutlineSymbolKindLabels`; `TestOutlinePanelRendersCodeSymbols` |
| `ui/prose_render_geometry_test.go` | `TestVisualLineHeightMatchesPublicShireiMeasure`; `TestMarkdownSpanHeightMatchesPublicShireiMeasure`; `TestVisualLineCaretRowsMatchRenderedGlyphOrigins`; `TestBlankVisualLineUsesConfiguredFallbackWhenShireiHasNoTextBounds`; `TestWrappedBoundaryKeepsTrailingCaretOnPreviousRow` |
| `ui/reveal_mapping_test.go` | `TestRevealMappingUsesCompactVisibleIndices`; `TestRevealMappingKeepsByteRangeOnLogicalLine`; `TestRowMapForDocumentDoesNotFoldHeadingItself`; `TestExpandFoldsForRevealOpensOnlyContainingFold`; `TestNavigateToSelectionQueuesCurrentRevisionReveal`; `TestOutlineNavigationQueuesNearTopReveal`; `TestFindRevealKeepsKeyboardFocusInFindField`; `TestEditableViewRevealsOffscreenLogicalLine`; `TestEditableViewRevealsHorizontalOverflowWithoutEditorFocus`; `TestFindNavigationQueuesCenterReveal`; `TestGoToLineQueuesCenterReveal` |
| `ui/settings_test.go` | `TestLoadUserSettingsMissingUsesDefaults`; `TestLoadUserSettingsMalformedUsesDefaults`; `TestUserSettingsPersistAndReload`; `TestThemeSelectionPersistsAndBumpsGeneration`; `TestPrimaryCommaOpensSettingsWithoutDocument`; `TestSettingsSurfaceRendersInEditorRegion`; `TestSettingsChangesApplyImmediatelyAndPersist` |
| `ui/theme_test.go` | `TestBuiltInThemesHaveDistinctSemanticPalettes`; `TestConfigureActiveThemeRefreshesFrameworkSelection`; `TestThemeReachesEditorAndPresentationStyles`; `TestResolveThemeSpecInheritsAndOverrides`; `TestResolveThemeSpecRejectsInvalidInput`; `TestParseThemeHex`; `TestParseThemeSpec` |
| `ui/tree_navigation_test.go` | `TestTreeNavigationVisiblePathMovement`; `TestTreeNavigationHierarchyAndHomeEnd`; `TestTreeNavigationRangeEndpoints`; `TestTreeNavigationTypeAheadMatchesUnicodeNamesAndWraps`; `TestNewTreeNavigationSnapshotsVisiblePaths` |
| `ui/tree_test.go` | `TestExpandedTreeRowsStackVertically`; `TestTreeMutationDefersRowIDInvalidationDuringRender`; `TestTreeSelectionClickUsesVisiblePathModel`; `TestTreePathMutationRemapsViewState`; `TestWorkspaceRefreshPrunesDeletedTreeViewState`; `TestTreeDragSelectionMatchesSinglePathPayload`; `TestTreeKeyboardMovesAndActivatesFocusedPath`; `TestTreeKeyboardF2StartsInlineRenameAndCommitPreservesTarget`; `TestTreeMarqueeRectAndIntersection`; `TestWorkspaceContextMenuTargetsRoot`; `TestSidebarEmptyBackgroundOpensWorkspaceContextMenu`; `TestSidebarBackgroundMarqueeSelectsVisibleRows` |
| `ui/word_navigation_test.go` | `TestEditableViewDispatchesWindowsWordNavigation`; `TestEditableViewKeepsCtrlAltChunkNavigation` |
| `ui/workbench_test.go` | `TestWorkbenchCommandsCopyPaths`; `TestFileOpenWithoutArgumentsOpensPicker`; `TestFileSaveCommandSurfacesOrdinaryFailure`; `TestFileSaveCommandSurfacesCommittedDurabilityWarning`; `TestSaveAsModalSurfacesOrdinaryFailure`; `TestSaveAsModalSurfacesCommittedDurabilityWarning`; `TestCtrlOInvokesFileOpenCommand`; `TestFolderClickUsesPersistentWorkbenchTreeState`; `TestOpenPickerCanTypeOnFirstAndSecondOpening`; `TestWorkbenchCommandsGoToLineAndFindNavigation`; `TestCurrentFindMatchesCachesUnchangedDocumentQuery`; `TestContextMenuPositionsAtPointerAndDismissesOutside` |
| `ui/workbench_snapshot_test.go` | `TestSnapshotWorkstationEmpty`; `TestSnapshotWorkstationSingleFile`; `TestSnapshotWorkstationMarkdown`; `TestSnapshotWorkstationSelectedTree`; `TestSnapshotWorkstationMultipleTabs`; `TestSnapshotWorkstationFilesSidebar`; `TestSnapshotWorkstationOutlineSidebar`; `TestSnapshotWorkstationStatusBar`; `TestSnapshotWorkstationPopup`; `TestSnapshotWorkstationDialog` |

`ui/editor_view_test.go` also contains the two editor benchmarks listed above;
they are performance evidence rather than user-visible acceptance tests. The
snapshot tests are opt-in host-font baselines (`SCRATCHPAD_VISUAL_SNAPSHOTS=1`)
and should be recreated as GPUI-native semantic/visual cases rather than
pixel-copied.

## Replacement gate

The current ledger has no basis for making GPUI the default. The minimum
replacement gate is:

1. Shell rows S-01 through S-22 have no unexplained missing or partial item;
2. editor rows E-01 through E-16 demonstrate actual interactive typing,
   selection, clipboard, IME, scrolling, shaping, stale reconciliation, and
   byte-preserving saves;
3. projection rows P-01 through P-10 consume Go-owned revision-tagged data and
   do not run a parser in Rust;
4. search/command/settings rows Q-01 through Q-12 preserve
   `commands.InitialVocabulary`, persistent settings, native focus, and
   accessibility semantics;
5. every snapshot scenario has a GPUI-native baseline, and native startup,
   RSS, first-paint, edit, scroll, resize, and idle measurements are recorded
   separately from Caliber/Go latency;
6. Shirei remains buildable and all existing application tests remain green.

Rows marked **blocked** are release evidence gaps rather than permission to
silently downgrade the behavior. When the parity implementation is complete,
write `docs/GPUI-MIGRATION-RESULTS.md` with the remaining accepted Shirei-only
capabilities and exactly one of `KEEP SHIREI DEFAULT`, `MAKE GPUI DEFAULT`, or
`ABANDON GPUI`.
