# Scratchpad Alicorn

Alicorn is Scratchpad's supported native frontend for v0.1.0. The Odin/Runa frontend owns transient interaction and presentation; the Go application remains authoritative for document bytes, commands, workspace operations, saving, conflict handling, and crash recovery. The two run in one native process through the Caliber C ABI.

Ordinary production text, buttons, and simple layout scopes use Alicorn's public `alicorn:ui` helpers; advanced retained controls continue to use the runtime API where they need exact identity, scrolling, text-input, or native behavior. See the [UI API dogfood report](../../docs/frontends/alicorn/UI-API-DOGFOOD.md) for the migration scope, before/after source counts, retained-output comparison, and validation results.

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

On macOS, Scratchpad's retained document tabs share the titlebar row with AppKit's native traffic lights; application menus remain in the macOS system menu bar. Windows keeps native caption behavior and hides the permanent File/Edit/Workspace/Document/View labels. Press Alt to open the native application menu, or use its Alt+letter routes and existing command shortcuts; Ctrl+Shift+P opens the Command Palette. The sidebar and document headers belong to the same retained workspace split as their contents, so tabs follow the editor pane immediately while resizing the sidebar. The selected tab uses the active editor-paper color and a connected contour, with the paper's top material edge open at the join. Find interrupts that connection and restores the ordinary selected treatment. Alicorn resolves native-control reservations and app-declared tab, divider, and blank-drag regions from finalized layout. Linux retains its system-decorated window and separate document-tab row as an explicit visual fallback. Scratchpad owns selection, close, reorder, and detach behavior.

`build` creates the native artifact under `out/alicorn`. `test` runs Go/Caliber ABI checks, Odin type-checking, Alicorn bridge tests, and frontend behavior tests. `smoke` builds and launches a native window for a bounded run and checks publication, host wake, presentation, and ordered shutdown. Native IME, dialogs, clipboard, OS trash, DPI, pointer feel, and tab/workspace drag-and-drop still need hands-on verification on the target operating systems.

For development-only invalidation checks, pass `--app-mutation-diagnostics` to `build`, `test`, `smoke`, or `run`. For example, `.\tools\alicorn.ps1 test --app-mutation-diagnostics` compiles Alicorn with `-debug -define:ALICORN_APP_MUTATION_DIAGNOSTICS=true`; the option is rejected for optimized builds and packages. Scratchpad currently reports backend state/projection adoption and user selection updates; these checks verify that a changed revision schedules UI work, not that the exact affected subtree was invalidated. After building, launch `out\alicorn\scratchpad-alicorn.exe --inspector-open` to inspect the trace (F9 toggles the inspector).

## Theme authoring

Scratchpad's Warm workbench and paper palettes are authored in `themes/scratchpad-workbench.json` and `themes/scratchpad-paper.json`; the contrasting Cool Light palette is authored in `themes/scratchpad-cool-light.json`. These themes extend `alicorn.base` and use semantic aliases. The paper theme defines app-specific paper-surface and editor-padding roles plus the analytic paper material, while the workbench theme authors the selected Tab underline role. The editor padding dimension flows through `style_metric` in the paper scope, so Alicorn environment density scales a real Scratchpad layout metric. The sRGB source values round-trip to the existing runtime colors exactly.

Choose Warm or Cool Light from **View → Use … Theme**, the command palette, or **Settings → Appearance**. Scratchpad stores the choice as a small versioned JSON preference at `%LOCALAPPDATA%\\Scratchpad\\preferences.json` on Windows and `~/Library/Application Support/Scratchpad/preferences.json` on macOS (using the platform configuration directory reported by Odin). A missing, malformed, unsupported-version, or unknown-theme preference falls back to Warm. If writing the preference fails, the selected theme remains active for the current session and Scratchpad reports the save failure.

The build, test, smoke, and run commands use Alicorn's `theme compile` command to generate static Odin theme data before checking or building the frontend. The application registers those immutable values at runtime; it does not read theme files or include the JSON compiler in the shipped binary. The paper surface uses its namespaced role and generated material definition, while Alicorn's core editor-background role remains available as the fallback. The tab recipe remains a sparse override of Alicorn's built-in defaults. The repository has no Scratchpad-specific theme serializer.

From the repository root, check and explain authored tokens with:

    odin run .deps/alicorn/tools/theme -collection:alicorn=.deps/alicorn -out:out/alicorn/theme-tool.exe -- check themes/scratchpad-workbench.json
    odin run .deps/alicorn/tools/theme -collection:alicorn=.deps/alicorn -out:out/alicorn/theme-tool.exe -- explain themes/scratchpad-paper.json scratchpad.semantic.paper.surface
    odin run .deps/alicorn/tools/theme -collection:alicorn=.deps/alicorn -out:out/alicorn/theme-tool.exe -- explain themes/scratchpad-paper.json material.app.scratchpad.editor.paper
    odin run .deps/alicorn/tools/theme -collection:alicorn=.deps/alicorn -out:out/alicorn/theme-tool.exe -- explain themes/scratchpad-workbench.json recipe.button.tab

Run the same commands for either theme file; explain prints token values and alias provenance, material parameters and source location, or the authored recipe fields and source location.

## Editor typography

Settings uses separate Appearance, Editor, Workspace, and Accessibility pages.
Large windows show a category sidebar; smaller windows use a category selector.
Each page scrolls independently of the fixed header and Done action. Font and
theme changes apply immediately.

Open **Settings → Editor** to choose an installed editor font, change its
logical pixel size, or reset to bundled Atkinson Hyperlegible Mono at 16 px.
The searchable picker lists monospaced families first and also allows
proportional families for prose. Its results are virtualized; each listed name
uses the workbench font, and the selected face appears in the live Settings
preview and the editor. Fonts without an accessible compatible regular face
are reported as unavailable rather than silently substituted.

The preference shares the existing atomic `preferences.json` file with the
theme. Existing theme-only files keep their theme and gain default typography.
Font preferences store a family name and size, resolve local faces at startup,
and fall back to the bundled face when a family disappears. Failed selections
leave the last working font active. The main editor and floating document use
the same regular and optional authentic italic faces, while UI typography stays
unchanged. View → Zoom changes and persists the editor size; Reset Zoom restores
16 px without changing the family.

Windows discovery uses DirectWrite; macOS uses CoreText. Scratchpad supplies
the chosen bytes to Alicorn and resets its own wrapped-row and table-layout
measurements before rebuilding. Font files and extracted collection faces are
limited to 64 MiB. See [font implementation and validation](../../docs/frontends/alicorn/EDITOR-FONTS.md)
for platform coverage and current limitations.

## Included behavior

Alicorn provides native File/Workspace/Edit/View menus; reorderable document tabs and tab drag-and-drop; dirty-close decisions and deferred app shutdown with Save All / Discard All / Cancel; saved-session restoration with per-document editor positions and recent workspaces; a virtualized workspace tree with search, quick open, create, rename, move, OS trash, and file/directory drag-and-drop; current-file Find/Replace and Go to Line; clipboard, undo/redo, IME composition, recovery, conflict resolution, and Save As; a command palette; live Markdown typography and editing commands; Tree-sitter syntax highlighting for Go, TypeScript, and TSX; table navigation/formatting; prose and cell-aware table wrapping; and per-document wrap override.

PNG and QOI files open in normal read-only document tabs, including workspace previews, Quick Open, recent files, session restoration, and reopening a closed tab. The viewer provides Fit, 100% (one source pixel per physical pixel), zoom buttons/shortcuts, and two-axis wheel/scrollbar panning. Zoom preserves the image point at the viewport center. Zoom and pan are retained per open image tab; external file changes replace the image safely. Classification reads only the header. A single worker reads and decodes the latest requested image, discards superseded revisions, and wakes the UI on completion; finished pixels are adopted without a second decode or copy. Encoded input is limited to 128 MiB and decoded pixels to 64 MiB with a 16,384-pixel dimension limit. Invalid or unsupported files show a contextual preview message. Recoverable application errors use persistent dismissible notices above the workspace without shifting its layout.

The editor reads a bounded source window, maps displayed bytes back to source offsets, and keeps edits optimistic while Go remains authoritative. Markdown meaning comes from the Go projection; the frontend renders transported ranges and does not parse Markdown.

Scratchpad installs its bundled Atkinson UI and monospace faces through Alicorn's public application font API, then registers the available platform UI fallback from disk. The empty-editor state uses a small app-owned PNG mark; switching Warm/Cool Light replaces its Runtime image handle and defers release of the old handle until a later build callback, after the replacement presentation has completed. The native host owns GPU textures and rebuilds them from Runtime-owned decoded pixels. Consumer packages include both Atkinson OFL notices in their release manifest.

## Current feature gaps

Compared with the retired Shirei workbench, Alicorn does not yet provide the outline sidebar (code symbols, Markdown headings, tasks, and links), independent manual fold/collapse controls for code and Markdown, editor font-zoom commands, or expand-selection. The [semantic zoom experiment](../../docs/SEMANTIC_VIEWS.md) provides four global depths and local source-range expansion. It restores the last saved workspace, open documents, active document, editor positions, sidebar width, and recent workspace list; crash-recovery data remains a separate lifecycle. The detailed coverage and follow-up list is in [Alicorn coverage](../../docs/frontends/alicorn/PARITY.md). These remaining product gaps are distinct from native-platform verification still pending for v0.1.0.

The retired Shirei and GPUI source is preserved at Git ref `archive/pre-v0.1.0-frontends`; it is no longer an active build target.


## Floating documents

Drag a text-document tab outside the Scratchpad window to open it in a compact
floating editor. The document remains in the shared authoritative workspace,
but its tab and editor view move to the child window. The floating editor has an
independent Alicorn Runtime, source-window reader, and accessibility reader; edits still flow through
Scratchpad's shared serial edit lane. Use **Return to tabs** (or close the
floating window) to put the document back in the primary tab strip. **On top**
is an optional native window setting. Image and unsupported-file tabs are not
detachable yet.

Detaching promotes a preview to a regular document and selects the next primary
tab, or the preceding tab when detaching the last one. On Windows, document
metadata, Save, On top, Return to tabs, and native caption controls share one
workbench-themed title bar. Context menus and persistent operation notices
use the selected workbench theme.

## Durable UI restoration

Clean sessions also retain the focused workspace-tree path and tree scroll, or
the editor focus area. These are additive application fields in the existing
version-1 session, written through Go's atomic session persistence. Alicorn node
IDs and restore tokens never enter that file. Startup expands only the focused
path's ancestors and restores through a fresh tree owner; deleted or hidden paths
fall back to the editor (or tree owner when no document exists). A virtualized
focus target remains logical until its row is described. Last-minute split and
tree-scroll input is captured at shutdown even without another description.

The Find query dogfoods Alicorn's `Text_Field_Buffer` and `text_field_controlled`
API. Its allocator is retained with the application and released at shutdown;
closing Find preserves the query. Committed input refreshes matches after adoption,
then requests an explicit final description. IME preedit remains transient.
Unmodified, non-repeating Enter uses the field's one-shot submit response to move
to the next match; F3/Shift+F3 and Escape keep their existing navigation behavior.
The frontend tests exercise this path against the actual Go backend, including
preedit, commit, submit, programmatic replacement, reopen, source invariance,
and allocator cleanup. Native smoke covers launch and shutdown; physical IME
composition and mixed-DPI pointer behavior still need native use.
