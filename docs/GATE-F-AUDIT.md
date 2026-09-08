# Gate F0 — command and authoring audit

Status: implementation started on the existing `main` baseline. This audit
records the seams that Gate F changes and the limits that remain deliberate.

## Current state before Gate F

`commands/commands.go` already provided stable IDs for file, document, tab,
view, outline, item, selection, comment, format, and edit operations. The IDs
were vocabulary only: shell routing lived in `ui/root.go`, key handling was a
second switch in `handleGlobalInput`, and Markdown task/table behavior was
implemented by UI helpers. Generic typing, clipboard, selection, mouse hit
testing, IME composition, and undo remain editor responsibilities.

The application has one authoritative `document.Document.Editor` buffer.
Markdown projections are revision-tagged and normally debounced by the
application coordinator. Before Gate F, table and task commands either used
the cached projection or reimplemented their own refresh policy. There is no
public language-provider registry; the application currently has one private
analysis seam for the asynchronous derived worker.

The Shirei v0.6.7 audit found useful popup, focus, clipboard, text-input, and
caret/IME primitives, but no public editor-caret rectangle for this custom
visible-row editor. Gate F therefore anchors the source-preserving slash,
fence, and selection surfaces to the editor region while keeping document
selection/caret ownership in `ScratchEditor`. A future exported caret anchor
would improve placement without changing command semantics.

## Gate F command contract

`commands/registry.go` now provides `CommandContext`, descriptors, bindings,
lookup, enablement, and the default registry. Context is explicit and made of
primitive facts: document/surface, root language, selection, table/task/fence
location, projection validity, and editor focus. Markdown commands are visible
and enabled only in Markdown outside a fence. `comment.toggle` is enabled only
for Go, JavaScript, TypeScript, and TSX code documents; unsupported languages
remain ordinary editable text.

`commands/transform.go` is the product/document tier. It snapshots current
source, synchronously reprojects stale Markdown for an explicit command, and
returns one source range/replacement plus the resulting selection. The UI
adapter applies that result with one `Document.Replace`, preserving the
existing one-undo-step behavior. No command package type depends on Shirei.

The initial Markdown IDs are:

```text
markdown.toggle-strong        markdown.toggle-emphasis
markdown.toggle-strike        markdown.toggle-inline-code
markdown.insert-link           markdown.heading-1/2/3
markdown.toggle-bulleted-list markdown.toggle-numbered-list
markdown.toggle-quote         markdown.insert-task
markdown.insert-code-block    markdown.set-fence-language
markdown.insert-table         markdown.insert-divider
markdown.smart-paste
```

The first shell surfaces dispatch these IDs from the Markdown menu,
`Ctrl/Cmd+B`, `Ctrl/Cmd+I`, `Ctrl/Cmd+K`, the source-preserving slash picker,
and a compact selection toolbar. The code proof dispatches
`Ctrl/Cmd+/` to the same stable `comment.toggle` ID.

## F0.5 presentation correction

Fenced code keeps its row-level surface in `markdownLineDecoration`; the
semantic `PresentationCodeBlock` style is now font-only. This prevents the
same background from being painted once per glyph and once per logical row.

## Inspiration map

- Inkdrop v6/v6.1: command-oriented editing, slash commands, autocomplete, and
  a floating toolbar are useful surface precedents; Scratchpad keeps the
  source-native document model instead of adopting CodeMirror.
- Obsidian Live Preview: source and presentation can coexist in one editor
  surface; Scratchpad borrows coexistence while staying source-forward.
- VS Code: stable command IDs plus explicit `when`-style context predicates
  motivate the registry and avoid mode-specific binding tables.
- Kate: compact command/action surfaces motivate the small picker and menu
  treatment.
- md-mode, markdown-mode, and Org: explicit Markdown delimiter alignment and
  table navigation are useful interaction precedents, but Markdown source
  alignment remains parser-owned rather than inferred from numeric content.

References used for the design check:

- https://forum.inkdrop.app/t/inkdrop-desktop-v6-0-0/5571
- https://forum.inkdrop.app/t/inkdrop-desktop-v6-1-0-better-editing-experience/5579
- https://help.obsidian.md/Live%2Bpreview%2Bupdate
- https://code.visualstudio.com/docs/configure/keybindings
- https://code.visualstudio.com/api/references/when-clause-contexts
- https://docs.kde.org/stable_kf6/en/kate/katepart/advanced-editing-tools-commandline.html

Deferred by design: plugin APIs, a general command palette, automatic table
realignment on every Tab, generic horizontal panning controls, rich rendered
Markdown, and IDE/terminal/notes features.
