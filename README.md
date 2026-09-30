# Scratchpad

Scratchpad is a native, file-first text editor for notes, prose, tasks, and code. It is built around ordinary files and a dependable, comfortable text-editing foundation.

## Product thesis

Scratchpad is being built as a **file-native projection editor**: files remain durable and portable, while future views may gather, reduce, or rearrange text without making those views a new source of truth.

For version 0.1.0, the work is focused on the editor foundation: ordinary file workflows and the basic feel of editing text well. Projection features are planned exploration for 0.2.0; they are not part of the 0.1.0 feature promise.

Read [the product thesis](docs/THESIS.md) for the long-term direction and [the roadmap](docs/PLAN.md) for the versioned scope.

## Run Scratchpad

Prerequisite: Go 1.25.5 or newer.

```bash
go run ./cmd/scratchpad
go run ./cmd/scratchpad --version
```

Run the Go checks with:

```bash
go test ./...
```

## Experimental frontends

The Go and Shirei application is the working product path.

## Alicorn

Alicorn explores a separate native shell over the same Scratchpad application and document model. It has a bounded editing viewport; clipboard, undo and redo, IME composition, and soft wrapping are still in progress.

From the repository root:

```powershell
.\tools\alicorn.ps1 run
```

See [Alicorn setup and status](frontends/alicorn/README.md) for prerequisites and platform details.

## GPUI

GPUI is an integration experiment, not a full editor port. It demonstrates a Rust/GPUI shell using Scratchpad's Go application through the Caliber boundary, with a bounded viewport and a small editing spike. See [the GPUI experiment notes](frontends/gpui/README.md) for its scope and build instructions.

## Project principles

- Ordinary files stay durable and portable.
- One document model supports prose, notes, tasks, and code.
- Derived structure may be rebuilt from source.
- Views do not silently modify source.
- Editing behavior stays explicit and predictable.

## Documentation

The [documentation index](docs/README.md) organizes the thesis, current roadmap, architecture, research, design contracts, and historical engineering records.

## License

Scratchpad is released under the [MIT License](LICENSE).
