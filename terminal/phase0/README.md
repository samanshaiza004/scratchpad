# Scratchpad terminal Phase 0

This is an isolated dependency, semantics, renderer, and PTY proof. It is not
the integrated terminal feature and is deliberately a nested Go module so the
root Scratchpad module remains on Go 1.25 until the toolchain gate is decided.

## Pinned inputs

| input | value |
| --- | --- |
| Scratchpad root Go module | Go 1.25.0; unchanged by this proof |
| local Go toolchain observed | Go 1.27.0 (`darwin/arm64`) |
| Phase 0 module | Go 1.26.0 |
| Go binding | `go.mitchellh.com/libghostty` at `v0.0.0-20260824160354-7a5ea4cb990c` |
| binding source commit | `7a5ea4cb990cc62df644dc7819b75bb931296063` |
| Ghostty source commit | `75d657788a63d1593e5fff22c766bd7e162f255c` |
| Zig | 0.16.0 |
| C compiler | AppleClang 21.0.0 (`/usr/bin/cc`) |
| Go PTY | `github.com/aymanbagabas/go-pty` v0.2.3 (`b1081175e7d78aa5e2fd02f88bcbc0af4e280039`) |
| Shirei | `go.hasen.dev/shirei` v0.6.7 |
| default link mode | static `libghostty-vt-static` through the binding's default build tag |

The Ghostty commit is taken from the binding revision's `CMakeLists.txt`; do
not update either revision independently. The binding is CGO-based and its Go
API is explicitly unstable. The binding module checksum is
`h1:FiNQBCVGDQMF0DMOtQ+R+38wJbzrN1HKerXn1Z4b0Hg=`.

## Run the proof

From this directory, first make the pinned native library available. The
binding's development build requires CMake, Zig 0.16.0, and pkg-config. The
binding's CMake file pins the Ghostty source revision above. For a reproducible
local proof, check out that commit separately and pass its path as the
FetchContent source:

```text
export PATH="/path/to/zig-0.16.0:$PATH"
export GHOSTTY_SOURCE=/path/to/ghostty-75d657788a63d1593e5fff22c766bd7e162f255c
cmake -S "$(go env GOMODCACHE)/go.mitchellh.com/libghostty@v0.0.0-20260824160354-7a5ea4cb990c" -B build \
  -DFETCHCONTENT_SOURCE_DIR_GHOSTTY="$GHOSTTY_SOURCE"
cmake --build build
export PKG_CONFIG_PATH="$GHOSTTY_SOURCE/zig-out/share/pkgconfig"
go test ./...
```

The tests intentionally start with canned `VTWrite` fixtures. The Shirei proof
then emits each leading cell at an explicit fixed coordinate and checks its
resolved rectangle, including a two-column CJK cell. Only after those tests
does `TestPTYShellSmoke` start `/bin/sh`, resize its PTY, send a command, and
verify clean exit.

The Phase 0A proof succeeded on macOS arm64 with Zig 0.16.0, AppleClang
21.0.0, and static `libghostty-vt.a`. `otool -L` on the linked test binary
reported only `libresolv`, CoreFoundation, Security, and libSystem; it did not
require a separately installed Ghostty dynamic library. Build output stays in
the ignored `build/` directory and is not part of the repository.

No font asset is bundled in Phase 0. The renderer proof requests CommitMono
first, then OCR-B and broad installed monospace families; missing faces remain
a host font-resolution concern for the eventual panel.
