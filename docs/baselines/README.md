# C0 benchmark baselines

These TSV files are raw output from the committed benchmark executables. They
are evidence artifacts, not timing gates. Fixture generators are deterministic;
the generated corpora are intentionally not checked in.

Environment for the recorded run:

- source revision: `9509f1d` (bounded editor view and all preceding C0 code);
- Go: `go version` from the development macOS host;
- Shirei: `v0.0.0-20260824003747-6df9f18e3c20` (`6df9f18`);
- OS/architecture: macOS on the development host;

The long-line closeout artifact was recorded with:

- source revision: `b44d36a` plus the closeout working tree;
- Go: `go1.27.0 darwin/arm64`;
- Shirei: `v0.0.0-20260824003747-6df9f18e3c20` (`6df9f18`);
- command: `GOCACHE=/tmp/scratchpad-gocache go run ./cmd/scratcheditor -fixture single-2m -operations first-paint,insert-near-9m,selection-visible,long-line-chunk-walk,scroll-top-bottom -out docs/baselines/scratcheditor-longline-closeout.tsv`;
- artifact: `scratcheditor-longline-closeout.tsv`.
- output format: TSV with fixture, document bytes, operation, wall time,
  allocation count/bytes, and heap before/after.

Reproduce the successful raw outputs with:

```bash
go run ./cmd/textbench -fixture source-mixed-100k -operations first-paint,insert-middle,paste-100k,selection-visible,scroll-top-bottom,resize -out docs/baselines/textarea-source-mixed-100k.tsv
go run ./cmd/scratcheditor -fixture source-mixed-1m -operations first-paint,insert-middle,paste-100k,selection-visible,scroll-top-bottom -out docs/baselines/scratcheditor-source-mixed-1m.tsv
go run ./cmd/scratcheditor -fixture source-mixed-10m -operations first-paint,insert-middle,paste-100k,selection-visible,scroll-top-bottom -out docs/baselines/scratcheditor-source-mixed-10m.tsv
go run ./cmd/scratcheditor -fixture single-2m -operations first-paint,insert-near-9m,selection-visible,scroll-top-bottom -out docs/baselines/scratcheditor-single-2m.tsv
```

The realistic 1 MiB TextArea invocation used the same operation set and was
interrupted after 90 seconds without producing a measurement row. The
canonical fragmentation workload retains seed `0x53435241544348`; its optional
correctness fuzz command is:

```bash
go test ./editor -fuzz=FuzzBufferDifferential -fuzztime=30s
```
