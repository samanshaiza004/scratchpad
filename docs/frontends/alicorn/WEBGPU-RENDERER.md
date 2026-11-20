# WebGPU renderer entry (issue #211, Stage B)

Scratchpad's Alicorn frontend is one application with two renderer entry
paths:

| Renderer | Host entry | Selector | Status |
| --- | --- | --- | --- |
| `sdl-gpu` | `alicorn:native/sdl_gpu` `host.Run(host.Application)` | default; `--renderer=sdl-gpu`; `SCRATCHPAD_RENDERER=sdl-gpu` | Reference renderer |
| `webgpu` | `alicorn:ui/webgpu.run` (hosted SDL3/WebGPU) | `--renderer=webgpu`; `SCRATCHPAD_RENDERER=webgpu` | Hosted migration target |

Both paths run the same callbacks, the same description phases, and the same
host-service vocabulary. `frontends/alicorn/app_host.odin` owns that surface;
`frontends/alicorn/app_layout.odin`, `main.odin`, and `floating_window.odin`
hold the application logic.

## Architecture

`app_host.odin` declares `Scratchpad_Application` once. It contains

* the window configuration (title, size, menus, menu presentation, decoration
  mode, chrome height/metrics/layout/appearance),
* `prepare` / `describe` / `after_frame`, the three phases that the reference
  `build` callback always performed,
* every host callback (`on_initialize`, `on_key`, `on_text_change`,
  `on_text_input`, `on_text_key`, `on_pointer`, `on_drag`,
  `on_scroll_capture`, `on_scroll`, `on_services`, `on_start`, `on_wake`,
  `on_scheduled_wake`, `on_close_requested`, `on_dialog`, `on_stop`,
  `on_menu_command`, `on_file_drop`, `on_tick`).

The two adapters below it are mapping-only:

* `run_scratchpad_sdl_gpu` fills a `host.Application` and calls `host.Run`
  exactly as the frontend did before the split. `build_app` is still
  `prepare → begin_frame → describe → end_frame → after_frame`.
* `run_scratchpad_webgpu` calls `alicorn:ui/webgpu.run` and maps each hosted
  callback back onto the shared description. The hosted runtime opens the
  frame but does not add a root container, so `hosted_render` runs `prepare`
  then `describe`, and `describe` opens the application's `.Root` itself —
  the same contract as the reference host's `build`. `after_frame` is passed
  as `webgpu.run`'s `on_after_frame` hook, so both hosts run post-layout work
  at the same point: `describe → end_frame → after_frame → present`.

Both hosts therefore run the after-frame phase after `end_frame` of the same
description pass, including the last pass before an idle period. Deferred
actions, focus/scroll restoration, the editor row trace, and the smoke
publication assertion all sample that identical position.

Secondary windows use `alicorn.Hosted_Window_Description` /
`Hosted_Runtime_Config` (`floating_window_description`), so the floating
editor is described once. On the native path `app_host.odin` bridges that
hosted description onto `host.Application` (the same shape Alicorn's own
`ui.run` adapter uses) and opens it through the host-owned window service.
One deliberate difference remains there: `floating_window_render` still
applies its post-layout work at the start of its next description
(`Floating_Window_State.after_frame_pending`), because that description is
shared with the native secondary-window bridge, which forwards no after-frame
hook. Moving it onto `Hosted_Runtime_Config.on_after_frame` is a separate
follow-up for both renderers.

## Field mapping

`host.Application` → shared description → `webgpu.run`:

| `host.Application` | `Scratchpad_Application` | `webgpu.run` | Notes |
| --- | --- | --- | --- |
| `state` | `state` (the `^App`) | `state` (generic `T`) | Same pointer |
| `title` | `title` | `title` | `"Scratchpad"` |
| `width`, `height` | `width`, `height` | `width`, `height` | 1200 × 760 |
| `menus` | `menus` | `menus` | `[]alicorn.Menu`; same borrowed storage |
| `menu_presentation` | `menu_presentation` | `menu_presentation` | `.Hidden` on Windows, `.Labels` elsewhere |
| `window_decorations` | `window_decorations` | `window_decorations` | `.Integrated_Title_Bar` (Windows), `.Content_Title_Bar` (macOS) |
| `window_chrome_height` | `window_chrome_height` | `window_chrome_height` | macOS content titlebar height |
| `window_chrome_metrics` | `window_chrome_metrics` | `window_chrome_metrics` | `proc(rawptr, ^Runtime, Metrics)` |
| `window_chrome_layout` | `window_chrome_layout` | `window_chrome_layout` | Connected titlebar tabs + drag regions |
| `window_chrome_appearance` | `window_chrome_appearance` | `window_chrome_appearance` | Windows only |
| `interaction_update_policy` | (adapter constant) | `.Explicit` | Matches `host.Application`'s zero value |
| `build` | `prepare` + `describe` (+`after_frame`) | `render` (`hosted_render`) + `on_after_frame` | Description owns `.Root`; after-frame runs after `end_frame` on both hosts |
| `on_initialize` | `on_initialize` | `on_initialize` | Hosted entry adds default font loading after it |
| `on_key` | `on_key` | `on_key` | `alicorn.Application_Key`; hosted key adapter is identity |
| `on_text_change` | `on_text_change` | `on_text_change` | `alicorn.Text_Change` |
| `on_text_input` | `on_text_input` | `on_text_input` | Hosted `Hosted_Text_Input_Event` converted to `Application_Text_Input_Event`; UTF-8 byte offsets preserved |
| `on_text_key` | `on_text_key` | `on_text_key` | `Application_Text_Key_Event` |
| `on_pointer` | `on_pointer` | `on_pointer` | Same |
| `on_drag` | `on_drag` | `on_drag` | Same |
| `on_scroll_capture` | `on_scroll_capture` | `on_scroll_capture` | Same |
| `on_scroll` | `on_scroll` | `on_scroll` | Nil in both paths today |
| `on_services` | `on_services(Scratchpad_Services)` | `on_services(UI_Host_Services)` | `host.Application_Services` / `UI_Host_Services` both converted into `Scratchpad_Services` |
| ↳ windows | `windows` | `UI_Host_Services.windows` | Native service re-shaped once via `Native_Window_Service` |
| ↳ dialogs | `dialogs` | `dialogs` | Same `alicorn.Hosted_Dialog_Service` |
| ↳ quit | `quit` | `quit` | Same `alicorn.Hosted_Quit_Service` |
| ↳ clipboard | `clipboard` | `clipboard_text` | `alicorn.Clipboard_Service`; the hosted `clipboard` (async) field is unused by Scratchpad |
| ↳ scheduler | `scheduler` | `scheduler` | Same `alicorn.Application_Scheduler`; scheduled wake class preserved |
| ↳ diagnostics | none | none | Not used by Scratchpad |
| ↳ file_drag | none | none | Not used by Scratchpad (file drops arrive via `on_file_drop`) |
| ↳ motion_clock | none | none | Not used by Scratchpad |
| `on_start` | `on_start(gui.Application_Waker)` | `on_start(Application_Waker)` | `host.Application_Waker` is converted field-for-field |
| `on_wake` | `on_wake(^alicorn.Runtime)` | `on_wake(Application_Context)` | `Application_Context` is converted to `^Runtime` |
| `on_scheduled_wake` | `on_scheduled_wake` | `on_scheduled_wake` | `Scheduled_Wake_Class` preserved |
| `on_close_requested` | `on_close_requested` | `on_close_requested` | `Hosted_Close_Result` (Allow/Defer) |
| `on_dialog` | `on_dialog` | `on_dialog` | `^File_Dialog_Result` |
| `on_stop` | `on_stop` | `on_stop` | Same |
| `on_menu_command` | `on_menu_command` | `on_menu_command` | `Action_ID` |
| `on_file_drop` | `on_file_drop` | `on_file_drop` | Borrowed path |
| `on_tick` | `on_tick` | `on_tick` | Nil in both paths today |
| `smoke` (separate `host.Run` argument) | — | `smoke` | Forwarded unchanged |

No `host.Application` field lacks a hosted equivalent at Alicorn c56f4b9.

## Build recipes

The frontend always carries both entry points, so it always compiles the
hosted SDL3/WebGPU host. Two consequences:

* `-define:WGPU_SHARED=true` is required for every frontend build (and the
  Odin frontend test build). AccessKit's Rust static library and Odin's static
  wgpu-native both define `rust_eh_personality`; the shared WGPU library
  avoids the duplicate symbol. This mirrors `examples/16_native_webgpu_ui`.
* `wgpu_native.dll` (Odin's
  `vendor/wgpu/lib/wgpu-windows-x86_64-msvc-release/lib/wgpu_native.dll`) must
  be staged next to the executable. `cmd/alicorn-dev` copies it into the
  artifact directory for `build`, `run`, `smoke`, and the frontend test
  executable.

Local candidate builds (Alicorn `codex/issue-211-scratchpad-webgpu` at
9b31260, not the pinned revision yet):

```powershell
$env:ALICORN_CANDIDATE_ROOT = 'C:\Users\saman\.codex\worktrees\alicorn-webgpu-migration\alicorn'
go run ./cmd/alicorn-dev build --odin C:\odin\odin.exe --allow-alicorn-revision
go run ./cmd/alicorn-dev smoke --odin C:\odin\odin.exe --allow-alicorn-revision --renderer=webgpu --backend=d3d12
go run ./cmd/alicorn-dev run  --odin C:\odin\odin.exe --allow-alicorn-revision --renderer=webgpu
```

`tools/alicorn.ps1` exposes the same switches (`-Renderer webgpu
--backend=vulkan`); `tools/alicorn.sh` forwards `--renderer=` /
`--backend=` through its remaining-argument pass-through. The renderer can
also be selected at launch with `--renderer=webgpu|sdl-gpu` or
`SCRATCHPAD_RENDERER=webgpu|sdl-gpu`. The hosted host itself accepts
`--backend=d3d12|vulkan`; without the flag wgpu chooses the adapter backend
(auto currently lands on Vulkan here; both backends are now validated).

Reference recipe:

```powershell
go run ./cmd/alicorn-dev build --odin C:\odin\odin.exe --allow-alicorn-revision
go run ./cmd/alicorn-dev smoke --odin C:\odin\odin.exe --allow-alicorn-revision --renderer=sdl-gpu
go run ./cmd/alicorn-dev test  --odin C:\odin\odin.exe --allow-alicorn-revision
```

### Artifacts and follow-ups

* `out/alicorn/scratchpad-alicorn.exe` — one binary, both renderers.
* `out/alicorn/wgpu_native.dll` — required by the hosted host.
* `dependencies.lock.json` is **not** bumped in this branch. The pin moves when
  the hosted work lands on Alicorn master; until then local builds need
  `--allow-alicorn-revision` plus `ALICORN_CANDIDATE_ROOT`.
* `cmd/alicorn-dev` detects AccessKit through both the legacy
  `native/sdl_gpu/accessibility_accesskit.odin` path and the hosted
  `host/sdl3/accessibility/accesskit.odin` path, because the candidate moved
  the adapter.
* Consumer packaging (`package`) is deliberately rejected in this branch:
  Alicorn's Windows/macOS packagers need a wgpu-native staging and license
  contract before a shipped package can start. `build`, `run`, `smoke`, and
  `test` are unaffected.

## Validation (2026-11-20, Windows x64, RTX 2080 SUPER)

Stage B wrap-up slice, executed against Alicorn
`codex/issue-211-scratchpad-webgpu` at `9b31260` with
`ALICORN_CANDIDATE_ROOT` and `--allow-alicorn-revision`:

* `test`: Go suites, the Odin type check, 13 bridge/lifecycle tests, and 255
  frontend tests all pass.
* `smoke --renderer=sdl-gpu`: both legs pass
  (`publication_rendered/wake_observed/ordered_shutdown/session_restore` =
  true for `clean` and `recovery`).
* `smoke --renderer=webgpu --backend=d3d12`: both legs pass with the same four
  assertions.
* `smoke --renderer=webgpu --backend=vulkan`: both legs pass with the same four
  assertions.
* The `publication_rendered` assertion lives in `scratchpad_build_after_frame`
  again (it had been moved into the description phase while the hosted runtime
  lacked a post-frame hook). Passing on both hosted backends is the evidence
  that `on_after_frame` now runs after `end_frame` of every described frame,
  including the last pass before idle.
* Capture parity on the same scene (`language/detection.go`, restored session,
  cool-light, workbench): hosted D3D12 and SDL_GPU `inspector.txt` agree on all
  75 text runs including `paint-spans` byte ranges and colors, and differ only
  in frame counters and per-node `reason` strings. `screenshot.ppm` is
  byte-identical (0 of 2,914,768 bytes differ).

### Row-trace fingerprints: remaining hosted/reference difference

`SCRATCHPAD_EDITOR_ROW_TRACE_PATH` traces agree on `text_fp` and
`geometry_fp` for every sampled row, but `style_fp` and `paint_fp` still differ
by a per-host constant (each host is stable across repeat runs). Moving
`after_frame` to the contract position did not change those values, so the
difference is not a sampling-phase artifact. The inspector dump above rules
out retained presentation state as the cause; the hash inputs that remain are
host-local identities: `node.font`, `text_run.font_generation`, and the
display list's text-run handle generations. The reference host seeds
DirectWrite and script fallback faces at startup (`native_load_default_fonts`
in Alicorn's `native/sdl_gpu/fonts.odin`), each of which advances
`Text_Engine.font_generation`; `ui/webgpu.run` loads only the bundled default
faces. Identical text, geometry, spans, inspector state, and pixels make this
difference non-observable; it is recorded here so a future slice does not
chase it as a rendering regression.

## Hands-on Stage C checklist

Not exercised by smoke; needs the real window:

1. Launch `out/alicorn/scratchpad-alicorn.exe --renderer=webgpu --backend=d3d12`
   with a real workspace and confirm the workbench, tabs, and status strip
   appear.
2. Modals and Quick Open float above the workbench (the hosted root contract
   and the presentation ordering changed in this slice).
3. Syntax highlighting on light themes (span colors must survive the hosted
   presentation list; the reference and hosted captures now agree).
4. Connected titlebar tabs: region declaration, tab reorder drag, window drag
   on the blank band, caption reservation at the measured content end.
5. Native menus: Hidden presentation on Windows, accelerators, disabled and
   checked items, command palette parity.
6. Text input: IME preedit/commit byte offsets, caret placement, click-drag
   selection, clipboard cut/copy/paste.
7. Scheduler wakes: selection autoscroll (Frequent) and theme compilation
   (Opportunistic) both keep the editor responsive.
8. Dialogs: open/save dialog round-trip through the hosted dialog service.
9. File drop: drag a file from Explorer into the window.
10. Floating window: detach a tab (`--renderer=webgpu`), Save / On top /
    Return to tabs, and the native-path floating window after the description
    unification.
11. Theme switching (Warm, Cool Light, Charcoal & Ink, Workbench Relief, Flat)
    and live editor theme reload.
12. Resize, DPI change, minimize/restore, and device-loss recovery.
