# Issue #157: Scratchpad startup and interaction measurements on macOS

This report completes the Scratchpad application-level comparison for Alicorn's structured layout-trace change. It covers a normal generated-workspace smoke and a bounded interaction sequence that opens a 5,002-line source file.

## Result

The tracing change did not produce a measurable improvement in end-to-end startup or first application-frame submission. In the large-document interaction, cumulative application-description callback time improved by a median 8.0% across paired runs, while whole-process CPU, elapsed time, and memory stayed effectively flat. This is a small application-level benefit, not an overall startup speedup.

All values below are seven-run medians after one warm-up per candidate. Percent change is the median of the seven paired run changes (structured versus baseline). RSS is binary MiB.

### Initial startup smoke

| Metric | Baseline | Structured | Paired median change |
| --- | ---: | ---: | ---: |
| Process elapsed | 3,322.05 ms | 3,322.02 ms | -0.7% |
| Process CPU | 381.47 ms | 369.30 ms | +0.5% |
| Peak RSS | 122.4 MiB | 122.1 MiB | -0.9% |
| Cumulative application-build callbacks | 7.02 ms | 7.09 ms | -1.2% |
| Slowest application-build callback | 6.84 ms | 6.92 ms | -1.1% |
| First application-frame submission | 354.01 ms | 354.84 ms | -0.7% |
| Host loop | 3,028.08 ms | 3,027.64 ms | +0.02% |

The paired CPU change differs from the change between the two separate medians because it summarizes run-by-run differences. Both summaries indicate no dependable startup win at this workload size.

### Large-document interaction

| Metric | Baseline | Structured | Paired median change |
| --- | ---: | ---: | ---: |
| Process elapsed | 3,350.79 ms | 3,347.67 ms | -0.02% |
| Process CPU | 672.00 ms | 674.87 ms | +0.9% |
| Peak RSS | 154.3 MiB | 153.4 MiB | -0.5% |
| Cumulative application-build callbacks | 41.51 ms | 36.73 ms | -8.0% |
| Slowest application-build callback | 12.01 ms | 9.42 ms | -22.5% |
| First application-frame submission | 354.35 ms | 355.07 ms | +0.3% |
| Host loop | 3,028.70 ms | 3,024.09 ms | -0.2% |

The interaction run's lower callback time is measurable, but it did not reduce total process CPU or first-frame submission time. The process elapsed and host-loop totals include the smoke harness's roughly three-second wait.

## Method

- Machine: Apple M1 MacBook Air (`MacBookAir10,1`), macOS 27.2, arm64.
- Build profile: release (`-o:speed`); SDL 3.4.18 shared/Homebrew.
- Odin: `dev-2026-11-nightly:9a69916` (binary SHA-256 `c0b4d3cf313c78e488b56e9d8b2f1753b8c959c8cf96208335367d93b38d9126`).
- Caliber: `197cd964cc7265bc60df599a6b8562eac7c75f3a`.
- Scratchpad source revision: `eae5556e8a01214a0b42a5bc8d33161b5048e041`; tree SHA-256 `452fde68efd2696760e758947942a7e8527193fd8419a66c7131321235b5baa9`.
- Alicorn A/B base: the Scratchpad lockfile's `4375e64642570d93c180244fb6c6f665bf8e679f`. The baseline has structured-tracing commit `067ff0c73551821474c30fc12d0eea2dea4a3009` reverted; the candidate includes it. Their runtime tree SHA-256 values are `3b8a860f101a9d3755af4f1508e025fd1c8f232c8ca7d1a5567b62bc5931e6a9` (baseline) and `124676ae1db1dec57adebc1ef5538e0bbfb57fa36ae83f9fbf1cd23bf0d410c9` (structured).
- Both candidates used the same host-timing overlay (SHA-256 `498790ffd4a3643a47a21f455dcef9c40f714544df34e9559b38613246b7e188`) to expose cumulative application-build time and first successful application-frame submission. The overlay is identical across candidates and is not part of the tracing comparison.
- Executable SHA-256: baseline `f39a913569a122cd89c05b139cd5988b529047c22da58e83213587c80ec4817d`; structured `4532100f66c76179be68802613f3777bb1b567525106b8da9fd0ef4b02bbf7c0`.
- Both candidates used the same font files and generated workspace: eight folders, 192 source files, and a README. The interaction workspace's `application/sample_00.go` contained 5,002 lines: a package declaration, a blank line, and 5,000 generated functions.
- Each scenario ran one fresh-process warm-up and seven measured fresh processes per candidate, alternating candidate order. All 28 measured runs and four warm-ups passed host publication, wake, and ordered-shutdown checks. Each interaction run also completed all nine fixture actions and verified the documents and temporary surfaces were closed.

The nine interaction actions use Scratchpad's existing UI and command paths: open `README.md`, open the large Go document, switch back to the README, open and close Quick Open after its worker is ready, open and close Settings, then close both documents. The fixture reports failure if any step fails or cleanup is incomplete.

### Local build compatibility note

The current Odin compiler required a local CoreFoundation string cast adjustment in `frontends/alicorn/system_fonts_darwin.odin` (`transmute(CF.StringRef)value`). The same compile-only adjustment was present in both candidate builds. It is unrelated to this measurement and is intentionally excluded from this commit.

## Interpretation and limits

`application_build_ns` is cumulative wall time spent in application-description callbacks, not exclusive CPU time. `application_build_max_ns` is the longest such callback. The first-submit metric is the first successful application-frame GPU submission; it does not measure when pixels became visible on screen. Process RSS is the high-water mark across the entire bounded process, not memory attributable to a single action.

At seven samples, nearest-rank p95 is the maximum observed sample and is not a stable tail-latency estimate. GPU/frame timing varied between runs and should not be interpreted as a tracing regression. This is a generated-workspace smoke, not a measurement on the maintainer's personal workspace or a physical interaction-latency study.

Raw logs and JSON summaries are retained locally under `/private/tmp/scratchpad-issue157-clean/results/current-startup` and `/private/tmp/scratchpad-issue157-clean/results/current-large-interaction`; the checked-in CSV contains every measured sample.

## Disposition for Issue #157

The Scratchpad application comparison is complete. It finds no meaningful end-to-end startup or first-submit improvement from structured tracing, and a modest reduction in application callback time when opening and closing a large document. The synthetic Alicorn construction benchmarks remain the evidence for the trace optimization's direct benefit.

This report does not close Issue #157. The remaining work is to finish the bounded historical attribution of construction costs and explicitly accept the retained-feature tradeoffs. There is no evidence here that justifies another Scratchpad startup optimization by itself.

## Reproduction

Build baseline and structured candidates from the exact runtime trees above, applying the identical host-timing overlay and Scratchpad source to both. Then run the two scenarios with the same compiler and generated workspace settings:

```sh
python3 tools/measure_startup_macos.py \
  --candidate baseline=/path/to/baseline/scratchpad-alicorn \
  --candidate structured=/path/to/structured/scratchpad-alicorn \
  --runs 7 --warmups 1 \
  --results-dir out/benchmarks/issue-157-startup

python3 tools/measure_startup_macos.py \
  --candidate baseline=/path/to/baseline/scratchpad-alicorn \
  --candidate structured=/path/to/structured/scratchpad-alicorn \
  --scenario interaction --large-document-lines 5000 \
  --runs 7 --warmups 1 \
  --results-dir out/benchmarks/issue-157-large-interaction
```
