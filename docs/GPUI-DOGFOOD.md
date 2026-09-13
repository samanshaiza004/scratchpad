# GPUI second-frontend dogfood

Status: experimental; Gate 1 through Gate 4 edit-spike implementation lives on branch
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
shaping, folds, projections, IME, and paint data remain local or deferred.
Gate 4 adds only a bounded Rust-local caret/selection session and one
in-flight source-edit intent; it is not a port of the editor.

## Gate 4: optimistic bounded editing

The first editable path tests Model B without moving the scalable editor into
Rust. Go remains authoritative for complete document bytes, editor revisions,
undo/domain edit semantics, dirty state, and persistence. Rust owns only one
bounded visible window plus its local caret and selection. It can produce one
`replace_document` intent containing the document id, application revision,
editor revision, global start/end byte offsets, and replacement bytes.

The visible resource descriptor now includes the window's global `start_byte`,
so a Rust edit can map a local selection back to the Go document without
serializing the document or guessing through replacement characters. The
initial Rust session accepts only non-truncated windows whose bytes are valid
UTF-8. This is a temporary Gate 4 mapping constraint, not a change to
Scratchpad's byte-preserving document model; the Go wire and editor still
accept bounded raw replacement bytes.

The Rust session applies the replacement locally before dispatch, then waits
for the Go acknowledgement carrying the new editor revision and the updated
application state. A stale editor revision is rejected before mutation. The
session can roll back its bounded optimistic copy on failure. The foreign
acceptance test exercises this through the real Go c-shared backend and
Caliber ABI, saves the edited file, verifies the bytes on disk, and then
proves that a second stale edit is rejected.
The spike intentionally allows only one in-flight edit; batching and typing
coalescence are deferred until a real interactive editor is justified.

This gate does not send cursor motion, selection changes, viewport movement,
IME preedit, shaping, layout, folds, projections, or paint data through
Caliber. It also does not yet provide a full interactive GPUI text editor;
those are separate experiments after this seam's synchronization costs are
reviewed.

## Gate 3.5 closeout

The first Gate 3 measurement was dominated by calling `Buffer.Line` once per
requested row. The existing piece buffer now exposes one narrow
`BoundedLines` operation: it resolves the start/end byte boundaries and copies
the requested contiguous range once, while preserving the same line/byte
bounds and partial-line semantics. This is an editor-internal seam used by
the adapter, not a document-RPC abstraction.

The foreign measurement now records warm medians and p95 values over 64
iterations. On the development Apple M1 host, using the release-built Go
backend and Caliber library, the 9.6 KiB fixture measured 84.8 µs median and
118.1 µs p95 for command → bounded visible resource → Rust cache. The Rust
foreign test is run through Cargo's normal test target, so these timings are
engineering measurements rather than an all-release performance claim.
The direct Go extraction benchmark measured 37.7 µs, 9,472 bytes, and one
allocation for the equivalent range. The remaining foreign stages were:
Rust encode/dispatch 10.6 µs median, backend pump/response decode 71.4 µs,
Caliber map/copy/release 1.0 µs, and `SPVS` decode/cache 1.3 µs. The backend
pump bucket intentionally includes Go command decode, range extraction,
resource publication, and response JSON; these measurements localize rather
than pretend to isolate those internal substeps.
The separate optimized foreign smoke measured 29.5 µs for one Gate 4 edit
dispatch → Go acknowledgement → state read → Rust reconciliation sample; it
is a smoke signal, not a warm distribution.

The shell now accepts a visible slice only when its document id, application
revision, and editor revision match the current active state. A stale slice is
ignored instead of becoming displayable. The scheduler stress test submits
100 rapid visible-range positions and verifies that one latest request remains
queued; each foreign resource is released before shutdown.

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
| Rust executable | 18.6 MiB | optimized release build |
| Go backend library | 24.2 MiB | optimized/stripped c-shared build |
| Caliber library | 0.4 MiB | optimized cdylib |
| native runtime artifacts | 3 | executable + Go backend + Caliber |
| command/state transport | 25.8 µs median / 27.9 µs p95 | Rust test path, 64 warm samples; command → state read |
| visible resource round trip | 84.8 µs median / 118.1 µs p95 | Rust test path, 64 warm samples; command → bounded resource → Rust cache |
| visible resource payload | 9,691 bytes | 256-line request from the 2,000-line fixture; 64 KiB maximum |
| Gate 4 edit acknowledgement | 29.5 µs | one optimized foreign-smoke sample; not a distribution |
| direct bounded extraction | 37.7 µs, 9,472 B, 1 alloc | Go editor benchmark for the equivalent contiguous range |
| settled idle RSS | not yet sampled | use the native platform sampler |
| cold startup | 30.0 s bounded attempt, timed out locally | native window did not complete in the managed macOS session |

The transport adds JSON encode/decode and one state copy into the Rust shell.
Gate 3.5 keeps one bounded line assembly in Go, one Caliber immutable-resource
copy, one Rust map copy, and one cached Rust byte vector; the complete
document is never serialized. The most important costs so far are the Go
runtime baseline, three-artifact packaging, dynamic-loader diagnostics,
resource/state lease accounting, and another application-owned wire format.
The main benefit is now concrete: the unchanged Scratchpad application/editor
packages supply both the Shirei shell and a Rust/GPUI shell, with only the
requested visible slice crossing the boundary.

The cumulative GPUI dogfood delta from the initial Gate 1 commit is about
2,102 added code/test lines and 94 deleted lines; Gate 4 contributes 791 added
and 27 deleted lines. This includes the bridge, shell, scheduler, runner,
protocol, bounded editor session, and acceptance tests, but excludes
documentation and workflow text. Gate 3's hop accounting is:

| hop | copy/allocation behavior |
| --- | --- |
| Rust command → Caliber | JSON command buffer allocation; Caliber copies the bounded command into its queue |
| Go pump → piece buffer | `BoundedLines` resolves two indexed boundaries and copies one bounded contiguous range |
| Go → Caliber resource | one 48-byte-header-plus-payload allocation and one Caliber immutable-resource copy |
| Caliber → Rust | Caliber map lease; Rust allocates one bounded `Vec<u8>` and copies the resource before releasing both leases |
| Rust cache → GPUI text | the shell retains the bounded byte vector; final lossy display conversion allocates a temporary render string |

The state path has its existing bounded JSON response/state copies. No hop
allocates in proportion to the document size beyond the requested slice.

`measure` runs the foreign test path and writes its command-to-state,
warm-median/p95 stage timings, and visible-resource measurements into
`frontends/gpui/build/measurements.json`, then
attempts the native launch/shutdown smoke. It also records the byte size of
each runtime artifact. Settled RSS still needs a native sampler. The direct
Shirei path remains simpler and has fewer copies and artifacts; Gate 3.5 only
tests whether the bounded data seam earns those costs.

## What stayed local

Document bytes remain authoritative in the existing piece-backed editor;
the Gate 3 resource is only a bounded copy of the requested visible lines.
Viewport ownership, shaping, projections, folds, IME, and rendering mechanics
remain outside this boundary. This keeps the existing scalable editor intact.
Gate 4's first spike confirms only the
smallest part of the Model B hypothesis: Go can remain authoritative for
document bytes and edit semantics while Rust keeps a bounded optimistic
caret/selection session. Viewport, IME, shaping, and layout remain untested.

## Current verdict

**continue** — only as a narrow experiment. Gate 4's bounded optimistic edit
spike shows that one Rust-local source replacement can cross the real Go →
Caliber → Rust path, receive revisioned acknowledgement, save, and reconcile a
stale edit without disturbing the scalable editor. This is evidence for a
source-edit seam, not ABI stabilization, a framework, or a claim that Caliber
is cheaper than direct Shirei integration. A full editor remains deferred until
this synchronization cost is reviewed.
