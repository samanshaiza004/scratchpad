# Scratchpad Alicorn — experimental frontend

This experimental frontend presents the real Scratchpad workbench shell and a bounded source view. It includes native File/Workspace/Edit menus and dialogs, document tabs, save and dirty-close decisions, a lazily expanded virtualized workspace tree, and a fixed-row virtualized document surface. The editor viewport owns durable keyboard focus; pointer placement, Shift-click extension, double-click word selection and word-granularity drag, triple-click logical-line selection and line-granularity drag, and captured-drag autoscroll are local presentation state shaped and hit-tested through Alicorn/Runa. Horizontal/vertical/page navigation and platform-normalized word/line/document movement remain frontend-local. Phase 4 implements bounded optimistic edits, stale-chain recovery, Scratchpad-authoritative Enter and undo/redo, OS clipboard commands, and frontend-local IME composition with native candidate-area positioning. Source display remains a 64 KiB window; committed edit payloads support up to 128 KiB so a 100 KiB paste fits. Soft wrapping remains deferred.

It uses the same Go application and `bridge/caliber/cshared` backend as GPUI. Alicorn does not have a frontend-specific Go backend. Canonical Scratchpad command IDs are published in the shared `StateEnvelope`; the Alicorn frontend maps them to host action tokens for native menus while Go remains the state and command authority.

From the repository root:

```powershell
.\tools\alicorn.ps1 run
.\tools\alicorn.ps1 test
.\tools\alicorn.ps1 smoke
```

```sh
./tools/alicorn.sh run
./tools/alicorn.sh test
./tools/alicorn.sh smoke
```

The wrapper syncs exact Caliber and Alicorn revisions from `dependencies.lock.json`. Odin is resolved from `ALICORN_ODIN` or `PATH`; Go is resolved from `SCRATCHPAD_GO` or `PATH`. Explicit `-Go` and `-Odin` options are available in PowerShell; the Go driver accepts `--go` and `--odin` on every platform.

On Windows, use 64-bit Go (`GOHOSTARCH=amd64`) with cgo enabled and a 64-bit MinGW-w64 GCC. Odin's normal Windows prerequisites (MSVC linker and Windows SDK) are also required. The wrapper reports these requirements before building if the selected toolchain is incompatible.

`test` performs Go/Caliber foreign-boundary checks, Odin type-checking, headless bridge integration, and editor-view coverage including a 10 MiB source fixture, clipboard and 100 KiB paste projection, Undo/Redo ownership, IME preedit/commit/cancel/recovery, Runa hit testing, pointer selection/autoscroll, multiline indentation, caret navigation, selection, and viewport reveal. The edit tests verify local feedback, serial revision convergence, stale-chain recovery, and Scratchpad-authoritative history. Rejected committed IME text stays recoverable in a buffer bounded by 128 KiB plus at most one crossing commit; Copy must succeed or the user must explicitly discard it before closing the document, and text input suspends once the recovery threshold is reached. `smoke` builds and launches the native window for a bounded run and verifies a real publication, host wake, presentation, and ordered shutdown. Use `run` for manual menu/dialog/tree/tab checks and to exercise document focus, clipboard, committed text, undo/redo, native IME, scrolling, and resizing. Native click-count/modifier delivery, drag autoscroll, clipboard, and IME still need manual Windows/macOS verification; headless tests do not certify OS candidate-window behavior. During pending edits, document/workspace commands remain visually enabled but are deferred until the edit queue settles. Soft wrapping remains deferred. Linux smoke requires an actual `DISPLAY` or `WAYLAND_DISPLAY`; without one the driver declines to claim a native smoke pass.

The window shows workspace entries, open-document state, and bounded document source from the existing Caliber bridge. Tree listings use `list_directory` and `refresh_workspace`; source uses the existing bounded `read_visible_lines` resource. Source edits reuse the frontend-neutral `replace_document` command; its acknowledgement includes canonical applied bytes when Scratchpad's Enter behavior transforms the requested LF. Menus, buttons, tabs, and dialogs project shared Scratchpad actions/operations; the document view retains caret/selection locally and stages edits in a bounded optimistic window while Scratchpad remains authoritative. Shirei remains Scratchpad's default frontend. See [`docs/frontends/alicorn/PARITY.md`](../../docs/frontends/alicorn/PARITY.md) for phase status and the future parity contract.
