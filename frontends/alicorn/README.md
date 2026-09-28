# Scratchpad Alicorn — experimental frontend

This experimental frontend presents the real Scratchpad workbench shell and a bounded source view. It includes native File/Workspace menus and dialogs, document tabs, save and dirty-close decisions, a lazily expanded virtualized workspace tree, and a fixed-row virtualized document surface. The editor viewport owns durable keyboard focus; pointer placement, Left/Right/Home/End, Up/Down, Page Up/Down, directional Shift selection, and in-viewport drag selection are local presentation state shaped and hit-tested through Alicorn/Runa. Phase 4C.1 adds collapsed-caret committed-text insertion with an immediate bounded optimistic projection and one serial Caliber edit request at a time. Selection replacement, Backspace/Delete, clipboard, undo/redo, line breaks/indentation, editor IME composition, and soft wrapping are not implemented yet.

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

`test` performs Go/Caliber foreign-boundary checks, Odin type-checking, headless bridge integration, and editor-view coverage including a 10 MiB source fixture, Runa hit testing, caret navigation, drag selection, preferred-column preservation, and viewport reveal. Its delayed-ack edit test holds the foreign worker before dispatch, verifies committed text appears locally while the authoritative bytes stay unchanged, then checks serial revision convergence. `smoke` builds and launches the native window for a bounded run and verifies a real publication, host wake, presentation, and ordered shutdown. Use `run` for manual menu/dialog/tree/tab checks and to try document focus, caret movement, selection, committed text insertion, scrolling, and resizing. During pending edits, document/workspace commands are disabled until the queue settles. Drag selection currently clamps to the visible viewport edge; drag autoscroll is deferred. Linux smoke requires an actual `DISPLAY` or `WAYLAND_DISPLAY`; without one the driver declines to claim a native smoke pass.

The window shows workspace entries, open-document state, and bounded document source from the existing Caliber bridge. Tree listings use `list_directory` and `refresh_workspace`; source uses the existing bounded `read_visible_lines` resource. Committed text reuses the existing frontend-neutral `replace_document` command and acknowledgement; no frontend-specific Go backend or edit protocol is added. Menus, buttons, tabs, and dialogs project shared Scratchpad actions/operations; the document view retains caret/selection locally and stages committed text in a bounded optimistic window while Scratchpad remains authoritative. Shirei remains Scratchpad's default frontend. See [`docs/ALICORN-PARITY.md`](../../docs/ALICORN-PARITY.md) for phase status and the future parity contract.
