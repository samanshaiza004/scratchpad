# Windows static SDL dogfood

Scratchpad can build an experimental Windows package with Alicorn's external
static native-link recipe:

```powershell
./tools/alicorn.ps1 package --version 0.1.1 --static-sdl `
    --out out/packages/windows-static-sdl
```

The Windows static package check is also available as an opt-in run of the
`Consumer package candidates` GitHub Actions workflow. Dispatch it with the
`static_sdl` input enabled. This keeps static SDL preparation out of routine
Go-only test runs; the job builds the package, checks its audit manifest and
SDL DLL absence, and launches the extracted archive from an unrelated working
directory. The package step uses a temporary short drive mapping because MSVC's
CMake try-compile FileTracker can fail under the recipe's nested staging path
on a hosted Windows runner.

This is an opt-in package experiment. The existing Windows package command
continues to produce the shared-SDL portable ZIP. Static mode asks the pinned
Alicorn checkout for a validated recipe, sets its `ODIN_ROOT` on the Odin
build process, and passes the recipe's compiler arguments directly. Scratchpad
still packages its Go backend and Caliber FFI library beside the application;
the experiment removes the private `SDL3.dll` dependency rather than combining
the Go and Odin runtimes into one executable.

The package step verifies the recipe's SDL and AccessKit library hashes,
packages the recipe's SDL version and license, audits the final PE dependency
graph, rejects an SDL or Alicorn host DLL import, and smoke-launches both the
staged application and relocated ZIP with a Windows-system-only `PATH`. The
Scratchpad release manifest records the SDL linkage and recipe fingerprint.

## Dogfood result

On 2026-10-14, the same Scratchpad, Alicorn, and Caliber revisions produced both
Windows x64 packages. The static build used Go 1.27.1, Rust 1.98.1, Odin
`dev-2026-09-nightly:a2fb372`, CMake 4.3.1, Ninja 1.13.2, MSVC 19.51.36248.0,
and the static MSVC CRT (`/MT`).

| Package | ZIP size | Runtime files |
| --- | ---: | --- |
| Shared SDL | 21,687,428 bytes | SDL3.dll, scratchpad_backend.dll, caliber_ffi.dll |
| Static SDL | 21,677,535 bytes | scratchpad_backend.dll, caliber_ffi.dll |

The static archive is 9,893 bytes smaller in this build. The size difference
is negligible; the concrete distribution benefit is removing `SDL3.dll` while
keeping the existing Go and Caliber library boundaries. The static package
manifest records SDL 3.4.16 and recipe fingerprint
`0fbd47df29bd2f42c7192cfdc99d89cf4d92e91b7a21b394db5dd443ca6bad69`.

Both package audits passed. Both the staged application and extracted ZIP
launched from an unrelated working directory; static mode used a Windows
system-only `PATH`. Scratchpad's native smoke selected Direct3D 12 and reported
successful publication, wake, presentation, and ordered shutdown.

For this run, CMake used Ninja from an MSVC developer environment. The
Visual Studio generator encountered a local Windows process-environment issue
where both `PATH` and `Path` reached MSBuild; Ninja configured the same x64
MSVC toolchain and passed Alicorn's compiler, architecture, target, and CRT
checks. The unusually long temporary worktree also exceeded CMake's 250-
character object-path limit, so I exposed the exact merged Alicorn checkout
through a temporary short drive mapping during the build. The mapping was
removed afterward; the normal `C:\Users\saman\dev\scratchpad` checkout path
does not need that workaround.

The portable shared-SDL ZIP remains the distribution baseline. Test the static
package on a clean Windows machine before making static SDL the default.
