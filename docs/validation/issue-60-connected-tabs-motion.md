# Scratchpad #60: Connected tabs and command-palette motion

## Implementation

Scratchpad dogfoods Alicorn's `ui.motion` API in two places:

- The compact connected document tab bar animates only its decorative selected indicator. Initial state snaps to the correct tab. Selection changes settle the outgoing and incoming indicators by durable tab identity. Selection semantics and tab/close hit geometry remain immediate.
- Opening the command palette opts one narrow accent surface into a birth `Reveal`. The panel, query field, keyboard focus, and accessible content are present immediately. Closing the palette cancels a pending reveal and creates no exit ghost.

Both behaviors use the active style environment's motion policy, including reduced motion. Scratchpad does not keep an animation timer, clock, or per-frame animation state; Alicorn owns interpolation and scheduling.

The browser-style reorder follow-up adds an opt-in full-tab drag preview and live neighbor displacement. Alicorn lifts a bounded inert paint snapshot of the source tab and follows the pointer directly. Scratchpad computes a proposed slot order only when the drag target changes and retargets neighboring tab roots with `ui.motion`'s theme `Settle` response. It commits document order only on drop; cancellation returns neighbors to the unchanged order. The original tab remains the sole semantic control, and visual translations leave layout, close hit targets, focus, accessibility bounds, and native caption regions at their logical positions.

The Scratchpad lockfile pins Alicorn `06daa41350472aba20bd68c6d3cb51e8e30592fa`. The development driver resolves the extracted `accesskit` and `accesskit_c` Odin collections from that pin so its normal check, test, build, run, and package commands continue to work.

## Validation

| Acceptance case | Result |
| --- | --- |
| Rapid A → B → C selection | Automated test verifies immediate selected semantics while only the outgoing/incoming decorations animate. |
| Select the current tab again | Automated test verifies no additional motion declaration. |
| Tab close targets and native caption regions | Automated test compares all tab/close hit bounds and caption-region identities/bounds before and after transitions. |
| Focus and accessibility | Automated test verifies keyboard and semantic keyboard focus are unchanged by decoration motion, and that exactly one tab is selected at every transition. |
| Palette entrance | Native demo opens the palette; automated test verifies the query remains focused while only the accent surface reveals. |
| Reduced motion | Tested with Scratchpad's app-level Reduce Motion override. Automated tests verify tab and palette decorations snap to their final state. |
| Minimize and restore | Manually exercised on the native window; the selected document remained selected after restore. |
| No work after settlement | Automated tests advance motion to completion, then rebuild descriptions and assert no new declarations or active owners. |
| Live tab reorder and pointer following | Native demo drags `.gitattributes` across `go.mod`; the dropped order changes after release. Runtime tests verify the lifted preview follows exact pointer deltas and only finalizes its bounded display commands. |
| Rapid insertion-slot reversal | Scratchpad test retargets neighboring tabs across two proposals, repeats one proposal as a no-op, and checks the authoritative document order is unchanged before drop. |
| Drop and cancellation | Scratchpad tests verify a drop commits the proposed order and snaps to the new logical geometry; cancellation clears drag state and leaves authoritative order unchanged. |
| Hit geometry, semantics, focus, and caption regions during drag motion | Automated test compares tab and close hit bounds, semantic role/label/selection/order/bounds, both focus states, and native caption-region geometry while neighbors move. |
| Reduced motion | Both normal and reduced-motion reorder configurations are covered; reduced motion has no active motion owners. |

The headless motion tests run in both normal and reduced-motion configurations. The complete `tools/alicorn.ps1 test` suite passed on this machine: Go packages, 13 bridge/lifecycle tests, and 204 frontend tests.

### Native demonstration

[Watch the 14-second Windows recording](issue-60-connected-tabs-motion-windows.mp4) (H.264, 1024×672, 30 fps).

[Watch the 7-second live-reorder recording](issue-60-live-reorder-windows.mp4) (H.264, 1216×798, 15 fps). It captures the native Scratchpad window and shows a document tab moved across its neighbor.

Recorded on Windows 10 Home build 19045 with SDL 3.4.2 and the D3D12 renderer. The demo uses a neutral Public Documents workspace. It shows three documents selected in sequence and the command palette opening. Keyboard navigation (`Ctrl+Tab`) was used for repeatable capture; the acceptance tests cover the same selection state transitions. This recording demonstrates the native result; it is not a frame-time benchmark.

## Authoring complexity

The original decorative motion authoring changes add 88 lines and remove 2 lines across the connected tab layout, palette, and app state. The live-reorder application integration adds 180 lines across tab layout, drag handling, and six app state fields (177 net after three removals); its focused regression test adds 207 lines. The existing `ui.motion` API owns interpolation, retargeting, reduced-motion behavior, and wake scheduling. Scratchpad contributes proposed-order calculation and a signature that prevents redeclaring motion while the insertion target is unchanged. There is no application-owned animation clock, frame timer, or per-frame interpolation loop.

A manual-animation twin was not implemented, so a manual LOC ratio is not claimed. Compared with the measured implementation above, a manual version would need app-owned timing and frame scheduling, per-tab interpolation state, interruption/retargeting for rapid reversals, reduced-motion snapping, and cleanup on drop or cancellation. Those responsibilities are covered by the motion API; Scratchpad only declares each changed slot target and its `Settle` policy.

## Maintainer follow-up

Please test the native drag edge cases that are not covered by this recording: Escape cancellation while neighbors are moving, reorder through horizontal overflow/auto-scroll, narrow-window drag targeting, closing or dirty tabs during a drag, and tab tear-off after dragging outside the window. Existing drag and titlebar suites cover their underlying generic contracts, but those combined Scratchpad interactions have not all been exercised manually here. For the selection indicator, fast A → B → C mouse selection and clicking the already-selected tab remain useful feel checks; the original recording uses keyboard navigation for deterministic capture.
