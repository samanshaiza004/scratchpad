# Scratchpad Alicorn Phase 1

This is an experimental lifecycle/state frontend, not the Scratchpad editor. It uses the same Go application and `bridge/caliber/cshared` backend as GPUI; there is no Alicorn-specific Go protocol.

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

`test` performs the Go/Caliber foreign-boundary checks, Odin type-check, and bridge lifecycle tests. `smoke` builds and launches the native window for a bounded run and verifies publication, host wake, and ordered shutdown. Linux smoke requires an actual `DISPLAY` or `WAYLAND_DISPLAY`; without one the driver declines to claim a native smoke pass.

The frontend shows only backend lifecycle and the real `StateEnvelope`: workspace, document count, active document, and revision. Shirei remains Scratchpad's default frontend; GPUI and the parity contract in `docs/ALICORN-PARITY.md` are unchanged in scope.
