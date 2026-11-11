# Validation records

Scratchpad v0.2.0 is published. Its #17 reports below are dated acceptance
records for the release candidate and retain the package hashes and limits
observed during those runs; the release page contains the published artifacts.

Each item records a bounded run, platform check, or manual acceptance matrix. Results apply to the commit, operating system, hardware, and scenario named by that record. A successful native startup smoke does not imply full physical-input or visual certification.

- [Semantic zoom and folding](semantic-zoom.md) — deterministic scenarios and platform interaction matrix; includes the large-document construction measurement.
- [Scratchpad #17 Windows release acceptance](issue-17-windows-2026-11-10.md) — Windows test/smoke/package evidence, worker timings and physical acceptance; native UI latency and process working-set metrics are explicitly unmeasured.
- [Scratchpad #17 macOS release closeout](issue-17-macos-2026-11-11.md) — Go/bridge/frontend tests, optimized native package audit and relocated launch smokes, repeated million-line worker samples, and maintainer-reported physical acceptance; native UI latency and full GUI-process memory high-water are explicitly unmeasured.
- [Connected-tab motion](issue-60-connected-tabs-motion.md) — Windows interaction and retained-motion observations; accompanying `.mp4` files are captures.
- [Live tab reordering](issue-60-live-reorder-windows.mp4) — Windows motion capture.
- [Live-theme dogfood](issue-166-scratchpad-dogfood.md) — Scratchpad editor-theme replacement exercise and state-continuity observations.

The current feature and release scope are summarized in the [roadmap](../PLAN.md) and [Alicorn coverage](../frontends/alicorn/PARITY.md). Historical validation reports are evidence for their named scenarios, not a rolling aggregate status.
