# Scratchpad #17 — Windows release acceptance

Date: 2026-11-10

Scratchpad candidate: `2f4194670da924c1c1231021c07e6d381f590bba`

Alicorn: `c7997e750bdc67a454033e4dfd12ae5828451d55`

Platform: Windows 10 Home 22H2, build 19045, AMD64; AMD Ryzen 5 7600X

Go: `go1.27.1 windows/amd64`; Odin: `dev-2026-11-nightly:08539cd`

## Automated Windows validation

`.\tools\alicorn.ps1 test -Odin C:\odin\odin.exe` passed. This ran the Go suite across the Scratchpad modules, bridge tests, and the Odin frontend checks: **241 Odin tests passed**.

`.\tools\alicorn.ps1 smoke -Odin C:\odin\odin.exe` passed on the Windows SDL/D3D12 host. The isolated native subprocess smoke verified clean two-document session restoration and a separate unsaved-recovery restart. This is native host/session evidence; its recovery scenario seeds a recovery snapshot and does not simulate forcibly killing a user-driven session.

## Large-prose semantic zoom planner

Command:

```powershell
go test -tags treesitter_release ./application -run '^$' `
  -bench 'BenchmarkSemanticZoomProseTransition/Paragraphs/lines=1000000/(Focus|Skim|Overview)$' `
  -benchtime=1x -count=3 -benchmem
```

Fixture: 1,000,001 source lines, 1,000 paragraph structures, approximately 19 MB of generated prose. This measures synchronous application plan construction. It does **not** measure the background worker, UI-to-visible latency, worker p50/p95, cancellation latency, peak process memory, or native accessibility serialization.

| Depth | Samples (ms/op) | Median | Allocated per query |
| --- | --- | ---: | ---: |
| Focus | 18.871, 18.946, 19.222 | 18.946 ms | 10.40 MB |
| Skim | 19.646, 19.048, 18.853 | 19.048 ms | 10.40 MB |
| Overview | 19.112, 19.696, 19.249 | 19.249 ms | 10.40 MB |

Every sample returned a supported plan with 1,000 folds. The raw output is retained locally at `out/issue-17-latest-alicorn-windows/semantic-zoom-benchmark.txt` and is not committed.

## Windows package candidate

Built from the exact Scratchpad candidate above. The package manifest records Alicorn `c7997e750bdc67a454033e4dfd12ae5828451d55`, Caliber `197cd964cc7265bc60df599a6b8562eac7c75f3a`, and SDL `3.4.20` shared. The native dependency audit and relocated-archive launch passed. The archive includes its declared license notices.

| Artifact | Size | SHA-256 | Signing |
| --- | ---: | --- | --- |
| `Scratchpad-v0.2.0-windows-amd64.zip` | 22,563,595 bytes | `c9c3ab03f1999e3c908e44de4cce93ed713e69fd13f77f23651b35af492b3f58` | Unsigned (Authenticode: `NotSigned`) |
| `Scratchpad.exe` | 8,562,176 bytes | `e4a276a92b072a12bf9c88b50fcf3622a77bfe425886da7d1da946581eccf3b6` | Unsigned |

This is a local candidate artifact, not a published release asset. Manual clean-location use, quit, and relaunch have not been recorded.

## Remaining acceptance

The following physical checks are still open on Windows:

- Measure the native semantic-zoom transitions on the large prose fixture, including when Full source first accepts typing/scrolling, worker p50/p95, cancellation latency, and peak memory.
- During a pending plan, type and paste, use IME composition where available, change depth/anchor, and switch or close the source. Confirm only the latest generation can publish and Full source stays available.
- Record ordinary edit/save/reopen, source navigation and stale-reference handling, and primary/detached-window isolation.
- Force-quit a session with an unsaved edit; verify the recovery prompt/data, unchanged source bytes, conflict handling, and recovery/dismissal.
- Manually use the exact package from a clean location, then quit and relaunch it.

The issue also requires macOS physical measurements and acceptance. The existing macOS comment is a partial run and does not provide worker percentiles, cancellation latency, peak memory, or the remaining cross-window/recovery-conflict evidence. This report does not justify closing #17.
