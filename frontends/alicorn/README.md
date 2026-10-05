# Scratchpad Alicorn

Alicorn is Scratchpad's supported native frontend for v0.1.0. The Odin/Runa frontend owns transient interaction and presentation; the Go application remains authoritative for document bytes, commands, workspace operations, saving, conflict handling, and crash recovery. The two run in one native process through the Caliber C ABI.

## Run

From the repository root:

```powershell
.\tools\alicorn.ps1 run
.\tools\alicorn.ps1 test
.\tools\alicorn.ps1 smoke
```

```sh
./tools/alicorn.sh run
./tools/alicorn.sh test
./tools/alicorn.sh smoke
```

The wrapper synchronizes the exact Caliber and Alicorn revisions in `dependencies.lock.json`. It requires Go 1.25.5 or newer, Odin, Rust/Cargo, and platform build tools. Windows requires 64-bit Go with cgo and 64-bit MinGW-w64 GCC, plus Odin's Windows linker/SDK prerequisites. macOS requires SDL3 (for example, `brew install sdl3`).

`build` creates the native artifact under `out/alicorn`. `test` runs Go/Caliber ABI checks, Odin type-checking, Alicorn bridge tests, and frontend behavior tests. `smoke` builds and launches a native window for a bounded run and checks publication, host wake, presentation, and ordered shutdown. Native IME, dialogs, clipboard, OS trash, DPI, pointer feel, and tab/workspace drag-and-drop still need hands-on verification on the target operating systems.

## Theme authoring

Scratchpad's workbench and paper palettes are authored in `themes/scratchpad-workbench.json` and `themes/scratchpad-paper.json`. Both extend `alicorn.base` and use semantic aliases; the paper theme also defines the app-specific `app.scratchpad.editor.paper_surface` role. The sRGB source values round-trip to the existing runtime colors exactly.

The build, test, smoke, and run commands use Alicorn's `theme compile` command to generate static Odin theme data before checking or building the frontend. The application registers those immutable values at runtime; it does not read theme files or include the JSON compiler in the shipped binary. The paper surface uses its namespaced role, while Alicorn's core editor-background role remains available as the fallback. The repository has no Scratchpad-specific theme serializer.

From the repository root, check and explain authored tokens with:

    odin run .deps/alicorn/tools/theme -collection:alicorn=.deps/alicorn -out:out/alicorn/theme-tool.exe -- check themes/scratchpad-workbench.json
    odin run .deps/alicorn/tools/theme -collection:alicorn=.deps/alicorn -out:out/alicorn/theme-tool.exe -- explain themes/scratchpad-paper.json scratchpad.semantic.paper.surface

Run the same commands for either theme file; explain prints the resolved linear-sRGB value and alias provenance.

## Included behavior

Alicorn provides native File/Workspace/Edit/View menus; reorderable document tabs and tab drag-and-drop; dirty-close decisions and deferred app shutdown with Save All / Discard All / Cancel; a virtualized workspace tree with search, quick open, create, rename, move, OS trash, and file/directory drag-and-drop; current-file Find/Replace and Go to Line; clipboard, undo/redo, IME composition, recovery, conflict resolution, and Save As; a command palette; live Markdown typography and editing commands; Tree-sitter syntax highlighting for Go, TypeScript, and TSX; table navigation/formatting; prose and cell-aware table wrapping; and per-document wrap override.

The editor reads a bounded source window, maps displayed bytes back to source offsets, and keeps edits optimistic while Go remains authoritative. Markdown meaning comes from the Go projection; the frontend renders transported ranges and does not parse Markdown.

## Current feature gaps

Compared with the retired Shirei workbench, Alicorn does not yet restore the saved workspace/open-document session, provide the outline sidebar (code symbols, Markdown headings, tasks, and links), fold/collapse controls for code and Markdown, selectable/persisted themes, editor font-zoom commands, or expand-selection. The detailed coverage and follow-up list is in [Alicorn coverage](../../docs/frontends/alicorn/PARITY.md). These are product gaps, distinct from native-platform verification still pending for v0.1.0.

The retired Shirei and GPUI source is preserved at Git ref `archive/pre-v0.1.0-frontends`; it is no longer an active build target.
