# GPUI migration results

This is the implementation closeout for the current migration pass at
Scratchpad commit `d4f030a`, after the initial parity and source-reuse ledgers.
It records what is proven and what remains before a frontend replacement
decision.

## Parity result

The GPUI frontend now has a real second shell rather than only the Gate 4
foreign-edit proof. It presents a Files tree with nested directory caching,
document tabs and dirty markers, a bounded editable viewport, local caret and
selection movement, PageUp/PageDown resource requests, command palette
navigation over all 75 Scratchpad command IDs, a current-document find surface,
font controls, refresh, and application-owned dirty-close decisions. The Go
application remains authoritative for bytes, revisions, save policy, workspace
mutations, and search matches.

The result is still **partial parity**. The GPUI editor accepts only bounded
valid-UTF-8 windows and does not yet provide native IME, shaped text, mouse
selection, clipboard, soft wrapping, Markdown/language projections, or
byte-preserving malformed-input editing. The shell does not yet expose the
complete Shirei lifecycle surface (Save As, recent/reopen, recovery, conflict
compare, workspace search, outline, and all tree mutation dialogs).

## Improvements

The migration reduced frontend/application coupling by keeping all new UI
state local to Rust and using semantic requests for application work. Directory
expansion is path-keyed and cached, viewport reads are latest-wins, search
matches are capped at 1,000 records, and local edit feedback does not wait for a
Go acknowledgement. The GPUI Kit command palette and tree primitives remain
upstream components; no GPL Zed application/editor code was copied.

## Regressions and limitations

Shirei remains the only frontend with production-quality IME, shaping,
clipboard, raw-byte editing, Markdown presentation, language spans, conflict
and recovery UX, persistent settings, and accessibility coverage. Those gaps
are recorded in `docs/GPUI-PARITY.md`; they are not silently downgraded in the
product contract. The bounded editor's valid-UTF-8 restriction is an explicit
temporary Gate 4 limitation.

## LOC/glue cost

From the Windows-validated baseline `e621f3b` to this pass, the repository adds
about 2,465 lines across the parity/source ledgers and GPUI shell, protocol,
tests, and command mapping. The new Caliber-facing surface is limited to
bounded refresh, mutation, find, close-decision, visible-resource, and
revisioned-edit messages; no generic UI RPC or renderer schema was added.

## Validation

On Windows with Go 1.25-era cgo, Rust/Cargo, MinGW, Visual Studio tooling, and
Caliber `abbe4f7`, the following passed:

* root `go test ./...` with `GOARCH=amd64` and `CGO_ENABLED=1`;
* nested `frontends/gpui/backend` cgo tests against the Caliber release DLL;
* 16 GPUI Rust unit tests and the foreign smoke test;
* GPUI Clippy with `-D warnings`;
* `go run ./cmd/gpui-dev test --release --allow-caliber-revision`;
* `go run ./cmd/gpui-dev smoke --release --allow-caliber-revision`, ending in
  `scratchpad-gpui ready revision=5 shutdown=ok`.

The native result is Windows-only in this pass. macOS and Linux native
certification, IME fixtures, visual baselines, and performance measurements
remain open work.

## Source reuse and platform findings

`docs/GPUI-SOURCE-REUSE.md` records the Apache-2.0 GPUI Kit dependency and the
Zed license boundary. The Windows cgo path is validated with Caliber's release
DLL and the existing harness; no separate GNU Rust Caliber target was needed
on this machine. The harness still keeps the cgo backend and GPUI executable
artifacts co-located.

## Recommendation

KEEP SHIREI DEFAULT
