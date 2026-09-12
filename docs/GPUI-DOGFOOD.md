# GPUI second-frontend dogfood

Status: experimental; Gate 1 and Gate 2 implementation lives on branch
`gpui-dogfood`. This document records the current evidence, not a product
claim.

## What was built

The Rust frontend uses `gpui-kit = "=0.6.1"` and no direct Caliber crate. A
nested Go module builds `libscratchpad_gpui_backend` with `-buildmode=c-shared`.
That library links the one Caliber `cdylib` and returns the `CaliberApiV1`
pointer/context to Rust. Rust calls `context_dispatch`,
`context_read_latest_state`, `state_publication_release`, and
`context_wake_sequence` from that returned table.

The foreground submits semantic commands only. One GPUI background task owns
the session and drains a coalescing queue; filesystem work and Go calls remain
off the foreground executor. Commands carry a schema version, numeric
`request_id`, application `based_on_revision`, kind, and payload. The first
shell displays workspace entries, tabs, active document identity, dirty/status
state, save/close controls, command-palette/settings affordances, and a
read-only placeholder.

The root Scratchpad module remains independent of Caliber. The cgo-dependent
backend has its own `go.mod`, and its tests run separately with
`GOEXPERIMENT=cgocheck2`.

## Acceptance evidence

- Root Scratchpad tests pass without Caliber configuration.
- Nested backend tests pass with `GOEXPERIMENT=cgocheck2`.
- Rust formatting, unit tests, clippy, and build pass on the development host.
- Backend lifecycle tests cover double-start, double-stop, call-after-stop,
  outstanding state-lease shutdown refusal, release, malformed/oversized
  packets, numeric request correlation, UTF-8 path rejection, and bounded
  listings.
- macOS loader inspection shows one backend dependency on Caliber and no Rust
  dependency on `caliber-ffi`; the runtime artifacts are colocated and the
  backend dependency is rewritten to `@rpath/libcaliber_ffi.dylib`.
- The native smoke path is implemented to exercise start, state read/release,
  list, open, save, close, and stop through the actual Go → Caliber → Rust
  path. The managed macOS development environment terminates the GUI-linked
  process before completion, so native launch remains a desktop CI acceptance
  check rather than local evidence.

## Measurements

The runner writes a machine-readable `measurements.json` beside the native
artifacts. A development macOS build produced approximately:

| item | observed value | note |
| --- | ---: | --- |
| Rust executable | 92 MiB | debug build, GPUI symbols included |
| Go backend library | 24 MiB | debug c-shared build |
| Caliber library | 0.8 MiB | debug cdylib |
| native runtime artifacts | 3 | executable + Go backend + Caliber |
| command/state transport | not yet sampled | add timestamp markers before Gate 3 |
| settled idle RSS | not yet sampled | use the native platform sampler |
| cold startup | not yet accepted | current runner records launch-to-shutdown timing |

The transport adds JSON encode/decode and one state copy into the Rust shell.
The current Gate 1 state is bounded and contains no document bytes. The most
important costs so far are the Go runtime baseline, three-artifact packaging,
dynamic-loader diagnostics, and shutdown lease accounting. The main benefit is
that the Scratchpad application/editor packages remain Shirei-free and a
second frontend can consume the same semantic contract.

## What stayed local

Document bytes, editor buffers, cursor and selection, viewport, shaping,
projections, folds, IME, and rendering remain outside this boundary. This keeps
the existing scalable editor intact. Gate 3, if warranted, will test bounded
immutable visible-line resources rather than publishing a whole document. Gate
4 will test whether Go should own document/edit semantics while Rust owns
frontend-local caret, selection, viewport, IME, shaping, and layout.

## Current verdict

**continue** — only as a narrow experiment. Gate 1 provides enough evidence to
justify a bounded read-only editor-slice investigation, but not ABI
stabilization, a framework, or a claim that Caliber is cheaper than direct
Shirei integration.
