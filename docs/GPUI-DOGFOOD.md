# GPUI second-frontend dogfood

Status: experimental; Gate 1 through Gate 3 implementation lives on branch
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

## Gate 3: bounded visible-line resource

Gate 3 now exercises the data plane without turning it into a document-RPC
system. `read_visible_lines` asks for a document id, start line, and explicit
line/byte bounds. The Go adapter reads those lines directly from the existing
piece-backed `editor.Buffer`; it never calls `Buffer.Text` or materializes a
`DocumentSnapshot`. It assembles only the requested bytes, publishes them as
one immutable Caliber resource, and returns the resource id/generation plus
the application/editor revisions and line range.

The application-owned resource payload is a 48-byte little-endian `SPVS`
header followed by raw bytes. It carries the slice schema, revisions, line
bounds, truncation bit, and payload length. The Rust client maps the resource
through the Caliber function table, accounts for a short-lived resource lease,
copies and validates the bounded payload, releases both the map lease and the
resource owner reference, and caches the result in the GPUI shell. The UI
renders the bounded slice as ordinary read-only text.

The limit is 256 lines and 64 KiB of payload. The payload preserves arbitrary
document bytes across the foreign boundary; lossy UTF-8 conversion happens
only for the temporary display string. The shell still owns only a cache of
the currently requested slice. Cursor, selection, viewport ownership,
shaping, folds, projections, IME, edit semantics, and paint data remain local
or deferred. Gate 4 is not included.

## Acceptance evidence

- Root Scratchpad tests pass without Caliber configuration.
- Nested backend tests pass with `GOEXPERIMENT=cgocheck2`.
- Rust formatting, unit tests, clippy, and build pass on the development host.
- Backend lifecycle tests cover double-start, double-stop, call-after-stop,
  outstanding state/resource-lease shutdown refusal, release and double
  release, malformed/oversized packets, numeric request correlation, UTF-8
  path rejection, bounded listings, and large-document visible slices.
- The Rust foreign test maps real immutable `SPVS` resources from a 2,000-line
  document and verifies that the returned bytes stay within the 64 KiB bound
  and contain only the requested range.
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
| command/state transport | 21.9 µs average | Rust test path, 16 samples; command → state read |
| visible resource round trip | 10.9 ms average | Rust test path, 16 samples; command → Go line assembly → Caliber map/copy/release |
| visible resource payload | 9,643 bytes | 256-line request from the 2,000-line fixture; 64 KiB maximum |
| settled idle RSS | not yet sampled | use the native platform sampler |
| cold startup | 30.0 s bounded attempt, timed out locally | native window did not complete in the managed macOS session |

The transport adds JSON encode/decode and one state copy into the Rust shell.
Gate 3 adds one bounded line assembly in Go, one Caliber immutable-resource
copy, one Rust map copy, and one cached Rust byte vector; the complete
document is never serialized. The most important costs so far are the Go
runtime baseline, three-artifact packaging, dynamic-loader diagnostics,
resource/state lease accounting, and another application-owned wire format.
The main benefit is now concrete: the unchanged Scratchpad application/editor
packages supply both the Shirei shell and a Rust/GPUI shell, with only the
requested visible slice crossing the boundary.

The cumulative GPUI dogfood delta from the initial Gate 1 commit is 1,112
added code/test lines and 71 deleted lines; this includes the bridge, shell,
scheduler, runner, protocol, and acceptance tests, but excludes documentation
and workflow text. Gate 3's hop accounting is:

| hop | copy/allocation behavior |
| --- | --- |
| Rust command → Caliber | JSON command buffer allocation; Caliber copies the bounded command into its queue |
| Go pump → piece buffer | each requested `Buffer.Line` is a bounded line copy; Go grows one bounded assembly buffer |
| Go → Caliber resource | one 48-byte-header-plus-payload allocation and one Caliber immutable-resource copy |
| Caliber → Rust | Caliber map lease; Rust allocates one bounded `Vec<u8>` and copies the resource before releasing both leases |
| Rust cache → GPUI text | the shell retains the bounded byte vector; final lossy display conversion allocates a temporary render string |

The state path has its existing bounded JSON response/state copies. No hop
allocates in proportion to the document size beyond the requested slice.

`measure` runs the foreign test path and writes its command-to-state and
visible-resource timings into `frontends/gpui/build/measurements.json`, then
attempts the native launch/shutdown smoke. It also records the byte size of
each runtime artifact. Settled RSS still needs a native sampler. The direct
Shirei path remains simpler and has fewer copies and artifacts; Gate 3 only
tests whether the bounded data seam earns those costs.

## What stayed local

Document bytes remain authoritative in the existing piece-backed editor;
the Gate 3 resource is only a bounded copy of the requested visible lines.
Cursor and selection, viewport ownership, shaping, projections, folds, IME,
editing, and rendering mechanics remain outside this boundary. This keeps the
existing scalable editor intact. Gate 4 will test whether Go should own
document/edit semantics while Rust owns frontend-local caret, selection,
viewport, IME, shaping, and layout.

## Current verdict

**continue** — only as a narrow experiment. Gate 3 demonstrates a bounded
immutable visible-line resource over the real Go → Caliber → Rust path without
disturbing the scalable editor. This is evidence for a data seam, not ABI
stabilization, a framework, or a claim that Caliber is cheaper than direct
Shirei integration. Gate 4 remains deferred until this cost record is reviewed.
