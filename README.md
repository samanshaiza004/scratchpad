# Scratchpad

Scratchpad is a native, file-first editor for notes, prose, tasks, and code. For v0.1.0, **Alicorn is the supported desktop frontend**. The Go application remains authoritative for document bytes, editing commands, workspace operations, saves, conflicts, and recovery; Alicorn provides the native window, interaction, and presentation.

## Product direction

Scratchpad keeps ordinary files durable and portable while exploring views that can gather or reduce text without becoming a new source of truth. Version 0.1.0 focuses on dependable file workflows and ordinary editing. Projection features described in [the product thesis](docs/THESIS.md) are future exploration, not a v0.1.0 promise. See [the roadmap](docs/PLAN.md) for current scope.

## Run Alicorn

From the repository root:

```powershell
.\tools\alicorn.ps1 run
```

```sh
./tools/alicorn.sh run
```

The wrapper synchronizes the pinned Alicorn and Caliber dependencies. It requires Go 1.25.5 or newer, Odin, Rust/Cargo for Caliber, and the platform's native build tools. Windows also needs a 64-bit MinGW-w64 C compiler; macOS needs SDL3 (`brew install sdl3`). See [Alicorn setup and current status](frontends/alicorn/README.md).

Run the Alicorn integration suite with `test` instead of `run`; `build` creates a native artifact and `smoke` checks launch, publication, wake, presentation, and shutdown.

## Checks

```sh
go test -tags treesitter_release ./...
```

The Alicorn integration suite also runs Go/Caliber boundary tests, Odin checks, and frontend behavior tests through `tools/alicorn.ps1 test` or `tools/alicorn.sh test`.

## Frontend history and known gaps

The former Shirei and GPUI implementations are preserved at the `archive/pre-v0.1.0-frontends` branch and tag. They are not supported build targets. Alicorn currently lacks saved-session restoration, the outline sidebar, fold controls, selectable/persisted themes, editor font-zoom controls, and expand-selection. These are recorded in the [Alicorn coverage and follow-up list](docs/frontends/alicorn/PARITY.md); native Windows/macOS validation is tracked separately from missing features.

## Project principles

- Ordinary files stay durable and portable.
- One document model supports prose, notes, tasks, and code.
- Derived structure may be rebuilt from source.
- Views do not silently modify source.
- Editing behavior stays explicit and predictable.

## Documentation

Start with the [documentation index](docs/README.md), [architecture](docs/ARCHITECTURE.md), [Alicorn editing behavior](docs/frontends/alicorn/EDITING.md), and [Markdown design](docs/frontends/alicorn/MARKDOWN.md). Completed implementation and retired frontend reports are under [engineering history](docs/history/README.md).

## License

Scratchpad is released under the [MIT License](LICENSE).
