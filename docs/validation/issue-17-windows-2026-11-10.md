# Scratchpad #17 — Windows release acceptance

Date: 2026-11-10

Scratchpad candidate: `da78552827d48081774287dfa3166840fabc2629`

Alicorn: `655c0f07dc73b3e22da184ea78e479acd0b0758f` (current `master`)

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

Every sample returned a supported plan with 1,000 folds. This synchronous planner run is retained as the earlier application-level baseline; it is not worker or native-UI timing.

## Asynchronous worker and cancellation diagnostic

An opt-in bridge diagnostic now exercises the real Caliber worker using a 18,981,000-byte prose file with 1,000,000 newline-terminated rows (1,000,001 buffer lines including the final empty line) and 1,000 paragraphs. Run it from PowerShell at the Scratchpad root:

```powershell
$ProjectRoot = (Resolve-Path .).Path
$env:SCRATCHPAD_SEMANTIC_ZOOM_DIAGNOSTICS = '1'
$env:CGO_ENABLED = '1'
$env:CALIBER_ROOT = Join-Path $ProjectRoot '.deps\caliber'
$CaliberRelease = Join-Path $ProjectRoot 'frontends\alicorn\build\caliber-target\release'
$env:CGO_CFLAGS = "-I$env:CALIBER_ROOT\include"
$env:CGO_LDFLAGS = "-L$CaliberRelease"
$env:PATH = "$CaliberRelease;$env:PATH"
Push-Location (Join-Path $ProjectRoot 'bridge\caliber')
try { go test -v . -run '^TestSemanticZoomWorkerDiagnostics$' -count=1 }
finally { Pop-Location }
```

Windows results, 20 successful requests:

| Measurement | p50 | p95 |
| --- | ---: | ---: |
| Request to published plan | 23.600 ms | 25.102 ms |
| Worker plan build | 23.597 ms | 25.102 ms |

One observed cancellation returned the worker in **1.000 ms**. The test also sampled Go-managed heap: 55.88 MB baseline / 95.34 MB peak allocated heap, and 56.91 MB baseline / 96.16 MB peak heap in use. These are Go runtime heap measurements, not process working-set, committed memory, or GPU memory. The diagnostic test is opt-in and reports values without timing-sensitive assertions.

This still does not measure when the native UI first accepts typing or scrolling while the plan is pending, end-to-end UI-to-visible latency, or OS process working-set peak.

## Windows package candidate

Built from the exact Scratchpad candidate above. The package manifest records Alicorn `655c0f07dc73b3e22da184ea78e479acd0b0758f`, Caliber `197cd964cc7265bc60df599a6b8562eac7c75f3a`, and SDL `3.4.20` shared. The native dependency audit and relocated-archive launch passed. The archive includes its declared license notices.

| Artifact | Size | SHA-256 | Signing |
| --- | ---: | --- | --- |
| `Scratchpad-v0.2.0-windows-amd64.zip` | 22,563,600 bytes | `6f08192e3fe177dc1776c3a4dbd5e20dd3ed7976969f877141a9312613856fc4` | Unsigned (Authenticode: `NotSigned`) |
| `Scratchpad.exe` | 8,604,672 bytes | `e80a13c1bde0eb38b6ce6f28ac5f0939c6aebeeac8396ef568a7d5607d8bab1b` | Unsigned |

This is a local candidate artifact, not a published release asset. Manual clean-location use, quit, and relaunch have not been recorded.

## Remaining acceptance

The following physical checks are still open on Windows:

- Measure native UI-to-visible latency and when Full source first accepts typing/scrolling while a plan is pending. Worker p50/p95, one cancellation-to-worker-exit sample, and Go heap samples are now recorded above; Windows process working-set peak remains unmeasured.
- During a pending plan, type and paste, use IME composition where available, change depth/anchor, and switch or close the source. Confirm only the latest generation can publish and Full source stays available.
- Record ordinary edit/save/reopen, source navigation and stale-reference handling, and primary/detached-window isolation.
- Force-quit a session with an unsaved edit; verify the recovery prompt/data, unchanged source bytes, conflict handling, and recovery/dismissal.
- Manually use the exact package from a clean location, then quit and relaunch it.

The issue also requires macOS physical measurements and acceptance. The existing macOS comment is a partial run and does not provide worker percentiles, cancellation latency, peak memory, or the remaining cross-window/recovery-conflict evidence. This report does not justify closing #17.
