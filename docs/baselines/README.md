# Retained benchmark baselines

The TSV and JSONL files in this directory are historical measurement artifacts. They record earlier editor, Shirei, and Tree-sitter experiments and remain useful for understanding the project's performance history. The executables that produced the Shirei editor TSVs (`cmd/scratcheditor` and `cmd/textbench`) were retired with that frontend and are preserved only at the `archive/pre-v0.1.0-frontends` Git ref; the old commands below are not current reproduction instructions.

The measurements are evidence, not timing gates. Their original source revisions, environments, and workload descriptions remain attached to the artifacts in Git history. Use the current [Alicorn integration guide](../../frontends/alicorn/README.md) for supported build and test commands.

The canonical editor-buffer fuzz target remains available:

```sh
go test ./editor -fuzz=FuzzBufferDifferential -fuzztime=30s
```
