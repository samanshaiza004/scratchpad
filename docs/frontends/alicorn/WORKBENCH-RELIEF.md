# Workbench Relief (experimental)

Select **Workbench Relief (Experimental)** in Settings → Appearance, View,
or the command palette. **Flat Workbench** uses the same Warm colors with flat
surfaces, providing a comparison. Warm and Cool Light keep their existing
appearances; Warm remains the default. The choice uses the existing atomic
version-1 preference file and is synchronized with detached documents.

The application names optical relationships without adding widget roles:

| Relationship | Optical height | Consumer |
| --- | --- | --- |
| Recessed | -0.75 | Editor well, optional sidebar well |
| Groove | -0.25 | Find-panel inset and pressed control treatment |
| Flush | 0 | Ordinary structural chrome/status areas |
| Mounted | 0.5 | Operable Default/Primary/Toolbar Button rest state |
| Floating | 1 | Settings, palettes and font picker |

The implementation uses Alicorn semantic surfaces, immutable material IDs and
typed Button recipes. Optical height never changes layout, interaction bounds,
semantic entities or window ordering. Font/text geometry is unaffected. The
JSON theme compiler still authors colors, lengths and material definitions;
the application connects typed setup-only Button material treatments to
Runtime-local handles. There is no new theme parser or paint callback.

## Reproduce the snapshots

Build the frontend against the matching Alicorn candidate, then run:

```powershell
.\tools\capture_workbench_relief.ps1
```

The tool opens the same real Editor Settings scene in Flat, Relief and
Increased Contrast + Reduced Transparency. `SCRATCHPAD_APPEARANCE_FIXTURE`
selects only in-memory fixture state; it does not save a preference. Session
and recovery persistence are disabled during these bounded smoke runs.
GPU readbacks, inspector output, counters and logs are written beneath
`out/workbench-relief`. Captures contain no blinking input field.

Windows D3D12 evidence from 2026-10-23, at the desktop's 100% scale:

![Flat Workbench](workbench-relief/flat.png)
![Workbench Relief](workbench-relief/relief.png)
![Relief with increased contrast and reduced transparency](workbench-relief/contrast.png)

All three native smokes passed publication/wake/ordered shutdown and each
submitted once during the 3-second settled run, with zero native host wake
events. These are appearance samples, not golden-image compatibility promises.

161 frontend regressions and 13 bridge tests pass. Optical transitions in the
full editor/modal/tab fixture preserve semantic nodes and caret source position
without new measurement or layout. Settings interaction/geometry is tested at
100%, 125%, 150% and 200% text scale; native material budgets independently use
all four pixel scales. Actual fractional-DPI monitor moves, physical AT and
macOS desktop captures remain unverified. Keep Alicorn #98 open for those
acceptance gates; do not infer native macOS behavior from these Windows runs.
