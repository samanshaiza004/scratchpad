# Scratchpad #60: Connected tabs and command-palette motion

## Implementation

Scratchpad dogfoods Alicorn's `ui.motion` API in two places:

- The compact connected document tab bar animates only its decorative selected indicator. Initial state snaps to the correct tab. Selection changes settle the outgoing and incoming indicators by durable tab identity. Selection semantics and tab/close hit geometry remain immediate.
- Opening the command palette opts one narrow accent surface into a birth `Reveal`. The panel, query field, keyboard focus, and accessible content are present immediately. Closing the palette cancels a pending reveal and creates no exit ghost.

Both behaviors use the active style environment's motion policy, including reduced motion. Scratchpad does not keep an animation timer, clock, or per-frame animation state; Alicorn owns interpolation and scheduling.

The Scratchpad lockfile now pins Alicorn `54aec2cf22e1fccf8de2d63cec347b1f57aa02ad`. The development driver resolves the extracted `accesskit` and `accesskit_c` Odin collections from that pin so its normal check, test, build, run, and package commands continue to work.

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

The headless motion tests run in both normal and reduced-motion configurations. The complete `tools/alicorn.ps1 test` suite passed on this machine: Go packages, 13 bridge/lifecycle tests, and 202 frontend tests.

### Native demonstration

[Watch the 14-second Windows recording](issue-60-connected-tabs-motion-windows.mp4) (H.264, 1024×672, 30 fps).

Recorded on Windows 10 Home build 19045 with SDL 3.4.2 and the D3D12 renderer. The demo uses a neutral Public Documents workspace. It shows three documents selected in sequence and the command palette opening. Keyboard navigation (`Ctrl+Tab`) was used for repeatable capture; the acceptance tests cover the same selection state transitions. This recording demonstrates the native result; it is not a frame-time benchmark.

## Authoring complexity

The production motion authoring changes add 88 lines and remove 2 lines across the connected tab layout, palette, and app state. They contain five `ui.motion` call sites: initial snap, outgoing/incoming tab targets, deselection, and palette reveal. The implementation has no application-owned frame timer or interpolation loop. The tests add 264 lines of focused coverage; dependency collection resolution for the extracted AccessKit package is a separate build-driver prerequisite and is excluded from this motion count.

A manual animation would need application-owned timing and interpolation, active-frame scheduling, interruption/retargeting rules for A → B → C, reduced-motion snapping, and lifecycle handling around palette close and window minimize/restore. Alicorn's motion API owns those mechanics, leaving Scratchpad to declare the target and transition policy. No manual-animation twin was implemented, so a manual LOC comparison is not claimed.

## Maintainer follow-up

Please judge the indicator's feel with mouse selection in a normal run, including fast A → B → C clicks and clicking the already-selected tab. The recording uses keyboard navigation for deterministic capture; the implementation and automated checks preserve mouse hit geometry.