# Scratchpad GPUI Gate 1

This is an experimental second frontend for Scratchpad. It asks one concrete
question:

> Can a Rust/GPUI shell consume Scratchpad's small application contract through
> the real Go-to-Caliber foreign boundary without making the Go application know
> about GPUI?

The experiment is deliberately not an editor port. The current Shirei frontend,
`main`, and the scalable Go editor remain the working product path.

## Boundary

```text
GPUI foreground
    │ semantic command
    ▼
one serialized GPUI background scheduler
    │ direct CaliberApiV1 table calls
    ▼
Go c-shared backend → Scratchpad application
    │ state publication and bounded listing
    ▼
GPUI state model
```

The Go backend links one Caliber `cdylib` at build time. The Rust executable
does not depend on `caliber-ffi`; it loads only the Go backend's small C symbol
surface, validates the returned Caliber ABI version/table size, and calls the
returned table directly. The expected Caliber checkout is pinned to
`e350c50` by [`EXPERIMENT-METADATA.toml`](EXPERIMENT-METADATA.toml), with an
explicit override required for another revision.

The lifecycle is explicit: `start → running → stop → stopped`. State leases are
accounted for across the foreign boundary, and shutdown is refused while one is
outstanding. Exported Go entry points return explicit statuses and never allow a
panic to cross the native boundary. The JSON protocol uses numeric
`request_id` correlation and bounded packets. Gate 1 accepts only valid UTF-8
paths; lossless arbitrary-byte path transport is intentionally deferred.

## Gate 1 shell

The shell contains application chrome only:

- workspace listing with local expansion/focus state;
- document tabs and active-document selection;
- save, close, dirty/conflict/status indicators;
- command-palette and settings affordances;
- a read-only document placeholder showing identity and revision.

The interface does not carry document bytes, cursor/selection/viewport state,
shaping, folds, projections, IME data, or paint data. `gpui-kit = "=0.6.1"`
is the only GPUI dependency and supplies the matching component family.

## Build and test

From the Scratchpad repository root:

```text
go run ./cmd/gpui-dev build --caliber-root /path/to/caliber
go run ./cmd/gpui-dev test --caliber-root /path/to/caliber
go run ./cmd/gpui-dev run --caliber-root /path/to/caliber
go run ./cmd/gpui-dev smoke --caliber-root /path/to/caliber
go run ./cmd/gpui-dev measure --caliber-root /path/to/caliber
```

`test` keeps the root Go suite independent, runs the nested cgo module with
`GOEXPERIMENT=cgocheck2`, and runs Rust format/tests/clippy. `build` emits
`artifact-manifest.json` with the executable, Go backend library, and Caliber
library. Platform runtime paths are colocated deliberately (`@rpath` on
macOS, `$ORIGIN` on Linux, and the executable directory on Windows).

No ABI stability, crates.io release, public generated header, IDL, or code
generation is promised.
