# Scratchpad #17 — Windows validation evidence

Date: 2026-11-10

Scratchpad candidate: `6a72339e8af3ae22bb25a08a15037e1bbb8dc955`

Platform: Windows 10 Home 22H2, build 19045, AMD64

CPU: AMD Ryzen 5 7600X 6-Core Processor

Go: `go1.27.1 windows/amd64`
Odin: `dev-2026-11-nightly:08539cd` (`C:\odin\odin.exe`)

This record covers automated and packaging work performed on Windows for issue #17. It does not claim physical GUI acceptance; those interactions still need a hands-on run.

## Windows package candidate

Built the source-only `0.2.0` Windows x64 package from the candidate revision above with the repository's packaging script. The generated manifest pins:

- Alicorn: `0c8b44bc0365803ebb2ccc464a64633ff0dcfe73`
- Caliber: `197cd964cc7265bc60df599a6b8562eac7c75f3a`
- SDL: `3.4.20`, shared

The packaging checks reported the native dependency audit and relocated archive launch as passed. The package contains the third-party license notices listed in its manifest.

| Artifact | Size | SHA-256 | Signing |
| --- | ---: | --- | --- |
| `Scratchpad-v0.2.0-windows-amd64.zip` | 22,531,375 bytes | `b9d0d57dad8b871a04dac656d84c5bbdf00b6a59cb5e846cb469c8ad5f6bd430` | Unsigned (Authenticode: `NotSigned`) |

This is a locally built validation artifact, not a published release asset. Its build inputs are recorded in `release-manifest.json` inside the package.

## Automated checks

Command:

```powershell
go test -tags treesitter_release ./application
```

Result: passed (`ok scratchpad/application`, 3.624 s).

The package build also completed its native dependency audit and relocated-archive launch smoke. The latter confirms the extracted package can launch from a relocated directory; it does not exercise editing, save/recovery, screen-reader, or multi-window interactions.

## Large-prose semantic zoom planner

Command:

```powershell
go test -tags treesitter_release ./application -run '^$' `
  -bench 'BenchmarkSemanticZoomProseTransition/Paragraphs/lines=1000000/(Focus|Skim|Overview)$' `
  -benchtime=1x -count=3 -benchmem
```

Fixture: 1,000,001 source lines, 1,000 paragraph structures, approximately 19 MB of generated prose. Each sample plans a complete result for the named depth; this measures the synchronous application planner, not the native background worker, UI-to-visible latency, or memory high-water behavior.

| Depth | Samples (ms/op) | Median | Allocated per query | Allocations |
| --- | --- | ---: | ---: | ---: |
| Focus | 19.102, 18.970, 19.089 | 19.089 ms | 10.40 MB | 4,057–4,058 |
| Skim | 18.879, 19.074, 18.693 | 18.879 ms | 10.40 MB | 4,058–4,061 |
| Overview | 19.745, 19.245, 18.961 | 19.245 ms | 10.40 MB | 4,060–4,068 |

All samples returned 1,000 folds and a supported plan. This is a machine-specific benchmark, not a cross-platform comparison or an end-to-end responsiveness guarantee. Raw output is retained locally at `out/issue-17-windows-validation/semantic-zoom-benchmark.txt` and is not part of the source repository.

## Physical Windows checks still required

No physical editing or recovery interaction was completed during this run. The packaged process was started with an isolated workspace and profile, but the desktop-control interface did not expose it as a target; an explicit app-launch attempt timed out. UI automation was stopped at that point. The following remain unverified on Windows:

- Semantic zoom while typing, pasting, and composing IME text; verify latest-request behavior, depth/anchor stability, and safe document/window switching or closing while a plan is pending.
- Ordinary edit, save, close, reopen, source navigation, and stale-reference behavior.
- Primary and detached-window isolation while navigating and editing.
- Terminate with an unsaved edit, restart, inspect recovery contents and prompt behavior, then verify source-disk bytes and save-conflict handling.
- Manually launch, use, quit, and relaunch the exact extracted package from a clean location. The automated relocated-launch smoke is narrower than this acceptance.

The issue also requires macOS physical acceptance and release-candidate evidence. This Windows record alone is not sufficient to close #17.
