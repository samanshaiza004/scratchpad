# Scratchpad

Scratchpad is a native, file-first editor for notes, prose, tasks, and code.
Ordinary files remain the durable source of truth. The Go application owns
document bytes, editing commands, workspace operations, saves, conflicts, and
recovery; the Odin/Alicorn frontend owns native interaction and presentation
through the Caliber C ABI.

The latest published release is [v0.1.1](https://github.com/samanshaiza004/scratchpad/releases/tag/v0.1.1).
The current `main` branch contains unreleased v0.2.0 work. Release status and
remaining acceptance gates are tracked in the [roadmap](docs/PLAN.md); the full
release history is in the [changelog](CHANGELOG.md).

## What is in current `main`

- Edit regular files in one source-backed document model, with Markdown and
  supported code presentation, selection expansion, folding, and source-aware
  Full, Focus, Skim, and Overview views.
- Work with derived surfaces: pin ranges, edit unambiguous pinned source, edit
  workspace search results, and navigate tasks, symbols, headings, and links.
- Use a keyboard-navigable workspace tree, Quick Open, editable Search and
  Symbols tools, detachable text-document windows, and read-only PNG/QOI
  previews.
- Restore clean sessions and recent workspaces, recover unsaved edits after a
  crash, choose an editor font and size, and switch persisted themes.

These are capabilities on the unreleased development line; consult the
[v0.1.1 release notes](CHANGELOG.md) for what is in the latest published
packages.

## Run from source

The wrappers synchronize the pinned Alicorn and Caliber revisions before
building or testing:

```sh
./tools/alicorn.sh run
./tools/alicorn.sh test
./tools/alicorn.sh smoke
```

On Windows, use the equivalent PowerShell commands:

```powershell
.\tools\alicorn.ps1 run
.\tools\alicorn.ps1 test
.\tools\alicorn.ps1 smoke
```

The native frontend requires Go with cgo, Odin, Rust/Cargo, and platform build
tools. See [Alicorn setup and usage](frontends/alicorn/README.md) for pinned
toolchain details, platform requirements, diagnostics, and interactive
features. Build consumer packages with `package --version <version>`; see the
[packaging guide](packaging/README.md). The v0.1.1 release has Windows x64 and
Apple Silicon macOS packages.

Run the backend and language tests independently with:

```sh
go test -tags treesitter_release ./...
```

## Product and engineering docs

- [Product thesis](docs/THESIS.md) — ordinary files, source-connected views,
  and the design laws.
- [Roadmap](docs/PLAN.md) — unreleased v0.2.0 scope and remaining release
  gates.
- [Documentation index](docs/README.md) — current guides, design notes, and
  validation records.
- [Alicorn coverage](docs/frontends/alicorn/PARITY.md) — current capabilities
  and known limits.
- [Changelog](CHANGELOG.md) — consolidated v0.1.0, v0.1.1, and Unreleased notes.

The former Shirei and GPUI frontends are preserved at the
`archive/pre-v0.1.0-frontends` Git ref for historical reference; they are not
active build targets.

## Principles

- Ordinary files stay durable and portable.
- One document model supports prose, notes, tasks, and code.
- Derived structure can be rebuilt from source.
- Views do not silently mutate source; writes require explicit, safe mapping.
- When structure is stale or unavailable, ordinary text remains available.

## License

Scratchpad is released under the [MIT License](LICENSE).
