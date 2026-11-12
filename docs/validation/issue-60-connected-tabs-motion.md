# Scratchpad #60: Connected tabs and command-palette motion

## Current implementation

Tab selection is immediate and deliberately has no selection-indicator animation. Clicking the already-visible active document tab is a no-op. Clicking that same document tab while Search, History, Diff, or a single-pane Pinned view is displayed still returns to the document.

The motion dogfood is live tab reordering. During a drag, Alicorn's bounded inert preview follows the pointer directly and Scratchpad retargets neighboring tab roots toward the proposed insertion slots with the active theme's `Settle` response. The authoritative tab order changes only on drop. Escape/capture cancellation, drop, and a new drag after an interrupted gesture snap all previously displaced tab roots back to their current logical slots. The gesture remembers that cleanup is needed even when the pointer returns to a zero-offset slot before release.

The command palette opts one narrow decorative accent into a birth `Reveal`. Its panel, query, focus, and accessible controls remain immediately available. A motion-policy change during that reveal re-declares the existing target with `Settle`; it does not replay the hidden/offset birth pose. Closing the palette cancels a pending reveal and does not create an exit ghost.

Both features use Alicorn's motion scheduler and the current workbench theme/accessibility policy. Scratchpad owns no animation clock, frame timer, or per-frame interpolation. Motion-only presentation keeps logical tab geometry, close hit targets, focus, accessibility semantics, and native caption regions unchanged.

The Scratchpad lockfile pins Alicorn `655c0f07dc73b3e22da184ea78e479acd0b0758f`. The development driver resolves the extracted `accesskit` and `accesskit_c` Odin collections from that pin.

## Automated validation on Windows

The `tools/alicorn.ps1 test -Odin C:\odin\odin.exe` suite passed on the checkout containing these changes: Go packages, 13 bridge/lifecycle tests, and 247 frontend tests.

| Acceptance case | Evidence |
| --- | --- |
| A → B → C tab selection | Automated test verifies immediate selected semantics and unchanged native caption geometry. |
| Clicking the selected tab | A pointer Down/Up test verifies no deferred selection command or backend revision change when its document is already displayed. Predicate cases verify that Search, History, and single-pane Pinned still return to that document. |
| Rapid reorder reversal | Motion diagnostics sample the same neighbor before and after retargeting; normal `Settle` preserves presented position and velocity. The repeated target produces no additional declaration. |
| Return to original slot, then cancel | The test returns a previously displaced neighbor to a zero target, confirms gesture cleanup remains armed, and verifies cancellation queues snap cleanup with no residual motion or document-order change. |
| Drop and cancellation | Automated tests verify committed order on drop and immediate reset of presentation-only offsets on drop/cancel. |
| Reduce Motion during reorder | Changing the effective preference re-applies the unchanged target and snaps motion; a reduced-motion retarget is required to land at its target without residual velocity. |
| Palette entrance and policy change | Tests verify one initial `Reveal`, focus availability, policy reapplication during the reveal, no replay of `Reveal`, and zero active motion after snapping/settlement. |
| Hit geometry, semantics, focus, caption regions | Existing drag-motion assertions compare logical bounds, tab semantics, both focus states, and native caption regions while the preview and neighbors move. |
| Idle after settlement | Existing tests rebuild after motion settles and verify no new declarations or active owners. |

The native recordings below predate the lifecycle/policy refinements in this record. They document the earlier decorative-selection demo and live-reorder appearance; they are not physical acceptance evidence for this exact source revision. No new Windows or macOS recording was captured for the changes above.

## Earlier native demonstrations

[Earlier 14-second Windows recording](issue-60-connected-tabs-motion-windows.mp4) (H.264, 1024×672, 30 fps) shows document selection and command-palette opening. Selection used keyboard navigation; its indicator motion has since been removed.

[Earlier 7-second live-reorder recording](issue-60-live-reorder-windows.mp4) (H.264, 1216×798, 15 fps) shows a tab dragged across its neighbor. It predates the latest interruption and dynamic Reduce Motion regressions.

The recordings were made on Windows 10 Home build 19045 with SDL 3.4.2 and the D3D12 renderer, using a neutral Public Documents workspace. They are visual examples, not frame-time benchmarks.

## Authoring complexity

The original selection-indicator and palette dogfood changes added 88 lines and removed 2 across the tab layout, palette, and app state. The live-reorder integration added 180 lines across tab layout, drag handling, and app state; its original focused regression added 207 lines. The current refinement adds gesture-lifetime cleanup, a policy signature shared by reorder and palette declarations, and deterministic tests that inspect sampled motion position and velocity. It does not add an application animation loop.

A manual-animation twin was not implemented, so no manual LOC ratio is claimed. The existing source comparison remains architectural: a manual implementation would need app-owned timing, per-tab interpolation, interruption/retargeting, reduced-motion handling, and drag-lifecycle cleanup. Alicorn owns those responsibilities; Scratchpad declares targets when the insertion slot or effective policy changes.

## Maintainer acceptance still needed

Run the exact current candidate natively on Windows and macOS before closing #60. Capture rapid mouse selection and drag reversal, Escape cancellation while neighbors are displaced, live Reduce Motion changes, horizontal overflow/auto-scroll, narrow-window targeting, dirty-tab interaction, minimize/restore, and tab tear-off. Verify the palette remains usable when Reduce Motion changes during its entrance. Record OS, renderer, Scratchpad commit, and the capture path.

The headless suite proves the retained state and transaction boundaries; it does not substitute for native pointer feel, OS preference delivery, or a current-candidate recording.
