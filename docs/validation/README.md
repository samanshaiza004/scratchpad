# Validation records

Each item records a bounded run, platform check, or manual acceptance matrix. Results apply to the commit, operating system, hardware, and scenario named by that record. A successful native startup smoke does not imply full physical-input or visual certification.

- [Semantic zoom and folding](semantic-zoom.md) — deterministic scenarios and platform interaction matrix; includes the large-document construction measurement.
- [Scratchpad #17 Windows release acceptance](issue-17-windows-2026-11-10.md) — latest Alicorn pin, Windows test/smoke/package evidence, synchronous and worker timings, cancellation and Go heap samples; physical acceptance remains open.
- [Scratchpad #17 macOS worker validation](issue-17-macos-2026-11-11.md) — latest-main Go/bridge/frontend tests, optimized native build, three repeated million-line worker samples, cancellation, and diagnostic-process peak RSS; native interactive and package acceptance remain open.
- [Connected-tab motion](issue-60-connected-tabs-motion.md) — Windows interaction and retained-motion observations; accompanying `.mp4` files are captures.
- [Live tab reordering](issue-60-live-reorder-windows.mp4) — Windows motion capture.
- [Live-theme dogfood](issue-166-scratchpad-dogfood.md) — Scratchpad editor-theme replacement exercise and state-continuity observations.

The current feature and release scope are summarized in the [roadmap](../PLAN.md) and [Alicorn coverage](../frontends/alicorn/PARITY.md). Historical validation reports are evidence for their named scenarios, not a rolling aggregate status.
