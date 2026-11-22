# Quick Open projection cache validation

## Result

The Quick Open cache regression benchmark compares the repeated filter-and-sort
work used before the cache with repeated reads through the retained projection.
The legacy loop mirrors the pre-cache call pattern from Scratchpad commit
`ef1f1bfd`: rendering, selection movement, and activation each filtered the
workspace path index again. The current loop computes the projection once and
reuses it for those same-query operations.

On November 22, 2026, the local macOS arm64 run used 5,000 synthetic paths and
the query `document 042`, which matched 125 paths. Each sample performed 90
operations; the reported values are the median of five samples:

| Measurement | Time |
| --- | ---: |
| First projection build for the query | 5.40 ms |
| 90 legacy full scans and sorts | 516.87 ms |
| 90 retained-cache lookups | 1.58 μs |

Environment: macOS 27.2.1, Odin `dev-2026-11:9a6991685`. The cache-lookup
measurement is near the timer's practical floor, so treat it as negligible
lookup cost rather than a precise per-call latency. The regression also
checks that cached and uncached results have the same ordering, that unchanged
queries and index generations reuse the retained allocation, and that query or
index-generation changes rebuild it.

## Limits

This is an isolated projection microbenchmark, not an end-to-end typing or frame
latency measurement. It excludes input dispatch, text shaping, layout, painting,
and path-index construction. A new query still builds its first projection
synchronously; this fixture measured that at 5.40 ms for 5,000 paths. Larger
workspaces need separate measurement before claiming a foreground latency bound.

The frontend regression suite exercises scoped Down/Escape routing and query
changes through Alicorn's public interaction-scope APIs. The standard
`alicorn-dev test` runner also resolves AccessKit from both the current Alicorn
host path and the older native-host path, so it can validate the locked runtime
without manually adding compiler collections.
