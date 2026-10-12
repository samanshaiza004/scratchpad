# Scratchpad consumer packages

Build a local consumer package from the pinned Alicorn and Caliber revisions:

```powershell
.\tools\alicorn.ps1 package --version 0.1.1
```

```sh
./tools/alicorn.sh package --version 0.1.1
```

The command always builds optimized production artifacts. It defaults to a
platform-specific directory under `out/packages/`; pass `--out` to choose a
different child directory under `out/`. Re-running the same command replaces
only an output directory carrying Scratchpad's package marker. It never
overwrites an unrelated directory.

The Windows x64 artifact is a portable ZIP containing a GUI-subsystem
`Scratchpad.exe`, the Go backend, Caliber, SDL3, and license files. The macOS
arm64 artifact is a Finder-launchable `Scratchpad.app` in a ZIP. Alicorn's
platform packagers audit native imports/load paths before the ZIP is created.
The command then extracts the ZIP into a temporary unrelated directory and
smokes that copy with a clean working directory.

Each output includes `release-manifest.json` and `SHA256SUMS.txt`. The archive
contains `alicorn-package.json`, `scratchpad-build-manifest.json`, and the
applicable license texts. The manifest records source and dependency revisions,
Go runtime modules, native audit results, and the archive hash.

## Platform requirements

- Both platforms: Go with cgo, Rust/Cargo, and the Odin compiler used by the
  pinned Alicorn revision.
- Windows: 64-bit Go, MSVC/Windows SDK, and 64-bit MinGW-w64 for cgo.
- macOS: Apple Silicon, Xcode Command Line Tools, CMake, `curl`, and `tar`.
  The package command downloads SDL 3.4.16 from the pinned upstream release,
  verifies its SHA-256, and builds the shared runtime that Alicorn requires.

macOS packaging ad-hoc signs the final app after all dependency path rewriting,
then verifies the signature and the extracted ZIP. Ad-hoc signing is not
Developer ID signing and does not notarize the app. Gatekeeper may still ask
you to approve a test build. Do not disable Gatekeeper to test this package.

In consumer builds, native-host output is captured in the per-user
`startup.log` before SDL initialization so early host failures can be diagnosed
without a console. Scratchpad backend startup errors also appear in the first
window and are written to that log. A missing or corrupted load-time DLL/dylib
can fail before application code runs; the package import/load-path audit is
the check for that case.

These commands build candidate packages only. They do not tag a version,
publish a GitHub Release, notarize, or install the application.
