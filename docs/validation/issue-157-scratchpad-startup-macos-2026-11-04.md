# Issue #157: Scratchpad startup and construction smoke on macOS

This is a first application-level comparison of Alicorn's structured layout-trace change. It measures Scratchpad's bounded native smoke path in fresh processes and records the Alicorn application-build timing emitted by the host.

## Result

Seven measured launches per candidate, after one warm-up per candidate, on an Apple M1 MacBook Air (`MacBookAir10,1`), macOS 27.2, arm64. Both candidates used the same Scratchpad source, Odin compiler, Caliber revision, generated workspace, and pending retained-effects API changes.

| Candidate | Process elapsed median | Process CPU median | Peak RSS median | Slowest app-build callback median | Host loop median |
| --- | ---: | ---: | ---: | ---: | ---: |
| Pre structured tracing | 3549.30 ms | 448.81 ms | 127.2 MiB | 13.774 ms | 3032.46 ms |
| Structured tracing | 3536.19 ms | 447.87 ms | 119.2 MiB | 13.783 ms | 3029.55 ms |

The paired median change in app-build maximum was -5.7%, but the candidate medians were effectively identical and individual samples varied substantially. Process CPU changed by +1.7%; elapsed time changed by +1.5%. These results do not show a reliable Scratchpad startup or app-construction improvement from structured tracing.

The process and host-loop durations include the smoke fixture's roughly three-second wait. They are not launch-to-first-visible-frame measurements. The host currently exposes the slowest individual app-build callback but not cumulative time across callbacks. Frame p95 and GPU-encode samples varied with desktop scheduling and are not evidence of a regression.

Both candidates passed all smoke checks: native publication, a wake, ordered shutdown, and successful SDL host completion. The generated workspace contained eight folders, 192 source files, and a README.

## Compared source states

- Scratchpad: `eeb7930500be000b94487040e53dbed190bf25eb`
- Alicorn pre-trace experiment: `ffc492546d8888d89a7496544551c06dc5a02040`
- Alicorn structured-trace experiment: `b739e22f1600f5d7cead161042cb905eb1065b54`
- Caliber: `197cd964cc7265bc60df599a6b8562eac7c75f3a`
- Odin: `odin-dev-2026-11` toolchain

The two Alicorn experiment trees included the same local copy of the pending retained-effects API changes, so the tracing implementation was the A/B difference. The experiment commit IDs are local measurement inputs, not published upstream revisions. The Scratchpad measurement worktree also carried two compile-compatibility edits: the current Odin CoreFoundation string cast and the test fixture's `radius` to `sigma` field rename for the pending API. Neither changed the measured runtime scenario.

## Reproduction

Build one optimized Scratchpad executable for each Alicorn source tree into separate output directories, using the same Scratchpad checkout, Odin, Caliber, and build flags:

```sh
go run ./cmd/alicorn-dev build --release \
  --odin "$ODIN" \
  --alicorn-root "$ALICORN_ROOT" --allow-alicorn-revision \
  --caliber-root "$CALIBER_ROOT" \
  --out "$OUT_DIR"
```

Then run the paired fresh-process measurement:

```sh
python3 tools/measure_startup_macos.py \
  --candidate pre_trace=/path/to/pre-trace/scratchpad-alicorn \
  --candidate structured_trace=/path/to/structured-trace/scratchpad-alicorn \
  --runs 7 --warmups 1 \
  --results-dir out/benchmarks/issue-157-macos
```

The runner alternates candidate order, creates a disposable workspace, launches each executable outside the repository working directory, captures per-process elapsed/CPU/peak-RSS and Alicorn host timings, and rejects runs that fail the Scratchpad smoke markers. Its JSON summary and raw logs are local measurement artifacts and should be retained with any future comparison.

## Disposition

The synthetic retained-locality benchmark demonstrates a large Alicorn-level improvement, but this representative Scratchpad smoke does not reveal a corresponding application-construction win. Keep Issue #157 open for a true launch-to-first-frame measurement, cumulative app-build instrumentation, and a larger real workspace / document interaction profile.
