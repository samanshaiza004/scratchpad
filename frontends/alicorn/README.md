# Scratchpad Alicorn — shell experiment

This experimental frontend is Scratchpad's workbench shell, not an editor port. It presents real backend state through native File/Workspace menus and dialogs, document tabs, selection, save and dirty-close decisions, plus a lazily expanded, virtualized workspace tree with path-based semantic focus and keyboard navigation. The document area remains a placeholder; text editing is not part of this phase.

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

`test` performs the Go/Caliber foreign-boundary checks, Odin type-check, and headless bridge integration for directory listing/refresh and opening, selecting, saving, and closing real documents through the existing generic commands. `smoke` builds and launches the native window for a bounded run and verifies a real publication, host wake, presentation, and ordered shutdown. Use `run` for manual menu, dialog, tree keyboard/scrolling, and tab interaction checks. Linux smoke requires an actual `DISPLAY` or `WAYLAND_DISPLAY`; without one the driver declines to claim a native smoke pass.

The window shows workspace entries and open-document state from the existing Caliber bridge. Tree listings are loaded through `list_directory` and `refresh_workspace`; they are bounded by the backend and no frontend-specific Go API is added. Menus, buttons, tabs, and dialogs are projections of shared Scratchpad actions/operations; the document area is explicitly a placeholder. Shirei remains Scratchpad's default frontend. See [`docs/ALICORN-PARITY.md`](../../docs/ALICORN-PARITY.md) for phase status and the future parity contract.
